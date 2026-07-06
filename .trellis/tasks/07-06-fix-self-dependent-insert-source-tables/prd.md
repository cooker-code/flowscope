# 修复自依赖 INSERT 缺失 sourceTables

## Goal

修复 FlowScope 在自依赖 `INSERT` 场景中漏出顶层 `sourceTables` 的解析契约问题：当 SQL 从物理表读取并写回同一张目标表时，`result_json.sourceTables` 仍必须包含该物理来源表。

## Requirements

- 在 `flowscope-core` 的生产分析路径中修复，不在 `neo4j-http-service` 或其它消费方做 fallback。
- 顶层 `sourceTables` 聚合必须保留所有被读取的物理表；即使来源表与 `targetTable.qualifiedName` 相同，也不能被过滤掉。
- `sourceTables` 只包含物理表，不把 CTE 或派生表别名 `a`、`b` 当作顶层来源表。
- 继续允许去重，同一张物理表多次读取时顶层只需要出现一次。
- 保持现有 `targetTable`、节点、边和错误摘要行为不回退。

## Acceptance Criteria

- [x] 最小回归 SQL：`INSERT OVERWRITE` 写入目标表，同时从同一目标表的两个分区/别名读取。
- [x] 回归断言 `targetTable.qualifiedName == "dw_ads.dm_eng_user_portrait_label_di"`。
- [x] 回归断言 `sourceTables` 包含 `dw_ads.dm_eng_user_portrait_label_di`。
- [x] 回归断言 `sourceTables` 不包含别名 `a`、`b`。
- [x] 相关 `flowscope-core` Rust 测试通过。

## Notes

- 线上复现：`auditId=190817`，`source_name=dmEngUserPortraitLabelDi.php`，`target_table=dw_ads.dm_eng_user_portrait_label_di`。
- 现象：`result_json` 顶层缺少 `sourceTables`，但 `nodes` 和 `edges` 已能识别同名物理表及别名路径。
- 根因：顶层物理表分类把 `sourceTables` 定义成“所有非 sink 物理表”，隐含假设同一物理节点不能同时是 source 和 sink；自依赖 INSERT 在全局图展平后正好违反这个假设。
- 预防：已新增 `.trellis/spec/flowscope-core/backend/analyze-result-contract.md`，明确 `sourceTables` 应按真实读取边独立分类，self-dependent write 必须同时出现在 `targetTable` 和 `sourceTables`。
- 验证：
  - `cargo fmt --all -- --check`
  - `cargo test -p flowscope-core test_self_dependent_insert_keeps_target_in_source_tables -- --nocapture`
  - `cargo test -p flowscope-core test_target_and_source_tables_for_insert_overwrite`
  - `cargo test -p flowscope-core test_multiple_target_tables_emit_error_and_clear_field`
  - `cargo test -p flowscope-core --lib`
  - `cargo build -p flowscope-cli`
  - `python3 scripts/regression-test-sql.py --bin target/debug/flowscope`
  - `node ./scripts/update_api_schema.cjs`
  - `cargo test -p flowscope-core --test schema_guard --locked`
  - `yarn workspace @pondpilot/flowscope-core test schema-compat.test.ts --silent`
- 影响排查：
  - `select_join`：`targetTable=null`，`sourceTables=["orders","users"]`。
  - `insert_from_source`：`targetTable="dw.tgt"`，`sourceTables=["dw.src"]`。
  - `with_cte_insert`：`targetTable="dw.tgt"`，`sourceTables=["dw.src"]`，CTE 不进入顶层来源。
  - `join_dependency`：`targetTable="dw.tgt"`，`sourceTables=["dw.src_a","dw.src_b"]`，只参与 JOIN 依赖的物理表仍保留。
  - `self_dependent_insert`：`targetTable="dw_ads.dm_eng_user_portrait_label_di"`，`sourceTables=["dw_ads.dm_eng_user_portrait_label_di"]`，这是本次唯一刻意变化。
- 生产打包：
  - `cd app && yarn build`
  - `rm -rf crates/flowscope-cli/embedded-app && mkdir -p crates/flowscope-cli/embedded-app && cp -R app/dist/. crates/flowscope-cli/embedded-app/`
  - `cargo zigbuild --target x86_64-unknown-linux-gnu.2.17 --target-dir target-zigbuild -p flowscope-cli --features serve --release`
  - glibc 校验最高版本：`GLIBC_2.17`
  - H5 zip：`flowscope-h5-20260706-1140.zip`，sha256 `4b01cc468a94d0e1eafa27aa1945b201a0d1779d42c57dd5717798ad1375f9ba`
  - Linux CLI：`target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope`，sha256 `8a30fb1550dafd9ff79ff41cf03a5fcd237a7c6f5dc0ff538559488446ad61ef`
  - H5 CDN：`http://upload.zhenguanyu.com/uploads/1092e9b3_flowscope-h5-20260706-1140.zip`
  - CLI CDN：`http://upload.zhenguanyu.com/uploads/01280f27_flowscope`
