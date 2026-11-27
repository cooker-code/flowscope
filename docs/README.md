# FlowScope Documentation

This folder contains the canonical documentation for FlowScope. The public API and behavior are defined by the Rust/TypeScript code, and these docs are kept in sync with the current implementation.

## Document Map

## License

FlowScope code is released under Apache-2.0 unless stated otherwise. The `app/` directory uses the O'Saasy License; see `app/LICENSE`.

### Release & Deployment

- `release-workflow.md`
  **打包发布 SOP**：UI 与 CLI 一致性原理、`cargo zigbuild` 标准流程、上传 `https://upload.zhenguanyu.com/h5/`、Neo4j 服务器部署、回滚与排错。说"打包发布"就走这份。
- `build-for-neo4j-server.md`
  `cargo-zigbuild` 方案的背景与深度排错（必读一次）。

### Core References

- `architecture-overview.md`
  System-level overview of Rust, WASM, and TS layers.
- `workspace-structure.md`
  Monorepo layout, package relationships, and build entry points.
- `core-engine-spec.md`
  Behavior and responsibilities of the Rust analyzer.
- `api-types.md`
  API surface for the TS wrapper (mirrors `packages/core/src/types.ts`).
- `schema-handling-design.md`
  Schema metadata rules, implied schema capture, and resolution behavior.
- `column_lineage.md`
  Column lineage semantics and edge types.
- `dialect-coverage.md`
  Supported dialect list and high-level statement coverage.
- `sqlfluff-gap-matrix.md`
  Rule-by-rule SQLFluff vs FlowScope lint parity matrix.
- `linter-architecture.md`
  Principles and key design decisions for AST-first, token-aware lint architecture.
- `dialect_compliance_spec.md`
  Dialect normalization and scoping rules used by the analyzer.
- `comprehensive_dialect_rules.md`
  Source of truth for dialect semantics in `crates/flowscope-core/specs/`.
- `error-codes.md`
  Issue code reference for `AnalyzeResult.issues`.

### Features

- `librarian.md`
  AI-powered chat panel for SQL lineage Q&A using data lineage and uploaded PDF docs.

### Guides

- [FlowScope 入图原理、提速与个人查询记录](guides/lineage-ingestion-personal-usage.zh-CN.md)

- `guides/quickstart.md`
  TypeScript quickstart and usage patterns.
- `guides/schema-metadata.md`
  How to pass schema metadata for better lineage.
- `guides/error-handling.md`
  Interpreting issues and handling partial results.

### Generated Artifacts

- `api_schema.json`
  JSON schema snapshot generated from Rust types.
- `crates/flowscope-core/src/generated/`
  Rust code generated from `crates/flowscope-core/specs/dialect-semantics/` via `build.rs`.

### Release Docs

- `publishing.md`
  NPM publishing flow for `@pondpilot/flowscope-core`.

- [Rust lineage storage and caller policies](guides/lineage-storage.md)
