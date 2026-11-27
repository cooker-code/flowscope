# UI Change Protocol

> 前端页面改造的必要流程。不走这个流程，需求会反复改不到点上。

本规范遵循 [AGENTS.md 的最小必要验证原则](../../../../AGENTS.md#按改动范围做最小必要验证)。按本次改动选择检查，定位元素或修改展示本身不要求启动后端、Docker 或完整链路。

---

## 问题根因

前端需求模糊的三大症状：
1. 说"这个地方有问题"但没有指定具体元素 → AI 猜错位置
2. 截图有红框标注但 headless 浏览器看不到渲染结果 → 无法自动验证
3. 需求描述的是"期望状态"而不是"当前是什么、应该改成什么" → 难以定位

---

## 必须在动手前明确的三件事

### 1. 组件定位（哪个文件）

凡是页面改动，必须先确认组件文件路径。方法：

```bash
# 用组件名/文本/类名搜索
grep -r "Audit History\|handleSelectAuditFile\|FileSelector" app/src --include="*.tsx" -l

# 用代码检索找调用链
rg -n "Audit History|handleSelectAuditFile|FileSelector" app/src
```

不确认到文件级别，不开始改。

### 2. DOM 元素定位（哪个元素）

用户截图标红框时，先通过源码确认组件、目标元素与稳定标识（如 data-testid）。只有源码无法明确定位，或需要观察实际布局/交互时，才打开目标页面取得 DOM ref 或截图；不因收到截图就启动浏览器或完整服务。

本轮使用 Trellis 任务时在 PRD 中记录，否则在交付说明中记录；不为定位单独创建任务：
```
目标元素：FileSelector.tsx Line 530，Audit History 区域的 <button> 元素
当前行为：点击后不调用 handleSelectAuditFile
期望行为：点击后调用 handleSelectAuditFile 并关闭 dropdown
```

### 3. API 数据先验证（数据层确认）

**血缘图数据逻辑问题，先确认数据来源和 API 返回，再决定修改哪一层。** 接口结构和语义未变化时，可复用已有接口测试或可信响应；纯文案、顺序、颜色修改不要求重新请求分析接口。

```bash
# 需要验证真实分析接口时的示例命令，不是每次 UI 修改的前置步骤
curl -s -X POST http://localhost:3099/api/analyze \
  -H 'Content-Type: application/json' \
  -d "{\"files\":[{\"name\":\"xxx.sql\",\"content\":$(cat test-sql/xxx.sql | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],\"sql\":\"\"}" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(json.dumps(r['summary'], indent=2))"
```

如果 API 返回的 `result_json` 中数据不对 → **先定位并修正产生错误的数据层，再改前端**。
如果 API 数据正确但图显示不对 → 才改前端渲染逻辑。

---

## Trellis PRD 前端任务模板

```markdown
## 目标元素
- 文件：`app/src/components/FileSelector.tsx`
- 位置：Line 530，Audit History section 的 button
- data-testid / ref / className：（从 snapshot -i 获取）

## 当前行为
（截图 + 描述）

## 期望行为
（截图 + 描述，或文字）

## API 数据验证结论
- [ ] 已用 curl 验证 API 返回正确
- [ ] API 有问题 → 先修 Rust 引擎
- [ ] API 正确 → 修前端渲染

## 验证方式
（手动 Chrome 操作步骤，或 agent-browser 命令）
```

---

## 前端改动的回测要求

按受影响行为选择最小检查：

- 纯文案、顺序、颜色和提示展示：静态核对及已有相关组件测试，按需运行类型或样式检查。没有明确风险时，不为低影响展示修改新增重复测试。
- 组件状态、事件或交互：运行相关组件测试；组件测试不能覆盖的布局、焦点、触屏等问题，再做一次目标浏览器验证。可以使用受控响应，不要求附带真实数据库。
- 接口字段或前后端契约：先验证变更入口，再接 UI；解析状态、筛选和分页优先使用临时 SQLite 的后端测试，不因状态来自数据库就启动 Neo4j。
- 构建配置、资源加载、打包交付或明确验收要求：运行 `cd app && yarn build`。该命令已包含 TypeScript 编译时，不为重复确认同一类型结果再运行 typecheck。
- **仅当验证目标是 CLI 嵌入页面时**，重新构建前端、同步资产、编译 serve CLI，并启动任务拥有的服务验证。普通 UI 修改不自动触发这条链路；前端展示验证也不自动触发 Docker。

**需要验证 CLI 嵌入或打包时的顺序**（见 AGENTS.md "CLI Serve Mode Build Order"）：
```bash
cd app && yarn build                                     # 1. 构建前端 bundle → app/dist/
# 2. 按项目资产同步步骤将 app/dist 同步到 CLI 嵌入目录
cargo build -p flowscope-cli --features serve             # 3. embed 进 binary
# 4. 使用独占端口启动本任务服务；结束后仅停止并核实本任务的 PID
```

**浏览器自动化分两档**：

| 工具 | Radix DropdownMenu / Popover 内的 button | 备注 |
|------|------------------------------------------|------|
| Cursor IDE 浏览器 MCP（`cursor-ide-browser`，基于 Playwright） | ✅ 可靠 | snapshot 拿 ref → click，DOM detach 前 Playwright 会等待事件冒泡完成 |
| 外部 `agent-browser` CLI | ❌ 不可靠 | DOM 会在 click 落地前被 Radix 卸载，需手动 Chrome 或 JS 注入 |

只有已确定需要浏览器验证时，才按当前平台能力选择工具；上述工具说明不构成默认启动浏览器或端到端链路的要求。验证通过后复用结果，新增修改只复验受影响行为；实际启动的资源仍须清理并核实退出。
