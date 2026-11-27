//! Rust-only black-box verification against a task-owned Neo4j instance.
#![cfg(feature = "serve")]
use flowscope_storage::{Neo4jConfig, Neo4jStore};
use reqwest::{Client, StatusCode};
use serde_json::{json, Value};
use std::{
    net::TcpListener,
    path::Path,
    process::{Child, Command, Stdio},
    time::Duration,
};
const ADMIN: &str = "test-admin-token-for-isolated-http-integration-only";
struct Server(Child);
impl Server {
    fn start(dir: &Path, config: &Path, port: u16, password: &str) -> Self {
        Self(
            Command::new(env!("CARGO_BIN_EXE_flowscope"))
                .args([
                    "--serve",
                    "--dialect",
                    "hive",
                    "--port",
                    &port.to_string(),
                    "--watch",
                ])
                .arg(dir)
                .arg("--lineage-config")
                .arg(config)
                .env("FLOWSCOPE_TEST_ADMIN", ADMIN)
                .env("FLOWSCOPE_TEST_GRAPH_PASSWORD", password)
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }
    fn stop(&mut self) {
        let _ = self.0.kill();
        self.0.wait().unwrap();
    }
}
impl Drop for Server {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
async fn api(
    client: &Client,
    base: &str,
    path: &str,
    token: &str,
    body: Option<Value>,
) -> (StatusCode, reqwest::header::HeaderMap, Value) {
    let req = if let Some(body) = body {
        client.post(format!("{base}{path}")).json(&body)
    } else {
        client.get(format!("{base}{path}"))
    };
    let res = req.bearer_auth(token).send().await.unwrap();
    let status = res.status();
    let headers = res.headers().clone();
    let text = res.text().await.unwrap();
    let value = serde_json::from_str(&text).unwrap_or(json!(text));
    (status, headers, value)
}
async fn ready(client: &Client, base: &str) {
    for _ in 0..100 {
        if client
            .get(format!("{base}/api/health"))
            .send()
            .await
            .is_ok()
        {
            return;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("test server did not start");
}
async fn provision(client: &Client, base: &str, id: &str, kind: &str, action: &str) -> String {
    let policy = json!({"id":id,"name":id,"kind":kind,"action":action,"enabled":true,"revision":0});
    let (status, _, body) = api(client, base, "/api/lineage/policies", ADMIN, Some(policy)).await;
    assert_eq!(status, StatusCode::OK, "{body}");
    let (_, _, issued) = api(
        client,
        base,
        "/api/lineage/tokens",
        ADMIN,
        Some(json!({"principalId":id})),
    )
    .await;
    issued["token"].as_str().unwrap().into()
}
async fn settled(client: &Client, base: &str, id: &str) -> Value {
    for _ in 0..150 {
        let (status, _, body) = api(
            client,
            base,
            &format!("/api/lineage/events/{id}"),
            ADMIN,
            None,
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        if body["status"] != "queued" {
            return body;
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    panic!("event did not settle: {id}");
}
async fn count(store: &Neo4jStore, db: &str, pattern: &str) -> i64 {
    store
        .graph()
        .execute(neo4rs::query(pattern).param("db", db))
        .await
        .unwrap()
        .next()
        .await
        .unwrap()
        .unwrap()
        .get("n")
        .unwrap()
}
#[tokio::test]
#[ignore = "requires an explicitly supplied task-owned loopback Neo4j"]
async fn isolated_http_scheduler_personal_policy_restart_and_receipts() {
    let uri = std::env::var("FLOWSCOPE_TEST_NEO4J_URI").unwrap();
    assert!(uri.starts_with("127.0.0.1:"));
    let password = std::env::var("FLOWSCOPE_TEST_NEO4J_PASSWORD").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let db_path = dir.path().join("state.db");
    let config = dir.path().join("lineage.json");
    let settings = json!({"stateDb":db_path,"adminTokenEnv":"FLOWSCOPE_TEST_ADMIN","neo4j":{"uri":uri,"user":"neo4j","passwordEnv":"FLOWSCOPE_TEST_GRAPH_PASSWORD","environment":"isolated-test"}});
    std::fs::write(&config, settings.to_string()).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let base = format!("http://127.0.0.1:{port}");
    let client = Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap();
    let mut server = Server::start(dir.path(), &config, port, &password);
    ready(&client, &base).await;
    let scheduler = provision(&client, &base, "schedule", "scheduler", "publish").await;
    let person = provision(&client, &base, "alice", "person", "record_usage").await;
    let db = format!("http_{}", uuid::Uuid::new_v4().simple());
    let schema = json!({"tables":[{"schema":db,"name":"a","columns":[{"name":"id","dataType":"BIGINT"}]},{"schema":db,"name":"b","columns":[{"name":"id","dataType":"BIGINT"}]},{"schema":db,"name":"t","columns":[{"name":"id","dataType":"BIGINT"}]}]});
    let source = json!({"sourceSystem":"change","sourceId":db,"sourceVersion":"1","environment":"isolated-test"});
    let publish = json!({"sql":format!("INSERT OVERWRITE TABLE {db}.t SELECT id FROM {db}.a"),"schema":schema,"lineage":source});
    let (status, headers, result) = api(
        &client,
        &base,
        "/api/analyze",
        &scheduler,
        Some(publish.clone()),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{result}");
    assert_eq!(result["summary"]["hasErrors"], false);
    assert_eq!(headers["x-flowscope-storage-status"], "queued");
    let first = headers["x-flowscope-event-id"]
        .to_str()
        .unwrap()
        .to_string();
    let first_outcome = settled(&client, &base, &first).await;
    assert_eq!(first_outcome["lineageStatus"], "committed");
    assert_eq!(
        first_outcome["graphChanges"]["nodes"]["M_TABLE"]["created"],
        2
    );
    let (status, _, metrics) = api(&client, &base, "/api/lineage/metrics", &scheduler, None).await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(metrics["scope"], "own");
    assert_eq!(metrics["queued"], 0);
    assert_eq!(metrics["committed"], 1);
    assert_eq!(metrics["rate"]["confirmedEvents"], 1);
    assert_eq!(metrics["rate"]["warmingUp"], true);
    assert!(metrics["rate"]["eventsPerMinute"].is_null());
    let (_, _, audit) = api(
        &client,
        &base,
        "/api/audit?lineage_status=committed",
        &scheduler,
        None,
    )
    .await;
    assert_eq!(audit["total"], 1);
    let row = &audit["records"][0];
    assert_eq!(row["graph_changes"], first_outcome["graphChanges"]);
    let (_, _, detail) = api(
        &client,
        &base,
        &format!("/api/audit/{}", row["id"]),
        &scheduler,
        None,
    )
    .await;
    assert_eq!(detail["graph_changes"], row["graph_changes"]);
    let store = Neo4jStore::connect(
        &Neo4jConfig {
            uri: uri.clone(),
            user: "neo4j".into(),
            password_env: "unused".into(),
            database: "neo4j".into(),
            environment: "isolated-test".into(),
        },
        &password,
    )
    .await
    .unwrap();
    let formal_before = count(
        &store,
        &db,
        "MATCH (n:M_TABLE {db_name:$db}) RETURN count(n) AS n",
    )
    .await;
    let footprint = json!({"sql":format!("INSERT OVERWRITE TABLE {db}.t SELECT id FROM {db}.b WHERE id>10"),"schema":schema,"lineage":source});
    let response = client
        .post(format!("{base}/api/analyze"))
        .bearer_auth(&person)
        .header("Idempotency-Key", "personal-retry")
        .json(&footprint)
        .send()
        .await
        .unwrap();
    assert_eq!(response.status(), StatusCode::OK);
    assert_eq!(response.headers()["x-flowscope-action"], "record_usage");
    let personal_id = response.headers()["x-flowscope-event-id"]
        .to_str()
        .unwrap()
        .to_string();
    assert_eq!(
        settled(&client, &base, &personal_id).await["usageStatus"],
        "committed"
    );
    let replay = client
        .post(format!("{base}/api/analyze"))
        .bearer_auth(&person)
        .header("Idempotency-Key", "personal-retry")
        .json(&footprint)
        .send()
        .await
        .unwrap();
    assert_eq!(replay.status(), StatusCode::OK);
    assert_eq!(replay.headers()["x-flowscope-event-id"], personal_id);
    assert_eq!(
        count(
            &store,
            &db,
            "MATCH (n:M_TABLE {db_name:$db}) RETURN count(n) AS n"
        )
        .await,
        formal_before
    );
    assert_eq!(count(&store,&db,"MATCH (:M_TABLE {db_name:$db,table_name:'a'})-[:READS_FROM]->(:M_TABLE {db_name:$db,table_name:'t'}) RETURN count(*) AS n").await,1);
    assert_eq!(count(&store,&db,"MATCH (:M_TABLE {db_name:$db,table_name:'b'})-[:READS_FROM]->(:M_TABLE {db_name:$db,table_name:'t'}) RETURN count(*) AS n").await,0);
    assert_eq!(
        api(&client, &base, "/api/lineage/policies", &person, None)
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    let mut forged = footprint.clone();
    forged["storageMode"] = json!("publish");
    assert_eq!(
        api(&client, &base, "/api/analyze", &person, Some(forged))
            .await
            .0,
        StatusCode::FORBIDDEN
    );
    let mut next = footprint.clone();
    next["lineage"]["sourceVersion"] = json!("2");
    let (_, headers, _) = api(&client, &base, "/api/analyze", &scheduler, Some(next)).await;
    let second = headers["x-flowscope-event-id"]
        .to_str()
        .unwrap()
        .to_string();
    assert_eq!(
        settled(&client, &base, &second).await["lineageStatus"],
        "committed"
    );
    assert_eq!(count(&store,&db,"MATCH (:M_TABLE {db_name:$db,table_name:'a'})-[:READS_FROM]->(:M_TABLE {db_name:$db,table_name:'t'}) RETURN count(*) AS n").await,0);
    assert_eq!(count(&store,&db,"MATCH (:M_TABLE {db_name:$db,table_name:'b'})-[:READS_FROM]->(:M_TABLE {db_name:$db,table_name:'t'}) RETURN count(*) AS n").await,1);
    let mut broken = publish;
    broken["sql"] = json!("SELECT FROM");
    broken["lineage"]["sourceVersion"] = json!("3");
    let (_, headers, parsed) = api(&client, &base, "/api/analyze", &scheduler, Some(broken)).await;
    assert_eq!(parsed["summary"]["hasErrors"], true);
    assert_eq!(
        settled(
            &client,
            &base,
            headers["x-flowscope-event-id"].to_str().unwrap()
        )
        .await["lineageStatus"],
        "not_requested"
    );
    let (_, _, history) = api(&client, &base, "/api/audit", &person, None).await;
    assert_eq!(
        history["total"], 1,
        "idempotency does not duplicate audit rows"
    );
    assert_eq!(history["records"][0]["usage_status"], "committed");
    let (_, _, tokens) = api(&client, &base, "/api/lineage/policies", ADMIN, None).await;
    let token_id = tokens["tokens"]
        .as_array()
        .unwrap()
        .iter()
        .find(|t| t["principalId"] == "schedule")
        .unwrap()["id"]
        .as_str()
        .unwrap();
    api(
        &client,
        &base,
        &format!("/api/lineage/tokens/{token_id}/revoke"),
        ADMIN,
        Some(json!({})),
    )
    .await;
    let committed_second = settled(&client, &base, &second).await;
    server.stop();
    // Simulate a crash after Neo4j commit but before the local acknowledgement.
    let conn = rusqlite::Connection::open(&db_path).unwrap();
    conn.execute(
        "UPDATE lineage_events SET status='queued',outcome=NULL,next_attempt=0 WHERE id=?1",
        [&second],
    )
    .unwrap();
    drop(conn);
    server = Server::start(dir.path(), &config, port, &password);
    ready(&client, &base).await;
    let recovered = settled(&client, &base, &second).await;
    assert_eq!(
        recovered["lineageStatus"], "committed",
        "revocation must not hide a previously committed receipt"
    );
    assert_eq!(recovered["graphChanges"], committed_second["graphChanges"]);
    assert_eq!(
        api(&client, &base, "/api/audit", &scheduler, None).await.0,
        StatusCode::UNAUTHORIZED
    );
    assert_eq!(count(&store,&db,"MATCH (:M_TABLE {db_name:$db,table_name:'b'})-[:READS_FROM]->(:M_TABLE {db_name:$db,table_name:'t'}) RETURN count(*) AS n").await,1);
    server.stop();
    assert!(
        server.0.try_wait().unwrap().is_some(),
        "test process exited"
    );
}

#[tokio::test]
#[ignore = "requires an explicitly supplied task-owned loopback Neo4j"]
async fn isolated_pending_events_recover_and_recheck_policy_after_restart() {
    let uri = std::env::var("FLOWSCOPE_TEST_NEO4J_URI").unwrap();
    assert!(uri.starts_with("127.0.0.1:"));
    let password = std::env::var("FLOWSCOPE_TEST_NEO4J_PASSWORD").unwrap();
    let dir = tempfile::tempdir().unwrap();
    let config = dir.path().join("lineage.json");
    let mut settings = json!({"stateDb":dir.path().join("state.db"),"adminTokenEnv":"FLOWSCOPE_TEST_ADMIN","neo4j":{"uri":"127.0.0.1:1","user":"neo4j","passwordEnv":"FLOWSCOPE_TEST_GRAPH_PASSWORD","environment":"isolated-test"}});
    std::fs::write(&config, settings.to_string()).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = listener.local_addr().unwrap().port();
    drop(listener);
    let base = format!("http://127.0.0.1:{port}");
    let client = Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .unwrap();
    let mut server = Server::start(dir.path(), &config, port, &password);
    ready(&client, &base).await;
    let scheduler = provision(&client, &base, "pending_schedule", "scheduler", "publish").await;
    let person = provision(&client, &base, "pending_person", "person", "record_usage").await;
    let payload = json!({"sql":"INSERT OVERWRITE TABLE pending.t SELECT id FROM pending.a","schema":{"tables":[{"schema":"pending","name":"a","columns":[{"name":"id","dataType":"BIGINT"}]},{"schema":"pending","name":"t","columns":[{"name":"id","dataType":"BIGINT"}]}]},"lineage":{"sourceSystem":"change","sourceId":"pending-task","sourceVersion":"1","environment":"isolated-test"}});
    let (status, h, _) = api(&client, &base, "/api/analyze", &scheduler, Some(payload)).await;
    assert_eq!(status, StatusCode::OK);
    let scheduler_id = h["x-flowscope-event-id"].to_str().unwrap().to_string();
    let (_, h, _) = api(
        &client,
        &base,
        "/api/analyze",
        &person,
        Some(json!({"sql":"SELECT id FROM pending.a"})),
    )
    .await;
    let person_id = h["x-flowscope-event-id"].to_str().unwrap().to_string();
    let (_, _, pending) = api(
        &client,
        &base,
        &format!("/api/lineage/events/{scheduler_id}"),
        ADMIN,
        None,
    )
    .await;
    assert_eq!(pending["status"], "queued");
    let changed = json!({"id":"pending_schedule","name":"pending_schedule","kind":"scheduler","enabled":true,"action":"parse_only","revision":1});
    assert_eq!(
        api(
            &client,
            &base,
            "/api/lineage/policies",
            ADMIN,
            Some(changed)
        )
        .await
        .0,
        StatusCode::OK
    );
    server.stop();
    settings["neo4j"]["uri"] = json!(uri);
    std::fs::write(&config, settings.to_string()).unwrap();
    server = Server::start(dir.path(), &config, port, &password);
    ready(&client, &base).await;
    assert_eq!(
        settled(&client, &base, &scheduler_id).await["status"],
        "blocked_policy"
    );
    assert_eq!(
        settled(&client, &base, &person_id).await["usageStatus"],
        "committed"
    );
    let (status, h, _) = api(
        &client,
        &base,
        "/api/analyze",
        &scheduler,
        Some(json!({"sql":"SELECT 1"})),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(h["x-flowscope-action"], "parse_only");
    assert!(!h.contains_key("x-flowscope-event-id"));
    server.stop();
}
