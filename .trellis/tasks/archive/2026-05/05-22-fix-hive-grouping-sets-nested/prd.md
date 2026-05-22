# 修复 GROUPING SETS 多级嵌套预处理（Bug 1）

> 父任务：`05-22-fix-hive-preprocess-3-parse-bugs`
> 涉及代码：`crates/flowscope-core/src/hive_preprocess.rs`（仅 Step 13）

## Goal

修复 `rewrite_grouping_sets`：当 `GROUP BY GROUPING SETS (...)` 的括号内部出现
**2 级或更深的括号嵌套**（如 set 内含 `date_sub(...)` 等函数调用）时，整段也
应被正确识别并替换为 `GROUP BY 1`。

## User Value

- 修复 `test-sql/29463.sql` 等使用复杂 GROUPING SETS（每个 set 内含函数调用产生
  2 级及以上嵌套）的真实生产 SQL parse 失败
- 消除"嵌套层数"这个隐含上限，未来新增更复杂 GROUPING SETS 不再产生同类 bug

## Confirmed Facts

- 文件 `test-sql/29463.sql` 第 109–111 行：
  ```sql
  group by grouping sets (
      (date_sub(next_day('__ph__','MO'),7), teacher_city, ..., unit),
      (date_sub(next_day('__ph__','MO'),7), teacher_city),
      (date_sub(next_day('__ph__','MO'),7))
  )
  ```
  （上面是 Step 1 预处理后的形态，原文 `'{{{dt}}}'` 已经被替换为 `'__ph__'`）
- 外层 `(...)` 是 GROUPING SETS 列表
- 内层 `(set_columns)` 是每个 set 自身的括号
- set 内 `date_sub(...)` 是函数调用 → 嵌套到第 2 级
- 当前 Step 13 regex（`hive_preprocess.rs:606`）：
  ```
  group\s+by\s+grouping\s+sets\s*\((?:[^()]|\([^()]*\))*\)
  ```
  内层 `\([^()]*\)` 只允许内部 0 级再嵌套（即 set 内不能再有任何 `(`）→
  29463 的 2 级形态不匹配 → 整段保留原文 → sqlparser 报 `Expected: end of statement, found: sets`

## Requirements

### 功能

1. `GROUP BY GROUPING SETS (...)`，无论括号嵌套到几级，都被整体识别并替换为 `GROUP BY 1`
2. 同一 SQL 内有多个 GROUPING SETS 时，全部都要替换（不止第一个）
3. 不影响：
   - 普通 `GROUP BY a, b`
   - 单引号字符串内出现 `grouping sets` 字面值（不能误伤）
   - `GROUP BY a WITH CUBE` / `WITH ROLLUP`（这是 sqlparser 已支持的形式，**不在本任务范围**）

### 测试

4. `mod tests` 新增至少：
   - `grouping_sets_two_level_nested`
   - `grouping_sets_three_level_nested`
   - `grouping_sets_simple_one_level_still_works`（防回归）
   - `grouping_sets_inside_string_literal_not_touched`（防误伤）
   - `grouping_sets_multiple_occurrences_in_one_sql`（多次出现）

### 集成

5. 实际跑 `analyze()` 对 `test-sql/29463.sql`，`issues` 不含 parse error

## Acceptance Criteria

- [ ] `cargo test -p flowscope-core --lib hive_preprocess::tests::grouping_sets` 全绿（含至少 5 条新增测试）
- [ ] `just regression-sql-fast` 输出中 `29463.sql` 显示 `errors=0`
- [ ] 现有 `grouping_sets_*` 单测无回归
- [ ] `just lint` 与 `just fmt-check-rust` 全绿

## Out of Scope

- `GROUP BY CUBE(...)` / `GROUP BY ROLLUP(...)`：当前 `rewrite_grouping_sets`
  函数名暗示也支持这两种，但**现有代码事实上只匹配 GROUPING SETS**。本任务
  保持现状，CUBE / ROLLUP 如未来真发现 corpus SQL 失败再单独开 task
- 父任务负责的 spec 文档更新（Step 13 段落表述）
- 父任务负责的 regression-expect 钉死

## Notes

- 本 child 完成后**不**修改 spec 与 regression-expect（父任务收口）
- 修复方案细节见 `design.md`
