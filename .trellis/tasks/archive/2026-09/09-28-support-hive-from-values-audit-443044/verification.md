# Verification — audit 443044

## Local replay

- Original SQL was fetched from `GET /api/audit/443044` and kept outside the
  repository. Its SHA-256 matches the audit value
  `b09425f3ca1f7d373f121644b122b995bed764039c43e32e59f8e6c07d132129`.
- Before the change, Hive CLI returned `PARSE_ERROR` at line 21, column 45.
- After the change, the unchanged SQL under Hive has zero issues, one INSERT
  OVERWRITE statement, target
  `temp.tmk_bpo_new_stock_model_2_0_sql_param_da`, no physical source tables,
  34 nodes, and 49 edges (17 data_flow, 32 ownership).
- The `nodes`, `edges`, `targetTable`, `sourceTables`, `statements`, and
  `summary` JSON fields exactly match the Databricks reference replay.

## Checks

- `cargo test -p flowscope-core --lib`: 1725 passed, 0 failed.
- `scripts/regression-test-sql.py --dialect hive --sql-dir <original repo test-sql>`:
  18 passed, 0 failed; 2 fixtures had warning issues.
- `yarn workspace @pondpilot/flowscope-core test schema-compat.test.ts --silent`:
  3 passed.
- `cargo fmt --all -- --check`, `git diff --check`: passed.
- `cargo clippy -p flowscope-core --lib --tests -- -D warnings`: failed on
  14 existing warnings in unchanged analyzer/linter files; no warning location
  was in this change's files.

## Package

- `app/dist` was rebuilt and recursively compared with
  `crates/flowscope-cli/embedded-app` with no differences.
- `cargo zigbuild --target x86_64-unknown-linux-gnu.2.17 --target-dir
  target-zigbuild -p flowscope-cli --features serve --release`: passed.
- Binary format: ELF 64-bit x86-64; maximum symbol version `GLIBC_2.17`;
  no `GLIBCXX_` symbols found.
- Linux CLI SHA-256:
  `713bab44b954c884c83fb58c61867f1372557a3ec93f9a40910fdbfcc183d1ef`.
- Frontend ZIP SHA-256:
  `4fbe0bd63bb1a883d8e6f34d20f7e67a6f1ad14aab10e2d6ae33bb708519ce76`;
  ZIP integrity check passed.

Production deployment and post-deployment audit readback have not happened.
