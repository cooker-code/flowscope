# 实施

1. 读取jsonl、PRD、design及Spec，记录31109旧SQL/DDL/原生错误边并查别名优先级合同。
2. 独立FlowScope C7 worktree修scope resolver及最小反例/无冲突Hive alias/多源歧义回归，禁止其他方言变化。
3. 同旧新CLI全3161原ETL扫描，按SQL/scope/表达式/元数据证明历史错边与新正确边，输出manifest/rejected。
4. 独立Neo4j C7 worktree实现严格替换合同，全部端点/旧关系先预检再事务替换，单测缺证据零写入/幂等/无关保留。
5. 新空隔离图整类回放与C1—C6全回归、独立AST、真实HTTP；任何确认差异继续查因，未知不算通过。
6. 独立check与Spec同步，分仓提交后按类别依赖合本地master，原WIP只按具体授权恢复，生产不改。
