# 实施与验证

1. 在 `analyzer/statements.rs` 的 INSERT 分析结束后增加位置映射注释，并在 `ddl.rs` 标记 DDL schema 为顺序权威来源。
2. 在 `global.rs` 传播跨语句目标映射冲突。
3. 加入 Core 回归，覆盖显式字段、DDL、分区、未知 schema、冲突与 UNION 分支。
4. 构建 debug CLI 和 WebAssembly，冻结 CLI SHA 并同步 `packages/core/wasm` 与 `app/public/wasm`。
5. 父任务以该 CLI 对原 ETL 和隔离 Neo4j 完成批量回测。
