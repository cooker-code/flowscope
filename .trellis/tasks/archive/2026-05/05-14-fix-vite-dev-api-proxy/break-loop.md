# Break the Loop: Vite Dev Missing `/api` Proxy

## 1. Root Cause Category

- **主类别**: A - Missing Spec（"dev 环境怎么搭"没有文档约定）
- **次类别**: E - Implicit Assumption（"agent 验证完了把配置回滚"这一假设
  本身错——proxy 不是临时调试配置，是长期开发依赖）

**具体根因**：

1. `vite.config.ts` 里没配 `/api` proxy，但 `app/src` 多处 `fetch('/api/...')`
   依赖它，整个项目**默认前后端同源**（即 CLI serve 模式）。
2. 我在上一个 task 做浏览器 MCP 验证时，**临时**给 vite 加了 proxy，验证完
   写了一句 "回滚临时 proxy 配置" 就 revert 了。本质判断错误：把
   "开发态唯一可行的配置"当成"调试用的脏代码"。

## 2. Why The Previous "Fix" Failed

| 阶段 | 行为 | 错误判断 |
|------|------|----------|
| 验证前 | 在 vite.config.ts 加 proxy `/api → 3099` | 标记"临时/验证用" |
| 验证后 | 把 proxy 删掉 | 错把"dev 必需"当"调试 hack" |

**反思**：当一个配置**消失后立刻打破 dev 环境**，它就不是"临时"的。
判定标准应该是：

> 如果删了这个配置，下次任意开发者起 `yarn dev` 还能不能正常工作？
> 不能 → 必须常驻 + spec 文档化。

## 3. Prevention Mechanisms

| Priority | Mechanism | Action | Status |
|----------|-----------|--------|--------|
| P0 | vite proxy 常驻 + 注释解释为什么 | `app/vite.config.ts` | DONE |
| P0 | fetch 兜底：Content-Type 不是 JSON 时给 actionable hint | `AuditPage.fetchList` | DONE |
| P0 | Spec：dev 环境拓扑 + "改 dev 配置时的判定标准" | `frontend/state-management.md` § Dev Environment | DONE |
| P1 | README / AGENTS 加 dev 启动顺序：先起 CLI 再起 vite | 后续合入主 README | TODO |
| P2 | E2E smoke：CI 跑 `curl localhost:3000/api/health` 验证代理 | 可加到 `just check` | TODO |

## 4. Systematic Expansion

- **Similar issues**:
  - `SqlPreviewCapsule.loadDetail` / `useLoadAuditRecord` / `FileSelector` 同样
    `fetch('/api/...')`，同样在没 proxy 时会爆 `Unexpected token '<'`。
    本次只给 AuditPage 加了 Content-Type 兜底（最常用入口），其余暂不动，
    因为根因已被 vite proxy 解决，兜底是"安全网"不是必需。
- **Design improvement**:
  - 出现第 5 个 `/api/*` fetch 时，抽 `fetchJson` helper 把 Content-Type
    检查 + 错误格式化集中处理。现在 4 个还能忍。
- **Process improvement**:
  - 改 dev/build 配置时强制问一句："这个配置**删掉**之后下次启动还能 work 吗？"
  - PRD 模板加一行 "本次改动是否需要更新 `vite.config.ts` / `Cargo.toml` 等
    build/dev 配置？若需要，新加的项是临时验证还是长期依赖？"

## 5. Knowledge Capture

- [x] 更新 `app/vite.config.ts`：常驻 proxy + env escape hatch + 解释性注释
- [x] 强化 `app/src/pages/AuditPage.tsx`：fetchList 加 Content-Type 兜底
- [x] 写本 `break-loop.md` 记录因果链
- [x] 把 dev 环境约定写入 `state-management.md`（§ Dev Environment Contract）
- [ ] 后续把"dev 启动顺序"写进 README（不在本次 scope，标 TODO）
