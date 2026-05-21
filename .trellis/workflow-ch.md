# 开发工作流

---

## 核心原则

1. **先规划，再编码** —— 动手前先想清楚要做什么
2. **规范靠注入，不靠记忆** —— 指南由 hook/skill 自动注入，不依赖回忆
3. **一切沉淀为文件** —— 研究、决策、教训全部落到文件；对话会被压缩，文件不会
4. **增量开发** —— 一次只做一个任务
5. **复盘并写回规范** —— 每个任务结束后，回顾并把新知识写回 spec

---

## Trellis 系统

### 开发者身份

首次使用时，初始化身份：

```bash
python3 ./.trellis/scripts/init_developer.py <your-name>
```

会创建 `.trellis/.developer`（已 gitignore） + `.trellis/workspace/<your-name>/`。

### Spec 系统

`.trellis/spec/` 存放按 package 和 layer 组织的编码规范。

- `.trellis/spec/<package>/<layer>/index.md` —— 入口文件，包含 **Pre-Development Checklist** 和 **Quality Check**。真正的规范条文存在它所指向的 `.md` 文件里。
- `.trellis/spec/guides/index.md` —— 跨 package 的思考指南。

```bash
python3 ./.trellis/scripts/get_context.py --mode packages   # 列出所有 package / layer
```

**何时更新 spec**：发现了新的模式/约定 · 需要固化的 bug 防御措施 · 新的技术决策。

### 任务系统

每个任务在 `.trellis/tasks/{MM-DD-name}/` 下有独立目录，包含 `task.json`、`prd.md`、可选 `design.md`、可选 `implement.md`、可选 `research/`，以及 sub-agent 平台用的上下文清单（`implement.jsonl`、`check.jsonl`）。

```bash
# 任务生命周期
python3 ./.trellis/scripts/task.py create "<title>" [--slug <name>] [--parent <dir>]
python3 ./.trellis/scripts/task.py start <name>          # 设为活动任务（在平台支持时按 session 隔离）
python3 ./.trellis/scripts/task.py current --source      # 查看当前活动任务和来源
python3 ./.trellis/scripts/task.py finish                # 清除活动任务（触发 after_finish hooks）
python3 ./.trellis/scripts/task.py archive <name>        # 归档到 archive/{year-month}/
python3 ./.trellis/scripts/task.py list [--mine] [--status <s>]
python3 ./.trellis/scripts/task.py list-archive

# 代码规范上下文（通过 JSONL 注入到 implement/check sub-agent）
# `implement.jsonl` / `check.jsonl` 在 `task create` 时已 seed，sub-agent 平台
# 会在 planning 阶段由 AI 按需补充真正的 spec / research 条目。
python3 ./.trellis/scripts/task.py add-context <name> <action> <file> <reason>
python3 ./.trellis/scripts/task.py list-context <name> [action]
python3 ./.trellis/scripts/task.py validate <name>

# 任务元数据
python3 ./.trellis/scripts/task.py set-branch <name> <branch>
python3 ./.trellis/scripts/task.py set-base-branch <name> <branch>    # PR 目标分支
python3 ./.trellis/scripts/task.py set-scope <name> <scope>

# 层级（父/子任务）
python3 ./.trellis/scripts/task.py add-subtask <parent> <child>
python3 ./.trellis/scripts/task.py remove-subtask <parent> <child>

# 创建 PR
python3 ./.trellis/scripts/task.py create-pr [name] [--dry-run]
```

> 执行 `python3 ./.trellis/scripts/task.py --help` 查看权威、最新的命令列表。

**当前任务机制**：`task.py create` 创建任务目录，并在 session 身份可用时自动设置 per-session 活动任务指针，让 planning 阶段的 breadcrumb 立刻生效。`task.py start` 写入同一个指针（若已存在则幂等），并把 `task.json.status` 从 `planning` 翻成 `in_progress`。状态存放在 `.trellis/.runtime/sessions/`。如果 hook 输入、`TRELLIS_CONTEXT_ID` 以及平台原生 session 环境变量都拿不到 context key，则没有活动任务，`task.py start` 会失败并提示 session 身份配置方式。`task.py finish` 删除当前 session 文件（状态不变）。`task.py archive <task>` 写入 `status=completed`、把目录移到 `archive/`，并清理仍指向该任务的 runtime session 文件。

### Workspace 系统

记录每一次 AI 会话，用于跨会话追踪，存放在 `.trellis/workspace/<developer>/`。

- `journal-N.md` —— 会话日志。**每个文件最多 2000 行**；超过时自动创建 `journal-(N+1).md`。
- `index.md` —— 个人索引（总会话数、最近活跃时间）。

```bash
python3 ./.trellis/scripts/add_session.py --title "Title" --commit "hash" --summary "Summary"
```

### 上下文脚本

```bash
python3 ./.trellis/scripts/get_context.py                            # 完整的 session runtime
python3 ./.trellis/scripts/get_context.py --mode packages            # 可用 package + spec layer
python3 ./.trellis/scripts/get_context.py --mode phase --step <X.Y>  # 某个工作流步骤的详细指南
```

---

<!--
  WORKFLOW-STATE BREADCRUMB CONTRACT（编辑下方 tag 块前必读）

  下面 ## Phase Index 区段内嵌入的 [workflow-state:STATUS] 块，是每个支持
  Trellis 的 AI 平台 UserPromptSubmit hook 读取的「per-turn `<workflow-state>`
  breadcrumb」的唯一权威来源。inject-workflow-state.py（Python 平台）和
  inject-workflow-state.js（OpenCode 插件）只解析这些块 —— v0.5.0-rc.0 之后
  脚本里不再有 fallback 字典。

  STATUS 字符集：[A-Za-z0-9_-]+。当 hook 找不到对应 tag 时，会降级输出一行
  通用提示 "Refer to workflow.md for current step." —— 故意可见，让用户能
  察觉并修复损坏的 workflow.md。

  不变量（test/regression.test.ts）：
    workflow-walkthrough 中每个标记 `[required · once]` 的步骤，必须在所在
    phase 的 [workflow-state:*] 块里有对应的强制执行行。breadcrumb 是唯一
    的 per-turn 通道；如果某个强制步骤没在那里出现，AI 会静默跳过它
    （Phase 1 planning gate 跳过和 Phase 3.4 commit 跳过都是这种 gap 引发）。

  TAG ↔ PHASE 作用域：
    [workflow-state:no_task]      → 没有活动任务；Phase 1 之前
    [workflow-state:planning]     → 整个 Phase 1（status='planning'）
    [workflow-state:planning-inline] → Codex inline 版的 Phase 1
    [workflow-state:in_progress]  → Phase 2 + Phase 3.1-3.4
                                    （status 从 task.py start 到 task.py archive
                                    一直保持 'in_progress'）
    [workflow-state:in_progress-inline] → Codex inline 版的 Phase 2/3
    [workflow-state:completed]    → 当前为 DEAD：cmd_archive 在同一次调用里
                                    既翻转 status 又移动目录，解析器丢失指针
                                    （此块保留供未来显式的
                                    in_progress→completed 转换使用）

  编辑清单：
    - 修改某个 [workflow-state:STATUS] 块时，同步检查对应 phase 中
      `[required · once]` 步骤是否一致
    - 编辑完跑 `trellis update`，将新内容下推到下游用户项目
      （block-level 受管替换）
    - 完整运行时契约：
      .trellis/spec/cli/backend/workflow-state-contract.md
-->

## Phase 索引

```
Phase 1: Plan    → 分类需求、征得创建任务的同意，然后写 planning artifacts
Phase 2: Execute → 任务状态变成 in_progress 之后才能动手实现
Phase 3: Finish  → 验证、更新 spec、提交、收尾
```

### 请求分类（Request Triage）

- 简单对话或小任务：只问一句「这一轮是否需要创建 Trellis 任务」。用户说不需要，本会话就跳过 Trellis。
- 复杂任务：询问是否可以创建 Trellis 任务并进入 planning。如果用户拒绝，不得进行大范围 inline 实现；改为澄清范围或建议拆分。
- 用户同意创建任务 ≠ 同意开始实现。Planning 仍要先行。

### Planning 产物

- `prd.md` —— 需求、约束、验收标准。技术设计和执行清单不要放这里。
- `design.md` —— 复杂任务的技术设计：边界、契约、数据流、权衡、兼容性、上线/回滚形态。
- `implement.md` —— 复杂任务的执行计划：有序清单、验证命令、评审节点、回滚点。
- `implement.jsonl` / `check.jsonl` —— 给 sub-agent 用的 spec 与 research 清单，**不能替代** `implement.md`。
- 轻量任务可以只写 PRD；复杂任务在 `task.py start` 之前必须有 `prd.md`、`design.md`、`implement.md`。

<!-- Per-turn breadcrumb：没有活动任务时显示（Phase 1 之前） -->

[workflow-state:no_task]
No active task. First classify the current turn and ask for task-creation consent before creating any Trellis task.
Simple conversation / small task: ask only whether this turn should create a Trellis task. If the user says no, skip Trellis for this session.
Complex task: ask the user if you can create a Trellis task and enter the planning phase. If the user says no, explain, clarify scope, or suggest a smaller split.
[/workflow-state:no_task]

### Phase 1: Plan
- 1.0 创建任务 `[required · once]`（仅在征得任务创建同意后）
- 1.1 需求探索 `[required · repeatable]`（`prd.md`；复杂任务另需 `design.md` + `implement.md`）
- 1.2 研究 `[optional · repeatable]`
- 1.3 配置上下文 `[conditional · once]` —— Claude Code、Cursor、OpenCode、Codex、Kiro、Gemini、Qoder、CodeBuddy、Copilot、Droid、Pi
- 1.4 激活任务 `[required · once]`（评审节点，然后 `task.py start`；status → in_progress）
- 1.5 完成判据

<!-- Per-turn breadcrumb：整个 Phase 1 期间显示（status='planning'） -->

[workflow-state:planning]
Load `trellis-brainstorm`; stay in planning.
Lightweight: `prd.md` can be enough. Complex: finish `prd.md`, `design.md`, and `implement.md`; ask for review before `task.py start`.
Sub-agent mode: curate `implement.jsonl` and `check.jsonl` as spec/research manifests before start.
[/workflow-state:planning]

<!-- Per-turn breadcrumb：codex.dispatch_mode=inline 时 Phase 1 期间显示。
     Codex 专属、可选启用的 [workflow-state:planning] 替代。主 agent 在
     Phase 2 直接改代码，因此跳过 jsonl 维护 —— inline 流程改为加载
     `trellis-before-dev`，而不是向 sub-agent 注入 JSONL。 -->

[workflow-state:planning-inline]
Load `trellis-brainstorm`; stay in planning.
Lightweight: `prd.md` can be enough. Complex: finish `prd.md`, `design.md`, and `implement.md`; ask for review before `task.py start`.
Inline mode: skip jsonl curation; Phase 2 reads artifacts/specs via `trellis-before-dev`.
[/workflow-state:planning-inline]

### Phase 2: Execute
- 2.1 实现 `[required · repeatable]`
- 2.2 质量检查 `[required · repeatable]`
- 2.3 回滚 `[on demand]`

<!-- Per-turn breadcrumb：status='in_progress' 期间显示。
     作用域：Phase 2 + Phase 3.1-3.4（status 从 task.py start 到 task.py
     archive 一直保持 'in_progress'；只有 archive 会翻转它）。因此本块
     必须覆盖从实现到 commit 的每一个强制步骤，包括 Phase 3.3 spec 更新
     和 Phase 3.4 commit。 -->

Sub-agent dispatch protocol applies to all platforms and all sub-agents, including class-2 Codex/Copilot/Gemini/Qoder and `trellis-research`: every dispatch prompt starts with `Active task: <task path from task.py current>` before role-specific instructions.

[workflow-state:in_progress]
Flow: `trellis-implement` -> `trellis-check` -> `trellis-update-spec` -> commit (Phase 3.4) -> `/trellis:finish-work`.
Main-session default: dispatch implement/check sub-agents. Sub-agent self-exemption: if already running as `trellis-implement`, do NOT spawn another `trellis-implement` or `trellis-check`; if already running as `trellis-check`, do NOT spawn another `trellis-check` or `trellis-implement`. Dispatch is main session only.
Dispatch prompt starts with `Active task: <task path from task.py current>`. Read context: jsonl entries -> `prd.md` -> `design.md if present` -> `implement.md if present`.
[/workflow-state:in_progress]

<!-- Per-turn breadcrumb：codex.dispatch_mode=inline 时 status='in_progress'
     期间显示。Codex 专属、可选启用的 [workflow-state:in_progress] 替代。
     主会话直接改代码，不再 dispatch sub-agent。 -->

[workflow-state:in_progress-inline]
Flow: `trellis-before-dev` -> edit -> `trellis-check` -> validation -> `trellis-update-spec` -> commit (Phase 3.4) -> `/trellis:finish-work`.
Do not dispatch implement/check sub-agents in inline mode.
Read context: `prd.md` -> `design.md if present` -> `implement.md if present`, plus relevant spec/research loaded by skills.
[/workflow-state:in_progress-inline]

### Phase 3: Finish
- 3.1 质量验证 `[required · repeatable]`
- 3.2 调试复盘 `[on demand]`
- 3.3 Spec 更新 `[required · once]`
- 3.4 提交代码 `[required · once]`
- 3.5 收尾提醒

<!-- Per-turn breadcrumb：status='completed' 时显示。
     当前正常流程下为 DEAD：cmd_archive 在同一次调用里写入
     status='completed' 并把任务目录移到 archive/，因此活动任务解析器
     拿不到指针，hook 在已归档任务上永远不会触发。此块保留供未来的
     状态转换重构（例如显式的 in_progress→completed 命令）。编辑方式
     同其他存活块。 -->

[workflow-state:completed]
Code committed. Run `/trellis:finish-work`; if dirty, return to Phase 3.4 first.
[/workflow-state:completed]

### 规则

1. 先判断自己处在哪个 Phase，从该 Phase 的下一步继续
2. 每个 Phase 内按顺序执行；`[required]` 步骤不能跳过
3. Phase 可以回滚（例如 Execute 中发现 prd 缺陷 → 回 Plan 修正，再重新进入 Execute）
4. 标记 `[once]` 的步骤如果产物已存在则跳过，不要重跑
5. Artifact 的存在决定下一步走向；轻量任务允许缺 `design.md` / `implement.md`，复杂任务缺这两份就属于 planning 未完成。

### 活动任务路由（Active Task Routing）

当用户请求在活动任务上下文中匹配以下意图时，先做路由，再按需加载详细 phase 步骤。

[Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

- 规划或需求不清 -> `trellis-brainstorm`。
- `in_progress` 的实现/检查 -> 派发 `trellis-implement` / `trellis-check`。
- 反复调试 -> `trellis-break-loop`；spec 更新 -> `trellis-update-spec`。

[/Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

[codex-inline, Kilo, Antigravity, Windsurf]

- 规划或需求不清 -> `trellis-brainstorm`。
- 编辑前 -> `trellis-before-dev`；编辑后 -> `trellis-check`。
- 反复调试 -> `trellis-break-loop`；spec 更新 -> `trellis-update-spec`。

[/codex-inline, Kilo, Antigravity, Windsurf]

### 护栏（Guardrails）

- 同意创建任务 ≠ 同意开始实现；实现必须等 artifact 评审通过后的 `task.py start`。
- 轻量任务可以只写 PRD；复杂任务必须有 `design.md` + `implement.md`。
- Planning 必须落到任务 artifact 上；汇报完成前必须跑完检查。

### 加载步骤详情

每一步执行以下命令以获取详细指引：

```bash
python3 ./.trellis/scripts/get_context.py --mode phase --step <step>
# 例如 python3 ./.trellis/scripts/get_context.py --mode phase --step 1.1
```

---

## Phase 1: Plan

目标：对请求做分类，必要时征得任务创建同意，并产出实现前所需的 planning artifacts。

#### 1.0 创建任务 `[required · once]`

仅在获得任务创建同意后才创建任务目录。该命令把 status 设为 `planning`、写入 `task.json`、创建默认 `prd.md`，并在 session 身份可用时自动把新任务设为活动任务：

```bash
python3 ./.trellis/scripts/task.py create "<task title>" --slug <name>
```

`--slug` 只是人类可读的名字，**不要**带 `MM-DD-` 日期前缀；`task.py create` 会自动加上前缀。

命令成功后，per-turn breadcrumb 自动切换到 `[workflow-state:planning]`，提示 AI 继续 planning。

此处只执行 `create` —— **不要**同时跑 `start`。`start` 会把 status 翻成 `in_progress`，导致 breadcrumb 在 planning artifact 评审之前就切到 implementation。`start` 留到 1.4。

当 `python3 ./.trellis/scripts/task.py current --source` 已指向某个任务时，跳过此步。

#### 1.1 需求探索 `[required · repeatable]`

加载 `trellis-brainstorm` skill，按其指引与用户交互式探索需求。

Brainstorm skill 会引导你：
- 一次只问一个问题
- 能查的优先去查，少问用户
- 优先提供选项，少用开放性问题
- 用户每次回答后立刻更新 `prd.md`
- `prd.md` 专注于需求和验收标准
- 复杂任务在实现开始前要产出 `design.md` 和 `implement.md`

需求一旦变化，随时回到本步骤修改相应 artifact。

#### 1.2 研究 `[optional · repeatable]`

研究可以在需求探索过程中的任何时间发生。不限本地代码 —— 任何工具都可以用（MCP 服务、skills、网络搜索等）查外部信息：第三方库文档、行业实践、API 参考等。

[Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

派发研究 sub-agent：

- **Agent type**: `trellis-research`
- **Task description**: Research <具体问题>
- **关键要求**：研究输出**必须**持久化到 `{TASK_DIR}/research/`

[/Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

[codex-inline, Kilo, Antigravity, Windsurf]

直接在主会话中做研究，并把结论写入 `{TASK_DIR}/research/`。（`codex-inline` 这样做是为了避开 `fork_turns="none"` 隔离 —— 该隔离让 `trellis-research` sub-agent 解析不到活动任务路径。）

[/codex-inline, Kilo, Antigravity, Windsurf]

**研究 artifact 约定**：
- 每个研究主题一个文件（例如 `research/auth-library-comparison.md`）
- 第三方库的用法示例、API 参考、版本约束都记录到文件里
- 把发现的相关 spec 文件路径也记下来，便于后续引用

Brainstorm 和 research 可以自由交错 —— 暂停一下去研究某个技术问题，再回来和用户讨论。

**关键原则**：研究输出必须写入文件，不要只留在对话里。对话会被压缩，文件不会。

#### 1.3 配置上下文 `[required · once]`

[Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

维护 `implement.jsonl` 和 `check.jsonl`，让 Phase 2 的 sub-agent 拿到正确的 spec / research 上下文。这两个文件在 `task create` 时已经 seed 了一条自描述的 `_example` 行；你的工作就是把真实条目填进去。

**位置**：`{TASK_DIR}/implement.jsonl` 和 `{TASK_DIR}/check.jsonl`（已存在）。

**格式**：每行一个 JSON 对象 —— `{"file": "<path>", "reason": "<why>"}`。路径相对仓库根目录。

**应该放什么**：
- **Spec 文件** —— `.trellis/spec/<package>/<layer>/index.md` 以及具体的指南文件（`error-handling.md`、`conventions.md` 等）中与本任务相关的
- **Research 文件** —— `{TASK_DIR}/research/*.md` 中 sub-agent 需要查阅的

**不应该放什么**：
- 代码文件（`src/**`、`packages/**/*.ts` 等）—— 这些由 sub-agent 实现时自行读取，不需要预先注册
- 即将修改的文件 —— 同理

**两个文件的分工**：
- `implement.jsonl` → implement sub-agent 写出正确代码所需的 spec + research
- `check.jsonl` → check sub-agent 所需的 spec（质量指南、检查约定，必要时同样的 research）

这两个清单不能替代 `implement.md`。`implement.md` 是复杂任务的人类可读执行计划；jsonl 只列出要注入或加载的上下文文件。

**如何发现相关 spec**：

```bash
python3 ./.trellis/scripts/get_context.py --mode packages
```

会列出每个 package 及其 spec layer 的路径。挑选与本任务领域匹配的条目。

**如何追加条目**：

可以直接在编辑器里改 jsonl 文件，也可以用命令：

```bash
python3 ./.trellis/scripts/task.py add-context "$TASK_DIR" implement "<path>" "<reason>"
python3 ./.trellis/scripts/task.py add-context "$TASK_DIR" check "<path>" "<reason>"
```

填入真实条目后，seed 的 `_example` 行可以删除（可选 —— 消费者会自动跳过）。

跳过条件：`implement.jsonl` 和 `check.jsonl` 已经有 agent 维护的真实条目（只剩 seed 行不算）。

[/Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

[codex-inline, Kilo, Antigravity, Windsurf]

跳过此步。Phase 2 的 `trellis-before-dev` skill 会直接加载上下文。

[/codex-inline, Kilo, Antigravity, Windsurf]

#### 1.4 激活任务 `[required · once]`

Artifact 评审通过后，把任务状态翻成 `in_progress`：

```bash
python3 ./.trellis/scripts/task.py start <task-dir>
```

轻量任务，`prd.md` 即可。复杂任务必须在 start 前评审完 `prd.md`、`design.md`、`implement.md`。在 sub-agent 平台上，如需额外的 spec / research 上下文，要补充 jsonl 清单；只剩 seed 行的清单消费者也能容忍。

命令成功后，breadcrumb 自动切到 `[workflow-state:in_progress]`，进入 Phase 2 / 3。

如果 `task.py start` 报错提示 session 身份缺失（hook 输入、`TRELLIS_CONTEXT_ID`、平台原生 session 环境变量都没拿到 context key），按错误提示配置 session 身份后重试。

#### 1.5 完成判据

| 条件 | 是否必需 |
|------|:---:|
| `prd.md` 存在 | ✅ |
| 用户确认任务可以进入实现 | ✅ |
| 已执行 `task.py start`（status = in_progress） | ✅ |
| `research/` 有 artifact（复杂任务） | 推荐 |
| `design.md` 存在（复杂任务） | ✅ |
| `implement.md` 存在（复杂任务） | ✅ |

[Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

| 需要额外 spec 或 research 上下文时，已维护 `implement.jsonl` / `check.jsonl` | 推荐 |

[/Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

---

## Phase 2: Execute

目标：把评审过的 planning artifact 变成能通过质量检查的代码。

#### 2.1 实现 `[required · repeatable]`

[Claude Code, Cursor, OpenCode, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

派发 implement sub-agent：

- **Agent type**: `trellis-implement`
- **Task description**: 按已评审的任务 artifact 实现代码，过程中查阅 `{TASK_DIR}/research/` 下的材料；结束时跑项目 lint 和 type-check
- **Dispatch prompt guard**：告诉被派发的 agent 它本身就是 `trellis-implement` sub-agent，必须直接实现，**不得**再派发另一个 `trellis-implement` / `trellis-check`。

平台 hook / 插件自动完成：
- 读取 `implement.jsonl`，把引用的 spec / research 文件注入到 agent 的 prompt
- 注入 `prd.md`，以及（如存在）`design.md`、`implement.md`

[/Claude Code, Cursor, OpenCode, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

[codex-sub-agent]

派发 implement sub-agent：

- **Agent type**: `trellis-implement`
- **Task description**: 按已评审的任务 artifact 实现代码，过程中查阅 `{TASK_DIR}/research/` 下的材料；结束时跑项目 lint 和 type-check
- **Dispatch prompt guard**：prompt **必须**以 `Active task: <task path>` 开头，然后明确说明被派发的 agent 已经是 `trellis-implement`，必须直接实现，**不得**再派发另一个 `trellis-implement` / `trellis-check`。

Codex sub-agent 定义自动处理上下文加载：
- 用 `task.py current --source` 解析活动任务，然后读取 `prd.md`、（如存在）`design.md`、`implement.md`
- 读取 `implement.jsonl`，要求 agent 在编码前加载每个引用的 spec / research 文件

[/codex-sub-agent]

[Kiro]

派发 implement sub-agent：

- **Agent type**: `trellis-implement`
- **Task description**: 按已评审的任务 artifact 实现代码，过程中查阅 `{TASK_DIR}/research/` 下的材料；结束时跑项目 lint 和 type-check
- **Dispatch prompt guard**：告诉被派发的 agent 它本身就是 `trellis-implement` sub-agent，必须直接实现，**不得**再派发另一个 `trellis-implement` / `trellis-check`。

平台 prelude 自动处理上下文加载：
- 读取 `implement.jsonl`，把引用的 spec / research 文件注入到 agent 的 prompt
- 注入 `prd.md`，以及（如存在）`design.md`、`implement.md`

[/Kiro]

[codex-inline, Kilo, Antigravity, Windsurf]

1. 加载 `trellis-before-dev` skill 读取项目规范
2. 读 `{TASK_DIR}/prd.md`，再（如存在）读 `design.md`、`implement.md`
3. 查阅 `{TASK_DIR}/research/` 下的材料
4. 按已评审的 artifact 实现代码
5. 跑项目 lint 和 type-check

[/codex-inline, Kilo, Antigravity, Windsurf]

#### 2.2 质量检查 `[required · repeatable]`

[Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

派发 check sub-agent：

- **Agent type**: `trellis-check`
- **Task description**: 对照 spec 和任务 artifact 评审所有代码改动；发现问题就地修复；确保 lint 和 type-check 通过
- **Dispatch prompt guard**：告诉被派发的 agent 它本身就是 `trellis-check` sub-agent，必须直接评审 / 修复，**不得**再派发另一个 `trellis-check` / `trellis-implement`。

Check agent 的工作：
- 对照 spec 评审代码改动
- 对照 `prd.md`、（如存在）`design.md`、`implement.md` 评审代码改动
- 自动修复发现的问题
- 跑 lint 和 typecheck 验证

[/Claude Code, Cursor, OpenCode, codex-sub-agent, Kiro, Gemini, Qoder, CodeBuddy, Copilot, Droid, Pi]

[codex-inline, Kilo, Antigravity, Windsurf]

加载 `trellis-check` skill，按其指引验证代码：
- Spec 合规
- lint / type-check / tests
- 跨层一致性（当改动跨层时）

发现问题 → 修复 → 重新检查，直到全部通过。

[/codex-inline, Kilo, Antigravity, Windsurf]

#### 2.3 回滚 `[on demand]`

- `check` 发现 prd 缺陷 → 回 Phase 1 修 `prd.md`，再重做 2.1
- 实现走偏 → 回退代码，重做 2.1
- 需要更多研究 → 研究（同 Phase 1.2），把结论写入 `research/`

---

## Phase 3: Finish

目标：保证代码质量、沉淀经验、记录工作。

#### 3.1 质量验证 `[required · repeatable]`

加载 `trellis-check` skill 做最终验证：
- Spec 合规
- lint / type-check / tests
- 跨层一致性（当改动跨层时）

发现问题 → 修复 → 重新检查，直到全部通过。

#### 3.2 调试复盘 `[on demand]`

如果本任务涉及反复调试（同一个问题被修过多次），加载 `trellis-break-loop` skill：
- 归类根因
- 解释为什么之前的修复失败
- 提出预防机制

目标是沉淀调试教训，让同一类问题不再复发。

#### 3.3 Spec 更新 `[required · once]`

加载 `trellis-update-spec` skill，复盘本任务是否产生了值得记录的新知识：
- 新发现的模式或约定
- 踩到的坑
- 新的技术决策

相应地更新 `.trellis/spec/` 下的文档。即使结论是「没什么要更新」，也要走一遍判断过程。

#### 3.4 提交代码 `[required · once]`

AI 主导对本任务代码改动的批量提交，让 `/finish-work` 随后能干净执行。目标：先产出 work commit，再让 bookkeeping commit（archive + journal）落地 —— **绝不**交错。

**分步流程**：

1. **检查脏状态**：
   ```bash
   git status --porcelain
   ```
   把每一条脏路径都记下来。如果工作树干净，直接跳到 3.5。

2. **学习最近的提交风格**（让起草的 message 融入仓库习惯）：
   ```bash
   git log --oneline -5
   ```
   留意前缀约定（`feat:` / `fix:` / `chore:` / `docs:` …）、语言（中文/英文）、长度风格。

3. **把脏文件分成两组**：
   - **本会话 AI 编辑过的** —— 你在本会话通过 Edit/Write/Bash 工具调用写过/改过的文件。你清楚改了什么、为什么。
   - **未识别的** —— 你本会话**没**碰过的脏文件（可能是用户手改、上次会话遗留的 WIP，或无关工作）。**不得**静默纳入提交。

4. **起草提交计划**。把 AI 编辑过的文件按逻辑分到不同 commit（一个 commit 对应一个连贯的改动单元，而不是一个文件一个 commit）。每条：`<commit message>` + 文件列表。未识别文件单独列在底部。

5. **一次性呈现计划，征求一次性确认**。格式：
   ```
   Proposed commits (in order):
     1. <message>
        - <file>
        - <file>
     2. <message>
        - <file>

   Unrecognized dirty files (NOT in any commit — confirm include/exclude):
     - <file>
     - <file>

   回复 'ok' / '行' 执行。回复修改意见，或 '我自己来' / 'manual' 终止。
   ```

6. **确认后**：按顺序对每个批次执行 `git add <files>` + `git commit -m "<msg>"`。不要 amend。不要 push。

7. **被拒绝时**（用户回 "不行" / "我自己来" / "manual" / 任何对计划的否定）：停止。**不要**再起第二个计划。用户会手动提交；他们确认后你跳到 3.5。

**规则**：
- 全程**不准** `git commit --amend` —— 三阶段三 commit 流程（work commits → archive commit → journal commit）。
- 本步骤**绝不** push 到远端。
- 如果用户希望换 message 措辞但接受文件分组，改 message 后再确认一次 —— 但只要他们拒绝分组，就退到手动模式。
- 批量计划只问一次，**不要**逐 commit 询问。

#### 3.5 收尾提醒

完成上面步骤后，提醒用户可以运行 `/finish-work` 收尾（归档任务、记录会话）。

---

## 自定义 Trellis（针对 fork）

本节面向想要修改 Trellis 工作流本身的开发者。所有自定义都通过编辑本文件完成；脚本只是 parser。

### 修改某个步骤的语义

直接编辑上方 Phase 1 / 2 / 3 区段中对应步骤的 walkthrough 正文。关键不变量：
- 无活动任务时必须先做请求分类，并在创建 Trellis 任务前征得同意。
- Planning 必须区分轻量（PRD-only）与复杂任务（在 start 前要有 `prd.md` + `design.md` + `implement.md`）。
- 任何必须经过的执行路径，都要让 Phase 3.4 commit 提醒在 `/trellis:finish-work` 之前可达。

所有 tag 块都在上方 `## Phase Index` 区段中，紧跟每个 phase 摘要之后：

| 作用域 | 对应 tag |
|---|---|
| 无活动任务（Phase 1 之前） | `[workflow-state:no_task]`（Phase Index ASCII 之后） |
| 整个 Phase 1（任务已创建 → 准备实现） | `[workflow-state:planning]`（Phase 1 摘要之后） |
| Codex inline 的 Phase 1 | `[workflow-state:planning-inline]` |
| Phase 2 + Phase 3.1–3.4（实现 + 检查 + 收尾） | `[workflow-state:in_progress]`（Phase 2 摘要之后） |
| Codex inline 的 Phase 2 + Phase 3.1–3.4 | `[workflow-state:in_progress-inline]` |
| Phase 3.5 之后（已归档） | `[workflow-state:completed]`（Phase 3 摘要之后；**当前 DEAD**） |

### 修改 per-turn prompt 文本

直接编辑对应 `[workflow-state:STATUS]` 块的正文。改完后跑 `trellis update`（模板维护者）或重启你的 AI session（自用项目）—— 不需要改任何脚本。

### 新增自定义状态

加一个新块：

```
[workflow-state:my-status]
your per-turn prompt text
[/workflow-state:my-status]
```

约束：
- STATUS 字符集：`[A-Za-z0-9_-]+`（允许下划线和连字符，例如 `in-review`、`blocked-by-team`）
- 必须有一个生命周期 hook 把 `task.json.status` 写成你的自定义值，否则这个 tag 永远不会被读
- 生命周期 hook 写在 `task.json.hooks.after_*` 里，绑定到 `after_create / after_start / after_finish / after_archive` 之一

### 新增生命周期 hook

在 `task.json` 里加 `hooks` 字段：

```json
{
  "hooks": {
    "after_finish": [
      "your-script-or-command-here"
    ]
  }
}
```

支持的事件：`after_create / after_start / after_finish / after_archive`。注意 `after_finish` ≠ 状态变化（它只清除活动任务指针）；「任务完成」类通知应使用 `after_archive`。

### 完整契约

工作流状态机的运行时契约、所有状态写入点、伪状态（`no_task` / `stale_<source_type>`）、hook 可达性矩阵以及其他深度细节，见：

- `.trellis/spec/cli/backend/workflow-state-contract.md` —— 运行时契约 + writer 表 + 测试不变量
- `.trellis/scripts/inject-workflow-state.py` —— 实际 parser（只读 workflow.md，不内嵌文本）
