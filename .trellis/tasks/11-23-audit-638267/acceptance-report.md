# 审计 638267 原 SQL 回测

使用本工作树编译的 flowscope-core，通过 analyze 入口按 Hive 方言分析审计 SQL 原文。对照 SQL 只将 season_user_from AS from 中的别名加上反引号。两次均未传入表结构。

- 原 SQL 得到 1 条语句、0 个错误、7 条反引号规范提示、196 条未解析引用提示。
- 对照版本得到相同的 898 个节点和 1903 条边。比较全部边和节点属性，忽略指向两份不同 SQL 文本的位置后完全相同。
- op_order_index.versions 恰有 6 条取值转换边，全部来自 op_source。沿取值边递归追溯，每条路径的终点均属于 dw_conan_ads.ads_pedia_device_convert_cost_da。逐项对照原文的 op_source 投影如下。

| op_source 字段 | 物理来源字段 |
| --- | --- |
| net_gmv | season_pay_amt、season_refund_amt |
| pay_gmv | season_pay_amt |
| season_user_from | season_user_from |
| duration | season_course_type、season_course_duration |
| season_pay_dt | season_pay_dt |
| season_pay_tp | season_pay_tp |

专用别名回归 4 项通过。核心库全量测试 2710 项通过、14 项忽略、36 项快照失败。在未修改的 d65cf170 基线独立运行 golden 和 snapshots，两套测试的失败用例名称与本次 36 项逐一相同。cargo fmt 与核心库 Clippy 检查通过。

## 审计页 Warn 筛选

本地独立 SQLite 库通过 HTTP 接口写入 638267 原 SQL 两次、普通 SELECT 一次、语法错误一次。浏览器切换状态，Any 共 4 条，Warn 为 2 条记录、1 份按原文去重 SQL，Success 和 Failed 各 1 条。Warn 行显示黄色提示，刷新后保留筛选和计数。文件批量请求的专项测试确认，只有自身命中别名警告的文件进入 Warn。7 项存储测试及 15 项审计接口测试通过，前端类型检查和构建通过。临时服务、浏览器、配置目录和数据库已清理。
