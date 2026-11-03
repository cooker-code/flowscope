# 证据与根因

## 在线审计

2026-10-31 读取 GET http://10.13.35.4:7681/api/audit/559417。记录 source_name=dwd_conan_course_pedia_attend_da.hql，dialect=Hive，success=false。唯一错误：

> UNRESOLVED_REFERENCE: LATERAL VIEW output alias 'index_1' is declared more than once in this SELECT scope; references to it are ambiguous

SQL 已形成完整 INSERT 和来源表等分析结果，因此本例不属于 parser 不接受 posexplode 语法。

## 源码

- visitor.rs:641 起遍历 lateral_col_alias，仅以 alias.value 登记，未用 lateral_view_name 区分表别名。
- context.rs:754 起 register_lateral_view_binding 以列名为键，重复时移除绑定并记歧义；visitor 无条件转为 error。
- select_analyzer.rs:323 起依赖这些绑定展开字段来源；WHERE 走 ExpressionAnalyzer，实施时须核对共同解析入口。
- tests/lateral_view_struct_lineage.rs:148 的拒绝例 SELECT r.goods 对两个同名结构输出进行未限定访问，仍应保留拒绝；该例不能证明限定表别名后的同名列也应拒绝。
- 复杂类型CAST.md:51 将重复输出声明本身视为 error，范围过宽，须同步修订。

## 官方语义

- https://hive.apache.org/docs/latest/language/languagemanual-lateralview/：语法定义包含 tableAlias AS columnAlias；允许多个 LATERAL VIEW。
- https://hive.apache.org/docs/latest/language/hive-udfs/：posexplode(array) 输出 (pos,val)，位置从 0 开始。
- https://hive.apache.org/docs/latest/language/languagemanual-udf/：提供 LATERAL VIEW posexplode(...) tf AS pos,val 示例。

原 SQL 的 WHERE 使用 tmp.index_1=tmp1.index_1，已明确指定各列所属输出关系，应允许此合法引用。

## 判断边界

位置相等用于保留两侧相同下标的展开行；它本身不证明两个数组的生成顺序满足业务配对，尤其原 SQL 有 collect_set。本任务不改变此业务逻辑。
