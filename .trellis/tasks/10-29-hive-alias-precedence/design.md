# C7 设计

## 原因与最小修复

`select_analyzer.rs::resolve_lateral_alias_sources`在Hive启用lateral_column_alias时按名称盲展开先前别名，未先检查FROM真实字段。按现有scope resolver查询真实列，存在可解析来源则优先；确无源列才保留既有alias展开。不得通过关闭Hive全部alias或删除合法窗口控制边消除表面差异。先查当前Spec/已有方言规则，必要以Hive官方资料补证真实源列优先规则。

## 历史替换

冻结旧/新CLI、原CSV、DDL和元数据。整类扫描须区分真正同名source/alias冲突和普通C6新增依赖，生成精确old/new边合同；可复用已有唯一语义映射，但不能仅按node ID或alias相信旧/新节点相同。两端与旧关系先全量预检，任一不确定则拒绝该候选。只替换已证明错误值边，合法后续窗口边保留，所有无关记录语义不变；producer与原SQL/hash/edge证据可追溯。全量重建使用原prepared节点，不得全盘换新parser节点掩盖差异。

## 验收与边界

C7独立两仓worktree，依赖已验证C5/C6；新空17694隔离图重放C1—C7后只读全字段快照及AST，原750值边保留（除非精确C7合同证明其中也错），932+40624目标映射与416casefold均回归。C3新确认10305单独按原类别处理。生产图只读，未授权stash重叠文件之前不合原master；不push不部署。无法唯一证明的历史项保留unknown。embedding文本不消费值/控制边且不改元数据，不要求重建向量。
