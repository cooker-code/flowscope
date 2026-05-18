# Neo4j 图模型总览（FlowScope 血缘图）

> 本文描述 FlowScope SQL 解析结果在 Neo4j 中的存储模型。
> 代码实现位于 `neo4j_proc/`，数据由 `neo4j_proc/parse_and_sink.py` 写入。

---

## 总体设计原则

| 原则 | 做法 |
|---|---|
| **物理表是锚点** | `READS_FROM` / `JOINS_WITH` 只在 `M_TABLE` 间建边，查血缘无需绕 CTE |
| **CTE 保留细节** | `REF_COL_LINEAGE` 完整保留 CTE 链路，字段溯源时可追到每一步转换 |
| **过滤条件贴近读取** | `filters_json` 直接写在 `READS_FROM` 边属性上，不建独立 Filter 节点，避免热点 |
| **幂等写入** | 全部使用 `MERGE`，重复运行不产生脏数据 |
| **FlowScope 属性隔离** | 新增属性统一加 `flowscope_` 前缀，不覆盖已有 Neo4j 元数据字段 |

---

## 节点（3 种）

```
M_TABLE   — 物理表 / 视图
M_COL     — 列（物理列 + 派生列两种形态）
Cte       — CTE / 内联子查询（中间计算层）
```

### M_TABLE

**唯一键**：`(db_name, table_name)`

语义：SQL 中出现的任意一张物理表或视图。只要被任何 SQL 引用过就会创建，不依赖外部元数据。

| 属性 | 类型 | 说明 |
|---|---|---|
| `db_name` | String | 数据库名，如 `dw_dwd` |
| `table_name` | String | 表名，如 `dwd_eng_device_active_da` |
| `flowscope_kind` | String | `table` 或 `view` |
| `flowscope_canonical_fqn` | String | 完整限定名，如 `dw_dwd.dwd_eng_device_active_da` |
| `flowscope_resolution_source` | String | FlowScope 解析来源标识 |
| `flowscope_sql_path` | String | 最近一次出现的 SQL 文件路径 |
| `flowscope_sql_md5` | String | 最近一次 SQL 内容的 MD5（run_id 前缀） |
| `flowscope_observed_sql_count` | Integer | 被多少个 SQL 引用过（跨文件累加） |
| `flowscope_first_seen_at` | DateTime | 首次写入时间 |
| `flowscope_last_seen_at` | DateTime | 最近一次更新时间 |

---

### M_COL

**唯一键**（双约束）：
- 物理列：`(db_name, table_name, col_name)`
- 派生列：`flowscope_uid`（无完整归属信息时使用）

语义：列节点分两种形态：
- **物理列**（`physical_column`）：能明确定位到具体表的列，有完整三元组
- **派生列**（`projected_column` / `derived_column` / `aggregated_column`）：中间计算列，无法归属到物理表

| 属性 | 类型 | 说明 |
|---|---|---|
| `db_name` | String | 数据库名（物理列有，派生列可能为空） |
| `table_name` | String | 所属表名（物理列有，派生列可能为空） |
| `col_name` | String | 列名 |
| `flowscope_uid` | String | 全局唯一标识：`run_id::node_id` |
| `flowscope_kind` | String | `physical_column` / `projected_column` / `derived_column` / `aggregated_column` |
| `flowscope_canonical_fqn` | String | 完整限定名，如 `dw_dwd.dwd_eng_device_active_da.device_id` |
| `flowscope_expression` | String | 计算表达式（派生列有），如 `CAST(city_type AS STRING)` |
| `flowscope_agg_function` | String | 聚合函数，如 `COUNT`、`SUM`（聚合列有） |
| `flowscope_agg_is_group_key` | Boolean | 是否为 GROUP BY 键 |
| `flowscope_agg_distinct` | Boolean | 是否 DISTINCT 聚合 |
| `flowscope_resolution_source` | String | FlowScope 解析来源标识 |
| `flowscope_first_seen_at` | DateTime | 首次写入时间 |
| `flowscope_last_seen_at` | DateTime | 最近一次更新时间 |

---

### Cte

**唯一键**：`flowscope_uid`（= `run_id::node_id`）

语义：SQL 中的 CTE（`WITH` 子句）或内联子查询。作为字段级血缘的中间节点，不参与表级血缘（`READS_FROM`）。

| 属性 | 类型 | 说明 |
|---|---|---|
| `flowscope_uid` | String | 全局唯一标识：`run_id::node_id` |
| `label` | String | CTE 别名，如 `a1`、`new_device` |
| `subkind` | String | `with_cte`（WITH 子句定义）或 `derived_subquery`（内联子查询） |
| `run_id` | String | 来源 SQL 的 run_id |
| `flowscope_node_id` | String | FlowScope 内部节点 ID |
| `body_span_start` | Integer | SQL 文本中 CTE 体的起始字符偏移 |
| `body_span_end` | Integer | SQL 文本中 CTE 体的结束字符偏移 |
| `declaration_span_start` | Integer | CTE 名称声明处的起始偏移 |
| `declaration_span_end` | Integer | CTE 名称声明处的结束偏移 |
| `occurrence_count` | Integer | 同名 CTE 在 SQL 中被引用的次数 |
| `first_seen_at` | DateTime | 写入时间 |

---

## 关系（4 种）

```
(M_TABLE/Cte) ──[REF_TABLE_COL]──> (M_COL)           列归属
(任意节点)    ──[REF_COL_LINEAGE]─> (任意节点)         字段级血缘
(M_TABLE)     ──[READS_FROM]──────> (M_TABLE)          表级血缘（穿透 CTE）
(M_TABLE)     ──[JOINS_WITH]──────> (M_TABLE)          JOIN 关系
```

---

### REF_TABLE_COL（列归属）

- **方向**：`(M_TABLE 或 Cte) → (M_COL)`
- **语义**：声明哪张表或 CTE 拥有这个列
- **MERGE 键**：`(src_node, dst_node)` 自然唯一

| 属性 | 类型 | 说明 |
|---|---|---|
| `first_seen_at` | DateTime | 首次写入时间 |
| `updated_time` | DateTime | 最近更新时间 |

---

### REF_COL_LINEAGE（字段级血缘）

- **方向**：`(上游节点) → (下游节点)`
- **语义**：某列的数据从哪个列流入，完整保留 CTE 中间链路。`data_flow` 为纯透传，`derivation` 表示有计算转换
- **MERGE 键**：`(src, dst, sql_md5, flowscope_edge_type)`
- **节点类型分布**：M_COL→M_COL（主体）、M_TABLE→Cte、Cte→Cte、Cte→M_TABLE 等

| 属性 | 类型 | 说明 |
|---|---|---|
| `flowscope_edge_type` | String | `data_flow`（纯透传）或 `derivation`（有计算） |
| `flowscope_expression` | String | 转换表达式，如 `CAST(city_type AS STRING)`（`derivation` 时有值） |
| `flowscope_join_type` | String | 该字段流经的 JOIN 类型，如 `left`、`inner` |
| `flowscope_join_condition` | String | JOIN ON 条件 |
| `operation` | String | 操作类型补充标识 |
| `sql_md5` | String | 来源 SQL 内容 MD5 |
| `first_seen_at` | DateTime | 首次写入时间 |
| `updated_time` | DateTime | 最近更新时间 |

---

### READS_FROM（表级血缘）

- **方向**：`(下游 M_TABLE) → (上游 M_TABLE)`
- **语义**：下游表的计算依赖了上游表。**CTE 链路被完全穿透**，只在物理表之间建边。是血缘统计、影响分析的主力关系
- **MERGE 键**：`(dst_table, src_table, sql_md5)`，同一张 SQL 读取同一对表只产生一条边

| 属性 | 类型 | 说明 |
|---|---|---|
| `filters_json` | String（JSON） | 读取上游表时施加的业务过滤条件列表，格式：`[{"expression": "...", "clause_type": "WHERE"}]`，分区字段自动排除 |
| `filter_count` | Integer | 过滤条件数量（去重后） |
| `sql_md5` | String | 来源 SQL 内容 MD5 |
| `sql_path` | String | 来源 SQL 文件路径 |
| `first_seen_at` | DateTime | 首次写入时间 |
| `updated_time` | DateTime | 最近更新时间 |

> **分区字段排除规则**：`dt`、`ds`、`p_date`、`partition_date`、`stat_date`、`log_date`、`etl_date`、`biz_date` 等字段的过滤条件被识别为分区裁剪，不写入 `filters_json`，避免产生无业务意义的热点。

---

### JOINS_WITH（JOIN 关系）

- **方向**：`(左表 M_TABLE) → (右表 M_TABLE)`
- **语义**：两张物理表之间发生了 JOIN。跨 SQL 累计，同一对表多次 JOIN 会累加 `frequency`
- **MERGE 键**：`(left_table, right_table)`，不区分 SQL

| 属性 | 类型 | 说明 |
|---|---|---|
| `dominant_join_type` | String | 主要 JOIN 类型：`inner` / `left` / `left_outer` / `right` / `full` / `cross` 等 |
| `join_type_history` | List[String] | 历史出现过的所有 JOIN 类型（跨 SQL 累计） |
| `left_role` | String | 左表角色：`preserved`（保留所有行）/ `null_supplying`（补 NULL）/ `symmetric`（等价）/ `cartesian` |
| `right_role` | String | 右表角色（同上） |
| `join_keys_json` | String（JSON） | JOIN Key 列表，格式：`[{"left": "t0.id", "right": "t1.id", "on_expr": "t0.id = t1.id"}]` |
| `join_conditions` | List[String] | 原始 ON 条件字符串列表 |
| `key_count` | Integer | 等值 JOIN Key 数量 |
| `has_non_equi` | Boolean | 是否包含非等值条件（`<`、`>`、`!=`、`<>`） |
| `has_time_join` | Boolean | 是否包含时间范围 JOIN（`DATE_ADD`、`BETWEEN`、`INTERVAL` 等） |
| `has_join_dependency` | Boolean | 是否有 FlowScope join_dependency 类型边（仅参与过滤、不贡献列的表） |
| `frequency` | Integer | 被多少个 SQL 引用（跨文件累加） |
| `sql_md5_list` | List[String] | 涉及该 JOIN 的所有 SQL MD5 |
| `first_seen_at` | DateTime | 首次写入时间 |
| `last_seen_at` | DateTime | 最近一次出现时间 |

---

## 典型查询示例

### 查某张表的直接上游表（含过滤条件）

```cypher
MATCH (dst:M_TABLE {table_name: "dwd_conan_user_order_da"})-[r:READS_FROM]->(src:M_TABLE)
RETURN src.db_name + "." + src.table_name AS upstream,
       r.filter_count                      AS filter_count,
       r.filters_json                      AS filters,
       r.sql_path                          AS from_sql
ORDER BY src.table_name
```

### 查多层上游血缘链路

```cypher
MATCH path = (:M_TABLE {table_name: "dwd_conan_user_order_da"})
             -[:READS_FROM*1..]->(src:M_TABLE)
WITH src, min(length(path)) AS depth,
     collect(DISTINCT [n IN nodes(path) | coalesce(n.table_name, n.label)]) AS chains
RETURN src.db_name + "." + src.table_name AS upstream,
       depth,
       chains[0]                          AS shortest_chain
ORDER BY depth, upstream
```

### 查某张表的下游依赖（影响分析）

```cypher
MATCH path = (src:M_TABLE)-[:READS_FROM*1..]->(:M_TABLE {table_name: "dwd_eng_device_active_da"})
WITH src, min(length(path)) AS depth
RETURN src.db_name + "." + src.table_name AS downstream, depth
ORDER BY depth, downstream
```

### 查字段级血缘（某列从哪里来）

```cypher
MATCH (src:M_COL)-[:REF_COL_LINEAGE*1..6]->(dst:M_COL {table_name: "dwd_conan_user_order_da", col_name: "device_id"})
RETURN src.db_name + "." + src.table_name + "." + src.col_name AS source_col,
       dst.col_name                                             AS target_col
```

### 查两张表的 JOIN 方式

```cypher
MATCH (a:M_TABLE {table_name: "dwd_eng_user_device_rela_da"})-[j:JOINS_WITH]-(b:M_TABLE {table_name: "dwd_eng_device_active_da"})
RETURN j.dominant_join_type AS join_type,
       j.join_keys_json      AS join_keys,
       j.join_conditions     AS conditions,
       j.frequency           AS frequency
```

---

## 数据写入流程

```
SQL 文件
  │
  ▼
preprocess_sql()       — 去掉 SET/ADD 指令，替换 Hive 变量 ${var}
  │
  ▼
FlowScope /api/analyze — 解析 SQL，返回 AnalyzeResult JSON（nodes + edges）
  │
  ├── Pass 1: 实体写入
  │     merge_table()  → M_TABLE
  │     merge_cte()    → Cte
  │     merge_col()    → M_COL
  │
  ├── Pass 2: 基础关系
  │     write_ownership()   → REF_TABLE_COL
  │     write_lineage()     → REF_COL_LINEAGE
  │     write_reads_from()  → READS_FROM（穿透 CTE，只建 M_TABLE→M_TABLE）
  │
  └── Pass 3: 聚合关系
        extract_join_pairs() + write_joins_with() → JOINS_WITH
        detect_and_write_unions()                 → UnionGroup（如有 UNION）
```

---

## 边界说明

FlowScope 只负责 **SQL 解析**，不存储表的元数据（字段类型、注释、分区信息等）。
元数据需通过独立的元数据补全流程写入相同的 `M_TABLE` / `M_COL` 节点（非 `flowscope_` 前缀属性）。

| 来源 | 属性前缀 | 示例 |
|---|---|---|
| FlowScope SQL 解析 | `flowscope_` | `flowscope_kind`、`flowscope_expression` |
| 外部元数据补全 | 无前缀 | `col_type`、`is_union_sql`、`task_sql_md5` |
