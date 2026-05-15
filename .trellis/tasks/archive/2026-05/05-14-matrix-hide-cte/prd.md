# Matrix 隐藏 CTE 开关与传递性依赖补全

## Goal

在 Matrix 视图的 Tables 子模式下，**默认隐藏 CTE 节点**，并提供工具栏开关供用户按需展开。隐藏时通过 BFS 传递性补全，避免「仅通过 CTE 链相连」的物理表对依赖在矩阵中消失。

## Background

- Matrix 当前用 `isTableLikeType()` 收集表节点，把 `'table' | 'view' | 'cte'` 一锅端到矩阵里（`packages/react/src/utils/matrixUtils.ts:76`）。
- 截图实测：典型多 CTE 脚本里 CTE 节点能占矩阵 ≥30% 的行/列，把真物理表标签挤变形、稀释信号。
- FlowScope 数据模型已经承认 CTE 不是物理对象（`audit-api-spec.md` 中 `table_count` 只计 `Table | View`）。
- CTE 在跨脚本对比、聚类、heatmap 这些 Matrix 核心场景里没有语义价值。

## Requirements

### 数据层（matrixUtils）

- `MatrixData` 维持现接口，不破坏 Worker 协议。
- Worker payload 新增 `cteItemSet: string[]`（序列化用 array，主线程转 Set），用于主线程识别哪些 item 是 CTE。
- `extractTableDependenciesWithDetails` 已经会经由 column-level 路径建立 `cte→cte`、`cte→table`、`table→cte` 三种依赖；不修改这部分逻辑。
- 新增主线程工具函数 `collapseCteFromMatrix(matrix, cteSet) → MatrixData`：
  - 过滤掉 CTE item 行/列；
  - 对每对剩余的物理表 `(A, B)`，若原 cells 中 `A→...→B` 仅经由 CTE 链可达（且原本无直接 write/read），则在新矩阵中补一条 `write` 边，details 用 transitive 链上首尾任一段的 details（标记 `indirect: true` 字段供后续 tooltip 区分）。
  - 已存在的直接边保留原样。

### 状态管理

- `MatrixViewControlledState` 新增 `hideCte: boolean`，默认 `true`。
- 走 `useImmediateControlledMatrixState` pipeline，可被外部 controlled。

### UI

- Tables 工具栏（`subMode === 'tables'`）新增一个开关按钮（lucide `Layers` 图标），位置紧挨 Heatmap / Cluster / Complexity 这一组。
- Scripts 子模式下不显示该按钮。
- 按下时切换 `hideCte`，开启状态视觉与其他 toggle 一致（`bg-cyan-100 text-cyan-600 ring-1 ring-cyan-500`）。
- Tooltip 文案中文 + 英文：
  - 标题：`Hide CTE Aliases`
  - 说明：`Collapse CTE rows/columns and connect physical tables transitively.`

### 渲染层

- `MatrixView` 在 `fullMatrixData` 之后新增一个 useMemo 衍生的 `displayMatrixData`，根据 `hideCte && subMode === 'tables'` 决定是否调用 `collapseCteFromMatrix`。
- 后续所有 `sortedItems` / 过滤 / 渲染均基于 `displayMatrixData`。
- legend 区在 `hideCte` 开启时显示一个 `CTE Hidden` 状态标识。

## Acceptance Criteria

- [ ] 默认进入 Matrix-Tables 视图，CTE 节点（`a / before / t1` 这类）不出现在行列里。
- [ ] 工具栏 `Layers` 按钮可以一键切换显示/隐藏 CTE。
- [ ] 隐藏 CTE 时，原本通过 CTE 链相连的物理表之间能在矩阵里看到 `write` 箭头。
- [ ] Scripts 子模式工具栏不显示该按钮。
- [ ] 单测覆盖：`collapseCteFromMatrix` 至少覆盖 3 种场景：
  - 物理表 → CTE → 物理表（间接，应补全）；
  - 物理表 → CTE → CTE → 物理表（多跳间接）；
  - 物理表 → 物理表 同时也途径 CTE（直接边优先，不重复补）。
- [ ] `yarn workspace @pondpilot/flowscope-react lint && typecheck && test` 全部通过。

## Notes

- 不动 Rust 引擎、不动 worker 内 build 逻辑，纯前端聚合 + 渲染层改造。
- `details.indirect` 字段为可选扩展，TS 类型在 `TableDependencyWithDetails` 上标记为 `indirect?: true`。
