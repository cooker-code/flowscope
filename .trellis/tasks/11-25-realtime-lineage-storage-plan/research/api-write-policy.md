# 当前解析 API 标识、鉴权与拟定写入策略

2026-11-25 源码核查。FlowScope 主目录与规划工作树均为 d4e89415。本次未向生产发解析 POST、伪造 token 或执行数据库写入，也未核实外部网关鉴权。

## 1. 当前请求标识

当前入口为 `POST /api/analyze`，Rust HTTP 请求结构在 `/Users/blank/wangliang/gitcode/flowscope/crates/flowscope-cli/src/server/api.rs:51`。

| 当前字段/信息 | 来源 | 实际用途与局限 |
|---|---|---|
| sourceName / source_name | 可选请求体字符串，均被接受 | 原样交给 core，写入 audit_log.source_name；调用方自填，不校验来源身份或权限 |
| files[].name | 请求体的文件名/路径 | 文件分析、定位与按文件审计；自填，不是可信任务 ID |
| client_ip | ConnectInfo 连接地址 | 审计线索；有代理时可能是代理地址，不能据此认定调用系统或用户 |
| sql、hide_ctes、enable_column_lineage、template_mode | 请求体 | SQL 与解析选项，不决定图写权限 |
| task_id/source_id/source_version/write_mode | 当前 HTTP AnalyzeRequest 不存在 | 未来正式发布需要新增结构化上下文，不能假定现在已有 |
| Authorization/Bearer | 当前 handler/router 未读取或校验 | 应用内无解析 API token 鉴权；不等于证明网关也无鉴权 |

handler 在 api.rs:220 调用 core，随后在启用时记 SQLite 审计，api.rs:303 返回解析结果。当前未实现本 task 的 Neo4j writer，所以现状不是“解析成功即写正式图”。

## 2. 当前调用方

- Hive UDF：`/Users/blank/wangliang/gitcode/bigdata-hive-udf/src/main/java/com/yuanfudao/bigdata/udf/SqlAnalyzeUDF.java:55`。请求 body 传 sql、hide_ctes=false、enable_column_lineage=true、sourceName=taskName；空任务名默认 hive-udf。代码第 71 行只设置 Content-Type 与 Content-Length，没有 Authorization 或任务 ID/发布版本。此处仅为本地 UDF 实现证据，未回读注册 JAR。
- 网页 REST：`/Users/blank/wangliang/gitcode/flowscope/app/src/lib/backend-adapter.ts:100`。发 files[]、解析选项，未传顶层 sourceName 或 Authorization；`useAnalysis.ts:108` 把文件路径作为 files[].name。不能把未传 sourceName 的网页请求错误识别成可信系统。
- Librarian AI 服务的 Authorization/API Key 用于外部模型 API，不是 `/api/analyze` 的调用方身份机制。

## 3. 应用层鉴权范围

`/Users/blank/wangliang/gitcode/flowscope/crates/flowscope-cli/src/server/mod.rs:85` 注册路由，只有 CORS 和请求体大小等中间件，没有 token 校验。当前 ServerConfig/AppState 也无解析 API 凭据或写图策略。CORS 不承担服务间鉴权。

loopback 分支的 CORS 在 mod.rs:104 只允许 Content-Type；若新增浏览器 Authorization 请求，需要同时核对预检头。非 loopback 使用 permissive CORS；不能将其解读成“已认证来源”。本轮未改这些代码。

## 4. 最新规划：统一入口与两类图写入

用户本轮新增策略页面、调度 token 默认更新正式图和个人 token 查询使用标记，最新完整合同见 `policy-page-and-personal-usage.md`。前稿“另设发布解析入口、匿名 analyze 默认观察、每次显式 publish、策略只在重启加载”的建议已替换；第 1–3 节仍是未实现前的源码证据。

生产严格模式统一 `/api/analyze` 要求 Bearer token，服务端识别稳定主体。调度 token 的管理员策略可默认为 publish，个人 token 默认为 record_usage；均可降为 observe/parse_only，个人不可升为 publish。匿名仅在明确迁移窗口 parse_only，不写 Neo4j。缺失/无效凭据 401，越权 403。

解析后同库持久化完整事件、审计关联和策略判定才是 queued；后台复核当前 active_revision 后，分别执行正式血缘事务或个人 usage 事务。两种结果分别为 lineage_status/usage_status，均不等同于解析 success。策略页面保存经管理 API、SQLite 事务和运行时快照加载后才显示生效，不能只改本地浏览器状态。

## 5. 当前证据的限制

现有接口没有 token 校验、个人可信身份、使用标记、策略管理或本 task 的 Neo4j writer。历史 audit_log 不能凭 sourceName/IP 自动归属到个人，也不能把解析提交叫成实际查询执行。完整使用细节应来自未截断的事件载荷；实现前的历史记录只用作 SQL 回看和规则模拟。
