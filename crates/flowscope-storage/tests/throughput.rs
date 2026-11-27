//! Explicit, destructive benchmark for a task-owned loopback database only.
use flowscope_core::{analyze, AnalyzeRequest};
use flowscope_storage::{
    normalize, Action, ChangeCounts, LineageStore, Neo4jConfig, Neo4jStore, SourceContext,
    StorageEvent,
};
use neo4rs::query;
use serde_json::{json, Value};
use std::time::Instant;

#[tokio::test]
#[ignore = "requires a task-owned empty Neo4j and FLOWSCOPE_BENCH_INPUT"]
async fn isolated_real_event_throughput() {
    let uri = std::env::var("FLOWSCOPE_TEST_NEO4J_URI").unwrap();
    assert!(uri.starts_with("127.0.0.1:"));
    assert_eq!(
        std::env::var("FLOWSCOPE_BENCH_ALLOW_RESET").as_deref(),
        Ok("task-owned")
    );
    let config = Neo4jConfig {
        uri,
        user: "neo4j".into(),
        password_env: "FLOWSCOPE_TEST_NEO4J_PASSWORD".into(),
        database: "neo4j".into(),
        environment: "isolated-test".into(),
    };
    let store = Neo4jStore::connect(&config, "unused").await.unwrap();
    let input: Value = serde_json::from_str(
        &std::fs::read_to_string(std::env::var("FLOWSCOPE_BENCH_INPUT").unwrap()).unwrap(),
    )
    .unwrap();
    let audit = &input["audit"]["body"];
    let analysis = if let Some(text) = audit["result_json"].as_str() {
        serde_json::from_str(text).unwrap()
    } else {
        serde_json::from_value(audit["result_json"].clone()).unwrap()
    };
    let base = StorageEvent {
        event_id: "bench".into(),
        request_id: "bench".into(),
        principal_id: "scheduler".into(),
        principal_type: "scheduler".into(),
        token_id: "test".into(),
        policy_revision: 1,
        action: Action::Publish,
        environment: "isolated-test".into(),
        observed_at: "2026-11-27T00:00:00Z".into(),
        sql: audit["sql_text"].as_str().unwrap().into(),
        dialect: "hive".into(),
        parser_build: "bench".into(),
        source: Some(SourceContext {
            source_system: "change".into(),
            source_id: "100".into(),
            source_version: "1".into(),
            environment: "isolated-test".into(),
            ..Default::default()
        }),
        analysis,
    };
    let snapshot = normalize(&base);
    assert!(snapshot.issues.is_empty(), "{:?}", snapshot.issues);
    let mut measurements = Vec::new();
    for trial in 0..3 {
        // Only this disposable database can be reset. Keep background facts identical.
        store
            .graph()
            .run(query(
                "MATCH (n) WHERE NOT n:BENCH_BACKGROUND DETACH DELETE n",
            ))
            .await
            .unwrap();
        store.graph().run(query("UNWIND range(1,94555) AS i MERGE (f:LINEAGE_FACT:BENCH_BACKGROUND {fact_key:'background-'+toString(i)}) SET f.edge_key='background-'+toString(i),f.scope_key='background',f.active=false")).await.unwrap();
        for (phase, version) in [("first_publish", "1"), ("replace_revision", "2")] {
            let mut e = base.clone();
            e.event_id = format!("bench-{trial}-{version}");
            e.source.as_mut().unwrap().source_version = version.into();
            let start = Instant::now();
            let result = store.apply(&e).await.unwrap();
            let ms = start.elapsed().as_secs_f64() * 1000.;
            assert_eq!(result.lineage_status, "committed");
            let mut rows = store.graph().execute(query("MATCH (f:LINEAGE_FACT {scope_key:$scope,active:true}) RETURN count(f) AS n").param("scope",e.source.as_ref().unwrap().scope_key())).await.unwrap();
            let n: i64 = rows.next().await.unwrap().unwrap().get("n").unwrap();
            assert_eq!(n as usize, snapshot.facts.len());
            assert!(store.receipt(&e).await.unwrap().is_some());
            measurements.push(json!({"trial":trial,"phase":phase,"wallMs":ms,"entities":snapshot.entities.len(),"facts":n}));
            println!("MEASUREMENT {}", measurements.last().unwrap());
        }
    }
    if let Ok(path) = std::env::var("FLOWSCOPE_BENCH_OUTPUT") {
        std::fs::write(path, serde_json::to_string_pretty(&measurements).unwrap()).unwrap();
    }
}

#[tokio::test]
#[ignore = "requires a task-owned loopback Neo4j"]
async fn isolated_wide_batches_preserve_endpoints_and_withdraw() {
    let uri = std::env::var("FLOWSCOPE_TEST_NEO4J_URI").unwrap();
    assert!(uri.starts_with("127.0.0.1:"));
    let store = Neo4jStore::connect(
        &Neo4jConfig {
            uri,
            user: "neo4j".into(),
            password_env: "FLOWSCOPE_TEST_NEO4J_PASSWORD".into(),
            database: "neo4j".into(),
            environment: "isolated-test".into(),
        },
        &std::env::var("FLOWSCOPE_TEST_NEO4J_PASSWORD").unwrap(),
    )
    .await
    .unwrap();
    let cols = (0..130)
        .map(|i| json!({"name":format!("c{i}"),"dataType":"BIGINT"}))
        .collect::<Vec<_>>();
    let sql = format!(
        "INSERT OVERWRITE TABLE batch_test.t SELECT {} FROM batch_test.a",
        (0..130)
            .map(|i| format!("c{i}+1 AS c{i}"))
            .collect::<Vec<_>>()
            .join(",")
    );
    let request: AnalyzeRequest = serde_json::from_value(json!({"sql":sql,"dialect":"hive","schema":{"tables":[{"schema":"batch_test","name":"a","columns":cols},{"schema":"batch_test","name":"t","columns":cols}]}})).unwrap();
    let mut e = StorageEvent {
        event_id: "wide-batch-1".into(),
        request_id: "batch".into(),
        principal_id: "scheduler".into(),
        principal_type: "scheduler".into(),
        token_id: "test".into(),
        policy_revision: 1,
        action: Action::Publish,
        environment: "isolated-test".into(),
        observed_at: "2026-11-27T00:00:00Z".into(),
        sql: request.sql.clone(),
        dialect: "hive".into(),
        parser_build: "test".into(),
        source: Some(SourceContext {
            source_system: "change".into(),
            source_id: "300".into(),
            source_version: "1".into(),
            environment: "isolated-test".into(),
            ..Default::default()
        }),
        analysis: analyze(&request),
    };
    let snapshot = normalize(&e);
    assert!(snapshot.issues.is_empty(), "{:?}", snapshot.issues);
    assert!(
        snapshot
            .entities
            .values()
            .filter(|e| e.kind == "physical")
            .count()
            > 256
    );
    assert!(snapshot.facts.len() > 512);
    for version in ["1", "2"] {
        e.event_id = format!("wide-batch-{version}");
        e.source.as_mut().unwrap().source_version = version.into();
        let outcome = store.apply(&e).await.unwrap();
        assert_eq!(outcome.lineage_status, "committed");
        let changes = outcome.graph_changes.unwrap();
        if version == "1" {
            assert_eq!(
                changes.node_totals.created as usize,
                snapshot.entities.len()
            );
            assert_eq!(
                changes.relationship_totals.created as usize,
                snapshot.facts.len()
            );
            assert_eq!(changes.node_totals.updated, 0);
            assert_eq!(changes.relationship_totals.updated, 0);
        } else {
            // Derived identities include the source revision, so a new version
            // creates new derived columns and replaces their projected edges.
            assert_eq!(
                changes.node_totals,
                ChangeCounts {
                    created: 130,
                    updated: 0,
                    deleted: 0
                }
            );
            assert_eq!(changes.nodes["M_COL:Derived"].created, 130);
            assert_eq!(
                changes.relationship_totals,
                ChangeCounts {
                    created: 390,
                    updated: 0,
                    deleted: 390
                }
            );
        }
        let mut rows=store.graph().execute(query("MATCH (f:LINEAGE_FACT {scope_key:$scope,active:true}) OPTIONAL MATCH (a:LINEAGE_ENTITY {lineage_key:f.from_key}) OPTIONAL MATCH (b:LINEAGE_ENTITY {lineage_key:f.to_key}) RETURN count(f) AS n,count(a) AS src,count(b) AS dst").param("scope",e.source.as_ref().unwrap().scope_key())).await.unwrap();
        let row = rows.next().await.unwrap().unwrap();
        for field in ["n", "src", "dst"] {
            assert_eq!(
                row.get::<i64>(field).unwrap() as usize,
                snapshot.facts.len()
            );
        }
        let before = e.content_hash();
        assert_eq!(
            store.receipt(&e).await.unwrap().unwrap().graph_changes,
            Some(changes.clone())
        );
        assert_eq!(store.apply(&e).await.unwrap().graph_changes, Some(changes));
        assert_eq!(before, e.content_hash());
    }
    e.event_id = "wide-batch-withdraw".into();
    e.source.as_mut().unwrap().source_version = "3".into();
    e.source.as_mut().unwrap().event_kind = "withdraw".into();
    let withdrawn = store.apply(&e).await.unwrap();
    assert_eq!(withdrawn.reason.as_deref(), Some("withdrawn"));
    let changes = withdrawn.graph_changes.unwrap();
    assert_eq!(
        changes.relationship_totals.deleted as usize,
        snapshot.facts.len()
    );
    assert_eq!(changes.node_totals.deleted, 0);
    let mut rows = store
        .graph()
        .execute(
            query("MATCH (f:LINEAGE_FACT {scope_key:$scope,active:true}) RETURN count(f) AS n")
                .param("scope", e.source.as_ref().unwrap().scope_key()),
        )
        .await
        .unwrap();
    assert_eq!(
        rows.next().await.unwrap().unwrap().get::<i64>("n").unwrap(),
        0
    );
}
