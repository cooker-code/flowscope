# Fix edge operation propagation and filter scope contamination

## Goal

修复两个独立的引擎 bug：
1. 主表的 data_flow 边被错误地标注了 JOIN operation 类型
2. 派生表节点因 `qualified_name` 不含 scope 信息，导致不同 scope 的同名节点共享 FILTERS

## Bug 1：主表边错误带 JOIN operation

**根因（visitor.rs L642-663 + query.rs L436）**：
- `ctx.last_operation` 在 JOIN 循环处理后未清零，残留值被后续 `create_source_edge` 读取
- 派生表内部 subquery 含 JOIN 时，执行后 `last_operation` 被污染，随即给派生表 edge 赋了错误的 operation

**修复**：JOIN 循环末尾补 `self.ctx.last_operation = None`；派生表处理前后 save/restore `last_operation`。

**预期**：只有真正通过 JOIN 关键字连接的表才有 `operation`，FROM 主表 edge 的 `operation = null`。

## Bug 2：派生表 FILTERS 跨 scope 污染

**根因（visitor.rs L707 + context.rs L336-349 + query.rs L1341-1375）**：
- 派生表节点的 `qualified_name` 只是裸别名（如 `"a1"`），不含 scope 信息
- `apply_pending_filters` 用 `qualified_name` 做 key，导致不同 scope 的 `a1` 命中同一批 filters

**修复**：将 `apply_pending_filters` 的 key 改为 node_id（已含 scope），或将 `qualified_name` 改为含 scope 的唯一字符串。

## Acceptance Criteria

- [ ] `dwd_conan_user_order_da.sql` 中，主表 `new_device → 目标表` 的 edge `operation = null`
- [ ] INSERT 部分的 `a1` 节点 filters 只有 `order_status >= '2'` 等订单 filter，不包含 `rk = 1` 和 `time2dt`
- [ ] CTE 内部的 `a1` 节点 filters 仍为 `rk = 1` 和 `time2dt`（不受影响）
- [ ] `cargo test -p flowscope-core` 全量通过
- [ ] 5 个 test-sql 文件无回归（所有表有 edges，目标表有正确来源）
