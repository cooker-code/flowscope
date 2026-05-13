# SQL Audit Service — HTTP service with request audit logging

## Goal

将 FlowScope 作为一个带审计日志的 SQL 解析服务运行。用户可以向服务提交任意 SQL，服务执行解析分析后返回结果，同时将每次请求的输入 SQL、解析结果及元数据持久化记录到 SQLite，以便后续审计和追溯。

## Confirmed Facts (from codebase)

- FlowScope 已有完整的 HTTP 服务框架（`serve` feature），基于 axum + tokio，位于 `crates/flowscope-cli/src/server/`。
- 现有 API 端点中，含 SQL 输入的端点：`POST /api/analyze`、`POST /api/lint-fix`、`POST /api/split`、`POST /api/export/:format`。
- `AppState` 通过 `Arc<RwLock<>>` 共享，便于扩展新的全局状态（如审计写入器）。
- `ServerConfig` 目前硬编码绑定 `127.0.0.1`，CORS 限制为同源。
- `flowscope_core::analyze()` 返回 `AnalyzeResult`，含语句列表、血缘图节点/边，可提取 `stmt_count`、`table_count`、`has_cte`、`has_union`。
- `/api/analyze` 请求体支持 `sql` 字段（inline）和 `files` 数组（多文件批量），需分开记录。

## Decisions

| 决策 | 结论 |
|------|------|
| 审计存储 | SQLite（`rusqlite`），单文件嵌入式 |
| 审计端点范围 | `/api/analyze`、`/api/lint-fix`、`/api/split`、`/api/export/:format` |
| 网络绑定 | 新增 `--host` 参数，默认 `127.0.0.1`，`0.0.0.0` 时开放 CORS |
| 审计激活 | `--audit-log <path>` 显式指定 SQLite 路径，不指定则不审计 |
| files 数组处理 | 每个 FileSource 独立写一条审计记录，`file_name` 标识来源 |
| sql_text 存储 | 完整存储，不截断 |
| result_json 存储 | 完整解析结果 JSON，超 1 MB 时截断并标记 `result_truncated=1` |
| 审计查询 API | `GET /api/audit` 进入 MVP，支持分页和时间范围过滤 |

## SQLite 表结构

```sql
CREATE TABLE audit_log (
    id               INTEGER PRIMARY KEY AUTOINCREMENT,
    ts               TEXT    NOT NULL,               -- ISO 8601 UTC
    client_ip        TEXT    NOT NULL,               -- 请求来源 IP
    endpoint         TEXT    NOT NULL,               -- /api/analyze | /api/lint-fix | /api/split | /api/export/:format
    dialect          TEXT    NOT NULL,               -- generic | postgres | snowflake ...
    file_name        TEXT,                           -- files[] 模式的文件名，inline sql 时 NULL
    sql_text         TEXT    NOT NULL,               -- 完整原始 SQL，不截断
    sql_hash         TEXT    NOT NULL,               -- SHA-256(sql_text)，去重查找用
    sql_len          INTEGER NOT NULL,               -- 原始字节数，统计用
    has_cte          INTEGER NOT NULL DEFAULT 0,     -- 1 = 含 WITH/CTE
    has_union        INTEGER NOT NULL DEFAULT 0,     -- 1 = 含 UNION/INTERSECT/EXCEPT
    success          INTEGER NOT NULL,               -- 1 = 成功，0 = 失败
    duration_ms      INTEGER NOT NULL,               -- 端到端耗时（毫秒）
    stmt_count       INTEGER,                        -- 解析出的语句数（analyze/split 有值）
    table_count      INTEGER,                        -- 涉及的唯一表数（analyze 有值）
    result_json      TEXT,                           -- 完整解析结果 JSON
    result_truncated INTEGER NOT NULL DEFAULT 0,     -- 1 = result_json 超 1MB 被截断
    error_msg        TEXT                            -- 失败时的错误摘要
);

CREATE INDEX idx_audit_ts       ON audit_log(ts);
CREATE INDEX idx_audit_endpoint ON audit_log(endpoint);
CREATE INDEX idx_audit_sql_hash ON audit_log(sql_hash);
CREATE INDEX idx_audit_has_cte  ON audit_log(has_cte);
```

## Requirements

### 功能需求

1. **SQL 解析服务**：接收 HTTP POST 请求，调用 `flowscope_core::analyze()` 后返回 JSON 结果（与现有行为一致）。
2. **审计日志写入**：`--audit-log <path>` 开启后，上述四个端点每次请求都向 SQLite 写入一条（或多条，files 模式）审计记录。审计写入异步进行，不阻塞响应。
3. **files 数组拆分**：`/api/analyze` 的 `files` 字段中每个 FileSource 独立成一条审计记录，`file_name` 字段填入文件名。
4. **`has_cte` / `has_union` 提取**：从 `AnalyzeResult` 中扫描语句元数据填充，无需二次解析。
5. **`GET /api/audit`**：查询审计历史，支持参数：
   - `limit`（默认 50，最大 500）
   - `offset`（默认 0）
   - `from` / `to`（ISO 8601 日期，按 `ts` 过滤）
   - `endpoint`（按端点过滤）
   返回 `{ total, records: [...] }`。
6. **可配置 host**：`--host` 参数，默认 `127.0.0.1`，设为 `0.0.0.0` 时 CORS 开放所有来源。

### 非功能需求

- 审计写入失败不影响主响应（降级：记录 stderr 警告，继续返回结果）。
- 审计写入使用独立 tokio task，不占用请求处理线程。
- 服务重启后历史审计记录完整保留。

## Acceptance Criteria

- [ ] `POST /api/analyze`（inline sql）处理后，SQLite 中增加一条审计记录，字段完整。
- [ ] `POST /api/analyze`（files 数组含 3 个文件）处理后，SQLite 中增加 3 条审计记录。
- [ ] `has_cte` 对含 WITH 子句的 SQL 为 1，不含时为 0。
- [ ] `has_union` 对含 UNION 的 SQL 为 1，不含时为 0。
- [ ] 审计写入失败时，主响应仍正常返回（不受影响）。
- [ ] `GET /api/audit?limit=10&offset=0` 返回分页的审计记录列表。
- [ ] `GET /api/audit?from=2026-05-01&to=2026-05-13` 返回时间范围内的记录。
- [ ] 不传 `--audit-log` 启动时，不创建 SQLite 文件，行为与当前完全一致。
- [ ] `--host 0.0.0.0` 启动时，服务监听所有网络接口，CORS 开放。
- [ ] 现有所有 API 端点功能无回归（现有测试全部通过）。

## Out of Scope

- 用户认证与鉴权。
- 审计日志加密。
- 分布式多节点审计聚合。
- `GET /api/audit` 的全文 SQL 搜索（可后续迭代）。
