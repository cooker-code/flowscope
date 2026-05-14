# Audit API — Executable Contracts

> Code-spec for `crates/flowscope-cli/src/server/audit.rs` and the audit endpoints in `api.rs`.
> Covers SQLite schema, field semantics, API contracts, and known gotchas.

---

## 1. Scope / Trigger

This spec applies whenever:
- Modifying the audit SQLite schema
- Adding or changing audit query endpoints
- Changing how `AuditEntry` fields are extracted from `AnalyzeResult`
- Changing `stmt_count`, `table_count`, `sql_type`, `has_cte`, `has_union` logic

---

## 2. SQLite Schema (Current — v2)

```sql
CREATE TABLE IF NOT EXISTS audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ts               TEXT    NOT NULL,               -- ISO 8601 UTC millis e.g. "2026-05-13T10:00:00.123Z"
    client_ip        TEXT    NOT NULL,
    endpoint         TEXT    NOT NULL,               -- "/api/analyze" | "/api/lint-fix" | "/api/split" | "/api/export/:format"
    dialect          TEXT    NOT NULL,               -- "Generic" | "Hive" | "Postgres" etc.
    file_name        TEXT,                           -- files[] mode: source file name; inline SQL: NULL
    sql_text         TEXT    NOT NULL,               -- full original SQL — NEVER truncated
    sql_hash         TEXT    NOT NULL,               -- SHA-256(sql_text) hex, for dedup lookups
    sql_len          INTEGER NOT NULL,               -- byte length of sql_text
    has_cte          INTEGER NOT NULL DEFAULT 0,     -- 1 = SQL contains WITH clause (NodeType::Cte present)
    has_union        INTEGER NOT NULL DEFAULT 0,     -- 1 = SQL contains UNION/INTERSECT/EXCEPT
    success          INTEGER NOT NULL,               -- 1 = no errors, 0 = has_errors in AnalyzeResult
    duration_ms      INTEGER NOT NULL,               -- end-to-end handler latency in ms
    stmt_count       INTEGER,                        -- meaningful statements only (SET/USE/RESET excluded)
    table_count      INTEGER,                        -- physical tables and views only (CTE nodes excluded)
    sql_type         TEXT,                           -- primary statement type: INSERT | SELECT | WITH | CREATE ...
    result_json      TEXT,                           -- full AnalyzeResult JSON; truncated to 1 MiB if oversized
    result_truncated INTEGER NOT NULL DEFAULT 0,     -- 1 = result_json was truncated
    error_msg        TEXT                            -- error summary on failure; NULL on success
);

CREATE INDEX IF NOT EXISTS idx_audit_ts        ON audit_log(ts);
CREATE INDEX IF NOT EXISTS idx_audit_endpoint  ON audit_log(endpoint);
CREATE INDEX IF NOT EXISTS idx_audit_sql_hash  ON audit_log(sql_hash);
CREATE INDEX IF NOT EXISTS idx_audit_has_cte   ON audit_log(has_cte);
CREATE INDEX IF NOT EXISTS idx_audit_sql_type  ON audit_log(sql_type);
```

### Migration: adding new columns

New optional columns are added with `ALTER TABLE ... ADD COLUMN`. The migration runs at startup and ignores "duplicate column" errors (idempotent):

```rust
const MIGRATE_SQL_TYPE: &str = "ALTER TABLE audit_log ADD COLUMN sql_type TEXT";

if let Err(e) = conn.execute_batch(MIGRATE_SQL_TYPE) {
    if !e.to_string().contains("duplicate column") {
        return Err(...);
    }
}
```

---

## 3. Field Semantics (Critical)

### `stmt_count` — meaningful statements only

**Excludes** `SET`, `USE`, `RESET` statements (Hive/Spark engine config directives).

```rust
const CONFIG_STMT_TYPES: &[&str] = &["SET", "USE", "RESET"];

let meaningful: Vec<_> = result.statements.iter()
    .filter(|s| !CONFIG_STMT_TYPES.iter()
        .any(|t| s.statement_type.eq_ignore_ascii_case(t)))
    .collect();
let stmt_count = meaningful.len();
```

**Why**: Real-world Hive/Spark SQL files start with 4–8 `SET` lines. Without filtering, `stmt_count=5` for a file with one real query is misleading.

### `table_count` — physical tables only

**Excludes** CTE nodes (`NodeType::Cte`). Counts only `NodeType::Table | NodeType::View`.

```rust
let table_count = result.nodes.iter()
    .filter(|n| matches!(n.node_type, NodeType::Table | NodeType::View))
    .count();
```

**Why**: `AnalyzeResult.summary.table_count` includes CTEs. A query with 8 physical tables and 9 CTEs would show `17` — not useful for understanding data dependencies. The audit field should answer "how many real tables does this touch?"

### `sql_type` — primary statement type

The type of the **first meaningful** statement (after filtering SET/USE/RESET):

```rust
let sql_type = meaningful.first().map(|s| s.statement_type.clone());
// Examples: "INSERT", "SELECT", "WITH", "CREATE"
```

**Note**: `WITH` (not `INSERT`) is returned when a CTE-prefixed query appears before `INSERT OVERWRITE`. This is correct — the outer statement IS a WITH block.

### `has_cte` — WITH clause detection

```rust
let has_cte = result.nodes.iter().any(|n| n.node_type == NodeType::Cte);
```

**CTE vs subquery distinction**:
- CTE = `WITH name AS (...)` — named, reusable, appears at top of query → `has_cte = true`
- Subquery = anonymous `FROM (SELECT ...) t` — inline, single-use → does NOT set `has_cte`

### `has_union` — dual detection strategy

```rust
// Method 1: edge operation labels (covers table lineage UNIONs)
let has_union_edge = result.edges.iter().any(|e| {
    e.operation.as_deref()
        .map(|s| s.to_ascii_uppercase().contains("UNION"))
        .unwrap_or(false)
});

// Method 2: SQL text scan (catches literal-only UNIONs like SELECT 1 UNION SELECT 2)
let has_union_text = {
    let upper = sql_text.to_ascii_uppercase();
    upper.contains("UNION") || upper.contains("INTERSECT") || upper.contains("EXCEPT")
};

let has_union = has_union_edge || has_union_text;
```

### `sql_text` — never truncate

**Always store the full SQL text.** There is no truncation on `sql_text`.

`sql_len` records the byte count for statistics without reading the full text. `sql_hash` enables dedup queries without full-text scan.

### `result_json` — 1 MiB truncation

Truncated to 1,048,576 bytes if oversized. `result_truncated = 1` is set when truncation occurs. This is acceptable because summary fields (`stmt_count`, `table_count`, etc.) already capture the key analytics.

---

## 4. API Contracts

### `GET /api/audit` — list (no large fields)

**Response omits `sql_text` and `result_json`** to keep list responses small and browser-viewable.

```
GET /api/audit?limit=50&offset=0&from=2026-05-01T00:00:00.000Z&to=2026-05-31T23:59:59.999Z&endpoint=/api/analyze&sql_type=INSERT&success=true&file_name=orders&keyword=MERGE
```

| Param | Type | Default | Max | Notes |
|-------|------|---------|-----|-------|
| `limit` | int | 50 | 500 | clamped |
| `offset` | int | 0 | — | |
| `from` | ISO 8601 | — | — | filters `ts >= from` |
| `to` | ISO 8601 | — | — | filters `ts <= to` |
| `endpoint` | string | — | — | exact match on endpoint field |
| `sql_type` | string | — | — | exact match on `sql_type` column |
| `success` | bool | — | — | `true` / `false` query param |
| `file_name` | string | — | — | substring match: `file_name LIKE %value%` |
| `keyword` | string | — | — | case-insensitive substring on `sql_text` (list rows still omit `sql_text` in JSON) |

Response:
```json
{
  "total": 120,
  "records": [
    {
      "id": 10, "ts": "...", "client_ip": "127.0.0.1",
      "endpoint": "/api/analyze", "dialect": "Hive",
      "file_name": "orders.sql", "sql_hash": "...", "sql_len": 4885,
      "has_cte": true, "has_union": false, "success": true,
      "duration_ms": 5, "stmt_count": 1, "table_count": 3,
      "sql_type": "INSERT", "result_truncated": false, "error_msg": null
    }
  ]
}
```

### `GET /api/audit/:id` — detail (full fields)

Returns the complete record including `sql_text` and `result_json`.

```
GET /api/audit/10
```

Response: same shape as list record, plus:
- `sql_text`: full original SQL
- `result_json`: parsed `AnalyzeResult` as embedded JSON object (not string)

Returns `404` if id not found. Returns error if audit logging is not enabled.

### Audit is disabled when `--audit-log` is not passed

When `AppState.audit = None`, list returns `{ total: 0, records: [] }`. Detail returns 404 with "Audit logging is not enabled".

### `GET /api/config` — `audit_storage`

When serve mode returns configuration JSON, it includes:

```json
"audit_storage": {
  "type": "sqlite",
  "location": "/path/to/audit.db",
  "enabled": true
}
```

- `enabled`: `true` only when `--audit-log` is set **and** the audit writer initialized.
- `type`: storage backend label (`sqlite` today; reserved for future backends).
- `location`: absolute path to the SQLite audit file, or `null` when disabled.

---

## 5. files[] Mode — Multiple Records Per Request

`POST /api/analyze` supports a `files` array. **Each FileSource produces one audit record.**

```json
{ "sql": "", "files": [
  { "name": "orders.sql", "content": "SELECT ..." },
  { "name": "users.sql",  "content": "SELECT ..." }
]}
```

→ Two audit records written, each with:
- `file_name`: the respective file name
- `sql_text`: that file's content
- `sql_hash`: SHA-256 of that file's content
- Shared: `has_cte`, `has_union`, `stmt_count`, `table_count`, `sql_type`, `result_json` — all from the combined `AnalyzeResult`

**Why shared result**: The engine analyzes all files together as one cross-file lineage graph. Individual per-file results do not exist.

---

## 6. Validation & Error Matrix

| Condition | Behavior |
|-----------|----------|
| Audit write fails (SQLite error) | Log to stderr, continue — main response unaffected |
| `result_json` serialization fails | `result_json = null`, `result_truncated = false`, log stderr |
| Channel closed (writer dropped) | Log stderr, entry dropped silently |
| `--audit-log` not specified | `AppState.audit = None`, no SQLite file created |
| New column migration "duplicate column" | Silently ignored (idempotent) |
| `GET /api/audit/:id` — id not found | HTTP 404 |

---

## 7. Wrong vs Correct

### Wrong: truncating sql_text

```rust
// WRONG — destroys audit value
if sql.len() > 65536 {
    sql_text = format!("{}...[truncated]", &sql[..65536]);
}
```

### Correct: store full text, record length separately

```rust
// CORRECT
sql_text: full_sql.clone(),   // never truncated
sql_len: full_sql.len(),      // for statistics without reading text
sql_hash: sha256_hex(&full_sql), // for dedup without full-text scan
```

---

### Wrong: using summary.table_count

```rust
// WRONG — includes CTE nodes, inflates count
let table_count = result.summary.table_count; // = physical + CTE
```

### Correct: count only physical nodes

```rust
// CORRECT
let table_count = result.nodes.iter()
    .filter(|n| matches!(n.node_type, NodeType::Table | NodeType::View))
    .count();
```

---

### Wrong: including result_json in list query

```rust
// WRONG — SELECT * returns sql_text + result_json; 2 records can be 200MB+
"SELECT * FROM audit_log ORDER BY ts DESC LIMIT ?1"
```

### Correct: list omits large fields

```rust
// CORRECT — list query
"SELECT id, ts, client_ip, endpoint, dialect, file_name, sql_hash, sql_len,
 has_cte, has_union, success, duration_ms, stmt_count, table_count, sql_type,
 result_truncated, error_msg FROM audit_log ..."

// Detail query (GET /api/audit/:id)
"SELECT id, ts, ..., sql_text, ..., result_json, ... FROM audit_log WHERE id = ?1"
```

---

## 8. New Field Checklist (防止重蹈覆辙)

When adding a new column to `audit_log`, answer all four questions before writing code:

| Question | Why it matters |
|----------|----------------|
| **Write scenario**: what value is stored and is it ever truncated? | Audit fields that ARE the audit value (like `sql_text`) must never be truncated |
| **List query scenario**: does this field belong in list responses? | Large TEXT fields (>1KB typical) must be omitted from list queries |
| **Detail query scenario**: does this field belong in detail responses? | Almost always yes |
| **Semantic accuracy**: if sourcing from `AnalyzeResult`, does the engine's field mean exactly what the audit field name implies? | `summary.table_count` includes CTEs; `summary.statement_count` includes SET — never pass-through without verifying semantics |

### Engine field semantic mapping

| `AnalyzeResult` field | Audit field | Why they differ |
|-----------------------|-------------|-----------------|
| `summary.statement_count` | `stmt_count` (filtered) | Engine counts SET/USE/RESET; audit wants business statements only |
| `summary.table_count` | `table_count` (filtered) | Engine counts table+CTE nodes; audit wants physical tables only |
| `nodes` with `NodeType::Cte` | `has_cte` | Direct — CTE = WITH clause, NOT subquery |
| `edges[].operation` + text scan | `has_union` | Dual detection needed: edge labels miss literal-only UNIONs |

---

## 9. Build Notes

The `serve` feature requires `rusqlite` (bundled) and `sha2`:

```toml
[features]
serve = ["dep:rusqlite", "dep:sha2", ...]

[dependencies]
rusqlite = { version = "0.32", features = ["bundled"], optional = true }
sha2 = { version = "0.10", optional = true }
```

`rusqlite` with `bundled` statically links SQLite (~30s extra compile time). This avoids system library version conflicts.
