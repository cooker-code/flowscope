# Database Guidelines

> Database patterns and conventions for `flowscope-cli`.

---

## Overview

`flowscope-cli` uses **SQLite via `rusqlite`** (bundled feature) for the optional audit log in serve mode. There is no application database for normal CLI operation — SQLite is only created when `--audit-log <path>` is passed.

---

## SQLite Usage Pattern

### Connection lifecycle

- One connection opened at `AuditWriter::new()` startup (synchronous, before any async tasks).
- Connection wrapped in `Arc<Mutex<rusqlite::Connection>>` and shared to a background tokio task.
- Background task receives entries via `mpsc::UnboundedSender<AuditEntry>` and writes via `spawn_blocking`.

```rust
// Pattern: async channel → spawn_blocking → rusqlite
tokio::spawn(async move {
    while let Some(entry) = rx.recv().await {
        let conn = Arc::clone(&conn);
        tokio::task::spawn_blocking(move || {
            let conn = conn.lock().expect("audit db mutex");
            conn.execute(INSERT_SQL, rusqlite::params![...])?;
            Ok::<_, rusqlite::Error>(())
        }).await??;
    }
});
```

**Why `spawn_blocking`**: `rusqlite` is synchronous. Calling it directly on an async executor stalls other tasks.

### Query connections

For read queries (`GET /api/audit`), open a **separate connection** per query inside `spawn_blocking`. Do not reuse the writer connection for reads.

```rust
pub fn query(db_path: &Path, ...) -> anyhow::Result<(i64, Vec<Value>)> {
    let conn = rusqlite::Connection::open(db_path)?;
    // ... query
}
```

---

## Schema Conventions

- Table names: `snake_case` (e.g., `audit_log`)
- Column names: `snake_case`
- Boolean columns: `INTEGER NOT NULL DEFAULT 0` — SQLite has no bool type; use `0`/`1`
- Timestamps: `TEXT NOT NULL` in ISO 8601 UTC with milliseconds: `"2026-05-13T10:00:00.123Z"`
- Optional columns: `TEXT` or `INTEGER` (nullable, no DEFAULT)

### Index naming

```
idx_<table>_<column>
-- e.g.:
idx_audit_ts
idx_audit_endpoint
idx_audit_sql_hash
```

---

## Migrations

New columns are added with `ALTER TABLE ... ADD COLUMN`. Migrations run at startup and must be **idempotent** — ignore "duplicate column" errors:

```rust
const MIGRATE_FOO: &str = "ALTER TABLE audit_log ADD COLUMN foo TEXT";

if let Err(e) = conn.execute_batch(MIGRATE_FOO) {
    if !e.to_string().contains("duplicate column") {
        return Err(anyhow::anyhow!("Migration failed: {e}"));
    }
    // Already applied — silently continue
}
```

**Never use `CREATE TABLE` for migrations** — always `ALTER TABLE ADD COLUMN`.

---

## Query Patterns

### Parameterized queries (mandatory)

Always use `rusqlite::params![]` — never interpolate values into SQL strings.

```rust
// CORRECT
conn.execute("INSERT INTO t (a, b) VALUES (?1, ?2)", rusqlite::params![a, b])?;

// WRONG — SQL injection risk
conn.execute(&format!("INSERT INTO t (a, b) VALUES ({}, {})", a, b), [])?;
```

### Raw bind for dynamic queries

For queries with variable WHERE clauses, use `raw_bind_parameter` + `raw_query`:

```rust
let mut stmt = conn.prepare(&dynamic_sql)?;
for (i, v) in params.iter().enumerate() {
    stmt.raw_bind_parameter(i + 1, v.as_str())?;
}
stmt.raw_bind_parameter(limit_idx, limit)?;
let mut rows = stmt.raw_query();
```

**Important**: `raw_bind_parameter` must be called BEFORE `raw_query()`. Calling it after triggers a borrow error.

---

## Common Mistakes

### Including large TEXT columns in list queries

`sql_text` and `result_json` can be megabytes each. **Never include them in list/paginated queries.**

```rust
// WRONG — 2 records can be 200MB+
"SELECT * FROM audit_log ORDER BY ts DESC LIMIT ?1"

// CORRECT — omit large fields from list; use detail endpoint for full data
"SELECT id, ts, ..., sql_hash, sql_len, ... FROM audit_log ORDER BY ts DESC LIMIT ?1"
```

See [audit-api-spec.md](./audit-api-spec.md) for the full field split between list and detail.

### Truncating sql_text

Do not truncate `sql_text`. Store it fully and use `sql_len` for statistics.  
Only `result_json` has a 1 MiB truncation limit. See [audit-api-spec.md](./audit-api-spec.md).

### Calling rusqlite on the async executor

`rusqlite` is blocking I/O. Always wrap in `spawn_blocking`:

```rust
// WRONG
let result = conn.execute(...)?; // blocks async thread

// CORRECT
tokio::task::spawn_blocking(move || conn.execute(...)).await??;
```
