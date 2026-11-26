# 方案 B：Rust 存储层实施顺序与验收计划

2026-11-25 用户已批准首批实现：Rust /api/analyze token 策略、Neo4j 存储、策略页面，以及调度/个人 token 的隔离验证。本次实现和检查由主会话直接完成；结果与后续范围见 [implementation-result.md](./implementation-result.md)。下列 P0–P5 保留为完整路线图，不代表所有后续来源接入和生产迁移均已完成。

## 0. 实施前的决定与证据

- 用户已同意创建规划 task，明确选方案 B；新增统一 analyze 的调度/个人 token、策略页面和个人查询使用记录。解析结果与各类图写入结果分别表达，个人不修改正式生产血缘。
- `prd.md`、`design.md`、本文件及 research 一起评审。用户已要求实现并执行 task.py start。
- 业务实现集中在 FlowScope Rust workspace，进入新 crate 前核对 AGENTS、Trellis spec 和分支；主 master 保持只读。neo4j-http-service 原项目仅取证、固定输入和验证规则，不给它新增写入 API 或 Python storage 模块。
- 首期默认单实例 FlowScope + 持久磁盘 + 独立 Neo4j 验证实例。实际部署不满足时先调整事件仓库设计。
- 先核实源正式 API、稳定 ID、发布顺序和撤回来源；缺失不阻塞纯转换和观察记录，但会阻止正式激活该来源。

## 1. P0：固定基线与输入合同

产出：版本化接口契约、现状/候选结果对照样本、可复现输入清单。

1. 核对已部署 UDF JAR 与 Change 正式 HQL、依赖、业务日期，补齐本轮只读未查的线上事实。
2. 固定两份同分区 CSV、parser build、schema snapshot、源版本及测试图 URI；按文件和分区校验输入完整性。
3. 样本至少包含普通 INSERT、CTE、别名/子查询、JOIN 依赖、UNION、窗口、常量、SELECT *、目标列位置映射、Change-export、Mario、共享 SQL、多生产者、失败与多目标 SQL。
4. 定义 event/source/artifact/revision/fact 身份，明确业务版本与解析修正版本比较规则。
5. 在独立 Neo4j Community 实例部署测试图；不得直接以生产库新 database 名代替隔离。
6. 从官方资料和实际验证选定 Rust Neo4j 驱动，冻结 Bolt/Neo4j 5.27、事务和提交未知错误处理、连接池、TLS、Rust 工具链及 glibc 2.17 构建兼容证据。不能照搬 Python driver 的隐式重试约定。
7. 建立现有 Python loader 规则→Rust 模块→固定预期用例的移植表，核对来源质量、表/字段、SYNC、JOIN/UNION、CTE、别名、位置映射、窗口和共享版本规则；不复制历史接口文档中的未实现代码。
8. 冻结统一 `/api/analyze` 的生产严格 Bearer 身份合同与匿名 parse_only 迁移窗口。调度 token 经管理员授权默认 publish，个人默认 record_usage，均可配置 observe/parse_only；个人不能升为 publish。定义范围、禁止规则、管理权限和三个结果状态，见 `research/policy-page-and-personal-usage.md`。

通过条件：契约能表达所有现有语义和不完整状态；真实来源的版本顺序可说明；未覆盖来源明确降为 observation。

## 2. P1：新增 flowscope-storage 与 Neo4j 语义存储

产出：`crates/flowscope-storage`、Rust Neo4j 事务适配器、来源/产物/贡献 Schema 迁移与相应 spec；具体参考清单见 `research/rust-porting-map.md`。

1. 注册 workspace member/dependency，新增 model/normalize/store/service/error 和 Neo4j 后端。把已核实 loader 规则移植为 Rust pure normalize，不读 CSV、不打开连接、不直接调用元数据接口。
2. 实现观测记录、个人 record_usage、提交新来源版本、撤回、回执及当前版本读取的 Rust 语义接口。storage 依赖 core 的公开结果类型，core 不依赖 storage；CLI 通过 serve feature 加载可选 storage，普通 CLI 和 WASM 不引入驱动。
3. 实现 Neo4j 唯一约束、来源锁内版本比较、幂等和单事务投影替换。
4. 在新图使用含解析上下文的 artifact 身份，显式更新旧 fs_uid 契约和兼容查询；保留原 sql_md5 追溯。
5. 在 flowscope-cli 中增加 Rust CSV/JSON 快照导入模块，逐来源调用同一存储服务；先小样本对照，后完整来源快照重放。完整快照的缺失检测与单条事件路径分开，不改成调用 Python loader。
6. Rust 当前版本读取及 Neo4j 物化关系遵守当前有效贡献。多个生产者不以单个 M_TABLE.task_sql_md5 决定真相；旧 Python 查询客户端只做兼容评估，不作为运行依赖。
7. 实现 QUERY_ACTOR/QUERY_EVENT/TABLE_REFERENCE 与 SUBMITTED_QUERY/USES_TABLE。个人只挂使用角色，未知表不新建正式表/字段；事件幂等、同用户 token 轮换和多文件去重分别验收，不复用生产依赖关系。

通过条件：相同输入业务语义对齐；所有版本、共享、事务失败用例通过；无意外物理节点删除或值/控制依赖混淆。

## 3. P2：解析服务内编排与可靠后台写入

产出：FlowScope 同进程解析/存储编排、完整事件持久化、重启恢复、写入状态 API；取消跨服务内部写入端点。

1. 统一 `/api/analyze` 的调度/个人调用，解析只调用一次 core，保留完整结果；AnalyzeResult JSON 保持兼容，新增身份和事件/存储状态响应头，网页能读取。
2. 不另建解析发布入口。HTTP 层严格校验 Bearer，按主体/type 和当前策略选择默认动作。调度 token 的 publish 策略可直接触发正式候选，个人 token 选择 record_usage；缺失/无效凭据 401、越权 403。迁移匿名请求仅 parse_only，不写任何 Neo4j 数据。
3. 在 SQLite 持久库事务内写完整事件、pending 状态、策略判定与审计关联，提交后确认 queued。按现有数据库迁移顺序扩展 audit 的 request/event/principal/token_id 关联；重构可靠路径以避免旧 channel 再写一份重复审计。parse_only 仍可独立运行原审计。
4. 后台 Rust 任务直接调用 flowscope-storage，按来源控制顺序，配合 Neo4j 事务内锁和版本判断；成功提交后标记本地事件终态。应用启动初始化存储连接池，关闭时处理在途任务、释放连接，未完成事件保留待恢复。
5. 覆盖 timeout-after-commit、重启、网络中断、容量/磁盘失败、永久校验失败和人工重放。
6. 完整事件记录 principal_id/type、token_id、有效动作、policy_revision 和原因，不保存原始 token。后台每次提交前按当前有效策略复核；重启后旧队列不能沿用已撤销权限。已提交事件仅回读原回执，不重复变更或自动撤销；lineage_status 和 usage_status 分别维护。
7. 事件状态查询按主体/来源授权；快照导入同样需要受控导入主体和相同策略。浏览器若发送 Authorization，核对现有 loopback CORS 只允许 Content-Type 的限制并做针对性调整；服务级发布凭据不内嵌前端产物。

通过条件：只运行 FlowScope Rust 服务和 Neo4j，即可完成解析、个人使用记录、可信版本更新、策略持久生效、事件/当前版本查询及重启恢复；不调用 Python HTTP、FFI、解释器或子进程。不丢已受理事件，重复重放无重复关系；解析成功/已受理/正式生效分别表达。

## 3b. P2b：策略管理页面与审计回溯

产出：Rust 主体/token/策略管理 API、SQLite 持久策略与运行时快照、新策略页面及 AuditPage 联动。功能需求见 policy-page-and-personal-usage.md；本轮不形成视觉设计稿或 UI 代码。

1. 先实现管理 API 的 policy_admin 校验、主体/token 生命周期、策略读写与无副作用预览。token 绑定稳定主体，服务端只存摘要；管理员初始凭据来自受控部署配置，不能匿名发放管理权限。
2. 保存带 expected_revision，经 SQLite 事务与运行时快照加载后返回 active_revision；无法激活、保存冲突与存储失败可区分。队列读取有效 revision，策略变更不自动重放历史记录，在途事务的生效边界明确。
3. 新增策略管理入口并扩展现有 `/audit`：配置默认动作和范围、预览历史请求、保存/启停、查看解析/正式图/使用图的独立状态与原因。未知历史主体不自动认领，个人只能看自己，管理员管理范围由后端限制。
4. API 用受控样本证明判定和生效后再接前端；前端定位为 App 路由、现有 AuditPage 与拟新增策略页。沿用 URL 筛选状态和项目组件；页面视觉实现前再补齐产品语境与形态确认，本轮不绕过 skill 门禁创建设计稿。
5. 端到端验证：同一 API 上调度与个人两个 token 产生不同有效动作；保存后下一次请求/未开始队列用新 revision；无权用户、空列表、规则不匹配、预览无写入、失败/未生效和并发保存冲突均正确呈现。

通过条件：配置通过 Rust API 持久化且实际生效，不仅改变页面；解析历史可以解释为什么写/不写哪一类图，修改策略不会把历史 SQL 自动发布。

## 4. P3：可信实时来源与元数据

产出：Rust Change/Mario 首个来源适配器和物理元数据补齐。

1. 接入一个能提供正式版本的 Change 发布源。若只有轮询 API，明确其延迟目标和稳定游标，不称事件推送。
2. 接入 Mario ID/版本；定义 Change-export 目标与来源补全规则，不靠 SQL 猜外部目标。
3. 个人页面默认形成 record_usage（可按策略降级），身份来自个人 token。先标记解析提交；只有受信执行平台的执行 ID/状态能补充实际查询结果，不将 SQL 提交或个人自报成功当作执行证明。
4. schema 不完整时进入 pending_metadata；通过提供的快照、Rust 元数据适配器或 Neo4j 直查补齐后重解析并提交新 analysis_revision，保证每次正式激活的表/列图来自同份完整快照。不得依赖 Python 表字段接口获取元数据。
5. 兼容已有向量属性：写入时保留无关属性，文本变化记录待刷新信息。首期不迁移 embedding 模型，不运行 Python embedding 或语义检索服务来完成血缘写入。

通过条件：可信发布后无需等 CSV 即可查询新版本；临时解析不改变正式图；下线和旧事件不能互相复活；源事件延迟和解析到图延迟实测，元数据链路也不依赖 Python 服务。

## 5. P4：完整回填、灰度与切换

产出：按来源水位衔接的完整候选图、差异报告、回退方案。

1. 先给网页、UDF/调度调用方适配 token 与所需上下文，显式限定匿名 parse_only 迁移窗口；完成后启用生产严格身份与管理员默认动作。固定已验证 Rust 构建、Cargo.lock 与存储配置，按项目既有生产打包流程验证 Linux glibc 2.17。旧 Python 维护的 uv.lock 问题仅作为历史基线状态，不要求修复它才能运行 Rust 新链路。
2. Rust 快照导入器从完整可信源输入在新实例重建图，同步捕获后续增量；快照边界前后的重叠事件统一幂等处理，不在候选图构建环境调用 Python loader。
3. 原生产图只用于对照。以 SQL 和独立分析确定预期，不因旧图已有边就判新图错误，也不以新旧总数相近当作正确。
4. 所有日批补偿改走同一 Rust 入口。切换时停止旧 Python writer 对已迁移来源的管理；历史分区重跑不得回退新发布。
5. 验证 Neo4j 直查与 Rust 事件/当前版本接口读取同一版本。现有 Python HTTP 仅做可选兼容对照，其继续使用的适配另行确认，不成为新链路通过条件。获准后切换连接与受影响客户端，保留旧图和事件重放能力。
6. 在隔离环境实际演练回退：停止激活、切旧图、保留积压、恢复新图并重放，核对重复效果和版本水位。

通过条件：当前图语义和生产接口对照通过；新旧实例资源、保留期和发布窗口明确；切换没有采集空窗，回退演练有证据。

## 6. P5：按需要增加 PostgreSQL

1. 在 flowscope-storage 增加 Rust PG 适配器，实现相同 LineageStore 契约、事务和索引；解析结果使用 JSONB，版本与端点结构化索引，不重新实现 SQL→存储模型转换。
2. 复用同一套语义验收，不复制 SQL→图转换逻辑。
3. 若要求双写，增加独立 destination 的投递水位和补偿；不得承诺两库跨库原子性。

依赖：P1 合同稳定；与实时 Neo4j 首期验收分开。没有 PG 需求时不预先实现空 adapter。

## 7. 必测矩阵

| 用例 | 必须观察到的结果 |
|---|---|
| A→T 可信版本变为 B→T | 本来源旧贡献移除，新贡献出现，同一事务内完成 |
| 临时 B→T | 历史可查，正式 A→T 不变 |
| 个人 INSERT 或伪造 publish/context/用户 ID | 只按可信个人权限写 usage/记录，正式表/字段和生产依赖不变 |
| 个人引用未知或歧义表 | 独立 TABLE_REFERENCE/unresolved，不新建正式 M_TABLE/Physical |
| 个人 SQL 使用细节与执行状态 | SQL、过滤/JOIN/聚合/字段/窗口可回看；默认 not_observed，不称实际执行成功 |
| 个人 token 轮换、多文件与重试 | 稳定同一用户，一个 event 只计一次，新请求可产生新事件 |
| 策略页面保存/启停/重启 | active_revision 可回读，下一次/未开始事件使用新规则；未激活不能冒充生效 |
| 策略预览与历史匿名记录 | 预览零写入，历史身份不猜测，不自动发布旧 SQL |
| 个人/调度访问管理或他人详情 | policy_admin 与主体范围均由 API 强制，不只隐藏按钮 |
| 无 token 或仅将 sourceName 改为正式任务名 | 生产严格模式 401；匿名迁移最多 parse_only，不获得任何 Neo4j 写权限 |
| 两类 token 调同一 `/api/analyze` | 已授权调度默认 publish，个人默认 record_usage，无需第二个解析入口 |
| 严格身份模式缺失/无效凭据 | 401；不受理图写入，不从用户名/IP 猜调用主体 |
| 有效凭据无发布权限、来源/环境越界或命中禁止规则 | 拒绝正式提交，拟返回 403；请求字段不能扩大凭据权限 |
| publish 权限有效但缺源版本或解析/元数据不完整 | 明确未激活原因，不把记录成功称为正式图更新 |
| 已受理 queued 与 Neo4j committed | 前者只保证本地事件持久化，后者才证明正式事务已提交 |
| 排队后重启并撤销主体/来源权限 | 当前策略复核阻断新正式提交；已提交重试只回读回执 |
| 快照导入/状态查询尝试越权 | 同样按受控主体与来源授权，不形成旁路 |
| 旧版晚到、下线后旧版晚到 | 均不回退/复活 |
| 同 event 重发、提交后响应丢失重发 | 回执相同，边和贡献零增量 |
| 同源并发新版/旧版 | 数据库内版本判断，最终保持最新合法源版本 |
| 两源共享解析产物，一源撤回 | 另一来源及其可查路径保留 |
| Change 与 Mario 数字 ID 相同 | namespace 区分，不合并来源，不相互撤回 |
| 多任务共同写一张表 | 不被单值 task_sql_md5 覆盖，有各自 provenance |
| SQL 不变、parser/schema 改变 | 新 artifact 与 analysis_revision 可区分，其他有效来源不被覆盖 |
| 新版解析失败、空脚本、HTTP 错误 JSON | 失败记录可查，旧有效图保留并标记 stale/blocked |
| 合法常量 SQL、没有上游 | 与失败/空结果区别处理，按完整可信快照正确更新 |
| SELECT *、别名歧义、缺字段元数据 | pending/partial 可见，不伪造 Physical 或完整列血缘 |
| 多物理目标 | 明确 unsupported，不能取第一张目标替换 |
| 完整快照与局部 CSV | 只有完整受信来源清单允许生成撤回事件 |
| 表/列/CTE/表达式/控制依赖 | 端点、方向、类型、条件、表达式与已确认 SQL 一致 |
| CrossStatement 跨文件语义 | 原始端点和语句对完整保留，未支持投影时明确拒绝正式激活 |
| 写入中段故障、关系端点缺失 | 整个来源事务回滚，旧版本完整可见 |
| 服务重启/队列磁盘满/超大结果 | 已受理可恢复；未受理明确失败；完整 JSON 不被截断冒充成功 |
| 仅启动 Rust FlowScope 与 Neo4j | 解析、个人 usage、可信更新、策略 API、快照补偿、元数据补齐、状态读取均通过，无 Python 服务或子进程调用 |
| 驱动提交结果未知、应用在标记终态前崩溃 | 重放同一 event_id 查回原提交结果，来源贡献不重复 |
| 普通 CLI / WASM 与 serve 构建 | 前两者不引入存储驱动；serve 使用同进程 Rust 存储能力 |
| 昨日快照重放与实时新版交错 | 旧补偿不覆盖新版，缺少可比版本则不激活 |
| 已有向量属性及注释改变 | 无关向量不被清空，文本变化标记待刷新；embedding 系统不可用不阻塞图提交 |

## 8. 针对性验证命令

命令为后续对应阶段使用，不在纯规划轮运行全量构建。

Rust 存储模块：`cargo test -p flowscope-storage`，再对独立 Neo4j 实例运行迁移、事务、同源并发、重放和失败回滚集成测试。测试图 URI 必须断言为隔离目标；不能只靠 mock 或旧 Python HTTP 返回替代真实事务验证。

FlowScope 服务：新增后台存储/状态测试先用 `cargo test -p flowscope-cli --features serve <测试过滤>`，按构建依赖需要使用 `just test-cli-serve`；增加 Rust-only 黑盒用例，环境中不部署 Python 服务，直接使用固定 JSON/CSV 和 Rust API/Neo4j 读回验收。源代码同时检查无 Python HTTP 写入、FFI 和进程启动路径。

依赖与打包：核对 `cargo tree -p flowscope-core` 和 `cargo tree -p flowscope-wasm` 没有反向 storage/驱动依赖；检查普通 CLI 的依赖及构建，检查 WASM 目标构建；serve 构建和存储驱动按既有 release-workflow 的 zigbuild/glibc 2.17 流程验证。驱动选型完成后在实施记录中冻结具体版本、TLS 和集成测试入口。

基础解析变更才扩大至 `cargo test -p flowscope-core --lib` 与现有真实 SQL 回归；项目已有 `scripts/regression-test-sql.py` 属于开发验证脚本，不代表生产服务需要 Python。公开 JSON 契约变化还需 `just check-schema`，修改前端才跑对应 yarn typecheck/build。本轮没有业务实现，不执行这些构建和测试。

前端阶段需先验证管理 API，再执行 app 的 typecheck/build，并同步嵌入资产后验证 CLI serve 的新路由、策略生效与审计状态；构建流程沿用 just 及项目 UI 协议。若生成 Playwright 脚本，遵守上下文/浏览器嵌套 finally 清理和进程退出核查要求。

实施每阶段按项目 trellis-before-dev / trellis-check 流程加载适用 spec。源码和行为未变化时复用已验证结果，不无目的重跑全仓。

## 9. 原规划检查记录（实施前快照）

检查内容：已确认方案 B 在 PRD/设计/执行计划中一致；Rust crate 与依赖方向明确；移植和对照范围完整；无 Python 写入服务、元数据补齐或 embedding 隐藏依赖；保留可靠投递、版本、事务和共享保护；来源标识与可信身份分开、服务端策略在正式写入前生效；queued/committed 时点区分；历史证据未伪装成新运行结果；链接与文档完整；task 仍为 planning。图解交付前只看图自读路径，结果记录在 `research/plan-review.md`。
