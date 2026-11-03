# 实施清单

## 启动前

- [x] 获取审计 559417 原 SQL 和 result_json，定位错误代码。
- [x] 对照 Hive 官方文档、当前绑定代码、已有测试和规范。
- [x] 创建 PRD、设计和实施清单；保留工作区基线。
- [x] 用户审阅上述规划并同意实施后，task.py start。
- [x] 读取 trellis-before-dev、相关 Core 规范和边类型契约。

## 实施

- [x] 添加最小双 posexplode 合法重名例、原 SQL fixture；先验证修复前失败。
- [x] 建立表别名限定绑定，独立处理无前缀候选、结构成员访问和作用域。
- [x] 将歧义诊断移到实际引用阶段；已知虚拟表的未知列不得制造来源。
- [x] 修正投影、条件和链式 UDTF 输入解析，保持窗口依赖角色。
- [x] 补充正反例：限定位置列、限定值列、唯一无前缀值列、未引用重名列、实际无前缀歧义、结构元素歧义、未知限定列、真实关系遮蔽、嵌套作用域、常量输入。
- [x] 对 audit 559417 断言语句摘要、真实来源表和各值列物理根，禁止伪来源字段。
- [x] 更新过宽规范及 CHANGELOG；按 trellis-break-loop 记录此次误报根因。

## 验证

- [x] cargo test -p flowscope-core --test lateral_view_struct_lineage
- [x] cargo test -p flowscope-core --test scoping
- [x] cargo test -p flowscope-core --lib
- [x] cargo fmt --all -- --check
- [x] cargo clippy -p flowscope-core --all-targets -- -D warnings（已执行，既有问题导致失败；本次目标单独检查通过）
- [x] 核实 scripts/regression-test-sql.py 的 CLI 路径与重建要求；使用含本次修改的二进制执行，不拿旧 CLI 结果验收新源码。
- [x] python3 scripts/regression-test-sql.py；如基线失败，记录具体失败与本任务相关性。
- [x] 读取 trellis-check 与 trellis-update-spec，审查本次差异和物理根证据。
- [x] 分开报告本地验证、未部署状态、已有基线问题。
- [x] 提交范围沿用 commit-plan.md；用户于 2026-11-03 明确要求提交到远端。

## 执行结论

本地修复、原 SQL 和字段血缘验证已完成。全目标 Clippy 与 golden 存在已核实的基线问题，详细结果见 validation.md，不将其视为检查通过。2026-11-03 已获得提交并推送授权；提交时仅纳入本任务修复和任务资料，保留其他原有改动。已创建修复提交 be9d0dc4，并按项目规则完成本地归档；远端推送由本次 Git 流程继续执行。未部署。
