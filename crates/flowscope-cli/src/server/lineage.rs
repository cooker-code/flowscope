//! HTTP orchestration and durable, same-process Rust storage worker.
use super::lineage_policy::{failure, ApiError, Caller, PolicyDb, Principal, Settings};
use super::{audit::AuditEntry, AppState};
use axum::{
    extract::{Path, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use flowscope_core::AnalyzeResult;
use flowscope_storage::{
    Action, LineageStore, Neo4jStore, SourceContext, StorageError, StorageEvent,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{sync::Arc, time::Duration};
use tokio::sync::{watch, Notify};

pub struct ParsedSubmission {
    pub sql: String,
    pub result: AnalyzeResult,
    pub source: Option<SourceContext>,
    pub dialect: String,
}

pub struct LineageRuntime {
    pub settings: Settings,
    pub db: PolicyDb,
    notify: Notify,
}
impl LineageRuntime {
    pub fn new(settings: Settings) -> anyhow::Result<Self> {
        anyhow::ensure!(
            std::env::var(&settings.neo4j.password_env).is_ok_and(|p| !p.is_empty()),
            "configured Neo4j password environment variable is missing or empty"
        );
        let admin = std::env::var(&settings.admin_token_env).map_err(|_| {
            anyhow::anyhow!("configured admin token environment variable is missing")
        })?;
        let db = PolicyDb::open(&settings.state_db, &admin)?;
        Ok(Self {
            settings,
            db,
            notify: Notify::new(),
        })
    }
    pub async fn caller(
        &self,
        headers: &HeaderMap,
        requested: Option<Action>,
    ) -> Result<Option<Caller>, ApiError> {
        let c = self
            .db
            .authenticate(headers, requested, self.settings.allow_anonymous_parse)
            .await?;
        if c.is_none() && requested.is_some_and(|a| a != Action::ParseOnly) {
            return Err(failure(
                StatusCode::UNAUTHORIZED,
                "anonymous_requests_are_parse_only",
            ));
        }
        Ok(c)
    }
    pub fn source_allowed(
        &self,
        c: &Option<Caller>,
        source: &Option<SourceContext>,
    ) -> Result<(), ApiError> {
        if let Some(c) = c {
            if c.action == Action::Publish {
                let source = source.as_ref().ok_or_else(|| {
                    failure(StatusCode::BAD_REQUEST, "publish_requires_lineage_context")
                })?;
                source.version().map_err(|_| {
                    failure(
                        StatusCode::BAD_REQUEST,
                        "source_version_must_be_nonnegative_integer",
                    )
                })?;
                if !["publish", "withdraw"].contains(&source.event_kind.as_str()) {
                    return Err(failure(
                        StatusCode::BAD_REQUEST,
                        "unsupported_source_event_kind",
                    ));
                }
                if [&source.source_system, &source.source_id]
                    .iter()
                    .any(|value| {
                        value.is_empty()
                            || value.len() > 128
                            || !value
                                .chars()
                                .all(|c| c.is_ascii_alphanumeric() || "_-.".contains(c))
                    })
                {
                    return Err(failure(StatusCode::BAD_REQUEST, "invalid_source_identity"));
                }
                if source.environment != self.settings.neo4j.environment {
                    return Err(failure(
                        StatusCode::FORBIDDEN,
                        "source_environment_mismatch",
                    ));
                }
            }
        }
        Ok(())
    }
    pub async fn accept(
        &self,
        caller: Option<Caller>,
        headers: &HeaderMap,
        parsed: ParsedSubmission,
        entries: Vec<AuditEntry>,
    ) -> Result<HeaderMap, ApiError> {
        let ParsedSubmission {
            sql,
            result,
            source,
            dialect,
        } = parsed;
        let mut response = HeaderMap::new();
        let Some(caller) = caller else {
            self.db.record_audits(entries, None).await?;
            response.insert("x-flowscope-action", HeaderValue::from_static("parse_only"));
            response.insert(
                "x-flowscope-storage-status",
                HeaderValue::from_static("not_requested"),
            );
            return Ok(response);
        };
        if caller.action == Action::ParseOnly {
            self.db
                .record_audits(entries, Some(caller.principal.id))
                .await?;
            response.insert("x-flowscope-action", HeaderValue::from_static("parse_only"));
            response.insert(
                "x-flowscope-storage-status",
                HeaderValue::from_static("not_requested"),
            );
            return Ok(response);
        }
        let request_id = uuid::Uuid::new_v4().to_string();
        let event_id = if let Some(k) = headers.get("idempotency-key") {
            let key = k
                .to_str()
                .ok()
                .filter(|v| !v.is_empty() && v.len() <= 128)
                .ok_or_else(|| failure(StatusCode::BAD_REQUEST, "invalid_idempotency_key"))?;
            flowscope_storage::digest(format!("{}:{key}", caller.principal.id))
        } else {
            uuid::Uuid::new_v4().to_string()
        };
        let event = StorageEvent {
            event_id: event_id.clone(),
            request_id: request_id.clone(),
            principal_id: caller.principal.id.clone(),
            principal_type: caller.principal.kind.clone(),
            token_id: caller.token_id.clone(),
            policy_revision: caller.principal.revision,
            action: caller.action,
            environment: self.settings.neo4j.environment.clone(),
            observed_at: chrono::Utc::now().to_rfc3339(),
            sql,
            dialect,
            parser_build: option_env!("FLOWSCOPE_PARSER_BUILD")
                .unwrap_or(env!("CARGO_PKG_VERSION"))
                .to_string(),
            source,
            analysis: result,
        };
        let inserted = self.db.enqueue(event, entries).await?;
        let storage_status = if inserted {
            "queued".to_string()
        } else {
            self.db.event(event_id.clone(), caller.clone()).await?["status"]
                .as_str()
                .unwrap_or("queued")
                .to_string()
        };
        self.notify.notify_one();
        for (name, value) in [
            ("x-flowscope-request-id", request_id),
            ("x-flowscope-event-id", event_id),
            ("x-flowscope-action", caller.action.as_str().to_string()),
            ("x-flowscope-storage-status", storage_status),
        ] {
            response.insert(
                axum::http::HeaderName::from_static(name),
                HeaderValue::from_str(&value).map_err(|_| {
                    failure(StatusCode::INTERNAL_SERVER_ERROR, "invalid_event_header")
                })?,
            );
        }
        Ok(response)
    }
    async fn retry(&self, event_id: String, reason: String) {
        eprintln!("lineage retry event_id={event_id} reason={reason}");
        if self.db.retry(event_id, reason).await.is_err() {
            eprintln!("lineage retry state could not be saved");
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }
    async fn finish(
        &self,
        event_id: String,
        status: &str,
        outcome: Option<Value>,
        reason: Option<String>,
    ) {
        if self
            .db
            .finish(event_id.clone(), status, outcome, reason)
            .await
            .is_err()
        {
            // The graph may already have committed. Leave the event queued so
            // the next attempt reconciles its receipt instead of duplicating it.
            eprintln!("lineage state save failed event_id={event_id} phase=finish");
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
    }
    pub async fn run(self: Arc<Self>, mut stop: watch::Receiver<bool>) {
        let mut store: Option<Neo4jStore> = None;
        loop {
            if *stop.borrow() {
                break;
            }
            let event = match self.db.next().await {
                Ok(Some(e)) => e,
                _ => {
                    tokio::select! {_=stop.changed()=>{},_=self.notify.notified()=>{},_=tokio::time::sleep(Duration::from_millis(250))=>{}}
                    continue;
                }
            };
            if store.is_none() {
                let password = match std::env::var(&self.settings.neo4j.password_env) {
                    Ok(p) => p,
                    Err(_) => {
                        self.retry(event.event_id, "neo4j_password_missing".into())
                            .await;
                        continue;
                    }
                };
                match tokio::time::timeout(
                    Duration::from_secs(120),
                    Neo4jStore::connect(&self.settings.neo4j, &password),
                )
                .await
                {
                    Ok(Ok(s)) => store = Some(s),
                    Ok(Err(StorageError::Invalid(_))) => {
                        self.finish(
                            event.event_id,
                            "failed",
                            None,
                            Some("neo4j_environment_or_configuration_rejected".into()),
                        )
                        .await;
                        continue;
                    }
                    Ok(Err(err)) => {
                        self.retry(event.event_id, storage_failure_reason("connect", &err))
                            .await;
                        continue;
                    }
                    Err(_) => {
                        self.retry(event.event_id, "neo4j_connect_timeout".into())
                            .await;
                        continue;
                    }
                }
            }
            match tokio::time::timeout(
                Duration::from_secs(8),
                store.as_ref().expect("connected").receipt(&event),
            )
            .await
            {
                Ok(Ok(Some(outcome))) => {
                    let status = if outcome.lineage_status == "blocked" {
                        "blocked"
                    } else {
                        "committed"
                    };
                    self.finish(
                        event.event_id,
                        status,
                        serde_json::to_value(outcome).ok(),
                        None,
                    )
                    .await;
                    continue;
                }
                Ok(Ok(None)) => {}
                Ok(Err(StorageError::Conflict)) => {
                    self.finish(
                        event.event_id,
                        "failed",
                        None,
                        Some("content_or_version_conflict".into()),
                    )
                    .await;
                    continue;
                }
                Ok(Err(err)) => {
                    store = None;
                    self.retry(event.event_id, storage_failure_reason("receipt", &err))
                        .await;
                    continue;
                }
                Err(_) => {
                    store = None;
                    self.retry(event.event_id, "neo4j_receipt_timeout".into())
                        .await;
                    continue;
                }
            }
            // Authorization takes effect at this boundary. A transaction that
            // has already started may finish under its checked policy.
            match self.db.recheck(&event).await {
                Ok(true) => {}
                Ok(false) => {
                    self.finish(
                        event.event_id,
                        "blocked_policy",
                        None,
                        Some("current_policy_or_token_disallows_event".into()),
                    )
                    .await;
                    continue;
                }
                Err(_) => {
                    self.retry(event.event_id, "policy_recheck_failed".into())
                        .await;
                    continue;
                }
            }
            let started = std::time::Instant::now();
            match tokio::time::timeout(
                Duration::from_secs(30),
                store.as_ref().expect("connected store").apply(&event),
            )
            .await
            {
                Ok(Ok(outcome)) => {
                    eprintln!(
                        "lineage apply event_id={} elapsed_ms={} lineage_status={} usage_status={}",
                        event.event_id,
                        started.elapsed().as_millis(),
                        outcome.lineage_status,
                        outcome.usage_status
                    );
                    let status = if outcome.lineage_status == "blocked" {
                        "blocked"
                    } else {
                        "committed"
                    };
                    self.finish(
                        event.event_id,
                        status,
                        serde_json::to_value(outcome).ok(),
                        None,
                    )
                    .await;
                }
                Ok(Err(ref err)) if err.retryable() => {
                    store = None;
                    self.retry(event.event_id, storage_failure_reason("apply", err))
                        .await;
                }
                Err(_) => {
                    store = None;
                    self.retry(event.event_id, "neo4j_apply_timeout".into())
                        .await;
                }
                Ok(Err(err)) => {
                    let reason = match err {
                        StorageError::Conflict => "content_or_version_conflict",
                        StorageError::Database(_) => "neo4j_rejected_event",
                        _ => "invalid_storage_event",
                    };
                    self.finish(event.event_id, "failed", None, Some(reason.into()))
                        .await;
                }
            }
        }
    }
}
fn storage_failure_reason(stage: &str, error: &StorageError) -> String {
    match error.database_code() {
        Some(code) => format!("neo4j_{stage}_failed:{code}"),
        None => format!("neo4j_{stage}_failed"),
    }
}
fn runtime(state: &AppState) -> Result<&Arc<LineageRuntime>, ApiError> {
    state.lineage.as_ref().ok_or_else(|| {
        failure(
            StatusCode::SERVICE_UNAVAILABLE,
            "lineage_storage_not_configured",
        )
    })
}
pub fn routes() -> Router<Arc<AppState>> {
    Router::new()
        .route("/lineage/me", get(me))
        .route("/lineage/policies", get(list).post(save))
        .route("/lineage/policies/{id}", axum::routing::delete(remove))
        .route("/lineage/tokens", post(issue))
        .route("/lineage/tokens/{id}/revoke", post(revoke))
        .route("/lineage/policies/preview", post(preview))
        .route("/lineage/events/{id}", get(event_status))
}
async fn me(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Json<Value>, ApiError> {
    let rt = runtime(&state)?;
    let caller = rt
        .caller(&headers, None)
        .await?
        .ok_or_else(|| failure(StatusCode::UNAUTHORIZED, "bearer_token_required"))?;
    Ok(Json(
        json!({"principalId":caller.principal.id,"name":caller.principal.name,"kind":caller.principal.kind,"action":caller.action,"activeRevision":caller.principal.revision,"environment":rt.settings.neo4j.environment}),
    ))
}
async fn list(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
) -> Result<Response, ApiError> {
    let rt = runtime(&state)?;
    rt.db.admin(&headers).await?;
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(rt.db.list().await?),
    )
        .into_response())
}
async fn save(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(p): Json<Principal>,
) -> Result<Json<Value>, ApiError> {
    let rt = runtime(&state)?;
    let admin = rt.db.admin(&headers).await?;
    let p = rt.db.save(p, admin.principal.id).await?;
    Ok(Json(json!({"policy":p,"activeRevision":p.revision})))
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct DeleteRequest {
    revision: i64,
}
async fn remove(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
    Json(request): Json<DeleteRequest>,
) -> Result<Json<Value>, ApiError> {
    let rt = runtime(&state)?;
    let admin = rt.db.admin(&headers).await?;
    Ok(Json(
        rt.db
            .delete(id, request.revision, admin.principal.id)
            .await?,
    ))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct IssueRequest {
    principal_id: String,
}
async fn issue(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(p): Json<IssueRequest>,
) -> Result<Response, ApiError> {
    let rt = runtime(&state)?;
    rt.db.admin(&headers).await?;
    Ok((
        [(header::CACHE_CONTROL, "no-store")],
        Json(rt.db.issue(p.principal_id).await?),
    )
        .into_response())
}
async fn revoke(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let rt = runtime(&state)?;
    rt.db.admin(&headers).await?;
    rt.db.revoke(id).await?;
    Ok(Json(json!({"revoked":true})))
}
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PreviewRequest {
    policy: Principal,
    audit_id: Option<i64>,
}
async fn preview(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Json(p): Json<PreviewRequest>,
) -> Result<Json<Value>, ApiError> {
    let rt = runtime(&state)?;
    rt.db.admin(&headers).await?;
    p.policy.validate()?;
    let historical = if let Some(id) = p.audit_id {
        Some(rt.db.event_for_audit(id).await?)
    } else {
        None
    };
    let allowed = p.policy.enabled;
    let issues = historical
        .as_ref()
        .map(|e| flowscope_storage::normalize(e).issues)
        .unwrap_or_default();
    Ok(Json(
        json!({"allowed":allowed,"action":p.policy.action,"reason":if allowed{"caller_enabled"}else{"principal_disabled"},"qualityIssues":issues,"writesGraph":false}),
    ))
}
async fn event_status(
    State(state): State<Arc<AppState>>,
    headers: HeaderMap,
    Path(id): Path<String>,
) -> Result<Json<Value>, ApiError> {
    let rt = runtime(&state)?;
    let caller = rt
        .db
        .authenticate(&headers, None, false)
        .await?
        .expect("authenticated");
    Ok(Json(rt.db.event(id, caller).await?))
}

#[cfg(test)]
mod tests {
    use super::*;
    use axum::{
        body::{to_bytes, Body},
        extract::connect_info::MockConnectInfo,
        http::Request,
    };
    use flowscope_core::Dialect;
    use tower::ServiceExt;
    const ADMIN: &str = "isolated-test-admin-token-at-least-thirty-two-chars";
    async fn fixture() -> (tempfile::TempDir, Arc<AppState>, Router) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("state.db");
        let cfg = super::super::ServerConfig {
            dialect: Dialect::Hive,
            watch_dirs: vec![],
            static_files: Some(vec![]),
            metadata_url: None,
            metadata_schema: None,
            port: 3099,
            open_browser: false,
            schema_path: None,
            host: "127.0.0.1".parse().unwrap(),
            audit_log_path: Some(path.clone()),
            lineage_config_path: None,
            #[cfg(feature = "templating")]
            template_config: None,
        };
        let mut state = AppState::new(cfg).await.unwrap();
        let settings = Settings {
            state_db: path.clone(),
            neo4j: flowscope_storage::Neo4jConfig {
                uri: "127.0.0.1:1".into(),
                user: "neo4j".into(),
                password_env: "TEST_NOT_CONNECTED".into(),
                database: "neo4j".into(),
                environment: "test".into(),
            },
            allow_anonymous_parse: false,
            admin_token_env: "TEST_ADMIN".into(),
        };
        state.lineage = Some(Arc::new(LineageRuntime {
            db: PolicyDb::open(&path, ADMIN).unwrap(),
            settings,
            notify: Notify::new(),
        }));
        let state = Arc::new(state);
        let app = super::super::build_router(state.clone()).layer(MockConnectInfo(
            "127.0.0.1:3000".parse::<std::net::SocketAddr>().unwrap(),
        ));
        (dir, state, app)
    }
    async fn request(
        app: &Router,
        path: &str,
        token: Option<&str>,
        body: Option<Value>,
    ) -> (StatusCode, HeaderMap, Value) {
        let mut req = if body.is_some() {
            Request::post(path)
        } else {
            Request::get(path)
        };
        if let Some(token) = token {
            req = req.header("Authorization", format!("Bearer {token}"));
        }
        req = req.header("Content-Type", "application/json");
        let res = app
            .clone()
            .oneshot(
                req.body(Body::from(body.map(|b| b.to_string()).unwrap_or_default()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = res.status();
        let headers = res.headers().clone();
        let bytes = to_bytes(res.into_body(), usize::MAX).await.unwrap();
        let value = serde_json::from_slice(&bytes)
            .unwrap_or_else(|_| json!(String::from_utf8_lossy(&bytes)));
        (status, headers, value)
    }
    fn principal(id: &str, kind: &str, action: &str) -> Value {
        json!({"id":id,"name":id,"kind":kind,"enabled":true,"action":action,"revision":0})
    }
    async fn provision(app: &Router, id: &str, kind: &str, action: &str) -> String {
        let (status, _, saved) = request(
            app,
            "/api/lineage/policies",
            Some(ADMIN),
            Some(principal(id, kind, action)),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{saved}");
        assert_eq!(saved["activeRevision"], 1);
        let (status, _, issued) = request(
            app,
            "/api/lineage/tokens",
            Some(ADMIN),
            Some(json!({"principalId":id})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        issued["token"].as_str().unwrap().into()
    }
    #[test]
    fn storage_diagnostics_never_persist_raw_messages() {
        let error = StorageError::Invalid("secret password and SQL must not be logged".into());
        assert_eq!(
            storage_failure_reason("apply", &error),
            "neo4j_apply_failed"
        );
    }
    #[tokio::test]
    async fn retry_stage_survives_restart_and_clears_only_after_finish() {
        let (dir, state, app) = fixture().await;
        let token = provision(&app, "retry-person", "person", "record_usage").await;
        let (status, headers, _) = request(
            &app,
            "/api/analyze",
            Some(&token),
            Some(json!({"sql":"SELECT id FROM dw.a"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let id = headers["x-flowscope-event-id"]
            .to_str()
            .unwrap()
            .to_string();
        let rt = state.lineage.as_ref().unwrap();
        rt.retry(id.clone(), "neo4j_apply_timeout".into()).await;
        let reopened = PolicyDb::open(&dir.path().join("state.db"), ADMIN).unwrap();
        assert!(
            reopened.next().await.unwrap().is_none(),
            "retry must respect backoff"
        );
        let (_, _, event) = request(
            &app,
            &format!("/api/lineage/events/{id}"),
            Some(ADMIN),
            None,
        )
        .await;
        assert_eq!(event["reason"], "neo4j_apply_timeout");
        assert_eq!(event["status"], "queued");
        assert_eq!(event["attempts"], 1);
        rt.finish(
            id.clone(),
            "committed",
            Some(json!({"lineageStatus":"not_requested","usageStatus":"committed","reason":null})),
            None,
        )
        .await;
        let (_, _, event) = request(
            &app,
            &format!("/api/lineage/events/{id}"),
            Some(ADMIN),
            None,
        )
        .await;
        assert!(event["reason"].is_null());
        assert_eq!(event["status"], "committed");
        assert_eq!(event["attempts"], 1);
    }
    #[tokio::test]
    async fn audit_missing_event_metadata_matches_unknown_filter() {
        let (dir, _state, app) = fixture().await;
        let conn = rusqlite::Connection::open(dir.path().join("state.db")).unwrap();
        conn.execute("INSERT INTO audit_log(ts,client_ip,endpoint,dialect,sql_text,sql_hash,sql_len,success,duration_ms,principal_id,event_id)
            VALUES('2026-11-26T00:00:00.000Z','127.0.0.1','/api/analyze','Hive','SELECT 1','missing-event',8,1,1,'legacy-owner','missing')", []).unwrap();
        for path in ["/api/audit", "/api/audit?lineage_status=unknown"] {
            let (status, _, page) = request(&app, path, Some(ADMIN), None).await;
            assert_eq!(status, StatusCode::OK, "{page}");
            assert_eq!(page["total"], 1);
            assert_eq!(page["records"][0]["lineage_status"], "unknown");
        }
    }

    #[tokio::test]
    async fn audit_retention_settings_require_admin_and_persist() {
        let (dir, state, app) = fixture().await;
        let person = provision(&app, "retention_person", "person", "record_usage").await;
        for token in [None, Some(person.as_str())] {
            for body in [None, Some(json!({"retentionDays":3}))] {
                let (status, _, _) = request(&app, "/api/audit/settings", token, body).await;
                assert!(status == StatusCode::UNAUTHORIZED || status == StatusCode::FORBIDDEN);
            }
        }
        let (_, _, initial) = request(&app, "/api/audit/settings", Some(ADMIN), None).await;
        assert_eq!(initial["retentionDays"], 7);
        for invalid in [
            json!(0),
            json!(-1),
            json!(1.5),
            json!("7"),
            json!(4294967295u64),
        ] {
            let (status, _, _) = request(
                &app,
                "/api/audit/settings",
                Some(ADMIN),
                Some(json!({"retentionDays":invalid})),
            )
            .await;
            assert!(
                status == StatusCode::BAD_REQUEST || status == StatusCode::UNPROCESSABLE_ENTITY
            );
        }
        let (status, _, saved) = request(
            &app,
            "/api/audit/settings",
            Some(ADMIN),
            Some(json!({"retentionDays":3})),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{saved}");
        assert_eq!(saved["retentionDays"], 3);
        drop(super::super::audit::AuditWriter::new(dir.path().join("state.db")).unwrap());
        assert_eq!(
            super::super::audit_retention::read(&dir.path().join("state.db"))
                .unwrap()
                .retention_days,
            3
        );

        let conn = rusqlite::Connection::open(dir.path().join("state.db")).unwrap();
        conn.execute("INSERT INTO audit_log(ts,client_ip,endpoint,dialect,sql_text,sql_hash,sql_len,success,duration_ms)
            VALUES('2026-01-01T00:00:00.000Z','127.0.0.1','/api/analyze','Hive','SELECT 1','expired',8,1,1)", []).unwrap();
        let id = conn.last_insert_rowid();
        assert_eq!(
            super::super::audit_retention::cleanup_batch(
                &dir.path().join("state.db"),
                chrono::Utc::now()
            )
            .unwrap(),
            1
        );
        let (status, _, _) = request(&app, &format!("/api/audit/{id}"), Some(ADMIN), None).await;
        assert_eq!(status, StatusCode::NOT_FOUND);
        let (_, _, page) = request(&app, "/api/audit", Some(ADMIN), None).await;
        assert_eq!(page["total"], 0);
        assert_eq!(
            super::super::audit_retention::read(state.config.audit_log_path.as_ref().unwrap())
                .unwrap()
                .retention_days,
            3
        );
    }

    #[tokio::test]
    async fn audit_lineage_filter_matches_displayed_outcomes_before_pagination() {
        let (dir, state, app) = fixture().await;
        let owner = provision(&app, "filter_owner", "scheduler", "publish").await;
        let other = provision(&app, "filter_other", "scheduler", "publish").await;
        let cases = [
            ("queued", None),
            ("committed", None),
            ("blocked", None),
            ("blocked_policy", None),
            ("failed", None),
            (
                "queued",
                Some(json!({"lineageStatus":"committed","usageStatus":"not_requested"})),
            ),
            (
                "committed",
                Some(json!({"lineageStatus":null,"usageStatus":"not_requested"})),
            ),
            (
                "queued",
                Some(json!({"lineageStatus":"future_status","usageStatus":"not_requested"})),
            ),
            (
                "queued",
                Some(json!({"lineageStatus":"not_requested","usageStatus":"not_requested"})),
            ),
        ];
        let db = &state.lineage.as_ref().unwrap().db;
        for (index, (status, outcome)) in cases.into_iter().enumerate() {
            let (http, headers, result) = request(&app, "/api/analyze", Some(&owner), Some(json!({
                "sql":"SELECT 1", "sourceName":format!("status-filter-{index}"),
                "lineage":{"sourceSystem":"change","sourceId":format!("job-{index}"),"sourceVersion":"1","environment":"test"}
            }))).await;
            assert_eq!(http, StatusCode::OK, "{result}");
            db.finish(
                headers["x-flowscope-event-id"].to_str().unwrap().into(),
                status,
                outcome,
                None,
            )
            .await
            .unwrap();
        }
        for (token, mode) in [
            (&owner, "parse_only"),
            (&other, "publish"),
            (&other, "observe"),
        ] {
            let (status, _, result) = request(&app, "/api/analyze", Some(token), Some(json!({
                "sql":"SELECT 1", "storageMode":mode,
                "lineage":{"sourceSystem":"change","sourceId":"other","sourceVersion":"1","environment":"test"}
            }))).await;
            assert_eq!(status, StatusCode::OK, "{result}");
        }
        db.call(|conn| {
            conn.execute("INSERT INTO audit_log (ts,client_ip,endpoint,dialect,sql_text,sql_hash,sql_len,success,duration_ms) VALUES ('2026-01-01T00:00:00Z','127.0.0.1','/api/analyze','Hive','SELECT 1','legacy',8,1,1)", []).unwrap();
            conn.execute("UPDATE audit_log SET alias_warning=1 WHERE principal_id='filter_owner'", []).unwrap();
            Ok(())
        }).await.unwrap();

        for (status, count) in [
            ("committed", 2),
            ("queued", 1),
            ("blocked", 2),
            ("blocked_policy", 2),
            ("failed", 1),
            ("not_requested", 2),
            ("unknown", 2),
        ] {
            let (http, _, result) = request(
                &app,
                &format!("/api/audit?lineage_status={status}"),
                Some(&owner),
                None,
            )
            .await;
            assert_eq!(http, StatusCode::OK, "{result}");
            assert_eq!(result["total"], count, "status {status}");
            assert_eq!(result["records"].as_array().unwrap().len(), count as usize);
            for row in result["records"].as_array().unwrap() {
                assert_eq!(row["principal_id"], "filter_owner");
                if status == "blocked" || status == "blocked_policy" {
                    assert!([json!("blocked"), json!("blocked_policy")]
                        .contains(&row["lineage_status"]));
                } else if status == "unknown" {
                    assert!([Value::Null, json!("future_status")].contains(&row["lineage_status"]));
                } else {
                    assert_eq!(row["lineage_status"], status);
                }
            }
        }
        for (status, count) in [("queued", 2), ("not_requested", 3), ("unknown", 3)] {
            let (http, _, result) = request(
                &app,
                &format!("/api/audit?lineage_status={status}"),
                Some(ADMIN),
                None,
            )
            .await;
            assert_eq!(http, StatusCode::OK, "{result}");
            assert_eq!(result["total"], count, "admin status {status}");
        }
        let mut pages = vec![];
        for offset in [0, 1] {
            let (status, _, result) = request(&app, &format!("/api/audit?lineage_status=committed&limit=1&offset={offset}&alias_warning=true"), Some(&owner), None).await;
            assert_eq!(status, StatusCode::OK, "{result}");
            assert_eq!(result["total"], 2);
            assert_eq!(result["distinct_sql"], 1);
            assert_eq!(result["records"].as_array().unwrap().len(), 1);
            pages.push(result["records"][0]["id"].clone());
        }
        assert_ne!(pages[0], pages[1]);
        let (_, _, combined) = request(
            &app,
            "/api/audit?lineage_status=committed&source_name=status-filter-5",
            Some(&owner),
            None,
        )
        .await;
        assert_eq!(combined["total"], 1);
        assert_eq!(combined["records"][0]["lineage_status"], "committed");
        assert_eq!(
            request(
                &app,
                "/api/audit?lineage_status=invalid",
                Some(&owner),
                None
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );

        // A parse-only server has no exposed graph results, even if its database has old events.
        let unconfigured = Arc::new(AppState::new(state.config.clone()).await.unwrap());
        let plain = super::super::build_router(unconfigured).layer(MockConnectInfo(
            "127.0.0.1:3000".parse::<std::net::SocketAddr>().unwrap(),
        ));
        let (status, _, unknown) =
            request(&plain, "/api/audit?lineage_status=unknown", None, None).await;
        assert_eq!(status, StatusCode::OK, "{unknown}");
        assert_eq!(unknown["total"], 13);
        let (_, _, committed) =
            request(&plain, "/api/audit?lineage_status=committed", None, None).await;
        assert_eq!(committed["total"], 0);
        let mut config = state.config.clone();
        config.audit_log_path = Some(dir.path().join("plain.db"));
        let empty = super::super::build_router(Arc::new(AppState::new(config).await.unwrap()))
            .layer(MockConnectInfo(
                "127.0.0.1:3000".parse::<std::net::SocketAddr>().unwrap(),
            ));
        assert_eq!(
            request(&empty, "/api/audit?lineage_status=unknown", None, None)
                .await
                .0,
            StatusCode::OK
        );
    }

    #[tokio::test]
    async fn admin_lists_real_tokens_after_restart_and_revoked_tokens_disappear() {
        let (dir, state, app) = fixture().await;
        provision(&app, "token_owner", "scheduler", "publish").await;
        let (status, headers, issued) = request(
            &app,
            "/api/lineage/tokens",
            Some(ADMIN),
            Some(json!({"principalId":"token_owner"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(headers[header::CACHE_CONTROL], "no-store");
        let token = issued["token"].as_str().unwrap();
        let id = issued["tokenId"].as_str().unwrap();
        assert_ne!(token, id);

        let (status, headers, listing) =
            request(&app, "/api/lineage/policies", Some(ADMIN), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(headers[header::CACHE_CONTROL], "no-store");
        let row = listing["tokens"]
            .as_array()
            .unwrap()
            .iter()
            .find(|row| row["id"] == id)
            .unwrap();
        assert_eq!(row["token"], token);
        let (status, _, denied) = request(&app, "/api/lineage/policies", Some(token), None).await;
        assert_eq!(status, StatusCode::FORBIDDEN);
        assert!(!denied.to_string().contains(token));

        // Neither a restart nor bootstrap credential rotation loses issued values.
        let reopened = PolicyDb::open(
            &dir.path().join("state.db"),
            "rotated-test-admin-credential-with-thirty-two-characters",
        )
        .unwrap();
        let listing = reopened.list().await.unwrap();
        assert!(listing["tokens"]
            .as_array()
            .unwrap()
            .iter()
            .any(|row| row["id"] == id && row["token"] == token));
        reopened.revoke(id.into()).await.unwrap();
        let listing = reopened.list().await.unwrap();
        assert!(listing["tokens"]
            .as_array()
            .unwrap()
            .iter()
            .all(|row| row["id"] != id));
        let (status, _, _) = request(&app, "/api/lineage/me", Some(token), None).await;
        assert_eq!(status, StatusCode::UNAUTHORIZED);
        let token_id = id.to_string();
        let secret_cleared = state
            .lineage
            .as_ref()
            .unwrap()
            .db
            .call(move |conn| {
                Ok(conn.query_row(
                    "SELECT enabled=0 AND secret_ciphertext IS NULL FROM lineage_tokens WHERE id=?1",
                    [token_id],
                    |row| row.get::<_, bool>(0),
                ).unwrap())
            })
            .await
            .unwrap();
        assert!(secret_cleared);
    }

    #[tokio::test]
    async fn legacy_hash_only_token_is_preserved_and_captured_after_authentication() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("legacy.db");
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE lineage_principals(id TEXT PRIMARY KEY,document TEXT NOT NULL,revision INTEGER NOT NULL); \
             CREATE TABLE lineage_tokens(id TEXT PRIMARY KEY,principal_id TEXT NOT NULL,digest TEXT NOT NULL UNIQUE,enabled INTEGER NOT NULL,created_at TEXT NOT NULL);",
        )
        .unwrap();
        let mut policy = principal("legacy", "scheduler", "publish");
        policy["revision"] = json!(1);
        conn.execute(
            "INSERT INTO lineage_principals VALUES('legacy',?1,1)",
            [policy.to_string()],
        )
        .unwrap();
        let token = "fst_legacy_test_credential_that_was_originally_hash_only";
        conn.execute(
            "INSERT INTO lineage_tokens VALUES('legacy-id','legacy',?1,1,'2026-01-01T00:00:00Z')",
            [flowscope_storage::digest(token)],
        )
        .unwrap();
        drop(conn);
        let db = PolicyDb::open(&path, ADMIN).unwrap();
        assert!(db.list().await.unwrap()["tokens"][0]["token"].is_null());
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", HeaderValue::from_static("Bearer invalid"));
        assert!(db.authenticate(&headers, None, false).await.is_err());
        assert!(db.list().await.unwrap()["tokens"][0]["token"].is_null());
        headers.insert(
            "Authorization",
            HeaderValue::from_str(&format!("Bearer {token}")).unwrap(),
        );
        let caller = db
            .authenticate(&headers, None, false)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(caller.token_id, "legacy-id");
        let listing = db.list().await.unwrap();
        assert_eq!(listing["tokens"][0]["token"], token);
        let encrypted: Vec<u8> = db
            .call(|conn| {
                Ok(conn
                    .query_row(
                        "SELECT secret_ciphertext FROM lineage_tokens WHERE id='legacy-id'",
                        [],
                        |row| row.get(0),
                    )
                    .unwrap())
            })
            .await
            .unwrap();
        assert!(!encrypted
            .windows(token.len())
            .any(|bytes| bytes == token.as_bytes()));
        drop(db);
        let reopened = PolicyDb::open(&path, ADMIN).unwrap();
        assert_eq!(reopened.list().await.unwrap()["tokens"][0]["token"], token);
    }
    #[tokio::test]
    async fn strict_bearer_privilege_boundaries_and_durable_recovery() {
        let (_dir, state, app) = fixture().await;
        assert_eq!(
            request(&app, "/api/analyze", None, Some(json!({"sql":"SELECT 1"})))
                .await
                .0,
            StatusCode::UNAUTHORIZED
        );
        let person = provision(&app, "alice", "person", "record_usage").await;
        let scheduler = provision(&app, "change", "scheduler", "publish").await;
        let context = json!({"sourceSystem":"change","sourceId":"42","sourceVersion":"1","environment":"test"});
        let (status, headers, result) = request(
            &app,
            "/api/analyze",
            Some(&person),
            Some(
                json!({"sql":"INSERT OVERWRITE TABLE dw.t SELECT id FROM dw.a","lineage":context}),
            ),
        )
        .await;
        assert_eq!(status, StatusCode::OK, "{result}");
        assert_eq!(headers["x-flowscope-action"], "record_usage");
        assert_eq!(headers["x-flowscope-storage-status"], "queued");
        assert_eq!(result["summary"]["hasErrors"], false);
        assert_eq!(
            request(
                &app,
                "/api/analyze",
                Some(&person),
                Some(json!({"sql":"SELECT 1","storageMode":"publish","lineage":context}))
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            request(
                &app,
                "/api/analyze",
                Some(&scheduler),
                Some(json!({"sql":"SELECT 1"}))
            )
            .await
            .0,
            StatusCode::BAD_REQUEST
        );
        assert_eq!(
            request(&app, "/api/lineage/policies", Some(&person), None)
                .await
                .0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            request(&app, "/api/files", Some(&person), None).await.0,
            StatusCode::FORBIDDEN
        );
        let event_id = headers["x-flowscope-event-id"].to_str().unwrap();
        assert_eq!(
            request(
                &app,
                &format!("/api/lineage/events/{event_id}"),
                Some(&scheduler),
                None
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        let (_, _, history) = request(&app, "/api/audit", Some(&person), None).await;
        assert_eq!(history["total"], 1);
        assert_eq!(history["records"][0]["usage_status"], "queued");
        let id = history["records"][0]["id"].as_i64().unwrap();
        assert_eq!(
            request(&app, &format!("/api/audit/{id}"), Some(&scheduler), None)
                .await
                .0,
            StatusCode::FORBIDDEN
        );
        let runtime = state.lineage.as_ref().unwrap();
        let pending = runtime.db.next().await.unwrap().unwrap();
        assert_eq!(pending.action, Action::RecordUsage);
        let recovered = PolicyDb::open(&runtime.settings.state_db, ADMIN).unwrap();
        assert_eq!(
            recovered.next().await.unwrap().unwrap().event_id,
            pending.event_id
        );
        assert!(recovered.recheck(&pending).await.unwrap());
        recovered.revoke(pending.token_id.clone()).await.unwrap();
        assert!(!recovered.recheck(&pending).await.unwrap());
    }
    #[tokio::test]
    async fn audit_unknown_history_is_distinct_from_explicit_parse_only() {
        let (_dir, state, app) = fixture().await;
        let runtime = state.lineage.as_ref().unwrap();
        let legacy_id = runtime
            .db
            .call(|conn| {
                conn.execute(
                    "INSERT INTO audit_log (ts,client_ip,endpoint,dialect,sql_text,sql_hash,sql_len,success,duration_ms) \
                     VALUES ('2026-01-01T00:00:00.000Z','127.0.0.1','/api/analyze','Hive','SELECT 1','legacy',8,1,1)",
                    [],
                )
                .unwrap();
                Ok(conn.last_insert_rowid())
            })
            .await
            .unwrap();
        let parser = provision(&app, "audit_parser", "person", "parse_only").await;
        let (status, _, _) = request(
            &app,
            "/api/analyze",
            Some(&parser),
            Some(json!({"sql":"SELECT 1"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);

        let (_, _, history) = request(&app, "/api/audit", Some(ADMIN), None).await;
        let records = history["records"].as_array().unwrap();
        assert_eq!(records.len(), 2);
        let legacy = records.iter().find(|row| row["id"] == legacy_id).unwrap();
        assert_eq!(legacy["lineage_status"], "unknown");
        assert_eq!(legacy["usage_status"], "unknown");
        let explicit = records
            .iter()
            .find(|row| row["principal_id"] == "audit_parser")
            .unwrap();
        assert_eq!(explicit["lineage_status"], "not_requested");
        assert_eq!(explicit["usage_status"], "not_requested");

        let (status, _, detail) =
            request(&app, &format!("/api/audit/{legacy_id}"), Some(ADMIN), None).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(detail["lineage_status"], "unknown");
    }

    #[tokio::test]
    async fn revisions_preview_and_parse_only_cannot_upgrade() {
        let (_dir, _state, app) = fixture().await;
        let parse = provision(&app, "parser", "person", "parse_only").await;
        assert_eq!(
            request(
                &app,
                "/api/analyze",
                Some(&parse),
                Some(json!({"sql":"SELECT 1","storageMode":"observe"}))
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        let mut policy = principal("schedule", "scheduler", "publish");
        policy["enabled"] = json!(false);
        assert_eq!(
            request(
                &app,
                "/api/lineage/policies",
                Some(ADMIN),
                Some(policy.clone())
            )
            .await
            .0,
            StatusCode::OK
        );
        assert_eq!(
            request(
                &app,
                "/api/lineage/policies",
                Some(ADMIN),
                Some(policy.clone())
            )
            .await
            .0,
            StatusCode::CONFLICT
        );
        let (status, _, preview) = request(
            &app,
            "/api/lineage/policies/preview",
            Some(ADMIN),
            Some(json!({"policy":policy})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(preview["allowed"], false);
        assert_eq!(preview["writesGraph"], false);
        let mut bad = principal("impostor", "person", "publish");
        bad["revision"] = json!(0);
        assert_eq!(
            request(&app, "/api/lineage/policies", Some(ADMIN), Some(bad))
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
    }
    async fn delete_request(
        app: &Router,
        id: &str,
        token: &str,
        revision: i64,
    ) -> (StatusCode, Value) {
        let response = app
            .clone()
            .oneshot(
                Request::delete(format!("/api/lineage/policies/{id}"))
                    .header("Authorization", format!("Bearer {token}"))
                    .header("Content-Type", "application/json")
                    .body(Body::from(json!({"revision":revision}).to_string()))
                    .unwrap(),
            )
            .await
            .unwrap();
        let status = response.status();
        let bytes = to_bytes(response.into_body(), usize::MAX).await.unwrap();
        (
            status,
            serde_json::from_slice(&bytes)
                .unwrap_or_else(|_| json!(String::from_utf8_lossy(&bytes))),
        )
    }

    #[tokio::test]
    async fn physical_delete_removes_identity_and_tokens_but_preserves_history() {
        let (_dir, state, app) = fixture().await;
        let token = provision(&app, "delete_me", "person", "record_usage").await;
        let (status, headers, _) = request(
            &app,
            "/api/analyze",
            Some(&token),
            Some(json!({"sql":"SELECT id FROM dw.source"})),
        )
        .await;
        assert_eq!(status, StatusCode::OK);
        let event_id = headers["x-flowscope-event-id"]
            .to_str()
            .unwrap()
            .to_string();
        let db = &state.lineage.as_ref().unwrap().db;
        let pending = db.next().await.unwrap().unwrap();
        assert_eq!(
            delete_request(&app, "delete_me", &token, 1).await.0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            delete_request(&app, "delete_me", ADMIN, 0).await.0,
            StatusCode::CONFLICT
        );
        let (status, deleted) = delete_request(&app, "delete_me", ADMIN, 1).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(deleted["deletedTokenCount"], 1);
        // Verify the actual rows, not just an enabled flag or response field.
        let counts = db
            .call(|conn| {
                let p: i64 = conn
                    .query_row(
                        "SELECT count(*) FROM lineage_principals WHERE id='delete_me'",
                        [],
                        |r| r.get(0),
                    )
                    .unwrap();
                let t: i64 = conn
                    .query_row(
                        "SELECT count(*) FROM lineage_tokens WHERE principal_id='delete_me'",
                        [],
                        |r| r.get(0),
                    )
                    .unwrap();
                let a: i64 = conn
                    .query_row(
                        "SELECT count(*) FROM audit_log WHERE principal_id='delete_me'",
                        [],
                        |r| r.get(0),
                    )
                    .unwrap();
                Ok((p, t, a))
            })
            .await
            .unwrap();
        assert_eq!(counts, (0, 0, 1));
        assert!(!db.recheck(&pending).await.unwrap());
        assert_eq!(
            request(
                &app,
                "/api/analyze",
                Some(&token),
                Some(json!({"sql":"SELECT 1"}))
            )
            .await
            .0,
            StatusCode::UNAUTHORIZED
        );
        assert_eq!(
            request(
                &app,
                "/api/lineage/tokens",
                Some(ADMIN),
                Some(json!({"principalId":"delete_me"}))
            )
            .await
            .0,
            StatusCode::NOT_FOUND
        );
        assert_eq!(
            request(
                &app,
                &format!("/api/lineage/events/{event_id}"),
                Some(ADMIN),
                None
            )
            .await
            .0,
            StatusCode::OK
        );
        let (status, _, conflict) = request(
            &app,
            "/api/lineage/policies",
            Some(ADMIN),
            Some(principal("delete_me", "person", "record_usage")),
        )
        .await;
        assert_eq!(status, StatusCode::CONFLICT);
        assert_eq!(conflict, "principal_id_previously_used");
        assert_eq!(
            delete_request(&app, "bootstrap", ADMIN, 1).await.0,
            StatusCode::FORBIDDEN
        );
        assert_eq!(
            delete_request(&app, "missing", ADMIN, 1).await.0,
            StatusCode::NOT_FOUND
        );
    }

    #[tokio::test]
    async fn token_only_publish_and_enable_disable_apply_to_requests_and_queue() {
        let (_dir, state, app) = fixture().await;
        let token = provision(&app, "switcher", "scheduler", "publish").await;
        let request_body = json!({"sql":"SELECT 1","lineage":{"sourceSystem":"any_scheduler","sourceId":"job_200","sourceVersion":"1","environment":"test"}});
        let (status, _, _) = request(
            &app,
            "/api/analyze",
            Some(&token),
            Some(request_body.clone()),
        )
        .await;
        assert_eq!(
            status,
            StatusCode::OK,
            "no source or table allow-list is required"
        );
        let db = &state.lineage.as_ref().unwrap().db;
        let queued = db.next().await.unwrap().unwrap();
        let mut policy = principal("switcher", "scheduler", "publish");
        policy["revision"] = json!(1);
        policy["enabled"] = json!(false);
        let (status, _, saved) =
            request(&app, "/api/lineage/policies", Some(ADMIN), Some(policy)).await;
        assert_eq!(status, StatusCode::OK);
        assert_eq!(saved["activeRevision"], 2);
        assert_eq!(
            request(
                &app,
                "/api/analyze",
                Some(&token),
                Some(request_body.clone())
            )
            .await
            .0,
            StatusCode::FORBIDDEN
        );
        assert!(!db.recheck(&queued).await.unwrap());
        let mut policy = saved["policy"].clone();
        policy["enabled"] = json!(true);
        assert_eq!(
            request(&app, "/api/lineage/policies", Some(ADMIN), Some(policy))
                .await
                .0,
            StatusCode::OK
        );
        assert!(db.recheck(&queued).await.unwrap());
        assert_eq!(
            request(
                &app,
                "/api/analyze",
                Some(&token),
                Some(request_body.clone())
            )
            .await
            .0,
            StatusCode::OK
        );
        let mut malformed = request_body.clone();
        malformed["lineage"]["sourceId"] = json!("bad:identity");
        assert_eq!(
            request(&app, "/api/analyze", Some(&token), Some(malformed))
                .await
                .0,
            StatusCode::BAD_REQUEST
        );
        let mut wrong_environment = request_body;
        wrong_environment["lineage"]["environment"] = json!("other");
        assert_eq!(
            request(&app, "/api/analyze", Some(&token), Some(wrong_environment))
                .await
                .0,
            StatusCode::FORBIDDEN
        );
    }

    #[tokio::test]
    async fn legacy_scope_documents_migrate_once_and_keep_tokens() {
        let (_dir, state, app) = fixture().await;
        let token = provision(&app, "legacy", "scheduler", "publish").await;
        let db = &state.lineage.as_ref().unwrap().db;
        let mut legacy = principal("legacy", "scheduler", "publish");
        legacy["revision"] = json!(1);
        legacy["environments"] = json!(["old_env"]);
        legacy["sources"] = json!(["old:scope"]);
        legacy["deniedSources"] = json!(["old:denied"]);
        legacy["tables"] = json!(["old.table"]);
        db.call(move |conn| {
            conn.execute(
                "UPDATE lineage_principals SET document=?1 WHERE id='legacy'",
                [legacy.to_string()],
            )
            .unwrap();
            Ok(())
        })
        .await
        .unwrap();
        let migrated =
            PolicyDb::open(&state.lineage.as_ref().unwrap().settings.state_db, ADMIN).unwrap();
        let list = migrated.list().await.unwrap();
        let p = list["principals"]
            .as_array()
            .unwrap()
            .iter()
            .find(|p| p["id"] == "legacy")
            .unwrap();
        assert_eq!(p["revision"], 2);
        for key in ["environments", "sources", "deniedSources", "tables"] {
            assert!(p.get(key).is_none());
        }
        let mut headers = HeaderMap::new();
        headers.insert("Authorization", format!("Bearer {token}").parse().unwrap());
        assert!(migrated
            .authenticate(&headers, None, false)
            .await
            .unwrap()
            .is_some());
        let reopened =
            PolicyDb::open(&state.lineage.as_ref().unwrap().settings.state_db, ADMIN).unwrap();
        let list = reopened.list().await.unwrap();
        assert_eq!(
            list["principals"]
                .as_array()
                .unwrap()
                .iter()
                .find(|p| p["id"] == "legacy")
                .unwrap()["revision"],
            2
        );
    }
}
