# CLAUDE.md

This file is intentionally short. `AGENTS.md` is the canonical source of build, lint, test, and code style guidance for this repo.

## Required Reading

- Read `AGENTS.md` before making any changes.
- Use `README.md` for architecture and project overview.
- Keep Claude-specific notes here only when they are not already covered in `AGENTS.md`.

---

## Bug Handling During Validation (MANDATORY PROCESS)

**When a bug is found during validation/testing, do NOT fix it silently in conversation.**

Follow this loop for every bug, no matter how small:

```
发现 bug
  ↓
1. 在当前 Trellis 任务里记录（note 或 sub-task）
  ↓
2. 修复代码
  ↓
3. 立即运行 /trellis-break-loop（趁上下文新鲜）
   - 根因是什么？（设计缺陷 / 假设错误 / 语义理解偏差）
   - 为什么规划阶段没发现？
   - 什么 spec 规则能拦截它？
  ↓
4. 运行 /trellis-update-spec
   - 写"为什么犯这个错"，不只是"做了什么修复"
   - causal chain（因果链）比修复本身更有价值
```

### 反模式（禁止）

```
❌ 对话中发现 bug → 直接修 → 继续聊 → 任务结束时统一补 spec
```

这会导致：
- 因果链丢失（知道"不要截断"，但不知道"为什么会有截断这个想法"）
- spec 只有规则没有根因，下次遇到类似但不完全相同的情况仍会犯错
- Trellis 任务和实际代码变更脱节，无法追溯

### 正确模式

```
✅ 发现 bug → 暂停 → break-loop → update-spec → 修复 → 继续
```

即使会话变慢，每次修复都在给未来 AI 会话建立真正可用的记忆。

---

## 语言规则（MANDATORY）

**所有回复必须使用中文。** 代码、命令、技术术语保持原文，其余全部中文。
禁止混入日文（あ、い）或韩文（안녕）。违反即为严重错误。

---

## 前端改动规则（MANDATORY）

凡是前端页面改动，必须在 PRD 中明确以下三点，否则不得开始实现：

**1. 组件文件定位**：精确到文件路径 + 行号（不是"某个地方"）
**2. API 数据先验证**：血缘图/数据逻辑问题，必须先用 curl 验证 API 返回。
  - API 返回数据不对 → **先修 Rust 引擎**
  - API 数据正确但图显示不对 → 才改前端渲染

```bash
# 标准 API 验证命令（test-sql 目录）
curl -s -X POST http://localhost:3099/api/analyze \
  -H 'Content-Type: application/json' \
  -d "{\"files\":[{\"name\":\"xxx.sql\",\"content\":$(cat test-sql/xxx.sql | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')}],\"sql\":\"\"}" \
  | python3 -c "import json,sys; r=json.load(sys.stdin); print(json.dumps(r['summary'], indent=2))"
```

**3. 验证方式**：`agent-browser` 无法可靠点击 Radix UI DropdownMenu 内的 button，需手动 Chrome 验证或 JS 注入。

完整规范见：`.trellis/spec/flowscope-app/frontend/ui-change-protocol.md`

---

## 审计服务关键约定（result_json）

- `GET /api/audit` 列表接口：**不含** `sql_text` 和 `result_json`（避免页面崩溃）
- `GET /api/audit/:id` 详情接口：含完整 `sql_text` + `result_json`
- `stmt_count`：过滤 SET/USE/RESET，只计业务语句
- `table_count`：只计物理表（NodeType::Table | View），不含 CTE 节点
- `sql_type`：第一个有意义语句的类型（INSERT/SELECT/WITH）

完整约定见：`.trellis/spec/flowscope-cli/backend/audit-api-spec.md`

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
