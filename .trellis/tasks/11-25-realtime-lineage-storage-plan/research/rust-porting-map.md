# 方案 B：Python 入图规则到 Rust 的移植清单

2026-11-25 用户已选择 FlowScope 原生 Rust 存储层。本表用于实施和对照验收，不代表代码已移植。

## 1. 技术边界

- 新增 FlowScope workspace crate `flowscope-storage`，生产调用链仅为 Rust FlowScope → Neo4j；PG 后续增加同契约的 Rust adapter。
- neo4j-http-service 提供图结构、入图规则和已有结果作为参考；不把原 Python 包、HTTP 服务、解释器、FFI、子进程或 embedding 模型放入新写入链路。
- 固定 Python 实现的既有输出可用作一次性对照材料。Rust 单元和集成测试使用落盘的 JSON/CSV/业务语义预期，不要求测试时启动 Python 服务。
- 已有修复脚本中的规则需要核实是否已进入常规 loader；不能为了复用而把一组历史修复脚本作为新链路前置步骤。

## 2. 规则对照

原规则根目录：`/Users/blank/wangliang/gitcode/neo4j-http-service/`。

| 参考文件 | 必须保留/明确调整的语义 | Rust 归属与验证 |
|---|---|---|
| `docs/plan/graph-schema.md`、`docs/agents-1-full-initialization.md` | 现有节点业务键、标签、边方向和属性；历史未实现章节不得当成现状 | model、normalize、Neo4j schema；与当前源码及已取证图交叉核对 |
| `src/batch/source_quality.py` | 空 SQL、结构错误和假成功结果不更新正式图 | normalize/service；用合法常量、空脚本和错误 JSON 分别验证 |
| `src/batch/load_table_meta.py` | M_TABLE、TEMPLATE、锚点表、任务/模板属性及 catalog 规则 | normalize + Neo4j adapter；多生产者改为可信贡献，单值兼容属性不作为唯一归属 |
| `src/batch/load_column_meta.py` | Physical 自然键、类型/注释、列→表归属；元数据与解析推断区分 | Rust 元数据输入 + normalize；缺字段不能虚造 Physical |
| `src/batch/load_reads_from.py`、`src/batch/source_filters.py`、`src/batch/read_dependency_kind.py` | 上游→下游、过滤条件、反馈依赖分类；frequency 不是执行次数 | normalize + 当前 fact 物化；旧来源移除不能误删其他来源 |
| `src/batch/load_sync.py` | Change-export、SYNC 稳定身份、外部目标与真实上游区别、禁止错误目标自指 | normalize；多来源证据和 override 的可信度有明确输入合同 |
| `src/batch/load_joins.py`、`src/batch/load_unions.py` | JOIN 方向/类型/条件、RIGHT JOIN 规范化、UNION 分支属性 | normalize；不能用最后一次写入覆盖其他有效来源条件 |
| `src/batch/load_cte.py` | CTE 与 REF_TEP 的真实端点、方向和解析上下文 | normalize + artifact 身份；不靠任务名或 task_id 猜共享归属 |
| `src/batch/load_col_lineage.py` | 物理/逻辑字段区分、别名、表达式、位置映射、ownership、target_map、共享保护 | normalize + 事务 adapter；移植 value/ownership 语义，不移植分批提交造成的半图可见性 |
| `src/batch/load_window_controls.py` | CONTROLS_COL、partition/order 角色、未决状态与 complete 才能替换 | normalize；控制依赖不进入值来源 |
| `.trellis/spec/backend/lineage-version-scope.md` | change/mario namespace、共享/legacy 保护、局部输入不删、多版本歧义处理 | source/revision/fact 模型与 Rust store；新增原子版本提交，不能只复刻旧清理函数 |
| `src/batch/init_schema.py`、`src/batch/_neo4j_writer.py` | 唯一约束、参数化写入；批次重试仅作历史行为证据 | Rust schema/write；显式事务、锁内版本比较，依据所选 Rust driver 定义重试 |
| `src/batch/cleanup_isolated_residue.py`、`src/batch/verify_load.py` | 残留分类、共享保护、端点与元数据完整性检查 | Rust 导入/集成测试；全图清理不进入单条实时事件 |
| `src/service/neo4j_client.py` | 现有查询路径和单值 task_sql_md5 过滤的兼容范围 | 可选客户端对照；新版本以 Rust 状态和 Neo4j 当前物化图证明，不依赖 Python 路由 |
| `src/embedding/build_embeddings.py` | 物理节点向量属性及文本变化时的过期问题 | 首期仅兼容保留/标记待刷新，不移植模型，不成为写入成功条件 |

## 3. FlowScope 实施位置

现有 workspace 在根 Cargo.toml 只有 core、wasm、cli、export。现有 serve feature 已包含 Tokio、Axum 和 rusqlite；现有 sqlx 用于元数据读取。上述依赖存在不等于新 storage crate 或 Neo4j 写入已实现。

拟增/调整职责：

| 位置 | 作用 |
|---|---|
| 根 `Cargo.toml`、`Cargo.lock` | 登记新成员与依赖，冻结实际选定的驱动 |
| `crates/flowscope-storage/src/lib.rs` | 公开含 record_usage 的标准契约与 service，不暴露驱动实现给 core |
| `src/model.rs`、`src/store.rs` | 事件、来源版本、标准快照、提交结果、存储 trait |
| `src/normalize.rs` | 按对照表移植纯转换 |
| `src/service.rs`、`src/error.rs` | 质量预检、存储编排、可重试/终态/提交未知的结构化结果 |
| `src/neo4j/` | 驱动连接池、schema、原子提交、回执/当前版本读取 |
| CLI `src/server/lineage_policy.rs` 与管理 API 模块 | 主体/token 摘要、SQLite 策略、运行时 active_revision 和无副作用预览 |
| app 现有 AuditPage 与拟新增策略页面 | 调用身份、两类图结果、策略管理和生效反馈；管理权限由 Rust API 强制 |
| `crates/flowscope-cli/Cargo.toml` | 沿用 serve feature 引入可选 storage 依赖 |
| CLI `src/server/api.rs`、`state.rs`、`mod.rs` | 解析/写入入口、配置、后台任务生命周期 |
| CLI `src/server/lineage.rs`、`lineage_outbox.rs`、`lineage_import.rs` | 同进程编排、持久事件、Rust 快照输入适配 |
| 新 crate 和 CLI 对应 `tests/` | 固定样本语义对照、隔离 Neo4j 集成及无 Python 服务黑盒验收 |

后续实现时新增相应 storage spec，并同步已有边类型/来源版本契约；本轮没有创建以上源码文件。

## 4. 对照验收方法

固定同一原 SQL、AnalyzeResult、schema snapshot 和来源上下文，对比原始预期与 Rust 标准快照中的业务端点、方向、表达式、类型、过滤条件、角色和归属。ctime/utime 不作为等价比较依据；fs_uid 变更按已设计的 artifact 上下文迁移显式映射，不能直接忽略差异。

不能只比较节点/边总数。旧图已知残留、规则修复或新版本模型导致差异时，逐项解释并用原 SQL/独立预期判定。未知端点、unsupported 和 partial 必须在结果中体现。

独立运行的必要用例：环境中仅启动 Rust FlowScope 和隔离 Neo4j，验证临时记录、可信激活、版本替换、同源并发、共享保护、撤回、快照导入、元数据补齐、回执读取、断连重试和进程重启。Rust 进程不得调用 Python HTTP、FFI 或子进程；开发期现有 Python SQL 回归脚本与生产运行依赖分开说明。
