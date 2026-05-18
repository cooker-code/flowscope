# AGENTS.md

> **Claude / Cursor users**: See [`CLAUDE.md`](./CLAUDE.md) for project-specific MANDATORY rules (language, bug handling, frontend protocol, Trellis workflow shortcuts).

## Scope

This file applies to the entire FlowScope monorepo.

## Repo Overview

FlowScope is a Rust + TypeScript monorepo.
Key areas:
- `crates/` Rust workspace (core engine, wasm, CLI, export).
- `packages/` TypeScript packages (`@pondpilot/flowscope-core`, `@pondpilot/flowscope-react`).
- `app/` demo web app (Vite + React).
- `vscode/` VS Code extension + `vscode/webview-ui`.

## Cursor/Copilot Rules

- No `.cursor/rules/`, `.cursorrules`, or `.github/copilot-instructions.md` found.

## Tooling Defaults

- Use `just` as the task runner (see `justfile`).
- Use `yarn` for Node workspaces.
- Use `cargo` for Rust workspace.
- Node.js 18+ and Rust 1.82+ expected (see `README.md`).

## Build Commands

- `just build` (WASM + TypeScript packages).
- `just build-rust` (Rust workspace debug build).
- `just build-rust-release` (Rust workspace release build).
- `just build-cli` (CLI release build).
- `just build-cli-serve` (CLI with embedded web UI, release build).
- `just build-cli-serve-debug` (CLI with embedded web UI, debug build).
- `just build-wasm` (runs `./scripts/build-rust.sh`).
- `just build-ts` (runs `yarn build:ts`).
- `just run` (build + dev server).

### CLI Serve Mode Build Order

The CLI serve feature embeds the web app using rust-embed at compile time. This requires the app to be built first:

1. `cd app && yarn build` - Build frontend assets to `app/dist/`
2. `cargo build -p flowscope-cli --features serve` - Compile CLI with embedded assets

The `just build-cli-serve` target handles this dependency automatically.

## Dev Commands

- `just dev` (Vite dev server at `http://localhost:5173`).
- `yarn dev` (from `app/` if you want direct Vite usage).
- `just cli -- <args>` (run CLI in debug mode).
- `just cli-release -- <args>` (run CLI in release mode).

### 本地开发完整启动顺序（前端 + 后端）

必须按以下顺序依次启动，**缺少任一步骤页面功能不完整**：

**Step 1 — 启动前端 Vite dev server（端口 3000）**

```bash
cd app && yarn dev
```

- 访问地址：`http://localhost:3000/`
- Vite 将 `/api/*` 请求反向代理到 `http://localhost:3099`
- 如需修改代理目标：`FLOWSCOPE_API_PROXY=http://localhost:9099 yarn dev`

**Step 2 — 编译并启动后端 CLI serve（端口 3099）**

```bash
# 首次或代码变更后需重新编译
cargo build -p flowscope-cli --features serve

# 启动服务（必须带 --audit-log 参数，路径相对于项目根目录）
./target/debug/flowscope --serve --port 3099 --audit-log data/audit.db
```

- 后端监听地址：`http://127.0.0.1:3099/`
- `--audit-log`：指定 SQLite 审计日志文件路径，**启动时必须携带**，否则审计功能不可用
- `data/audit.db` 目录需提前存在：`mkdir -p data`

## Lint, Format, Typecheck

- `just lint` (Rust + TypeScript lint).
- `just lint-rust` (`cargo clippy --workspace -- -D warnings`).
- `just lint-ts` (`yarn workspaces run lint`).
- `just lint-fix` (`yarn workspaces run lint:fix`).
- `just fmt` (Rust + TS formatting).
- `just fmt-rust` (`cargo fmt --all`).
- `just fmt-check-rust` (`cargo fmt --all -- --check`).
- `just fmt-ts` (runs Prettier across workspaces).
- `just typecheck` (`yarn workspaces run typecheck`).

## Test Commands

- `just test` (Rust + TS tests).
- `just test-rust` (`cargo test --workspace`).
- `just test-rust-release` (`cargo test --workspace --release`).
- `just test-ts` (`yarn workspaces run test`).
- `just test-core` (`cargo test -p flowscope-core`).
- `just test-cli` (`cargo test -p flowscope-cli`).
- `just test-cli-serve` (CLI tests with serve feature, builds app first).
- `just test-lineage` (`cargo test -p flowscope-core --test lineage_engine`).
- `just test-lineage-verbose` (same test with `--nocapture`).
- `just check-schema` (Rust schema guard + TS schema compatibility).
- `just coverage` (generate HTML coverage report in `coverage/`, requires `cargo-llvm-cov`).
- `just coverage-lcov` (generate LCOV file at `lcov.info` for CI/Codecov).
- `just coverage-summary` (print coverage summary to stdout).

## Workspace Utilities

- `just install` (install Node dependencies).
- `just setup` (install deps + tools + hooks + build).
- `just install-rust-tools` (installs `wasm-pack` and `cargo-watch`).
- `just install-hooks` (install `prek` hooks).
- `just clean` (cargo clean + remove node_modules).
- `just update-schema` (regenerate API schema snapshot).
- `just check` (fmt check + lint + typecheck + schema checks).
- `just check-all` (Rust + TS + schema compatibility).
- `just watch` (rebuild Rust workspace on changes).
- `just watch-test` (run Rust tests on changes).
- `just watch-lineage` (run lineage tests on changes).

## Package-Level Scripts

- `packages/core`: `yarn test`, `yarn test:watch`, `yarn lint`, `yarn typecheck`.
- `packages/react`: `yarn test`, `yarn test:watch`, `yarn lint`, `yarn typecheck`.
- `app`: `yarn dev`, `yarn build`, `yarn preview`, `yarn lint`, `yarn typecheck`.
- `vscode`: `npm run build`, `npm run build:webview`, `npm run watch`, `npm run typecheck`.
- `vscode/webview-ui`: `yarn build`, `yarn dev`, `yarn lint`, `yarn typecheck`.

## Single Test Tips

- Rust lineage tests: `just test-lineage-filter PATTERN`.
- Rust lineage tests (manual): `cargo test -p flowscope-core --test lineage_engine PATTERN`.
- Schema compatibility: `yarn workspace @pondpilot/flowscope-core test schema-compat.test.ts --silent`.
- For other Rust crates, use `cargo test -p <crate>` then filter with a test name if needed.

## Code Style (Rust)

- Follow standard Rust conventions (see `CONTRIBUTING.md`).
- Format with `cargo fmt` before committing.
- Lint with `cargo clippy` and fix warnings.
- Workspace uses Rust 2021 edition (see `Cargo.toml`).
- Avoid unused variables; if intentionally unused, prefix with `_`.
- Keep modules small and focused; `flowscope-core` uses a layered analyzer.

## Error Handling (Rust)

- Use `ParseError` for fatal parsing failures returned via `Result<T, ParseError>`.
- Use `Issue` for non-fatal analysis problems (collected and returned alongside results).
- `flowscope-cli` uses `anyhow::Result` with `Context` for CLI errors.
- `flowscope-export` and analyzer input use `thiserror::Error` for structured errors.

## Lineage Graph Edge Types

`flowscope-core` emits 5 edge variants (`EdgeType` in
`crates/flowscope-core/src/types/response.rs`). The choice is part of the
analyzer ↔ renderer contract — do not invent new types or change emission
rules without updating both sides and the spec below.

| Variant | JSON | Visual (light) | When emitted |
|---|---|---|---|
| `DataFlow` | `data_flow` | Solid grey (`#94A3B8`) | Plain column passthrough (`expression` is `None`). |
| `Derivation` | `derivation` | Dashed purple (`#8B5CF6`, `6 4`) | Column with any transformation: function, arithmetic, `CASE`, aggregate, `CAST`, etc. (`expression` is `Some`). |
| `JoinDependency` | `join_dependency` | Dotted green (`#10B981`, `2 2`) | A JOIN operand that contributes NO column to the sink. Carries `join_type` + `join_condition`. |
| `Ownership` | `ownership` | Not drawn (structural) | `relation → column` containment. Used by the UI for grouping, not as a visible edge. |
| `CrossStatement` | `cross_statement` | Only in multi-statement views | Cross-file / cross-statement linkage (e.g. dbt `ref(...)`). `statementIds` carries a `[producer, consumer]` pair. |

Key rules:

- `DataFlow` ↔ `Derivation` is decided by `expression.is_some()` at
  `crates/flowscope-core/src/analyzer/query.rs:1077`. NEVER set an
  `expression` on a `DataFlow` edge.
- `JoinDependency` is emitted by `add_join_dependency_edges`
  (`crates/flowscope-core/src/analyzer/statements.rs:351`) only for
  tables in `joined_table_info` that do not already reach the sink via
  `DataFlow`/`Derivation`.
- Through node-collapse in `analyzer/transform.rs:226`, `Derivation`
  "wins" over `DataFlow` — once a chain has a transformation, the
  collapsed edge stays `Derivation`.
- Frontend renderer reads colors/dasharrays from
  `packages/react/src/constants.ts` (`COLORS.edges`, `EDGE_STYLES`) and
  legend labels from `packages/react/src/components/Legend.tsx`. Keep
  these in sync with the Rust enum.

Full contract, worked examples, invariants, and anti-patterns:
[`.trellis/spec/flowscope-core/backend/edge-types.md`](./.trellis/spec/flowscope-core/backend/edge-types.md).

## Code Style (TypeScript)

- TypeScript is strict (see `CONTRIBUTING.md`).
- ESM modules are used (`"type": "module"`).
- Use single quotes and trailing commas in multiline structures.
- Prettier config:
  - `printWidth`: 100
  - `tabWidth`: 2
  - `semi`: true
  - `singleQuote`: true
  - `trailingComma`: `es5`
  - `arrowParens`: `always`
- ESLint config highlights:
  - `@typescript-eslint/no-unused-vars`: error, allow unused args with `_` prefix.
  - `@typescript-eslint/explicit-module-boundary-types`: off.

## Testing Expectations

- Add unit tests for new functionality (`CONTRIBUTING.md`).
- Add integration tests for complex features.
- Use fixtures under `crates/flowscope-core/tests/fixtures/` when needed.
- Keep test output clean; avoid noisy logs unless `--nocapture` is intended.

## Docs and Updates

- Update documentation and `CHANGELOG.md` if a change requires it (see `CONTRIBUTING.md`).
- Docs index and specs live in `docs/README.md`.
- Usage guides live in `docs/guides/`.
- The CLI usage details live in `crates/flowscope-cli/README.md`.
- Core engine overview lives in `crates/flowscope-core/README.md`.

## Releases (Single Tag)

Use a single repo tag for each release (`vX.Y.Z`) and align Rust workspace + npm package versions.

1. Update versions:
   - `Cargo.toml` workspace version + workspace dependencies
   - `packages/core/package.json`, `packages/react/package.json`, `packages/core/wasm/package.json`
   - Update peer dependency on `@pondpilot/flowscope-core` in `packages/react`
2. Update `CHANGELOG.md`:
   - Move Unreleased entries to `## [X.Y.Z] - YYYY-MM-DD`
   - Summarize changes per crate/package
3. Validate:
   - `just fmt-rust`
   - `just test-core`
   - `yarn workspace @pondpilot/flowscope-react build`
   - `yarn workspace @pondpilot/flowscope-core build`
4. Publish crates (order matters):
   - `cargo publish -p flowscope-core`
   - `cargo publish -p flowscope-export`
   - `cargo publish -p flowscope-cli`
5. Publish npm packages:
   - `yarn workspace @pondpilot/flowscope-core publish --access public`
   - `yarn workspace @pondpilot/flowscope-react publish --access public`
6. Tag + release:
   - `git tag vX.Y.Z`
   - `git push origin vX.Y.Z`
   - `gh release create vX.Y.Z --title "vX.Y.Z" --notes-file <notes>` (use CHANGELOG notes)

## Notes

- The demo app (`app/`) and VS Code webview (`vscode/webview-ui/`) currently define no tests.
- For full CI parity, `just check` runs formatting checks, lint, typecheck, and schema checks.

<!-- gitnexus:start -->
# GitNexus — Code Intelligence

This project is indexed by GitNexus as **flowscope** (16558 symbols, 37905 relationships, 300 execution flows). Use the GitNexus MCP tools to understand code, assess impact, and navigate safely.

> If any GitNexus tool warns the index is stale, run `npx gitnexus analyze` in terminal first.

## Always Do

- **MUST run impact analysis before editing any symbol.** Before modifying a function, class, or method, run `gitnexus_impact({target: "symbolName", direction: "upstream"})` and report the blast radius (direct callers, affected processes, risk level) to the user.
- **MUST run `gitnexus_detect_changes()` before committing** to verify your changes only affect expected symbols and execution flows.
- **MUST warn the user** if impact analysis returns HIGH or CRITICAL risk before proceeding with edits.
- When exploring unfamiliar code, use `gitnexus_query({query: "concept"})` to find execution flows instead of grepping. It returns process-grouped results ranked by relevance.
- When you need full context on a specific symbol — callers, callees, which execution flows it participates in — use `gitnexus_context({name: "symbolName"})`.

## Never Do

- NEVER edit a function, class, or method without first running `gitnexus_impact` on it.
- NEVER ignore HIGH or CRITICAL risk warnings from impact analysis.
- NEVER rename symbols with find-and-replace — use `gitnexus_rename` which understands the call graph.
- NEVER commit changes without running `gitnexus_detect_changes()` to check affected scope.

## Resources

| Resource | Use for |
|----------|---------|
| `gitnexus://repo/flowscope/context` | Codebase overview, check index freshness |
| `gitnexus://repo/flowscope/clusters` | All functional areas |
| `gitnexus://repo/flowscope/processes` | All execution flows |
| `gitnexus://repo/flowscope/process/{name}` | Step-by-step execution trace |

## CLI

| Task | Read this skill file |
|------|---------------------|
| Understand architecture / "How does X work?" | `.claude/skills/gitnexus/gitnexus-exploring/SKILL.md` |
| Blast radius / "What breaks if I change X?" | `.claude/skills/gitnexus/gitnexus-impact-analysis/SKILL.md` |
| Trace bugs / "Why is X failing?" | `.claude/skills/gitnexus/gitnexus-debugging/SKILL.md` |
| Rename / extract / split / refactor | `.claude/skills/gitnexus/gitnexus-refactoring/SKILL.md` |
| Tools, resources, schema reference | `.claude/skills/gitnexus/gitnexus-guide/SKILL.md` |
| Index, status, clean, wiki CLI commands | `.claude/skills/gitnexus/gitnexus-cli/SKILL.md` |

<!-- gitnexus:end -->
