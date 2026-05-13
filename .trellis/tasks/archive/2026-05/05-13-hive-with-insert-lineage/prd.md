# Fix Hive WITH-INSERT-OVERWRITE lineage: target table isolated

## Goal

修复 `flowscope-core` 引擎在 Hive 方言下 `WITH cte AS (...) INSERT OVERWRITE TABLE target ...` 模式的血缘解析 bug：目标表被注册为孤立节点（0 条 edges），无法反映数据流向。

## Root Cause (from research)

sqlparser 将 `WITH ... INSERT OVERWRITE` 解析为 `Statement::Query`（不是 `Statement::Insert`），其中 `body = SetExpr::Insert(...)`。

- `analyze_statement` 的 `Statement::Query` 分支调用 `analyze_query(ctx, query, None)` —— `sink_target_id = None`，不创建目标 Table 节点
- `visit_set_expr` 的 `SetExpr::Insert` 分支把目标表错误地当作 source 注册（`add_source_table`）
- 正确的 `analyze_insert` 路径（`Statement::Insert`）永远不被调用

## Fix

在 `analyze_statement` 的 `Statement::Query` 分支中，检查 `query.body` 是否为 `SetExpr::Insert`。若是，提取 INSERT 的目标表，创建 Table 节点并作为 `sink_target_id` 传入 `analyze_query`，同时调用 `tracker.record_produced`。

**关键文件**：`crates/flowscope-core/src/analyzer/statements.rs`（约 L98-L147）

## Acceptance Criteria

- [ ] `WITH new_device AS (...) INSERT OVERWRITE TABLE dw_conan_dwd.dwd_conan_user_order_da ...` 解析后，目标表有 data_flow edges（不再孤立）
- [ ] `test-sql/` 下 5 个真实 SQL 文件的解析结果中，**所有有 INSERT OVERWRITE 的文件目标表都不孤立**
- [ ] 新增回归测试：Hive 方言 `WITH ... INSERT OVERWRITE` 目标表必须有 edges
- [ ] 现有 `cargo test -p flowscope-core` 全部通过（无回归）

## Test SQL Files to Validate

位于 `test-sql/`：
1. `dwd_conan_user_order_da.sql` — `WITH ... INSERT OVERWRITE`（直接触发 bug）
2. `dwd_eng_shendu_user_feature_di.sql` — `INSERT OVERWRITE`（大型 CTE）
3. `dwd_eng_frog_user_devices_detail_chapter_finish_da.sql` — `INSERT OVERWRITE`
4. `dwd_eng_chapter_quiz_question_report_ext_desc_all.sql` — `INSERT OVERWRITE`
5. `dwd_conan_referral_frog_di.sql` — `INSERT OVERWRITE`

所有 5 个文件解析后目标表必须有 edges。
