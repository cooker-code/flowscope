# PRD: 修 vite dev 缺 API proxy 导致 audit 页崩溃

## Bug 描述

用户在 vite dev (`http://localhost:3000`) 打开 `/audit`，列表出现红色错误：

```
Unexpected token '<', "<!DOCTYPE "... is not valid JSON
```

DOM Path 落在 `AuditPage` 的 `<div class="text-destructive ...">`。

## 根因

`vite.config.ts` 没配 `server.proxy['/api']` → 所有 `/api/*` 请求走
vite 的 SPA fallback，返回 `index.html`（即 `<!DOCTYPE html>...`）。
前端 `await res.json()` 把 HTML 当 JSON 解析，立刻报错。

## 上下文：我刚刚踩过这个坑

上一个 task（`05-14-fix-audit-page-tz-and-filter-state`）做浏览器
MCP 验证时**临时**把 proxy 加到 `vite.config.ts`，验证完**回滚**了。
今天用户重启 vite dev → 立刻撞同一个坑。错误判断：把"开发态依赖"当
"临时调试配置"对待。

## 前端协议三要素

### 1. 组件文件定位

| 文件 | 行号 | 角色 |
|---|---|---|
| `app/vite.config.ts` | L9-L11 | 没配 `/api` proxy（根因） |
| `app/src/pages/AuditPage.tsx` | L116-L132 | `fetchList` 错误处理只显示原始异常文本，对配置类错误不友好 |

### 2. API 数据验证

```bash
# 直连 3099（CLI server）
curl -sI 'http://localhost:3099/api/audit?limit=1'
# HTTP/1.1 200 OK
# content-type: application/json   ← OK

# 经过 vite 3000（无 proxy 时）
curl -sI 'http://localhost:3000/api/audit?limit=1'
# HTTP/1.1 200 OK
# content-type: text/html           ← 撞 SPA fallback
```

**API 没问题**，是 dev server 的 routing 没把 `/api` 路由到上游。

### 3. 验证方式

- 改 `vite.config.ts` → 重启 vite → `curl localhost:3000/api/audit?limit=1`
  必须返回 JSON、`total > 0`
- Cursor IDE 浏览器 MCP 打开 `http://localhost:3000/audit`，列表必须有
  5000+ 行；时间列东八区；红色错误条不再出现

## 修复方案

1. **vite.config.ts** 永久加 proxy：

   ```ts
   server: {
     port: 3000,
     proxy: {
       '/api': process.env.FLOWSCOPE_API_PROXY ?? 'http://localhost:3099',
     },
   },
   ```

   用环境变量做 escape hatch，万一 CLI 跑在别的端口可以临时覆盖。

2. **AuditPage.fetchList** 加 Content-Type 检查兜底：当 `/api/*` 返回
   非 JSON（HTML 等）时，**不要**直接 `res.json()` 让浏览器抛
   `Unexpected token '<'`，而是给一条**可操作**的错误提示：
   "Audit API did not return JSON ... CLI 是否在 3099 / vite proxy 是否配了 `/api`"。

3. **Spec 沉淀**：把"vite dev 必须代理 /api 到 CLI"和"做 dev 配置改动
   时千万不要事后回滚"写进 spec / break-loop。

## 验收标准

1. `vite.config.ts` proxy 配置常驻、有解释性注释
2. `curl localhost:3000/api/audit?limit=1` 返回 JSON
3. 浏览器 MCP 在 `/audit` 上看到完整列表、无红色错误条
4. typecheck + lint 全绿
5. break-loop 文档 + spec 更新已提交

## 不修复项

- 不引入 react-query 或 fetch 抽象（避免 over-engineering）
- 不动 cli serve 模式（3099 单端口直接访问），它本来就 OK
