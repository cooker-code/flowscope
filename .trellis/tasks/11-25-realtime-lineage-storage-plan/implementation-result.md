# Rust 存储与 token 策略首批实现结果

2026-11-25，按用户“先 Rust 接通 /api/analyze token 策略和 Neo4j，再做策略页，并隔离验证两类 token”的授权完成首批实现。完整 P0–P5 路线图继续保留，不把来源接入、完整回填或生产切换称为本次已完成。

## 本次交付

- 新增 `flowscope-storage`，纯 Rust 标准事件/快照转换、Neo4j 显式事务、来源版本与贡献、历史回执；core 保持纯解析。普通 CLI/WASM 的正常依赖树没有存储或 Neo4j 驱动。
- `--lineage-config` 启用严格 Bearer 与 SQLite 持久事件。调度 token 默认 publish，个人默认 record_usage；按后续用户反馈简化为调用方启用状态和默认动作，移除调用方的环境、来源与表范围配置。请求只能降低权限。调度任务身份和版本继续用于血缘归属与版本替换，部署环境仍须匹配。
- `/api/analyze` 保持 AnalyzeResult 正文，新增事件和存储状态响应头；正式图、个人图、解析结果分别表达。SQLite 先事务保存完整事件与审计关联，Rust worker 再直接写 Neo4j。
- 个人 INSERT 和伪造来源只形成查询使用记录；未知表用 TABLE_REFERENCE，不创建正式 M_TABLE/Physical。默认只证明解析提交，不证明 SQL 已实际执行。
- Neo4j 同事务替换来源贡献，共享来源保留，版本乱序不回退；写入中途失败回滚。连接中断/未知提交保留队列，同 event 重试。恢复时先对账已提交回执，再检查当前权限，避免 token 撤销把旧提交误报为未写。
- 管理 API：调用方/策略保存、生效版本、启用/停用、调用方及 token 物理删除、token 一次性发放/撤销、无写入预览；审计与事件详情按主体授权。
- `/access`、`/policies` 与 `/audit` 已接真实 API。复用审计页主题和组件，包含保存冲突、权限失败、三个状态、排队刷新、个人详情回溯。浏览器 token 只发往同源 API，不进入 AI 服务请求。
- 配置示例、CLI 文档、使用指南、Trellis 可执行契约与可复用 Rust/浏览器测试脚本已补齐。

## 已核实的测试

| 检查 | 结果 |
| --- | --- |
| 存储纯转换 | 3 项通过：INSERT 位置映射/元数据、CTE/UNION/JOIN 端点、窗口控制依赖 |
| 真实 Neo4j 存储事务 | 1 个综合测试通过：首次发布、替换、共享、撤回、幂等、旧版本、失败保留、事务后段约束失败回滚、并发版本及冲突后同事件重试 |
| 真实 Rust HTTP + Neo4j | 2 个综合测试通过：调度/个人区别、个人 INSERT、越权、幂等、完整审计、解析失败、崩溃回执恢复、断连积压重启及策略复核 |
| server 单元/审计迁移 | 12 项通过，含旧策略迁移、物理删除、启用切换和队列权限复核 |
| 既有 serve API / 集成 | 92 + 11 项通过 |
| Cargo clippy（storage + CLI serve，all targets，warnings as errors） | 通过 |
| 普通 CLI 无默认 features 编译 | 通过，保留原 fix/main 的既有警告 |
| core / WASM / 普通 CLI 正常依赖树 | 无 storage / neo4rs |
| 前端 token 发送边界 / 删除请求 / 错误表达 | 3 项通过，`yarn test:lineage` |
| 前端 typecheck / lint / build | 通过；构建仍有现有 ONNX eval 和 bundle 体积提示 |
| 浏览器真实页面 | 保存与 activeRevision、token 发放/隐藏/撤销、预览、409、个人 403、审计独立状态、个人详情回溯通过；桌面/平板/手机与深色主题已检查 |

隔离使用本任务创建的 Neo4j **5.26 Community** 容器，端口只绑定 127.0.0.1；不是生产 Neo4j 5.27 的兼容性验收。运行链路只有 Rust FlowScope 和 Neo4j，未运行 Python 服务。Python 仅用于开发期进程/配置编排，不是产品依赖。

## 已存在的基线失败

扩大运行 `cargo test -p flowscope-cli --features serve --lib --tests` 时，`lint_cli` 的 CP005、JJ001、LT013、RF006、ST012 五个自动修复测试失败。将未修改的 `d4e89415` 用 git archive 导出到独立临时目录，运行相同 lint 用例，复现相同五项失败（43 通过、5 失败）。本次没有修改这些 lint 规则；不把全仓检查宣称为全绿。

## 实施中固定的边界

- neo4rs 0.8 对负数 tiny integer 的解码会把 -1 当成 255；版本初值改用字符串读取并严格解析，真实首发测试覆盖。驱动并发可能返回可重试 deadlock；服务使用原 event ID 可靠重试，测试覆盖最新版本保持。
- artifact / 幂等身份排除 schema 的采集时间 updatedAt，但保留全部语义内容，避免同请求重试因时间变化冲突。
- INSERT Physical 字段采用 core 的 insertTarget 位置合同，不用 SELECT 别名伪造物理字段。
- 只使用隔离候选图；不会接管或清理旧 Python writer 的 unmanaged 边。完整旧规则对照、SYNC 专项和来源元数据适配仍需后续验证。
- 首期为单实例 FlowScope + 持久 SQLite + Neo4j；PG、多实例 outbox、保留期管理、自动元数据补齐、Change/Mario 发布采集、CSV 全量回填、生产切换与 glibc 2.17 发布验证均不在本次已完成范围。

## 使用与验收入口

- 配置/API/验证文档：`docs/guides/lineage-storage.md`
- 配置样例：`docs/examples/lineage-config.json`
- 存储测试：`crates/flowscope-storage/tests/lineage.rs`
- HTTP 测试：`crates/flowscope-cli/tests/lineage_http.rs`
- 页面回归：`scripts/verify-lineage-ui.cjs`
- 页面截图和浏览器清理证据：`research/ui/`

当前代码位于 `codex/realtime-lineage-storage-plan` 的独立工作树。自动验证完成与用户验收分开记录；未提交、未部署、未修改生产图、未归档 task。

## 首次实现验证清理

测试脚本和所创建的浏览器进程均已退出，临时浏览器配置目录已删除；最终预览服务已通过 SIGTERM 正常退出；任务专属 Neo4j 容器及匿名卷已移除；原有 PostgreSQL 容器保留。临时基线构建目录和私有测试凭据/数据库已删除。最终 app/dist 与 CLI 嵌入 index 一致，并已用最终嵌入构建完成页面回归。

跨层边界、缺陷类别及 spec 固化见 [实施复核记录](./research/implementation-review.md)。

## 页面反馈后的当前运行状态

用户随后要求保持本地隔离环境运行并检查页面。当前 `http://127.0.0.1:3099` 和演示 Neo4j 保留运行，四组原有凭据均可继续使用。按页面反馈移除调用方的环境/来源/表范围规则，加入启用状态列及物理删除。删除仅用于本次验证创建的临时调用方，没有删除四个演示调用方。

最终页面已重新构建、嵌入 Rust 并运行；1076×986 用户窗口、桌面、平板、手机及深色主题均已检查。调度先后发布 A→T 与 B→T，个人 INSERT 只形成使用记录，正式图仍为 B→T。验证脚本、浏览器和临时回归 Neo4j 已清理，用户验收用的服务保留。

本次调整、API 合同及验证细节见 [策略精简与调用方管理验证](./research/token-policy-followup.md)，页面截图位于 `research/ui-token-policy/`。未提交代码，尚待用户验收。
