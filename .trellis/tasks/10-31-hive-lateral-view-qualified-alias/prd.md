# Hive LATERAL VIEW 同名输出列兼容

## 目标

修复审计 559417 的合法 Hive SQL 在 FlowScope 中被报为 UNRESOLVED_REFERENCE 的问题，保留原 SQL 和字段来源语义。

## 已确认事实

- 用户提供入口：http://10.13.35.4:7681/?auditId=559417。
- GET /api/audit/559417 返回 Hive 请求、success=false；唯一 error 为重复声明 index_1，非 parser 语法错误。
- 原 SQL 对 attend_dt_list、formal_attend_dt_list 分别执行 LATERAL VIEW posexplode，表别名分别为 tmp、tmp1，输出列分别为 (index_1, attend_dt)、(index_1, formal_dt)。WHERE 使用 tmp.index_1 = tmp1.index_1。
- Hive posexplode(array) 的第一列为从 0 开始的位置，第二列为元素值。两个不同表别名下的同名输出列可通过限定引用区分。
- visitor.rs 注册阶段只按输出列名调用 register_lateral_view_binding，context.rs 发现重复后立即清除绑定并报错；现有测试与规范也采用此过宽规则。
- 原 SQL 及审计结果保存在 research/。工作区原有改动不属于本任务。

## 要求

- 支持不同 LATERAL VIEW 具有同名输出列，并正确识别 tmp.index_1 与 tmp1.index_1。
- 仅在实际引用不能唯一定位时报告歧义，不因重复声明本身拒绝合法 SQL。
- 限定输出与无前缀的唯一输出列保留各自输入来源，不能将输出别名推成物理表或物理字段，不能任选或合并两个生产者消除歧义。
- 保持既有结构元素访问、前序 LATERAL VIEW 输出复用、真实关系别名优先、SELECT 作用域隔离与窗口控制依赖分离。
- 修复进入 flowscope_core::analyze 共用路径，不改业务 SQL，不做脚本或前端专用绕过。

## 验收标准

- 未修改的 audit-559417.sql 经公开 analyze() Hive 入口返回无 error；INSERT 类型、overwrite、目标表和两个真实来源表保持正确。
- 两个 posexplode 使用相同位置列名时，WHERE/SELECT 中的表别名限定引用均无误报；只声明而不引用重名列也不报错。
- 生成值列 attend_dt/formal_dt 分别追溯到对应数组输入；不产生来源表物理列 attend_dt、formal_dt、index_1 或虚构来源表 tmp/tmp1。
- 实际使用无前缀的歧义输出，以及有歧义的结构输出 r.goods，继续报错且不猜测来源；不存在的限定输出不得回退成已知输入来源。
- 原 lateral_view_struct_lineage 回归、作用域和窗口控制相关回归通过；核心单测与真实 SQL 回归结果分别记录。
- 原始 SQL 的本地 SHA-256 与审计 sql_hash 核对；任何已有基线失败单独说明，不能视为本任务通过。

## 范围外

不执行业务 SQL，不验证数组业务对齐或 collect_set 的顺序语义；不部署、不上传 CDN、不改服务器、不改已有审计记录、不自动提交代码。

## 当前状态

用户于 2026-10-31 明确批准按方案实施，并要求原 SQL 验证及字段血缘检查；任务已启动。技术方案和实施清单见 design.md、implement.md。
