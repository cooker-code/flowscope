# 固化 INSERT 目标列位置映射

## Goal

将 C3 目标列位置映射从临时解析结果固化到 FlowScope Core：显式列、DDL schema、分区、多语句冲突与 UNION 分支位置。隔离回测后由父任务合入本地 master，生产不改。

## Requirements

- 在 `flowscope-core` 的实际 INSERT 分析路径输出位置型目标字段映射；不改写 SELECT 标签、普通值边或窗口控制边。
- 仅以显式 INSERT 字段列表或导入/DDL 建立的 schema 作为目标字段顺序依据；未知、通配符、重复输出和字段数不一致必须保持 unresolved。
- Hive 静态分区不占 SELECT 位置，动态分区占末尾位置。
- 多语句冲突不得保留先出现的映射。
- UNION 必须按 `SetExpr` 分支的显式投影位置逐分支绑定；仅扁平输出数相等不能视为证明。
- 构建 CLI 与 WASM，供 Neo4j 批处理针对原 ETL 重放；隔离图验收由父任务执行，生产不改。

## Acceptance Criteria

- [x] Core 单元测试覆盖 schema、显式字段、静/动态分区、无 schema、冲突和 UNION 不同别名分支。
- [x] Core、CLI、lineage、scoping、WASM 相关 Rust 测试通过。
- [x] 新 CLI 和 WASM 均由该 worktree 源码构建并有 SHA-256 冻结记录。
- [ ] 父任务使用冻结 CLI 完成 932 条普通 INSERT、236 个任务哈希及 159 条 UNION 的隔离图回测。

## Notes

- Keep `prd.md` focused on requirements, constraints, and acceptance criteria.
- Lightweight tasks can remain PRD-only.
- For complex tasks, add `design.md` for technical design and `implement.md` for execution planning before `task.py start`.
