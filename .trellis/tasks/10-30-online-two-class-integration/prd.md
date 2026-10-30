## 目标

1. 两独立worktree并行修复前导下划线标识符与复杂类型。
2. 用今天失败的53份非PHP原SQL全量回测，解析与字段血缘通过后合master。

## 需求

- R1：原SQL哈希不变，正式native/WASM同源，不以改SQL、吞异常或手工造边替代修复。
- R2：按原SQL独立期望核对输出覆盖、值来源、窗口控制角色、目标位置；Schema缺证不虚报通过。
- R3：FROM VALUES、exists、View COMMENT、多个GROUPING SETS仅保留清单；PHP完全排除。
- R4：原有WIP保护；不push、不部署、不写生产图。

## 交付结果

- [x] O1：两类实现和回归通过，具备独立worktree证据。
- [x] O2：53份SQL全部有回测结果，本类字段验证通过，其余明确保留。
- [x] O3：WASM验收，合master后复查并保留原有改动。
