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

### 生产打包发布（UI + CLI 一致性 + 上传 CDN）

说"打包发布"就严格按下面步骤走，不要临时拼步骤。

> **约束**：生产分析在 CLI serve 后端跑，前端只走 REST，不需要 `wasm-pack`。
> 服务器是 CentOS 7 / glibc 2.17，**必须用 `cargo zigbuild`**，不能用 `cargo build` 或 `cross build`。

#### Step 0 — 预检

```bash
cargo test -p flowscope-core --lib           # 核心单测必须全绿
python3 ./scripts/regression-test-sql.py     # 真实 SQL 回归（要求 0 failed）
```

#### Step 1 — 构建前端

```bash
cd app && yarn build && cd ..
# 产物：app/dist/
```

#### Step 2 — 同步前端资产到 CLI 嵌入目录

```bash
rm -rf crates/flowscope-cli/embedded-app
mkdir -p crates/flowscope-cli/embedded-app
cp -R app/dist/. crates/flowscope-cli/embedded-app/
# 自检（无输出为正常）
diff -q app/dist/index.html crates/flowscope-cli/embedded-app/index.html
```

#### Step 3 — 交叉编译 Linux CLI（glibc 2.17）

`serve` 默认不包含原生 DuckDB 数据库文件导出；SQL 解析、HTTP 服务和 SQLite 审计不受影响。如部署 CLI 需要 `-f duckdb`，使用 `--features 'serve,duckdb'`。

```bash
cargo zigbuild \
  --target x86_64-unknown-linux-gnu.2.17 \
  --target-dir target-zigbuild \
  -p flowscope-cli \
  --features serve \
  --release
# 产物：target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
```

验证 glibc 版本（最高必须是 2.17，出现 2.18+ 立即排查）：

```bash
strings target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope \
  | grep '^GLIBC_' | sort -V -u | tail -3
```

#### Step 4 — 上传前端和 CLI 到 CDN

```bash
# 上传 H5 前端（zip 打包后上传）
cd app/dist && zip -qr "../../flowscope-h5-$(date +%Y%m%d-%H%M).zip" . && cd ../..
./scripts/upload-h5.sh   # 自动选最新 flowscope-h5-*.zip，上传并 sha256 校验

# 上传 CLI 二进制（直接上传，无需压缩）
./scripts/upload-h5.sh target-zigbuild/x86_64-unknown-linux-gnu/release/flowscope
```

两条命令各打印一个 `URL:`，记录备用。

#### Step 5 — 部署 CLI 到 Neo4j 服务器

将 Step 4 上传的 CLI CDN URL 交给运维，服务器侧使用独立的启动脚本完成部署和重启。

完整流程、回滚方案、双端一致性验证见 [`docs/release-workflow.md`](./docs/release-workflow.md)。

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
- `just regression-sql` (build release CLI + run `test-sql/*.sql` regression: headline-field assertions for `sqlType`/`insertType`/`targetTable`/`sourceTables`/`statementTypes`/`errorCount`, pinned in `test-sql/.regression-expect.json`).
- `just regression-sql-fast` (same regression, skip rebuild — for SQL fixture iteration).
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

`flowscope-core` emits 6 edge variants (`EdgeType` in
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
| `WindowControl` | `window_control` | Dotted sky-blue (`#0EA5E9`, `1 4`) | A `PARTITION BY` / `ORDER BY` input. It is not a value source; metadata carries `windowRole`. |

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

## Trellis 任务流程速查

| 阶段 | 工具 | 时机 |
|------|------|------|
| 恢复任务 | `/trellis-continue` | 新会话开始 / 中断后续做（自动路由到正确 phase） |
| 需求不清晰 | `/trellis-brainstorm` | 规划前 |
| 开始编码前 | `/trellis-before-dev` | 每次切换 package 时 |
| 发现 bug | `/trellis-break-loop` | **bug 修复后立即** |
| 编码完成 | `/trellis-check` | 提交前 |
| 沉淀经验 | `/trellis-update-spec` | break-loop 之后 |
| **任务收尾** | **`/trellis-finish-work`** | **work commit 之后立即（archive + 写 journal）** |
| 架构定制 | `/trellis-meta` | 修改 `.trellis/`、platform hooks、skills、commands 时 |

## Claro / Trellis / DocZ 收尾规则

当用户说“收尾”“task 收尾”“同步 claro”“补充 Claro task”“将 Trellis task 补充到 Claro”“把 `.trellis/tasks` 文档上传到 Claro/DocZ”等类似表达时，必须使用项目内 `.agents/skills/conan-claro-task-append/SKILL.md`。

如果当前 Codex 会话的自动 skill 清单没有注入 `conan-claro-task-append`，也必须手动读取该 skill，再按 canonical skill 完成闭环；不能因为 skill 未出现在注入列表中就跳过 Claro/DocZ 收尾。

收尾闭环至少包含：

- 创建或复用 Claro Task / Story，并挂到合适 Epic。
- 触发或人工落地 Claro Task `score` 估分；涉及周期计划时区分 `score` 与 `plannedScore`。
- DocZ 目录必须和 Claro Task 对应，上传 Trellis task 的关键文档，并把 DocZ 短链挂到 Claro Task artifacts。
- 用户语义是“收尾”时，必须将 Claro Task 状态推进到 `done`，并回读验证。
- 确认完成证据后归档 Trellis task，记录 journal，并提交本次收尾产生的本地改动。

常用 Claro Epic：

| 场景 | Epic |
| --- | --- |
| SQL 解析、SQL parser、lineage analyzer、审计页 SQL 解析能力 | `[E-4900471] SQL 解析` |
| Change 任务排查、Hive/表修改维护、无法明确归属的兜底任务 | `[E-4900415] Change 任务排查与表修改维护` |
| Neo4j 图谱修复、血缘图修复验证、图谱关系验证 | `[E-4900472] neo4j 图谱修复验证` |
| 广告投放、promotion、广告消耗、投放 Change/DS 需求 | `[E-4900490] 广告投放` |

---

<!-- TRELLIS:START -->
# Trellis Instructions

These instructions are for AI assistants working in this project.

This project is managed by Trellis. The working knowledge you need lives under `.trellis/`:

- `.trellis/workflow.md` — development phases, when to create tasks, skill routing
- `.trellis/spec/` — package- and layer-scoped coding guidelines (read before writing code in a given layer)
- `.trellis/workspace/` — per-developer journals and session traces
- `.trellis/tasks/` — active and archived tasks (PRDs, research, jsonl context)

If a Trellis command is available on your platform (e.g. `/trellis:finish-work`, `/trellis:continue`), prefer it over manual steps. Not every platform exposes every command.

If you're using Codex or another agent-capable tool, additional project-scoped helpers may live in:
- `.agents/skills/` — reusable Trellis skills
- `.codex/agents/` — optional custom subagents

Managed by Trellis. Edits outside this block are preserved; edits inside may be overwritten by a future `trellis update`.

<!-- TRELLIS:END -->
