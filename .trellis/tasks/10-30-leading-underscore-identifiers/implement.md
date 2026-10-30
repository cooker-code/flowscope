## 实施顺序

1. 读取jsonl和Spec，精确复现根因。
2. 最小正式实现和有意义的语法/字段血缘回归；不修改原SQL。
3. 本类测试、diff/fmt检查，记录证据。
4. 主session集成、53份全量重放、独立字段验收和WASM检查后合master。

## 本分支结果（2026-10-30）

- 正式 Core 方言已只放宽 `_` 作为 Hive/Spark 标识符首字符；未改写审计 SQL。
- 单元和 `leading_underscore_lineage` 集成测试通过。后者覆盖 CTE、表/列别名、
  窗口值与控制依赖、显式 INSERT 目标映射，以及带/不带前导下划线 SQL 的物理 value roots 对照。
- 冻结的 35 份原 SQL native 回放为 **34 通过，1 等待复杂类型修复**。唯一未通过
  的 557564 已越过前导下划线首错，现停在 `ARRAY<STRUCT>` 的 `Expected: >, found: <`。
- 外部结构化证据：
  `/Users/blank/.codex/tmp/field-lineage-audit-20261029-01a1866f/cases/online-failures-20261030/replay-leading-underscore-core-20261030.json`。
- 未宣称完整两类集成、WASM 或 master 验收；这些由主 session 在合并后完成。
