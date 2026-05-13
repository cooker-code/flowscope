# Design: SQL Audit Service

## Architecture Overview

在现有 `flowscope-cli` serve 模式之上叠加两个正交扩展：

1. **AuditWriter**：可选的后台审计写入器，持有 SQLite 连接，通过 `tokio::sync::mpsc` channel 异步接收审计条目写入，完全不阻塞请求处理。
2. **`--host` / CORS 扩展**：`ServerConfig` 增加 `host` 字段，运行时动态决定 CORS 策略。

```
HTTP Request
    │
    ▼
axum Handler (analyze / lint-fix / split / export)
    │── 调用 flowscope_core::analyze()
    │── 构造 AuditEntry
    │── audit_tx.send(entry)  ← fire-and-forget，不等待
    │
    ▼
正常 JSON 响应

background task (AuditWriter)
    └── recv AuditEntry → INSERT INTO audit_log (rusqlite, spawn_blocking)
```

## Module Changes

### `crates/flowscope-cli/Cargo.toml`

```toml
[features]
serve = [
    ...,
    "dep:rusqlite",   # 新增
]

[dependencies]
rusqlite = { version = "0.32", features = ["bundled"], optional = true }  # 新增
sha2 = { version = "0.10", optional = true }                               # 新增（SHA-256）
```

> `rusqlite` 已在 `dev-dependencies = "0.32"`，版本保持一致即可。`sha2` 无其他依赖，体积极小。

### `crates/flowscope-cli/src/server/audit.rs`（新文件）

```rust
pub struct AuditEntry {
    pub ts: String,          // chrono::Utc::now().to_rfc3339_opts(SecondsFormat::Millis, true)
    pub client_ip: String,
    pub endpoint: String,
    pub dialect: String,
    pub file_name: Option<String>,
    pub sql_text: String,    // 完整原文，不截断
    pub sql_hash: String,    // SHA-256 hex
    pub sql_len: usize,
    pub has_cte: bool,
    pub has_union: bool,
    pub success: bool,
    pub duration_ms: u64,
    pub stmt_count: Option<usize>,
    pub table_count: Option<usize>,
    pub result_json: Option<String>,   // 超 1MB 时截断
    pub result_truncated: bool,
    pub error_msg: Option<String>,
}

pub struct AuditWriter {
    tx: tokio::sync::mpsc::UnboundedSender<AuditEntry>,
}

impl AuditWriter {
    pub fn new(db_path: PathBuf) -> Result<Self> {
        // 在 spawn_blocking 线程上打开 SQLite，建表，启动 background recv loop
    }
    pub fn record(&self, entry: AuditEntry) {
        // fire-and-forget，忽略 send 错误（channel 关闭时降级）
        let _ = self.tx.send(entry);
    }
}
```

背景 task 使用 `tokio::task::spawn_blocking` 包装 `rusqlite::Connection::execute`，避免阻塞 async executor。

**`has_cte` 提取**：`result.nodes.iter().any(|n| n.node_type == NodeType::Cte)`

**`has_union` 提取**：`result.edges.iter().any(|e| e.operation.as_deref().map(|s| s.to_ascii_uppercase().contains("UNION")).unwrap_or(false))`

**`result_json` 截断**：序列化后若 `> 1_048_576` 字节，截断到恰好 1 MB 并设 `result_truncated = true`。

### `crates/flowscope-cli/src/server/state.rs`

`ServerConfig` 新增字段：
```rust
pub audit_log_path: Option<PathBuf>,   // --audit-log
pub host: std::net::IpAddr,            // --host，默认 127.0.0.1
```

`AppState` 新增字段：
```rust
pub audit: Option<Arc<AuditWriter>>,
```

### `crates/flowscope-cli/src/cli.rs`

新增 CLI 参数（在 `serve` feature 块内）：
```rust
#[cfg(feature = "serve")]
#[arg(long, value_name = "PATH")]
pub audit_log: Option<PathBuf>,

#[cfg(feature = "serve")]
#[arg(long, default_value = "127.0.0.1")]
pub host: std::net::IpAddr,
```

### `crates/flowscope-cli/src/server/mod.rs`

`run_server` → 按 `config.host` 构造 `SocketAddr`：
```rust
let addr = SocketAddr::new(config.host, config.port);
```

`build_router` → CORS 策略按 host 动态选择：
```rust
let cors = if config.host == IpAddr::V4(Ipv4Addr::LOOPBACK) {
    // 现有同源限制
    CorsLayer::new().allow_origin([localhost, loopback])...
} else {
    // 外部访问：开放所有来源
    CorsLayer::permissive()
};
```

### `crates/flowscope-cli/src/server/api.rs`

四个端点（`analyze`、`lint_fix`、`split`、`export`）在返回前：
1. 计算 `duration_ms`（在 handler 开头 `let start = Instant::now()`）
2. 提取 `client_ip`（从 axum `ConnectInfo<SocketAddr>` extractor）
3. 构造 `AuditEntry`，调用 `state.audit.as_ref().map(|w| w.record(entry))`

新增 `GET /api/audit` handler：
```rust
async fn audit_records(
    State(state): State<Arc<AppState>>,
    Query(params): Query<AuditQueryParams>,
) -> ...
```

从 SQLite 查询，返回：
```json
{ "total": 120, "records": [...] }
```

## Data Flow: POST /api/analyze with files[]

```
Request { sql: "", files: [f1, f2, f3] }
    │
    ├── flowscope_core::analyze() on ALL files → result
    │
    ├── audit f1: { file_name: "f1.sql", sql_text: f1.content, ... }
    ├── audit f2: { file_name: "f2.sql", sql_text: f2.content, ... }
    └── audit f3: { file_name: "f3.sql", sql_text: f3.content, ... }
         ↑ 每条记录共享同一次分析的 duration_ms / result_json
```

> `stmt_count` / `table_count` / `has_cte` / `has_union` 来自 **整体** `AnalyzeResult`，每条文件记录写入相同值（因为是同一次分析）。

## SQLite Schema（最终版）

```sql
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
    result_json      TEXT,
    result_truncated INTEGER NOT NULL DEFAULT 0,
    error_msg        TEXT
);
CREATE INDEX IF NOT EXISTS idx_audit_ts       ON audit_log(ts);
CREATE INDEX IF NOT EXISTS idx_audit_endpoint ON audit_log(endpoint);
CREATE INDEX IF NOT EXISTS idx_audit_sql_hash ON audit_log(sql_hash);
CREATE INDEX IF NOT EXISTS idx_audit_has_cte  ON audit_log(has_cte);
```

## Compatibility & Rollback

- 所有修改在 `serve` feature 内，不影响 CLI/WASM/TypeScript 包。
- `--audit-log` 不指定时，`AppState.audit = None`，handler 中 `Option::map` 直接短路，零开销。
- 现有测试全部无需修改（test_state 不传 audit）。
- 回滚：仅需移除 `audit.rs`、撤销 `state.rs` / `api.rs` / `cli.rs` 的少量字段修改。
