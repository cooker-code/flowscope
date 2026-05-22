# 修复 inline 多列 AS 解构语法预处理（Bug 2）

> 父任务：`05-22-fix-hive-preprocess-3-parse-bugs`
> 涉及代码：`crates/flowscope-core/src/hive_preprocess.rs`（新增 Step 4.5）

## Goal

修复 `FlowscopeHiveDialect` 不支持 Hive 的 inline 多列 AS 解构语法：

```sql
<function>(<args>) AS (<col1>, <col2>, ...)
```

这是 Hive UDTF（POSEXPLODE / EXPLODE / INLINE / STACK / JSON_TUPLE / 自定义 UDTF
…）在 SELECT 列表内联展开时的合法语法。sqlparser-rs 在 `AS (` 处报错。

**本任务采用「按语法形态识别」而不是「UDTF 白名单」**：只要源 SQL 中出现
`<标识符>(<嵌套表达式>) AS (<col_list>)` 的语法结构，就改写为 parser 可吞下
的形态，并保留所有别名供下游列引用解析。函数名是什么不重要 — 重要的是
"AS 后紧跟左括号"这个语法特征。

## User Value

- 修复 `test-sql/29209.sql` 等使用 POSEXPLODE inline 多列展开的真实生产 SQL parse 失败
- 覆盖任意 UDTF（包括用户自定义、未来 Hive 新增），不依赖维护白名单
- 与 Hive 的 LATERAL VIEW 形态（`LATERAL VIEW POSEXPLODE(x) t AS pos, val`，
  sqlparser-rs 原生支持）正交互补

## Confirmed Facts

- 文件 `test-sql/29209.sql` 第 12 行：
  ```sql
  SELECT POSEXPLODE(SPLIT('{{{holiday_weeks}}}', ',')) AS (pos, hw_val)
  ```
- Step 1 已经把 `'{{{holiday_weeks}}}'` 替换为 `'__ph__'`
- `FlowscopeHiveDialect` 不识别 `AS (col_list)` 这种 inline 多列别名 → 在 `AS (`
  之后的 `(` 处报错（`Expected: ), found: (`）
- 下游 SQL 中通过 `hw.pos` / `hw.hw_val` 引用这两个 colname，**别名必须保留**
  否则下游列引用会找不到列
- 现有 Step 4 (`rewrite_transform_using`) 只处理 `USING 'script' [AS (cols)]`
  这种 TRANSFORM 子句，**不**处理 SELECT 列表中的 inline UDTF
- 现有 hive_preprocess 管道完全没有处理这种语法的 step

### Hive UDTF inline 别名语法的边界

| 形式 | 是否合法 Hive | sqlparser-rs 是否能 parse | 本任务行为 |
|------|--------------|--------------------------|---------|
| `POSEXPLODE(x) AS (pos, val)` | ✓ | ✗ | **改写** |
| `EXPLODE(x) AS (val)` | ✓ | ✗ | **改写** |
| `INLINE(x) AS (a, b, c)` | ✓ | ✗ | **改写** |
| `my_udtf(x) AS (a, b)`（用户自定义） | ✓ | ✗ | **改写**（语法识别即覆盖） |
| `my_udf(x) AS y`（普通 UDF 单别名） | ✓ | ✓ | **不动**（AS 后非 `(`） |
| `cast(x AS bigint) AS y` | ✓ | ✓ | **不动**（AS 内嵌在 cast 内，外层 AS 后非 `(`） |
| `LATERAL VIEW POSEXPLODE(x) t AS pos, val` | ✓ | ✓ | **不动**（LATERAL VIEW 形态，sqlparser 原生支持） |
| `from (select 1) t(c)` | ✓ | ✓ | **不动**（标识符是右括号 `)` 而非函数调用） |

## Requirements

### 功能

1. 新增 Step 4.5：识别 `<IDENT>(<args>) AS (<col_list>)` 语法形态并改写
2. 改写规则：`<IDENT>(<args>) AS (<c1>, <c2>, ..., <cN>)` →
   `NULL AS <c1>, NULL AS <c2>, ..., NULL AS <cN>`
   - 保留所有别名，下游 `t.c1` 引用仍能解析为列引用
   - 对 parser 而言每个 `NULL AS <col>` 是合法 select-list item
   - 血缘骨架：UDTF 调用本身不引入新表（输入是字符串字面量、数组字面量、
     或已经被 Step 1 替换为 `'__ph__'` 的占位符），因此把 UDTF 调用替换为
     `NULL` 不损失血缘信息
3. 不依赖函数名白名单 — 只看 `AS (` 这个语法特征
4. 不影响：
   - `<func>(<args>) AS <single_alias>`（普通 UDF / scalar 函数，AS 后非 `(`）
   - `cast(x AS bigint) AS y` 等内嵌 AS 的复杂表达式
   - `LATERAL VIEW <UDTF>(<args>) <tab_alias> AS <col_alias>[, ...]`（sqlparser 原生）
   - `<subquery> AS t(c)`（标识符是子查询右括号，不是函数调用名）

### 测试

5. `mod tests` 新增至少：
   - `inline_multi_col_as_posexplode_two_col`
   - `inline_multi_col_as_explode_single_col_in_parens`
   - `inline_multi_col_as_custom_udtf_no_whitelist`（关键：证明不靠白名单）
   - `inline_multi_col_as_scalar_function_with_single_alias_not_touched`（防误伤）
   - `inline_multi_col_as_cast_with_inner_as_not_touched`（防误伤）
   - `inline_multi_col_as_lateral_view_form_not_touched`（防误伤）
   - `inline_multi_col_as_subquery_alias_not_touched`（防误伤）

### 集成

6. 实际跑 `analyze()` 对 `test-sql/29209.sql`，`issues` 不含 parse error

## Acceptance Criteria

- [ ] `cargo test -p flowscope-core --lib hive_preprocess::tests::inline_multi_col_as` 全绿（含至少 7 条新增测试）
- [ ] `just regression-sql-fast` 输出中 `29209.sql` 显示 `errors=0`
- [ ] 现有所有 hive_preprocess 单测无回归（重点关注 `transform_using_removed`、`full_pipeline_smoke`）
- [ ] `just lint` 与 `just fmt-check-rust` 全绿

## Out of Scope

- LATERAL VIEW 形态的修复（sqlparser-rs 原生已支持）
- 改写 `NULL` 之外的占位（如想替换为输入 args 的字符串拼接 — 没必要，会增加复杂度）
- 父任务负责的 spec 文档更新（新增 Step 4.5 段）
- 父任务负责的 regression-expect 钉死
- 添加任何"已知 UDTF 名字列表"的代码 — 故意不做（违背本任务的「按语法不按白名单」原则）

## Notes

- 本任务的核心是「**语法形态识别**」：`AS` 后紧跟 `(` 是 Hive UDTF inline 多列
  别名的**唯一**语法标识。不要再引入 UDTF 名字判断
- 修复方案细节、正则边界、误伤分析见 `design.md`
