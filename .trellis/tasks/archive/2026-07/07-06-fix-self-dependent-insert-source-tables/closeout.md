# 修复自依赖 INSERT 缺失 sourceTables - 收尾记录

## 任务结论

已修复 FlowScope 在自依赖 `INSERT` 场景下漏出顶层 `result_json.sourceTables` 的契约问题。

修复后，当 SQL 从目标表历史分区读取再写回同一目标表时：

- `targetTable.qualifiedName` 保持写入目标表。
- `sourceTables` 保留同一张被读取的物理表。
- `sourceTables` 不包含派生表别名 `a` / `b`。
- 重复读取同一物理表只保留一次。

## 关键改动

- `crates/flowscope-core/src/analyzer/global.rs`
  - 将顶层物理表分类从“source = 非 sink 的物理表”改为“source = 读取边的物理 from 端”。
  - 保持 `targetTable` 按写入边识别。
  - `sourceTables` 现在可在自依赖写入中包含与 `targetTable` 相同的物理表。
- `crates/flowscope-core/src/analyzer/tests.rs`
  - 新增 `test_self_dependent_insert_keeps_target_in_source_tables` 回归测试。
- `crates/flowscope-core/src/types/response.rs`
- `packages/core/src/types.ts`
- `docs/api_schema.json`
  - 同步响应契约说明。
- `.trellis/spec/flowscope-core/backend/analyze-result-contract.md`
  - 沉淀 `targetTable` / `sourceTables` 顶层契约。
- `.agents/skills/conan-claro-task-append/SKILL.md`
- `.trellis/spec/guides/claro-task-scoring.md`
- `AGENTS.md`
  - 在本项目内搭建 Claro / DocZ / Trellis 收尾流程入口。

## 验证

- `cargo fmt --all -- --check`
- `cargo test -p flowscope-core test_self_dependent_insert_keeps_target_in_source_tables -- --nocapture`
- `cargo test -p flowscope-core test_target_and_source_tables_for_insert_overwrite`
- `cargo test -p flowscope-core test_multiple_target_tables_emit_error_and_clear_field`
- `cargo test -p flowscope-core --lib`
- `node ./scripts/update_api_schema.cjs`
- `cargo test -p flowscope-core --test schema_guard --locked`
- `yarn workspace @pondpilot/flowscope-core test schema-compat.test.ts --silent`
- `cargo build -p flowscope-cli`
- `python3 scripts/regression-test-sql.py --bin target/debug/flowscope`

SQL 回归脚本结果：18 passed，0 failed，2 个既有 warning。

## 影响排查

| 场景 | 当前结果 | 判断 |
| --- | --- | --- |
| 普通 SELECT JOIN | `targetTable=null`, `sourceTables=["orders","users"]` | 保持正确 |
| 普通 INSERT FROM source | `targetTable="dw.tgt"`, `sourceTables=["dw.src"]` | 保持正确 |
| WITH CTE INSERT | `targetTable="dw.tgt"`, `sourceTables=["dw.src"]` | CTE 不进入顶层来源 |
| JOIN dependency | `targetTable="dw.tgt"`, `sourceTables=["dw.src_a","dw.src_b"]` | join-only 来源仍保留 |
| 自依赖 INSERT | `targetTable` 与 `sourceTables` 都是 `dw_ads.dm_eng_user_portrait_label_di` | 本次刻意修复 |

## 生产打包

- H5 zip: `flowscope-h5-20260706-1140.zip`
- H5 CDN: `http://upload.zhenguanyu.com/uploads/1092e9b3_flowscope-h5-20260706-1140.zip`
- H5 sha256: `4b01cc468a94d0e1eafa27aa1945b201a0d1779d42c57dd5717798ad1375f9ba`
- Linux CLI: `target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope`
- CLI CDN: `http://upload.zhenguanyu.com/uploads/01280f27_flowscope`
- CLI sha256: `8a30fb1550dafd9ff79ff41cf03a5fcd237a7c6f5dc0ff538559488446ad61ef`
- glibc 最高版本：`GLIBC_2.17`

## Claro / DocZ 收尾

- Epic: `[E-4900471] SQL 解析`
- Story: `[S-1187] FlowScope sourceTables 契约修复`
- Task: `[T-1646] 修复自依赖 INSERT 缺失 sourceTables`
- Claro Task: `https://claro.zhenguanyu.com/tasks/1646`
- Task 状态：`done`
- Story 状态：`done`
- score: `4`
- plannedScore: `4`
- DocZ 目录：`S160-技术:projects/[P-7] AI探索/Epics/[E-4900471] SQL 解析/[S-1187] FlowScope sourceTables 契约修复/[T-1646] 修复自依赖 INSERT 缺失 sourceTables/07-06-fix-self-dependent-insert-source-tables`
- DocZ 短链：`https://docz.zhenguanyu.com/s/rd/f/aL7UoAtp`
- 上传文件：`task.json`, `prd.md`, `closeout.md`
- Task 产物挂载：`source=docz`, `type=other`, `title=DocZ: 07-06-fix-self-dependent-insert-source-tables`

## 遗留风险

- 已生成并上传新 CLI serve 二进制；线上服务需要替换二进制并重启后生效。
- 旧 audit 记录中已经写入的 `result_json` 不会自动刷新，需要重新分析或重写 audit 记录。
- 完整 `cargo test -p flowscope-core` 当前会碰到仓库既有 golden snapshot 漂移；本次验证使用 `--lib`、schema guard、SQL 回归和定向单测覆盖变更面。
