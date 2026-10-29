## Goal

1. 将窗口函数的值来源与控制依赖分开表达，并使经 CTE、窗口输出和后续聚合传播的控制影响可查询。
2. 用户于 2026-10-29 明确批准 PARTITION BY/ORDER BY 计入依赖并区分角色。
3. 沿用父 Task 的独立 worktree、原 ETL 回测、隔离图验收和本地 master 合并边界，生产不改。

## Requirements

### R1 修改

- **R1.1**：FlowScope 保留既有值边，另发 `window_control` 边；`metadata.windowRole` 为 `partition` 或 `order`，相同端点的值/控制及两种角色都不能合并。
- **R1.2**：内联窗口、命名窗口、复杂表达式和跨 CTE 传播有明确测试；不能解析时输出 unresolved/Issue，不能把遗漏写成没有控制依赖。
### R2 新增

- **R2.1**：Neo4j 以独立 `CONTROLS_COL` 保存控制依赖，不进入 `DERIVES_COL` 值来源或旧字段覆盖率。
- **R2.2**：历史 prepared ETL 使用修复后的 parser 生成控制合同，只在输出和来源身份可唯一证明时回补；保持原值边、目标映射、所有原任务和共享节点。
### R3 新增

- **R3.1**：提供独立的字段窗口控制查询接口，可沿“值边与至少一条控制边”的路径查控制根，继承当前版本过滤，并与值来源响应分开。
- **R3.2**：控制解析/回补状态必须区分 complete、unresolved 和 legacy unknown；没有边不自动表示已证明无控制依赖。
### R4 修改

- **R4.1**：独立 SQL AST 审计保留角色、跨 CTE 控制传播、expected/actual/unresolved；不得使用 FlowScope 产物作为自身唯一预期。
- **R4.2**：在真实隔离 Neo4j 回测 FIRST_VALUE、MAX OVER→COUNT、同列双角色、命名窗口、歧义/缺元数据、版本/共享身份、重复重放；验证 C1—C4 回归集合和值边不被污染。

## User-visible Outcomes

- [ ] **O1（R1.1、R1.2）**：原 ETL 中的窗口分组与排序字段能够看到独立角色，未解析情况有具体原因。
- [ ] **O2（R2.1、R2.2、R3.1、R3.2）**：可分别查询值来源和窗口控制来源；经过 CTE/后续聚合仍可追溯。
- [ ] **O3（R4.1、R4.2）**：问题文档保留整类实际回测、独立检查及未验证清单，隔离通过后才合本地 master，生产图不变。

## 本仓职责

本仓承担 R1 的原生解析、全局压平身份、导出和 renderer 合同，并提供原 ETL 实际CLI回放与同一构建产物给 Neo4j 专用隔离图验收。本仓不部署、不推送，原 master 未提交的 INSERT/DDL 等变更保持保护。
