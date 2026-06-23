# 审计页目标表筛选设计

## Boundaries

涉及层：
- 后端审计写入：`crates/flowscope-cli/src/server/audit.rs`
- 后端 HTTP 参数解析：`crates/flowscope-cli/src/server/api.rs`
- 前端审计页：`app/src/pages/AuditPage.tsx`
- 审计 API 契约：`.trellis/spec/flowscope-cli/backend/audit-api-spec.md`

不涉及：
- `flowscope-core` 分析器目标表推导规则。
- 详情页 SQL/lineage 展示。
- 审计列表返回 `sql_text` 或 `result_json`。

## Data Flow

1. `/api/analyze` 或 `/api/export/:format` 调用 `flowscope_core::analyze` 得到 `AnalyzeResult`。
2. 审计写入前从 `AnalyzeResult.target_table` 提取目标表：
   - 优先 `qualified_name`
   - 否则 `label`
   - 否则 `NULL`
3. `AuditEntry.target_table` 写入 SQLite `audit_log.target_table`。
4. `GET /api/audit` 解析 `target_table` 参数，传入 `AuditLogListFilters.target_table`。
5. `AuditWriter::query` 使用 `target_table = ?` 精确匹配，并在列表 JSON 中返回 `target_table`。
6. `AuditPage` 将目标表筛选存入 URL，并把 `target_table` 渲染为表格列。

## Contracts

- `target_table` 是物化字段，避免列表查询读取或解析 `result_json`。
- 筛选是精确匹配，符合用户“库名.表名查询”的要求。
- 列表 API 继续只返回轻量字段，不能新增 `sql_text` 和 `result_json`。
- SQLite schema 演进走 additive migration，保持老审计库兼容。

## Compatibility

- 新库直接通过 `CREATE_TABLE_SQL` 创建 `target_table`。
- 老库通过 `ALTER TABLE audit_log ADD COLUMN target_table TEXT` 补齐。
- 增加 `idx_audit_target_table` 支撑目标表筛选。
- 对历史记录，`target_table` 为 `NULL`，列表显示 `—`；筛选不会命中这些记录。

## Trade-offs

- 精确匹配比模糊匹配更符合“库名.表名”的定位需求，也避免误命中同名短表；代价是用户必须输入完整目标表。
- 物化 `target_table` 会增加 schema migration，但比在列表查询中解析 `result_json` 更稳定、更轻。
