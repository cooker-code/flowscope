# Implement: SQL Audit Service

## Pre-flight Checks

```bash
cargo build -p flowscope-cli --features serve    # 确认当前 serve 构建通过
cargo test -p flowscope-cli --features serve     # 确认现有测试全绿
```

## Implementation Checklist

### Step 1 — 依赖：Cargo.toml
- [ ] `crates/flowscope-cli/Cargo.toml`：
  - 将 `rusqlite = "0.32"` 从 `dev-dependencies` 移入 `[dependencies]`，设为 `optional = true`，加入 `serve` feature 列表
  - 新增 `sha2 = { version = "0.10", optional = true }`，加入 `serve` feature 列表

验证：`cargo build -p flowscope-cli --features serve` 编译通过

---

### Step 2 — CLI 参数：cli.rs
- [ ] `serve` feature 块内新增两个参数：
  - `--host <IP>`：`std::net::IpAddr`，default `"127.0.0.1"`
  - `--audit-log <PATH>`：`Option<PathBuf>`
- [ ] `main.rs` 中将新参数透传到 `ServerConfig`

验证：`cargo run -p flowscope-cli --features serve -- --serve --help` 显示两个新参数

---

### Step 3 — ServerConfig / AppState：state.rs
- [ ] `ServerConfig` 新增 `host: std::net::IpAddr`、`audit_log_path: Option<PathBuf>`
- [ ] `AppState` 新增 `audit: Option<Arc<AuditWriter>>`（`AuditWriter` 在 Step 4 定义）
- [ ] `AppState::new()` 中：若 `config.audit_log_path.is_some()` 则初始化 `AuditWriter`，否则 `None`

---

### Step 4 — 审计写入器：server/audit.rs（新文件）
- [ ] 定义 `AuditEntry` struct（全部字段见 design.md）
- [ ] 定义 `AuditWriter`：持有 `mpsc::UnboundedSender<AuditEntry>`
- [ ] `AuditWriter::new(db_path)` 实现：
  - `spawn_blocking` 打开 SQLite 连接
  - 执行 `CREATE TABLE IF NOT EXISTS` + 四个索引
  - 启动后台 `spawn` loop：`while let Some(entry) = rx.recv().await { spawn_blocking(|| conn.execute(...)) }`
- [ ] `AuditWriter::record(&self, entry)` 实现：`let _ = self.tx.send(entry)`（降级：失败只打印 stderr）
- [ ] 辅助函数 `fn extract_audit_flags(result: &AnalyzeResult) -> (bool, bool, usize, usize)`
  - `has_cte`: `result.nodes.iter().any(|n| n.node_type == NodeType::Cte)`
  - `has_union`: `result.edges.iter().any(|e| e.operation.as_deref().map(|s| s.to_ascii_uppercase().contains("UNION")).unwrap_or(false))`
  - `stmt_count`: `result.summary.statement_count`
  - `table_count`: `result.summary.table_count`
- [ ] 辅助函数 `fn truncate_result_json(result: &AnalyzeResult) -> (Option<String>, bool)`
  - 序列化后 > 1_048_576 字节时截断，`result_truncated = true`
- [ ] 辅助函数 `fn sha256_hex(s: &str) -> String`

---

### Step 5 — 网络绑定 + CORS：server/mod.rs
- [ ] `run_server()` 中 `SocketAddr::new(config.host, config.port)` 替换硬编码 `127.0.0.1`
- [ ] `build_router()` 中 CORS 策略按 host 分支：
  - `host == 127.0.0.1` 或 `::1`（loopback）：保持现有同源限制
  - 其他：`CorsLayer::permissive()`
- [ ] `build_router()` 参数改为接收 `ServerConfig`（或新增 `host: IpAddr`）

验证：`flowscope --serve --host 0.0.0.0 --port 3000` 启动后可从非 localhost 访问

---

### Step 6 — Handler 接入审计：server/api.rs
- [ ] 为四个 handler 添加 `ConnectInfo<SocketAddr>` extractor 获取 client IP
- [ ] 在 handler 入口处 `let start = std::time::Instant::now()`
- [ ] `analyze` handler：
  - inline sql 路径：分析后构造 1 条 `AuditEntry`，`file_name = None`
  - files 路径：每个 `FileSource` 构造 1 条 `AuditEntry`，`file_name = Some(f.name.clone())`
  - 调用 `state.audit.as_ref().map(|w| w.record(entry))`
- [ ] `lint_fix` handler：构造 1 条 AuditEntry（`stmt_count/table_count/has_cte/has_union = None/false`）
- [ ] `split` handler：构造 1 条 AuditEntry（`stmt_count = result.statements.len()`，其他 NULL/false）
- [ ] `export` handler：构造 1 条 AuditEntry（类似 analyze，但 result_json 可不存）
- [ ] Router 中添加 `ConnectInfo` 支持：在 `axum::serve()` 调用处加 `.into_make_service_with_connect_info::<SocketAddr>()`

---

### Step 7 — 审计查询 API：server/api.rs
- [ ] 新增 `AuditQueryParams` struct：`limit(50)`, `offset(0)`, `from`, `to`, `endpoint`
- [ ] 新增 `GET /api/audit` handler：从 `AppState` 取 `AuditWriter` → `spawn_blocking` 执行 SELECT
  - 若 `audit = None`，返回 `{"total":0,"records":[]}` 或 404（建议 200 空结果）
- [ ] `api_routes()` 注册 `.route("/audit", get(audit_records))`

---

### Step 8 — 测试
- [ ] `tests/serve_api.rs` 新增审计相关测试：
  - `audit_records_written_for_analyze`：analyze 后 SQLite 有 1 条记录
  - `audit_files_array_writes_multiple_records`：3 文件 → 3 条记录
  - `audit_has_cte_flag_set_for_cte_query`
  - `audit_has_union_flag_set`
  - `audit_query_api_returns_records`：GET /api/audit 返回正确分页
  - `audit_disabled_when_no_path`：不传 audit_log 路径时无 SQLite 写入
  - `audit_failure_does_not_affect_response`：写入失败（关闭 channel）主响应仍 200

---

## Validation Commands

```bash
# 编译
cargo build -p flowscope-cli --features serve

# 全量测试
cargo test -p flowscope-cli --features serve

# 手动验证
flowscope --serve --audit-log /tmp/test-audit.db --watch ./test-sql --port 3001 &
curl -s -X POST http://localhost:3001/api/analyze \
  -H 'Content-Type: application/json' \
  -d '{"sql":"WITH cte AS (SELECT 1) SELECT * FROM cte UNION SELECT 2"}' | jq .
curl -s http://localhost:3001/api/audit | jq '.records[0] | {has_cte, has_union, sql_len}'
# 期望: has_cte=1, has_union=1
```

## Risky Files / Rollback Points

| 文件 | 风险 | 回滚方式 |
|------|------|----------|
| `server/mod.rs` | CORS 策略改动可能影响现有 web UI | git revert 单文件 |
| `server/api.rs` | ConnectInfo extractor 需在 serve() 处配套修改 | 两处必须同步修改 |
| `Cargo.toml` | rusqlite bundled 增加编译时间（~30s） | 移回 dev-dependencies |

## Notes

- `rusqlite` 使用 `bundled` feature 静态链接 SQLite，避免系统库版本问题，代价是增加约 30 秒编译时间。
- background writer 使用 `UnboundedSender`，若写入积压过大会占用内存；对正常使用量（每秒数十请求）无问题。如需限流可改 `bounded(1024)`。
- `ConnectInfo` extractor 在反向代理后会拿到代理 IP；如需真实 IP，可后续加 `X-Forwarded-For` 解析。
