# 修复与验证结果（2026-10-31）

## 原 SQL

审计 559417 原文未改；保存 SQL 与正式测试 fixture 字节一致，SHA-256 为 ce2a1fe98ac0cd875d48461bf1710af52c60720052236235f389094a3bf10ecd，与审计 sql_hash 一致。

当前源码构建的 target/debug/flowscope 重放返回退出码 0，issues=[]：1 条 INSERT OVERWRITE、目标 dw_conan_dwd.dwd_conan_course_pedia_attend_da、真实来源为该 DA 表及 dw_conan_dwd.dwd_conan_course_pedia_attend_di。summary.tableCount=3 包含中间派生关系 res，不是 3 张物理来源表。

## 字段血缘

16 个业务目标字段逐项断言：各自仅来自 DA/DI 的同名物理字段。attend_dt 的两支来源均为 attend_dt_list，formal_dt 的两支来源均为 formal_attend_dt_list；没有两组数组互相串线。load_datetime 无物理字段根。没有伪物理字段 attend_dt、formal_dt、index_1，也没有把 tmp/tmp1 建成物理来源表。

DA 是自依赖 INSERT 的上一批次来源，节点可与写入目标复用；断言在物理列处停止，不跨该节点递归推断前一天执行。展开值列与位置列保留 UDTF expression/Derivation；窗口位置输入只保留对应 WindowControl 角色。

逐字段结果见 research/field-lineage-validation.json，完整结果见 research/audit-559417-after.json。

## 已通过检查

| 检查 | 结果 |
|---|---|
| Core --lib | 1750 passed |
| lateral_view_struct_lineage | 15 passed（原有7项＋新增8项） |
| scoping | 22 passed |
| lineage_engine | 451 passed |
| complex_types_lineage | 3 passed |
| strict_imported_schema | 5 passed |
| 现有 SQL 回归，显式指定新构建 CLI | 18 passed、0 failed；2 条有警告 |
| Clippy --lib --test lateral_view_struct_lineage -D warnings | 通过 |
| cargo fmt --all -- --check | 通过 |
| git diff --check | 通过 |

## 未全绿检查与基线证据

- cargo test -p flowscope-core --tests 在 golden 的 10 项快照失败后停止，因此不能宣称全部集成测试通过。用隔离副本保留原有工作区改动、仅恢复本次修改前的 4 个分析器文件及旧 lateral 测试后，同样 10 项失败；对应生成快照的 JSON 正文逐项相同。见 research/golden-baseline-comparison.json、golden-baseline.log、core-all-tests.log。未接受或改写旧快照。
- cargo clippy --all-targets -D warnings 失败：lineage_engine 布尔比较、statements 测试模块位置及 linter 测试 sort_by 写法。诊断涉及的源码文件逐个与 HEAD 对比均未改变，见 research/clippy-existing-files.json。未扩大本任务修改范围。
- 隔离副本曾共用 Cargo 产物目录，导致一次后续测试复用了旧 Core 产物；已强制重新编译本次源码并完整重跑相关 496 项集成测试、Core 单测、CLI 构建及原 SQL。最终命令状态见 research/validation-commands.json。

## 审查与交付边界

本轮主会话完成实现和检查，无子代理。按 trellis-break-loop 和 trellis-update-spec 更新复杂类型CAST.md；无模板目录需同步。未改 HTTP/JSON 接口或边枚举，无前端修改。仅本地分析器和 CLI 验证，未执行业务 SQL、未部署服务器，旧审计行仍保持原记录。

已删除本次隔离源码副本；测试快照已复制到任务 research/golden-after 留证；仓库原本已跟踪的 .snap.new 草稿均按 HEAD 内容保留，未删除或接受快照。代码未提交，保留用户原有 30 项改动；CHANGELOG 仅追加本任务 Fixed 条目。

## 提交前独立验证（2026-11-03）

用户授权提交并推送。将 Git 暂存区导出到独立源码目录，并使用该目录独立的 Cargo target；未纳入原有 SQL 指纹、CLI/导出依赖等工作区改动。

- Core 单测：1748 passed。
- 集成测试：lateral_view_struct_lineage 15、scoping 22、lineage_engine 451、complex_types_lineage 3、strict_imported_schema 5，合计 496 passed。
- cargo fmt --all -- --check：通过。
- cargo clippy -p flowscope-core --lib --test lateral_view_struct_lineage -- -D warnings：通过。
- 审计原 SQL、fixture 和 sql_hash 三者一致。
- git diff --cached --check 对原始 SQL 的两份副本报告尾随空白与缩进空白；为满足保留原文及哈希要求，不修改 SQL。排除这两份原文后的暂存差异检查通过。
- 2026-10-31 的全目标 Clippy 与 golden 基线失败记录继续保留，不把上述针对性检查描述为全仓库检查通过。

本次提交仅包含本任务修复、规范、CHANGELOG Fixed 条目和任务资料；其他既有改动保留。Git 推送包含 master 上已有的 28 个提交，目标为当前跟踪配置的 origin/master。
