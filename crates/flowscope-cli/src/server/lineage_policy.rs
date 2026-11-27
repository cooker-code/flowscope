//! Persistent caller identity and policy. All SQLite access runs off the async executor.
use super::audit::{insert_entry, AuditEntry};
use super::token_vault::TokenVault;
use axum::http::{HeaderMap, StatusCode};
use flowscope_storage::{digest, Action, Neo4jConfig, StorageEvent};
use rusqlite::{params, Connection, OptionalExtension};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    path::{Path, PathBuf},
    sync::{Arc, Mutex},
    time::Duration,
};

pub type ApiError = (StatusCode, String);
type StoredEventRow = (
    String,
    String,
    String,
    i64,
    Option<String>,
    Option<String>,
    String,
);
pub fn failure(status: StatusCode, code: &str) -> ApiError {
    (status, code.to_string())
}
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Settings {
    pub state_db: PathBuf,
    pub neo4j: Neo4jConfig,
    #[serde(default)]
    pub allow_anonymous_parse: bool,
    #[serde(default = "admin_env")]
    pub admin_token_env: String,
}
fn admin_env() -> String {
    "FLOWSCOPE_LINEAGE_ADMIN_TOKEN".into()
}
impl Settings {
    pub fn load(path: &Path) -> anyhow::Result<Self> {
        let settings: Self = serde_json::from_slice(&std::fs::read(path)?)?;
        anyhow::ensure!(
            !settings.neo4j.uri.is_empty()
                && !settings.neo4j.uri.contains('@')
                && !settings.neo4j.user.is_empty()
                && !settings.neo4j.database.is_empty(),
            "Neo4j requires URI without embedded credentials, user and database"
        );
        anyhow::ensure!(
            !settings.neo4j.environment.trim().is_empty()
                && !settings.neo4j.password_env.is_empty()
                && !settings.admin_token_env.is_empty(),
            "environment and secret environment variable names are required"
        );
        Ok(settings)
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Principal {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub enabled: bool,
    pub action: Action,
    pub revision: i64,
}
impl Principal {
    pub fn validate(&self) -> Result<(), ApiError> {
        if self.id.is_empty()
            || self.id.len() > 128
            || !self
                .id
                .chars()
                .all(|c| c.is_ascii_alphanumeric() || "_-.".contains(c))
            || self.name.trim().is_empty()
        {
            return Err(failure(
                StatusCode::BAD_REQUEST,
                "invalid_principal_identity",
            ));
        }
        if !["scheduler", "person", "admin"].contains(&self.kind.as_str())
            || (self.action == Action::Publish && self.kind != "scheduler")
            || (self.action == Action::RecordUsage && self.kind != "person")
        {
            return Err(failure(StatusCode::BAD_REQUEST, "invalid_principal_policy"));
        }
        Ok(())
    }
    pub fn choose(&self, requested: Option<Action>) -> Result<Action, ApiError> {
        if !self.enabled {
            return Err(failure(StatusCode::FORBIDDEN, "principal_disabled"));
        }
        let action = requested.unwrap_or(self.action);
        if action != self.action
            && !(action == Action::ParseOnly
                || action == Action::Observe
                    && matches!(self.action, Action::Publish | Action::RecordUsage))
        {
            return Err(failure(StatusCode::FORBIDDEN, "action_not_allowed"));
        }
        Ok(action)
    }
}
#[derive(Clone)]
pub struct Caller {
    pub principal: Principal,
    pub token_id: String,
    pub action: Action,
}
#[derive(Clone)]
pub struct PolicyDb {
    conn: Arc<Mutex<Connection>>,
    token_vault: TokenVault,
}
impl PolicyDb {
    pub fn open(path: &Path, admin_token: &str) -> anyhow::Result<Self> {
        anyhow::ensure!(
            admin_token.len() >= 32,
            "bootstrap admin token must contain at least 32 characters"
        );
        if let Some(parent) = path.parent() {
            if !parent.as_os_str().is_empty() {
                std::fs::create_dir_all(parent)?;
            }
        }
        let mut conn = Connection::open(path)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
        }
        conn.busy_timeout(Duration::from_secs(5))?;
        conn.execute_batch("PRAGMA journal_mode=WAL; PRAGMA foreign_keys=ON;
            CREATE TABLE IF NOT EXISTS lineage_principals(id TEXT PRIMARY KEY,document TEXT NOT NULL,revision INTEGER NOT NULL);
            CREATE TABLE IF NOT EXISTS lineage_tokens(id TEXT PRIMARY KEY,principal_id TEXT NOT NULL REFERENCES lineage_principals(id),digest TEXT NOT NULL UNIQUE,enabled INTEGER NOT NULL,created_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS lineage_policy_changes(id INTEGER PRIMARY KEY,principal_id TEXT NOT NULL,revision INTEGER NOT NULL,actor TEXT NOT NULL,changed_at TEXT NOT NULL);
            CREATE TABLE IF NOT EXISTS lineage_events(id TEXT PRIMARY KEY,principal_id TEXT NOT NULL,token_id TEXT NOT NULL,action TEXT NOT NULL,body TEXT NOT NULL,content_hash TEXT NOT NULL,status TEXT NOT NULL,attempts INTEGER NOT NULL DEFAULT 0,next_attempt INTEGER NOT NULL DEFAULT 0,outcome TEXT,last_error TEXT,created_at TEXT NOT NULL);
            CREATE INDEX IF NOT EXISTS lineage_events_pending ON lineage_events(status,next_attempt);")?;
        migrate_token_policies(&mut conn)?;
        if let Err(error) =
            conn.execute_batch("ALTER TABLE lineage_tokens ADD COLUMN secret_ciphertext BLOB")
        {
            if !error.to_string().contains("duplicate column") {
                return Err(error.into());
            }
        }
        let has_encrypted_tokens = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM lineage_tokens WHERE secret_ciphertext IS NOT NULL)",
            [],
            |row| row.get(0),
        )?;
        let token_vault = TokenVault::load(path, has_encrypted_tokens)?;
        let principal = Principal {
            id: "bootstrap".into(),
            name: "Bootstrap administrator".into(),
            kind: "admin".into(),
            enabled: true,
            action: Action::Observe,
            revision: 1,
        };
        conn.execute("INSERT INTO lineage_principals(id,document,revision) VALUES('bootstrap',?1,1) ON CONFLICT(id) DO UPDATE SET document=excluded.document,revision=excluded.revision",[serde_json::to_string(&principal)?])?;
        conn.execute("INSERT INTO lineage_tokens(id,principal_id,digest,enabled,created_at) VALUES('bootstrap','bootstrap',?1,1,?2) ON CONFLICT(id) DO UPDATE SET digest=excluded.digest,enabled=1",params![digest(admin_token),chrono::Utc::now().to_rfc3339()])?;
        Ok(Self {
            conn: Arc::new(Mutex::new(conn)),
            token_vault,
        })
    }
    pub async fn call<T: Send + 'static>(
        &self,
        f: impl FnOnce(&mut Connection) -> Result<T, ApiError> + Send + 'static,
    ) -> Result<T, ApiError> {
        let conn = self.conn.clone();
        tokio::task::spawn_blocking(move || {
            let mut conn = conn.lock().map_err(|_| {
                failure(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "policy_database_unavailable",
                )
            })?;
            f(&mut conn)
        })
        .await
        .map_err(|_| failure(StatusCode::INTERNAL_SERVER_ERROR, "policy_task_failed"))?
    }
    pub async fn authenticate(
        &self,
        headers: &HeaderMap,
        requested: Option<Action>,
        anonymous: bool,
    ) -> Result<Option<Caller>, ApiError> {
        let token = match headers.get(axum::http::header::AUTHORIZATION) {
            None if anonymous => return Ok(None),
            Some(h) => h
                .to_str()
                .ok()
                .and_then(|s| s.strip_prefix("Bearer "))
                .filter(|s| !s.is_empty())
                .ok_or_else(|| failure(StatusCode::UNAUTHORIZED, "invalid_bearer_token"))?,
            None => return Err(failure(StatusCode::UNAUTHORIZED, "bearer_token_required")),
        };
        let hash = digest(token);
        let raw = token.to_owned();
        let token_vault = self.token_vault.clone();
        self.call(move|conn|{
            let row:Option<(String,String,bool)>=conn.query_row("SELECT t.id,p.document,t.secret_ciphertext IS NOT NULL FROM lineage_tokens t JOIN lineage_principals p ON p.id=t.principal_id WHERE t.digest=?1 AND t.enabled=1",[hash],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?))).optional().map_err(db_error)?;
            let (token_id,document,has_secret)=row.ok_or_else(||failure(StatusCode::UNAUTHORIZED,"invalid_bearer_token"))?;
            let principal:Principal=serde_json::from_str(&document).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"invalid_stored_policy"))?;
            let action=principal.choose(requested)?;
            if token_id!="bootstrap" && !has_secret {
                let encrypted=token_vault.encrypt(&token_id,&raw)?;
                conn.execute("UPDATE lineage_tokens SET secret_ciphertext=?1 WHERE id=?2 AND secret_ciphertext IS NULL",params![encrypted,token_id]).map_err(db_error)?;
            }
            Ok(Some(Caller{principal,token_id,action}))
        }).await
    }
    pub async fn admin(&self, headers: &HeaderMap) -> Result<Caller, ApiError> {
        let caller = self
            .authenticate(headers, None, false)
            .await?
            .expect("authenticated");
        if caller.principal.kind != "admin" {
            return Err(failure(StatusCode::FORBIDDEN, "policy_admin_required"));
        }
        Ok(caller)
    }
    pub async fn list(&self) -> Result<Value, ApiError> {
        let token_vault = self.token_vault.clone();
        self.call(move|conn|{
        let mut stmt=conn.prepare("SELECT document FROM lineage_principals ORDER BY id").map_err(db_error)?;
        let rows=stmt.query_map([],|r|r.get::<_,String>(0)).map_err(db_error)?;
        let mut principals=vec![];for row in rows{let s=row.map_err(db_error)?;principals.push(serde_json::from_str::<Value>(&s).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"stored_policy_invalid"))?);}
        let mut stmt=conn.prepare("SELECT id,principal_id,created_at,secret_ciphertext FROM lineage_tokens WHERE enabled=1 AND id!='bootstrap' ORDER BY created_at DESC").map_err(db_error)?;
        let rows=stmt.query_map([],|r|Ok((r.get::<_,String>(0)?,r.get::<_,String>(1)?,r.get::<_,String>(2)?,r.get::<_,Option<Vec<u8>>>(3)?))).map_err(db_error)?;
        let mut tokens=vec![];
        for row in rows {
            let (id,principal,created_at,encrypted)=row.map_err(db_error)?;
            let token=encrypted.map(|value|token_vault.decrypt(&id,&value)).transpose()?;
            tokens.push(json!({"id":id,"principalId":principal,"enabled":true,"createdAt":created_at,"token":token}));
        }
        Ok(json!({"principals":principals,"tokens":tokens}))
    }).await
    }
    pub async fn event_for_audit(&self, id: i64) -> Result<StorageEvent, ApiError> {
        self.call(move|conn|{
            let body:Option<String>=conn.query_row("SELECT e.body FROM audit_log a JOIN lineage_events e ON e.id=a.event_id WHERE a.id=?1",[id],|r|r.get(0)).optional().map_err(db_error)?;
            serde_json::from_str(&body.ok_or_else(||failure(StatusCode::NOT_FOUND,"history_has_no_storage_event"))?).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"event_invalid"))
        }).await
    }
    pub async fn save(&self, mut p: Principal, actor: String) -> Result<Principal, ApiError> {
        p.validate()?;
        if p.id == "bootstrap" {
            return Err(failure(
                StatusCode::FORBIDDEN,
                "bootstrap_policy_is_deployment_managed",
            ));
        }
        self.call(move|conn|{
            let tx=conn.transaction().map_err(db_error)?;
            let current:Option<i64>=tx.query_row("SELECT revision FROM lineage_principals WHERE id=?1",[&p.id],|r|r.get(0)).optional().map_err(db_error)?;
            if current.unwrap_or(0)!=p.revision{return Err(failure(StatusCode::CONFLICT,"policy_revision_conflict"));}
            let retired:bool=tx.query_row("SELECT EXISTS(SELECT 1 FROM lineage_policy_changes WHERE principal_id=?1)",[&p.id],|r|r.get(0)).map_err(db_error)?;
            if current.is_none() && retired {return Err(failure(StatusCode::CONFLICT,"principal_id_previously_used"));}
            p.revision+=1;
            tx.execute("INSERT INTO lineage_principals(id,document,revision) VALUES(?1,?2,?3) ON CONFLICT(id) DO UPDATE SET document=excluded.document,revision=excluded.revision",params![p.id,serde_json::to_string(&p).map_err(|_|failure(StatusCode::BAD_REQUEST,"invalid_policy"))?,p.revision]).map_err(db_error)?;
            tx.execute("INSERT INTO lineage_policy_changes(principal_id,revision,actor,changed_at) VALUES(?1,?2,?3,?4)",params![p.id,p.revision,actor,chrono::Utc::now().to_rfc3339()]).map_err(db_error)?;
            tx.commit().map_err(db_error)?;Ok(p)
        }).await
    }
    pub async fn delete(
        &self,
        id: String,
        revision: i64,
        actor: String,
    ) -> Result<Value, ApiError> {
        if id == "bootstrap" {
            return Err(failure(
                StatusCode::FORBIDDEN,
                "bootstrap_policy_is_deployment_managed",
            ));
        }
        self.call(move|conn|{
            let tx=conn.transaction().map_err(db_error)?;
            let current:Option<i64>=tx.query_row("SELECT revision FROM lineage_principals WHERE id=?1",[&id],|r|r.get(0)).optional().map_err(db_error)?;
            let current=current.ok_or_else(||failure(StatusCode::NOT_FOUND,"principal_not_found"))?;
            if current!=revision {return Err(failure(StatusCode::CONFLICT,"policy_revision_conflict"));}
            let token_count=tx.execute("DELETE FROM lineage_tokens WHERE principal_id=?1",[&id]).map_err(db_error)?;
            tx.execute("DELETE FROM lineage_principals WHERE id=?1",[&id]).map_err(db_error)?;
            tx.execute("INSERT INTO lineage_policy_changes(principal_id,revision,actor,changed_at) VALUES(?1,?2,?3,?4)",params![id,current+1,format!("delete:{actor}"),chrono::Utc::now().to_rfc3339()]).map_err(db_error)?;
            tx.commit().map_err(db_error)?;
            Ok(json!({"deleted":true,"principalId":id,"deletedTokenCount":token_count,"historyRetained":true}))
        }).await
    }
    pub async fn issue(&self, principal: String) -> Result<Value, ApiError> {
        let token_vault = self.token_vault.clone();
        self.call(move|conn|{
        if principal=="bootstrap"{return Err(failure(StatusCode::FORBIDDEN,"bootstrap_token_is_deployment_managed"));}
        let exists:bool=conn.query_row("SELECT EXISTS(SELECT 1 FROM lineage_principals WHERE id=?1)",[&principal],|r|r.get(0)).map_err(db_error)?;
        if !exists{return Err(failure(StatusCode::NOT_FOUND,"principal_not_found"));}
        let id=uuid::Uuid::new_v4().to_string();let raw=format!("fst_{}{}",uuid::Uuid::new_v4().simple(),uuid::Uuid::new_v4().simple());
        let encrypted=token_vault.encrypt(&id,&raw)?;
        conn.execute("INSERT INTO lineage_tokens(id,principal_id,digest,enabled,created_at,secret_ciphertext) VALUES(?1,?2,?3,1,?4,?5)",params![id,principal,digest(&raw),chrono::Utc::now().to_rfc3339(),encrypted]).map_err(db_error)?;
        Ok(json!({"tokenId":id,"token":raw,"principalId":principal}))
    }).await
    }
    pub async fn revoke(&self, id: String) -> Result<(), ApiError> {
        self.call(move |conn| {
            if id == "bootstrap" {
                return Err(failure(
                    StatusCode::FORBIDDEN,
                    "bootstrap_token_is_deployment_managed",
                ));
            }
            let n = conn
                .execute(
                    "UPDATE lineage_tokens SET enabled=0,secret_ciphertext=NULL WHERE id=?1",
                    [id],
                )
                .map_err(db_error)?;
            if n != 1 {
                return Err(failure(StatusCode::NOT_FOUND, "token_not_found"));
            }
            Ok(())
        })
        .await
    }
    pub async fn recheck(&self, e: &StorageEvent) -> Result<bool, ApiError> {
        let e = e.clone();
        self.call(move|conn|{
        let row:Option<String>=conn.query_row("SELECT p.document FROM lineage_tokens t JOIN lineage_principals p ON p.id=t.principal_id WHERE t.id=?1 AND t.principal_id=?2 AND t.enabled=1",params![e.token_id,e.principal_id],|r|r.get(0)).optional().map_err(db_error)?;
        let Some(doc)=row else{return Ok(false);};let p:Principal=serde_json::from_str(&doc).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"invalid_stored_policy"))?;
        Ok(p.choose(Some(e.action)).is_ok())
    }).await
    }
    pub async fn record_audits(
        &self,
        entries: Vec<AuditEntry>,
        principal: Option<String>,
    ) -> Result<(), ApiError> {
        self.call(move |conn| {
            let tx = conn.transaction().map_err(db_error)?;
            for entry in entries {
                insert_entry(&tx, &entry).map_err(db_error)?;
                let id = tx.last_insert_rowid();
                tx.execute(
                    "UPDATE audit_log SET principal_id=?1 WHERE id=?2",
                    params![principal, id],
                )
                .map_err(db_error)?;
            }
            tx.commit().map_err(db_error)?;
            Ok(())
        })
        .await
    }
    pub async fn audit_access(&self, id: i64, caller: Caller) -> Result<(), ApiError> {
        self.call(move |conn| {
            let owner: Option<Option<String>> = conn
                .query_row(
                    "SELECT principal_id FROM audit_log WHERE id=?1",
                    [id],
                    |r| r.get(0),
                )
                .optional()
                .map_err(db_error)?;
            let owner =
                owner.ok_or_else(|| failure(StatusCode::NOT_FOUND, "audit_record_not_found"))?;
            if caller.principal.kind != "admin"
                && owner.as_deref() != Some(caller.principal.id.as_str())
            {
                return Err(failure(StatusCode::FORBIDDEN, "audit_access_denied"));
            }
            Ok(())
        })
        .await
    }
    pub async fn decorate_audits(&self, records: &mut Vec<Value>) -> Result<(), ApiError> {
        let mut pending = std::mem::take(records);
        *records = self
            .call(move |conn| {
                decorate_audit_rows(conn, &mut pending)?;
                Ok(pending)
            })
            .await?;
        Ok(())
    }

    pub async fn enqueue(
        &self,
        e: StorageEvent,
        entries: Vec<AuditEntry>,
    ) -> Result<bool, ApiError> {
        self.call(move|conn|{
        let tx=conn.transaction().map_err(db_error)?;
        let existing:Option<String>=tx.query_row("SELECT content_hash FROM lineage_events WHERE id=?1",[&e.event_id],|r|r.get(0)).optional().map_err(db_error)?;
        if let Some(hash)=existing {if hash!=e.content_hash(){return Err(failure(StatusCode::CONFLICT,"idempotency_key_conflict"));}return Ok(false);}
        tx.execute("INSERT INTO lineage_events(id,principal_id,token_id,action,body,content_hash,status,created_at) VALUES(?1,?2,?3,?4,?5,?6,'queued',?7)",params![e.event_id,e.principal_id,e.token_id,e.action.as_str(),serde_json::to_string(&e).map_err(|_|failure(StatusCode::BAD_REQUEST,"invalid_event"))?,e.content_hash(),e.observed_at]).map_err(db_error)?;
        for entry in entries {insert_entry(&tx,&entry).map_err(db_error)?;let id=tx.last_insert_rowid();tx.execute("UPDATE audit_log SET principal_id=?1,event_id=?2 WHERE id=?3",params![e.principal_id,e.event_id,id]).map_err(db_error)?;}
        tx.commit().map_err(db_error)?;Ok(true)
    }).await
    }
    pub async fn next(&self) -> Result<Option<StorageEvent>, ApiError> {
        self.call(|conn|{
        let body:Option<String>=conn.query_row("SELECT body FROM lineage_events WHERE status='queued' AND next_attempt<=?1 ORDER BY created_at,id LIMIT 1",[chrono::Utc::now().timestamp_millis()],|r|r.get(0)).optional().map_err(db_error)?;
        body.map(|b|serde_json::from_str(&b).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"invalid_queued_event"))).transpose()
    }).await
    }
    pub async fn finish(
        &self,
        id: String,
        status: &str,
        outcome: Option<Value>,
        reason: Option<String>,
    ) -> Result<(), ApiError> {
        let status = status.to_string();
        self.call(move |conn| {
            conn.execute(
                "UPDATE lineage_events SET status=?1,outcome=?2,last_error=?3 WHERE id=?4",
                params![status, outcome.map(|v| v.to_string()), reason, id],
            )
            .map_err(db_error)?;
            Ok(())
        })
        .await
    }
    pub async fn retry(&self, id: String, reason: String) -> Result<(), ApiError> {
        self.call(move|conn|{
        conn.execute("UPDATE lineage_events SET attempts=attempts+1,next_attempt=?1+MIN(60000,1000*(1 << MIN(attempts,6))),last_error=?3 WHERE id=?2",params![chrono::Utc::now().timestamp_millis(),id,reason]).map_err(db_error)?;Ok(())
    }).await
    }
    pub async fn event(&self, id: String, caller: Caller) -> Result<Value, ApiError> {
        self.call(move|conn|{
        let row:Option<StoredEventRow>=conn.query_row("SELECT principal_id,action,status,attempts,outcome,last_error,body FROM lineage_events WHERE id=?1",[&id],|r|Ok((r.get(0)?,r.get(1)?,r.get(2)?,r.get(3)?,r.get(4)?,r.get(5)?,r.get(6)?))).optional().map_err(db_error)?;
        let (principal,action,status,attempts,outcome,reason,body)=row.ok_or_else(||failure(StatusCode::NOT_FOUND,"event_not_found"))?;
        if caller.principal.kind!="admin"&&caller.principal.id!=principal{return Err(failure(StatusCode::FORBIDDEN,"event_access_denied"));}
        let event:StorageEvent=serde_json::from_str(&body).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"event_invalid"))?;
        let mut result=json!({"eventId":id,"principalId":principal,"action":action,"status":status,"attempts":attempts,"reason":reason,"parseStatus":if event.analysis.summary.has_errors{"failed"}else{"succeeded"},"policyRevision":event.policy_revision,"lineageStatus":if event.action==Action::Publish{status.as_str()}else{"not_requested"},"usageStatus":if event.action==Action::RecordUsage{status.as_str()}else{"not_requested"}});
        if let Some(o)=outcome{let o:Value=serde_json::from_str(&o).map_err(|_|failure(StatusCode::INTERNAL_SERVER_ERROR,"outcome_invalid"))?;for key in ["lineageStatus","usageStatus","reason"]{result[key]=o[key].clone();}}
        Ok(result)
    }).await
    }
}

/// Decorate rows using the caller's SQLite read snapshot.
/// Kept synchronous so filtered list counts, page rows and displayed states agree.
pub(super) fn decorate_audit_rows(
    conn: &Connection,
    records: &mut [Value],
) -> Result<(), ApiError> {
    let ids: Vec<i64> = records
        .iter()
        .filter_map(|record| record["id"].as_i64())
        .collect();
    if ids.is_empty() {
        return Ok(());
    }
    let placeholders = vec!["?"; ids.len()].join(",");
    // Read all metadata in one query; never fetch an event's large body here.
    let mut statement = conn
        .prepare(&format!(
            "SELECT a.id,a.principal_id,a.event_id,e.action,e.status,e.outcome,e.last_error
         FROM audit_log a LEFT JOIN lineage_events e ON e.id=a.event_id
         WHERE a.id IN ({placeholders})"
        ))
        .map_err(db_error)?;
    let mut rows = statement
        .query(rusqlite::params_from_iter(ids))
        .map_err(db_error)?;
    let mut metadata = std::collections::HashMap::new();
    while let Some(row) = rows.next().map_err(db_error)? {
        let id: i64 = row.get(0).map_err(db_error)?;
        let principal: Option<String> = row.get(1).map_err(db_error)?;
        let event: Option<String> = row.get(2).map_err(db_error)?;
        let action: Option<String> = row.get(3).map_err(db_error)?;
        let status: Option<String> = row.get(4).map_err(db_error)?;
        let outcome: Option<String> = row.get(5).map_err(db_error)?;
        let reason: Option<String> = row.get(6).map_err(db_error)?;
        let default_status = if principal.is_some() && event.is_none() {
            "not_requested"
        } else {
            "unknown"
        };
        let mut extra = json!({"principal_id":principal,"event_id":event,
            "lineage_status":default_status,"usage_status":default_status});
        if let Some(action) = action {
            extra["lineage_status"] = json!(if action == "publish" {
                status.as_deref()
            } else {
                Some("not_requested")
            });
            extra["usage_status"] = json!(if action == "record_usage" {
                status.as_deref()
            } else {
                Some("not_requested")
            });
            extra["policy_reason"] = json!(reason);
            if let Some(outcome) = outcome {
                if let Ok(outcome) = serde_json::from_str::<Value>(&outcome) {
                    for (key, field) in [
                        ("lineageStatus", "lineage_status"),
                        ("usageStatus", "usage_status"),
                        ("reason", "policy_reason"),
                    ] {
                        extra[field] = outcome[key].clone();
                    }
                }
            }
        }
        metadata.insert(id, extra);
    }
    for record in records {
        if let Some(extra) = record["id"].as_i64().and_then(|id| metadata.get(&id)) {
            for (key, value) in extra.as_object().expect("audit metadata object") {
                record[key] = value.clone();
            }
        }
    }
    Ok(())
}

fn db_error(_: rusqlite::Error) -> ApiError {
    failure(
        StatusCode::INTERNAL_SERVER_ERROR,
        "lineage_state_database_error",
    )
}

/// One-time conversion of stored policies to token-only authorization. Removed
/// scope fields do not survive in documents or continue restricting callers.
fn migrate_token_policies(conn: &mut Connection) -> anyhow::Result<()> {
    let tx = conn.transaction()?;
    let rows = {
        let mut statement = tx
            .prepare("SELECT id,document,revision FROM lineage_principals WHERE id!='bootstrap'")?;
        let rows = statement.query_map([], |r| {
            Ok((
                r.get::<_, String>(0)?,
                r.get::<_, String>(1)?,
                r.get::<_, i64>(2)?,
            ))
        })?;
        rows.collect::<Result<Vec<_>, _>>()?
    };
    for (id, document, revision) in rows {
        let mut document: Value = serde_json::from_str(&document)?;
        let object = document
            .as_object_mut()
            .ok_or_else(|| anyhow::anyhow!("stored principal is not an object"))?;
        let mut changed = false;
        for key in ["environments", "sources", "deniedSources", "tables"] {
            changed |= object.remove(key).is_some();
        }
        if !changed {
            continue;
        }
        object.insert("revision".into(), json!(revision + 1));
        let principal: Principal = serde_json::from_value(document)?;
        principal
            .validate()
            .map_err(|(_, code)| anyhow::anyhow!(code))?;
        anyhow::ensure!(
            principal.id == id,
            "stored principal identity differs from its key"
        );
        tx.execute(
            "UPDATE lineage_principals SET document=?1,revision=?2 WHERE id=?3",
            params![serde_json::to_string(&principal)?, principal.revision, id],
        )?;
        tx.execute("INSERT INTO lineage_policy_changes(principal_id,revision,actor,changed_at) VALUES(?1,?2,'system:token_policy_migration',?3)",params![id,principal.revision,chrono::Utc::now().to_rfc3339()])?;
    }
    tx.commit()?;
    Ok(())
}
