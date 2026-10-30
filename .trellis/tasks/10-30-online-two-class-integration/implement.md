## 实施顺序

1. 两worker实现和本类回归。
2. 集成并原样回放53SQL。
3. 独立字段验收与必要Schema核对；其余四类不实施。
4. trellis-check、Core/lineage/scoping/CLI/WASM相关验证。
5. 更新Spec和问题清单，按类commit并快进master，复查原WIP保护。

## 最终验收范围（2026-10-30）

- 原 SQL 53 份（非 PHP），原文 SHA 不变；不执行业务 SQL。35 份首错为下划线，11 份首错为复杂类型，另外7份最初即保留。复杂类型修通后557500仍有exists错误。
- 用户确认：缺表直接报错，只做解析；提供的严格Schema未知表报UNKNOWN_TABLE。557924因此失败，不查迁移、不造字段。最终预期44成功、9明确错误。
- V5 已达到44/9、native/WASM语义53/53一致；496个INSERT位置、443条已可独立证明的值根路径及557134/557185的14个最终输出均匹配。复杂SQL的最后漏根last_total_weekcount已修复；lambda局部变量及数字字面量不作为物理来源。
- V5独立验收不覆盖所有深CTE/star的精确根集合，未决项保留状态，禁止扩大为全字段语义证明。
- review确认重复LATERAL输出别名会覆盖前者，补明确错误后重建V6，最终验收记录为准。
- Core2665项非快照测试通过、3ignored，Core lib1749包含其中；WASM17、core lib clippy -D warnings通过。36项旧快照差异正在与基线实测对照，不盲目接受快照。
- 全量原SQL/DDL/结果、运行时、图快照保存在外部证据目录`/Users/blank/.codex/tmp/field-lineage-audit-20261029-01a1866f/cases/online-two-category-fix`；Git只保留必要任务记录、复核脚本和最终摘要。

## V6 最后代码检查点

代码提交 `64b9bbb2`，此前独立下划线提交 `a7d1f078`、复杂类型提交 `91bfae33` 已由 `e18262d0` 集成。重复LATERAL输出别名已明确错误，回归7/7。最终V6：53原SQL44成功9错误、WASM53语义一致；Core非快照2666 passed/3ignored，core lib clippy -D warnings通过。V6独立对照496位置、443已证明值根路径、14复杂类型输出全部匹配。窗口183个(auditId,role,physical_source)三元组匹配，不含output endpoint，不能称全窗口输出的精确根证明。

基线a7在独立target实跑golden10/snapshots26同集合失败：既有AnalyzeResult快照契约漂移；未更新或接受快照，生成产物保存外部证据。此缺口不得伪报为全量测试通过。本轮未改CLI接口；CLI native正式构建成功；额外CLI全tests触发无关export/DuckDB重编译后已终止，未算通过。

V6已用全新17695基线、真实44任务scope正规四loader两轮回放。精确Physical值边3407、控制359、已证Physical目标映射510均匹配；557924节点/scope为0，24无target SELECT映射为0。代码已FF到原仓库master 64b9bbb2，原有7文件SHA逐项不变，无需新增stash。合后Core含原WIP复查进行中。最终图回读与运行时绑定见research/final-validation.json。

合后原始master含原有两项Substring回归实际运行Core lib：1751 passed；原有7文件逐SHA保持。本次无需stash，历史stash/补丁均保留。

最终逐位置验收496/496：470 Derived输出自身目标映射+26 Physical输出对应40条incoming列值映射，共510条精确目标路径全部匹配。CTE关系级18条不纳入列targetmap，也不要求项目合同明确不建的CTE→M_TABLE REF_TEP。先前26/18缺失为验收器误报，已撤回；没有据此造Derived、Physical或列关系。正确只读验收器已保留。40条合法关系的mapping_basis默认legacy_name标签不准确，作为本轮范围外既有元属性问题记录，未改Neo服务程序。
