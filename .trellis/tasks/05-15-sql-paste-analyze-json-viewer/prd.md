# PRD: SQL 快速粘贴分析 + JSON 结果查看器

## 背景

当前 UI 存在两个使用摩擦点：
1. 用户想分析一条 SQL 片段，但必须先创建「项目 → 文件 → 粘贴 → 运行」，流程冗长
2. 用户想对照 `/api/analyze` 原始 JSON 结构理解 UI 上的各分析块（血缘图、矩阵等），但 UI 没有提供原始 JSON 查看入口

---

## 功能一：Quick Analyze 对话框

### 目标元素（组件定位）
- 触发按钮：**新增** 到 `app/src/components/Workspace.tsx` 顶部 Header 操作栏（约 Line 325–380），放在 Share / Export 按钮右侧
- 新建组件：`app/src/components/QuickAnalyzeDialog.tsx`（全新文件）

### 当前行为
用户需要通过 ProjectSelector → 创建项目 → 创建/选择文件 → 粘贴 SQL → 点击 Lineage 按钮，才能完成分析。

### 期望行为
- 点击顶部 Header 的「Quick Analyze」按钮（图标 `Zap`）
- 弹出 Dialog，内置 CodeMirror SQL 编辑器（复用 `SqlView`）
- 用户粘贴 SQL → 点击「Analyze」→ 结果更新至右侧 AnalysisView（同现有分析流程一致）
- 关闭对话框后，结果仍保留在右侧面板

### 技术方案
- 使用 `Dialog` 组件（`app/src/components/ui/dialog.tsx`）
- 使用 `SqlView` from `@pondpilot/flowscope-react`
- 获取 `adapter` via `useBackend()`
- 获取 `setResult` via `useLineageActions()`
- 调用 `adapter.analyze({ files: [{ name: '__quick__.sql', content: sql }], dialect: currentProject?.dialect ?? 'ansi', schemaSQL: '', hideCTEs: false, enableColumnLineage: true })`
- 成功后 `actions.setResult(result.result)` 更新全局状态

### API 数据验证结论
- [x] `/api/analyze` 接口已存在且工作正常，无需变更 API
- [x] REST 模式下 dialect 由服务端控制，WASM 模式用 currentProject.dialect 或默认 'ansi'
- [x] 新功能仅增加 UI 入口，不修改分析逻辑

---

## 功能二：JSON Tab（原始响应查看器）

### 目标元素（组件定位）
- 文件：`app/src/components/AnalysisView.tsx`
- 位置：TabsList 约 Line 378–388，在现有 Lineage/Hierarchy/Matrix/Schema/Issues tab 后追加 JSON tab
- 依赖修改：`app/src/lib/navigation-context.tsx` Line 13–15，`AnalysisTab` 联合类型和 `VALID_TABS` 加入 `'json'`

### 当前行为
分析结果面板只展示可视化视图（血缘图、矩阵等），无法查看底层 JSON 数据。

### 期望行为
- 新增「JSON」Tab，切换后显示 `/api/analyze` 原始返回的 `AnalyzeResult` JSON
- 格式化展示（`JSON.stringify(result, null, 2)`）
- 顶部有「Copy」按钮（复制到剪贴板）
- 字体 monospace，内容可滚动

### API 数据验证结论
- [x] `result` 对象已存在于 `useLineage().state.result`，无需任何 API 变更
- [x] 纯前端渲染改动

---

## 验证方式

1. `cd app && yarn typecheck` 无错误
2. `cd app && yarn build` 无错误
3. CLI serve 模式重新 embed 并验证：
   ```bash
   cd app && yarn build
   cargo build -p flowscope-cli --features serve
   ```
4. 浏览器打开 → 点击 Quick Analyze → 粘贴 SQL → Analyze → 右侧看到血缘图
5. 点击 JSON Tab → 看到完整 JSON 结构 + 复制按钮可用
