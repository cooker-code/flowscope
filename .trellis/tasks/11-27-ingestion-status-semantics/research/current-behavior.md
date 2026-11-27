# 当前源码证据

取证基线：`754390a0accc8c3438c0b571da09e4b38c763364`，2026-11-27。

| 对象 | 位置 | 事实及影响 |
| --- | --- | --- |
| 六种标签 | `app/src/lib/lineage-api.ts` 的 `INGESTION_STATUS_LABELS` | 当前 failed 与 blocked 分开，unknown 有可见标签 |
| 状态说明与原因 | `app/src/components/GraphIngestionStatus.tsx` | `statusKey` 把缺失/陌生值变成 unknown；`canExplain` 排除 not_requested；committed 没有统计 |
| 审计表状态单元格 | `app/src/pages/AuditPage.tsx` | 只传入 lineage_status 与 policy_reason；queued 触发定时刷新 |
| 原因解释 | `app/src/lib/graph-ingestion-reasons.ts` | 支持质量检查、版本、策略、Neo4j 错误，但没有具体网络错误证据时不能推断 |
| 请求受理 | `crates/flowscope-cli/src/server/lineage.rs` 的 `accept` | 仅 parse_only 直接记录审计；publish 解析失败也可能进入事件队列 |
| 后台执行 | 同文件 `run` | 可重试错误保持 queued；配置/内容/最终存储错误为 failed；策略复核拒绝为 blocked_policy；正式写入经 Neo4jStore.apply |
| 审计状态拼装 | `crates/flowscope-cli/src/server/lineage_policy.rs` 的 `decorate_audit_rows` | 无身份/事件历史为 unknown，有身份而无事件默认为 not_requested，存储 outcome 优先 |
| 筛选 | `crates/flowscope-cli/src/server/audit.rs` 的 `LineageStatusFilter`、`LINEAGE_STATUS_SQL` | blocked 与 blocked_policy 目前合并；分页总数和行选择使用同一读事务，新的分类必须一起更新 |
| 存储结果 | `crates/flowscope-storage/src/model.rs` 的 `ApplyOutcome` | 只有 lineage_status、usage_status、reason，尚无变更统计 |
| 正式血缘更新 | `crates/flowscope-storage/src/neo4j.rs` 的 `publish` / `entity` / `project` | 版本拒绝与质量拒绝都返回 blocked；同版本同内容 already_current；业务对象复用 MERGE，关系按受影响旧/新事实重建 |
| 事务与恢复 | 同文件 `apply` / `receipt` / `apply_tx` | outcome_json 写在业务事务内，commit 后返回结果；错误 rollback；可复用回执保存统计 |
| 数据库验证 | `crates/flowscope-storage/tests/lineage.rs` | 现有隔离 Neo4j 测试默认 ignored，需明确配置空测试库；普通单测通过不能证明真实写入统计 |

现有约束见 `.trellis/spec/flowscope-cli/backend/lineage-policy.md` 的 Audit graph status contract、`audit-api-spec.md` 的 lineage_status 筛选，以及 `.trellis/spec/flowscope-storage/backend/index.md`。这些文档描述的是旧的六状态合同，实施时需要同步修订，不能当作新需求继续保留未知徽标。

本地 Git 只有 master 这一长期分支，没有 dev；主工作区干净但比 origin/master 多两个本地提交。任务从已核实的本地基线创建独立分支与工作区，未改写、推送或合并历史。

本机未检索到独立 `trellis-start` skill，已直接读取 `.trellis/workflow.md`、运行 `get_context.py` 并按现有 `trellis-brainstorm` 进入规划。主会话遵循 inline 模式，没有派发实现/检查子智能体。
