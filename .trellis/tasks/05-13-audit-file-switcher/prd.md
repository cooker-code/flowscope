# Fix file switcher + connect file list to audit SQLite

## Goal

修复 serve 模式下文件切换器切换文件时 SQL 内容和血缘图不更新的 bug；同时将文件列表数据源从 `/api/files` 改为 `/api/audit`（SQLite 审计记录），使文件列表和审计日志联动。

## Confirmed Facts (from codebase)

### Bug 根因（已定位）

`app/src/components/EditorArea.tsx` 中自动触发 `runAnalysis` 的 `useEffect` 只监听 `schemaChanged` 和 `hideCTEsChanged`，**不监听 `activeFileId` 的变化**。

Backend mode 下 `selectFile()` 只更新 `backendActiveFileId` 状态（`project-store.tsx:589`），不触发重新分析。

### 关键文件

- `app/src/components/EditorArea.tsx` — 分析自动触发 useEffect（行 128~165）
- `app/src/components/FileSelector.tsx` — 文件选择器 UI
- `app/src/hooks/useBackendFiles.ts` — 后端文件列表 hook，当前轮询 `/api/files`
- `app/src/lib/project-store.tsx` — `selectFile()` / `backendActiveFileId` 状态

## Requirements

### 1. Bug 修复：切换文件自动触发分析

在 backend mode 下，`backendActiveFileId` 变化时，自动调用 `runAnalysis`，使用新选中文件的内容和路径。

### 2. 功能改造：文件列表来源改为审计 SQLite

- 后端新增 `GET /api/audit/files` 端点（或复用 `GET /api/audit`），按 `file_name` 去重，每个文件返回最新一条审计记录摘要（`id`、`file_name`、`ts`、`sql_type`、`table_count`、`has_cte`）。
- 前端文件列表改从审计记录获取，展示：文件名 + 最近处理时间 + sql_type + table_count。
- 点击文件列表中某条记录：调用 `GET /api/audit/:id` 获取完整 `sql_text`，加载到编辑器并触发分析。

## Acceptance Criteria

- [ ] serve 模式下切换文件，编辑器内容立即更新为新文件的 SQL。
- [ ] serve 模式下切换文件，血缘图自动重新计算，无需手动点 Analyze。
- [ ] 文件列表展示 SQLite 中历史出现过的文件（按 file_name 去重，取最新记录）。
- [ ] 文件列表每条显示：文件名、最近处理时间、sql_type、table_count。
- [ ] 点击文件列表记录，编辑器加载对应 sql_text 并自动触发分析。
- [ ] 现有测试无回归。

## Out of Scope

- 审计历史的完整查询 UI（分页、时间过滤）。
- 文件内容编辑（serve 模式保持只读）。
