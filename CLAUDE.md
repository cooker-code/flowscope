# CLAUDE.md

This file is intentionally short. `AGENTS.md` is the canonical source of build, lint, test, and code style guidance for this repo.

## Required Reading

- Read `AGENTS.md` before making any changes.
- Use `README.md` for architecture and project overview.
- Keep Claude-specific notes here only when they are not already covered in `AGENTS.md`.

---

## Bug Handling（MANDATORY）

**任何 bug，无论大小，必须按以下顺序处理**：

1. 在当前 Trellis 任务里记录 → 2. 修复 → 3. **立即** `/trellis-break-loop` → 4. `/trellis-update-spec`

禁止"对话中发现 → 直接修 → 继续聊"——会丢失因果链，下次类似场景仍会犯错。

完整流程与反模式见 `.claude/skills/trellis-break-loop/SKILL.md` 和 `.claude/skills/trellis-update-spec/SKILL.md`。

---

## 语言规则（MANDATORY）

**所有回复必须使用中文。** 代码、命令、技术术语保持原文，其余全部中文。
禁止混入日文（あ、い）或韩文（안녕）。违反即为严重错误。

---

## 前端改动规则（MANDATORY）

凡是前端页面改动，必须在 PRD 中明确以下三点，否则不得开始实现：

1. **组件文件定位**：精确到文件路径 + 行号（不是"某个地方"）。
2. **API 数据先验证**：血缘/数据逻辑问题先用 curl 验证 API 返回；API 不对 → **先修 Rust 引擎**；API 对、图不对 → 才改前端渲染。
3. **验证方式**：`agent-browser` 无法可靠点击 Radix UI DropdownMenu 内的 button，需手动 Chrome 验证或 JS 注入。

完整规范、curl 模板、验证 SOP 见 `.trellis/spec/flowscope-app/frontend/ui-change-protocol.md`。

---

## 审计服务关键约定（result_json）

- `GET /api/audit` 列表接口：**不含** `sql_text` 和 `result_json`（避免页面崩溃）
- `GET /api/audit/:id` 详情接口：含完整 `sql_text` + `result_json`
- `stmt_count`：过滤 SET/USE/RESET，只计业务语句
- `table_count`：只计物理表（NodeType::Table | View），不含 CTE 节点
- `sql_type`：第一个有意义语句的类型（INSERT/SELECT/WITH）

完整约定见：`.trellis/spec/flowscope-cli/backend/audit-api-spec.md`

---

## 血缘图边类型（MANDATORY 契约）

5 种 `EdgeType` 是 `flowscope-core` 分析器与 React 渲染器的核心契约。新增/修改边类型必须同步 Rust 枚举 + 前端样式 + spec 三端。

- 完整表格（视觉/触发条件/JSON 值）见 [`AGENTS.md` § Lineage Graph Edge Types](./AGENTS.md#lineage-graph-edge-types)
- 完整契约、不变量、反模式、worked examples 见 `.trellis/spec/flowscope-core/backend/edge-types.md`

---

## Trellis 任务流程速查

| 阶段 | 工具 | 时机 |
|------|------|------|
| 需求不清晰 | `/trellis-brainstorm` | 规划前 |
| 开始编码前 | `/trellis-before-dev` | 每次切换 package 时 |
| 发现 bug | `/trellis-break-loop` | **bug 修复后立即** |
| 编码完成 | `/trellis-check` | 提交前 |
| 沉淀经验 | `/trellis-update-spec` | break-loop 之后 |

---

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **flowscope** (16558 symbols, 37905 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/flowscope/context` | Codebase overview, check index freshness |
| `gitnexus://repo/flowscope/clusters` | All functional areas |
| `gitnexus://repo/flowscope/processes` | All execution flows |
| `gitnexus://repo/flowscope/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
