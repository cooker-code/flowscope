# Workspace Index - wangliang

> Journal tracking for AI development sessions.

---

## Current Status

<!-- @@@auto:current-status -->
- **Active File**: `journal-1.md`
- **Total Sessions**: 20
- **Last Active**: 2026-11-27
<!-- @@@/auto:current-status -->

---

## Active Documents

<!-- @@@auto:active-documents -->
| File | Lines | Status |
|------|-------|--------|
| `journal-1.md` | ~686 | Active |
<!-- @@@/auto:active-documents -->

---

## Session History

<!-- @@@auto:session-history -->
| # | Date | Title | Commits | Branch |
|---|------|-------|---------|--------|
| 20 | 2026-11-27 | 统一审计入图状态并补充实际变更统计 | `d01351e6` | `codex/fix-ingestion-status-semantics` |
| 19 | 2026-11-27 | 入图优化、审计页精简及 Linux CLI 打包上传 | `ec001c6f`, `2fdb5395` | `codex/fix-lineage-retry-throughput` |
| 18 | 2026-11-26 | 修复历史审计类型校正阻塞启动 | `577e0295` | `codex/fix-audit-startup-blocking` |
| 17 | 2026-11-26 | 汇总全部本地分支并验证审计功能 | `fde842be`, `41af81ee` | `codex/fix-audit-table-flicker` |
| 16 | 2026-11-26 | 审计入图状态展示具体原因 | `391384d4` | `codex/audit-status-reasons` |
| 15 | 2026-11-26 | 审计页增加入图状态筛选 | `fc5ab52e4bd3ae41152cc7c9233c7b65b74681c8` | `codex/audit-ingestion-filter` |
| 14 | 2026-11-26 | Token 列表显示真实凭据并隐藏已撤销记录 | `a603b169` | `codex/token-value-display` |
| 13 | 2026-11-26 | 合并遗留分支并保留工作树资料 | `9815f02b`, `8b35d60a` | `codex/audit-graph-status` |
| 12 | 2026-09-28 | Hive FROM VALUES audit 443044 fix（补录分支记录） | `3f6f6538` | `codex/fix-hive-from-values-443044` |
| 11 | 2026-11-26 | 审计表增加入图状态与问号说明 | `7b6e72ae` | `codex/audit-graph-status` |
| 10 | 2026-11-03 | 提交并推送 Hive LATERAL VIEW 限定引用修复 | `be9d0dc4` | `master` |
| 9 | 2026-07-06 | 修复自依赖 INSERT 缺失 sourceTables 收尾 | `82b3f7f9` | `master` |
| 8 | 2026-06-23 | 完成审计目标表筛选 | `27e1a1b3`, `16fc359f` | `codex/audit-target-table-filter` |
| 7 | 2026-05-15 | SQL 快速粘贴分析 + JSON 结果查看器 | `2cf69f8` | `master` |
| 6 | 2026-05-15 | CLAUDE.md 加 MANDATORY：work commit 后必须跑 /trellis-finish-work | `bde255a` | `master` |
| 5 | 2026-05-15 | Trellis 任务批量归档与文档引用同步 | `e572725`, `fa09a69`, `5cb7083`, `eec94b8`, `7c692ba`, `017401d` | `master` |
| 4 | 2026-05-15 | 审计记录新增可选 sourceName 字段（API + DB + UI 全链路） | `44e28ce`, `c4f4f0b` | `master` |
| 3 | 2026-05-15 | Vite dev /api 代理修复 + 防回归约束 | `869b001`, `3c90c9f` | `master` |
| 2 | 2026-05-15 | 审计页时间本地化与筛选状态跨页保持 | `90f6310`, `b57259a` | `master` |
| 1 | 2026-05-15 | Hive SQL 预处理：从 Python 脚本提升到 Rust core | `d61a010`, `14835c0` | `master` |
<!-- @@@/auto:session-history -->

---

## Notes

- Sessions are appended to journal files
- New journal file created when current exceeds 2000 lines
- Use `add_session.py` to record sessions