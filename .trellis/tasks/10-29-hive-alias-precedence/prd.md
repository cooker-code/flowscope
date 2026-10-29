# Hive 同名字段与投影别名优先级

## Goal

1. 修复原ETL中已有真实源字段被同SELECT先前投影别名遮蔽的值来源错误。
2. 独立C7 worktree整类验证后合本地master，生产不改。

## Requirements

### R1 修改

- **R1.1**：Hive当前FROM scope有可解析同名真实字段时使用该字段；只有没有真实源字段时才沿用既有lateral alias（同一SELECT较早投影别名）功能，不能改变其他方言。
- **R1.2**：真实31109的`CAST(memberuserid AS STRING) AS userid`后`CONCAT(CAST(userid AS STRING), SUBSTR(completedtime,1,19)) AS event_id`依赖Physical userid及completedtime，不得将memberuserid当作event_id值源或event_rk控制根。

### R2 新增

- **R2.1**：全3161原ETL比较修复前后parser，识别同类同名冲突，保存Markdown与逐项证据；旧Derived节点按原SQL/scope/表达式精确映射，端点不唯一则明确拒绝。
- **R2.2**：历史值边替换必须有同一原SQL、真实元数据、旧边与修正原生parser证明；仅删除明确错误source/edge_id/target组合，补正确值源，绝不删其后合法窗口控制边，不创建猜测节点。

### R3 修改

- **R3.1**：隔离图逐条证明错误边消失、正确边存在、所有无关值/归属/C3映射及C1—C6回归保留；重复回放幂等。
- **R3.2**：独立原SQL AST和真实HTTP确认31109 memberuserid错误根消失且userid/completedtime合法依赖保持；代码检查及整类图回测通过后才合master。

## User-visible Outcomes

- [ ] **O1（R1.1、R1.2）**：同名alias不再把真实字段来源替换成另一字段，非冲突alias功能不回退。
- [ ] **O2（R2.1、R2.2）**：每条历史替换有精确可审阅清单与拒绝原因，字段和scope身份不被猜测。
- [ ] **O3（R3.1、R3.2）**：Markdown保存全量及每类验收，生产不改，原master WIP受保护。
