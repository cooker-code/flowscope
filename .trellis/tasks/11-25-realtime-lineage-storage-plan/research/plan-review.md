# 规划检查记录

日期：2026-11-25。检查对象为用户选择方案 B 后更新的规划产物；不是实现测试或用户验收。

## 范围与事实

- 用户已同意建 task，确认临时解析只留记录、可信来源更新正式图，并明确选方案 B：FlowScope 内的 Rust 存储层，先 Neo4j、后 PG，不依赖 Python 服务；PRD、设计、执行计划及移植清单已同步。
- UDF 负责解析调用，Python batch 负责入图，两者未混淆。现状 HQL/JAR 仅本地实现证据，线上注册与正式调度未回读已标明。
- 核实到的线上健康、schema 配置、Neo4j 版本/约束/标签、计数及最大表 utime 已记录；最大 utime 未写成分区日或完整更新时间证明。
- 历史 sink 接口描述与当前线上 OpenAPI 的差异已明确，没有把历史设计当作可调用接口。
- 日常维护失败有现存运行记录和日志支持；本轮没有重跑生产任务或把健康检查当作刷新成功。
- 上述运行事实沿用前轮只读证据，本次仅更新技术方向，没有重复查询生产或宣称新的线上状态。

## 本轮 API 标识核查

本轮对主目录和规划工作树 d4e89415 做源码取证：HTTP 请求支持 sourceName/source_name、files[].name；client_ip 来自连接。sourceName 原样传递并用于审计，没有任务/版本/写图权限语义。Rust handler/router 未读取 Authorization/Bearer，也无解析 API token 校验；网页和本地 Hive UDF 调用未带解析 API 凭据。Librarian AI API Key 与此无关。外部网关鉴权未核实，未发送解析 POST 或凭据试探请求。证据见 api-write-policy.md。

## 本轮统一接口、策略页面和个人图记录核查

用户确认解析成功与正式图更新成功分别表达，并要求统一 `/api/analyze` 识别调度/个人 token、可配置策略页面与个人查询标记。已补入 R10–R13/A8、设计第 5 节、个人图模型和 P2/P2b/测试矩阵。

当前 SQLite 核查为源码证据：success 来自 summary.has_errors 的反值，警告可与成功共存；analyze 的 error_msg=None，解析错误在 result_json.issues，且结果可能截断。本轮未查询具体 SQLite 行，不将用户“有报错”的表述直接当作已证实 bug。

有效方案采用生产统一 Bearer、调度默认 publish、个人默认 record_usage、可按策略降级，匿名迁移仅 parse_only。取消前稿另一解析发布入口和仅重启加载策略的安排。管理员经 Rust API 在 SQLite 保存并激活 revision，active_revision 可回读；后台复核当前主体与策略，修改策略不自动重放历史。

个人 actor/event/USES_TABLE 与正式血缘关系分开。未知表不由个人请求创建正式元数据，个人 INSERT 仅记录 declared_write；新模型默认记录解析提交，不冒充 SQL 执行或已成功访问。token 轮换、多文件、幂等、越权与状态分别验收。完整功能/API/数据需求见 policy-page-and-personal-usage.md。

页面仅完成功能和接口需求，本轮没有视觉稿/原型/代码。impeccable loader 已确认 PRODUCT.md/DESIGN.md 缺失，未伪造设计语境或进入 craft；待正式 UI 阶段再按 skill 完成必要设计上下文。本轮规划范围内的接口、SQLite、权限及交互状态均已记录，不以该视觉阶段前置条件阻断它们。

## 需求到方案

| PRD | 设计与实施覆盖 |
|---|---|
| R1/R2/R9 | flowscope-cli → flowscope-storage → core；同进程 Rust 调用、驱动直连；Neo4j 先实现、PG 后适配 |
| R3 | 六类 core 边、所有现有图对象、过滤/JOIN/UNION/窗口；未支持场景显式拒绝激活 |
| R4/R8 | 稳定来源与源版本、发布/执行/临时观测分开、可信来源激活门禁 |
| R5 | 持久投递、提交后 ack、同源锁内比较、共享贡献和失败回滚测试矩阵 |
| R6 | 原图/固定样本对照、独立 Community 实例、Rust 状态与图直查、旧图回退；旧 Python HTTP 仅作可选客户端对照 |
| R7 | Rust 日批导入共用入口、完整快照才能撤回、源水位和切换事件衔接 |
| R10–R13/A7/A8 | 统一 analyze 的身份与默认动作、持久策略页面、个人使用图、真实执行证据边界和审计关联 |

## 方案 B 依赖核对

- 新增的是 Rust crate 与 Neo4j 适配器；没有规划 Python 包、写入服务 API、嵌入解释器或子进程。
- HTTP handler、持久事件 worker、快照导入器统一调用 flowscope-storage；版本比较最终仍在数据库事务内，未因去掉跨服务 HTTP 而弱化并发保护。
- core/WASM 不反向依赖 storage，沿用 serve 的可选依赖边界；驱动适配与 glibc 2.17 构建检查列入 P0/发布验收。
- 元数据由输入快照、Rust 适配器或 Neo4j 直查补齐；不隐含调用 Python 字段接口。
- embedding/旧检索客户端没有成为首期写入通过条件；保留已有向量与标记过期的边界已写明。
- 新增“仅运行 Rust FlowScope 与 Neo4j”的端到端用例；Python 既有固定输出可作为测试材料，但不要求在新运行环境启动 Python。
- 旧 Python uv.lock 故障仍是现状证据，已移除其作为新链路前置条件的表述；切换时仍需停止旧 writer 竞争已迁移来源。

风险保留：源系统事件能力和版本字段未确定；同 SQL 不同解析上下文需要显式产物身份迁移；当前生产图没有 scope provenance；元数据缺失不可假装完整；性能目标未压测；线上切换未授权、未执行。

## 图解自读

现状图的自读问题：谁送 SQL、谁解析、JSON 到哪里、谁真正写图？按图内标签能复述 Change/Mario 快照→HQL→UDF→FlowScope，原 JSON 经 UDF 返回 HQL 存分区，再与物理字段分区导出两份 CSV，batch 写 Neo4j，向量更新与检索读图。图注明这是链路定义，最近一次维护未成功走完。

目标图自读：统一 analyze 先校验 token/策略，缺失/无效凭据或越权拒绝；core 解析后 parse_only 直接返回，其他完整事件先持久化 SQLite；后台复核策略，调度 publish 更新正式来源贡献、个人 record_usage 写使用层、observe/错误保留记录，撤权则阻断。三条存储分支均是 Rust 直连 Neo4j，提交结果分别记状态，不经过 Python。策略管理是已记录的独立管理 API，页面保存后的 active_revision 决定后续判定。

个人关系图自读：稳定用户通过 SUBMITTED_QUERY 连到一次解析提交，事件通过 USES_TABLE 指向已唯一确认的表，或指向保留缺口的 TABLE_REFERENCE。事件标签带“解析提交”和 SQL/使用方式，不表示真实执行；图中没有个人事件到生产 READS_FROM 的路径。

配色：蓝色表示重点模块或拟建流程，黄色标后续 PG；没有用绿色声称规划已实现。已做结构和语义自读，未进行当前 Codex 聊天客户端的单独渲染验收，不将其表述为已验证界面效果。

## 文件与工作区

完整性核查：PRD、design、implement、research 文本非空；JSON 可解析；无未填占位；代码围栏成对；research 中已有绝对证据路径存在。方案 A 的 Python 模块/内部写入接口不再出现在有效实施步骤中。任务状态为 planning，分支 codex/realtime-lineage-storage-plan，基线 master，独立工作树位于项目 .worktrees 内。

业务验证：只做生产 GET/Neo4j 只读查询及源码取证。无代码构建、单元/集成测试、生产写入、部署或维护任务回放；本轮没有对应实现，不能报告实现测试通过。

工作区范围：本轮写入仅在规划工作树的新 task 目录，未提交，未创建 Rust 源码或修改 Cargo 配置。用户已确认技术方向、两类 token 行为和状态分离；更新后的完整文档尚待用户审阅，不能把选型确认当作实现授权或实现验收。
