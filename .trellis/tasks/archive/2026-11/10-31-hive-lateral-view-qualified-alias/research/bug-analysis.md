# Bug Analysis: LATERAL VIEW 同名位置列误报

## 1. Root Cause Category

E（隐含假设）与 D（测试覆盖缺口）：原绑定把输出列名当作 SELECT 范围内唯一标识，没有表达 LATERAL VIEW 表别名。此前防止歧义覆盖的测试只验证 r.goods 的拒绝，却把“声明重复”直接等价为“实际引用有歧义”。

## 2. Why Fixes Failed

原实现对真正歧义引用拒绝正确，但拒绝范围过宽。本次未采用删除校验或后写覆盖的修复，因为这会隐藏字段来源选择错误。先添加公开 analyze 入口的合法限定引用例，在修复前复现，再修改绑定与统一引用解析。

## 3. Prevention Mechanisms

| 优先级 | 机制 | 落地 |
|---|---|---|
| P0 | 名称模型 | 同时保存表别名和输出列名，多候选直到实际引用判断 |
| P0 | 解析状态 | NotFound/Resolved/Ambiguous/UnknownColumn 分开；错误状态不得推成物理字段 |
| P0 | 正反例配对 | 合法限定重名与真实未限定歧义并列回归 |
| P0 | 物理根断言 | 原 SQL 检查全部业务字段、两侧数组无串线、禁止伪字段 |
| P1 | 规范 | 修订复杂类型CAST.md 的过宽拒绝规则 |

## 4. Systematic Expansion

统一覆盖投影、WHERE、链式 UDTF 和窗口控制，保留真实关系限定名优先和 SELECT 作用域。常量输入也登记输出，避免空来源被误认为没声明。本次不扩展通用 Hive Schema 检查，也不调整生产或业务 SQL。

## 5. Knowledge Capture

- 已更新 .trellis/spec/flowscope-core/backend/复杂类型CAST.md。
- 已更新 CHANGELOG，并保存原 SQL 与分析 JSON。
- 此项目无 src/templates/markdown/spec 模板目录，不执行模板同步。
- 代码提交须按项目工作流单独确认，本轮未获得提交授权。
