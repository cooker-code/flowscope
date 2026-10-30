# 调研：线上两类 SQL 的独立字段血缘验收设计与 Schema 覆盖

- 查询：以线上失败原文 SQL 为输入，独立 SQLGlot Hive AST、冻结/只读 DDL 和 FlowScope 结果图分别核对 2026-10-30 的前导下划线标识符、`ARRAY/STRUCT` 复杂类型两类修复。
- 范围：混合（本地只读原 SQL、DDL、代码与规范；不访问生产 Neo4j、不调用线上分析接口、不执行 SQL）。
- 日期：2026-10-30

## 发现

### 输入边界和回放分组

- 权威清单为 `/Users/blank/.codex/tmp/field-lineage-audit-20261029-01a1866f/cases/online-two-category-fix/non-php-manifest.json`：53 份去重后的非 PHP 原 SQL；其中 46 份 `in_scope=true`，其余 7 份保持失败清单。原始 SQL 路径和 SHA-256 都在该清单中，验收必须逐条重算 SHA-256，不能经改写 SQL 回放。
- 46 份范围由 35 份“前导下划线标识符”与 11 份“复杂类型首错”组成；`557564` 同时带有复杂类型的 secondary category，仍只计一份 SQL。7 份保留失败：`558128`、`557486`（同时代表 `557405`）、`556525`（FROM VALUES），`557826`、`557557`（exists），`557572`（CREATE VIEW COMMENT），`557728`（多个 GROUPING SETS）。
- 复杂类型 worker 的原文重放新增已确认的后续错误：`557500` 在 `ARRAY/STRUCT` 首错消除后进入 `exists(push_groups, g -> ...)`。`exists` 属于用户明确暂缓的既有保留类别，不能为使 46/46 成功而兼容它。因此该 SQL 的本类语法修复可单独证明，但端到端解析必须标为 `BLOCKED_BY_DEFERRED_EXISTS`；最终全量 53 份预期为最多 45 成功、8 保留失败（原 7 + 557500），以集成 native/WASM 实测为准。
- 今日审计窗口刷新到 `2026-10-30T02:20:49Z`（台北 10:20:49）仍为 66 个失败审计、65 份去重 SQL，无新失败；PHP 输入完全不在本次读取或验收范围内。
- 相关原始证据：`.../online-failures-20261030/分类汇总.json`（分类和 557564 secondary 错误）、`.../sql/<audit_id>.sql`（原文）、`.../details/<audit_id>.json`（线上只读审计细节）。

### 独立期望来源与覆盖能力

使用 `/Users/blank/wangliang/gitcode/neo4j-http-service/.venv/bin/python` 中的 SQLGlot `30.25.0`，调用既有的独立审计模块 `src/batch/sql_lineage_expectations.py`。该模块不读取 FlowScope 解析结果；它基于 Hive AST 的 scope tree 生成：语句编号、scope/CTE 输出、输出位置、表达式、可解析的物理字段根、未决引用、窗口 `partition`/`order` 控制依赖以及 INSERT 目标位置。

- 代码模式：`analyze_original_sql()` 在 [sql_lineage_expectations.py](/Users/blank/wangliang/gitcode/neo4j-http-service/src/batch/sql_lineage_expectations.py:788) 只解析原 SQL；`_physical_sources()` 在同文件 [line 409](/Users/blank/wangliang/gitcode/neo4j-http-service/src/batch/sql_lineage_expectations.py:409) 对 scalar subquery、无法唯一归属的列和 `*` 明确留下 unresolved，而不是伪造根字段；`_window_control_dependencies()` 在 [line 310](/Users/blank/wangliang/gitcode/neo4j-http-service/src/batch/sql_lineage_expectations.py:310) 将值输入和 `PARTITION BY`/`ORDER BY` 角色分离。
- 独立预扫描可读出全部 46 份原 SQL，得到 1,411 个顶层输出、1,283 个已解析物理根引用、2,077 个窗口控制依赖和 170 个包含 `*` 的输出。39 份存在至少一个 AST 未决值引用，4 份仅因 DDL 版本未经同版本证明而为 PARTIAL，3 份没有未决根且可作为纯 AST 值来源对照样本。
- 这说明“解析成功”不等于“所有字段血缘已证明”。未决根大多来自深层 CTE/派生 scope、`*`、scalar subquery 或不唯一的无表别名列；它们应在验收 CSV 以 `UNVERIFIABLE_AST_SCOPE` / `UNVERIFIABLE_STAR_SCHEMA` / `UNVERIFIABLE_SCALAR_SUBQUERY` 保留，不得作为零来源、常量或成功路径。

### 当前 Schema 覆盖

1. 冻结 DDL 目录 `/Users/blank/.codex/tmp/field-lineage-audit-20261029-01a1866f/ddl/` 有 2,379 份可解析 DDL（另有 13 份错误状态），用于字段名存在性和 `*` 的保守展开；它自身不是“审计时刻的版本证明”。
2. 46 份中 25 份为只读 SELECT，无物理写入目标，因此目标列位置为 `N/A`，不能要求 Neo4j 写入表节点或 `insertTargetMapping`。
3. 21 份 INSERT 现在都已具备目标 DDL。原冻结 DDL 覆盖 18 张；以下 3 张此前缺失、现已由主 session 只读点查并保存为 `.../online-two-category-fix/current-ddl/conan_sg.<table>.json`：

   | auditId | 目标表 | 输出/目标位置 | 依据 |
   | --- | --- | ---: | --- |
   | 557781 | `conan_sg.ads__finance_singapore_math_season_pushed_left_ma` | 7/7 | 当前只读 DDL |
   | 557565 | `conan_sg.ads__finance_korea_math_season_pushed_left_ma` | 7/7 | 当前只读 DDL |
   | 557134 | `conan_sg.ads__finance_korea_eng_season_pushed_left_ma` | 7/7 | 当前只读 DDL |

4. 合计 21 个 INSERT 的 503 个输出位置均可以按 DDL 顺序生成目标字段期望；这只是字段顺序和字段名的证据。对带 `dt='...'` 的静态分区，`dt` 不占 SELECT 输出位置。
5. 初始扫描后发现的 21 张**源**表 DDL 已全部由主 session 只读 MCP 点查成功，并保存在 `.../online-two-category-fix/current-ddl/<db.table>.json`；包括一个 `CREATE VIEW ... AS SELECT`，该 view 的可见字段名按 defining SELECT 输出名读取。补齐后，46 份 SQL 不再存在“引用的物理 source table 没有 DDL”的缺口。原最小名单如下，供 DDL 证据追溯（每张括号为涉及 auditId）：

   - `conan_sg.ads__finance_korea_eng_season_user_ma` (557134)、`conan_sg.ads__finance_korea_math_season_user_ma` (557565)、`conan_sg.ads__finance_singapore_math_season_user_ma` (557781)
   - `dora.ods_tidb_dora_emon_customer_dora_emon_follow_info_da`、`dw_ods.ods_dora_emon_customer_customer_da_da` (均为 556573)
   - `dw_conan_ads.ads_eng_finance_chinese_season_info_da_history_error` (557819)、`dw_conan_ads.ads_eng_finance_math_season_info_da_error` (557817)、`dw_conan_ads.ads_eng_finance_season_info_da_history_error` (557185)
   - `dw_conan_dim.dim_eng_city_level_0618`、`dw_conan_temp.bd_qudao_yingshe` (均为 556708)
   - `dw_conan_dim.dim_pub_date` (557867)、`dw_dim.dim_pub_date`、`dw_conan_temp.cgdb_daren_yingshe` (均为 557590)
   - `dw_conan_dwd.dwd_order_course_detail_try_double_try_da_no_sensitive_view` (557883)、`dw_conan_ori.bolt_logistics_shipment_da` (557091)
   - `dw_conan_temp.pedia_bd_cpa_keyfrom_mapping` (558145、558146)、`dw_conan_temp.peida_tencent_site` (558155、558156)
   - `dw_conan_temp.shangwuqudaoyurenyuanyingshe`、`temp.yxzz_sw_author_relate` (均为 556200、556731)
   - `temp.adid_darenid`、`temp.authorid_zhubo_yingshe_new` (均为 557943)

### 21 个 INSERT 的目标位置期望清单

除后三张使用 current-ddl 外，其余为冻结 DDL。每一行的“输出=映射”已经由独立 AST 以原 SQL 计算；最终隔离图回测仍须证明每个位置存在到正确目标字段的连续值路径。

| auditId | 类别 | 目标表 | 输出=映射 |
| --- | --- | --- | ---: |
| 557823 | complex | `dw_conan_dwd.dwd_eng_fin_mem_order_da` | 36=36 |
| 557819 | complex | `dw_conan_ads.ads_finance_chinese_season_pushed_left_ma` | 7=7 |
| 557817 | complex | `dw_conan_ads.ads_finance_math_season_pushed_left_ma` | 7=7 |
| 557812 | complex | `dw_conan_ads.ads_finance_music_season_pushed_left_ma` | 7=7 |
| 557811 | complex | `dw_conan_ads.ads_finance_art_season_pushed_left_ma` | 7=7 |
| 557781 | complex | `conan_sg.ads__finance_singapore_math_season_pushed_left_ma` | 7=7 |
| 557750 | underscore | `dw_conan_temp.ads_conan_growth_chin_zj_acquisition` | 22=22 |
| 557590 | underscore | `dw_conan_ads.ads_commerce_try_order_detail_wide_da_v1` | 173=173 |
| 557565 | complex | `conan_sg.ads__finance_korea_math_season_pushed_left_ma` | 7=7 |
| 557564 | underscore + complex | `dw_conan_dwd.dwd_conan_growth_thirdapi_redeem_event_state_da` | 18=18 |
| 557544 | complex | `dw_conan_ads.ads_finance_write_season_pushed_left_ma` | 7=7 |
| 557500 | complex | `dw_conan_ads.ads_finance_sci_season_pushed_left_ma` | 7=7 |
| 557497 | underscore | `dw_conan_dwd.dwd_conan_growth_thirdapi_redeem_conflict_lock_da` | 8=8 |
| 557206 | underscore | `dw_conan_dwd.dwd_conan_try_double_ds_third_order_channel_detail` | 14=14 |
| 557185 | complex | `dw_conan_ads.ads_finance_eng_season_pushed_left_ma` | 7=7 |
| 557134 | complex | `conan_sg.ads__finance_korea_eng_season_pushed_left_ma` | 7=7 |
| 556731 | underscore | `dw_conan_dwd.dwd_conan_try_double_yxzz_third_channel` | 12=12 |
| 556724 | underscore | `dw_conan_ads.ads_conan_try_model_yingyu_w0_feature_di` | 79=79 |
| 556708 | underscore | `dw_conan_ads.ads_commerce_bd_try_double_order_detail_wide_da` | 48=48 |
| 556573 | underscore | `dw_conan_dwd.dwd_pedia_weixin_add_user_info_da` | 17=17 |
| 556504 | underscore | `dw_conan_dwd.dw_live_order_zhuangku_da` | 6=6 |

### 隔离图的独立验收合同

最终接入新 `17695` 隔离 Neo4j 时，每个 auditId 必须产生一条机器可读验收记录，至少含 `audit_id`、原 SQL SHA、native/WASM、语句索引、scope、输出 position、期望物理值根、期望窗口控制 role、预期目标列、实际节点/边 ID、状态和无法证明原因。

为让正式 Core 收到真实 schema 而不依赖 CLI 的 DDL parser，生成器还为每个 auditId 导出了两种同源输入：`online-two-class-expectations/schemas/<auditId>.sql`（只拼接实际 DDL 原文）和 `schema-metadata/<auditId>.json`（生产 `SchemaMetadata` 形状）。`summary.json` 的 `schema_exports` 为每张参与表记录了 DDL JSON 路径与 DDL SHA-256。表字段名和 `dataType` 仅来自 CREATE TABLE DDL；CREATE VIEW 保留原始 DDL，SchemaMetadata 仅带其 defining SELECT 的暴露字段名、不声明类型，绝不从待验的 workload SQL 或 target/output 反推字段。

| 层次 | 通过条件 | 失败或不可证明的处理 |
| --- | --- | --- |
| 原文与解析 | 除已确认的 `557500` 后续 deferred-exists 阻断外，范围 SQL 原 SHA 不变；native 和 WASM 都无解析错误且语句数一致 | 任何其他解析错误、原文哈希变化或 native/WASM 差异阻止合并 |
| 53 SQL 回归 | 目标上限为 45 成功；8 份保留为失败（原 7 + 557500），每份错误类别仍属于清单，不计为兼容成功 | 新增成功/失败或错误类别漂移都单列，不把保留类吞掉 |
| 值血缘 | 对 AST 已证的每个 `(scope, statement, output position, physical root)`，隔离图中存在 `DataFlow` 或 `Derivation` 的连续值路径到正确输出/目标列；表达式边必须是 `Derivation` | 少边、错根、到错 position、把变换画成 `DataFlow` 均失败；AST unresolved 记录为 `UNVERIFIABLE`，不可用空根通过 |
| 窗口控制 | `PARTITION BY`、`ORDER BY` 仅作为带 `windowRole=partition/order` 的 `WindowControl` 边；同字段值输入与控制输入可并存 | 控制列混入值来源、丢失 role 或丢边均失败；scope 无法唯一归属时显式 `UNVERIFIABLE` |
| INSERT 目标 | 21 个 INSERT 的 503 个已映射位置：`insertTarget.position`（一基）和目标字段名与独立 DDL 期望一致；静态分区不占位置 | 无映射、错顺序、用 SELECT label 替代 target field 均失败 |
| 隔离图 | 只将本轮构造结果写入新 17695；以图内节点、边和目标映射 readback 对照，不以 CLI 无报错代替 | 不访问 10.13.35.4 生产图；缺 Schema 或 AST scope 证据只报告覆盖缺口 |

### FlowScope 合同和实现检查位置

- Hive 预处理入口与作用范围：`crates/flowscope-core/src/hive_preprocess.rs`，规范 [hive-compat-preprocess.md](/Users/blank/.codex/worktrees/flowscope-online-two-class-integration/flowscope/.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md:1) 明确必须在 core 的 `analyze()` 路径修复，不能在外部批脚本做专用绕过。
- 语句诊断 span 是预处理后的字节范围：`crates/flowscope-core/src/analyzer/input.rs:466` 的 `parse_statement_ranges_best_effort()`；定位原 SQL 时必须先从预处理文本按 span 切片，不能把偏移直接解释成原文坐标。
- 边类型与窗口约束：[edge-types.md](/Users/blank/.codex/worktrees/flowscope-online-two-class-integration/flowscope/.trellis/spec/flowscope-core/backend/edge-types.md:1) 规定表达式边为 `Derivation`，窗口控制是带 role 的 `WindowControl`，而非值血缘。
- INSERT 目标位置约束：[analyze-result-contract.md](/Users/blank/.codex/worktrees/flowscope-online-two-class-integration/flowscope/.trellis/spec/flowscope-core/backend/analyze-result-contract.md:1) 规定显式 INSERT 列优先、无权威 schema 时不能从 SELECT 别名猜目标顺序。

### 已补齐 Schema 后的未决引用归因（不得自动豁免）

`current-ddl/` 的 24 份 JSON 全部加载后，`missing_source_tables=[]`，所以仍留下的 3,100 条 AST 未决输出不是 Schema 缺失。它们已逐条落在 `online-two-class-expectations.csv`，主要是以下三个可实现的审计器语义缺口：

1. **高阶数组函数的 lambda 局部变量和累加器作用域**。代表是 `557185`、`557134`、`557500`、`557544`、`557811`、`557812`、`557817`、`557819`、`557565`、`557781` 的 `transform/aggregate/filter`。例如 `aggregate(periods, 0, (a,p) -> a + p.weeks)` 中 `a`、`p.weeks`，以及 `transform(classes,c -> element_at(c,2))` 中的 `c`，目前被 SQLGlot helper 误当普通列而显示为 `weeks`、`r.fee`、`level`、`goods` 等 unresolved。正确审计规则是：lambda 参数绝不能成为 Physical 根；`p.field` 应递归回 lambda 的 collection 输入 `periods` 所在投影，accumulator 应合并 initializer 和 collection 元素根。该族是**可唯一判定作用域的 AST 修复**，不是人为 SQL 错误。
2. **CTE/派生表的 `*` 与别名投影传播**。代表是营销报表 `558145`（同源的 558146–558158）、宽表 `557590`、`557894`、`557943`。例如 `op_enriched` 的 `s.*`、`op_order_flags` 的 `a.*`、`wide_scoped` / 各层 `SELECT *`，以及上层引用 `m.\`负责人\``、`d.sku_id`、`t.order_id`。现有 helper 仅能直接对物理表 `*` 按 DDL 展开，不能把 CTE alias 的 `*` 展开到其 producer 的同名/同位置投影，于是这些明确定义的 CTE 输出误留为 unresolved。正确修复是：当 alias 指向唯一 Scope 时逐列替换该 Scope 的 `selects`，遇到 UNION 按位置合并分支；保留列位置和 expression lineage，禁止把 CTE 别名当 Physical 表根。
3. **标量子查询的 relation-level 聚合**。14 次 `OUTPUT_SCALAR_SUBQUERY_UNSUPPORTED` 均出现在营销报表族的表达式中，例如 `op_fee_health` 的 `IF((SELECT COUNT(*) FROM ...)=0,1,0)`。`COUNT(*)` 是合法且没有 Physical 字段根的 table aggregate，不应标为“无来源常量”或 AST 未决。审计器应递归子查询 Scope：`COUNT(*)` 输出 relation/table aggregate 依赖，普通 scalar subquery 输出继续按其 select projection 递归；只有相关子查询绑定不唯一时才保留 `UNVERIFIABLE_SCALAR_SUBQUERY_SCOPE`。

这三类外，CSV 中仍显示的 `stat_level`、`group_key`、`valid_unknown`、`is_conversion`、`order_id` 等是上述 CTE/star/lambda producer 的投影别名，不能按字段字符串单独补 Schema 或当常量处理。下一版独立期望应先实现上述作用域规则，再重新统计可证明输出数；未实施前，当前 7,297 条 `PROVABLE` 只表示已被审计器证明的子集，不能扩大为 10,427 条全部正确。

独立 SQLGlot 官方 API 交叉验证进一步收敛了两个边界（证据：`/Users/blank/.codex/tmp/field-lineage-audit-20261029-01a1866f/cases/online-two-category-fix/oracle-crosscheck/`）：

- `557134` 与 `557185` 在 2,403 张真实 DDL 下，14 个最终落表输出都能回溯到 Physical 字段；lambda accumulator/item 没有被伪造成 Physical 根。这是对上述 lambda 作用域规则的实证，文件为 `focused-557134-557185/sqlglot-official-oracle.json`。
- 百科营销报表 `558145`–`558158` 的 SQLGlot qualify 曾报告 `dt`、`download_vendor_type`、`account_id`、`adsetid` 等无法解析（详单在 `focused-pedia-14/sqlglot-official-oracle.json`），**这不是 DDL 漂移的结论**。先前导出的 SchemaMetadata 漏掉了 Hive `PARTITIONED BY` 字段，`dt` 很可能正属于该类；CTE/derived 投影传播也可能造成同样的 qualify 报错。生成器已修正为从真实 CREATE TABLE DDL 同时导出数据列和分区列（分区列仅用于 source resolution，不占 INSERT 的 SELECT 输出 position），并保留 CREATE VIEW defining SELECT 的显式投影名。对剩余列，必须逐条以“Physical table + column + 原始 DDL JSON/片段”确认后，才能标记 `UNVERIFIABLE_SQL_DDL_DRIFT`；不能把审计器/qualify 错误交给 SQL 作者。

修正分区字段后，SQLGlot 官方 lineage API 已对全 46 份重新交叉验证（`.../oracle-crosscheck/full-46-top-level/sqlglot-official-oracle.{json,csv,summary.json}`）：25 份 SQL、449 个顶层输出有独立 Physical lineage；另有 4 个输出仅受该 API 对同名投影无法按 position 寻址的限制。其余 21 份是 SQLGlot 的 scope/CTE-star 传播能力未覆盖，不能外推为源 Schema 缺失。尤其百科 14 份已经逐条证实：`dt` 在真实物理 DDL 的分区字段中；`adsetid` 最早来自 `dw_conan_dwd.dwd_pedia_cpd_info_da.adsetid`；`account_id` 来自 ODS media-account 的 `accountid` 经 CTE CAST；`download_vendor_type` 来自 `dwd_pedia_device_active_user_label_da.download_vendor_type`。因此这四者均不构成 SQL-DDL 漂移，也不能借由当前 audit helper 的未决状态免除图路径核对。

### 已执行 native-v2 对照与阻断缺陷

正式 native 结果位于 `.../online-two-category-fix/replay-native-v2/`，运行时清单为 `integrated-runtime-v2.json`。通用独立对照脚本 `compare_native_expectations.py` 已实际运行，结果为 `native-v2-independent-comparison.json`：对现有 AST 已证明的 443 个 Physical-root→目标字段值路径全部匹配；496 个可解析 INSERT 目标位置映射全部匹配；`557500` 是唯一正式 parse error（已知 deferred `exists`）。这两个数字不能覆盖 AST scope 未决输出。

针对官方 oracle 已可证明的复杂类型样本，又做了 target-column ancestor 对照，发现并已报告阻断性字段血缘缺陷：

- `557185`：目标位置 1 `user_id` 正确；位置 2–7（`goods_type`、`stage_level`、`sale_method`、`weekcount`、`fee`、`confirm_type`）在 native 图里都只有目标字段自身、没有任何源 Physical 祖先。官方 oracle 要求这六个目标均至少来自 `dw_conan_ads.ads_finance_eng_user_season_ma` 的 `cur_get_weekcount`、`cur_left_weekcount`、`cur_refund_weekcount`、`cur_total_weekcount`、`first_level`、`last_left_weekcount`、`last_total_weekcount`、`level_weeks`、`order_list`、`receipt_list`、`settled_fee`、`settled_weekcount`。
- `557134`：位置 1 `user_id` 正确；位置 2 `goods_type`、3 `level`、4 `sale_method` 分别缺 `class_log`、`cur_get_weekcount`、`cur_left_weekcount`、`cur_refund_weekcount`、`cur_total_weekcount`、`last_left_weekcount`、`last_total_weekcount`、`period_log`、`settled_fee`、`settled_weekcount`；位置 5 `weekcount` 缺 `last_total_weekcount`、`settled_fee`；位置 6 `fee` 缺 `last_total_weekcount`；位置 7 `type` 匹配。

这与 native `557185.json` 的 15 个 `UNKNOWN_COLUMN` warning（`found`、`remaining`、`idx`、`capacity`、`done` 等 lambda/STRUCT 局部名被错误绑定为源表字段）相符。结论是复杂类型已经通过语法入口，但 lambda/STRUCT 作用域仍造成真实字段血缘丢失；在该缺陷修复并重放前不得合并或宣称 45 份端到端字段正确。

### native-v3 正式重放的独立结果（2026-10-30）

正式 v3 全量回放已在 `.../online-two-category-fix/replay-native-v3/summary.json` 完成，结果确为 53 条原 SQL 中 45 条 `hasErrors=false`、8 条 `hasErrors=true`。8 条失败保持在用户暂缓范围：3 条 `FROM VALUES`、2 条既有 `exists`、1 条 `CREATE VIEW COMMENT`、1 条多个 `GROUPING SETS`，以及 `557500` 复杂类型入口修通后暴露的 `exists(push_groups, ...)`；没有把该第八条错报为本轮复杂类型已经端到端兼容。

独立 comparison 实际读取 v3 JSON，而非从 FlowScope 结果生成期望：

- `native-v3-independent-comparison.json`：496 个 INSERT 目标列位置/名称映射全部匹配，已有 AST 明确 Physical 值根的 443 条根路径全部匹配。
- `native-v3-oracle-focused-comparison.json`：官方 SQLGlot 独立 oracle 可完整证明的 `557134`、`557185` 共 14 个落表输出仅 8 条匹配、6 条不匹配。`557134` 的 7 条与 `557185.user_id` 匹配；`557185` 的位置 2–7（`goods_type`、`stage_level`、`sale_method`、`weekcount`、`fee`、`confirm_type`）各缺且只缺同一个真实 Physical 根：`dw_conan_ads.ads_finance_eng_user_season_ma.last_total_weekcount`，没有额外根。

因此 v3 已消除 v2 的“所有 complex expression 源根丢失”问题，但仍未达到“复杂类型字段血缘全部正确”的合并门槛。应在补齐 `last_total_weekcount` 的 STRUCT/lambda 聚合传播后，用同一份原 SQL、同一真实 SchemaMetadata 和同一独立 oracle 再重放；不能以解析成功、496 个 target map 匹配或 443 个部分根匹配替代这 6 个确证缺根。

`native-v3-oracle-full-comparison.json` 也保留了对 full-46 官方 oracle 的尝试性输出，但**不得把其中 351 项 MISMATCH 直接报成字段血缘错误**：该官方 oracle 覆盖了许多没有 INSERT/CREATE TABLE 真实落表 target 的 SELECT 顶层输出，而本次比较器按 `insertTarget` 终点检索实际图节点。对于例如 `557988`、`557924` 的 SELECT，实际终点为空只是“当前 native JSON 没有可按 position 锚定的 Physical target”，属于 `UNVERIFIABLE_NO_PHYSICAL_TARGET`，不是 source root 被证实丢失。只有与明确的 output/target endpoint 绑定的 focused 比较可作严格 exact-set 门禁；其余输出需在隔离 Neo4j 保留 scope/output 节点定位后，按同一期望重新核对。

### `557943` 的 HAVING alias 与值来源（2026-10-30）

`557943.sql:649` 定义 `chaifen_before.authorid = COALESCE(toto.authorid, hour_cost.darenid)`；`717` 的 `HAVING authorid IS NOT NULL` 引用的是这个同名投影 alias。原 SQL 同时使用 FULL OUTER JOIN，强行把 HAVING 的 `authorid` 改写或绑定为 `toto.authorid` 会删除 `hour_cost.darenid` 分支，改变业务语义，不能作为解析修复。

v3 JSON 的该值节点 `column_9a9aef56c5c0baf3` 有来自 `toto.authorid`、`hour_cost.darenid` 的两条 `Derivation` 入边；沿普通 value edge 反向可达两个 Physical 根：`dw_conan_dwd.dwd_conan_growth_thirdapi_third_vendor_order_detail_da.json_extra` 和 `temp.adid_darenid.darenid`。因此这个 **投影字段的值来源** 已独立完整；HAVING 属于行过滤/statementFilters 表示问题，必须与 value-lineage 验收分离。该 SQL 没有物理落表 target，不能据它的顶层 `Output` 空终点反推 value 缺失。

相反，`557924` 的 `temp.author_id_name_dianshang` 当前以真实 MCP GetDDL 返回 `TableNotFound`，仍是 `UNVERIFIABLE_SOURCE_SCHEMA`；既不造 schema，也不将该 SQL 声称为“所有 source field 已完整验证”。

### native-v4 对复杂类型根缺失的回归验收（2026-10-30）

v4 使用原始 SQL 与 v3 相同的真实 SchemaMetadata 重放后，已实际运行独立 strict exact-set 对照 `native-v4-oracle-focused-comparison.json`：`557134` 和 `557185` 的 14 个明确落表输出为 **14 MATCH / 0 MISMATCH**。此前 `557185` 位置 2–7 统一漏掉的 `dw_conan_ads.ads_finance_eng_user_season_ma.last_total_weekcount`，现已到达每一个输出；每个输出严格是 oracle 的 12 个 Physical roots，且没有 extra/pseudo Physical root。

同次通用独立对照 `native-v4-independent-comparison.json` 保持：496 个 INSERT 目标 position/name 映射全部匹配，443 条已经由本地 AST 审计器明确的 Physical-value-root 路径全部匹配。该结果解除 v3 针对复杂类型的确定性阻断；它不扩大为无真实 target 的 SELECT 顶层输出已完整验证，也不解除 `557924` 的真实 source Schema 缺口。隔离 Neo4j 的入图/readback 仍是合并前独立必经层。

### 用户决策：缺表 SQL 只做解析、明确报错（2026-10-30）

用户已明确决定：对 `557924` 这类真实 source table 缺失（`temp.author_id_name_dianshang` 的 GetDDL 为 `TableNotFound`）的 SQL，**不再继续迁移/补结构/外部 Schema 点查**。解析器应使用 `SchemaMetadata.allowImplied=false`：遇到未解析 source table 产生明确 error；不伪造表、字段或 Physical 血缘，也不将其挂为无限期 `unknown` 阻塞流程。此后停止该 SQL 的外部 Schema 采集。

最终全量回放的验收基线因此从 v4 的“45 成功 + 8 条暂缓错误”调整为 **44 条成功 + 9 条明确错误**：此前 8 条保持原类别，新增 `557924` 的 `source schema/table missing` 明确错误。后续 V5（加入 typed numeric literal 与 strict schema 策略）只对其余 44 条做独立 value lineage、WindowControl role 与 INSERT target-position 验收；`557924` 的通过条件仅是原 SQL 未改、错误类别明确、没有暗示 schema 或伪造 Physical 节点/边。

### V5 最终原 SQL 回放与独立验收（2026-10-30）

V5 使用最终 Core 版本重放全部 53 条原 SQL，结果为 **44 条 `hasErrors=false` / returncode 0，9 条 `hasErrors=true` / returncode 1**。9 条错误均符合冻结范围：3 条 `FROM VALUES`、3 条 `exists`（包括复杂类型入口通过后暴露 `exists(push_groups, ...)` 的 `557500`）、1 条多个 `GROUPING SETS`、1 条 `CREATE VIEW COMMENT`，以及 `557924` 的严格 Schema 错误 `UNKNOWN_TABLE: temp.author_id_name_dianshang is absent from the strict imported schema metadata`。这证明缺表 SQL 已明确报错而非伪造 source Schema 或被留作无限 unknown。

V5 的独立结果如下，期望输入仍只来自原 SQL 和真实 DDL/官方 oracle，未从 V5 结果反推：

- `native-v5-oracle-focused-comparison.json`：`557134` 与 `557185` 的 14 个完整可证明落表输出为 **14 MATCH / 0 MISMATCH**。`557185` 的位置 2–7 每项都严格包含 oracle 的 12 个 Physical roots（包括此前缺失的 `last_total_weekcount`），没有 extra/pseudo root。
- `native-v5-independent-comparison.json`：496 个 INSERT target position/name 映射为 **496 MATCH**；本地 AST 已可唯一证明的 443 条 Physical value-root 到输出路径为 **443 MATCH**。
- `557185.json` 身份级扫描：`u.level`、`u.sale`、`0.00005D` 均为 0 个 node `label`、`qualifiedName` 或 canonical identity 命中。`u.level`/`u.sale` 仅在原 `transform/filter` 表达式文本中出现，属于 lambda 成员访问，未作为 Physical/Column source；`0.00005D` 不出现在节点或边身份中。
- 44 条成功 SQL 合计存在 359 条 `WindowControl`：199 条 `metadata.windowRole=partition`、160 条 `metadata.windowRole=order`。值血缘独立对照只接受 `data_flow`/`derivation`，因此控制边未混入 443 条 value-root 通过数。

覆盖边界必须保留：独立 AST 对深 CTE、CTE-star 和部分 scalar-subquery 的 scope 传播仍有明确未决，不能把 443 条已证明 value-root 或 359 条存在的窗口控制边扩大声称为全部 scope 输出已经 exact-set 证明。独立 AST 中窗口输出的可唯一证明子集仍是 30 条；隔离 Neo4j 需要对这一子集按 scope/output 节点和 `windowRole` 做 readback，且所有无真实 Physical target 的 SELECT 顶层输出继续标为不可按 target-position 精确核验。

### V6 最终版本复验（2026-10-30）

V6 是产品 duplicate-alias 明确 error 与最终 typed numeric/strict schema 策略合入后的正式版本。本次重新运行所有独立对照，结果与 V5 的正确结论一致并以 V6 为最终证据：全 53 SQL 为 **44 成功、9 明确错误**；`557924` 仍为预期的 `UNKNOWN_TABLE`；focused complex oracle 为 **14 MATCH / 0 MISMATCH**；INSERT target position/name 为 **496 MATCH**；独立 AST 已证明的 value-root 为 **443 MATCH**。

另外新增对 window control 的物理来源三元组比对：从原 SQL/DDL 独立期望中提取 `(auditId, role, Physical source)`，仅保留 role 为 `partition`/`order`、source 明确且无 unresolved reason 的三元组。V6 逐条从 `WindowControl` 边 source 端沿普通 value edge 回溯 Physical ancestor 后对照，得到 **183/183 MATCH，0 missing**（`partition` 94、`order` 89）。该结论只证明控制边的 Physical source 与 `windowRole` 在同一 auditId 内存在并匹配；**它不包含 output endpoint、scope identity 或窗口输出 position 的映射，不能称为 183 个字段/输出的精确证明**。值边仍由独立的 443 条 value-root 对照负责，二者不混合。

此前“30 个窗口 proof”的说法已核实并修正：30 是先前独立 AST 中 window scope 未决/不可唯一证明项的数量，不是已证明 window control 的专用 30 条清单；当前 research 与 evidence 目录没有单独的“30 条 proof manifest”。因此不再将 30 表述为 proof 数量。本条记录的 183/183 是可复现的 Physical control-source 三元组对照，其范围如上，不扩大到 output/field exact proof。

### 外部参考

- Spark SQL 3.5.7 regular identifier 允许由字母、数字和下划线构成；本轮 `_rp`、`__semantic_tuomin_0` 等前导下划线标识符属于应兼容的有效 Spark SQL：[Identifiers](https://spark.apache.org/docs/3.5.7/sql-ref-identifier.html)。
- Spark SQL 3.5.7 将 `ARRAY`、`STRUCT` 作为内建复杂数据类型；`CAST(... AS ARRAY<STRUCT<...>>)` 属于应兼容的类型表达式：[Data Types](https://spark.apache.org/docs/3.5.7/sql-ref-datatypes.html)。

## 注意事项 / 未找到

- 本调研没有运行待集成二进制、WASM 或新 17695 图写入，因此不宣称本轮修复已通过；本文给出的是独立期望、Schema 边界和阻止误报的验收合同。
- 冻结 DDL 在审计后采集时，除主 session 已验证的 current-ddl 外不能单独证明审计时刻的 schema version；最终结果应保留 DDL 文件、`lastDdlTime`、读取时间和 SQL SHA。
- 独立 SQLGlot 对部分 Spark named struct/lambda 写法会给兼容警告，并在深 scope 处留下 unresolved；这正是验收必须同时保留 AST 覆盖状态与隔离图 readback 的原因，而不是 FlowScope 可以照抄 SQLGlot AST。
- 未找到可用于 21 张源表全部字段存在性的 DDL，因此这 21 张表的未限定列和 `*` 不可标为完全物理根验证；应只读补齐上述最小名单后再汇总覆盖率。
- 已补齐上述 21 张源 DDL 后，研究目录中的 `generate_online_expectations.py` 已实际生成独立期望：46/46 原 SQL SHA-256 不变、2,403 张表/视图 schema 可用、无缺失 source table DDL。扁平化 10,427 条输出记录中，top-level 为 720 条 `PROVABLE`、690 条 `UNVERIFIABLE_AST_SCOPE`、1 条 `UNVERIFIABLE_WINDOW_CONTROL`；scope 输出为 6,577 条 `PROVABLE`、2,410 条 `UNVERIFIABLE_AST_SCOPE`、29 条 `UNVERIFIABLE_WINDOW_CONTROL`。这些不确定性现在是明确的 SQL AST scope / scalar-subquery / 星号传播边界，不再泛称为 Schema 未知。
