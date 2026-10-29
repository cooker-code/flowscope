## Goal

1. 修复原 ETL 的 SUBSTR/SUBSTRING/TRIM/FLOOR/CEIL/CEILING 复杂表达式遗漏物理值来源，使其下游值与窗口控制能完整追溯。
2. 以 C6 独立 worktree 实施，先保存确认问题，再原脚本整类隔离回测，合本地 master，生产不改。

## Requirements

### R1 修改

- **R1.1**：FlowScope 通过 AST 递归收集 Expr::Substring 的输入/起点/长度、Expr::Trim 的输入/修剪参数、Floor/Ceil 的输入等字段引用，保持值来源与窗口控制角色独立。
- **R1.2**：原任务25303的dbctime在真实DDL与固定SQL下产生可定位Physical值来源，普通及嵌套/动态参数反例有回归。

### R2 新增

- **R2.1**：全量扫描3161原ETL，历史回补仅针对可由SQL、parser、精确旧scope和元数据证明的Substring值边；无法唯一定位须记录拒绝。
- **R2.2**：独立loader只连接已存在Physical和原Derived fs_uid，保留原值边、ownership和target_map，不创建字段节点。

### R3 新增

- **R3.1**：黄金基线462158条值/归属记录全部保留且属性不变，新增边逐条等于manifest；重复加载图规模与语义不变。
- **R3.2**：C1—C5正常集、独立AST及真实HTTP全部回归；明确所有缺元数据、历史自源和无法唯一回补原因。

### R4 修改

- **R4.1**：两仓只提交本类改动，保护原master WIP；每类隔离验证后才合本地master，不push、不部署、不改生产。

## User-visible Outcomes

- [ ] **O1（R1.1、R1.2）**：SUBSTR等表达式的真实字段值来源不会再丢失，25303窗口控制可经正确值前缀追溯dbctime。
- [ ] **O2（R2.1、R2.2、R3.1）**：可确认历史缺边有逐项回补与拒绝明细，既有值/目标映射/归属不受误改。
- [ ] **O3（R3.2、R4.1）**：Markdown记录整类实际隔离回测及合并状态，证据不足项不冒充正确，生产图不变。
