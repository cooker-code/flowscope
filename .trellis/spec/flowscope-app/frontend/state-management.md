# State Management

> 前端状态管理约定。**违反任何一条都属于 bug，必须修。**

---

## 状态分类

| Category | Storage | When |
|----------|---------|------|
| **URL state** | `useSearchParams` | 列表页 filter / 分页 / 排序、详情页 id、Sheet/Tab 当前选中项 |
| **Persistent UX state** | `localStorage` | 跨页导航需要"恢复用户视角"的少量元信息（如最近一次列表 query） |
| **Component-local** | `useState` | 输入框正在键入的值、Modal 开关、动画状态等不需要跨刷新/跨页恢复的瞬态 |
| **Server cache** | 直接 fetch + 局部 `useState`/`useMemo` | 当前项目暂不引入 react-query；远端数据按页拉取，URL 变化时重拉 |

---

## URL as Source of Truth（MANDATORY for list pages）

**任何"带 filter / 分页 / 排序"的列表页面，过滤条件和分页必须存在 URL `?key=value` 里。**

### 为什么

`react-router` 在路由切换时会卸载组件，`useState` 状态丢失。用户从列表点进详情、
再点回列表，期望条件和页码都保持。把状态放 URL：
1. 跨路由切换天然保活（URL 不变就保留，URL 变了浏览器 Back/Forward 也能复原）
2. 可分享：把 URL 发同事，对方看到的就是同一个过滤视图
3. 可深链：从外部直接打开预过滤的 URL
4. 可调试：从地址栏一眼看出当前 filter

### 标准模式

```tsx
import { useSearchParams } from 'react-router-dom';
import { useDebounce } from '@/hooks/useDebounce';

const ANY = '__any__';

export function MyListPage() {
  const [searchParams, setSearchParams] = useSearchParams();

  // 1. 从 URL 读 filter / pagination 当前值
  const sqlType = searchParams.get('sql_type') ?? ANY;
  const page = Math.max(1, parseInt(searchParams.get('page') ?? '1', 10) || 1);

  // 2. 文本输入框：本地 state 即时回显 + debounce 后写入 URL
  //    （否则每输一个字符就改 URL，污染历史栈）
  const [keywordInput, setKeywordInput] = useState(searchParams.get('keyword') ?? '');
  const debouncedKeyword = useDebounce(keywordInput, 300);
  useEffect(() => {
    if (debouncedKeyword !== (searchParams.get('keyword') ?? '')) {
      updateParams({ keyword: debouncedKeyword }, { resetPage: true });
    }
  }, [debouncedKeyword]);

  // 3. setter helper：清掉等于默认值的参数，保持 URL 干净
  const updateParams = (updates, opts) => {
    setSearchParams(prev => {
      const next = new URLSearchParams(prev);
      for (const [k, v] of Object.entries(updates)) {
        if (v === null || v === '' || v === ANY) next.delete(k);
        else next.set(k, v);
      }
      if (opts?.resetPage) next.delete('page'); // filter 变了就回第 1 页
      return next;
    }, { replace: true });
  };
}
```

### 必须遵守

- 默认值（`__any__`、空字符串、`page=1`）**不写入 URL**，URL 保持干净。
- 改 filter 时 `page` 必须重置为 1（业务语义：换条件就翻第一页）。
- `setSearchParams` 用 `{ replace: true }` 避免每次输入就压一条历史。
- 文本输入框走"本地 state + debounce → URL"，避免按一次 Back 才退一个字符的体验。

### 反例（禁止）

```tsx
// ❌ 列表页 filter 直接 useState —— 跳详情回来后丢失
const [sqlType, setSqlType] = useState(ANY);
const [page, setPage] = useState(1);
```

> 历史教训：`AuditPage` 最初这么写，用户从列表点 Open lineage 进详情，
> 再 Back to audit list 时所有筛选条件被重置为 Any、回到第 1 页。
> 见 `.trellis/tasks/archive/2026-05/05-14-fix-audit-page-tz-and-filter-state/`.

---

## Cross-Page Hand-off via localStorage

**用户在 A 页面设了视角，跳到 B 详情页后点"返回 A"时，要还原 A 的视角。**

如果 B 是从 A 推进来的（A 的 URL 还在 history 上层），`navigate(-1)` 即可。但 B
**也可能是从外部直接打开**（分享链接、深链），这时 `navigate(-1)` 没有意义。

折中方案：A 在每次 URL 变化时把当前 query 写到 `localStorage`，B 的"返回 A"按钮
读这个 key。

```tsx
// AuditPage.tsx
export const LAST_AUDIT_QUERY_KEY = 'flowscope.audit.lastListQuery';

useEffect(() => {
  const params = new URLSearchParams();
  for (const k of URL_PARAM_KEYS) {
    const v = searchParams.get(k);
    if (v !== null && v !== '') params.set(k, v);
  }
  try {
    window.localStorage.setItem(LAST_AUDIT_QUERY_KEY, params.toString());
  } catch {} // private mode / quota
}, [searchParams]);

// SqlPreviewCapsule.tsx
const saved = window.localStorage.getItem(LAST_AUDIT_QUERY_KEY) ?? '';
navigate(saved ? `/audit?${saved}` : '/audit');
```

### 必须遵守

- `localStorage` 读写必须 `try/catch`（隐私模式、配额满会抛）。
- key 用 `<app>.<domain>.<purpose>` 三段命名，避免冲突。
- 只存导航需要的最小信息，不要把全部应用状态都丢进去。

---

## Timestamp Rendering（MANDATORY）

**任何来自 API 的 ISO 时间戳，渲染前必须经过 `formatLocalTs`。**

后端用 UTC（RFC 3339 `Z` 后缀）是对的；浏览器默认会用本地时区，但前端必须**主动
触发本地化转换**，不能裸渲染。

```tsx
// ✅
import { formatLocalTs } from '@/lib/utils';
<td title={r.ts}>{formatLocalTs(r.ts)}</td>

// ❌ 裸渲染 ISO 字符串
<td>{r.ts}</td>
```

### 必须遵守

- 用 `formatLocalTs(iso)` 而不是各处 `new Date(iso).toLocaleString()`，确保
  全站时间格式一致（`YYYY-MM-DD HH:MM:SS`）。
- 把原始 ISO 放 `title` 属性，鼠标 hover 可以看到原值（调试 / 跨时区核对）。
- 详情页 / Sheet / Tooltip 等所有显示时间的地方都要走这个 helper。

> 历史教训：`AuditPage` 列表 + `SqlPreviewCapsule` Sheet 都直接渲染 `r.ts`，
> 东八区用户看到 `2026-05-14T09:34:56.736Z` 以为是上午 9 点。
> 见 `.trellis/tasks/archive/2026-05/05-14-fix-audit-page-tz-and-filter-state/`.

---

## When to Use Global State

当前项目使用 React Context (`@/lib/project-store`) 作为唯一的全局 store。
**新功能默认不要加全局 state**，先问：

1. 这个状态会被多少个组件读？只有 1-2 个 → 用 props / URL。
2. 这个状态变了会触发多少组件重渲染？> 5 个 → 才考虑全局。
3. 这个状态需要持久化吗？需要 → URL（视角）/ localStorage（偏好）/ 后端（账号关联）。

---

## Dev Environment Contract（MANDATORY）

**前端在 dev 模式下假设 `/api/*` 已经被 Vite 代理到 CLI HTTP server。**

### 拓扑

```
浏览器 ──HTTP──> Vite dev (3000) ──/api/*──> CLI serve (3099)
                                 └──/*────> React SPA
```

`app/vite.config.ts` 里有常驻 proxy：

```ts
server: {
  port: 3000,
  proxy: {
    '/api': process.env.FLOWSCOPE_API_PROXY ?? 'http://localhost:3099',
  },
},
```

CLI 跑在别的端口时用 `FLOWSCOPE_API_PROXY=http://localhost:9099 yarn dev`。

### 启动顺序

1. 先起 CLI：`just cli-release -- serve --audit-log /tmp/flowscope-audit.db --port 3099`
2. 再起前端：`yarn workspace @pondpilot/flowscope-app dev`（或 `cd app && yarn dev`）

如果先起 vite 再起 CLI 也 OK（vite proxy 是按请求建立连接的），但 CLI 没起来时
前端会看到下面的友好错误。

### 错误处理约定：HTML fallback 检测

**用 `fetch('/api/...')` + `res.json()` 的代码必须先检查 `content-type`。**
否则 dev 配置错（proxy 没生效 / CLI 没起）时 `res.json()` 会抛
`Unexpected token '<', "<!DOCTYPE "...`，用户看了一头雾水。

```tsx
const res = await fetch('/api/audit?...');
if (!res.ok) { setError(`Request failed (${res.status})`); return; }

const contentType = res.headers.get('content-type') ?? '';
if (!contentType.includes('application/json')) {
  const preview = (await res.text()).slice(0, 60).replace(/\s+/g, ' ');
  setError(
    `API did not return JSON (got: "${preview}…"). ` +
    'Check CLI is running on http://localhost:3099 and Vite has /api proxied.'
  );
  return;
}
const data = await res.json();
```

> 历史教训：上一个 task 验证完误把 proxy 当临时调试配置回滚了，下一次
> `yarn dev` 立刻整页崩溃。
> 见 `.trellis/tasks/archive/2026-05/05-14-fix-vite-dev-api-proxy/break-loop.md`.

### 改 dev 配置时的判定标准

每次动 `vite.config.ts` / `Cargo.toml` / `package.json` 的 dev/build 字段，
**问一句**：

> 如果删掉这一行，**下次别人 / CI 起 `yarn dev` 还能正常工作吗？**

- 不能 → 这是长期依赖，必须常驻 + 注释解释 + 写进 spec。
- 能 → 才是真正的"临时调试配置"，可以回滚。

---

## Common Mistakes

| 反模式 | 后果 | 正确做法 |
|--------|------|----------|
| 列表页 filter 用 `useState` | 跳详情回来丢失 | `useSearchParams` |
| 输入框每个字符都写 URL | 历史栈污染、Back 体验差 | 本地 state + `useDebounce` |
| 默认值（`Any`、`1`、空字符串）写入 URL | URL 又长又脏 | setter 自动剔除等于默认值的项 |
| 裸渲染 API timestamp | 跨时区用户看错时间 | `formatLocalTs(iso)` |
| `localStorage` 不 `try/catch` | 隐私模式 / 配额满直接报错 | 必须包 `try { ... } catch {}` |
| `vite.config.ts` 缺 `/api` proxy | 整页爆 `Unexpected token '<'` | proxy 常驻 + fetch 端 Content-Type 兜底 |
| 把 dev 必需配置当临时调试 hack 回滚 | 下次 `yarn dev` 立刻坏 | "删了还能工作吗"判定标准 |
