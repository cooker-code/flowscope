# Hive入口的复杂类型CAST

## 范围与根因

Hive请求在正式Core中允许Spark的ARRAY/STRUCT/MAP类型。sqlparser-rs 0.61部分DataType分支按方言身份硬编码，包装HiveDialect不能仅靠supports_struct_literal开启类型语法。兼容必须在Core共用路径，CLI/WASM同源；不能修改工作负载原SQL或以整段Generic方言回退代替。

## 入口与契约

`FlowscopeHiveDialect::parse_prefix(&mut Parser)`接管普通`CAST`和严格匹配的 Hive 数值后缀字面量；值表达式仍交给Hive parser。类型递归构造现有`DataType`，不引入响应字段/边类型：`ARRAY<T>`、`STRUCT<name: TYPE>`、`STRUCT<name TYPE>`、`MAP<K,V>`。

- STRUCT字段名是类型成员，不是Physical来源字段。
- CAST输出的值来源仍是其被转换表达式。PARTITION/ORDER字段只产生window_control，不混入值边。
- INSERT保留既有位置合同，不从SELECT别名猜测目标列。
- `CAST` token必须无条件消费，禁止将移动parser游标的调用放进debug_assert；release/WASM会删除该断言。
- 新复杂类型递归仅设局部`MAX_HIVE_COMPLEX_TYPE_DEPTH=128`，越限返回ParserError，不能无限递归。

## 兼容与拒绝矩阵

| 输入 | 结果 |
|---|---|
| ARRAY嵌套STRUCT/MAP、紧邻`>>` | 正确AST类型 |
| 字段名反引号、块注释、混合大小写 | 保留合法类型语义 |
| STRUCT字段冒号省略 | Spark合法，接受 |
| 缺右尖括号、MAP缺value、STRUCT缺字段类型 | 保留解析拒绝 |
| 第129层复杂类型 | 明确深度错误 |
| 普通DECIMAL/STRING ARRAY CAST | 保留既有解析行为 |
| exists/FROM VALUES/View COMMENT/多个GROUPING SETS | 本任务不扩大兼容范围 |

## 必需回归

`complex_types_lineage.rs`直接调用`analyze()`：CAST(payload...)只保留payload值来源，类型字段item_id/attrs不成为Physical；FIRST_VALUE的值和窗口角色分离，INSERT位置1/2准确。方言测试覆盖畸形/深度边界及普通CAST。集成必须在最终同源native与release WASM重放原SQL，不能仅跑debug语法测试。

## 错误与正确方式

错误：删除类型结构或把整SQL送Generic解析，只检查hasErrors=false。正确：局部CAST类型AST解析、原SQL哈希不变，并比较完整字段来源、窗口角色和目标位置。

当天557500在复杂类型修复后仍遇到exists，须保留BLOCKED_BY_DEFERRED_EXISTS，不能虚报整份通过。

## 复杂表达式的字段依赖

- Hive 高阶函数必须启用 `supports_lambda_functions()` 并生成正式 `Expr::Lambda`。Lambda 参数及其成员属于局部变量；集合、初始化值和外部捕获列保留依赖。禁止用 Arrow 二元运算优先级或字符串替换猜测 Lambda 范围。非法参数列表直接报错。
- `CompoundFieldAccess` 必须递归收集根表达式和动态下标，静态成员名不构成物理字段。
- 支持的 LATERAL VIEW explode/posexplode 系列在当前 SELECT 注册输出绑定；真实关系别名优先，不能把输出别名建成物理表。值边与 WindowControl 使用相同绑定、保持角色分离。
- 对 `search_state.idx` 这类表达式，只有 AST 能证明唯一可见的 `search_state` 是结构值，才按基础列解析；不能靠表达式文本包含 `named_struct(` 判定。
- `0.00005D`、`0F`、`0BD`、`1L` 是数值，不是来源字段；带引号标识符不改写，L 仅接受整数字面量。
- 已提供 `allowImplied=false` 的 Schema 时，未知外部来源表返回 UNKNOWN_TABLE 错误；无 Schema 的符号解析继续保留。缺表不触发外部元数据查询或猜测补结构。

回归覆盖见 `lateral_view_struct_lineage.rs`、`hive_typed_numeric_lineage.rs`、`strict_imported_schema.rs`。以上均位于正式 Core，native 与 WASM 共用。

重复 LATERAL VIEW 输出别名不能通过 HashMap 覆盖来任选生产者：当前 SELECT 标记歧义、清除已有输出绑定并发 UNRESOLVED_REFERENCE error；两条输入都不能被猜成唯一来源。真实关系别名优先契约保持，回归包含两个AS r的拒绝例。
