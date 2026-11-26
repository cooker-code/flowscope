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


## Session 8: 完成审计目标表筛选

**Date**: 2026-06-23
**Task**: 完成审计目标表筛选
**Branch**: `codex/audit-target-table-filter`

### Summary

实现审计日志 target_table 落库、精确筛选、前端筛选框和列表列；剔除 GitNexus 规则/技能/文档引用；完成本地页面验证、生产服务端 zigbuild 打包上传，并归档 Trellis task。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `27e1a1b3` | (see git log) |
| `16fc359f` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 9: 修复自依赖 INSERT 缺失 sourceTables 收尾

**Date**: 2026-07-06
**Task**: 修复自依赖 INSERT 缺失 sourceTables 收尾
**Branch**: `master`

### Summary

完成 flowscope-core 自依赖 INSERT sourceTables 契约修复并提交代码；完成生产 CLI serve 打包上传；创建 Claro Story 1187 / Task 1646，写入 score=4、plannedScore=4，上传 Trellis 文档到 DocZ 并挂载 Task 产物；Trellis task 已归档。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `82b3f7f9` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 10: 提交并推送 Hive LATERAL VIEW 限定引用修复

**Date**: 2026-11-03
**Task**: 提交并推送 Hive LATERAL VIEW 限定引用修复
**Branch**: `master`

### Summary

提交本任务修复和资料；隔离暂存版本验证1748个Core单测及496个集成测试通过，目标Clippy和格式检查通过。保留SQL指纹及CLI导出等原有改动。归档当前任务，随后推送origin/master并核实远端SHA。

### Main Changes

- 修复不同 LATERAL VIEW 的同名输出列限定引用，保留真实来源和窗口依赖角色。
- 同时提交任务规划、原 SQL、字段来源证据和规范；按项目流程归档本任务。
- SQL 指纹、CLI/导出依赖等其他原有改动留在工作区。

### Git Commits

| Hash | Message |
|------|---------|
| `be9d0dc4` | fix(hive): 修复LATERAL VIEW同名输出列限定引用及字段血缘 |

### Testing

- [OK] 在独立暂存源码和独立 Cargo target 下，1748 个 Core 单测、496 个相关集成测试通过。
- [OK] 本次目标 Clippy（-D warnings）和 cargo fmt 检查通过。
- [OK] 原 SQL、fixture 和审计哈希一致；保留原文空白。
- 已知全目标 Clippy 与 golden 基线失败详见归档任务 validation.md；不据此声称全仓库检查通过。
- [OK] 独立验证源码目录及编译产物已清理。

### Status

[OK] 修复提交、本地任务归档、journal 和针对性验证已完成；远端推送由本次 Git 流程继续执行。

### Next Steps

- 将当前 master 普通推送到 origin/master，读取远端 SHA 与本地 HEAD 比较。


## Session 11: 审计表增加入图状态与问号说明

**Date**: 2026-11-26
**Task**: 审计表增加入图状态与问号说明
**Branch**: `codex/audit-graph-status`

### Summary

在解析列后展示六类入图状态，圆圈问号支持悬停、点击、键盘和触屏说明；区分历史未知与明确未请求。前端构建、类型和 lint、3 项传输测试、6 项 Rust 测试及桌面/手机浏览器检查通过，临时进程和浏览器目录已清理。本次按用户要求不创建 Trellis task，未部署线上。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `7b6e72ae` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 12: Hive FROM VALUES audit 443044 fix（补录分支记录）

**Date**: 2026-09-28
**Task**: Hive FROM VALUES audit 443044 fix
**Branch**: `codex/fix-hive-from-values-443044`

### Summary

Created GitLab issue 1; enabled Hive FROM VALUES table factor, added parser and public analyze regressions, replayed unchanged audit SQL with exact Databricks lineage parity, verified 1725 core tests and 18 SQL fixtures, built glibc 2.17 Linux serve binary and frontend ZIP; deployment and post-audit verification remain pending.

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `3f6f653826abed5d47a7ce2b544356c478c54f9e` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 13: 合并遗留分支并保留工作树资料

**Date**: 2026-11-26
**Task**: 合并遗留分支并保留工作树资料
**Branch**: `codex/audit-graph-status`

### Summary

合入 Hive DDL 已等价实现的历史、Hive FROM VALUES 的 3 个回归测试和旧任务记录；保留主干较新的 Hive 解析能力。保存两份旧工作树的未提交任务与验证资料，清除任务元数据中的旧工作树关联。多次出现过滤条件的本地修复已等价合入 master，按用户选择不引入外部上游历史。合并后的 1750 项核心测试通过，分支及未提交文件已保存到仓库外备份，随后执行本地分支和工作树清理。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `9815f02b` | (see git log) |
| `8b35d60a` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 14: Token 列表显示真实凭据并隐藏已撤销记录

**Date**: 2026-11-26
**Task**: Token 列表显示真实凭据并隐藏已撤销记录
**Branch**: `codex/token-value-display`

### Summary

Token 管理显示实际凭据，管理员可在刷新和重启后再次读取；采用加密持久化与独立密钥，旧哈希记录在成功认证后补存完整值；撤销后隐藏并清除密文，保留历史ID引用。前端构建/lint/3项传输测试、16项服务端测试、Rust Clippy、1750项核心测试、18个SQL回归以及Token管理浏览器检查通过。浏览器、临时目录与测试服务已清理。本次按用户要求不创建Trellis task。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `a603b169` | 显示真实凭据并隐藏已撤销记录 |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 15: 审计页增加入图状态筛选

**Date**: 2026-11-26
**Task**: 审计页增加入图状态筛选
**Branch**: `codex/audit-ingestion-filter`

### Summary

增加六类入图状态与全部选项，筛选条件保存在URL并在切换条件时重置分页；后端在计数和分页前匹配有效入图结果，同一个读取快照内返回状态；涵盖策略阻止别名、历史未知和未请求的区别、调用方隔离及无入图配置场景。前端构建/lint/3项接口测试、17项服务端测试、Clippy、1750项核心测试、18个SQL回归通过；浏览器验证筛选/分页/刷新/详情返回/重置和390px窄屏，测试服务及浏览器资源已清理。本次不创建Trellis task。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `fc5ab52e4bd3ae41152cc7c9233c7b65b74681c8` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete


## Session 16: 审计入图状态展示具体原因

**Date**: 2026-11-26
**Task**: 审计入图状态展示具体原因
**Branch**: `codex/audit-status-reasons`

### Summary

每条状态悬浮展示实际 policy_reason，翻译常见检查项并保留完整表字段和原文；补充未入图不自动重试说明。前端类型检查、Lint、6 项测试、1750 核心测试、18 SQL 回归及 8 项桌面和手机浏览器场景通过；验证进程、临时目录与服务已清理。按用户要求不创建 Trellis task。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `391384d4` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete
