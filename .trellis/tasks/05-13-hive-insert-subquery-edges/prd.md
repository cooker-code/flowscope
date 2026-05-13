# Fix INSERT OVERWRITE subquery data_flow edges missing

## Goal

修复 `flowscope-core` 引擎中 `INSERT OVERWRITE TABLE target SELECT ... FROM (subquery)` 模式下，目标表缺少 `data_flow` 入边的 bug（表级别血缘断裂）。

## 两个受影响文件的现象

### frog 文件（`dwd_eng_frog_user_devices_detail_chapter_finish_da.sql`）
- 结构：`INSERT OVERWRITE TABLE ... SELECT collect_set(...) FROM (subquery) GROUP BY ...`
- 现象：目标表有 ownership edges（列结构正确），但无 `data_flow` IN edge（表级别血缘断裂）
- 原因线索：`collect_set` 聚合函数只产生 `derivation` 边到列节点，表级 data_flow 未建立

### quiz 文件（`dwd_eng_chapter_quiz_question_report_ext_desc_all.sql`）
- 结构：`INSERT OVERWRITE TABLE ... SELECT ... FROM (subquery) INNER JOIN ... LEFT JOIN ...`
- 现象：130 条 data_flow 边存在，但 0 条指向目标表
- 原因线索：外层是子查询（`FROM (...)`），data_flow 在子查询内部正确，但没有向上传递到目标表

## Acceptance Criteria

- [ ] `dwd_eng_frog_user_devices_detail_chapter_finish_da.sql` 解析后，目标表有 `data_flow` IN edge（不再只有 ownership/derivation）
- [ ] `dwd_eng_chapter_quiz_question_report_ext_desc_all.sql` 解析后，目标表有 `data_flow` IN edge
- [ ] 另外 3 个 test-sql 文件解析结果无回归
- [ ] `cargo test -p flowscope-core` 全部通过
- [ ] 新增回归测试：`INSERT OVERWRITE + collect_set` 和 `INSERT OVERWRITE + outer subquery` 两个场景

## Out of Scope

- 列级血缘的完整追踪（collect_set 等聚合函数的输入列溯源）
