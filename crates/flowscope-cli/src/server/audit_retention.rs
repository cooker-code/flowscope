//! Global audit retention. Maintenance uses its own short-lived connection.
use chrono::{DateTime, Datelike, SecondsFormat, Utc};
use rusqlite::Connection;
use serde::{Deserialize, Serialize};
use std::{path::Path, time::Duration};

pub const CLEANUP_BATCH_SIZE: usize = 200;

#[derive(Clone, Copy, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct AuditSettings {
    pub retention_days: u32,
}

impl AuditSettings {
    pub fn cutoff(self, now: DateTime<Utc>) -> anyhow::Result<String> {
        anyhow::ensure!(
            self.retention_days > 0,
            "retentionDays must be a positive integer"
        );
        let cutoff = now
            .checked_sub_signed(chrono::TimeDelta::days(i64::from(self.retention_days)))
            .filter(|date| date.year() >= 0)
            .ok_or_else(|| anyhow::anyhow!("retentionDays exceeds the supported date range"))?;
        Ok(cutoff.to_rfc3339_opts(SecondsFormat::Millis, true))
    }
}

pub fn initialize(conn: &Connection) -> anyhow::Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS audit_settings (
            id INTEGER PRIMARY KEY CHECK(id=1),
            retention_days INTEGER NOT NULL CHECK(retention_days>0)
        );
        INSERT OR IGNORE INTO audit_settings(id,retention_days) VALUES(1,7);",
    )?;
    Ok(())
}

fn settings(conn: &Connection) -> anyhow::Result<AuditSettings> {
    Ok(conn.query_row(
        "SELECT retention_days FROM audit_settings WHERE id=1",
        [],
        |row| {
            Ok(AuditSettings {
                retention_days: row.get(0)?,
            })
        },
    )?)
}

pub fn read(path: &Path) -> anyhow::Result<AuditSettings> {
    settings(&Connection::open(path)?)
}

pub fn save(path: &Path, value: AuditSettings) -> anyhow::Result<AuditSettings> {
    value.cutoff(Utc::now())?;
    let conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_secs(2))?;
    conn.execute(
        "UPDATE audit_settings SET retention_days=?1 WHERE id=1",
        [value.retention_days],
    )?;
    Ok(value)
}

/// Delete only expired audit rows. Durable events keep their idempotency/retry state.
pub fn cleanup_batch(path: &Path, now: DateTime<Utc>) -> anyhow::Result<usize> {
    let mut conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_millis(200))?;
    let tx = conn.transaction_with_behavior(rusqlite::TransactionBehavior::Immediate)?;
    let cutoff = settings(&tx)?.cutoff(now)?;
    let has_events: bool = tx.query_row(
        "SELECT EXISTS(SELECT 1 FROM sqlite_master WHERE type='table' AND name='lineage_events')",
        [],
        |row| row.get(0),
    )?;
    let pending_guard = if has_events {
        "AND NOT EXISTS (SELECT 1 FROM lineage_events e
                         WHERE e.id=audit_log.event_id AND e.status='queued')"
    } else {
        ""
    };
    let deleted = tx.execute(
        &format!(
            "DELETE FROM audit_log WHERE id IN (
            SELECT id FROM audit_log WHERE ts<?1 {pending_guard}
            ORDER BY ts LIMIT ?2
        )"
        ),
        rusqlite::params![cutoff, CLEANUP_BATCH_SIZE],
    )?;
    tx.commit()?;
    Ok(deleted)
}

/// Build new indexes after listening and cleanup, never during synchronous startup.
pub fn ensure_query_indexes(path: &Path) -> anyhow::Result<()> {
    let conn = Connection::open(path)?;
    conn.busy_timeout(Duration::from_millis(200))?;
    conn.execute_batch(
        "CREATE INDEX IF NOT EXISTS idx_audit_sql_type_ts ON audit_log(sql_type,ts);",
    )?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fixture() -> (tempfile::TempDir, std::path::PathBuf, Connection) {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("audit.db");
        let conn = Connection::open(&path).unwrap();
        conn.execute_batch("PRAGMA journal_mode=WAL;
            CREATE TABLE audit_log(id INTEGER PRIMARY KEY,ts TEXT NOT NULL,event_id TEXT,sql_type TEXT);
            CREATE INDEX idx_audit_ts ON audit_log(ts);").unwrap();
        initialize(&conn).unwrap();
        (dir, path, conn)
    }

    #[test]
    fn settings_default_persist_and_reject_invalid_values() {
        let (_dir, path, conn) = fixture();
        assert_eq!(read(&path).unwrap().retention_days, 7);
        save(&path, AuditSettings { retention_days: 14 }).unwrap();
        initialize(&conn).unwrap();
        assert_eq!(read(&path).unwrap().retention_days, 14);
        for retention_days in [0, u32::MAX] {
            assert!(save(&path, AuditSettings { retention_days }).is_err());
            assert_eq!(read(&path).unwrap().retention_days, 14);
        }
    }

    #[test]
    fn cleanup_respects_boundary_and_preserves_pending_events() {
        let (_dir, path, conn) = fixture();
        conn.execute_batch("CREATE TABLE lineage_events(id TEXT PRIMARY KEY,status TEXT,body TEXT);
            INSERT INTO lineage_events VALUES('pending','queued','keep queued body'),('done','committed','keep durable body');
            INSERT INTO audit_log(id,ts,event_id) VALUES
            (1,'2026-11-18T23:59:59.999Z',NULL),
            (2,'2026-11-19T00:00:00.000Z',NULL),
            (3,'2026-11-26T00:00:00.000Z',NULL),
            (4,'2026-11-18T00:00:00.000Z','pending'),
            (5,'2026-11-18T00:00:00.000Z','done');").unwrap();
        let now = "2026-11-26T00:00:00Z".parse().unwrap();
        assert_eq!(cleanup_batch(&path, now).unwrap(), 2);
        let ids = conn
            .prepare("SELECT id FROM audit_log ORDER BY id")
            .unwrap()
            .query_map([], |row| row.get::<_, i64>(0))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap();
        assert_eq!(ids, vec![2, 3, 4]);
        let bodies: String = conn
            .query_row(
                "SELECT group_concat(body,';') FROM lineage_events",
                [],
                |r| r.get(0),
            )
            .unwrap();
        assert_eq!(bodies, "keep queued body;keep durable body");
        conn.execute(
            "UPDATE lineage_events SET status='failed' WHERE id='pending'",
            [],
        )
        .unwrap();
        assert_eq!(cleanup_batch(&path, now).unwrap(), 1);
    }

    #[test]
    fn cleanup_is_bounded_and_retries_after_contention_without_event_tables() {
        let (_dir, path, conn) = fixture();
        conn.execute_batch(
            "WITH RECURSIVE n(i) AS (VALUES(1) UNION ALL SELECT i+1 FROM n WHERE i<201)
            INSERT INTO audit_log(id,ts) SELECT i,'2026-01-01T00:00:00.000Z' FROM n;",
        )
        .unwrap();
        let now = "2026-11-26T00:00:00Z".parse().unwrap();
        conn.execute_batch("BEGIN IMMEDIATE").unwrap();
        assert!(cleanup_batch(&path, now).is_err());
        conn.execute_batch("ROLLBACK").unwrap();
        assert_eq!(cleanup_batch(&path, now).unwrap(), CLEANUP_BATCH_SIZE);
        assert_eq!(cleanup_batch(&path, now).unwrap(), 1);
        assert_eq!(cleanup_batch(&path, now).unwrap(), 0);
    }

    #[test]
    fn type_time_index_eliminates_full_result_sort() {
        let (_dir, path, _) = fixture();
        ensure_query_indexes(&path).unwrap();
        let conn = Connection::open(&path).unwrap();
        let plan = conn
            .prepare(
                "EXPLAIN QUERY PLAN SELECT id,ts FROM audit_log
            WHERE sql_type='SELECT' AND ts>='2026-11-01' ORDER BY ts DESC LIMIT 50",
            )
            .unwrap()
            .query_map([], |row| row.get::<_, String>(3))
            .unwrap()
            .collect::<Result<Vec<_>, _>>()
            .unwrap()
            .join("\n");
        assert!(
            plan.contains("COVERING INDEX idx_audit_sql_type_ts"),
            "{plan}"
        );
        assert!(!plan.contains("TEMP B-TREE"), "{plan}");
    }
}
