# Use audit result_json directly; default run mode to active file only

## Goal

两处改进：
1. Serve 模式默认 run mode 改为 "Run Active File Only"（原来是 "Run All Files"，无意义）
2. 从 Audit History 点击文件时，直接使用 SQLite 中存储的 `result_json` 渲染血缘图，不重新解析 SQL

## Confirmed Facts (from codebase)

- RunMode 默认值在 `project-store.tsx` 多处设为 `'all'`（L187, L281, L388）
- 结果注入路径：需同时调用 `useAnalysisStore().setResult` 和 `actionsRef.current.setResult`（在 `useAnalysis.ts` 内部，外部无法直接访问）
- `handleSelectAuditFile`（`FileSelector.tsx:145`）目前只设置 sql_text + 触发 selectFile，不调用 runAnalysis；分析由 EditorArea 的 useEffect 自动触发
- `GET /api/audit/:id` 返回完整 `result_json` 字段（已实现）

## Requirements

### 1. 默认 run mode 改为 'current'

在 serve/backend mode 启动时，`backendRunMode` 初始值改为 `'current'`（`project-store.tsx:281`）。
非 serve 模式不变（保持 `'all'`）。

### 2. 点击 Audit History 直接使用 result_json

修改 `handleSelectAuditFile`：
- `GET /api/audit/:id` 已返回 `result_json`（解析后的 JSON 对象）
- 拿到 result_json 后，直接注入到 lineage 显示状态，跳过 runAnalysis
- 注入路径：通过 `useAnalysis.ts` 暴露一个 `setResultFromCache(result: AnalyzeResult)` 函数，内部调用 `storeResult` + `actionsRef.current.setResult`
- `handleSelectAuditFile` 调用该函数而不是等待自动 re-analysis

## Acceptance Criteria

- [ ] Serve 模式启动后，Run Configuration 默认选中 "Run Active File Only"
- [ ] 点击 Audit History 中的文件，血缘图立即更新（无 loading 等待），直接展示历史解析结果
- [ ] `result_json` 为 null 时（旧记录无结果），fallback 到原来的 runAnalysis 行为
- [ ] 非 serve 模式 run mode 默认值不变（保持 'all'）
- [ ] 现有测试无回归

## Out of Scope

- result_json 的 schema 验证
- 离线/过期 result_json 的刷新机制
