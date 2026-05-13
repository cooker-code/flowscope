# SQL Audit Service — HTTP service with request audit logging

## Goal

将 FlowScope 作为一个带审计日志的 SQL 解析服务运行。用户可以向服务提交任意 SQL，服务执行解析分析后返回结果，同时将每次请求的输入 SQL、解析结果及元数据持久化记录到 SQLite，以便后续审计和追溯。

## Status: Delivered (2026-05-13)

初版 MVP 已实现并验证。见下方「实际交付 vs 计划」。

---

## Decisions

| 决策 | 结论 |
|------|------|
| 审计存储 | SQLite（`rusqlite` bundled），单文件嵌入式 |
| 审计端点范围 | `/api/analyze`、`/api/lint-fix`、`/api/split`、`/api/export/:format` |
| 网络绑定 | `--host` 参数，默认 `127.0.0.1`，`0.0.0.0` 时开放 CORS |
| 审计激活 | `--audit-log <path>` 显式指定 SQLite 路径，不指定则不审计 |
| files 数组处理 | 每个 FileSource 独立写一条审计记录，`file_name` 标识来源 |
| sql_text 存储 | **完整存储，绝不截断** |
| result_json 存储 | 完整解析结果 JSON，超 1 MiB 截断并标记 `result_truncated=1` |
| 审计查询 API | 列表 `GET /api/audit`（无大字段）+ 详情 `GET /api/audit/:id`（完整字段）|

---

## 实际交付 vs 计划的差异

### 计划外新增

1. **`sql_type` 字段**（对话中发现需要）：记录第一个有意义语句的类型（INSERT / SELECT / WITH / CREATE）。
2. **`GET /api/audit/:id` 详情接口**（对话中发现列表不应含大字段）：返回完整 `sql_text` + `result_json`，列表接口去掉这两个大字段。
3. **前端构建**：发现 `embedded-app/` 只有占位符，构建了 `app/` 前端并嵌入 CLI 二进制。

### 实现中修正的设计决策

| 原计划 | 实际实现 | 原因 |
|--------|----------|------|
| `stmt_count` = 所有语句数 | 过滤 SET/USE/RESET 后的数量 | Hive SQL 文件通常以 4–8 条 SET 开头，原计数无意义 |
| `table_count` = `summary.table_count` | 只计 `NodeType::Table \| View` | `summary.table_count` 含 CTE 节点，不反映真实物理表数 |
| `has_cte` = 含任意 CTE 节点 | 同（未变） | 确认：CTE = WITH 子句，不含子查询 |
| 列表接口含所有字段 | 列表省略 `sql_text` / `result_json` | 两个文件的完整字段会使浏览器页面高度超过 90,000px |

---

## SQLite 表结构（最终版）

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
    sql_type         TEXT,
    result_json      TEXT,
    result_truncated INTEGER NOT NULL DEFAULT 0,
    error_msg        TEXT
);
```

字段语义详见 `.trellis/spec/flowscope-cli/backend/audit-api-spec.md`。

---

## Acceptance Criteria（最终）

- [x] `POST /api/analyze`（inline sql）处理后，SQLite 中增加一条审计记录，字段完整。
- [x] `POST /api/analyze`（files 数组含多个文件）每个文件独立一条审计记录。
- [x] `has_cte` 对含 WITH 子句的 SQL 为 true，子查询不触发。
- [x] `has_union` 对含 UNION/INTERSECT/EXCEPT 的 SQL 为 true。
- [x] `stmt_count` 过滤 SET/USE/RESET，只计业务语句。
- [x] `table_count` 只计物理表和视图，不含 CTE 节点。
- [x] `sql_type` 返回第一个有意义语句的类型（INSERT/SELECT/WITH 等）。
- [x] `GET /api/audit` 列表不含 `sql_text` / `result_json`，页面可正常浏览。
- [x] `GET /api/audit/:id` 返回完整字段含 `sql_text` 和 `result_json`。
- [x] 审计写入失败时，主响应仍正常返回。
- [x] 不传 `--audit-log` 启动时，行为与之前完全一致。
- [x] `--host 0.0.0.0` 启动时，CORS 开放，服务可从外部访问。
- [x] FlowScope Web UI 可访问（embedded-app 已构建）。
- [x] 现有 76 个单元测试全部通过。

## Out of Scope

- 用户认证与鉴权。
- 审计日志加密。
- 分布式多节点审计聚合。
- `GET /api/audit` 的全文 SQL 搜索。
- 审计 UI 集成进 Web App（`/audit` 路由）— 后续迭代。
