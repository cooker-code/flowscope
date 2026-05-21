# Break-Loop: Duplicate Filters in Multi-Occurrence Table Nodes

## Bug Summary
TableNode FILTERS 区域对同一 SQL statement 内被多次引用的表显示重复 filter。

## Root Cause Category
**Backend data contract violation + missing frontend sanitization**

Rust 核心在同一 statement 内对同一张表被多次引用时，把每个引用的 WHERE predicates 全部追加到 `node.filters` 数组，没有去重。例如表被引用 2 次且各有 4 个 filter，`node.filters` 就包含 8 条（4 重复）。前端 `buildTableNodeData` 直接透传 `node.filters` 给 `TableNodeData`，渲染层没有去重。

## Why First Fix Failed
**误判了问题层**。看到 OccurrenceCycler 显示 `◀ 1/2 ▶` 就联想到「跨 statement 合并导致重复」，直接修改了 `mergeNodesForNavigation`（跨 statement 合并路径），但实际上这是「同一 statement 内两个子查询引用同一张表」的场景。跨 statement 合并路径根本没有被触发。

**错误调查顺序**：猜测 → 改代码 → 失败 → 查 API 数据 → 发现根因。

**正确调查顺序**：查 API 数据（`test/ui_response.txt` 已在 IDE 里打开！）→ 定位问题层 → 改代码。

## Prevention Mechanism
1. 任何 UI 数据异常，**第一步先检查 API 返回的原始数据**，确认问题在前端还是后端
2. `node.filters` 是 backend 输出的 public contract，前端 display 层应做防御性去重
3. 添加 `deduplicateFilters()` helper 作为 display 层的 sanitization，保证 `node.filters` 里的重复不会传播到 UI

## Files Changed
- `packages/react/src/utils/graphBuilders.ts` — `deduplicateFilters()` + apply to `buildTableNodeData`
- `packages/react/src/workers/graphBuilder.worker.ts` — same
- `packages/react/src/utils/nodeOccurrences.ts` — per-occurrence filters in metadata (cross-statement future use)
- `packages/react/src/components/TableNode.tsx` — `focusedOccurrenceIndex` + `activeFilters`
- `packages/react/src/types.ts` — `occurrenceFilters?: FilterPredicate[][]`
