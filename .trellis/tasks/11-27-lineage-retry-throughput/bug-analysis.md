# Bug Analysis: 651353 因事实扫描和逐条交互反复超时

## 1. Root Cause Category

- E / Implicit Assumption：已有 fact_key 唯一索引被误当作能覆盖 edge_key 和 scope_key/active 查询；实际上每条关系都会扫描全部 LINEAGE_FACT。
- D / Test Coverage Gap：原有小图契约测试验证了业务正确性，没有包含真实规模背景事实和 30 秒 worker 限制。
- A / Missing Spec：初始化索引、批量交互和分阶段诊断没有明确合同。

线上 PROFILE 有 94,555 行 NodeByLabelScan；真实解析规范化为 494 实体、657 事实。旧版隔离更新耗时 32.58–38.19 秒，HTTP 重现约 30 秒后 queued、attempts+1。线上补索引后，旧 worker 自动将同一事件提交，最终 attempts=644。

## 2. Why Fixes Failed

本轮业务修复无需多轮改动：先验证索引与批量方案，再在线上只加索引即可恢复。不能把原先的通用错误当成网络故障，也没有通过增加 worker、增加 apply 超时或人工改状态掩盖失败。

额外 HTTP 压测准备发现共用 Cargo target 的跨 worktree 构建会残留混合产物。那些初次结果作废；清理受影响的构建包并重新构建，核对旧/新存储索引和 worker 诊断标记后，才冻结二进制重测。没有把无效对比计入报告。

## 3. Prevention Mechanisms

| 优先级 | 机制 | 具体动作 | 状态 |
| --- | --- | --- | --- |
| P0 | 初始化合同 | 三个与过滤条件对应的索引及 ONLINE 等待 | 已实现，线上索引已生效 |
| P0 | 原子批量写 | 256 条一批、有序锁、数量断言、同一事务 | 已实现并验证 |
| P0 | 故障诊断 | connect/receipt/apply/policy_recheck 原因、错误码、耗时及状态保存失败日志 | 已实现并验证 |
| P0 | 回归 | 真实规模与 HTTP 超时复现、跨批次宽表、共享来源和回滚 | 已执行 |
| P1 | 构建取证 | 冻结旧/新二进制并确认版本标记，避免共用 target 污染 | 已用于有效对比 |

## 4. Systematic Expansion

- 同类问题：来源事实替换和目标生产来源汇总也需要专用索引，不能只优化 edge_key。
- 设计：保留单 worker；缺少原子领取时不可直接复制 next() 循环。当前主要成本在每个事件内部。
- 计数：正式关系 frequency 是去重 SQL 哈希数，个人提交按 QUERY_EVENT 聚合；后台重试不增加个人提交数。
- 运维：索引准备与单笔 apply 的预算分开，避免大库建索引反复落入 8 秒连接重试。

## 5. Knowledge Capture

- 已新增 `.trellis/spec/flowscope-storage/backend/ingestion-performance.md`，包含 7 节可执行合同。
- 已更新 storage index 和 CLI lineage-policy 的入口。
- 已更新入图原理与个人查询指南、CHANGELOG 和验证记录。
- 本仓库不存在 `src/templates/markdown/spec/`，没有创建不适用的 Trellis 模板源目录。
