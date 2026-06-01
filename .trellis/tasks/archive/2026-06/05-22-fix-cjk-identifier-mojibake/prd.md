# Fix CJK identifier mojibake in SQL parsing

## Goal

修复 `flowscope` CLI / core 解析含**中文（及其它非 ASCII）标识符或字符串字面量**的 SQL 时，输出的 `label` / `canonicalName.name` / `expression` 字段出现 mojibake 乱码的问题，使 JSON / Dali / CSV / XLSX 等所有输出 format 都正确保留原始 UTF-8 字符。

## Reproduction (验证乱码现象)

输入 SQL（`/tmp/flowscope-test/cn.sql`，UTF-8 编码）：

```sql
select
    '分销' as `一级`
    ,'分销-B端-CPA' as `二级渠道`
    ,'体验会员' as `cpa类型`
    ,period_monday as `周一`
from A
```

复现命令：

```bash
./target/release/flowscope -d hive -f json /tmp/flowscope-test/cn.sql
```

实际输出（节选，UTF-8 字节被错误地以 Latin-1 解读后再 UTF-8 编码，疑似双重 mojibake）：

```json
{
  "label": "ãâãâ¤ãâãâ¸ãâãâãâãâ§ãâãâºãâãâ§",
  "expression": "'ÃÂ¥ÃÂÃÂÃÂ©ÃÂÃÂ'"
}
```

期望输出：

```json
{
  "label": "一级",
  "expression": "'分销'"
}
```

旁证：
- ASCII 表名 `a` / 列名 `period_monday` 完全正常；
- stdin 与 file 两种输入路径乱码现象一致 → 排除文件 IO 编码问题；
- `-f table` 输出不显示列 label，故终端 locale 无关；
- 输入文件 `file(1)` 报告 `UTF-8 text` → 输入合法。

## Requirements

### 必须

- R1：含 CJK / 其它非 ASCII 字符的 SQL 标识符（反引号、双引号、方括号等任何 quote 形式）在 lineage 输出中保持原字符串。
- R2：含 CJK / 其它非 ASCII 的字符串字面量（单引号 / E'...' 等）在 `expression` 字段中保持原字符串。
- R3：覆盖所有产生 `label` / `canonicalName` / `expression` 的 output format：`json`、`dali`、`csv`、`xlsx`、`mermaid`、`html`。
- R4：在 `crates/flowscope-core/tests/fixtures/` 中新增至少 1 个含 CJK 的 fixture，并在 `cargo test -p flowscope-core` 中加入正向断言（直接比对字符串而非字节）。
- R5：`just regression-sql` 的金标 `test-sql/.regression-expect.json` 增量校验中文样本（至少 1 个），且 headline 字段（`sqlType` / `targetTable` / `sourceTables` 等）不退化。

### 不在本次范围（待定/单独提）

- N1：linter 规则消息文案（issue message）中是否也存在同样问题——本次仅在 implement 阶段顺手验证一次，若也乱码则记为 follow-up，不在本任务必修。
- N2：VSCode webview / app demo 的渲染显示——本任务只保证 CLI / core 输出正确，前端展示问题单独发任务。

## Acceptance Criteria

- [ ] 上述复现命令的 JSON 输出中，`label` / `canonicalName.name` / `expression` 包含的中文与 SQL 源文件**字节完全一致**（使用 `jq -r '.nodes[].label'` + `diff` 验证）。
- [ ] 至少覆盖 1 个 CJK fixture 的单元测试，断言字段值 `== "一级"` 这种**正向字符串相等**（不允许只判断 `!= ""`）。
- [ ] `just regression-sql` 通过，新增的中文期望写入 `.regression-expect.json`。
- [ ] `just lint`、`just test-rust`、`just check` 全部通过。
- [ ] `dali` / `csv` / `xlsx` / `mermaid` / `html` 任选 2 个手工抽查输出，中文不乱码（在 PR 描述里贴样本）。

## Risk / Open Questions

- Q1：根因在 `sqlparser-rs` 上游 lexer，还是在 flowscope 自己的 unquote / canonicalize 过程？由 Phase 1.2 research 确定，若在上游则方案需要在 flowscope 层加 workaround（fork / patch / 字符串重建）。
- Q2：现有金标 `test-sql/.regression-expect.json` 是否已经存在被乱码污染的字段值？若是，需要在本任务中一并修正（属于 R5）。

## Notes

- Lightweight vs complex 判定推迟到 Phase 1.2 research 结束：若根因清晰且局部可修，按 PRD-only 推进；若涉及上游 fork / 多处改造，补 `design.md` + `implement.md` 升级为 complex。
- Research 阶段**禁止改动产品代码**，仅允许新建 `.trellis/tasks/05-22-fix-cjk-identifier-mojibake/research/` 下的调查脚本与笔记。
