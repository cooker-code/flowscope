# UI Change Protocol

> 前端页面改造的必要流程。不走这个流程，需求会反复改不到点上。

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

# 用 GitNexus 找调用链
npx gitnexus query "audit file selector dropdown" --repo flowscope
```

不确认到文件级别，不开始改。

### 2. DOM 元素定位（哪个元素）

如果用户截图标红框，必须：
1. 在 Chrome 打开页面 → 手动 F12 检查元素 → 复制 data-testid 或 className
2. 或者用 `agent-browser snapshot -i` 获取 ref，确认是哪个 ref

**格式要求**：在 PRD 里写明：
```
目标元素：FileSelector.tsx Line 530，Audit History 区域的 <button> 元素
当前行为：点击后不调用 handleSelectAuditFile
期望行为：点击后调用 handleSelectAuditFile 并关闭 dropdown
```

### 3. API 数据先验证（数据层确认）

**血缘图逻辑问题，必须先验证 API 返回，再改前端。**

```bash
# 标准验证命令
curl -s -X POST http://localhost:3099/api/analyze \
  -H 'Content-Type: application/json' \
  -d "{\"files\":[{\"name\":\"xxx.sql\",\"content\":$(cat test-sql/xxx.sql | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],\"sql\":\"\"}" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(json.dumps(r['summary'], indent=2))"
```

如果 API 返回的 `result_json` 中数据不对 → **先修引擎（Rust），不改前端**。
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

每次前端改动后必须：
1. `cd app && ../node_modules/.bin/vite build` 构建通过
2. `cd app && npx tsc --noEmit` 类型检查通过
3. 更新 `embedded-app` → 重启服务 → 手动验证目标行为
4. 确认其他页面元素无破坏（截图对比）

**agent-browser 的限制**：Radix UI DropdownMenu 内部的 button 无法被 `click @ref` 可靠点击（DOM 会被提前删除）。需要通过手动 Chrome 操作或 JS 注入验证。
