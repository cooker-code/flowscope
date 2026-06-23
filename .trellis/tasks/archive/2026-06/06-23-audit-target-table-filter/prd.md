# 审计页目标表筛选

## Goal

在审计日志页面新增“目标表”筛选，并在列表中展示目标表，方便用户按 `库名.表名` 快速定位写入某张目标表的 SQL 分析记录。

用户价值：
- 当前只能按 SQL keyword 搜索，无法稳定地区分“SQL 文本中提到过某表”和“该记录实际写入的目标表”。
- 审计列表需要直接显示目标表，减少进入详情页确认 `targetTable` 的次数。

## Confirmed Facts

- 前端审计页位于 `app/src/pages/AuditPage.tsx`。
- 审计页筛选条件以 URL query 为事实源，并保存到 `LAST_AUDIT_QUERY_KEY` 供详情页返回列表时恢复。
- 当前前端筛选项包含 `from`、`to`、`sql_type`、`success`、`file_name`、`source_name`、`keyword`、`page`。
- 后端审计 API 位于 `crates/flowscope-cli/src/server/api.rs`，列表查询参数通过 `AuditQueryParams` 解析。
- 审计 SQLite 读写和查询逻辑位于 `crates/flowscope-cli/src/server/audit.rs`。
- 当前 `GET /api/audit` 列表响应不包含 `sql_text` 和 `result_json`，这是已有性能契约。
- 当前 `audit_log` 没有独立的目标表列；目标表只在 `AnalyzeResult.target_table` 中存在。
- `AnalyzeResult.target_table` 的优先展示字段应使用 `TableRef.qualified_name`，缺失时可降级到 `TableRef.label`。
- 修改审计 schema 需要同时更新 `CREATE_TABLE_SQL`、`ADDITIVE_MIGRATIONS`、必要索引和 legacy migration 测试。

## Requirements

- 新增审计字段 `target_table`，记录单目标写入表的展示名。
- `target_table` 值必须来自分析结果的 `target_table.qualified_name`；缺失时降级使用 `target_table.label`；没有目标表时为 `NULL`。
- `GET /api/audit` 新增 `target_table` 查询参数，要求用户输入 `库名.表名` 形式后查询。
- `target_table` 筛选语义为精确匹配，不使用 SQL 文本 keyword 模糊匹配。
- `GET /api/audit` 列表响应返回 `target_table`，但继续不返回 `sql_text` 和 `result_json`。
- 审计页新增“Target table”筛选框，输入态和 URL query 同步，300ms debounce 行为与现有文本筛选保持一致。
- 审计页列表新增目标表列，展示 `target_table`，空值显示 `—`，长表名使用截断并提供 title。
- Reset 必须清空目标表筛选。
- 从详情页返回审计页时必须恢复目标表筛选。
- 老版本审计数据库启动后必须通过 additive migration 自动补齐 `target_table` 列。

## Acceptance Criteria

- [x] 使用 `POST /api/analyze` 分析 `INSERT ... db.table ...` 后，审计列表记录包含该目标表。
- [x] `GET /api/audit?target_table=db.table` 只返回目标表精确匹配的记录。
- [x] 审计页可以输入 `db.table` 过滤目标表，URL 中保存 `target_table=db.table`。
- [x] 审计页表格展示目标表列，并且空目标表显示 `—`。
- [x] Reset 后目标表输入框、URL 参数、列表筛选都被清空。
- [x] 旧 schema 审计库通过 `AuditWriter::new` 打开两次不报错，并存在 `target_table` 列。
- [x] `GET /api/audit` 仍不返回 `sql_text` 和 `result_json`。
- [x] 相关 Rust 单测通过：审计模块需要 `serve` feature，已跑 `cargo test -p flowscope-cli --features serve ...` 目标测试。
- [x] 前端类型检查通过：`yarn workspace @pondpilot/flowscope-app typecheck`。

## Notes

- 实现前必须通过代码检索、调用点梳理和测试验证确认后端函数/前端组件影响范围。
- `.gitignore` 当前已有用户未提交修改，本任务不得回滚或覆盖。
- `cargo test -p flowscope-cli` 当前存在 5 个与本任务无关的 `lint_cli` core-autofix 失败；本次审计/serve 目标测试已单独通过。
