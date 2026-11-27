use flowscope_core::{analyze, AnalyzeRequest};
use flowscope_storage::{
    normalize, Action, ChangeCounts, GraphChanges, LineageStore, Neo4jConfig, Neo4jStore,
    SourceContext, StorageEvent,
};
use neo4rs::query;
use serde_json::json;

fn event(sql: &str, version: &str) -> StorageEvent {
    let request: AnalyzeRequest =
        serde_json::from_value(json!({"sql":sql,"dialect":"hive","schema":{"tables":[
            {"schema":"dw","name":"a","columns":[{"name":"id","dataType":"BIGINT"}]},
            {"schema":"dw","name":"b","columns":[{"name":"id","dataType":"BIGINT"}]},
            {"schema":"dw","name":"t","columns":[{"name":"target_id","dataType":"BIGINT"}]},
            {"schema":"dw","name":"common","columns":[{"name":"id","dataType":"BIGINT"}]},
            {"schema":"dw","name":"u","columns":[{"name":"target_id","dataType":"BIGINT"}]}
        ]}}))
        .unwrap();
    StorageEvent {
        event_id: format!("event-{version}"),
        request_id: "request".into(),
        principal_id: "scheduler".into(),
        principal_type: "scheduler".into(),
        token_id: "test-token".into(),
        policy_revision: 1,
        action: Action::Publish,
        environment: "isolated-test".into(),
        observed_at: "2026-11-25T00:00:00Z".into(),
        sql: sql.into(),
        dialect: "hive".into(),
        parser_build: "test".into(),
        source: Some(SourceContext {
            source_system: "change".into(),
            source_id: "100".into(),
            source_version: version.into(),
            environment: "isolated-test".into(),
            event_kind: "publish".into(),
            ..Default::default()
        }),
        analysis: analyze(&request),
    }
}

#[test]
fn physical_target_uses_declared_position_and_missing_metadata_blocks() {
    let mut e = event(
        "INSERT OVERWRITE TABLE dw.t SELECT id AS renamed FROM dw.a",
        "1",
    );
    let s = normalize(&e);
    assert!(
        s.issues.is_empty(),
        "{:?}\n{}",
        s.issues,
        serde_json::to_string_pretty(&e.analysis).unwrap()
    );
    assert!(s.entities.values().any(|n| n.kind == "physical"
        && n.table.as_ref().unwrap().table_name == "t"
        && n.column.as_deref() == Some("target_id")));
    assert!(!s
        .entities
        .values()
        .any(|n| n.kind == "physical" && n.column.as_deref() == Some("renamed")));
    let before = e.content_hash();
    for t in &mut e.analysis.resolved_schema.as_mut().unwrap().tables {
        t.updated_at = "later".into();
    }
    assert_eq!(
        before,
        e.content_hash(),
        "schema capture timestamp must not break idempotency"
    );
    e.analysis.resolved_schema = None;
    assert!(normalize(&e)
        .issues
        .iter()
        .any(|i| i.starts_with("pending_metadata:")));
}

#[test]
fn control_edges_do_not_become_value_edges() {
    let e = event(
        "INSERT OVERWRITE TABLE dw.t SELECT row_number() OVER (ORDER BY id) AS n FROM dw.a",
        "1",
    );
    let s = normalize(&e);
    assert!(s.issues.is_empty(), "{:?}", s.issues);
    let controls: Vec<_> = s
        .facts
        .values()
        .filter(|f| f.kind == "CONTROLS_COL")
        .collect();
    assert!(!controls.is_empty());
    for c in controls {
        assert!(!s
            .facts
            .values()
            .any(|f| f.from == c.from && f.to == c.to && f.kind == "DERIVES_COL"));
    }
}

#[test]
fn cte_union_and_join_preserve_source_endpoints() {
    for sql in [
        "WITH x AS (SELECT id FROM dw.a) INSERT OVERWRITE TABLE dw.t SELECT id FROM x",
        "INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.a UNION ALL SELECT id FROM dw.b",
    ] {
        let e = event(sql, "1");
        let s = normalize(&e);
        assert!(s.issues.is_empty(), "{sql}: {:?}", s.issues);
        assert!(s.facts.values().any(|f| f.kind == "DERIVES_COL"));
    }
    let e = event(
        "INSERT OVERWRITE TABLE dw.t SELECT a.id FROM dw.a a LEFT JOIN dw.b b ON a.id=b.id",
        "1",
    );
    let s = normalize(&e);
    assert!(s.issues.is_empty(), "{:?}", s.issues);
    let joins: Vec<_> = s
        .facts
        .values()
        .filter(|f| f.kind == "JOINS_WITH")
        .collect();
    assert!(
        !joins.is_empty(),
        "{}",
        serde_json::to_string_pretty(&e.analysis).unwrap()
    );
    for f in joins {
        assert_eq!(s.entities[&f.from].table.as_ref().unwrap().table_name, "a");
        assert_eq!(s.entities[&f.to].table.as_ref().unwrap().table_name, "b");
    }
}

async fn count(store: &Neo4jStore, cypher: &str) -> i64 {
    store
        .graph()
        .execute(query(cypher))
        .await
        .unwrap()
        .next()
        .await
        .unwrap()
        .unwrap()
        .get("n")
        .unwrap()
}

/// Run only against the task-owned, empty Neo4j container. Never accepts a
/// production URI; the harness explicitly enables this test and supplies env.
#[tokio::test]
#[ignore = "requires FLOWSCOPE_TEST_NEO4J_URI and an isolated empty database"]
async fn isolated_neo4j_versions_usage_shared_sources_and_replay() {
    let uri = std::env::var("FLOWSCOPE_TEST_NEO4J_URI").unwrap();
    assert!(
        uri.starts_with("127.0.0.1:"),
        "isolated test must use loopback"
    );
    let config = Neo4jConfig {
        uri,
        user: "neo4j".into(),
        password_env: "FLOWSCOPE_TEST_NEO4J_PASSWORD".into(),
        database: "neo4j".into(),
        environment: "isolated-test".into(),
    };
    let store = Neo4jStore::connect(&config, &std::env::var(&config.password_env).unwrap())
        .await
        .unwrap();
    assert_eq!(
        count(&store, "MATCH (n:LINEAGE_EVENT) RETURN count(n) AS n").await,
        0,
        "requires an empty task database"
    );
    let a = event("INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.a", "1");
    assert!(
        normalize(&a).issues.is_empty(),
        "{:?}\n{}",
        normalize(&a).issues,
        serde_json::to_string_pretty(&a.analysis).unwrap()
    );
    let initial = store.apply(&a).await.unwrap();
    assert_eq!(initial.lineage_status, "committed");
    let changes = initial.graph_changes.clone().unwrap();
    assert_eq!(
        changes.node_totals.created as i64,
        count(&store, "MATCH (n:LINEAGE_ENTITY) RETURN count(n) AS n").await
    );
    assert_eq!(changes.nodes["M_TABLE"].created, 2);
    assert_eq!(changes.nodes["M_COL:Physical"].created, 2);
    assert_eq!(
        changes.relationship_totals.created as i64,
        count(
            &store,
            "MATCH ()-[r]->() WHERE r.projection_key IS NOT NULL RETURN count(r) AS n"
        )
        .await
    );
    assert_eq!(changes.node_totals.updated, 0);
    assert_eq!(
        store.apply(&a).await.unwrap().graph_changes,
        initial.graph_changes
    );
    assert_eq!(
        store.receipt(&a).await.unwrap().unwrap().graph_changes,
        initial.graph_changes
    );
    let mut same = a.clone();
    same.event_id = "same-version-new-event".into();
    assert_eq!(
        store.apply(&same).await.unwrap().graph_changes,
        Some(GraphChanges::default())
    );
    let nodes = count(&store, "MATCH (n:M_TABLE) RETURN count(n) AS n").await;
    let facts = count(
        &store,
        "MATCH ()-[r:READS_FROM|DERIVES_COL|REF_TABLE_COL]->() RETURN count(r) AS n",
    )
    .await;
    let mut personal = event(
        "INSERT OVERWRITE TABLE dw.new_target SELECT id FROM dw.a WHERE id>10",
        "1",
    );
    personal.event_id = "personal".into();
    personal.principal_id = "person-1".into();
    personal.principal_type = "person".into();
    personal.action = Action::RecordUsage;
    personal.source = None;
    assert_eq!(
        store.apply(&personal).await.unwrap().usage_status,
        "committed"
    );
    store.apply(&personal).await.unwrap();
    assert_eq!(
        count(&store, "MATCH (n:M_TABLE) RETURN count(n) AS n").await,
        nodes
    );
    assert_eq!(
        count(
            &store,
            "MATCH ()-[r:READS_FROM|DERIVES_COL|REF_TABLE_COL]->() RETURN count(r) AS n"
        )
        .await,
        facts
    );
    assert_eq!(count(&store,"MATCH (:QUERY_ACTOR {principal_id:'person-1'})-[:SUBMITTED_QUERY]->(q:QUERY_EVENT) RETURN count(q) AS n").await,1);
    assert_eq!(count(&store,"MATCH (:QUERY_EVENT)-[:USES_TABLE {usage_role:'declared_write'}]->(:TABLE_REFERENCE) RETURN count(*) AS n").await,1);
    let mut unqualified = event("SELECT id FROM unknown_personal_table", "1");
    unqualified.event_id = "personal-unqualified".into();
    unqualified.principal_id = "person-1".into();
    unqualified.principal_type = "person".into();
    unqualified.action = Action::RecordUsage;
    unqualified.source = None;
    assert_eq!(
        store.apply(&unqualified).await.unwrap().usage_status,
        "committed"
    );
    assert_eq!(count(&store,"MATCH (:QUERY_EVENT {event_id:'personal-unqualified'})-[:USES_TABLE {usage_role:'read'}]->(:TABLE_REFERENCE) RETURN count(*) AS n").await,1);
    assert_eq!(
        count(&store, "MATCH (n:M_TABLE) RETURN count(n) AS n").await,
        nodes
    );
    let mut shared = a.clone();
    shared.event_id = "shared".into();
    shared.source.as_mut().unwrap().source_id = "101".into();
    store.apply(&shared).await.unwrap();
    let b = event("INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.b", "2");
    store.apply(&b).await.unwrap();
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'a'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,1,"second source retains its contribution");
    let mut withdraw = shared.clone();
    withdraw.event_id = "withdraw".into();
    withdraw.source.as_mut().unwrap().source_version = "3".into();
    withdraw.source.as_mut().unwrap().event_kind = "withdraw".into();
    let withdrawn = store.apply(&withdraw).await.unwrap().graph_changes.unwrap();
    assert!(withdrawn.relationships["READS_FROM"].deleted > 0);
    assert_eq!(withdrawn.node_totals.deleted, 0);
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'a'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,0);
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'b'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,1);
    let before = count(&store, "MATCH (f:LINEAGE_FACT) RETURN count(f) AS n").await;
    store.apply(&b).await.unwrap();
    assert_eq!(
        before,
        count(&store, "MATCH (f:LINEAGE_FACT) RETURN count(f) AS n").await
    );
    let mut stale = a.clone();
    stale.event_id = "stale".into();
    assert_eq!(
        store.apply(&stale).await.unwrap().reason.as_deref(),
        Some("stale_source_version")
    );
    let mut broken = event("INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.a", "4");
    broken.analysis.resolved_schema = None;
    assert_eq!(
        store.apply(&broken).await.unwrap().lineage_status,
        "not_requested"
    );
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'b'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,1,"invalid candidate leaves current graph intact");
    let mut conflict = b.clone();
    conflict.event_id = "conflict".into();
    conflict.sql.push(' ');
    assert!(store.apply(&conflict).await.is_err());
    assert_eq!(
        count(
            &store,
            "MATCH (r:LINEAGE_EVENT {event_id:'conflict'}) RETURN count(r) AS n"
        )
        .await,
        0,
        "failed transaction rolls back event too"
    );
    let mut late = event("INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.a", "6");
    late.event_id = "late-failure".into();
    let normalized = normalize(&late);
    let reserved = normalized
        .entities
        .values()
        .find(|n| n.kind == "derived")
        .unwrap()
        .key
        .clone();
    store
        .graph()
        .run(
            query("CREATE (:LINEAGE_ENTITY:WRITER_TEST_BLOCKER {lineage_key:$key})")
                .param("key", reserved),
        )
        .await
        .unwrap();
    let error = store.apply(&late).await.unwrap_err();
    assert_eq!(
        error.database_code(),
        Some("Neo.ClientError.Schema.ConstraintValidationFailed")
    );
    assert!(
        !error.retryable(),
        "a constraint failure must not retry forever"
    );
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'b'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,1,"late failure rolls back previous contribution deactivation");
    assert_eq!(
        count(
            &store,
            "MATCH (e:LINEAGE_EVENT {event_id:'late-failure'}) RETURN count(e) AS n"
        )
        .await,
        0
    );
    store
        .graph()
        .run(query("MATCH (n:WRITER_TEST_BLOCKER) DELETE n"))
        .await
        .unwrap();
    let mut newer = event("INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.b", "5");
    let mut older = event("INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.a", "4");
    newer.event_id = "concurrent-new".into();
    older.event_id = "concurrent-old".into();
    let (a, b) = tokio::join!(store.apply(&newer), store.apply(&older));
    // Neo4j may abort one lock contender. Explicit transactions do not retry
    // themselves; replay exactly the same event, as the durable worker does.
    for (event, result) in [(&newer, a), (&older, b)] {
        if let Err(error) = result {
            assert!(
                error.retryable(),
                "unexpected terminal concurrent error: {error}"
            );
            store.apply(event).await.unwrap();
        }
    }
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'b'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,1,"concurrent old/new commits leave newest source current");
    assert_eq!(count(&store,"MATCH (:M_TABLE {table_name:'a'})-[:READS_FROM]->(:M_TABLE {table_name:'t'}) RETURN count(*) AS n").await,0);
    // Different sources concurrently create the same physical objects.
    let mut left = event("INSERT OVERWRITE TABLE dw.u SELECT id FROM dw.common", "1");
    left.event_id = "shared-create-left".into();
    left.source.as_mut().unwrap().source_id = "201".into();
    let mut right = left.clone();
    right.event_id = "shared-create-right".into();
    right.source.as_mut().unwrap().source_id = "202".into();
    let (left_result, right_result) = tokio::join!(store.apply(&left), store.apply(&right));
    let mut created_tables = 0;
    let mut created_columns = 0;
    for (event, result) in [(&left, left_result), (&right, right_result)] {
        let outcome = match result {
            Ok(outcome) => outcome,
            Err(error) => {
                assert!(error.retryable(), "{error}");
                store.apply(event).await.unwrap()
            }
        };
        let changes = outcome.graph_changes.unwrap();
        created_tables += changes
            .nodes
            .get("M_TABLE")
            .cloned()
            .unwrap_or_default()
            .created;
        created_columns += changes
            .nodes
            .get("M_COL:Physical")
            .cloned()
            .unwrap_or_default()
            .created;
    }
    assert_eq!(created_tables, 2);
    assert_eq!(created_columns, 2);
    // An identical publication by a new source touches existing physical nodes,
    // but only the target's producer properties change; no timestamp-only updates.
    let mut third = left.clone();
    third.event_id = "shared-third".into();
    third.source.as_mut().unwrap().source_id = "203".into();
    let delta = store.apply(&third).await.unwrap().graph_changes.unwrap();
    assert_eq!(
        delta
            .nodes
            .get("M_COL:Physical")
            .cloned()
            .unwrap_or_default(),
        ChangeCounts::default()
    );
    assert_eq!(
        delta.nodes["M_TABLE"],
        ChangeCounts {
            created: 0,
            updated: 1,
            deleted: 0
        }
    );
    // Backward-compatible receipts distinguish unavailable statistics from zero.
    let old: flowscope_storage::ApplyOutcome = serde_json::from_value(
        json!({"lineageStatus":"committed","usageStatus":"not_requested","reason":null}),
    )
    .unwrap();
    assert!(old.graph_changes.is_none());
}
