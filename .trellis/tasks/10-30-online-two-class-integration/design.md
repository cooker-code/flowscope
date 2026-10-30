## 设计与验收

修改正式Core方言，复用sqlparser AST能力，不改原SQL绕过。两分支不同方法的共享文件由主session集成。独立AST与正式native按statement/scope/字段来源/窗口role/targetposition对照；现有冻结Schema补星号。缺证或差异不伪报全正确。WASM与native同源，未定位字段差异阻止合并。
