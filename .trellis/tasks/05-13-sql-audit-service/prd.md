# SQL Audit Service — HTTP service with request audit logging

## Goal

将 FlowScope 作为一个带审计日志的 SQL 解析服务运行。用户可以向服务提交任意 SQL，服务执行解析分析后返回结果，同时将每次请求的输入 SQL、解析结果及元数据持久化记录，以便后续审计和追溯。

## Confirmed Facts (from codebase)

- FlowScope 已有完整的 HTTP 服务框架（`serve` feature），基于 axum + tokio。
- 现有 API 端点：
  - `POST /api/analyze` — 血缘分析（表/列级血缘图）
  - `POST /api/lint-fix` — Lint + 自动修复
  - `POST /api/split` — 语句拆分
  - `POST /api/completion` — SQL 代码补全
  - `POST /api/export/:format` — 导出（json/mermaid/html/csv/xlsx）
  - `GET /api/files`, `GET /api/schema`, `GET /api/config`, `GET /api/health`
- CORS 当前限制为同源（127.0.0.1 + localhost），阻止跨站请求。
- `AppState` 通过 `Arc<RwLock<>>` 共享，便于扩展新的全局状态。
- 核心引擎支持 14 种 SQL 方言（Generic/Postgres/Snowflake/BigQuery/Hive/DuckDB 等）。
- `flowscope-core` 完全纯内存处理，无 I/O，每次调用线程安全。

## Requirements

### 功能需求

1. **SQL 解析服务**：接收 HTTP POST 请求，内含待解析 SQL 文本，调用 `flowscope_core::analyze()` 后返回 JSON 格式的血缘/解析结果。
2. **审计日志**：每次收到解析请求时，将以下信息持久化记录：
   - 请求时间戳（ISO 8601）
   - 客户端来源（IP 地址）
   - 输入 SQL 文本
   - 使用的 SQL 方言
   - 解析是否成功
   - 响应耗时（毫秒）
   - （可选）解析结果摘要（涉及表数、语句数等）
3. **审计查询 API**（可选 MVP scope）：`GET /api/audit` 支持分页、按时间范围过滤，返回历史审计记录。
4. **服务启动**：在现有 `--serve` 模式基础上增加 `--audit-log` 参数开启审计，或始终开启（取决于讨论结果）。

### 非功能需求

- 审计写入不得阻塞 SQL 解析响应（异步写入）。
- 服务应支持多并发请求。
- 审计存储应在重启后保留数据。

## Acceptance Criteria

- [ ] `POST /api/analyze` 处理请求时，审计记录被写入持久化存储。
- [ ] 审计记录包含：时间戳、来源 IP、SQL 文本、方言、成功/失败、耗时。
- [ ] 审计写入失败不影响主响应返回（降级处理）。
- [ ] 服务重启后历史审计记录仍可访问。
- [ ] 现有所有 API 端点功能不受影响（无回归）。

## Out of Scope

- 用户认证与鉴权（不在本次范围）。
- 审计日志加密（可后续迭代）。
- 分布式多节点审计聚合。

## Decisions

- **审计存储**：SQLite（单文件嵌入式，`rusqlite` 或 `sqlx + sqlite`）
- **审计端点范围**：仅含 SQL 输入的端点：`/api/analyze`、`/api/lint-fix`、`/api/export/:format`、`/api/split`
- **网络绑定**：可配置，新增 `--host` 参数（默认 `127.0.0.1`，`0.0.0.0` 时同步开放 CORS）

## Open Questions

1. **审计功能激活方式**：始终开启，还是需要 CLI 参数 `--audit-log <path>` 显式指定？
