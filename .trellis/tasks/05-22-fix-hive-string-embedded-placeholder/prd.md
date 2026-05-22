# 修复字符串内嵌占位符破坏边界（Bug 3）

> 父任务：`05-22-fix-hive-preprocess-3-parse-bugs`
> 涉及代码：`crates/flowscope-core/src/hive_preprocess.rs`（仅 Step 1）

## Goal

修复 `substitute_placeholders`：当 `{{{var}}}` / `{{var}}` / `${var}` **嵌在**单引号
或双引号字符串字面量内部（前后还有其他字符）时，必须把**整个字符串字面量**
归一化为 `'__ph__'`，而不是只替换占位符部分（后者会拆穿字符串边界）。

## User Value

- 修复 `test-sql/30907.sql` 等使用 `LIKE '%{{{var}}}%'` 模式的真实生产 SQL parse 失败
- 解决一类隐藏 bug：原本字符串字面量被破坏，但 parser 报错位置远在错误真实位置之后
  （30907 真实根因在第 41 行，错误报到第 28 行），极难排查

## Confirmed Facts

- 文件 `test-sql/30907.sql` 第 41 行：
  ```sql
  and spuname like '%{{{spuname}}}%'
  ```
- 当前 `substitute_placeholders` 9 个正则按顺序：
  ```
  triple_sq → triple_dq → triple_bare
  → double_sq → double_dq → double_bare
  → dollar_sq → dollar_dq → dollar_bare
  ```
- `ph_re_triple_sq` 模式 `'\{\{\{[^}]*\}\}\}'` 要求**整个字符串就是占位符**，
  对 `'%{{{spuname}}}%'` 不匹配
- 落到 `ph_re_triple_bare` (`\{\{\{[^}]*\}\}\}`) 后，把字符串内部的裸 `{{{spuname}}}`
  替换为 `'__ph__'`，产出：
  ```
  '%{{{spuname}}}%'  →  '%'__ph__'%'
  ```
  破坏字符串边界，下游 parser 错位

## Requirements

### 功能

1. 单引号字符串内嵌任意数量的 `{{{var}}}`、`{{var}}`、`${var}` 时，**整个字符串**
   被替换为 `'__ph__'`
2. 双引号字符串同上（替换为 `'__ph__'`，注意输出统一用单引号 — Hive 字符串规范）
3. 不影响：
   - 紧贴引号的整体形式：`'{{{var}}}'`（已有 _sq 规则覆盖）
   - 不含占位符的纯字符串：`'%abc%'`、`"v"`
   - 裸占位符：`{{{var}}}`（SELECT 列表外部出现）
4. 多占位符场景：`'%{{{a}}}%{{{b}}}%'` 也被整体替换为 `'__ph__'`

### 测试

5. `mod tests` 新增至少：
   - `placeholder_triple_embedded_in_single_quoted`
   - `placeholder_multiple_embedded_in_single_string`
   - `placeholder_double_brace_embedded_in_dq`
   - `placeholder_no_var_string_untouched`（防误伤）

### 集成

6. 实际跑 `analyze()` 对 `test-sql/30907.sql`，`issues` 不含 parse error

## Acceptance Criteria

- [ ] `cargo test -p flowscope-core --lib hive_preprocess::tests::placeholder` 全绿（含至少 4 条新增测试）
- [ ] `just regression-sql-fast` 输出中 `30907.sql` 显示 `errors=0`
- [ ] 现有 `placeholders_*` 全部单测无回归
- [ ] `just lint` 与 `just fmt-check-rust` 全绿

## Out of Scope

- 字符串内含 `\'` 反斜杠转义的复杂场景（Step 7 后续处理；如发现实际 corpus 出现再开 task）
- 字符串内含 `''` 双单引号转义（Hive SQL 罕见）
- 父任务负责的整合工作（regression-expect 钉死、spec 更新）

## Notes

- 本 child 完成后**不**直接更新 `hive-compat-preprocess.md` 的 Step 1 描述；由父任务统一收口
- 本 child 完成后**不**修改 `test-sql/.regression-expect.json`；由父任务统一钉死
