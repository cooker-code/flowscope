# 执行计划

## 进入实现前

- [x] 用户同意创建任务并规划。
- [x] 用户确认实际新增/更新/删除统计口径。
- [x] 核实状态组件、后端状态来源、筛选计数与存储结果模型。
- [x] 用户评审 `prd.md` / `design.md` / 本计划，并授权开始实现。
- [x] 通过后再运行 `task.py start`，读取 `trellis-before-dev`；主会话直接实施与检查，遵循 inline 模式。

工作区：`/Users/blank/wangliang/gitcode/flowscope/.worktrees/codex%2Ffix-ingestion-status-semantics`。
分支：`codex/fix-ingestion-status-semantics`。仓库当前没有 dev，沿用已核实的 master 作为基线，不在主工作区修改代码。

## 顺序

1. `flowscope-storage`：提取普通发布的纯前置检查，保留事务内质量校验；扩展可选变更统计模型，确保旧 JSON 可读。
2. 在实际业务节点与投影关系写入处生成分类变更证据，与回执同事务保存，覆盖无变化、幂等回读和撤回。
3. `flowscope-cli`：让解析失败和前置检查拒绝保存审计/终态证据后跳过执行队列；策略复核拒绝映射为未请求。不得破坏内容校验与幂等键。
4. 统一正式入图业务状态与原因，接入列表、详情和事件响应；更新有效筛选表达式，使分页总数和行状态一致。个人 usage 状态不共用正式图映射。
5. 将已提交的 `graphChanges` 暴露给审计行，先在隔离运行实例验证真实 API，再连接 UI。
6. `app`：调整四种状态、空白历史、筛选项和说明；成功面板接入分组统计，未请求状态接入具体原因。沿用 tooltip/popover 的事件隔离及轮询稳定性。
7. 修订相关 API、状态与存储 spec，执行 `trellis-check`。如果实施中修复了已有 bug，按项目要求执行 `trellis-break-loop` 并沉淀必要契约。
8. 交付改动、已通过的验证及未验证范围；本任务授权不包含生产发布、生产重跑或生产图修改。

## 针对性验证

### Rust 与 API

- `cargo test -p flowscope-storage`：前置检查与结果模型旧 JSON 兼容，不以普通单测代替数据库统计验证。
- `cargo test -p flowscope-cli --features serve server::lineage`：受理、队列、策略复核、事件、审计列表/详情以及筛选计数。
- 补充 `server::audit` 的相关筛选测试并定向运行：验证新分类的总数、分页及旧参数兼容。
- 使用任务独占的空 Neo4j 数据库运行 `isolated_neo4j_versions_usage_shared_sources_and_replay` 及新增统计用例。明确指定回环测试 URI，并检查测试要求的隔离环境；不使用生产凭据。
- 真实数据库覆盖：首次创建、业务属性更新、旧关系删除、仅刷新时间、同事件回读、同内容新事件、共享来源、并发统计、撤回、旧版本拒绝、事务中途约束失败的完整回滚、提交成功但 SQLite 尚未完成时的 receipt 恢复。
- 先证明后端真实结果符合契约，再改成功状态展示。

### 前端与运行行为

- `yarn workspace @pondpilot/flowscope-app test src/pages/AuditPage.test.tsx`，并运行新增状态组件用例：四种标签、历史空白、零与缺失统计的区别、未请求原因、分组数字、轮询稳定。
- `yarn workspace @pondpilot/flowscope-app test:lineage`：原因文本、未知代码与长列表保持完整。
- `yarn workspace @pondpilot/flowscope-app typecheck` 与 `yarn workspace @pondpilot/flowscope-app build`。
- 前端资产同步到 CLI 当前实际嵌入目录后，`cargo build -p flowscope-cli --features serve`。使用任务独占端口和 `--audit-log` 启动并验证嵌入页面，不能只检查 Vite 页面。
- 浏览器核查悬浮、点击、键盘、触屏、长列表、深浅主题，徽标和面板操作不打开行详情；待入图刷新为已入图后统计正确。
- 如编写 Playwright 脚本，浏览器启动后将上下文创建、操作、断言置于 try/finally；即使上下文关闭失败也继续等待浏览器关闭。结束后核实本次进程退出及临时克隆目录清理，分别报告功能和资源清理结果。
- 只停止本任务启动的服务 PID、浏览器和数据库容器；保留其他工作区及用户进程。

## 关键审查与回退点

- 不用分析节点数冒充实际变更，不把未记录统计转成 0，不重复累计同一事件的回执。
- 前置拒绝不得丢失审计与幂等证据；队列重试不得显示成终止失败。
- 状态 SQL 与详情归类不能分叉，历史缺证据不伪造业务结论。
- 回退以任务分支变更为单位，可选 JSON 字段无需破坏性迁移；测试容器和临时服务在验证结束后清理。

## 当前进度

实现已落地；逐项实际验证、运行环境中断及资源清理结果见 `implementation-result.md`。用户界面验收由用户判断。
