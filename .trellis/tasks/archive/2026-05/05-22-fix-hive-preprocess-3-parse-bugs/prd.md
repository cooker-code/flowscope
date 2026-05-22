# 修复 Hive SQL 预处理 3 个解析报错（父任务）

## Goal

修复 `crates/flowscope-core/src/hive_preprocess.rs` 中 3 处独立缺陷，让以下生产 Hive SQL 文件能成功通过 `flowscope_core::analyze`，零 parse error：

- `test-sql/29463.sql` — GROUPING SETS 多级嵌套
- `test-sql/29209.sql` — `POSEXPLODE(...) AS (col1, col2)` inline 多列 AS 解构语法
- `test-sql/30907.sql` — `'%{{{spuname}}}%'` 字符串内嵌占位符破坏边界

三个缺陷根因不同、修复点不同，但**共用同一管道、同一测试基础设施、同一份 spec**，
父任务负责跨子任务的整合与验收，每个子任务负责单点 bug 的修复与单测。

## User Value

- Hive corpus 通过率从 ~99.96% 进一步逼近 100%
- 所有 `analyze()` 调用方（REST `/api/analyze`、wasm、CLI、React、VS Code 扩展）自动受益
- spec 文档与代码同步增强

## Child Task Map

| Child | 标题 | 修复点 | Touch |
|-------|------|-------|------|
| `05-22-fix-hive-string-embedded-placeholder` | Bug 3 字符串内嵌占位符 | Step 1 占位符替换 | `substitute_placeholders` + 测试 |
| `05-22-fix-hive-grouping-sets-nested` | Bug 1 GROUPING SETS 多级嵌套 | Step 13 | `rewrite_grouping_sets` + 测试 |
| `05-22-fix-hive-inline-multi-col-as` | Bug 2 inline 多列 AS 解构语法 | Step 4.5 新增 | 新增 `rewrite_inline_multi_col_as` + 接入 + 测试 |

### 推荐实施顺序

`fix-hive-string-embedded-placeholder` → `fix-hive-grouping-sets-nested` → `fix-hive-inline-multi-col-as`

**理由**：风险从小到大、改动从轻到重；前一个修完不会影响后一个修复点的代码区域，
便于逐个 child 独立验证、独立 commit、独立 revert。

> 三个 child 之间**没有强依赖**（不是必须按这个顺序做），但建议依次推进以最小化
> 联调成本。每个 child 完成后即可单独跑回归 gate。

## 跨子任务（父任务自身）的直接工作

子任务全部完成（status=completed 或代码已合入）后，父任务直接做以下整合：

1. **`.regression-expect.json` 钉死**：用 `just regression-sql-fast` 实测输出值
   填入 29463 / 29209 / 30907 三个文件的 `sqlType` / `statementTypes` /
   `errorCount=0` 等字段；INSERT 类还要 `targetTable` + `insertType` +
   `sources`（**直接抄观察值，不要凭直觉**）。
2. **spec 文档统一更新**：`.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md`
   的 Step 1 / Step 4 / Step 13 段落同步增量修改；hive_preprocess.rs 模块顶部
   `//! ## Pipeline (in order)` 注释新增 Step 4.5 行。
3. **跨子任务回归**：`just lint`、`just fmt-check-rust`、`just test-core`、
   `just regression-sql-fast` 全绿。

> 父任务不重复 child 的代码修复工作，只做整合 + 终极验收。

## Cross-child Acceptance Criteria（父任务验收）

- [ ] 3 个 child 任务的状态全部为 `completed`，对应代码均已合入
- [ ] `just test-core` 全绿
- [ ] `just regression-sql-fast` 输出中 29463 / 29209 / 30907 均 `errors=0`
- [ ] `test-sql/.regression-expect.json` 已为这 3 个文件添加钉死项，再跑 `just regression-sql-fast` 仍然全绿
- [ ] `just lint` 与 `just fmt-check-rust` 全绿
- [ ] `.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md` 已同步：
  - Step 1 段补充"单引号 / 双引号字符串内嵌占位符"小节
  - Step 4 段后插入 Step 4.5 段
  - Step 13 段更新嵌套支持表述
- [ ] `hive_preprocess.rs` 模块顶部 13-step 注释清单已加 Step 4.5

## Out of Scope（整个父任务范围）

- 不修预处理后 → 原文的 span 反向映射（已知限制）
- 不重写 Step 1 占位符正则架构（仅增量增加规则）
- 不引入字符级 SQL 扫描器框架（如某 child 必须用字符级实现，单点引入即可）
- 不修改前端 / VS Code / React 任何代码
- 子任务之间**不引入互相依赖**：若 child 实现时发现需要另一个 child 已经修好的代码才能验证，立即记录到本 PRD 的"Risk"段并回到 brainstorm

## Notes

- 三个子任务**不是 dependency 树**（child A 不阻塞 child B），父子结构纯粹是组织
- 父任务**不直接 `task.py start` 进入实施**，直到子任务全部完成；父任务的整合工作通过 child finish 后再 start parent 完成
- 每个 child 都是 complex task（PRD + design + implement 三件套），单文件 + 单测 + 简短 spec 改动
