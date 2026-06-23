# 审计页目标表筛选实现计划

## Checklist

- [x] 影响分析：检索 `AuditEntry`、`AuditWriter::query`、`audit_records`、`AuditPage` 的调用点和测试覆盖。
- [x] 更新 `AuditEntry` 和审计写入调用，加入 `target_table`。
- [x] 从 `AnalyzeResult.target_table` 提取展示用目标表。
- [x] 更新 SQLite schema、insert SQL、query SQL、query_one SQL、query_files 如必要。
- [x] 新增 `target_table` filter，并补后端单测：
  - round trip 返回目标表
  - 精确筛选
  - legacy migration 补列并幂等
- [x] 更新 `AuditQueryParams` 和 `/api/audit` 参数传递。
- [x] 更新 `AuditPage`：
  - URL key
  - 本地 input state
  - debounce sync
  - request query
  - reset
  - list record type
  - 表格目标表列和空态 `colSpan`
- [x] 更新 `.trellis/spec/flowscope-cli/backend/audit-api-spec.md`。
- [x] 运行验证命令。

## Validation

- `cargo test -p flowscope-cli audit`
- `yarn workspace app typecheck`
- 如改动触及共享 TS 类型，再跑 `just typecheck`。

## Validation Results

- PASS: `cargo fmt -p flowscope-cli --check`
- PASS: `git diff --check`
- PASS: `yarn workspace @pondpilot/flowscope-app typecheck`
- PASS: `cargo test -p flowscope-cli --features serve target_table`
- PASS: `cargo test -p flowscope-cli --features serve server::audit::tests`
- PASS: `cargo test -p flowscope-cli --features serve additive_migration_is_idempotent_on_existing_db`
- PASS: `cargo test -p flowscope-cli --features serve insert_and_query_round_trip`
- PASS: `cargo test -p flowscope-cli --features serve audit_records_target_table_for_insert_sql`
- PASS: `cargo test -p flowscope-cli --features serve audit_query_filter_by_target_table_exact_match`
- PASS: `yarn build` in `app/` completed Vite production build.
- PASS: synced `app/dist` to `crates/flowscope-cli/embedded-app/` for serve-mode embedding.
- PASS: `cargo build -p flowscope-cli --features serve` completed debug serve build.
- PASS: started backend at `http://127.0.0.1:3099` with `--watch data/watch-sql --audit-log data/audit.db`.
- PASS: started frontend at `http://127.0.0.1:3000/`.
- PASS: seeded `/api/analyze` with `INSERT INTO dw_conan.audit_target_table_ui_test SELECT id FROM ods_conan.source_users`; audit list returned `target_table = dw_conan.audit_target_table_ui_test`.
- PASS: browser page test at `/audit?target_table=dw_conan.audit_target_table_ui_test` showed the target table filter value, `Target table` column, and 1 matching record.
- PASS: browser Reset test cleared the target table input and URL parameter, then restored the unfiltered list.
- PASS: browser manual input test restored `target_table=dw_conan.audit_target_table_ui_test` in the URL and reduced the list to 1 record.
- PASS: browser console error log was empty during the audit page test.
- PASS: `git diff --check` after build/start/page validation.
- PASS: production precheck `cargo test -p flowscope-core --lib` passed (`1721 passed`).
- PASS: production precheck `python3 ./scripts/regression-test-sql.py` passed (`17 passed`, `0 failed`, `2 with warnings`).
- PASS: production frontend build `yarn build` in `app/` passed.
- PASS: production serve asset sync completed; `diff -q app/dist/index.html crates/flowscope-cli/embedded-app/index.html` had no output.
- PASS: production server build `env ZIG_GLOBAL_CACHE_DIR=/private/tmp/flowscope-zig-cache cargo zigbuild --target x86_64-unknown-linux-gnu.2.17 --target-dir target-zigbuild -p flowscope-cli --features serve --release` completed in `6m 28s`.
- PASS: production binary check reported ELF Linux x86-64 executable at `target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope`.
- PASS: production binary GLIBC check max version was `GLIBC_2.17`; `GLIBCXX_` check had no output.
- PASS: production binary local sha256 `bee8e0cdbf146d28005b443bc9000ea64cce85bf41785a5dba7aaf04b5cb7686`.
- PASS: uploaded production server binary with remote sha256 verification: `http://upload.zhenguanyu.com/uploads/4cfb4ef0_flowscope`.
- NOTE: `cargo test -p flowscope-cli audit` ran 0 tests because the audit module is behind the `serve` feature and the filter does not match non-serve tests.
- NOTE: `cargo test -p flowscope-cli` ran non-serve tests and failed in 5 unrelated `lint_cli` core-autofix cases (`CP005`, `LT013`, `JJ001`, `RF006`, `ST012`); audit/serve code is not compiled in that command.
- NOTE: `data/audit.db` was modified by the local page validation because the running server writes audit records there and migrates the local schema.

## Risk Points

- 审计 schema migration 顺序必须保持 `CREATE TABLE` -> additive migrations -> indexes。
- 列表接口不能返回大字段。
- `files[]` 模式当前每个文件写一条审计记录，但分析结果是整体结果；本次沿用现有 `sql_type/table_count` 语义，目标表同样来自整体 `AnalyzeResult`。
- 表格新增列会改变横向宽度，需要保持 `overflow-x-auto` 下不挤压文本。
