# C3 INSERT 目标字段映射设计

解析器在语句完成后读取 INSERT 的显式字段列表；没有显式列表时仅从导入或 DDL 建立的 schema 读取顺序。它把位置、目标字段和依据写在输出节点 `metadata.insertTarget`，并把完整合同写在目标表 `metadata.insertTargetMapping`。

普通 SELECT 的每个输出和一个目标位置一一对应。UNION 的每个分支都是同一目标投影的另一条值来源：递归检查 `SetExpr` 的每个分支，拒绝通配投影或分支宽度不一致；只有每一分支宽度都等于权威目标列数、并且 AST 分支总宽度等于已分析输出数时，才按已验证的 branch position 写映射。这样不同 alias 不会被误当成不同目标列。

全局图合并时，如果同一列或表从不同语句得到冲突的映射，状态变为 `unresolved`，消费者不得继续使用首次映射。
