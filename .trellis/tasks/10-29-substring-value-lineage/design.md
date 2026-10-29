# Substring 值来源设计

## 范围与依赖

继承用户已批准的全量字段审计、分类独立 worktree、原 ETL 整类回测和本地 master 合并范围。本类由 C5 最终复审确认，先登记 Markdown 后实施。C5 工作提交作为分支依赖；C5、C6 均不得在对应回测完成前合 master，生产不改、不 push、不部署。原两个 master 的既有 WIP 保持保护，未获具体重叠处理授权前不得 stash。

## 原生 parser

在 `collect_column_refs` 处理 `Expr::Substring`、`Expr::Trim`、`Expr::Floor`/`Expr::Ceil`，递归收集被截取表达式、FROM/FOR、TRIM输入/修剪参数以及取整输入中的列引用；单位和字面量精度不是字段；沿用既有列解析、Physical/Derived、data_flow/derivation 与窗口控制合同。不能以字符串正则替代 AST，也不改变字段值与控制角色区分。测试嵌套 CAST/unix_timestamp/SUBSTR、标准 SUBSTRING、动态起点/长度及多源歧义；同步使用同一 helper 的控制提取、schema/WASM/TS 合同。先验证真实25303在真实DDL下新增 Physical dbctime 来源，再扫原3161 ETL 识别整类影响。

## 历史回补

固定修复后的 CLI、原 CSV、DDL/字段元数据与源代码哈希。仅为确含本类函数的表达式新增已由修复 parser 声明的值边；目标必须按同 SQL、statement、owner scope、表达式和标签唯一对应原 Derived fs_uid。Physical 源使用真实完整限定名和元数据身份，Hive casefold 仅唯一时回退。源、目标任一不能证明则拒绝并记录，禁止按数组顺序或旧 node ID 直接相信，禁止新造图节点。

准备器输出逐边 manifest、rejected 与加载合同。独立 loader 只 MATCH 两端并 MERGE 已证明的 DERIVES_COL，边类型/表达式沿用原值合同，保存稳定edge_id和本修复producer/SQL。不得替换旧节点、删除原值边、改 ownership 或 target_map；全部端点先验证，再写；重复加载语义与规模不变。可复用 C5 的唯一语义节点匹配及 C3 的 CLI/DDL 校验，共享 helper 变动要单独保持兼容测试。

## 验收与回滚

新空隔离图按完整原输入+C1—C5修复重建，再应用本类可确认集合。黄金基线462158条 DERIVES_COL/REF_TABLE_COL记录必须全保留、属性不变；新增记录逐条等于 manifest，不把修复后总哈希变化当失败。完整核验932位置修复/40624正常映射/123036归属/416大小写边、窗口值与角色、真实HTTP、全部字段与独立AST差异。真实缺边、历史自源和未闭合值前缀保持具体分类。代码分两仓独立提交；隔离回放不复用有旧错控制边的图。回滚仅删本producer精确关系或回退本类代码；生产无应用动作。
