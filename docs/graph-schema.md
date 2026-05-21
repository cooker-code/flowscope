# Neo4j 图模型总览（FlowScope 血缘图）

> 本文描述 FlowScope SQL 解析结果在 Neo4j 中的存储模型。
> 代码实现位于 `neo4j_proc/`，数据由 `neo4j_proc/parse_and_sink.py` 写入。

---

## 总体设计原则

| 原则 | 做法 |
|---|---|
| **物理表是锚点** | `READS_FROM` / `JOINS_WITH` 只在 `M_TABLE` 间建边，查血缘无需绕 CTE |
| **CTE 保留细节** | `REF_TEP` 完整保留 CTE 链路，每步读取的过滤条件挂在边上 |
| **过滤条件累积** | `CTE.upstream_filters_json` 缓存上游链路的全部过滤条件，不需要 traverse 即可读 |
| **过滤条件贴近读取** | `filters_json` 直接写在边属性上（`READS_FROM` / `REF_TEP`），不建独立 Filter 节点，避免热点 |
| **幂等写入** | 全部使用 `MERGE`，重复运行不产生脏数据 |
| **FlowScope 属性隔离** | 解析写入的属性统一加 `fs_` 前缀，不覆盖已有 Neo4j 元数据字段 |

---

## 节点 / 关系总览

> 整张血缘图共有 **5 种节点** 和 **7 种关系**。下面两张总览表先给出全景，后续章节再分别展开属性细节。

### 节点总览（5 种）

| 名称 | 解释 | 数据来源 |
|---|---|---|
| `M_TABLE` | 物理表 / 视图（任何 SQL 引用过即创建） | SQL 解析 |
| `M_COL` | 列（物理列 + 派生列两种形态） | SQL 解析 |
| `CTE` | CTE / 内联子查询（字段级血缘的中间计算层） | SQL 解析 |
| `UnionGroup` | UNION / UNION ALL 分支汇聚节点（分支表 ≥ 2 时为避免 C(N,2) 边数爆炸而引入的中介节点） | 自生成（SQL 解析推导） |
| `ExportTarget` | 调度系统导出作业终点（仅 SELECT、无 INSERT/CREATE 仓内写入目标，导出到 MySQL/Kafka/文件等仓外目的地） | SQL 解析（占位） + 调度元数据（确认/补全） |

### 关系总览（7 种）

| 名称 | 端点 | 解释 | 数据来源 |
|---|---|---|---|
| `REF_TABLE_COL` | (`M_TABLE` / `CTE` / `ExportTarget`) → (`M_COL`) | 列归属（声明该列属于哪个容器） | SQL 解析 |
| `REF_COL_LINEAGE` | (`M_COL`) → (`M_COL`) | 字段级血缘（列到列，含 `data_flow` / `derivation`） | SQL 解析 |
| `REF_TEP` | (`M_TABLE` / `CTE`) → (`CTE`) | 读取进 CTE，边上携带"该步直接施加的过滤条件" | SQL 解析 |
| `READS_FROM` | (下游 `M_TABLE` / `ExportTarget`) → (上游 `M_TABLE`) | 表级血缘（穿透 CTE，下游主力关系） | SQL 解析（下游为 `ExportTarget` 时由调度元数据补全确认） |
| `JOINS_WITH` | (`M_TABLE`) → (`M_TABLE`) | JOIN 关系（跨 SQL 累计 `frequency`） | SQL 解析 |
| `UNION_BRANCH` | (`M_TABLE`) → (`UnionGroup`) | UNION 分支输入 | 自生成（SQL 解析推导） |
| `UNION_PRODUCES` | (`UnionGroup`) → (`M_TABLE`) | UNION 合并输出到物理表 | 自生成（SQL 解析推导） |

> **数据来源约定**：
> - `SQL 解析` —— 由 FlowScope SQL 解析直接生成，写入属性带 `fs_` 前缀；
> - `自生成` —— 解析逻辑根据语义额外推导出的中介节点 / 关系（不直接对应一段 SQL 文本）；
> - `调度元数据` —— 由外部调度系统补全或升级，写入属性**不带** `fs_` 前缀（与"元数据补全层"约定一致）。

---

## 节点详解

### M_TABLE

**唯一键**：`(db_name, table_name)`
**语义**：SQL 中出现的任意一张物理表或视图。只要被任何 SQL 引用过就会创建，不依赖外部元数据。

| 属性 | 类型 | 说明 |
|---|---|---|
| `db_name` | String | 数据库名，如 `dw_dwd`（无前缀，作为唯一键的一部分）|
| `table_name` | String | 表名，如 `dwd_eng_device_active_da`（无前缀，作为唯一键的一部分）|
| `fs_kind` | String | `table` 或 `view` |
| `fs_fqn` | String | 完整限定名，如 `dw_dwd.dwd_eng_device_active_da` |
| `fs_res_src` | String | 解析来源标记，如 `unknown` / `explicit` 等（来自 FlowScope `resolutionSource`）|
| `fs_sql_path` | String | 最近一次写入时的 SQL 文件路径 |
| `fs_run_id` | String | 最近一次写入的批次 ID |
| `fs_sql_count` | Integer | 累计在多少个 SQL 中被引用（重复 merge 时自增）|



---

### M_COL

**唯一键**（双约束）：
- 物理列：`(db_name, table_name, col_name)`
- 派生列：`fs_uid`（= `run_id::node_id`，无完整归属信息时使用）

**语义**：列节点分两种形态：
- **物理列**（`physical_column`）：能明确定位到具体表的列，有完整三元组
- **派生列**（`projected_column` / `derived_column` / `aggregated_column`）：中间计算列，无法归属到物理表

| 属性 | 类型 | 适用 | 说明 |
|---|---|---|---|
| `db_name` | String | 物理列；派生列若可定位则可选 | 数据库名（无前缀，作为唯一键的一部分） |
| `table_name` | String | 物理列；派生列若可定位则可选 | 所属表名（无前缀，作为唯一键的一部分） |
| `col_name` | String | 全部 | 列名（无前缀，作为唯一键的一部分） |
| `fs_uid` | String | 全部 | 全局唯一标识：`run_id::node_id` |
| `fs_kind` | String | 全部 | `physical_column` / `projected_column` / `derived_column` / `aggregated_column` |
| `fs_fqn` | String | 物理列 | 完整限定名，如 `dw_dwd.dwd_eng_device_active_da.device_id` |
| `fs_res_src` | String | 物理列 | 解析来源标记（来自 FlowScope `resolutionSource`） |
| `fs_expr` | String | 派生列 | 计算表达式，如 `CAST(city_type AS STRING)` |
| `fs_agg_fn` | String | 聚合列 | 聚合函数，如 `COUNT`、`SUM` |
| `fs_agg_gk` | Boolean | 聚合列 | 是否为 GROUP BY 键 |
| `fs_agg_dist` | Boolean | 聚合列 | 是否 DISTINCT 聚合 |
| `run_id` | String | 派生列 | 本次解析的批次 ID |

> 派生列的 `fs_expr` / `fs_agg_*` 仅在 FlowScope 解析得到对应信息时才写入，没有则不存在该属性。

---

### CTE

**唯一键**：`fs_uid`（= `run_id::node_id`）
**语义**：SQL 中的 CTE（`WITH` 子句）或内联子查询。作为字段级血缘的中间节点，不参与表级血缘（`READS_FROM`）。

| 属性 | 类型 | 说明 |
|---|---|---|
| `fs_uid` | String | 全局唯一标识：`run_id::node_id` |
| `fs_node_id` | String | FlowScope 内部节点 ID（如 `cte_xxx` / `derived_xxx`） |
| `label` | String | CTE 别名，如 `a1`、`new_device` |
| `subkind` | String | `with_cte`（WITH 子句定义，`node_id` 以 `cte_` 开头）或 `derived_subquery`（内联子查询） |
| `run_id` | String | 本次解析的批次 ID |
| `body_span_start` / `body_span_end` | Integer | CTE 主体在原 SQL 中的字符 span |
| `decl_span_start` / `decl_span_end` | Integer | CTE 声明位置（`WITH name AS (...)` 中的 `name` 位置）|
| `occurrence_count` | Integer | 同名 CTE 在 SQL 中被引用的次数（基于 `nameSpans` 计数）|
| `upstream_filters_json` | String（JSON） | **累积上游所有过滤条件**（多轮传播，含间接来源），格式：`[{"expression":"...","clause_type":"WHERE"}]` |
| `upstream_filters_count` | Integer | 累积上游过滤条件数量（去重后） |

> `upstream_filters_*` 是为方便查询而预计算的冗余属性。点开 CTE 节点直接可见所有间接祖先的过滤条件，无需追溯链路。

---

### UnionGroup

**唯一键**：`id`（= `sql_md5::run_id::container_node_id`）
**语义**：N 元 `UNION` / `UNION ALL` 的分支汇聚节点。仅当某个输出容器的所有列都同时来自 ≥ 2 张不同的源表时才创建，
用中介节点取代 C(N,2) 条两两边，避免边数量爆炸。**不参与表级血缘（`READS_FROM`）**。

| 属性 | 类型 | 说明 |
|---|---|---|
| `id` | String | 全局唯一标识：`sql_md5::run_id::container_id` |
| `union_type` | String | 固定值 `union`（当前实现未区分 `UNION` 与 `UNION ALL`）|
| `branch_count` | Integer | 分支表数量 |
| `sql_md5` | String | 来源 SQL 内容 MD5 |
| `run_id` | String | 本次解析的批次 ID |

> 配套关系：`(M_TABLE) -[:UNION_BRANCH]-> (UnionGroup) -[:UNION_PRODUCES]-> (M_TABLE)`，详见下文。

---

### ExportTarget

**唯一键**（双阶段，分两步落地）：
- **占位阶段（SQL 解析）**：`fs_uid`（= `run_id::node_id`）—— 解析时无法确认是否真为导出作业，先建占位节点
- **确认阶段（调度元数据补全）**：`(scheduler, task_id)` —— 调度系统确认该 SQL 文件是导出作业后，将占位节点合并/升级为确认节点

**语义**：调度系统中以 SELECT 终止、且没有明确仓内写入目标（无 `INSERT INTO` / `CREATE TABLE AS` 等）的导出作业终点，最终结果导出到仓外目的地（MySQL、Kafka、HTTP、文件等）。

> SQL 解析阶段**无法判定**一个孤立的 SELECT 究竟是临时查询还是导出作业；只有在补充调度元数据后才能确认。**未被调度元数据确认的 `fs_status = pending` 占位节点应在血缘可视化中默认隐藏**，避免 ad-hoc SELECT 污染图谱。

| 属性 | 类型 | 来源 | 适用阶段 | 说明 |
|---|---|---|---|---|
| `fs_uid` | String | SQL 解析 | 占位 / 确认 | 占位节点全局唯一标识：`run_id::node_id` |
| `fs_kind` | String | SQL 解析 | 占位 / 确认 | 固定值 `export_target` |
| `fs_status` | String | SQL 解析 / 调度元数据 | 占位 / 确认 | `pending`（解析占位，未确认）或 `confirmed`（调度元数据已确认） |
| `sql_md5` | String | SQL 解析 | 占位 / 确认 | 来源 SQL 内容 MD5 |
| `sql_path` | String | SQL 解析 | 占位 / 确认 | 来源 SQL 文件路径 |
| `scheduler` | String | 调度元数据 | 确认 | 调度系统名，如 `airflow` / `dolphinscheduler` / `crontab` |
| `task_id` | String | 调度元数据 | 确认 | 调度任务 ID（与 `scheduler` 组成确认阶段唯一键） |
| `task_name` | String | 调度元数据 | 确认 | 调度任务名（人类可读） |
| `target_type` | String | 调度元数据 | 确认 | 导出目标类型：`mysql` / `kafka` / `http` / `file` / `oss` 等 |
| `target_location` | String | 调度元数据 | 确认 | 目标位置：MySQL FQN（`db.table`）/ Kafka topic / 文件路径 / URL |
| `owner` | String | 调度元数据 | 确认 | 业务渠道 |
| `ctime` / `utime` | DateTime | 调度元数据 | 确认 | 见 [时间属性统一约定](#时间属性统一约定mandatory) |

**配套关系**（详见下文关系详解）：

| 关系 | 端点 | 作用 |
|---|---|---|
| `READS_FROM` | (`ExportTarget`) → (`M_TABLE`) | 复用表级血缘关系，标记导出作业读取了哪些上游物理表 |
| `REF_TABLE_COL` | (`ExportTarget`) → (`M_COL`) | 声明导出作业的输出列（以派生列形态存储） |
| `REF_COL_LINEAGE` | (上游 `M_COL`) → (`ExportTarget` 的输出 `M_COL`) | 字段级血缘的终点 |

---

## 关系详解

> **属性前缀约定**：FlowScope SQL 解析写入的属性统一使用 `fs_` 前缀；调度元数据 / 元数据补全写入的属性**不带** `fs_` 前缀，详见后文"元数据补全层"。

```
(M_TABLE/CTE/ExportTarget) ──[REF_TABLE_COL]──> (M_COL)         列归属
(M_COL)                    ──[REF_COL_LINEAGE]─> (M_COL)        字段级血缘（纯列到列）
(M_TABLE/CTE)              ──[REF_TEP]─────────> (CTE)          读取进 CTE（含直接过滤条件）
(M_TABLE/ExportTarget)     ──[READS_FROM]──────> (M_TABLE)      表级血缘（穿透 CTE）
(M_TABLE)                  ──[JOINS_WITH]──────> (M_TABLE)      JOIN 关系
(M_TABLE)                  ──[UNION_BRANCH]────> (UnionGroup)   UNION 分支输入
(UnionGroup)               ──[UNION_PRODUCES]──> (M_TABLE)      UNION 产出输出表
```

---

### REF_TABLE_COL（列归属）

- **方向**：`(M_TABLE / CTE / ExportTarget) → (M_COL)`
- **语义**：声明哪个容器（物理表、CTE 或导出作业）拥有这个列。`ExportTarget` 作为 src 时，dst 为该导出作业的输出列（派生列形态）
- **MERGE 键**：`(src_node, dst_node)` 自然唯一

FlowScope SQL 解析层**不会**在此关系上写入任何属性（关系存在性即代表"列归属"）。
下列字段是为**外部元数据补全流程**预留的占位属性，FlowScope 不写入、不读取。

| 属性 | 类型 | 来源 | 说明 |
|---|---|---|---|
| `is_pk` | Boolean / Integer | 外部元数据 | 是否是主键。SQL 解析无法判定，需由 DDL/Hive Metastore 等外部源写入 |


---

### REF_COL_LINEAGE（字段级血缘）

- **方向**：`(M_COL) → (M_COL)`
- **语义**：列到列的字段级血缘。两端**必须都是 M_COL**，容器级依赖由 REF_TEP / READS_FROM 负责。`data_flow` 为纯透传，`derivation` 表示有计算转换
- **终点扩展**：当下游容器为 `ExportTarget` 时，dst 为 `ExportTarget` 通过 `REF_TABLE_COL` 持有的派生列形态 `M_COL`，无需引入新节点类型
- **MERGE 键**：`(src_col, dst_col, sql_md5, fs_edge_type)`

| 属性 | 类型 | 说明 |
|---|---|---|
| `fs_edge_type` | String | `data_flow`（纯透传）或 `derivation`（有计算） |
| `fs_expr` | String | 转换表达式，如 `CAST(city_type AS STRING)`（仅 `derivation` 时有值） |
| `fs_join_type` | String | 该字段流经的 JOIN 类型，如 `left`、`inner` |
| `fs_join_cond` | String | JOIN ON 条件 |
| `sql_md5` | String | 来源 SQL 内容 MD5 |


---

### REF_TEP（读取进 CTE）

- **方向**：`(M_TABLE 或 CTE) → (CTE)`
- **语义**：记录物理表或上游 CTE 被读入某个 CTE 时**直接施加**的过滤条件。保留 CTE 中间层结构，用于追溯"每步计算读了什么、过滤了什么"
- **MERGE 键**：`(src, dst_cte, sql_md5)`

| 属性 | 类型 | 说明 |
|---|---|---|
| `filters_json` | String（JSON） | **该步直接过滤条件**（来自 src 节点自身的 `WHERE`），分区字段排除，格式：`[{"expression":"...","clause_type":"WHERE"}]` |
| `filters_count` | Integer | 直接过滤条件数量（去重后） |
| `sql_md5` | String | 来源 SQL 内容 MD5 |

> CTE→CTE 的 REF_TEP 边 `filters_count` 通常为 0（CTE 本身不带 WHERE），完整过滤链需查 dst CTE 节点的 `upstream_filters_json`。

---

### READS_FROM（表级血缘）

- **方向**：`(下游 M_TABLE / ExportTarget) → (上游 M_TABLE)`
- **语义**：下游容器依赖上游物理表。**CTE 链路被完全穿透**，只在物理表 / 导出作业之间建边，是血缘统计和影响分析的主力关系
  - 下游为 `M_TABLE`：标准的表 → 表血缘（最常见）
  - 下游为 `ExportTarget`：导出作业读取的上游表；占位阶段即可建立，调度元数据确认后语义升级为"确认的导出依赖"
- **MERGE 键**：`(dst_node, src_table, sql_md5)`（`dst_node` 可为 `M_TABLE` 或 `ExportTarget`）

| 属性 | 类型 | 说明 |
|---|---|---|
| `filters_json` | String（JSON） | 读取上游表时施加的业务过滤条件（格式同 REF_TEP），分区字段自动排除 |
| `filters_count` | Integer | 过滤条件数量（去重后） |
| `sql_md5` | String | 来源 SQL 内容 MD5 |
| `sql_path` | String | 来源 SQL 文件路径（最近一次写入） |


> **分区字段排除规则**：`dt` / `ds` / `p_date` / `partition_date` / `stat_date` / `log_date` / `etl_date` / `biz_date` 的过滤条件被识别为分区裁剪，不写入 `filters_json`。

---

### JOINS_WITH（JOIN 关系）

- **方向**：`(左表 M_TABLE) → (右表 M_TABLE)`
- **语义**：两张物理表之间发生了 JOIN。跨 SQL 累计，同一对表多次 JOIN 会累加 `frequency`
- **MERGE 键**：`(left_table, right_table)`，不区分 SQL

| 属性 | 类型 | 说明 |
|---|---|---|
| `join_type` | String | 主要 JOIN 类型（与 `dominant_join_type` 同值，便于直观查询） |
| `dominant_join_type` | String | 主要 JOIN 类型：`inner` / `left` / `right` / `full` / `cross` 等 |
| `join_type_history` | List[String] | 历史出现过的所有 JOIN 类型（跨 SQL 累计） |
| `left_role` | String | 左表角色：`preserved` / `null_supplying` / `symmetric` / `cartesian` |
| `right_role` | String | 右表角色（同上） |
| `join_keys_json` | String（JSON） | JOIN Key 列表，格式：`[{"left":"t0.id","right":"t1.id","on_expr":"..."}]` |
| `join_conditions` | List[String] | 原始 ON 条件字符串列表 |
| `key_count` | Integer | 等值 JOIN Key 数量 |
| `has_non_equi` | Boolean | 是否包含非等值条件 |
| `has_time_join` | Boolean | 是否包含时间范围 JOIN |
| `has_join_dependency` | Boolean | 是否含仅参与过滤、不贡献列的表 |
| `frequency` | Integer | 被多少个 SQL 引用（跨文件累加） |
| `sql_md5_list` | List[String] | 涉及该 JOIN 的所有 SQL MD5 |


---

### UNION_BRANCH（UNION 分支输入）

- **方向**：`(M_TABLE) → (UnionGroup)`
- **语义**：物理表作为某个 UNION 的一个分支输入，挂接到对应的 `UnionGroup`
- **MERGE 键**：`(branch_table, union_group, index)`

| 属性 | 类型 | 说明 |
|---|---|---|
| `index` | Integer | 分支序号（按分支表 FQN 字典序排列）|
| `is_first` | Boolean | 是否是第 0 个分支（`index == 0`）|

---

### UNION_PRODUCES（UNION 产出表）

- **方向**：`(UnionGroup) → (M_TABLE)`
- **语义**：UNION 的合并结果输出到某张物理表（即输出容器为 M_TABLE 时建边）
- **MERGE 键**：`(union_group, output_table)` 自然唯一

> 该边无业务属性，仅声明拓扑关系。

---

## 查询场景

### 场景一：表级血缘 — 直接上游（含过滤条件）

> 使用关系：`READS_FROM`

```cypher
// dwd_conan_user_order_da 依赖哪些物理表？读取时施加了哪些过滤条件？
MATCH (dst:M_TABLE {table_name: "dwd_conan_user_order_da"})
      -[r:READS_FROM]->(src:M_TABLE)
RETURN src.db_name + "." + src.table_name AS upstream,
       r.filters_count                     AS filters_count,
       r.filters_json                      AS filters,
       r.sql_path                          AS from_sql
ORDER BY src.table_name
```

**示例结果：**
```
upstream                                      filters_count  filters
dw_dwd.dwd_eng_device_active_da               3              [device_id IS NOT NULL, device_id <> '', ...]
dw_dwd.dwd_eng_user_device_rela_da            3              [device_id IS NOT NULL, ...]
dw_dwd.dwd_eng_order_course_detail_da         2              [order_status >= '2', ...]
dw_dwd.dwd_site_user_reg_profile_da           4              [userid <> '', userid IS NOT NULL, ...]
dw_conan_dwd.dwd_conan_growth_thirdapi_...    3              [redeem_code <> '', ...]
```

---

### 场景二：表级血缘 — 多层上游链路

> 使用关系：`READS_FROM`（可变长路径）

```cypher
// 递归查出所有层级的上游表，并返回最短依赖路径
MATCH path = (:M_TABLE {table_name: "dwd_conan_user_order_da"})
             -[:READS_FROM*1..]->(src:M_TABLE)
WITH src,
     min(length(path))  AS depth,
     collect(DISTINCT [n IN nodes(path) | coalesce(n.table_name, n.label)]) AS chains
RETURN src.db_name + "." + src.table_name AS upstream,
       depth,
       chains[0]                          AS shortest_chain
ORDER BY depth, upstream
```

---

### 场景三：影响分析 — 下游依赖我的表

> 使用关系：`READS_FROM`（反向遍历）

```cypher
// 如果 dwd_eng_device_active_da 表结构变更，哪些下游表会受影响？
MATCH path = (dst:M_TABLE)
             -[:READS_FROM*1..]->
             (:M_TABLE {table_name: "dwd_eng_device_active_da"})
WITH dst, min(length(path)) AS depth
RETURN dst.db_name + "." + dst.table_name AS downstream,
       depth
ORDER BY depth, downstream
```

---

### 场景四：CTE 中间层 — 每步直接过滤条件

> 使用关系：`REF_TEP`（边上的 `filters_json` 是该步直接过滤）

```cypher
// 查看 dwd_conan_user_order_da 解析过程中各 CTE 直接读了哪些表、施加了哪些过滤
MATCH (src)-[r:REF_TEP]->(cte:CTE)
WHERE EXISTS {
  MATCH (:M_TABLE {table_name: "dwd_conan_user_order_da"})
        -[:READS_FROM*0..]->(src)
}
RETURN labels(src)[0]                         AS src_type,
       coalesce(src.table_name, src.label)    AS src_name,
       cte.label                              AS cte_name,
       r.filters_count                        AS filters_count,
       r.filters_json                         AS filters
ORDER BY cte.label, src_name
```

**示例结果：**
```
src_type  src_name                   cte_name  filters_count  filters
M_TABLE   dwd_eng_device_active_da   a1        3              [device_id IS NOT NULL, ...]
M_TABLE   dwd_eng_device_active_da   t1        3              [device_id IS NOT NULL, ...]
M_TABLE   dwd_eng_user_device_rela_da t0       3              [device_id IS NOT NULL, ...]
CTE       t0                         b         0              []          ← CTE→CTE 通常为 0
CTE       t1                         b         0              []
```

---

### 场景五：CTE 累积过滤 — 全链路过滤条件

> 使用 CTE 节点的 `upstream_filters_json` 属性（已预计算）

```cypher
// 直接读取某个 CTE 的累积上游过滤条件，无需 traverse
MATCH (c:CTE {label: "new_device"})
RETURN c.fs_uid                  AS cte_uid,
       c.subkind                 AS cte_kind,
       c.upstream_filters_count  AS filter_count,
       c.upstream_filters_json   AS all_upstream_filters
```

**示例结果：**
```
cte_uid                        cte_kind   filter_count  all_upstream_filters
run_cfaefa6cd186::cte_a3b1...  with_cte   3             [device_id IS NOT NULL,
                                                          device_id <> '',
                                                          device_id <> '00000000-...']
```

> `fs_uid` 前缀 `cte_` 对应 `subkind = with_cte`；若为 `derived_xxx` 则 `subkind = derived_subquery`。

---

### 场景六：字段级血缘 — 某列从哪来

> 使用关系：`REF_COL_LINEAGE`

```cypher
// dwd_conan_user_order_da.device_id 的数据来源列是什么？经过了哪些转换？
MATCH (src:M_COL)
      -[r:REF_COL_LINEAGE*1..8]->
      (dst:M_COL {table_name: "dwd_conan_user_order_da", col_name: "device_id"})
RETURN src.db_name + "." + src.table_name + "." + src.col_name AS source_col,
       [rel IN r | rel.fs_edge_type]                           AS edge_types,
       [rel IN r | rel.fs_expr]                                AS expressions
ORDER BY source_col
```

---

### 场景七：字段级血缘 — 某列影响了哪些下游列

> 使用关系：`REF_COL_LINEAGE`（反向）

```cypher
// dwd_eng_device_active_da.device_id 的数据最终流向了哪些目标列？
MATCH (:M_COL {table_name: "dwd_eng_device_active_da", col_name: "device_id"})
      -[r:REF_COL_LINEAGE*1..8]->
      (dst:M_COL)
WHERE dst.table_name IS NOT NULL          // 只看物理列
RETURN DISTINCT dst.db_name + "." + dst.table_name + "." + dst.col_name AS target_col,
                [rel IN r | rel.fs_edge_type]                            AS edge_types
ORDER BY target_col
```

---

### 场景八：JOIN 关系 — 两表 JOIN 方式详情

> 使用关系：`JOINS_WITH`

```cypher
// dwd_eng_user_device_rela_da 和 dwd_eng_device_active_da 是如何 JOIN 的？
MATCH (a:M_TABLE {table_name: "dwd_eng_user_device_rela_da"})
      -[j:JOINS_WITH]-
      (b:M_TABLE {table_name: "dwd_eng_device_active_da"})
RETURN j.dominant_join_type   AS join_type,
       j.left_role            AS left_table_role,
       j.right_role           AS right_table_role,
       j.join_keys_json       AS join_keys,
       j.join_conditions      AS on_conditions,
       j.frequency            AS appeared_in_n_sqls
```

**示例结果：**
```
join_type  left_table_role  right_table_role  join_keys                              on_conditions
inner      symmetric        symmetric         [{"left":"t0.device_id",               ["t0.device_id = t1.device_id"]
                                               "right":"t1.device_id",
                                               "on_expr":"t0.device_id=t1.device_id"}]
```

---

### 场景九：JOIN 全景 — 某张表的所有 JOIN 关系

> 使用关系：`JOINS_WITH`

```cypher
// dwd_eng_device_active_da 和哪些表有 JOIN 关系？分别是什么类型？
MATCH (center:M_TABLE {table_name: "dwd_eng_device_active_da"})
      -[j:JOINS_WITH]-(other:M_TABLE)
RETURN other.db_name + "." + other.table_name AS partner_table,
       j.dominant_join_type                   AS join_type,
       j.key_count                            AS eq_key_count,
       j.has_non_equi                         AS has_range_cond,
       j.frequency                            AS sql_count
ORDER BY j.frequency DESC
```

---

### 场景十：列归属 — 某张表拥有哪些列

> 使用关系：`REF_TABLE_COL`

```cypher
// 查出 dwd_eng_device_active_da 在血缘图中被引用过的全部字段
MATCH (t:M_TABLE {table_name: "dwd_eng_device_active_da"})
      -[:REF_TABLE_COL]->(c:M_COL)
RETURN c.col_name     AS col,
       c.fs_kind      AS kind,
       c.fs_fqn       AS fqn
ORDER BY c.col_name
```

---

### 场景十一：导出作业 — 某物理表被哪些导出作业消费

> 使用节点：`ExportTarget`；关系：`READS_FROM`（下游为 `ExportTarget`，仅看已被调度元数据确认的）

```cypher
// dwd_conan_user_order_da 被哪些导出作业拉到仓外（MySQL/Kafka/文件）？
MATCH (et:ExportTarget {fs_status: "confirmed"})
      -[:READS_FROM]->(src:M_TABLE {table_name: "dwd_conan_user_order_da"})
RETURN et.scheduler         AS scheduler,
       et.task_name         AS task_name,
       et.target_type       AS target_type,
       et.target_location   AS target_location,
       et.owner             AS owner
ORDER BY et.scheduler, et.task_name
```

> 默认过滤 `fs_status = "confirmed"` 排除尚未被调度元数据确认的占位节点（ad-hoc SELECT）。

---

### 场景十二：导出作业 — 某导出作业的字段级血缘

> 使用关系：`REF_TABLE_COL` + `REF_COL_LINEAGE`

```cypher
// 导出作业 task_id="export_user_order_to_mysql" 的每个输出列各自来自哪些上游列？
MATCH (et:ExportTarget {scheduler: "airflow", task_id: "export_user_order_to_mysql"})
      -[:REF_TABLE_COL]->(out:M_COL)
OPTIONAL MATCH (src:M_COL)-[r:REF_COL_LINEAGE*1..8]->(out)
WHERE src.table_name IS NOT NULL          // 只看可定位到物理表的源列
RETURN out.col_name                                                   AS export_col,
       collect(DISTINCT src.db_name + "." + src.table_name + "." + src.col_name) AS source_cols
ORDER BY out.col_name
```

---

## 元数据补全层（节点/关系的非 `fs_` 属性）

> 上文（"节点详解 / 关系详解"）描述的是 FlowScope SQL 解析层写入的属性（统一带 `fs_` 前缀）。
> 本章节列出**所有由外部源补全到同一批节点/关系上的属性**，以及仅存在于元数据层、不参与 SQL 解析的额外节点（`Metric` / `MetricDomain`）和额外关系。
> 数据来自直接读取生产 Neo4j 实例（统计基数：`M_TABLE` 4748、`M_COL` 97397、`REF_TABLE_COL` 97398、`REF_COL_LINEAGE` 92987、`REF_COL` 8669、`REF_TABLE` 8267、`MATERIALIZED_IN` 153、`BELONGS_TO` 23、`SOURCED_FROM` 14、`GOVERNED_BY` 4、`DERIVED_FROM` 3）。

---

### 时间属性统一约定（MANDATORY）

**所有节点和所有关系都必须挂两个时间戳**：

| 标准名 | 含义 | 当前物理存储名 | 类型 | 写入语义 |
|---|---|---|---|---|
| `ctime` | 首次写入时间，**不可变** | `created_time` | ISO-8601 String（UTC，如 `2025-12-08T13:13:11.491Z`） | `ON CREATE SET n.ctime = datetime()` |
| `utime` | 最近一次修改时间，**每次 MERGE 必须刷新** | `updated_time` | ISO-8601 String | `ON CREATE / ON MATCH SET n.utime = datetime()` |

> 物理层名 `created_time` / `updated_time` 与文档标准名 `ctime` / `utime` 是同一字段的两种写法；当前查询 / 写入仍走长名以保持向后兼容，后续统一迁移期间应**双写**两种名字直至所有消费方切换完毕。

---

### M_TABLE 扩展属性

唯一键 `(db_name, table_name)` 见上文。下列字段由外部源补全到同一节点上，**均无 `fs_` 前缀**。覆盖率基于 4748 个节点统计。

| 属性 | 类型 | 覆盖率 | 来源 | 说明 |
|---|---|---|---|---|
| `ctime` / `utime` | DateTime | 100% / 100% | 元数据同步 | 见 [时间属性统一约定](#时间属性统一约定mandatory) |
| `table_id` | Integer | 99.8% | Hive Metastore | Hive 内部表 ID |
| `flag_dt` | String (date) | 99.8% | 元数据同步 | 当前快照所属分区日期，如 `2026-04-22` |
| `table_comment` | String | 99.6% | Hive Metastore | 表注释 |
| `owner` | String | **98.9%** | Hive Metastore / 平台 | **归属人**（LDAP 账号，如 `zhangyuanbj02`；团队归属用 `data_team`） |
| `id` | String (UUID) | 98.0% | 平台 | 平台业务 ID（与 `table_id` 不同维度） |
| `is_part` | Integer (0/1) | 98.0% | Hive Metastore | 是否分区表 |
| `theme_domain` | String | 97.1% | 平台标注 | 主题域：订单 / 用户 / 投放 / 学习报告 / 设备 / 续报服务 / 课程 / 学习任务 …… |
| `editor` | String | 97.1% | 平台 | 最近编辑人 LDAP（或 `system`） |
| `business_domain` | String | 95.3% | 平台标注 | 业务域：斑马AI课 / 斑马百科 / 斑马AI口语课 / 斑马硬件 …… |
| `table_embedding` | List\<Float\>(768) | 86.2% | LLM | 表名+注释的语义向量（768 维），用于向量召回 / 表搜索 |
| `partition_key` | String | 85.5% | Hive Metastore | 分区键，如 `dt` / `hour,dt` / `scene,dt` |
| `task_sql_md5` | String | 51.7% | 调度系统 | 产出该表的 SQL 文件 MD5 |
| `task_name` | String | 48.6% | 调度系统 | 产出任务名（如 `dimEngMentorInfoDa.php`） |
| `table_ai_try` | String | 48.9% | LLM | LLM 反推的"主表 / 关联表 / 过滤条件"摘要 |
| `table_ai_try_comment` | String | 48.9% | LLM | 上述摘要的进一步注释 |
| `db_type` | String | 1.9% | 平台 | 库类型，仅 Doris 库节点有值（`doris`） |
| `uuid` | String | 1.8% | Doris 平台 | Doris 平台表 UUID |
| `primary_key` | String | 1.8% | Doris DDL | 主键列表，如 `` `platform`, `accountId`, `ts` `` |

---

### M_COL 扩展属性
| 属性 | 类型 | 覆盖率 | 来源 | 说明 |
|---|---|---|---|---|
| `ctime` / `utime` | DateTime | 100% / 100% | 元数据同步 | 见统一约定 |
| `table_id` | Integer | 100% | Hive Metastore | 所属 Hive 表 ID（与 `M_TABLE.table_id` 对齐） |
| `col_type` | String | 100% | Hive / Doris DDL | 列类型，如 `int` / `bigint` / `string` / `varchar(256)` |
| `flag_dt` | String (date) | 100% | 元数据同步 | 快照分区日期 |
| `col_enum_values` | List\<String\> | 100% | LLM / 业务 | 枚举字典，格式 `["1:微信", "2:抖音", ...]`；无枚举为 `[]` |
| `id` | String (UUID) | 97.7% | 平台 | 平台业务 ID |
| `cd_id` | Integer | 97.7% | Hive Metastore | Hive `CDS` 表 ID（列定义集合 ID） |
| `col_comment` | String | 96.8% | Hive Metastore | 列注释 |
| `col_embedding` | List\<Float\>(768) | 88.0% | LLM | 列名+注释的语义向量 |
| `comment` | String | 2.3% | Doris DDL | **Doris 列注释**（与 `col_comment` 同义，仅 Doris 来源使用） |
| `db_type` | String | 2.3% | 平台 | `doris` |
| `uuid` | String | 2.3% | Doris 平台 | Doris 平台列 UUID |

> Hive 来源用 `col_comment`、Doris 来源用 `comment`，目前未做合并。查询时应 `coalesce(c.col_comment, c.comment) AS comment`。

---
