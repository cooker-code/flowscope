# 审计 633467 的 Hive 同名位置列兼容复核

## 目标与验收

允许同一 SELECT 中的两个 posexplode 各声明 index_1，按 tmp.index_1 与 tmp1.index_1 区分来源。真正的未限定歧义仍须报错。原 SQL 应返回零错误，两个展开数组各自保留正确的物理字段来源。

## 复核结果

- 审计记录的方言为 Hive。服务端使用启动配置的方言分析 SQL。分析器的默认 catalog 为空，作业的执行 catalog 无法由该审计确定。
- 从审计 API 读取的 SQL 与 fixtures/hive_lateral_view_audit_559417.sql 逐字节相同。master 已包含 be9d0dc4 的限定引用修复，本次重跑已有本地专项测试产物，15 项通过，含原文和字段血缘断言。
- 2026-11-23 使用原 SQL、开启字段血缘，重放到 10.13.35.4:7681/api/analyze，返回 1 个 UNRESOLVED_REFERENCE，仍误判 index_1。健康接口返回 0.7.0，未提供提交号。

## 本轮验收

用户于 2026-11-23 将范围确认为代码修复及本地测试。核对 633467 原文与回归样例逐字节相同，在包含 be9d0dc4 的 d65cf170 源码上运行核心单测（1748 项通过）和 LATERAL VIEW 专项（15 项通过）。原 SQL 的 issues 为空。attend_dt_list、formal_attend_dt_list 各自仅依赖 DA 和 DI 两表的同名列，展开后的 attend_dt、formal_dt 也分别核对了物理来源。真正未限定的同名引用仍有歧义诊断。接口结构兼容测试 3 项通过。使用已有本地 CLI 跑 18 个 SQL 回归，0 个失败，2 个样例带警告。本轮未上传或部署。
