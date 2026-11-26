# Bug Analysis: WITH 审计映射与筛选性能

## 1. Root Cause Category

- B，跨层契约：StatementMeta.statement_type 的 WITH 描述语法结构，而 AnalyzeResult.sql_type 的 select 描述实际读写行为。旧审计映射取前者，导致页面显示 —。
- D，测试覆盖缺口：普通小数据列表能通过，类型过滤在大量大字段审计行上还需要对匹配行排序，真实性能问题没有被小样本发现。
- E，隐含假设：历史解析会长期保留，且每次按状态筛选逐行查询事件也足够快；线上 65 万条数据推翻了该假设。

## 2. Why Fixes Failed

- 原有类型映射修复已在本地基线中，但线上记录仍是 WITH。修复写入逻辑不会自动改写旧行，需要保留范围内的后台校正和实际部署。
- 单列 sql_type 索引能找到匹配类型，却不能同时提供 ts 倒序，查询计划仍出现临时排序。
- 首次界面脚本未关闭欢迎弹窗，页面其余控件被隐藏于可访问树；按实际 Get Started 流程处理后交互通过。这是验证脚本定位问题，未通过修改产品代码绕过。
- EXPLAIN 测试最初沿用创建新索引前的连接，读取缓存的旧 schema。改为与实际请求一致的新连接后，验证到复合索引并无临时排序。

## 3. Prevention Mechanisms

| Priority | Mechanism | Specific Action | Status |
| --- | --- | --- | --- |
| P0 | 契约回归 | 真实 652177 SQL 经解析、审计映射和 HTTP 保存验证 SELECT | 已验证 |
| P0 | 边界保护 | 清理仅作用 audit_log，保留 queued 审计及持久事件，覆盖截止时间边界 | 已验证 |
| P0 | 服务维护隔离 | 监听后分批清理、校正与建索引，写锁退让且可停止 | 已验证 |
| P1 | 性能证据 | 保留同一大数据样本的旧/新 HTTP 结果和耗时，区分查询优化与删除效果 | 已验证，见 verification.md |
| P1 | 页面状态 | 服务端生效值、草稿独立、错误不冒充成功，桌面与窄屏验证 | 已验证 |

## 4. Systematic Expansion

- 同一 workload 分类用于普通分析及导出审计，保留基线共享映射，不在页面独立猜测。
- 列表状态装饰改为一次关联查询，并进入与筛选、计数、分页相同的读事务。缺失事件显示 unknown，与 unknown 筛选一致。
- 事件正文承担恢复和幂等语义，不能因为解析历史可删就连同事件删除。
- 性能报告注明本机、合成数据、构建类型与 HTTP 测量方式，不把本地耗时冒充线上结果。

## 5. Knowledge Capture

- 已新增 backend/audit-retention.md，记录 API、数据库、维护、错误和测试契约。
- 已更新 audit-api-spec.md 及后端规范索引。
- 已更新用户指南和 CHANGELOG。
- 仓库没有 src/templates/markdown/spec 模板目录，因此没有模板同步对象。
