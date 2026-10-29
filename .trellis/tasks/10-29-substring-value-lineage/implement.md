# 实施与核验

1. C6 两仓独立 worktree，读取 jsonl、PRD、design、implement 与各层 Spec。记录 C5 依赖 commit 和原 master WIP 哈希。
2. parser 补 Substring、Trim、Floor/Ceil 递归及真实25303/生日/支付时间/动态参数反例，构建新不可变CLI，跑 Rust/schema/WASM/TS 相关回归。
3. 扫描全3161原 ETL，以旧/新 parser 和精确 scope 对齐生成可证明的复杂标量函数值边 manifest；记录拒绝原因；仅扩展有真实原ETL证据的同类AST递归，不猜测端点身份。
4. 实现只消费 manifest 的严格端点 loader，单测身份歧义/缺字段/不动原图结构/重复加载。
5. 新空隔离图重放 C1—C5、C3合同和C6，逐条核对新增边，黄金基线全保留；重复执行不增节点/关系。原SQL独立AST及真实HTTP确认25303值前缀与窗口控制闭合。
6. 全范围独立检查、Spec与问题文档同步；每类通过后按C5→C6顺序合本地master，原WIP只按具体授权保护恢复；不push、不部署、不改生产。
