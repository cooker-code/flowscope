# Break the Loop: Audit Page Timezone & Filter State Loss

## Bug 1: UTC Timestamp Displayed Verbatim

### 1. Root Cause Category

- **Category**: E - Implicit Assumption
- **Specific Cause**: 前端直接渲染后端的 `ts` 字段（RFC 3339 UTC ISO 字符串
  `2026-05-14T09:34:56.736Z`），默认假设用户能"读懂"。东八区用户看到 09 误以为是
  早上 9 点（实际是当地下午 5 点）。后端 API 给的格式是对的（标准 UTC ISO），
  但前端没有承担"展示层本地化"的职责。

### 2. Why It Slipped In

- 开发时机器/容器/CI 大多走 UTC，开发者本地浏览器自动转换的体感缺失。
- 没有强制约定"所有 timestamp 显示必须经过本地化 helper"，第一版直接 `{r.ts}`
  通过了 code review。

### 3. Prevention Mechanisms

| Priority | Mechanism | Action | Status |
|----------|-----------|--------|--------|
| P0 | 提供共享 helper | `formatLocalTs` in `app/src/lib/utils.ts` | DONE |
| P1 | Spec 约束 | `state-management.md` 增加 "Timestamp Rendering" 段 | DONE |
| P2 | Lint 提示 | 未来可写 ESLint 规则禁止 `{*.ts}` 这种模式（暂不上） | TODO（按需） |

## Bug 2: Filter / Pagination Reset After Navigating to Lineage Detail

### 1. Root Cause Category

- **Category**: A - Missing Spec **+** B - Cross-Layer Contract（路由层与组件状态层）
- **Specific Cause**: 列表筛选 / 分页全部存在 `useState`，没同步到 URL。React Router
  跳详情时组件卸载、`useState` 销毁；回来时组件重建、state 重置为初始值。
  URL state 是 React Router 跳转中**唯一稳定可持久化**的层，但我们没用它。

### 2. Why It Slipped In

- 没有项目级的"列表型页面状态放哪"约定（`state-management.md` 文档原本为空模板）。
- 单页测试时只有"前进-看数据"，没人测过"前进-后退-看 UI 是否还原"，
  因此 useState 方案能通过 review。

### 3. Prevention Mechanisms

| Priority | Mechanism | Action | Status |
|----------|-----------|--------|--------|
| P0 | 把"列表型页面 filter + page 必须用 URL"写进 spec | 见 state-management.md | DONE |
| P0 | 详情→列表的跨页传递机制 | `localStorage[LAST_AUDIT_QUERY_KEY]` 持久化最近 list query | DONE |
| P1 | 共享 `useUrlState` Hook（后续如果出现第二个列表页） | 抽象 useSearchParams + debounce 模式 | TODO |
| P2 | 验证 checklist 加一条"前进→后退" | UI Change Protocol 加 SOP | TODO |

### 4. Systematic Expansion

- **Similar issues**: 当前项目除了 AuditPage 没有别的列表过滤页，但未来添加任何
  「带 filter + 分页 + 详情跳转」页面都要套同一套规则。
- **Design Improvement**: 第二个列表页出现时立刻抽 `useUrlState`，避免每个页面
  各自 `useSearchParams + useDebounce` 重写。
- **Process Improvement**: PRD 模板应加一行 "本页是否有跳出再返回的场景？
  若有：状态必须 URL 同步"。

### 5. Knowledge Capture

- [x] 更新 `.trellis/spec/flowscope-app/frontend/state-management.md`
- [x] 在 `state-management.md` 加 "Timestamp Rendering" 与 "URL as Source of Truth"
- [ ] 后续出现第二个列表页时，抽 `useUrlState` 并回填 spec 示例
