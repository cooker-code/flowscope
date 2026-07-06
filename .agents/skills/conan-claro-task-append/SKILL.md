---
name: conan-claro-task-append
description: 将已有 Trellis task 补登记到 Claro 并同步 DocZ，完成项目管理闭环。用户说以下任意话术时必须使用本 skill：
  “同步 claro”、“收尾”、“task 收尾”。
  “收尾”内容包含 Claro Task/Story关联、DocZ 上传、Trellis archive、
  journal / commit，以及 worktree 场景下的代码合回和 worktree 销毁。
---

# Conan Claro Task Append

“收尾”的含义只包含 6 步：

1. **Claro Task/Story**：创建或复用 Claro Story / Task，并挂到合适的 Epic；用户语义是“收尾”时，将 Claro Task 推进到 `done` 并回读确认。
2. **估分**：创建或复用 Claro Task 后触发 `cf task estimate-by-ai <task_id>`，再回读 Task 的 `score` / `ai_estimate_status`。估分失败不阻断收尾，但必须报告失败原因和回读状态。
3. **DocZ 上传 + Task 产物挂载**：用 `cf docz-path --type task --id <task_id>` 找到标准 Task 目录，在该目录下创建 Trellis task 同名目录，上传 Trellis task 的关键文档，然后先用 `docz-cli shortlink` 生成可点击的 DocZ URL，再用 `cf task artifacts add/sync` 将该 URL 挂载到 Claro Task 产物中。
4. **Trellis archive**：确认已有完成证据后归档 Trellis task。这里不重新做验收，不重建缺失的验收文档；如果完成证据缺失，停止并报告缺什么。
5. **journal / commit**：记录本次收尾 journal，并提交收尾产生的本地改动；如果没有本地改动，报告工作区干净。
6. **worktree 代码提交**：如果任务是在隔离 worktree / task branch 完成的，将 task branch 合回目标分支并销毁 worktree；如果不是 worktree 场景，明确记录为不适用。


收尾不包含以下动作：
- 不重新跑完整验收流程。

## 需要配合的工具知识

- claroflow-cli
- docz
- 如果仓库有 `AGENTS.md`、`CLAUDE.md` 或 `.trellis/workflow.md`，先遵守仓库本地约束；不要为了补 Claro 改动业务代码。
- 本项目中，收尾的流程边界和最终回复格式以当前 skill 为准。

## 常用 Epic 路由

优先使用这四个常开 Epic：

| 场景 | Epic | DocZ 路径 |
| --- | --- | --- |
| SQL 解析、SQL parser、审计页 SQL 解析能力、目标表筛选、lineage analyzer | `[E-4900471] SQL 解析` | `S160-技术:projects/[P-7] AI探索/Epics/[E-4900471] SQL 解析` |
| Change 任务排查、Hive/表修改维护、无法明确归属的兜底任务 | `[E-4900415] Change 任务排查与表修改维护` | `S160-技术:projects/[P-7] AI探索/Epics/[E-4900415] Change 任务排查与表修改维护` |
| Neo4j 图谱修复、血缘图修复验证、图谱关系验证 | `[E-4900472] neo4j 图谱修复验证` | `S160-技术:projects/[P-7] AI探索/Epics/[E-4900472] neo4j 图谱修复验证` |
| 广告投放、投放需求、promotion、广告消耗、投放 Change/DS 需求 | `[E-4900490] 广告投放` | `S160-技术:projects/[P-7] AI探索/Epics/[E-4900490] 广告投放` |

如果用户没有指定 Epic，按任务内容推断；广告投放相关任务优先归到 Epic `[E-4900490]`；仍然无法判断时兜底到 Change Epic `[E-4900415]`，并在结果里说明这个归属判断。

小型 Change 修改默认挂载点：

- Epic: `4900415`，`Change 任务排查与表修改维护`
- Story: `879`，`Change 任务排查与表修改`

广告投放任务默认挂载点：

- Epic: `4900490`，`广告投放`
- Story: 不预设固定 Story，先按当前 Claro 用户名查本人未完成 Task；如果已有语义匹配的 Task，直接复用该 Task 及其所属 Story/Epic。

## 工作流程

### 1. 定位 Trellis task 文档

先确定要补到 Claro 的 Trellis task。优先级：

1. 用户明确给出的 `.trellis/tasks/...` 路径。
2. 当前 active Trellis task：如果仓库有 `./.trellis/scripts/get_context.py`，运行 `python3 ./.trellis/scripts/get_context.py` 获取真实状态。
3. 用 task 标题、ID、目录名在 `.trellis/tasks` 中搜索：`rg --files .trellis/tasks | rg '<keyword>'`。

只上传 task 相关关键文档，不上传无意义的大日志、会话 jsonl、构建产物或临时文件。默认选择：

- `prd.md`
- `implement.md`
- `research/**/*.md`
- `check*.md`
- `acceptance*.md`
- `acceptance*.jsonl`
- `closeout.md`
- `journal*.md`
- `task.json`
- 其他与 task 交付直接相关的 Markdown / 文本文件

如果目录里存在大量文件，先列清单并选择关键文档；不要把整个 `.trellis` 树上传。

### 2. 创建或复用 Claro Story / Task

先查当前 Claro 用户名和本人未完成 Task。这一步优先级高于 Epic/Story 路由和新建 Task；如果语义匹配，优先复用已有 Task，不要重复创建：

```bash
cf whoami
for STATUS in draft todo designing coding dev_done testing test_done; do
  cf task list --me --status "$STATUS" --limit 200
done
```

判断语义匹配时，重点看 Task 标题、描述、所属 Story/Epic、DocZ 路径和 Trellis task 主题是否一致；若匹配，直接使用该 Task，并继续执行 `cf task context "$TASK_ID"` 和 `cf docz-path --type task --id "$TASK_ID"`。只有本人未完成 Task 中没有语义匹配项时，才继续选择 Epic/Story 或新建 Task。

再确认 Epic：

```bash
cf docz-path --type epic --id "$EPIC_ID"
cf agent decompose context --epic-id "$EPIC_ID"
cf story list --epic "$EPIC_ID" --page-size 50
```

选择 Story 的顺序：

1. 用户指定的 Story。
2. 小型 Change 使用 Story `879`，前提是该 Story 仍允许追加 Task。
3. Epic 下已有标题和任务主题匹配的 Story。
4. 没有合适 Story 时自行创建 Story。

创建 Story 示例：

```bash
cf story create \
  --epic "$EPIC_ID" \
  --domain "$DOMAIN_LEAF_ID" \
  --title "$STORY_TITLE" \
  --description "$STORY_DESC" \
  --assignee 45
```

`cf story create` 需要 leaf domain。优先从同 Epic 现有 Story、`cf agent decompose context --epic-id` 或用户提供的上下文里复用 domain；如果仍无法确定，先把已查到的 Epic/候选 Story 说明清楚，只补问 domain 这一项。

创建 Task 前先查重：

```bash
cf task list --story "$STORY_ID" --limit 100
```

如果已有同主题 Task，优先复用并补文档，不要重复创建。创建 Task 优先用高层命令：

```bash
cf create-task \
  --title "$TASK_TITLE" \
  --story-id "$STORY_ID" \
  --desc "$TASK_DESC" \
  --json
```

如果 `cf create-task` 不可用，使用底层命令：

```bash
cf task create --story "$STORY_ID" --title "$TASK_TITLE" --description "$TASK_DESC" --assignee 45
```

创建或复用后读取上下文：

```bash
cf task context "$TASK_ID"
cf docz-path --type task --id "$TASK_ID"
```

构造 Claro Task 页面链接，最终回复必须带上：

```bash
CLARO_TASK_URL="https://claro.zhenguanyu.com/tasks/$TASK_ID"
```

如果当前环境不是 online，先用 `cf env` 读取 server，再按 `<server>/tasks/<task_id>` 拼接；不要只给 `cf task context` 命令而不给可点击链接。

### 2.1 估分

创建或复用 Claro Task 后，必须触发一次 AI 估分，并回读结果：

```bash
cf task estimate-by-ai "$TASK_ID"
cf task context "$TASK_ID"
```

触发估分前先确认 Task 描述或已上传的 DocZ / Trellis 文档中能支撑估分判断。这里的“估分”是 Claro Task 的 `score` 字段，取值范围固定为 **1-5**；不是 `estimate_hours`。`estimate_hours` 只代表估时，除非用户明确要求估时，否则不要用 `cf task update --estimate` 或 `estimate_hours` 代替估分。

估分口径以 `.trellis/spec/guides/claro-task-scoring.md` 为准；若该文件存在，先读取它再估分。

估分依据必须覆盖三类要素：

- **反复程度**：需求执行中是否出现反复修改、反复验证、返工、卡点重查、验收口径调整；反复越多，分值应越高。
- **人工接入**：是否需要人工确认口径、人工处理平台权限 / 发布 / 数据修复、人工介入排查阻断；人工接入越多，分值应越高。
- **需求复杂度**：涉及的系统、表、SQL / HQL、调度、发布、回归验证、前后端或跨仓库范围；范围越复杂，分值应越高。

1-5 分参考口径：

| score | 口径 |
| --- | --- |
| 1 | 占位、登记、迁移壳、小文档或极小配置；基本没有验证和协同。 |
| 2 | 单点小改或小流程补充；验证明确，最多一个系统，基本无返工。 |
| 3 | 常规交付默认值；涉及正常开发 / 排查 / SQL / ETL 小改 / 回归，但范围可控。 |
| 4 | 谨慎使用；需要同时满足至少两个强证据：跨系统或跨仓库、多轮验证/返工、人工或平台协同、生产发布/回滚风险。 |
| 5 | 极少使用；必须同时满足高复杂度、明显反复或阻断、强人工接入、生产链路高风险，且 4 分不足以区分工作量。 |

批量估分时，如果 4/5 分超过整体任务数的 25%，必须二次复核。常见情况应落在 2/3 分。

如果 Task 描述过短，先把可确认的交付范围、反复点、人工接入和复杂度补进描述或 DocZ 文档，再估分；不要只基于空描述或标题估分。

如果当前 CLI 只支持 `cf task estimate-by-ai` 而没有直接写 `score` 的命令，必须使用 Claro 支持的 Task 更新接口写入 `score`；若接口也不可用，必须报告“估分无法落地”的真实阻断，不要改写 `estimate_hours` 伪装成已估分，也不要只写评论代替落库。

当 `cf task estimate-by-ai "$TASK_ID"` 长时间停在 `ai_estimate_status=generating`，或回读 `score=null` 时，不要继续等待到收尾结束。先按上面的 1-5 口径给出人工分，再用当前 Task 的 `version` 做乐观锁写入 `score`：

```bash
TASK_VERSION="$(cf task context "$TASK_ID" | jq -r '.task.version')"
CF_PROFILE="$(jq -r '.current' ~/.claroflow/credentials.json)"
CF_SERVER="$(jq -r --arg p "$CF_PROFILE" '.profiles[$p].server' ~/.claroflow/credentials.json | sed 's#/*$##')"
CF_TOKEN="$(jq -r --arg p "$CF_PROFILE" '.profiles[$p].apiKey' ~/.claroflow/credentials.json)"

curl -sS -X PUT "$CF_SERVER/api/tasks/$TASK_ID" \
  -H "Authorization: Bearer $CF_TOKEN" \
  -H 'Content-Type: application/json' \
  --data "{\"score\":$TASK_SCORE,\"expectedVersion\":$TASK_VERSION}" \
  | jq '{success, error, message, data: {id: .data.id, score: .data.score, version: .data.version, status: .data.status}}'

cf task context "$TASK_ID" | jq '{task: {id: .task.id, score: .task.score, version: .task.version, ai_estimate_status: .task.ai_estimate_status}, story: {id: .story.id, score: .story.score}}'
```

写入前必须设置 `TASK_SCORE` 为 1-5 的整数，并在最终回复中说明依据。`ai_estimate_status` 仍可能保留为 `generating`，但只要 `task.score` 已落库且回读非空，即可视为 Task 估分已完成；如果 Story 汇总分也出现在回读中，一并报告。评论只能补充理由，不能替代 `task.score`。

回读时至少记录：

- `task.score`
- 当前周期 `plannedScore`；如果未写入，说明 Task 是否未进入周期、接口是否不可用、或本轮只要求补总分。
- `task.ai_estimate_status`
- `task.ai_estimate_meta`

写入 `score` 后，如果 Task 已经在周期 / 计划中，或用户要求补计划分，还要写入周期排期关系上的 `plannedScore`。完整工作量排进当前周期时 `plannedScore=score`；只排入一部分工作时 `plannedScore<score` 并把原因写入周期排期备注。当前 CLI 未暴露该字段时，使用 Claro 页面同源接口：

```bash
GET /api/squads/<squadId>/task-cycle-board
GET /api/squads/<squadId>/task-cycle-schedules?taskId=<taskId>&cycleId=<cycleId>
PATCH /api/squads/<squadId>/task-cycle-schedules
```

如果 `cf task estimate-by-ai` 返回失败、`ai_estimate_status=failed`，或 `score` 仍为空，先按上面的接口兜底写入人工分；只有接口也不可用时，才继续 DocZ 上传、状态推进和 Trellis archive，并在最终回复中写明估分未完成的原因、回读状态和后续 owner。不要把估分失败、空分数或仅写评论表述成已估分成功。

用户触发“收尾”语义时，在 DocZ 上传和必要的归档动作完成后，将 Claro Task 推进到 `done` 并回读确认：

```bash
cf task goto "$TASK_ID" --status done
cf task context "$TASK_ID"
```

如果 `cf task goto` 不可用，再尝试：

```bash
cf task update "$TASK_ID" --status done
cf task context "$TASK_ID"
```

状态推进失败时不要静默跳过，在最终回复中明确报告失败原因。

### 3. 建 DocZ 目录、上传 Trellis 文档并挂载 Task 产物

DocZ 目录必须和 Claro Task 对应。先取 Task DocZ 根目录：

```bash
TASK_DOCZ_ROOT="$(cf docz-path --type task --id "$TASK_ID")"
```

在 Task 根目录下创建一个和 Trellis task 目录名或 task slug 对应的子目录。不要额外套 `trellis/` 中间层。

正确结构示例：

```text
.../[T-1324] 审计页面增加目标表筛选/06-23-audit-target-table-filter/prd.md
```

错误结构示例：

```text
.../[T-1324] 审计页面增加目标表筛选/trellis/06-23-audit-target-table-filter/prd.md
```

上传示例：

```bash
TASK_DOCZ_DIR="$TASK_DOCZ_ROOT/$TRELLIS_TASK_DIR_NAME"

docz-cli mkdir "$TASK_DOCZ_ROOT/$TRELLIS_TASK_DIR_NAME"
docz-cli upload ".trellis/tasks/.../prd.md" "$TASK_DOCZ_ROOT/$TRELLIS_TASK_DIR_NAME"
docz-cli upload ".trellis/tasks/.../acceptance.md" "$TASK_DOCZ_ROOT/$TRELLIS_TASK_DIR_NAME"
```

如果 `docz-cli` 在非交互 shell 里拿不到认证环境，使用：

```bash
zsh -ic 'docz-cli ls "S160-技术:projects/[P-7] AI探索"'
```

注意区分两类能力：

- DocZ 文件上传：用 `docz-cli mkdir/upload/write`。
- Claro Task artifact URL 元数据：用 `cf task artifacts add/sync`。artifact 不能替代 DocZ 上传；DocZ 上传完成后，还必须把上传目录挂到 Task 产物。

DocZ 文件上传完成后，必须先为上传目录生成可点击的 DocZ URL，再把这个 URL 作为 Claro Task 产物追加到 Task 上。`cf task artifacts add` 的 `--type` 是必填项；DocZ 目录统一使用 `other`，`--source` 使用 `docz`。

禁止把 `cf docz-path` 返回的 DocZ 内部路径直接写入 artifact URL。该路径形如 `S160-技术:projects/.../[T-xxx] .../task-slug`，只供 `docz-cli` 定位文件；如果直接作为 URL 挂到 Claro，页面会把它拼成 `https://claro.zhenguanyu.com/tasks/<DocZ内部路径>` 并导致 404。

正确做法：

```bash
TASK_DOCZ_URL="$(docz-cli shortlink "$TASK_DOCZ_DIR")"

cf task artifacts add "$TASK_ID" \
  --url "$TASK_DOCZ_URL" \
  --type other \
  --title "DocZ: $TRELLIS_TASK_DIR_NAME" \
  --source docz
```

如果后续需要幂等替换同一来源的 DocZ 产物，或发现已挂载了 DocZ 内部路径导致 404，使用 `cf task artifacts sync` 按 `source=docz` 原子替换为短链：

```bash
cf task artifacts sync "$TASK_ID" \
  --source docz \
  --items "[{\"url\":\"$TASK_DOCZ_URL\",\"type\":\"other\",\"title\":\"DocZ: $TRELLIS_TASK_DIR_NAME\"}]"
```

默认首次收尾可使用 `add` 追加本次上传目录；修正已有错误 artifact 时使用 `sync`。不要用 artifact 替代正文上传。

上传后至少验证：

```bash
cf task context "$TASK_ID"
cf docz-path --type task --id "$TASK_ID"
docz-cli ls "$TASK_DOCZ_DIR"
docz-cli ls "$TASK_DOCZ_URL"
# 从 cf task context 回读 Task 产物，确认存在 source=docz、title=DocZ: $TRELLIS_TASK_DIR_NAME、url=$TASK_DOCZ_URL
```

artifact 回读必须确认 `url` 是以 `https://docz.zhenguanyu.com/` 开头的可点击链接；如果 `url` 仍是 `S160-技术:projects/...` 这类内部路径，视为失败，必须立即用 `cf task artifacts sync` 修正。

如果上传的是 Markdown 关键文档，可抽查一份：

```bash
docz-cli cat "$TASK_DOCZ_ROOT/$TRELLIS_TASK_DIR_NAME/prd.md" | sed -n '1,40p'
```

不要把完整长文档贴到最终回复，只汇报文件名、路径、Task 产物挂载结果和关键证据。

### 4. Trellis archive

收尾时归档 Trellis task，但只在已有完成证据时执行。完成证据可以是已存在的 `acceptance-report.md`、明确的验证记录、用户明确确认完成、或对应 task 文档中的完成结论。

这里不重新跑完整验收，不重建缺失的 PRD / acceptance / report。缺少完成证据时停止归档，并报告缺少哪一类证据。

归档示例：

```bash
python3 ./.trellis/scripts/task.py archive "$TRELLIS_TASK_ID_OR_SLUG"
```

归档后确认 task 已移动到 archive 目录：

```bash
rg --files .trellis/tasks/archive | rg "$TRELLIS_TASK_DIR_NAME"
```

### 5. journal / commit

收尾时记录本次收尾 journal，并提交收尾产生的本地改动。优先使用项目已有脚本：

```bash
python3 ./.trellis/scripts/add_session.py \
  --title "$SESSION_TITLE" \
  --commit "$COMMIT_HASH" \
  --summary "$SUMMARY"
```

提交前先查看工作区：

```bash
git status --short --branch --untracked-files=all
```

只提交本次收尾相关文件，不顺手提交无关改动。若没有本地改动，最终回复中报告工作区干净。

### 6. worktree 代码提交

如果 Trellis task 在隔离 worktree 或 task branch 执行，还必须处理代码合回和 worktree 销毁；如果不是 worktree 场景，最终回复写明“不适用”。

判断依据优先级：

1. task 记录、PRD、journal 中的 `isolated_worktree`、`worktree_path`、`branch`、`base_branch`。
2. `git worktree list`。
3. `git branch --show-current`。

处理规则：

1. 确认 worktree 工作区干净，并且任务代码已经提交到 task branch。若仍有未提交改动，停止收尾并报告，不能把未提交改动藏进收尾动作。
2. 回到主 checkout，切到目标分支。默认目标分支是 `master`，除非 task 明确记录了其他 `base_branch`。
3. 将 task branch 合回目标分支。合回成功后验证关键文件已经出现在目标分支。
4. 执行 `git worktree remove <worktree-path>` 销毁 task worktree。
5. 不默认删除本地 task branch 或远端 branch；只有用户明确要求时才删除分支。

参考命令：

```bash
git worktree list
git checkout master
git pull --ff-only
git merge --no-ff <task-branch>
git worktree remove <worktree-path>
```

## 最终回复格式

用简短中文汇报，必须按 6 步包含：

1. **Claro Task/Story**：Epic、Story、Task 的 ID / 标题，说明复用还是新建，Task 最终状态、Claro Task 页面链接和回读命令。
2. **估分**：`cf task estimate-by-ai` 执行结果，回读到的 `score`、`ai_estimate_status`、失败原因或后续 owner。
3. **DocZ 上传 + Task 产物挂载**：完整 Task DocZ root、Trellis task 同名上传目录、可点击 DocZ URL、上传文件清单、`cf task artifacts add/sync` 挂载结果，以及证明目录、短链和 Task 产物都存在的验证命令 / 结果。
4. **Trellis archive**：归档的 Trellis task 路径、归档命令 / 结果；如果未归档，说明阻断原因。
5. **journal / commit**：journal 写入位置、提交哈希；如果没有提交，说明原因和当前 `git status`。
6. **worktree 代码提交**：task branch、目标分支、合回状态、worktree 路径、`git worktree remove` 是否成功；非 worktree 场景写明“不适用”。

示例：

```markdown
收尾完成：

1. Claro Task/Story
   - Epic: `[E-4900471] SQL 解析`
   - Story: `[S-123] FlowScope SQL 解析体验`，复用
   - Task: `[T-1324] 审计页面增加目标表筛选`，新建，状态 `done`
   - 链接: `https://claro.zhenguanyu.com/tasks/1324`
   - 验证: `cf task context 1324` 回读为 `done`

2. 估分
   - 命令: `cf task estimate-by-ai 1324`
   - 回读: `score=4`, `ai_estimate_status=done`

3. DocZ 上传 + Task 产物挂载
   - Root: `S160-技术:projects/[P-7] AI探索/Epics/[E-4900471] SQL 解析/.../[T-1324] 审计页面增加目标表筛选`
   - 目录: `.../[T-1324] 审计页面增加目标表筛选/06-23-audit-target-table-filter`
   - 链接: `https://docz.zhenguanyu.com/s/rd/f/xxxxxx`
   - 上传: `prd.md`, `acceptance.md`, `acceptance-report.md`
   - 产物挂载: `cf task artifacts add 1324 --url "$TASK_DOCZ_URL" --type other --title "DocZ: 06-23-audit-target-table-filter" --source docz`
   - 验证: `docz-cli ls "$TASK_DOCZ_DIR"` 和 `docz-cli ls "$TASK_DOCZ_URL"` 均可见上述文件；`cf task context 1324` 可见 `source=docz` 且 `url` 以 `https://docz.zhenguanyu.com/` 开头的 DocZ 产物

4. Trellis archive
   - 已归档到 `.trellis/tasks/archive/2026-07/06-23-audit-target-table-filter`

5. journal / commit
   - journal: `.trellis/workspace/wangliang/journal-1.md`
   - commit: `abc1234 chore(task): closeout ...`

6. worktree 代码提交
   - 不适用：本 task 不在隔离 worktree 执行
```

## 失败处理

- `cf` 未登录或网络失败：先运行 `cf whoami` / `cf health` 取证；不要假装创建成功。
- Story 创建缺 domain：优先从同 Epic 现有 Story 复用；仍缺时只问 domain，不要中断其他已能确认的信息。
- DocZ token 缺失：说明需要 `DOCSYNC_API_TOKEN`，不要改用不对应的本地文件占位。
- Task 产物挂载失败：保留 DocZ 上传结果，运行 `cf task context "$TASK_ID"` 和失败命令取证，在最终回复中明确报告 `cf task artifacts add/sync` 失败原因；不要把“DocZ 上传成功”表述成“Task 产物已挂载”。如果挂载 URL 是 DocZ 内部路径而不是 `https://docz.zhenguanyu.com/` 短链，也按挂载失败处理并立即修正。
- 估分失败：继续后续收尾动作，但运行 `cf task context "$TASK_ID"` 回读 `score`、`ai_estimate_status`、`ai_estimate_meta`，最终回复明确报告失败原因；不要把失败或空分数包装成成功。
- 已存在同名目录或同主题 Task：优先复用并补齐缺失文档，避免重复对象。
- 缺少完成证据：停止 Trellis archive，不重新跑完整验收，不重建 task 文档。
- worktree 有未提交改动：停止 worktree 合回和销毁，报告 `git status`，让任务回到正常提交步骤。
- 推进 Task 状态仅在用户明确说“收尾”（或等义表达）时才执行；单纯“补充 Claro”或“关联 task”不推进状态。
