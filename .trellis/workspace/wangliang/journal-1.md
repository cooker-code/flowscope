# Journal - wangliang (Part 1)

> AI development session journal
> Started: 2026-05-12

---



## Session 1: Hive SQL 预处理：从 Python 脚本提升到 Rust core

**Date**: 2026-05-15
**Task**: Hive SQL 预处理：从 Python 脚本提升到 Rust core
**Branch**: `master`

### Summary

把 13 步 Hive SQL 兼容预处理（占位符替换/SET-ADD 行过滤/DDL 过滤/TRANSFORM USING 改写/数组下标/双引号字符串/反斜杠转义/CTE 缺 AS/分号合并/语句拆分/NOT IN/孤儿 AS/GROUPING SETS）从客户端 Python 脚本完整移植到 flowscope-core Rust 实现，作为 Dialect::Hive 选择时的默认行为。real /api/analyze 调用方现在自动享受同样的兼容性，warehouse 全量 SQL 100% 解析通过。同时编写了 25 个 Rust 单元测试 + hive_corpus 集成测试，并把脚本删除以避免双轨维护。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `d61a010` | (see git log) |
| `14835c0` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 2: 审计页时间本地化与筛选状态跨页保持

**Date**: 2026-05-15
**Task**: 审计页时间本地化与筛选状态跨页保持
**Branch**: `master`

### Summary

AuditPage 列表 + SqlPreviewCapsule 详情面板的时间统一通过 formatLocalTs() 渲染本地时区格式（YYYY-MM-DD HH:MM:SS），原 ISO 字符串放 title 属性供 hover 调试。所有列表筛选条件（sql_type/success/file_name/keyword/source_name/page）从 useState 迁移到 useSearchParams（URL state），跨页导航通过 localStorage 的 LAST_AUDIT_QUERY_KEY 保留最后一次列表 query，从详情页『Back to audit list』可一键还原原始视角。新增 .trellis/spec/flowscope-app/frontend/state-management.md 沉淀 URL/localStorage/timestamp 三类约定。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `90f6310` | (see git log) |
| `b57259a` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 3: Vite dev /api 代理修复 + 防回归约束

**Date**: 2026-05-15
**Task**: Vite dev /api 代理修复 + 防回归约束
**Branch**: `master`

### Summary

yarn dev 时浏览器报 Unexpected token '<', '<!DOCTYPE'... is not valid JSON 的根因是 vite.config.ts 缺 /api proxy（之前曾被当临时调试配置回滚过），导致 /api/* 请求落到 Vite 的 SPA fallback 返回 index.html。永久修复：vite.config.ts 加 server.proxy['/api'] = process.env.FLOWSCOPE_API_PROXY ?? 'http://localhost:3099' 并写注释说明依赖。AuditPage.fetchList 加防御性 content-type 检查，命中 HTML 时直接抛出可执行的错误提示。state-management.md 新增 Dev Environment Contract 章节标记为 MANDATORY。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `869b001` | (see git log) |
| `3c90c9f` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 4: 审计记录新增可选 sourceName 字段（API + DB + UI 全链路）

**Date**: 2026-05-15
**Task**: 审计记录新增可选 sourceName 字段（API + DB + UI 全链路）
**Branch**: `master`

### Summary

/api/analyze 接受可选 sourceName 字段（snake_case 与 camelCase 都兼容），透传到 flowscope-core::AnalyzeRequest 和 audit_log 持久化层。SQLite 表 audit_log 加 source_name TEXT 列 + idx_audit_source_name 索引，schema 初始化重构为三阶段（CREATE TABLE → ADDITIVE_MIGRATIONS ALTER TABLE → CREATE INDEXES），修复了 CREATE INDEX 在 ALTER TABLE 之前执行导致 legacy DB 升级失败的潜在 bug。GET /api/audit?source_name=... 支持 LIKE 子串过滤。前端 AuditPage 加 Name 筛选框 + 表格列；SqlPreviewCapsule 详情面板显示 source_name。新增 4 个 Rust 单测覆盖往返/过滤/详情/迁移幂等。break-loop 文档记录 schema 迁移顺序教训。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `44e28ce` | (see git log) |
| `c4f4f0b` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 5: Trellis 任务批量归档与文档引用同步

**Date**: 2026-05-15
**Task**: Trellis 任务批量归档与文档引用同步
**Branch**: `master`

### Summary

补齐本会话 4 个 task（port-hive-preprocess-to-core / fix-audit-page-tz-and-filter-state / fix-vite-dev-api-proxy / audit-source-name）的 task.py archive 流程，状态从 planning 推进到 completed。同步修复 spec 与源码 doc 注释中的 task 路径引用（hive_preprocess.rs:9、state-management.md 第 88/155/226 行）从 .trellis/tasks/05-14-* 改为 .trellis/tasks/archive/2026-05/05-14-*。另外回填 3 个历史遗留裸 task 目录（05-13-audit-review-page / 05-13-derived-subquery-join-leak / 05-14-matrix-hide-cte）的 task.json metadata（含 backfilled=true、actualCompletedAt、commit 指向、原始问题如 title 双重 escape unicode），统一 archive 入库。最后核实 fix-complex-sql-parse 与 fix-hive-sql-parse-errors 两个 in_progress task 的真实状态：通过 stdin smoke test 验证 3 个 PR（STRUCT 命名字段 / DIV 整除 / INSERT 带括号 SELECT）全部生效（PR3 实际由 753f20c FlowscopeHiveDialect 升级带过来，无独立 commit），同样补 metadata + archive。git push origin master 共推送 14 个 commit。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `e572725` | (see git log) |
| `fa09a69` | (see git log) |
| `5cb7083` | (see git log) |
| `eec94b8` | (see git log) |
| `7c692ba` | (see git log) |
| `017401d` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 6: CLAUDE.md 加 MANDATORY：work commit 后必须跑 /trellis-finish-work

**Date**: 2026-05-15
**Task**: CLAUDE.md 加 MANDATORY：work commit 后必须跑 /trellis-finish-work
**Branch**: `master`

### Summary

本会话 7 个 task 全部漏写 journal 的反面教材沉淀为流程纪律：CLAUDE.md 新增『任务收尾（MANDATORY）』红字章节，明确 work commit 落地后必须主动跑 /trellis-finish-work（archive + 写 journal + 更新 workspace index），不得等用户提醒。同时在底部 Trellis 任务流程速查表加一行兜底。规则含判定标准（commit 是否 task 相关 / 多 task 一并归档 / 用户暂缓时如何回应）+ 完整命令文档指针 .cursor/commands/trellis-finish-work.md。这条规则的第一次自我应用就是本 session 自身——doc commit 后按规则补这条 journal 闭环。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `bde255a` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 7: SQL 快速粘贴分析 + JSON 结果查看器

**Date**: 2026-05-15
**Task**: SQL 快速粘贴分析 + JSON 结果查看器
**Branch**: `master`

### Summary

新增 Quick Analyze 对话框（顶部 Header Zap 按钮）让用户无需项目/文件直接粘贴 SQL 触发血缘分析；在 AnalysisView 新增 JSON Tab 展示 /api/analyze 完整 AnalyzeResult 结构，含复制按钮。typecheck + lint + build 全通过。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `2cf69f8` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete
