# Trellis 使用感受

> 围绕「新增需求 = UI + 后端 + DB」这个最常见的全栈场景，对 Trellis 当前模型的 5 个真问题与对应解法。
> 配套阅读：[`trellis使用的思考.md`](./trellis使用的思考.md)（流程规划随笔）、[`../CLAUDE.md`](../CLAUDE.md)、[`../.trellis/workflow-ch.md`](../.trellis/workflow-ch.md)。

---

## 场景

新增一个需求，同时涉及：
- 前端 UI 页面（`app/` 或 `packages/react/`）
- 后端逻辑（`crates/flowscope-cli/` 的 serve / 审计 API）
- 数据库表（Neo4j 图 schema 或 `data/audit.db`）

下面 5 个问题就是从这个场景里冒出来的，每条都对应 Trellis 当前模型的一个简化代价。

---

## 1. UI + 后端 + DB 在 Trellis 里是几个 task？

**结论：1 个 parent task + 3 个子 task 是当前 Trellis 模型下最自然的形态**，但「拆 vs 合」要看反馈闭环能否在单个 task 内闭合。

### 决策表（替代「凭感觉」的拆分）

| 信号 | 倾向 |
|---|---|
| 任一层独立可发布、可回滚 | 拆 |
| 下一层需要等上一层先合并才能验证（DB→API→UI 典型链） | **拆**（按依赖顺序排子 task） |
| 任一层会影响别人（API 契约、DB schema） | **拆**（让 issue/PR 可追溯到单层） |
| 改动量 < 0.5 天 且不跨包 | 合（思考文档 §1.1 的 0.5 天阈值） |
| `task.json.package` 字段无法精确填一个值 | **拆**（合的代价就是这字段被迫空着） |

### 实际落地

```bash
python3 ./.trellis/scripts/task.py create "<feature> 顶层" --slug feat-app-foo
python3 ./.trellis/scripts/task.py create "DB schema 与迁移" --slug feat-data-foo-schema --parent 05-19-feat-app-foo
python3 ./.trellis/scripts/task.py create "审计/API 接口" --slug feat-cli-foo-api --parent 05-19-feat-app-foo
python3 ./.trellis/scripts/task.py create "前端表单/列表" --slug feat-app-foo-ui --parent 05-19-feat-app-foo
```

parent task 的 `prd.md` 写顶层用户故事 + Non-goals + 跨层依赖图（DB → API → UI 这条线），子 task 的 `prd.md` 写本层的契约与验收。Trellis 现成支持 `parent` 字段，`task.py add-subtask` 也是现成命令。

### 追问 1（2026-05-19，源码 + 官方文档验证）

> **1.1 明确要拆，敏捷编程里的 feature 对应到父 task。能不能新增 feature 别名？**

**结论：拆 = 官方推荐做法（有原文背书）；feature 别名是本地扩展，官方没有这个概念。**

官方架构文档 [Architecture / Team-level behavior](https://docs.trytrellis.app/advanced/architecture) 原文：

> **Subtask trees** — Parent tasks can hold shared requirements while child tasks run their own Plan -> Execute -> Finish loop.

也就是说"父 task 写共享需求 + 子 task 各跑独立的三阶段"是官方架构里的一等公民，对应 §3.1 的拆分建议。

但官方 task 实体只有 `task` 一种（详见 [ch06 Task Management Workflow](https://docs.trytrellis.app/guide/ch06-task-management)），**没有 `feature` 这个 type**。`.trellis/scripts/task.py` 的源码也确认了：`create` 只接 `--slug` / `--package` / `--parent` / `--priority` / `--assignee`，没有 `--type`（参见 `.trellis/scripts/task.py:399`）。

落地三种方案，按改动成本递增：

| 方案 | 怎么做 | 成本 |
|---|---|---|
| **零改动惯例** | 顶层 task 的 slug 强制以 `feat-` 前缀，子 task 用 `feat-<module>-<sub>` —— grep 就能筛 feature | 0 |
| **本地 wrapper** | 在 `.trellis/scripts/` 加一个 `feature.py`，转发到 `task.py create --slug feat-<x>`，自动创父+子骨架 | 半天 |
| **改 `task.py`** | 给 `create` 加 `--type feat\|story\|fix` 必填参数（思考文档 §6 落地工程项 1） | 1 天 + 后续同步上游 |

⚠️ 注意成本：方案 3 一旦做了，每次 `trellis update` 拉上游模板都得手工 merge `task.py`。

---

> **1.2 父 task 中写用户故事 + Goals（必须完成）+ 子 task 引用，类似 Claude Code 的 team 模式？**

**结论：用户故事 + Goals 写在 `prd.md` 是对的；子 task 引用 Trellis 已有原生支持；但"Claude Code team 模式"这个术语官方不存在，需要矫正成 **sub-agents**。**

**子 task 引用是现成机制**：`task.json` 已经有 `subtasks` 和 `children` 字段，由 `task.py add-subtask <parent> <child>` 维护（参见 `.trellis/scripts/task.py:454-461`）。父 task 的 `prd.md` 里再人工写一段「Subtasks」即可：

```markdown
## Goals（必须完成的硬目标）
- G1: 用户能在 UI 上保存 SQL 模板并复用
- G2: 模板按 owner / created_at 排序
- G3: 跨用户隔离（用户 A 看不到用户 B 的）

## Non-goals
- 不做分享 / 协作
- 不做版本历史

## Subtasks
- DB schema: .trellis/tasks/05-19-feat-data-tpl-schema
- API:       .trellis/tasks/05-19-feat-cli-tpl-api
- UI:        .trellis/tasks/05-19-feat-app-tpl-ui
```

**"Claude Code team 模式"需要矫正**：[Anthropic 官方 Claude Code 文档](https://docs.claude.com/en/docs/claude-code/sub-agents) 里没有 "team mode" 这个产品名 —— 多 agent 协作的官方术语就叫 **sub-agents**。Trellis 架构文档里出现的 "Team-level layer" 也不是 agent 编排概念，原文：

> Team-level layer: git-tracked workflow/spec/task files plus per-developer workspace memory, so multiple people and multiple AI tools operate against the same conventions.

意思是「多人 + 多 AI 工具共用同一套 workflow/spec/task 文件」 —— **是源文件层面的多人共享，不是 agent 之间的"组队"**。所以你要表达的"team 模式"，准确说法是：

- **Trellis 三个内置 sub-agents 协作**：`trellis-research` / `trellis-implement` / `trellis-check`（见 [Custom Sub-agents](https://docs.trytrellis.app/advanced/custom-agents) 官方表）
- **主会话做"协调者"**：派发 sub-agents、评审 diff、决定提交。Trellis 架构文档原文：「Only the main session may dispatch Trellis implement/check agents.」（也写在本地 `.claude/agents/trellis-implement.md:17`）

---

> **1.3 这就是 team 模式编程，不同 agent 要分配好。前提是多 agents 定义。**

**结论：定义已经现成（11 个平台中的任意一个），但"按子 task 分配不同 agent"在 Trellis 当前架构里 ≠ 派发不同 `name` 的 agent，而是 ≠ 派发同一个 `trellis-implement`，**但喂不同的 `implement.jsonl`**。**

官方架构文档（架构 / Agent and skill module）已经定义了：

| Sub-agent | 角色 | 主要上下文 |
|---|---|---|
| `trellis-research` | 调研代码、文档、API、备选方案；写到 `research/` | research prompt + 可选研究上下文 |
| `trellis-implement` | 按 PRD + spec 写代码 | `prd.md`、`info.md`、`implement.jsonl` |
| `trellis-check` | 评审 + 跑检查 + 自修 | `prd.md`、`check.jsonl`、改动文件 |

本地仓库这三个文件路径：`.claude/agents/trellis-{implement,check,research}.md`，frontmatter 已声明可用 `tools`。

"如何按子 task 分配 agent"的官方做法：

```
主会话（你）
  ├── 派发 trellis-research（带 DB 调研问题）→ 写 research/db-schema.md
  ├── 派发 trellis-implement（cwd=DB 子 task 目录，喂该 task 的 implement.jsonl）→ 改 schema
  ├── 派发 trellis-check（同子 task 目录）→ 评审 DB 改动
  ├── 派发 trellis-implement（cwd=API 子 task 目录）→ 改 Rust 代码
  ├── ...
```

**关键不变量**：派发 prompt 第一行必须是 `Active task: <task path from task.py current>`（`.trellis/workflow-ch.md:208` 明确写了），sub-agent 由此切换上下文。

如果真需要"DB agent / API agent / UI agent"这样的角色分化（比如 DB agent 拒绝改 Rust 代码），方案是 [Custom Sub-agents](https://docs.trytrellis.app/advanced/custom-agents)：自定义新 agent + 限制 `tools` 字段。但 Trellis 作者明确建议：

> If you plan to roll this out across your team, put the change in `.trellis/spec/backend/` (or wherever your convention lives) instead of the agent definition, so the sub-agent's behavior changes through spec injection rather than a fork.

也就是说 —— **优先用 spec 注入做"软约束"，不要轻易 fork agent 定义**。Trellis 把"分工"做成"上下文切片"，而不是"角色切分"。

---

> **1.4 补充特殊模块：数据 ETL 时上下文需要基于 Neo4j 查 2 度血缘，是单独开 py task 还是集成？要求改动小。**

**结论：不要单独开 py task。用 `trellis-research` sub-agent + `user-neo4j` MCP，0 代码改动就能跑通；进阶版改两个文件让它自动触发。**

#### 为什么不开单独 py task

| 单独开 py task 的问题 | 后果 |
|---|---|
| py task 跑出来的 cypher 结果还要**人手工**塞回 ETL task | 没解决"上下文进 ETL 上下文"这一步，等于白做 |
| 重复造轮子 —— `trellis-research` 就是为"先调研再实现"设计的 | 偏离 Trellis 架构 |
| py task 完成后会 archive，下次相似 ETL 又要重跑 | 没沉淀 |

正确做法：ETL 还是普通 task（`<MM-DD>-feat-data-<x>` 命名），把"查血缘"放到该 task 的 **research 阶段**，结果落到 `research/lineage-context.md`，自动注入 `trellis-implement`。

#### 本地已有的 Neo4j 接入双通道（验证过）

```bash
$ ls /Users/blank/.cursor/projects/.../mcps/user-neo4j/tools/
get-schema.json   # 拿图 schema
read-cypher.json  # 跑只读 cypher
write-cypher.json # 跑写 cypher

$ ls neo4j_proc/
parse_and_sink.py  setup_schema.py  sink/  ...
```

- **业务血缘图**：`neo4j_proc/` 已经把 SQL 解析结果落到 Neo4j（`M_TABLE` / `M_COL` / `CTE` / `UnionGroup` 4 类节点 + `READS_FROM` / `JOINS_WITH` / `REF_TEP` 关系，schema 详见 [`graph-schema.md`](./graph-schema.md)）
- **MCP 通道**：`user-neo4j` MCP 已注册，主会话和 sub-agent 都能直接调

—— 也就是说"查 2 度血缘"的所有基础设施都到位了，缺的只是"什么时候、怎么查、结果存哪、怎么注入"的流程串接。

#### 三档落地方案（从 0 代码到自动化）

##### Layer 0：手工 + jsonl 注入（今天就能跑，0 代码）

ETL 类 task 创建后，在 Phase 1.2 研究阶段执行 3 步：

```bash
# Step 1: 在主会话里调 user-neo4j MCP read-cypher，把 2 度血缘存成文件
cat > "$TASK_DIR/research/lineage-context.md" <<'EOF'
# 血缘上下文：dw_dwd.dwd_eng_device_active_da（2 度）

> 查询时间：2026-05-19
> Cypher：见文末

## 上游表（1 度）
| 表 | 关键列 | 过滤条件 |
| ... | ... | ... |

## 上游表（2 度）
...

## 下游表（1 度）
...

## 下游表（2 度，会受影响的下游）
...

## JOIN 关系（1 度）
...

## 原始 Cypher
```cypher
MATCH (t:M_TABLE {db_name: 'dw_dwd', table_name: 'dwd_eng_device_active_da'})
OPTIONAL MATCH path_up = (t)<-[:READS_FROM*1..2]-(up:M_TABLE)
OPTIONAL MATCH path_down = (t)-[:READS_FROM*1..2]->(down:M_TABLE)
OPTIONAL MATCH (t)-[j:JOINS_WITH]->(other:M_TABLE)
RETURN t, collect(DISTINCT up) AS upstream,
          collect(DISTINCT down) AS downstream,
          collect(DISTINCT {other: other, join: j}) AS joins
```
EOF

# Step 2: 挂进 implement.jsonl
python3 ./.trellis/scripts/task.py add-context "$TASK_DIR" implement \
  "research/lineage-context.md" "2 度血缘上下文，避免改坏下游"

# Step 3: 同步挂进 check.jsonl，让质检也能看到
python3 ./.trellis/scripts/task.py add-context "$TASK_DIR" check \
  "research/lineage-context.md" "验证 ETL 改动不破坏下游字段契约"
```

**改动量：0 行代码 / 0 个文件新建**。

##### Layer 1：让 `trellis-research` 自动跑（改 2 个文件，推荐 ⭐）

把 Layer 0 的人工步骤交给 sub-agent，让它在 ETL 类 task 的研究阶段自己跑：

**修改 1**：`.claude/agents/trellis-research.md` frontmatter 加 Neo4j MCP 工具：

```diff
 ---
 name: trellis-research
 tools: Read, Write, Edit, Bash, Glob, Grep,
        mcp__exa__web_search_exa, mcp__exa__get_code_context_exa,
+       mcp__neo4j__get-schema, mcp__neo4j__read-cypher
 ---
```

**修改 2**：在 `.trellis/spec/data/index.md`（思考文档 §2 标记"待建"的那份）里加一段「ETL 类 task 调研模板」：

```markdown
## ETL Research Protocol

任何 `feat-data-*` task 在 Phase 1.2 必须先派发 `trellis-research` 跑：

1. **2 度血缘查询**（用 `user-neo4j` MCP 的 `read-cypher`）：
   ```cypher
   MATCH (t:M_TABLE {db_name: $db, table_name: $tbl})
   OPTIONAL MATCH (t)<-[:READS_FROM*1..2]-(up:M_TABLE)
   OPTIONAL MATCH (t)-[:READS_FROM*1..2]->(down:M_TABLE)
   OPTIONAL MATCH (t)-[j:JOINS_WITH]->(o:M_TABLE)
   RETURN t,
          collect(DISTINCT {tbl: up,   depth: length((t)<-[:READS_FROM*]-(up))}) AS upstream,
          collect(DISTINCT {tbl: down, depth: length((t)-[:READS_FROM*]->(down))}) AS downstream,
          collect(DISTINCT {tbl: o, join: j}) AS joins
   ```

2. **CTE 链路展开**（如改的是含 CTE 的 SQL）：
   ```cypher
   MATCH path = (t:M_TABLE {db_name: $db, table_name: $tbl})
        <-[:REF_TEP*1..3]-(c:CTE)
   RETURN path
   ```

3. 结果写到 `{TASK_DIR}/research/lineage-context.md`，包含：
   - 上游 2 度表清单 + 每张表的关键列
   - 下游 2 度表清单 + 列级影响（哪些下游表会因为字段变更受影响）
   - JOIN 关系（at least join_type + condition）
   - 风险提示：如下游 2 度有线上看板/对外接口，标红

4. 把 `research/lineage-context.md` 加入 `implement.jsonl` 和 `check.jsonl`。
```

主会话在创建 ETL task 后只需要说一句：「派发 `trellis-research` 按 ETL Research Protocol 查 `dw_dwd.foo` 的血缘」—— sub-agent 看到 spec 就知道怎么跑。

**改动量：2 个文件（一个 agent frontmatter，一个新增 spec）**。

##### Layer 2：写专用 wrapper 脚本（最完整但成本最高）

如果发现频繁手工触发上面这段，再做：

```python
# .trellis/scripts/lineage_context.py
# 用法：python3 .trellis/scripts/lineage_context.py <task_dir> --table dw_dwd.foo --depth 2
```

脚本职责：
- 通过 `neo4j` Python 包跑 cypher（不绕 MCP）
- 把结果模板化写到 `<task_dir>/research/lineage-context.md`
- 调 `task.py add-context` 自动挂 jsonl
- 可选：作为 `after_create` hook，对 `package=data` 的 task 自动触发

**改动量：1 个新 Python 文件 + 可能改 `config.yaml`**。

#### 推荐路径

| 阶段 | 做什么 | 改动 |
|---|---|---|
| **今天** | Layer 0：跑一次手工流程验证血缘上下文真有用 | 0 |
| **本周** | Layer 1：改 agent frontmatter + 写 `.trellis/spec/data/index.md` | 2 个文件 |
| **跑 5+ 个 ETL task 后** | Layer 2：写 `lineage_context.py`，挂 `after_create` hook | 1 个新文件 + config |

#### 关键设计取舍

> **为什么放 `trellis-research` 不放 `trellis-implement`？**
>
> implement 阶段调 cypher 会让 sub-agent prompt 暴涨（cypher 输出经常上千行节点），而且每次 implement 重跑会拖慢。research 阶段跑一次、结果固化为文件、implement 阶段只读文件 —— 这是 Trellis "文件即知识"原则的标准用法。

> **为什么不开新 sub-agent `trellis-lineage`？**
>
> 呼应官方建议（追问 1.3 末段 Trellis 作者原话）：**优先用 spec 注入做"软约束"**。新建 sub-agent 会让派发模式越来越碎，跨平台同步成本上升。把 cypher 模板写在 spec 里、用现成的 `trellis-research` 跑，是最符合 Trellis 哲学的解。

---

## 2. UI / 后端 / DB 的上下文差异巨大，要在同一个 agent 里完成吗？

**不应该。这正是 `implement.jsonl` 设计出来的原因 —— 按 task 范围切上下文，每个子 task 派发独立的 `trellis-implement` sub-agent。**

参考 `.trellis/workflow-ch.md` 中 `[workflow-state:in_progress]` 段：

> Main-session default: dispatch implement/check sub-agents.
> Read context: jsonl entries -> `prd.md` -> `design.md if present` -> `implement.md if present`.

每个子 task 的 `implement.jsonl` 只塞自己这一层的 spec：

| 子 task | `implement.jsonl` 内容 |
|---|---|
| `feat-data-foo-schema` | `.trellis/spec/data/index.md`（思考文档 §2 标记"待建"，要先补） + `docs/graph-schema.md` |
| `feat-cli-foo-api` | `.trellis/spec/flowscope-cli/backend/index.md` + `.trellis/spec/flowscope-cli/backend/audit-api-spec.md` |
| `feat-app-foo-ui` | `.trellis/spec/flowscope-app/frontend/index.md` + `.trellis/spec/flowscope-app/frontend/ui-change-protocol.md` |

主会话只做派发 + 评审 + 提交，不直接写代码。**sub-agent 的 prompt 里看到的只有它该看到的 spec**，不会被 Rust 的契约文档干扰 React 的样式约定，反之亦然。

如果硬塞进一个 task 做完三层：`implement.jsonl` 会同时塞 `app + cli + data` 三套 spec，sub-agent prompt 膨胀，hallucination 概率上升 —— 这是合 task 的隐性代价（思考文档没明说，但从 jsonl 机制反推可见）。

### 追问 2（2026-05-19，源码 + 官方文档验证）

> **2.1 明确下 `implement.jsonl` 是做什么的？是父 task 还是子 task 中存在？**

**结论：每个 task 目录（无论父子）都有一份独立的 `implement.jsonl`，分别注入给该 task 派发的 `trellis-implement` sub-agent。**

官方 [Appendix D: JSONL Configuration Format Reference](https://docs.trytrellis.app/advanced/appendix-d) 原文（一句话定义 + 三句话规则）：

> JSONL entries should point at spec files (`.trellis/spec/**`) or the task's research outputs (`{TASK_DIR}/research/*.md`) — things the sub-agent needs to read before writing code (rules + background). Don't add raw source files or directories (...) — sub-agents already have `Read` / `Grep` and will fetch code when they need it.

也就是 `implement.jsonl` 是「**写代码之前必须先读哪些规范和上下文**」的清单 —— 给 `trellis-implement` 的"预读手册"。

**官方支持的 JSONL 文件**（同一文档表格）：

| 文件 | sub-agent | 典型内容 |
|---|---|---|
| `implement.jsonl` | `trellis-implement` | workflow + 相关 spec 索引 + 任务 `research/` 目录 |
| `check.jsonl` | `trellis-check` | 质量类 spec + finish-work / check 命令 spec |
| `research.jsonl` | `trellis-research` | 调研用参考材料（spec 或外部文档摘录） |

**位置 = task 目录（与父子无关）**：官方架构文档 [Task store module](https://docs.trytrellis.app/advanced/architecture) 把 `implement.jsonl` 列在 task 目录结构里：

```
.trellis/tasks/<MM-DD-slug>/
├── task.json
├── prd.md
├── info.md
├── implement.jsonl   ← 每个 task 自己一份
├── check.jsonl       ← 每个 task 自己一份
└── research/
```

注意官方目录里**没有 `design.md`** —— 文件叫 `info.md`（Optional technical design）。本仓库 `.trellis/workflow-ch.md` 里仍叫 `design.md`，这是本仓库的本地化命名，并非官方默认。

**父子 task 的 `implement.jsonl` 关系**：

- **完全独立**，没有继承机制。父 task 的 jsonl 不会自动传递给子 task。
- 父 task 如果只是"聚合器"（不直接产出代码），它的 `implement.jsonl` 可以只放一行：`{"file": "<parent-prd>", "reason": "feature-level requirements"}`，或者干脆留 seed 行。
- 子 task 各自维护自己那层的 spec 清单。
- 如果子 task 需要看父 task 的 PRD，可以在子 task 的 `implement.jsonl` 里加：`{"file": ".trellis/tasks/<parent>/prd.md", "reason": "Parent feature requirements"}`。**Trellis 官方推荐的"feature 上下文共享"方式就是这条**。

---

> **2.2 父 task 对应的 agent 的功能需要明确边界。**

**结论：这是个**重要的反向问题**——Trellis 当前架构里"父 task 没有专属 agent"。官方设计是「主会话 = 父 task 的协调者」，三个 sub-agent 只服务于「正在写代码的子 task」。**

依据：

- 官方 [Architecture / Agent and skill module](https://docs.trytrellis.app/advanced/architecture) 只列了 `trellis-research` / `trellis-implement` / `trellis-check` 三个 sub-agent，**没有 `trellis-feature` / `trellis-orchestrator` 一类的父级 agent**。
- 工作流原文：「Only the main session may dispatch Trellis implement/check agents.」 ——派发权属于主会话，不能授权给某个 sub-agent。

所以"父 task agent"的边界，事实上落在**主会话**身上，职责清单：

| 阶段 | 主会话（父 task 协调者）做什么 | 主会话**不**做什么 |
|---|---|---|
| Plan | 写父 task `prd.md`（用户故事 + Goals + Non-goals + Subtasks 列表）；调用 `task.py create --parent` 派生子 task | 不写代码 |
| Execute | 按依赖顺序（DB → API → UI）逐个 `task.py start <child>`；对每个子 task 派发 `trellis-implement` + `trellis-check`；评审 sub-agent 返回的 diff | 不亲自实现细节 |
| Bug 出现 | 决定 bug 归属哪个子 task；记录在该子 task 的 `prd.md`；按需触发 `/trellis-break-loop` | 不在父 task 里直接修代码 |
| Finish | 全部子 task 完成后，在父 task 自己跑 Phase 3.3 `/trellis-update-spec`、Phase 3.4 commit、`/trellis:finish-work` | 不能跳过子 task 单独 finish 父 task |

如果你想把"父 task 协调者"也变成一个 sub-agent（例如限定它只能调用 `task.py` 和 `Read`，不能直接 `Edit`），那是 [Custom Sub-agents](https://docs.trytrellis.app/advanced/custom-agents) 章节的扩展。一个示例 frontmatter：

```yaml
---
name: trellis-feature-coordinator
description: Coordinates a parent task's subtasks. Reads PRDs, dispatches child implement/check, never edits code.
tools: Read, Bash, Glob, Grep
---
```

但要意识到 Trellis 作者明确不鼓励这种 fork，建议先用主会话 + spec 注入解决。

---

## 3. 测试时遇到 bug —— vibe code 还是走流程？

**强制走 bug 处理流程。** CLAUDE.md 顶部「Bug Handling（MANDATORY）」已经写死：

```
1. 在当前 Trellis 任务里记录 → 2. 修复 → 3. **立即** `/trellis-break-loop` → 4. `/trellis-update-spec`

禁止"对话中发现 → 直接修 → 继续聊"——会丢失因果链，下次类似场景仍会犯错。
```

具体落地两种情况：

| 场景 | 处理方式 |
|---|---|
| **当前 feature task 自测时发现的 bug**（属于"实现没到位"） | 在当前子 task 的 `prd.md` 加「问题/缺陷」段，或建 `research/bug-<n>.md`；修完跑 `/trellis-break-loop` + `/trellis-update-spec`，**不另开 task**（属于实现范围） |
| **已 archive 的 task 在后续测试中暴露的 bug**（属于"上次没修干净"） | 按思考文档 §3.1 新建 `fix` 类 task：`<MM-DD>-fix-<module>-<slug>`；`prd.md` 必须含**复现步骤 + 失败测试用例 + 严重度**；Finish 阶段交付 before/after 二段验收报告 |

思考文档 §0 那句"agent 拿不到反馈就废"就是冲这个场景写的 —— **不写 repro 测试就不知道修没修好**。

> 反面教材：CLAUDE.md 第 35 行提到 2026-05-13~05-15 期间 7 个 task 全部漏写 journal，事后才 backfill。这就是 vibe-fix 不归档的成本。

### 追问 3（2026-05-19，源码 + 官方文档验证）

> **3.1 如果强制走 bug 处理，要在 `trellis使用的思考.md` 里明确。研发过程中的 bug 该如何定义？**

**结论：Trellis 官方文档**没有**专门定义 "研发期 bug vs 用户反馈 bug" 的分类。`/trellis-break-loop` skill 的 5 类根因分类是目前最接近的官方分类工具，可以基于它派生出研发期 vs 用户期的处理路径区分。**

依据：

- 官方 [ch06 Task Management](https://docs.trytrellis.app/guide/ch06-task-management) 和 [Architecture](https://docs.trytrellis.app/advanced/architecture) 都没有"bug 类型"的术语表 —— 在 Trellis 模型里 bug 就是一个 `status=planning/in_progress` 的普通 task，没有 `task.type=bug` 字段。
- 唯一接近的分类来自 `.claude/skills/trellis-break-loop/SKILL.md:18-26`（本仓库本地副本，与官方一致）的根因 5 类：A. Missing Spec / B. Cross-Layer Contract / C. Change Propagation Failure / D. Test Coverage Gap / E. Implicit Assumption。

**建议在 `trellis使用的思考.md` §1 或 §3.1 补一段**（项目本地约定，不是官方）：

| Bug 来源 | 命名约定 | task 形态 | 必须的额外产物 |
|---|---|---|---|
| **研发期 bug**（当前 task 自测中暴露） | 不另开 task | 写入当前子 task 的 `prd.md` 「## 缺陷」段，或新增 `research/bug-<N>.md` | repro 步骤 + 修复后 before/after |
| **联调期 bug**（跨子 task 之间集成失败） | 不另开 task | 写入 parent task 的 `prd.md` 「## 集成缺陷」段 | 必须标注是哪两个子 task 的契约不匹配 |
| **用户反馈 bug**（已发布功能被人发现） | `<MM-DD>-fix-<module>-<slug>` | **独立新 task**（思考文档 §3.1） | severity 字段 + repro 测试用例先红再绿 |
| **回归 bug**（曾经修过又复发） | 同上 + 后缀 `-regression` | **独立新 task** | 必须强制 `/trellis-break-loop`，分析为什么上次修复没拦住 |

为什么要这么分？呼应思考文档 §0「能力上限 = 反馈闭环」：研发期 bug 的反馈链是「自测 → 自修」，本身就在当前 task 闭环里；用户反馈 bug 的反馈链是「现场 → issue → task → PR → spec」，需要 task 实体把这一链路串起来。

---

> **3.2 `/trellis-break-loop` 和 `/trellis-update-spec` 这两个命令是什么？**

**它们不是 shell 命令，是 Trellis 平台层注册的 skill / slash command。本地源码在 `.claude/skills/trellis-{break-loop,update-spec}/SKILL.md`，对应官方 [Architecture / Agent and skill module](https://docs.trytrellis.app/advanced/architecture) 提到的 skill 路由。**

| Skill | 触发时机 | 核心动作 | 产出 |
|---|---|---|---|
| `/trellis-break-loop` | bug 修完后**立即**触发（CLAUDE.md MANDATORY） | 按 5 维框架做深度分析：① 根因分类（5 类）② 之前修复为什么失败 ③ 预防机制（6 类，文档/架构/编译/运行时/测试/Review）④ 系统扩散（类似问题在哪）⑤ 知识沉淀清单 | 一段结构化 Markdown 分析报告 + **必须**立即跑 `/trellis-update-spec` 落地，否则分析白做 |
| `/trellis-update-spec` | bug 修复后、新功能实现后、踩到隐式约定后 | 判断要更新的是 **code-spec** (`.trellis/spec/<layer>/*.md`) 还是 **thinking guide** (`.trellis/spec/guides/*.md`)；按 7 段模板（Scope / Signatures / Contracts / Validation Matrix / Cases / Tests / Wrong vs Correct）写入 | 更新后的 spec 文件 + 必要时更新 `index.md` |

两者关系（来自 `.claude/skills/trellis-update-spec/SKILL.md:334-345` 原文）：

```
Learn something → /trellis-update-spec → Knowledge captured
     ↑                                  ↓
/trellis-break-loop ←──────────────── Future sessions benefit
(deep bug analysis)
```

通俗说：`break-loop` 是「想清楚为什么会出 bug，和怎么不再犯」，`update-spec` 是「把这次的教训刻进规范文件，让下次的 AI/人不重蹈覆辙」。前者不落地，等于没分析。

⚠️ 本仓库的写法是 `/trellis-break-loop`（连字符）和 `/trellis-update-spec`，官方在某些文档里写作 `/trellis:break-loop`（冒号），两种形式都对，取决于平台。

---

> **3.3 验收标准如何定义？UI / 后端的标准不一样。**

**结论：Trellis 官方**不内置**按层区分的验收标准 —— 它把验收标准的"在哪写"定义清楚，"写什么"由项目自己在 `.trellis/spec/<layer>/index.md` 维护。**

依据：

- 官方 [Architecture / Spec library](https://docs.trytrellis.app/advanced/architecture)：「Spec library — Project conventions and thinking guides under `.trellis/spec/`.」 ——验收标准属于 project conventions，要项目自己维护。
- 本仓库已有 9 个 layer 入口：
  ```
  .trellis/spec/flowscope-app/frontend/index.md
  .trellis/spec/flowscope-react/frontend/index.md
  .trellis/spec/flowscope-react/backend/index.md
  .trellis/spec/flowscope-core/backend/index.md
  .trellis/spec/flowscope-core/frontend/index.md
  .trellis/spec/flowscope-cli/backend/index.md
  .trellis/spec/flowscope-export/backend/index.md
  .trellis/spec/flowscope-wasm/backend/index.md
  .trellis/spec/flowscope-vscode-webview/frontend/index.md
  ```
- 但**只有 `flowscope-app/frontend` 有 ui-change-protocol.md 这种细化协议**，其他 layer 暂无对应的验收 checklist。

**推荐写法：在每个 `index.md` 加一段「## Acceptance Checklist」**（思考文档 §3.2.1~3.2.5 已经把内容草拟好了，把它落到对应 spec 文件即可）：

**`.trellis/spec/flowscope-app/frontend/index.md` 追加片段示例**：

```markdown
## Acceptance Checklist（UI 类 task 必须全勾）

### 必跑命令
- [ ] `cd app && yarn build`
- [ ] `cd app && yarn typecheck`
- [ ] `cargo build -p flowscope-cli --features serve`（embed 新 bundle）

### 必有产物
- [ ] `prd.md` 含「目标元素」段（文件 + 行号 + DOM selector）
- [ ] `research/screenshots/before.png` + `after.png`
- [ ] 用 Cursor IDE 浏览器 MCP 跑核心交互路径并截图入 PRD

### 跨层验证
- [ ] API 数据已用 curl 验证（不对 → 先修 Rust）
- [ ] CLI Serve 模式启动后手动验证目标行为
```

**`.trellis/spec/flowscope-cli/backend/index.md` 追加片段示例**：

```markdown
## Acceptance Checklist（Backend / API 类 task 必须全勾）

### 必跑命令
- [ ] `cargo fmt --all -- --check`
- [ ] `cargo clippy --workspace -- -D warnings`
- [ ] `cargo test -p flowscope-cli`
- [ ] `cargo test -p flowscope-cli --features serve`（embed 模式）

### 必有产物
- [ ] `prd.md` 含 API 契约：方法 + 路径 + 请求/响应字段 + 错误码
- [ ] 新增/修改的 fixture 落在 `crates/flowscope-cli/tests/fixtures/`
- [ ] 若改 audit API：契约（详情含 sql_text/result_json，列表不含）未破坏

### 跨层验证
- [ ] 手动 `./target/debug/flowscope --serve --port 3099 --audit-log data/audit.db` + curl 走核心路径
- [ ] 若涉及 EdgeType：同步前端 `packages/react/src/constants.ts` + `Legend.tsx`
- [ ] 影响分析（高风险写进 PRD）
```

**为什么 Trellis 把验收清单放 spec 而不是 workflow？**

`/trellis-check` skill 的源代码（`.claude/agents/trellis-check.md:28-30`）原文：

> Before checking, read:
> - `.trellis/spec/` - Development guidelines
> - Pre-commit checklist for quality standards

也就是说 `trellis-check` sub-agent 在每次质量检查时**会自动加载对应 layer 的 `index.md`**。把验收清单写在 spec 里，下次 sub-agent 就能自动按这份清单逐项检查 —— 这就是为什么思考文档 §6.3 的"落地工程项 3"（acceptance-checklists 落到每个 spec 的 `acceptance.md`）成立。

---

## 4. 需求对应 feature，但 Trellis 没有 feature 概念？

**对，戳到一个真简化。Trellis 的实体只有 Task；feature 是用 parent task 隐式表达的。**

| 概念 | Trellis 里的承载 |
|---|---|
| Feature | `parent` 字段为 `null` 的 task（自己当聚合点） |
| Story / Sub-task | `parent` 指向 feature task 的 task |
| Bug | 独立 task，type=`fix`（思考文档 §1.1 提案的枚举） |

这个简化的代价是：

- ❌ 不能用一个命令查"这个 feature 当前进度多少 %"
- ❌ `package` 字段被迫只能填一个，跨层 feature 没法表达
- ❌ Sprint / 版本规划没有原生支持（要靠 task 命名前缀或外部工具）
- ✅ 换来的好处：没有 JIRA 那种"史诗→特性→故事→任务"的层级负担，单人开发跑得动

如果想补齐 feature 概念，思考文档 §6 已经把候选改造列出来了（`feat-infra-task-py-type-args`），可以再加一条：给 `task.py create --type feat` 自动生成 parent task 模板。

---

## 5. UI 截图、DOM 元素信息为什么不在 PRD 上下文里？

**问题分两半：（a）截图理论上应该进 PRD/research，（b）当前没有任何工具强制这一点 —— 完全靠 brainstorm 阶段的人盯着。**

### 当前 Trellis 的两层上下文 split

```
prd.md            → 文本上下文（人写、sub-agent 读）
implement.jsonl   → spec/research 文件清单（不含代码、不含图片）
```

UI 协议（路径在 [`.trellis/spec/flowscope-app/frontend/ui-change-protocol.md`](../.trellis/spec/flowscope-app/frontend/ui-change-protocol.md)）已经定了 PRD 模板：

```markdown
## 目标元素
- 文件：`app/src/components/FileSelector.tsx`
- 位置：Line 530，Audit History section 的 button
- data-testid / ref / className：（从 snapshot -i 获取）

## 当前行为
（截图 + 描述）

## 期望行为
（截图 + 描述，或文字）
```

### 为什么实际任务里经常没有？

1. **brainstorm skill 没强制问**：现在 `/trellis-brainstorm` 提的是开放式问题，没把"截图 + 组件 + 行号 + DOM ref"做成强制 prompt。
2. **截图是二进制**：git diff 看不出变化，spec 文档也没法 grep；社区试过一次（`05-18-verify-screenshot-in-task` 这个归档 task 就是验证截图能不能嵌进 task），结论是放 `research/screenshots/`，PRD 用 markdown 引用。
3. **`implement.jsonl` 只接 spec/research 文件路径**：截图本身不能直接列在 jsonl，必须包一层 markdown（比如 `research/ui-elements.md`，里面用 `![](screenshots/before.png)` 引用）。

### 推荐落地（不需要改 Trellis 框架，纯流程修正）

凡是 UI 类子 task：

1. **brainstorm 时强制产出**（参考 CLAUDE.md「前端改动规则 MANDATORY」）：
   - `prd.md` 写组件路径 + 行号 + DOM selector + curl 验证结论
   - `research/screenshots/before.png` / `after-mock.png`
   - `research/ui-elements.md`（截图引用 + DOM 路径 + selectors + role + aria-label）

2. **在 `implement.jsonl` 里挂上** `research/ui-elements.md`：
   ```json
   {"file": "research/ui-elements.md", "reason": "UI 元素定位 + 当前/期望状态截图"}
   ```
   sub-agent 派发时 hook 会自动注入，写代码前就有元素地图。

3. **brainstorm 阶段的"gate"**：上面三件没齐 → 不让 `task.py start`。这条目前只在 CLAUDE.md 文字层强制，没有工具层 enforcement，是思考文档 §6 落地工程项 3 的候选。

### 追问 4（2026-05-19，源码 + 官方文档验证）

> **4.1 spec 不是沉淀的知识吗？为什么 spec 里会有 PRD 模板？**

**结论：你戳到一个真分层错位。`ui-change-protocol.md` 是混合体 —— 同一份文件塞了三种不同性质的内容，PRD 模板严格说不属于"沉淀的知识"，但放在 spec 里是工程上的务实折中。**

#### Trellis 官方的 spec 分类（已落地，可验证）

`.claude/skills/trellis-update-spec/SKILL.md:72-77` 原文表（也是官方 [Architecture / Spec library](https://docs.trytrellis.app/advanced/architecture) 的实现层定义）：

| 类型 | 位置 | 目的 | 内容风格 |
|---|---|---|---|
| **Code-Spec** | `<layer>/*.md` | 告诉 AI **怎么安全实现** | Signatures, contracts, matrices, cases, test points |
| **Guide** | `guides/*.md` | 帮 AI **写之前先想什么** | Checklists, questions, pointers to specs |

本仓库已经按这个分层落地了，验证：

```bash
$ ls .trellis/spec/guides/
fix-location-thinking-guide.md
cross-layer-thinking-guide.md
code-reuse-thinking-guide.md
index.md
```

—— `guides/` 全部是思考触发器，不是 PRD 模板。

#### 那 PRD 模板属于第几类？

**严格分类法（官方两分法下的归位）**：

| 内容 | 性质 | 应该放的位置 |
|---|---|---|
| "调用什么 API / 怎么写 fetch" | Code-Spec | `flowscope-app/frontend/api-conventions.md`（spec layer） |
| "改 UI 前先想 API 是不是数据问题" | Thinking Guide | `guides/ui-data-validation-guide.md` |
| **"PRD 必须包含目标元素 + 截图 + curl 验证段"** | **工作流模板 / Template** | **既不是 spec 也不是 guide，是"过程模板"** |
| "打包顺序：yarn build → cargo build → 重启" | Code-Spec（构建契约） | `flowscope-app/frontend/build-order.md` |

**官方没有"templates"这个分类**，从 [Architecture](https://docs.trytrellis.app/advanced/architecture) 的 Spec library 段就能看出来。`trellis-update-spec` skill 里出现的 "Sync templates" 那行（`.claude/skills/trellis-update-spec/SKILL.md:127`）指的是 **Trellis CLI 自己的源码模板**（`src/templates/markdown/spec/`），不是用户级"PRD 写作模板"。

也就是说 —— **Trellis 官方在概念层就没给"PRD 模板"留位置**。`ui-change-protocol.md` 把它塞进 spec 是社区/项目的本地权宜之计。

#### 为什么实操上**还是**塞 spec？务实理由

塞 spec 不"纯"，但有 3 个工程优势：

1. **sub-agent 自动加载**：`trellis-implement` 派发时，hook 会读 `implement.jsonl`，里面挂上 `flowscope-app/frontend/ui-change-protocol.md` 就能自动注入 —— PRD 模板要发挥作用，必须在 brainstorm 阶段被 AI 看见。templates 目录如果不被注入，就是死文档。
2. **避免再造一个分类轴**：再开一个 `.trellis/templates/` 目录意味着 brainstorm skill 要新增一条加载路径、`trellis-update-spec` 要新增一个"模板更新"判断分支、文档要新增一段说明 —— 维护负担 ≥ 收益。
3. **"模板 + 协议"难拆**：`ui-change-protocol.md` 里"必须先 curl 验证 API"既是思考触发器（属于 guide）又是 PRD 必填段（属于模板），物理上拆不开。

#### 三种处理方案

| 方案 | 改动量 | 优劣 |
|---|---|---|
| **A. 接受现状**（混合体留 spec） | 0 | 务实，但概念层有错位，新人会困惑 |
| **B. 三段拆分**（thinking 入 guides，模板入 brainstorm skill 的 "Artifact Rules" 段，构建入 spec 新文件） | 半天 | 概念正本清源，但要改 brainstorm skill 和 jsonl 引用 |
| **C. 新增 `.trellis/templates/`** + brainstorm skill 加载路径 | 1 天+ | 最干净，但维护负担最大，也是上游不支持的发明 |

**推荐 B**：把 `ui-change-protocol.md` 拆成：

```
.trellis/spec/guides/ui-data-validation-guide.md        # "改前先 curl 验证 API" 思考触发
.trellis/spec/flowscope-app/frontend/ui-change-protocol.md  # 保留：构建顺序 + 浏览器 MCP 选型（code-spec 性质）
.claude/skills/trellis-brainstorm/SKILL.md              # 在 "Artifact Rules" 段嵌入"UI 类 task 的 PRD 必须包含..."
```

这样 spec 重新纯净，模板内嵌进 brainstorm 工作流，不丢自动注入能力。

#### 一句话回答你的问题

> **spec 是"沉淀的知识"，PRD 模板严格说不属于"知识"而属于"工作流契约"。当前文件混合在一起是务实折中（为了被自动注入），代价是概念混乱。理论最优解是把 PRD 模板移到 brainstorm skill，但实操上社区普遍接受这种"小污染换大便利"。**

---

### 追问 5（2026-05-19，源码 + 官方文档验证）

> **5.1 真实使用过程中，截图就是没存。日后回头不知道当时情况。**

**先承认这是真实漏洞，再分析根因，最后给出按强制力分层的工程化解法。**

#### 根因分析（4 层都有问题）

| 层 | 漏洞 | 证据 |
|---|---|---|
| **L1 工具** | Cursor IDE Markdown Preview **不渲染** 本地相对路径图片，只显示 alt 文字 | `.trellis/tasks/archive/2026-05/05-18-verify-screenshot-in-task/prd.md:31-36` 实测结论 |
| **L2 流程** | 截图 → 命名 → 移动到 `research/screenshots/` → PRD 写 markdown 引用，**4 步上下文切换** | `ui-change-protocol.md:64-83` 的模板要求 |
| **L3 心智** | 修 bug 时心思全在修复，截图被推迟到归档前，归档前已经忘了"当时是什么样" | 经验法则 |
| **L4 enforcement** | 没截图也能 `task.py start` / `git commit` / `task.py archive`，没有任何工具层 gate | `task.py` 源码无截图检查 |

**L1 是被忽视最严重的根因**：之前我在追问 4 推荐的"放 `research/screenshots/` + markdown 引用"，**在 Cursor Preview 里看不见**。看不见 → 不会有"截图有价值"的正反馈 → 下次更不愿意截 → 漏洞滚雪球。

#### 解法分层（按强制力 ↑ + 成本 ↑）

##### Layer 1：**修 L1 工具问题**（必做，0 成本）

把 05-18 task 的结论硬化：

| 选项 | 操作 | 适用 |
|---|---|---|
| **图床 / GitHub Issue** | 拖图到 GitHub Issue 评论框，复制返回的 `https://user-images.githubusercontent.com/...` URL，粘到 PRD | 需要联网，但跨设备永久可见 |
| **本地保留 + 不走 Preview** | 截图存 `research/screenshots/`，PRD 里只写文件名（不写 markdown 图片语法），需要看时直接打开 png | 离线 OK，但要养成"用 Finder/资源管理器打开"的习惯 |
| **换扩展** | 在 Cursor 里装 `Markdown Preview Enhanced` 或 `Markdown All in One`，它们渲染本地图片 | 一次性配置，但要全 team 统一 |

**推荐组合**：日常用本地 `research/screenshots/`（git 追踪二进制），关键节点（bug 严重度 blocker / 跨包变更）额外传一份到 GitHub Issue 当主参考。

##### Layer 2：**让截图"顺手"**（半天工程，最有效）

写一个 shell 函数或脚本，把"截图 → 命名 → 移动 → 引用"压缩成 1 行：

```bash
# 加到 ~/.zshrc 或仓库 scripts/screenshot-to-task.sh
screenshot() {
  local label="${1:-shot}"
  local task_dir=$(python3 ./.trellis/scripts/task.py current 2>/dev/null | tail -1)
  if [[ -z "$task_dir" ]]; then echo "No active task"; return 1; fi
  local target="$task_dir/research/screenshots/$(date +%H%M%S)-$label.png"
  mkdir -p "$(dirname "$target")"
  screencapture -i "$target"   # macOS 交互式截图
  echo "Saved: $target"
  echo "Markdown: ![${label}](./research/screenshots/$(basename "$target"))" | pbcopy
  echo "(已复制 markdown 引用到剪贴板)"
}
```

调用：`screenshot before` → 框选区域 → 自动保存到 active task + markdown 引用进剪贴板。

**为什么这一步最关键**：根据「最小阻力原则」，只要把工具成本从 4 步降到 1 步，"忘记截图"的概率会断崖式下降。

##### Layer 3：**brainstorm 阶段加截图门禁**（轻度修改 skill）

在 `.claude/skills/trellis-brainstorm/SKILL.md` 的 "Artifact Rules" 段加一条 UI 类 task 强制问题：

```markdown
## UI 类 task 强制问题（在 prd.md 落地前必须问完）

1. **当前状态截图**：用户能否提供一张"现在看到的样子"？
   - 期望：`research/screenshots/before-*.png` 至少 1 张
   - 如果回答"先不截，我直接说"，必须在 PRD「## 当前行为」段用文字详细描述（颜色、位置、点击后的反馈）

2. **期望状态截图或描述**：用户能否提供一张"希望变成的样子"？或者文字版

3. **目标元素**：组件文件 + 行号 + DOM selector（用 `screenshot` 命令或 Chrome DevTools 拿）
```

skill 是 brainstorm AI 自己读的，不需要改框架代码。

##### Layer 4：**finish-work / archive 加 lint**（兜底，中等成本）

修改 `/trellis-finish-work` 命令（或它调用的脚本），在归档前检查：

```python
# 伪代码
if task.json 的 package 含 'app' 或 'react' 或 'vscode':
    screenshots = glob(f"{task_dir}/research/screenshots/*.png")
    if len(screenshots) == 0:
        warn("UI 类 task 但没有截图，回头看会看不懂。确认要归档吗？(y/N)")
```

这是最后一道关卡，已经晚了，但能拦住"完全裸归档"的最坏情况。

##### Layer 5：**task.py validate 加 hard gate**（最强约束，最大成本）

给 `task.py start` 加 module-aware 校验：

- module=app/react/vscode 且 `research/screenshots/` 为空 → `task.py start` 失败
- 失败提示："UI 类 task 必须先有当前状态截图。运行 `screenshot before` 或加 `--no-screenshot` 跳过"

这条改 Trellis 框架，破坏上游兼容性，**只在团队大到没办法靠自觉时才上**。

#### 给你的推荐组合

| 阶段 | 做什么 | 成本 | 收益 |
|---|---|---|---|
| **本周** | Layer 1（图床方案落到 `ui-change-protocol.md`）+ Layer 2（写 `screenshot` 函数） | 半天 | 立刻消除 80% 的"截图没存"问题 |
| **本月** | Layer 3（brainstorm skill 加门禁问题） | 1 小时 | 让 AI 主动催截图 |
| **下季度** | 视频/截图丢失率仍 > 30% → 上 Layer 4 finish-work lint | 1 天 | 兜底 |
| **暂不做** | Layer 5（task.py hard gate） | 2 天+ | 收益 < 上游兼容性代价 |

#### 关于"日后回头不知道情况"的额外护栏

即使有截图，3 个月后回头看仍可能"看不懂当时为啥这么改"。建议 PRD 模板里强制三段：

```markdown
## 当前行为
- 截图：![before](url-or-file)
- 文字复现路径：访问 X → 点 Y → 发现 Z
- 数据快照（如有）：API 返回的 JSON 摘要

## 为什么有问题（用户视角）
- 直接说"不符合 X 期望"，不只说"看起来不对"

## 期望行为
- 截图：![after-mock](url-or-file)
- 验收语：用什么测试 / 操作能确认"修对了"
```

第一段截图 + 第二段"为什么有问题"是抗"上下文遗忘"的关键 —— 6 个月后回看，靠这两段重建当时的判断。

---

## 6. Issue → Task → Branch → PR 全链路能不能自动化？

> 补录题：GitHub / GitLab 仓库里用户提的 issue 能不能自动变 task、自动切分支修复、自动提 PR？

**结论：目前 Trellis 官方**只内置「task → 外部 tracker」单向同步样板**，**没有**「外部 issue → task」反向自动化；切分支和提 PR 也都是"半自动"——记录字段是有的，自动操作要靠 MCP 或自写脚本补齐。**

### 现状四层验证

| 链路环节 | 官方 Trellis | 本仓库 `.trellis/scripts/` | 本地 GitLab MCP plugin |
|---|---|---|---|
| **Issue → Task** 自动创建 | ❌ 无内置 | ❌ 无（`hooks/linear_sync.py` 是反向：task → Linear） | ✅ 主会话可调 MCP 读 issue 内容，但要人接续触发 brainstorm |
| **自动切分支** | ❌（`set-branch` 只是写字段） | ❌（要手动 `git checkout -b`） | ❌ |
| **Task → PR** 自动创建 | ❌（`task.py` 子命令表里**没有** `create-pr`，见 [Appendix B](https://docs.trytrellis.app/advanced/appendix-b)） | ⚠️ `workflow-ch.md:70` 写了 `task.py create-pr`，但 `task.py` 源码里**没实现**这个子命令 —— 本地文档过时/未实现 | ✅ MCP `create-merge-request` 命令 |
| **PR Review/合并 → 回写 Task** | ❌ | ❌ | ✅ MCP `review-merge-request` |

依据：

- 官方 [Appendix B: Command & Skill Cheat Sheet](https://docs.trytrellis.app/advanced/appendix-b) 的 `task.py` 子命令表只有 14 个：`create / add-context / validate / list-context / start / finish / set-branch / set-base-branch / set-scope / add-subtask / remove-subtask / archive / list / list-archive`，**确实没有 `create-pr`**。
- 本仓库 `.trellis/scripts/hooks/linear_sync.py:5-9` 注释：「Syncs task events to Linear via the `linearis` CLI」—— 触发时机是 `after_create / after_start / after_archive` 三个 lifecycle hook，模式是 **task.py → 外部 CLI**，不是反向。

### Trellis 的官方集成哲学

Trellis 故意保持中立，**不绑定**特定 tracker（GitHub / GitLab / Linear / Jira）。它给的是 3 个挂载点：

| 挂载点 | 用途 | 例子 |
|---|---|---|
| **Lifecycle hooks**（`config.yaml` 的 `hooks.after_*`） | task 状态变化时跑任意 shell | `linear_sync.py create` |
| **`task.json` 自由字段**（`branch` / `pr_url` / `meta`） | 记录外部系统的 ID 与 URL | `task.py set-branch / set-base-branch` |
| **主会话 + MCP** | 互动式调用第三方 API | GitLab MCP 的 `create-merge-request` |

—— 自动化不是 Trellis 自带的，是你按这三个挂载点**自己拼装出来**的。

### 三种落地方案（按改动量递增）

#### 方案 A：零改动 + MCP 驱动（推荐起点）

不写一行代码，纯靠主会话 + GitLab MCP plugin：

```text
用户：「修这个 issue：https://gitlab.com/x/y/-/issues/42」
  ↓
主会话调 gitlab MCP 读 issue 标题/正文/labels
  ↓
触发 trellis-brainstorm，把 issue 内容塞进初始 PRD
  ↓
人确认 → task.py create + 把 issue URL 写进 task.json.meta.issue_url
  ↓
主会话跑 git checkout -b fix/issue-42 + task.py set-branch
  ↓
trellis-implement → trellis-check → commit
  ↓
主会话调 gitlab MCP create-merge-request，把 task.json.meta.issue_url
  写进 MR 描述的 "Closes" 字段
```

优点：今天就能跑，不动 Trellis 框架。
缺点：每一步都要主会话主动调用，没真正"无人值守"。

#### 方案 B：半自动 hooks（仿 `linear_sync.py` 写 `github_sync.py` / `gitlab_sync.py`）

在 `.trellis/scripts/hooks/` 新增脚本，挂到 `config.yaml`：

```yaml
hooks:
  after_create:
    - "python3 .trellis/scripts/hooks/gitlab_sync.py create"
  after_start:
    - "python3 .trellis/scripts/hooks/git_branch_create.py"   # git checkout -b <branch>
  after_archive:
    - "python3 .trellis/scripts/hooks/gitlab_sync.py archive"  # 创 MR + 关 issue
```

`gitlab_sync.py` 完全可以照搬 `linear_sync.py` 的结构，把 `linearis` 换成 `glab` CLI 或调用 GitLab REST API。

`task.json` 需要额外字段记 issue：

```json
{
  "meta": {
    "gitlab": {
      "issue_iid": 42,
      "issue_url": "https://gitlab.com/x/y/-/issues/42",
      "mr_iid": null,
      "mr_url": null
    }
  }
}
```

优点：人只管描述需求，剩下的状态同步自动跑。
缺点：单向同步好做（task → tracker），双向同步要写 webhook 接收端（issue → task），工程量大。

⚠️ 反向同步（issue → task）的最大难点：**Trellis 没有"server"形态**，不能监听 webhook。要做反向只能用 polling（定时 cron 拉 issue 列表，diff 出新增 issue 后创 task）—— 这是单人开发场景下成本/收益最差的一块。

#### 方案 C：完全自动化 CLI（重度修改）

给 `task.py` 加两个新子命令（破坏上游兼容，慎重）：

```bash
python3 ./.trellis/scripts/task.py from-issue https://gitlab.com/x/y/-/issues/42
# → 自动 fetch issue 标题/正文/labels → 创 task → 切分支 → 写 meta.issue_url

python3 ./.trellis/scripts/task.py push-pr [--draft]
# → 自动 git push -u origin HEAD → glab mr create --description "Closes #42"
#   → 把 MR URL 回写 task.json.pr_url
```

优点：一行命令完成 issue→task 或 task→PR。
缺点：每次 `trellis update` 拉上游模板都要手工 merge，且仅适合 GitLab/GitHub 一种 tracker。

### 推荐组合（按使用规模分档）

| 规模 | 推荐 | 理由 |
|---|---|---|
| **本仓库现状（单人）** | 方案 A | issue 数量少，主会话 + MCP 已经够用；写 hook 的 ROI 不够 |
| **小团队 2-5 人** | 方案 A + 一个 `gitlab_sync.py` 单向 hook（task → issue 状态同步） | 不让 PM 在 GitLab 看到"issue 卡了几天没人动" |
| **大团队 / 多人协作** | 方案 B 完整版 + polling 反向同步 | issue 数量大到必须自动化分发 |

### 当前最该做的两件事（不动 Trellis 框架）

1. **修文档矛盾**：`.trellis/workflow-ch.md:70` 把不存在的 `task.py create-pr` 写进了命令清单，应改成"用 `gh pr create` 或 `glab mr create`，可选自动同步 `task.json.pr_url`"。
2. **建一个 `task.json.meta.issue_url` 约定**：让本仓库的所有 fix 类 task 在 PRD 顶部或 `task.json.meta` 里强制带 issue URL —— 这是后续做任何自动化的最小数据基础。

### 反向洞察

这条链路完整化，需要的不是"再多一个 Trellis 命令"，而是**让 Trellis 当中间状态机**：

```
GitLab Issue (用户语言)
   ↓ 抽取 + brainstorm
Trellis Task (开发语言：PRD / spec / 验收清单)
   ↓ git workflow
Branch + Commits
   ↓ task.json.pr_url
GitLab MR (协作语言：reviewer / pipeline / merge)
```

Trellis 的角色是把"用户语言"翻译成"开发语言"，再翻译回"协作语言"。这一翻译过程恰恰是 AI 最擅长的部分 —— **自动化的核心不是流程脚本，而是 brainstorm skill 能从 issue 文本里抽出 PRD 的精度**。脚本只是把翻译结果搬运到不同系统。

---

## 串起来的反向洞察

把这 5 个问题串起来看，全指向同一个深层问题：

> **Trellis 的 task 模型是"扁平 + 单层 spec/research 注入"，但真实需求是"多层 + 多端 + 多模态上下文"。**

| 你问的 | 真问题 |
|---|---|
| Q1 几个 task | task 模型扁平，没有自然的 feature 边界 |
| Q2 同一个 agent | 上下文注入按 task 范围，但 task 边界没强制按模块切 |
| Q3 vibe fix | 工具没强制 repro test，全靠 CLAUDE.md 文字提醒 |
| Q4 feature 缺失 | parent task 是 feature 的隐式形态，但没人记得设 parent |
| Q5 截图缺失 | jsonl 只接文本文件，二进制只能靠 PRD 主动引用 |
| Q6 issue/PR 自动化缺失 | Trellis 故意保持 tracker 中立，集成靠 hook + MCP 自拼装 |

---

## 短期内不改 Trellis 框架就能落地的两件事

1. **跑一遍思考文档 §6 的"落地工程项 1"**：给 `task.py create` 加 `--type` `--module` `--parent` 强制参数。这是把问题 1/4 工具化的最便宜方式。
2. **写一个 `feat` 类 task 的 PRD 模板**（放在 `.trellis/spec/guides/feat-prd-template.md`），强制包含"UI 截图段 + API 契约段 + DB schema 段"三个 H2。brainstorm skill 加载这个模板，缺段不让进 `task.py start`。

---

## 备注

- 本文档基于 2026-05-19 仓库现状写就，当前 `task.json` schema 还没落到思考文档 §1.3 的强约束（`type` / `module` / `severity` 都是 `null`）。
- 引用的 `parent` / `subtasks` / `children` 字段是 `task.json` 现有字段，可用。
- 引用的 `add-subtask` 命令在 `python3 ./.trellis/scripts/task.py --help` 中可查。
