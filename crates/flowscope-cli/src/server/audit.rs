//! SQL audit logging for serve mode.
//!
//! Provides `AuditWriter` which accepts `AuditEntry` values via an unbounded
//! mpsc channel and persists them asynchronously to a SQLite database using
//! `spawn_blocking`, keeping the async executor unblocked.

use std::path::PathBuf;
use std::sync::Arc;

use flowscope_core::{AnalyzeResult, NodeType};
use sha2::{Digest, Sha256};
use tokio::sync::mpsc;

/// One row written to `audit_log`.
#[derive(Debug, Clone)]
pub struct AuditEntry {
    pub ts: String,
    pub client_ip: String,
    pub endpoint: String,
    pub dialect: String,
    pub file_name: Option<String>,
    pub sql_text: String,
    pub sql_hash: String,
    pub sql_len: usize,
    pub has_cte: bool,
    pub has_union: bool,
    pub success: bool,
    pub duration_ms: u64,
    /// Number of meaningful statements (SET/config lines excluded).
    pub stmt_count: Option<usize>,
    /// Number of physical tables only (CTE nodes excluded).
    pub table_count: Option<usize>,
    /// Primary statement type of the SQL: INSERT / SELECT / WITH / etc.
    pub sql_type: Option<String>,
    pub result_json: Option<String>,
    pub result_truncated: bool,
    pub error_msg: Option<String>,
}

const RESULT_JSON_MAX_BYTES: usize = 1_048_576; // 1 MiB

/// Statement types that carry no lineage value (engine config directives).
const CONFIG_STMT_TYPES: &[&str] = &["SET", "USE", "RESET"];

/// Returns (has_cte, has_union, stmt_count, table_count, sql_type) from an AnalyzeResult.
///
/// - `stmt_count`:  meaningful statements only — SET/USE/RESET are excluded.
/// - `table_count`: physical tables and views only — CTE nodes are excluded.
/// - `sql_type`:    primary statement type of the first meaningful statement
///                  (INSERT / SELECT / WITH / CREATE / …).
/// - `has_union`:   detected via edge operation labels AND SQL text scan.
pub fn extract_audit_flags(
    result: &AnalyzeResult,
    sql_text: &str,
) -> (bool, bool, usize, usize, Option<String>) {
    let has_cte = result.nodes.iter().any(|n| n.node_type == NodeType::Cte);

    let has_union_edge = result.edges.iter().any(|e| {
        e.operation
            .as_deref()
            .map(|s| s.to_ascii_uppercase().contains("UNION"))
            .unwrap_or(false)
    });
    let has_union_text = {
        let upper = sql_text.to_ascii_uppercase();
        upper.contains("UNION") || upper.contains("INTERSECT") || upper.contains("EXCEPT")
    };
    let has_union = has_union_edge || has_union_text;

    // Count only meaningful statements (skip SET / USE / RESET config lines)
    let meaningful: Vec<&flowscope_core::StatementMeta> = result
        .statements
        .iter()
        .filter(|s| {
            !CONFIG_STMT_TYPES
                .iter()
                .any(|t| s.statement_type.eq_ignore_ascii_case(t))
        })
        .collect();

    let stmt_count = meaningful.len();

    // Primary sql_type = first meaningful statement type
    let sql_type = meaningful.first().map(|s| s.statement_type.clone());

    // Physical tables and views only — CTE nodes are excluded
    let table_count = result
        .nodes
        .iter()
        .filter(|n| matches!(n.node_type, NodeType::Table | NodeType::View))
        .count();

    (has_cte, has_union, stmt_count, table_count, sql_type)
}

/// Serialize AnalyzeResult to JSON, truncating at 1 MiB if necessary.
/// Returns (json_string, was_truncated).
pub fn truncate_result_json(result: &AnalyzeResult) -> (Option<String>, bool) {
    match serde_json::to_string(result) {
        Ok(json) => {
            if json.len() > RESULT_JSON_MAX_BYTES {
                let truncated = json[..RESULT_JSON_MAX_BYTES].to_string();
                (Some(truncated), true)
            } else {
                (Some(json), false)
            }
        }
        Err(e) => {
            eprintln!("flowscope: audit: failed to serialize result JSON: {e}");
            (None, false)
        }
    }
}

/// Compute SHA-256 hex digest of a string.
pub fn sha256_hex(s: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(s.as_bytes());
    format!("{:x}", hasher.finalize())
}

const CREATE_TABLE_SQL: &str = r#"
CREATE TABLE IF NOT EXISTS audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ts               TEXT    NOT NULL,
    client_ip        TEXT    NOT NULL,
    endpoint         TEXT    NOT NULL,
    dialect          TEXT    NOT NULL,
    file_name        TEXT,
    sql_text         TEXT    NOT NULL,
    sql_hash         TEXT    NOT NULL,
    sql_len          INTEGER NOT NULL,
    has_cte          INTEGER NOT NULL DEFAULT 0,
    has_union        INTEGER NOT NULL DEFAULT 0,
    success          INTEGER NOT NULL,
    duration_ms      INTEGER NOT NULL,
    stmt_count       INTEGER,
    table_count      INTEGER,
    sql_type         TEXT,
    result_json      TEXT,
    result_truncated INTEGER NOT NULL DEFAULT 0,
    error_msg        TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_ts        ON audit_log(ts);
CREATE INDEX IF NOT EXISTS idx_audit_endpoint  ON audit_log(endpoint);
CREATE INDEX IF NOT EXISTS idx_audit_sql_hash  ON audit_log(sql_hash);
CREATE INDEX IF NOT EXISTS idx_audit_has_cte   ON audit_log(has_cte);
CREATE INDEX IF NOT EXISTS idx_audit_sql_type  ON audit_log(sql_type);
"#;

/// Migration: add sql_type column to existing databases that pre-date this field.
const MIGRATE_SQL_TYPE: &str =
    "ALTER TABLE audit_log ADD COLUMN sql_type TEXT";

const INSERT_SQL: &str = r#"
INSERT INTO audit_log (
    ts, client_ip, endpoint, dialect, file_name,
    sql_text, sql_hash, sql_len,
    has_cte, has_union, success, duration_ms,
    stmt_count, table_count, sql_type, result_json, result_truncated, error_msg
) VALUES (
    ?1, ?2, ?3, ?4, ?5,
    ?6, ?7, ?8,
    ?9, ?10, ?11, ?12,
    ?13, ?14, ?15, ?16, ?17, ?18
)
"#;

/// Asynchronous audit log writer backed by a SQLite database.
///
/// Entries are queued via an unbounded channel and written in a
/// dedicated `spawn_blocking` worker, so the async executor is never
/// blocked by SQLite I/O.
pub struct AuditWriter {
    tx: mpsc::UnboundedSender<AuditEntry>,
}

impl AuditWriter {
    /// Open (or create) the SQLite database at `db_path` and start the
    /// background writer task.  Returns `Err` only if the database cannot
    /// be opened or the schema cannot be initialised.
    ///
    /// This function is synchronous and can be called from any context
    /// (including single-threaded tokio runtimes used in tests).
    pub fn new(db_path: PathBuf) -> anyhow::Result<Self> {
        // Open and initialise the SQLite connection synchronously.
        // This runs before spawning any async tasks, so it works in both
        // single-threaded (test) and multi-threaded (production) runtimes.
        let conn = {
            let conn = rusqlite::Connection::open(&db_path).map_err(|e| {
                anyhow::anyhow!("Failed to open audit database {}: {}", db_path.display(), e)
            })?;
            conn.execute_batch(CREATE_TABLE_SQL).map_err(|e| {
                anyhow::anyhow!("Failed to initialise audit schema: {}", e)
            })?;
            // Migrate existing databases: ignore "duplicate column" error
            if let Err(e) = conn.execute_batch(MIGRATE_SQL_TYPE) {
                let msg = e.to_string();
                if !msg.contains("duplicate column") {
                    return Err(anyhow::anyhow!("Failed to migrate audit schema: {}", e));
                }
            }
            conn
        };

        let (tx, mut rx) = mpsc::unbounded_channel::<AuditEntry>();

        // Wrap the connection in a mutex so it can be moved into the async context.
        let conn = std::sync::Mutex::new(conn);
        let conn = Arc::new(conn);

        tokio::spawn(async move {
            while let Some(entry) = rx.recv().await {
                let conn = Arc::clone(&conn);
                let result = tokio::task::spawn_blocking(move || {
                    let conn = conn.lock().expect("audit db mutex");
                    conn.execute(
                        INSERT_SQL,
                        rusqlite::params![
                            entry.ts,
                            entry.client_ip,
                            entry.endpoint,
                            entry.dialect,
                            entry.file_name,
                            entry.sql_text,
                            entry.sql_hash,
                            entry.sql_len as i64,
                            entry.has_cte as i32,
                            entry.has_union as i32,
                            entry.success as i32,
                            entry.duration_ms as i64,
                            entry.stmt_count.map(|v| v as i64),
                            entry.table_count.map(|v| v as i64),
                            entry.sql_type,
                            entry.result_json,
                            entry.result_truncated as i32,
                            entry.error_msg,
                        ],
                    )
                })
                .await;

                match result {
                    Ok(Ok(_)) => {}
                    Ok(Err(e)) => eprintln!("flowscope: audit: write failed: {e}"),
                    Err(e) => eprintln!("flowscope: audit: task join error: {e}"),
                }
            }
        });

        Ok(Self { tx })
    }

    /// Queue an audit entry for writing. Fire-and-forget: errors are logged to
    /// stderr but never propagate to the caller.
    pub fn record(&self, entry: AuditEntry) {
        if let Err(e) = self.tx.send(entry) {
            eprintln!("flowscope: audit: channel closed, entry dropped: {e}");
        }
    }

    /// Query audit records from the database.
    ///
    /// This is a blocking operation that should be called from within
    /// `spawn_blocking`.  Returns rows as `serde_json::Value` arrays.
    pub fn query(
        db_path: &std::path::Path,
        limit: i64,
        offset: i64,
        from: Option<&str>,
        to: Option<&str>,
        endpoint_filter: Option<&str>,
    ) -> anyhow::Result<(i64, Vec<serde_json::Value>)> {
        let conn = rusqlite::Connection::open(db_path)?;

        // Collect dynamic filter conditions and their parameter values
        let mut cond_parts: Vec<&'static str> = Vec::new();
        let mut extra_params: Vec<String> = Vec::new();

        if let Some(f) = from {
            cond_parts.push("ts >= ?");
            extra_params.push(f.to_string());
        }
        if let Some(t) = to {
            cond_parts.push("ts <= ?");
            extra_params.push(t.to_string());
        }
        if let Some(ep) = endpoint_filter {
            cond_parts.push("endpoint = ?");
            extra_params.push(ep.to_string());
        }

        let where_clause = if cond_parts.is_empty() {
            String::new()
        } else {
            format!("WHERE {}", cond_parts.join(" AND "))
        };

        // Get total count using named params approach
        let count_sql = format!("SELECT COUNT(*) FROM audit_log {where_clause}");
        let total: i64 = {
            let mut stmt = conn.prepare(&count_sql)?;
            // Bind dynamic extra params positionally
            for (i, v) in extra_params.iter().enumerate() {
                stmt.raw_bind_parameter(i + 1, v.as_str())?;
            }
            let mut rows = stmt.raw_query();
            match rows.next()? {
                Some(row) => row.get(0)?,
                None => 0,
            }
        };

        // Build select with limit/offset at end (after extra params)
        let extra_count = extra_params.len();
        let limit_idx = extra_count + 1;
        let offset_idx = extra_count + 2;
        let select_sql = format!(
            "SELECT id, ts, client_ip, endpoint, dialect, file_name, sql_text, sql_hash, sql_len, \
             has_cte, has_union, success, duration_ms, stmt_count, table_count, sql_type, \
             result_json, result_truncated, error_msg \
             FROM audit_log {where_clause} ORDER BY ts DESC LIMIT ?{limit_idx} OFFSET ?{offset_idx}"
        );

        let mut stmt = conn.prepare(&select_sql)?;
        for (i, v) in extra_params.iter().enumerate() {
            stmt.raw_bind_parameter(i + 1, v.as_str())?;
        }
        stmt.raw_bind_parameter(limit_idx, limit)?;
        stmt.raw_bind_parameter(offset_idx, offset)?;

        let mut rows = stmt.raw_query();
        let mut records = Vec::new();
        while let Some(row) = rows.next()? {
            let id: i64 = row.get(0)?;
            let ts: String = row.get(1)?;
            let client_ip: String = row.get(2)?;
            let endpoint: String = row.get(3)?;
            let dialect: String = row.get(4)?;
            let file_name: Option<String> = row.get(5)?;
            let sql_text: String = row.get(6)?;
            let sql_hash: String = row.get(7)?;
            let sql_len: i64 = row.get(8)?;
            let has_cte: i32 = row.get(9)?;
            let has_union: i32 = row.get(10)?;
            let success: i32 = row.get(11)?;
            let duration_ms: i64 = row.get(12)?;
            let stmt_count: Option<i64> = row.get(13)?;
            let table_count: Option<i64> = row.get(14)?;
            let sql_type: Option<String> = row.get(15)?;
            let result_json_raw: Option<String> = row.get(16)?;
            let result_truncated: i32 = row.get(17)?;
            let error_msg: Option<String> = row.get(18)?;

            // Parse result_json string back to Value so it embeds as JSON, not escaped string
            let result_json = result_json_raw
                .as_deref()
                .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok());

            records.push(serde_json::json!({
                "id": id,
                "ts": ts,
                "client_ip": client_ip,
                "endpoint": endpoint,
                "dialect": dialect,
                "file_name": file_name,
                "sql_text": sql_text,
                "sql_hash": sql_hash,
                "sql_len": sql_len,
                "has_cte": has_cte != 0,
                "has_union": has_union != 0,
                "success": success != 0,
                "duration_ms": duration_ms,
                "stmt_count": stmt_count,
                "table_count": table_count,
                "sql_type": sql_type,
                "result_json": result_json,
                "result_truncated": result_truncated != 0,
                "error_msg": error_msg,
            }));
        }

        Ok((total, records))
    }
}
