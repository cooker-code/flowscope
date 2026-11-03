# 提交计划（2026-11-03 已授权）

拟创建一个 work commit：`fix(hive): 修复LATERAL VIEW同名输出列限定引用及字段血缘`。用户于 2026-11-03 要求“提交代码到远端”，授权按此范围提交并推送到当前跟踪目标 origin/master。

## 本次修复

- crates/flowscope-core/src/analyzer/context.rs
- crates/flowscope-core/src/analyzer/expression.rs
- crates/flowscope-core/src/analyzer/select_analyzer.rs
- crates/flowscope-core/src/analyzer/visitor.rs
- crates/flowscope-core/tests/lateral_view_struct_lineage.rs
- crates/flowscope-core/tests/fixtures/hive_lateral_view_audit_559417.sql
- .trellis/spec/flowscope-core/backend/复杂类型CAST.md
- CHANGELOG.md

CHANGELOG.md 仅暂存本轮追加的 Fixed 条目；该文件原有的 sqlFingerprint Added 条目不包含在此次提交。

## 原有改动（全部排除）

- .github/workflows/ci.yml
- .trellis/spec/flowscope-core/backend/analyze-result-contract.md
- AGENTS.md
- CHANGELOG.md（仅原有改动排除，本轮 Fixed 条目单独暂存）
- Cargo.lock
- Cargo.toml
- README.md
- crates/flowscope-cli/Cargo.toml
- crates/flowscope-cli/README.md
- crates/flowscope-cli/src/main.rs
- crates/flowscope-cli/tests/export_cli.rs
- crates/flowscope-cli/tests/serve_api.rs
- crates/flowscope-core/Cargo.toml
- crates/flowscope-core/README.md
- crates/flowscope-core/src/analyzer.rs
- crates/flowscope-core/src/analyzer/global.rs
- crates/flowscope-core/src/lib.rs
- crates/flowscope-core/src/types/response.rs
- crates/flowscope-core/tests/common/mod.rs
- crates/flowscope-export/Cargo.toml
- crates/flowscope-export/README.md
- crates/flowscope-export/src/lib.rs
- crates/flowscope-export/tests/export_formats.rs
- docs/api_schema.json
- docs/release-workflow.md
- packages/core/src/types.ts
- packages/core/tests/schema-compat.test.ts
- crates/flowscope-core/src/sql_fingerprint.rs
- crates/flowscope-core/tests/fixtures/sql_fingerprint/
- crates/flowscope-core/tests/sql_fingerprint.rs

## 任务资料

本任务规划、验收与已纳入 Git 范围的原 SQL 证据随修复同一提交保存；按项目要求随后完成本地 task 归档与 journal。Claro/DocZ 同步不在本次 Git 提交请求范围内。原有其他改动继续排除。
