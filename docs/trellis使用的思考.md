# Request — Trellis 个人开发流程重规划
> 参考：Conventional Commits、Conventional Branch、Trellis 现有 `workflow.md`。
> 范围：**个人开发链路（solo）为主**；团队链路只列差异点，后期再细化。

---

## 0. 设计原则（呼应随笔的判断）

最核心的三句话，作为整套流程的地基：

1. **能力上限 = 反馈闭环**——agent 拿不到反馈就废，所以每类 task 都必须定义"什么算验收通过"。
2. **可验证 / 可评审 / 可交付的工程闭环**——bug 不是"看起来对了"，而是「旧版本失败 + 新版本通过」的二段验收报告。
3. **review 双阶段**——AI 扫低级别风险（null、边界、测试缺口），人做关键判断（产品方向、抽象边界、性能/可维护性的取舍）。

落地到 Trellis：**每个 task 都要回答"这个 task 是哪一类、归哪个模块、用哪套验收"**，剩下的执行流程沿用 `workflow.md` 三阶段（Plan → Execute → Finish）。

---

## 1. Task 类型与命名规范

### 1.1 类型集合（与 Conventional Commits 对齐）

| 类型前缀 | 触发场景 | 在 PR / commit 里对应 | Issue（个人 / 团队） |
|---|---|---|---|
| `feat`  | 新功能、新页面、新接口、新字段 | `feat: ...` / minor 版本 | 建议（≥ 0.5 天工作量强制）/ 必须 |
| `fix`   | 任何 bug 修复（含致命/严重/一般/提示四档） | `fix: ...` / patch 版本 | **必须** / **必须** |
| `refactor` | 不改外部行为的重构、重命名、抽提 | `refactor: ...` | 复杂重构（≥ 10 文件 / 跨包）必须 / 必须 |
| `perf`  | 性能优化（必须带 benchmark） | `perf: ...` | **必须** / **必须** |
| `chore` | 依赖升级、脚本、CI、配置、本地工具 | `chore: ...` | 可选 / 影响多人时必须 |
| `docs`  | 文档、spec、注释（无代码改动） | `docs: ...` | 可选 / 改外部文档时建议 |
| `test`  | 只新增/修改测试（不改产品代码） | `test: ...` | 可选 / 可选 |
| `hotfix`| 线上紧急修复（与 `fix` 区分优先级，绕过常规节奏） | `fix!: ...` 或 hotfix 分支 | **必须** / **必须** |

**Issue 必要性判断依据**：

- **核心规则**：「会影响产品行为或产生时序证据」的类型必须留 issue（`fix` / `hotfix` / `perf` / 达阈值的 `feat` / `refactor`）；「只动文件、不动行为」的可省（`chore` / `docs` / `test` 及小重构）。
- **为什么 `fix` 个人也强制**：呼应 `suibi.md` §3「创建 issue。描述要清晰。前端的错误要到元素的粒度」和 §20「agent 的能力上限取决于它能不能自己拿到反馈」。bug 的反馈链是 `issue（现象+复现）→ task（修复+验收报告）→ PR（关闭 issue）→ spec 沉淀`；缺 issue 等于断了下次同类问题的追溯路径。
- **为什么 `perf` 必须留 issue**：baseline 数字和目标数字必须有持久化载体，issue 是最自然的位置——不留容易退化成"感觉变快了"。
- **`feat` 的 0.5 天阈值**：低于这个量级的小功能（加个按钮、补个字段）走 task 已经够；超过就涉及产品方向，需要 issue 让历史可追溯。
- **`refactor` 的 10 文件阈值**：当影响面大到需要让别人知情时，issue 是协同信号。



### 1.2 命名格式

```
{MM-DD}-{type}-{module}-{slug}
```

- `MM-DD` —— 由 `python3 ./.trellis/scripts/task.py create` 自动补
- `type` —— 上表 8 种之一
- `module` —— 见 §2 模块清单（缩写）
- `slug` —— 小写连字符短语，≤ 5 个词

示例（替换历史命名风格）：

| 旧命名 | 新命名 | 类型理由 |
|---|---|---|
| `05-13-audit-review-page` | `05-13-feat-app-audit-review-page` | 新增页面 |
| `05-13-cte-alias-scope-collision` | `05-13-fix-core-cte-alias-scope` | bug 修复 |
| `05-14-port-hive-preprocess-to-core` | `05-14-refactor-core-port-hive-preprocess` | 跨包搬迁，外部行为不变 |
| `05-18-fix-duplicate-filters-multi-occurrence` | `05-18-fix-react-duplicate-filters` | 已经是 fix，补 module |
| `05-15-sql-paste-analyze-json-viewer` | `05-15-feat-app-sql-paste-analyze` | 新功能 |

### 1.3 `task.json` 强约束补全

历史 task `package` 字段大量为 `None`，从今往后强制要求：

```jsonc
{
  "id": "05-18-fix-react-duplicate-filters",
  "type": "fix",                       // 新增：枚举 feat/fix/refactor/...
  "module": "react",                   // 新增：见 §2 模块清单
  "package": "packages/react",         // 已有：精确到包/目录
  "severity": "major",                 // 新增（仅 fix/hotfix 必填）：blocker/major/minor/cosmetic
  "title": "TableNode FILTERS 重复显示修复",
  "status": "in_progress",
  // ... 其余沿用 workflow.md
}
```

> 建议给 `.trellis/scripts/task.py create` 增加 `--type` `--module` `--severity` 三个必填/可选参数，自动校验并写入 `task.json`。这是后续工程项（见 §6）。

---

## 2. 模块（业务模块）清单

你说的"前端 / 后端 / 客户端 / 数据"在本仓库对应：

| `module` 缩写 | 对应代码位置 | 业务范畴 | spec 入口 |
|---|---|---|---|
| `app`       | `app/` | 演示 Web 应用（Vite + React） | `.trellis/spec/flowscope-app/frontend/index.md` |
| `react`     | `packages/react/` | React 渲染库（节点、布局、图例） | `.trellis/spec/flowscope-react/frontend/index.md` |
| `core`      | `crates/flowscope-core/` | Rust 血缘解析引擎（含 Hive 预处理、edge 推导） | `.trellis/spec/flowscope-core/backend/index.md` |
| `cli`       | `crates/flowscope-cli/` | Rust CLI + serve 模式 + 审计 API | `.trellis/spec/flowscope-cli/backend/index.md` |
| `export`    | `crates/flowscope-export/` | 导出工具 | `.trellis/spec/flowscope-export/backend/index.md` |
| `wasm`      | `crates/flowscope-wasm/` | WASM 入口 | `.trellis/spec/flowscope-wasm/backend/index.md` |
| `data`      | `neo4j_proc/`、`data/audit.db`、`docs/graph-schema.md` | 数据层：Neo4j 图谱构建、审计 SQLite、schema | （**待建**：`.trellis/spec/data/index.md`） |
| `infra`     | `justfile`、`scripts/`、`.github/` 等 | 构建、CI、工具链 | （`chore` 类专用，无 spec） |

> **关键澄清（呼应你的疑问）**：
> - "数据" = `data` 模块，是 Neo4j 图、审计 DB、schema 这类**持久化/管道**逻辑，**不等于**"前端调接口前先 curl 验证数据"——那个是任何前端 task 都要做的"数据验证步骤"，写在 `app`/`react` 的验收清单里。

---

## 3. 每类 Task 的流程与验收（核心）

> 总骨架：所有 task 都跑 Trellis 的 Phase 1/2/3（见 `workflow.md`）。
> 本节只规定**每类 task 在 Plan/Execute/Finish 里特有的产物 + 验收清单**。

### 3.1 `fix` 系（含 `hotfix`）—— Bug 修复

**判定严重度**（写进 `task.json.severity`）：

| 严重度 | 含义 | 处理时效 |
|---|---|---|
| `blocker` | 系统崩溃、核心流程阻断、数据/资产受损 | 立即修，可中断当前 task。走 `hotfix` 而非 `fix` |
| `major`   | 主要功能异常但有 workaround | 当前 sprint / 当前会话内修 |
| `minor`   | 次要功能不符预期，不影响核心 | 进 backlog 排序 |
| `cosmetic`| UI 错位、文案、体验提示 | 滚动排期，技术债 |

**Plan 阶段（Phase 1）必产**：

- [ ] `prd.md` 写明：**复现步骤** + **最小复现路径**（哪些输入/操作触发）
- [ ] `prd.md` 写明：**根因初判**（哪一层：data/api/render/build？）
- [ ] `prd.md` 写明：**严重度**和**处理策略**
- [ ] **失败测试用例**先补在 `research/repro-test.md` 或直接落到测试代码里，**当前会失败**

**Execute 阶段（Phase 2）特殊要求**：

- 最小改动原则：不在 fix 里做无关重构（重构走 `refactor`）
- 反复出现 2 次以上的 bug → 立刻 `/trellis-break-loop`（CLAUDE.md MANDATORY）

**Finish 阶段（Phase 3）验收报告必含**：

```markdown
## 验收报告
- 复现命令：<curl/yarn test/cargo test 命令>
- 修复前：<输出片段，证明失败>
- 修复后：<输出片段，证明通过>
- 影响范围：<列出受影响文件、关键调用点和验证命令输出>
- 回归测试：<列出跑过的测试集，确保旧用例没破>
```

不允许只写"已修复"。**没有 before/after 的验收报告就是没修。**

### 3.2 `feat` 系 —— 新需求

**Plan 阶段必产**：

- [ ] `prd.md` 包含：**用户故事**（who/what/why）+ **完成定义（Done-when）**
- [ ] 复杂 task 必须补 `design.md` + `implement.md`（沿用 `workflow.md` 规定）
- [ ] **非目标（Non-goals）**：明确这次不做什么，防止 scope creep

**Execute 阶段特殊要求**：

按模块走对应专用协议：

| 模块 | 必读协议 |
|---|---|
| `app` / `react` | [`ui-change-protocol.md`](../.trellis/spec/flowscope-app/frontend/ui-change-protocol.md) —— 必须先 curl 验证 API、定位组件文件 + 行号 |
| `core` | [`edge-types.md`](../.trellis/spec/flowscope-core/backend/edge-types.md) —— 边类型契约不可破坏 |
| `cli` | [`audit-api-spec.md`](../.trellis/spec/flowscope-cli/backend/audit-api-spec.md) —— audit API 字段契约 |
| `vscode` | `.trellis/spec/flowscope-vscode-webview/frontend/index.md` |
| `data` | （**待建** `.trellis/spec/data/index.md`，至少包含 schema 变更流程 + Neo4j 重建命令） |

**Finish 阶段验收报告必含**（按模块差异化）：

#### 3.2.1 `app` / `react` 验收（前端）

- [ ] `cd app && yarn build` 通过
- [ ] `cd app && yarn typecheck` 通过
- [ ] **CLI serve 跨层验证**：`cargo build -p flowscope-cli --features serve` 重新 embed
- [ ] 端到端验证：用 **Cursor IDE 浏览器 MCP**（基于 Playwright）跑核心交互路径
- [ ] 截图嵌入 PRD（参考 `05-18-verify-screenshot-in-task` 的做法）
- [ ] 关键页面/组件无回归

#### 3.2.2 `core` 验收（后端 Rust 引擎）

- [ ] `cargo fmt --all -- --check` 通过
- [ ] `cargo clippy --workspace -- -D warnings` 通过（即 `just lint-rust`）
- [ ] `cargo test -p flowscope-core` 全绿
- [ ] 新增/修改的 fixture 落在 `crates/flowscope-core/tests/fixtures/`
- [ ] 若涉及 `EdgeType` —— **同步更新前端 `packages/react/src/constants.ts` 与 `Legend.tsx`** 与 spec
- [ ] **影响分析**：列出关键调用点、受影响模块和高风险行为变化；高风险必须在 PRD 中说明

#### 3.2.3 `cli` 验收（CLI + 审计 API）

- [ ] `cargo test -p flowscope-cli` 全绿
- [ ] `cargo test -p flowscope-cli --features serve`（embed 模式）全绿
- [ ] **审计 API 契约检查**：`/api/audit` 列表**不含** `sql_text`/`result_json`；`/api/audit/:id` 详情**必须含**；`stmt_count`/`table_count`/`sql_type` 计数规则未破坏（见 `audit-api-spec.md`）
- [ ] 手动启动 `./target/debug/flowscope --serve --port 3099 --audit-log data/audit.db` 通过 curl 走核心路径

#### 3.2.4 `vscode` 验收（客户端）

- [ ] `npm run build` + `npm run build:webview` 通过
- [ ] `npm run typecheck` 通过
- [ ] 在 VS Code Dev Host 中手动验证扩展加载、命令注册、webview 通信
- [ ] 录屏或截图入 PRD

#### 3.2.5 `data` 验收（数据层）

- [ ] schema 变更：更新 `docs/graph-schema.md` 并附 diff
- [ ] Neo4j 图谱重建命令：`bash neo4j_proc/run.sh` 一次能跑通
- [ ] 审计 DB schema 变更：附 migration SQL 与回滚 SQL
- [ ] 至少一份 sample 数据查询验证：节点数、关系数、典型查询返回正常

### 3.3 `refactor` 系 —— 重构

- [ ] **前置必做**：梳理关键调用点、受影响文件和外部行为边界，影响范围写进 PRD
- [ ] 重构前后**外部行为不变**——所有相关测试全绿，没有新增/删除任何业务测试断言
- [ ] 复杂重构（>10 文件 / 跨包）必须有 `design.md`
- [ ] Commit 不混入 feat / fix 的改动

### 3.4 `perf` 系 —— 性能

- [ ] PRD 写明 **baseline 数据**（命令 + 数字 + 环境）
- [ ] 修改后给出 **改进后数据**（同一命令、同一环境）
- [ ] 提升 < 5% 视为无效，需要重新评估方案
- [ ] 不在 `perf` task 里夹带 feat/fix

### 3.5 `chore` / `docs` / `test`

- [ ] 单一职责：`chore` 不改产品代码、`docs` 不改 ts/rust 实现、`test` 不改产品代码
- [ ] `chore` 升级依赖：必须跑一次完整 `just check` + `just test`
- [ ] `docs` 仅文档变更，无需走完整 Phase 2，但仍需 Phase 3.3 `trellis-update-spec`

---

## 4. 通用 PR / Commit 规范

### 4.1 Commit Message

```
<type>(<module>): <description>

[Body：why + 关键决策点]

[Footer：
Closes #<issue-id>
Trellis: <task-dir-name>
BREAKING CHANGE: <if any>]
```

示例：
```
fix(react): TableNode FILTERS 区域同 statement 多引用去重

根因：core 在同 statement 多引用同表时，把每个引用的 WHERE
predicates 都追加到 node.filters，造成重复。前端透传未做去重。

Closes #44
Trellis: 05-18-fix-react-duplicate-filters
```

### 4.2 PR 描述模板

```markdown
## 改了什么
（一句话 + 链接到关键文件）

## 为什么这样改
（设计取舍、其他被否决的方案）

## 风险点
（影响范围、回滚策略）

## 需要 reviewer 重点看
（具体到行号、契约边界）

## 验收报告
（见 §3 对应模块的清单）

## 关联
- Issue: #<id>
- Trellis: .trellis/tasks/.../prd.md
```

---

## 5. 个人 vs 团队链路差异

> 个人链路（本文档主体）已足够闭环；团队链路只列差异，后续单独写文档。

| 维度 | 个人 | 团队 |
|---|---|---|
| Issue | 可选，自己用 `prd.md` 替代 | **必须先有 issue 才能创 task**，PR title 必带 `#<id>` |
| Review | AI 自查（`trellis-check`）+ 自己 review | AI 一阶段（低级风险）+ 人二阶段（关键判断），见 `suibi.md` §7 |
| Severity | 自己定 | PO/Tech Lead 复核 |
| 分支策略 | 直接在 feature 分支提交 + 自合 | `feature/` `fix/` `hotfix/` 前缀，PR → develop → release |
| 紧急修复 | 直接打 `hotfix` task | 走专门 hotfix 流程 + on-call 通知 |

---

## 6. 落地工程项（后续 Trellis task 候选）

1. **`feat-infra-task-py-type-args`**：给 `task.py create` 加 `--type` `--module` `--severity` 必/选参数，自动写 `task.json`。
2. **`docs-spec-data-bootstrap`**：在 `.trellis/spec/data/index.md` 建立数据层 spec，至少覆盖 Neo4j schema 变更流程、审计 DB migration 流程。
3. **`docs-spec-acceptance-checklists`**：把 §3 的各模块验收 checklist 落到每个 spec 的 `acceptance.md`（单文件，便于 `trellis-check` 引用）。
4. **`chore-trellis-workflow-state-fix`**：在 `workflow.md` 的 `[workflow-state:in_progress]` 里加一句"按 task.json.type 加载对应验收 checklist"。
5. **`docs-rename-history-tasks`**（可选）：批量把已归档 task 重命名为新规范，方便 grep。**不强制**，因为 git 历史会乱。

---

## 7. 一句话总结

> **每个 task 都要回答三个问题**：
> 1. **类型**：feat / fix / refactor / perf / chore / docs / test / hotfix
> 2. **模块**：app / react / core / cli / export / wasm / vscode / data / infra
> 3. **验收**：能不能拿出 before/after 二段报告 + 模块专属 checklist 全勾
>
> 三问都答不上来 → 任务还没规划好，不要 `task.py start`。
