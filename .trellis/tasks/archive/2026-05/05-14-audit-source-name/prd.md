# PRD: 审计加 source_name 字段（业务标识）

## 需求来源

用户调 `POST /api/analyze` 时希望能带一个**可选**的标识字段（如调度 ID、
dbt model 名、业务侧 SQL 标签等），让 audit 记录可被业务关联和检索。
默认空，不传不写。

## 用户决策（已确认）

| 决策点 | 选择 |
|---|---|
| 字段命名 | **复用 core 已有的 `source_name`**（API 入参 `sourceName`/`source_name`，DB 列 `source_name`，前端列名 `Name`） |
| 适用端点 | **只 `/api/analyze`**（split / lint-fix / export 的 audit 行 `source_name` 写 NULL） |
| 前端范围 | **API + DB + 列表显示 + Name 输入框做 LIKE 过滤**（同 file_name 模式） |

## 影响分析（gitnexus）

- **风险等级**: LOW
- **直接受影响**: `AuditEntry` 的 4 个调用点（`analyze` / `split` / `lint_fix` / `export`，全在 `crates/flowscope-cli/src/server/api.rs`）
- **跨层**: Rust DB schema → Rust API → 前端列表 + 详情 + URL state

## 改动清单

### 1. `crates/flowscope-cli/src/server/audit.rs`

- `AuditEntry` 加 `pub source_name: Option<String>`
- `AuditLogListFilters` 加 `pub source_name_filter: Option<&'a str>`
- `CREATE_TABLE_SQL` 加 `source_name TEXT`
- 新增 `MIGRATE_SOURCE_NAME = "ALTER TABLE audit_log ADD COLUMN source_name TEXT"`（同已有 `MIGRATE_SQL_TYPE` 模式，忽略 `duplicate column` 错误）
- 新增 `CREATE INDEX IF NOT EXISTS idx_audit_source_name ON audit_log(source_name)`
- `INSERT_SQL` 加 `source_name` 列（参数从 18 → 19）
- `query()` SELECT / WHERE / JSON 输出都加 `source_name`
- `query_one()` SELECT / JSON 输出都加 `source_name`

### 2. `crates/flowscope-cli/src/server/api.rs`

- 内部 `struct AnalyzeRequest` 加 `#[serde(default, alias = "sourceName")] source_name: Option<String>`
- `analyze()`：
  - 把 `payload.source_name` 透传到 `flowscope_core::AnalyzeRequest.source_name`（core 早就有这个字段）
  - audit.record 的 entry 加 `source_name: payload.source_name.clone()`
- `split` / `lint_fix` / `export` 的 audit.record entry 加 `source_name: None`
- `AuditQueryParams` 加 `source_name: Option<String>`（LIKE 过滤）
- `audit_records` 把这个 filter 透传到 `AuditLogListFilters.source_name_filter`

### 3. 前端

- `app/src/pages/AuditPage.tsx`:
  - `AuditListRecord` 加 `source_name: string | null`
  - URL_PARAM_KEYS 加 `'source_name'`
  - 新增 `Name` 输入框（同 File name UX，本地 state + debounce → URL）
  - 表格加 Name 列（位于 File 和 Type 之间）
- `app/src/components/SqlPreviewCapsule.tsx`:
  - `AuditDetail` 加 `source_name: string | null`
  - 详情面板加一行 `Name: <source_name 或 —>`

### 4. Spec

- `.trellis/spec/flowscope-cli/backend/audit-api-spec.md` 加 `source_name` 字段说明
  - API 入参（驼峰 / snake 都接受）
  - 列表 / 详情接口返回字段
  - 过滤参数语义（LIKE %s%）

## API 协议示例

请求：

```json
POST /api/analyze
{
  "sql": "INSERT INTO t SELECT * FROM s",
  "dialect": "hive",
  "sourceName": "etl-job-1234"
}
```

审计行（GET /api/audit/:id）：

```json
{
  "id": 5108,
  "source_name": "etl-job-1234",
  "file_name": null,
  "sql_type": "INSERT",
  ...
}
```

过滤：`GET /api/audit?source_name=etl-job` → LIKE `%etl-job%`

## 验收标准

1. `cargo test -p flowscope-cli` 全绿（含新增的迁移幂等 + 写入查询测试）
2. `just lint` 全绿
3. 用 curl 端到端：
   ```bash
   # 新库
   curl -X POST localhost:3099/api/analyze -H 'Content-Type: application/json' \
     -d '{"sql":"SELECT 1","dialect":"hive","sourceName":"test-A"}'
   curl 'localhost:3099/api/audit?source_name=test-A&limit=1' | jq '.records[0].source_name'
   # 必须输出 "test-A"
   ```
4. 旧库迁移：用 *本次改动前* 的库文件启动，新写入不报错、老行 source_name 为 NULL
5. 浏览器 MCP：列表多一列 Name、过滤生效、详情面板显示 Name
6. typecheck + eslint 全绿

## 不修复项

- 不动 core 的 `source_name`（已存在）
- 不引入 audit 的全文检索 / 索引重构
- 不给 split / lint-fix / export 加 sourceName 入参（用户明确只 analyze）
