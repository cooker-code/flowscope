# PRD: 修审计页时区本地化和筛选状态保持

## Bug 描述（来自用户报告）

1. **时区显示成 UTC**：审计列表「Time」列显示 `2026-05-14T09:34:56.736Z`，
   用户在东八区期望看到 `2026-05-14 17:34:56`。
2. **筛选状态丢失**：在列表里筛 `Success=Success`、设了页码、文件名等条件，
   点 `Open lineage` 进详情看血缘，再 `Back to audit list` 回来时，**所有
   筛选条件被重置为 Any、页码回到 1**。

## 前端协议三要素（CLAUDE.md MANDATORY）

### 1. 组件文件定位（精确到行号）

| Bug | 文件 | 行号 | 当前代码 |
|---|---|---|---|
| 时区 | `app/src/pages/AuditPage.tsx` | L287 | `{r.ts}` 原样渲染 ISO 字符串 |
| 筛选状态 | `app/src/pages/AuditPage.tsx` | L42-L48 | 6 个 filter + page 全是 `useState`，未同步到 URL |
| 跳详情 | `app/src/pages/AuditPage.tsx` | L105-L107 | `navigate('/?auditId=${id}')` 不带 referrer |
| 回列表 | `app/src/components/SqlPreviewCapsule.tsx` | L89-L91 | `navigate('/audit')` 不带 query |

### 2. API 数据先验证

- **时区**：`/api/audit` 返回 `ts: "2026-05-14T09:34:56.736Z"` —— 是
  RFC 3339 / ISO 8601 标准格式，**API 正确**，不需要改后端。
  本地化属于纯前端职责。
- **筛选**：API 接受 `from/to/sql_type/success/file_name/keyword` query
  参数，前端 `queryString` (L60-L76) 正确构造请求。**API 正确**，bug 在
  状态持久化层。

### 3. 验证方式

Cursor IDE 浏览器 MCP（基于 Playwright，可靠点击 Radix UI Select）：

- 启动 vite dev（已有的话直接用）`http://localhost:5173/audit`
- 或用 `http://localhost:3099/audit`（serve 模式，CLI 内嵌静态资源）
- 操作脚本（验证 SOP）：
  1. 设 `Success=Success`、`SQL type=INSERT`、`File name=ads_eng`、`Page=3`
  2. 点行的 `Open lineage` → 进详情
  3. 点 `Back to audit list`
  4. **断言**：URL 含 `?success=true&sql_type=INSERT&file_name=ads_eng&page=3`；
     筛选 UI 控件显示对应值；分页停在 Page 3
- 时区验证：检查列表第一行 Time 列字符串符合 `YYYY-MM-DD HH:MM:SS`
  且小时部分等于 UTC 小时 + 8（东八区）。

## 修复方案

### Fix 1：时区本地化

把 L287 改成：

```tsx
<td className="px-3 py-2 whitespace-nowrap font-mono">{formatTs(r.ts)}</td>
```

`formatTs` 用 `Intl.DateTimeFormat` 或者 `new Date(...).toLocaleString` 输出
`YYYY-MM-DD HH:MM:SS`（默认本地时区，不依赖用户系统 locale 字符串差异）。

### Fix 2a：filter / page 同步到 URL

用 `useSearchParams`：

- 6 个 filter + `page` 全部从 URL 读，setter 改成 `setSearchParams`
- 默认值（ANY / 1 / 空字符串）不写入 URL（保持 URL 干净）
- 进页时初始 state 从 `searchParams` 反序列化

### Fix 2b：跳详情 + 回列表保留 query

- `openLineage(id)`：把当前 `searchParams` 序列化到 `localStorage.setItem('lastAuditListQuery', ...)` **或** 直接通过 `navigate` 的 `state` 传递。
- `SqlPreviewCapsule` 的 `Back to audit list`：跳 `/audit?<saved query>`。
- 选 **localStorage 方案**：简单可靠，跨刷新都行；不污染 router state。

## 验收标准

1. `cargo` / `yarn workspace app` 编译 + lint + typecheck 全绿
2. Cursor IDE 浏览器 MCP 跑通验证 SOP 两个场景：
   - 时区：Time 列等于 UTC + 8h 的本地字符串
   - 筛选保持：设条件 → 进详情 → 回列表 → URL + UI + 分页一致
3. 走 `/trellis-break-loop` 把"UI 列表筛选状态必须 URL 同步"沉淀到
   `.trellis/spec/flowscope-app/frontend/` 的 spec 里

## 不修复项

- API 时区格式（保持 UTC ISO 标准）
- 跨用户/跨浏览器持久化（不做服务端 user preference，本地够用）
