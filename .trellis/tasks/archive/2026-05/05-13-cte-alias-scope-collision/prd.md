# Fix CTE alias scope collision: same-name aliases in different scopes merged

## Goal

修复 `flowscope-core` 中同名 subquery 别名在不同词法作用域被合并成同一节点的 bug。

## Root Cause

**触发点**：`crates/flowscope-core/src/analyzer/visitor.rs`（Derived 分支）

节点 ID 由 `generate_statement_scoped_node_id("derived", statement_index, alias)` 生成。两个同名 `b` 在同一条语句中，statement_index 相同，别名相同，ID 完全相同。`context.rs` 的 `add_node` 在 ID 已存在时静默跳过第二个节点，造成合并。

`StatementContext` 已有 `scope_stack: Vec<Scope>` 且 `scope_id` 单调递增，只需在节点 ID 生成时加入 `current_scope_id()` 即可。

## Bug 示例（dwd_conan_user_order_da.sql）

```sql
with new_device as (
  select ... from (...) a left join (...) b  -- scope-N 的 b = 设备-用户关联数据
)
insert overwrite table target
select ... from new_device as a left join (...) b  -- scope-M 的 b = 订单数据
```

当前：两个 `b` 合并为同一节点 → CTE `new_device` 混入订单数据来源，血缘图逻辑错误。

## Acceptance Criteria

- [ ] `dwd_conan_user_order_da.sql` 解析后，两个 `b` 是独立节点（设备 vs 订单）
- [ ] CTE `new_device` 的 data_flow 来源只有设备相关链路，不包含订单数据
- [ ] 目标表的 3 条来源路径（`new_device`、`b`-订单、`c`-用户注册）各自独立正确
- [ ] `cargo test -p flowscope-core` 全量通过
- [ ] 新增测试：同名 derived alias 在嵌套 CTE 内外不冲突
- [ ] 另外 4 个 test-sql 文件无回归

## Out of Scope

- WITH 子句命名的 CTE 同名冲突（仅修复 derived table alias）
