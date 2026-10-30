## Goal

1. 修复正式FlowScope Core的Hive入口的Spark复杂类型兼容，保持原SQL正文和字段依赖语义。

## Requirements

- R1：范围为11份首错及557564后续错误。以今日审计冻结原文为输入，不通过改写原文或吞异常冒充修复。
- R2：解析、字段值来源、窗口控制和目标位置映射回归正确；不能丢字段或混入控制来源。
- R3：PHP完全排除；FROM VALUES、exists、View COMMENT和多个GROUPING SETS不实施。
- R4：独立worktree，检查通过后由主session集成到master；不push、不部署、不写生产。

## User-visible Outcomes

- [ ] O1：本类正式程序修复及最小回归通过。
- [ ] O2：今日非PHP53SQL全量回放，本类及共享输入的血缘逐项核对，其余四类保留明确失败。
- [ ] O3：合入master，原有WIP受保护。
