# 修复 RLIKE / SIMILAR TO 条件的字段值依赖遗漏

## Goal

修复 CASE 条件中 RLIKE / SIMILAR TO 字段引用漏采集导致普通值来源缺失。

## Requirements

- 修复 `ExpressionAnalyzer::collect_column_refs` 对 Hive `RLIKE` 条件未递归采集左值字段的问题；同类 `SIMILAR TO` 不能继续遗漏。
- 修复必须位于 `flowscope-core` 的真实 SQL 分析路径，不能由 Neo4j 预处理或图回填补边。
- 保持普通值来源与窗口控制来源的边类型边界：本项只恢复 CASE 的普通 `Derivation` 输入。
- 使用 task 31491 的原始 CTE → GROUP BY → 窗口结构验证 `applyaccountid → account_type` 值链；不写入任何 Neo4j 图。

## Acceptance Criteria

- [ ] CASE + RLIKE 与 CASE + SIMILAR TO 的字段采集单元回归通过。
- [ ] 原始 31491 结构的解析回归确认 CASE 来源来自具体 Physical 列，而非 relation-level fallback。
- [ ] Core、CLI、WASM 相关测试和构建通过；父任务使用冻结 CLI 进行隔离图回测。

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
