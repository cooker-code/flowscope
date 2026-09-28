# Design

## Boundary and cause

The audit API returns the original SQL. `flowscope_core::analyze()` selects
`FlowscopeHiveDialect` for `Dialect::Hive`. That wrapper delegates the
`supports_values_as_table_factor` trait method to its default (`false`).
`sqlparser` recognizes bare `FROM VALUES (..), (..)` only when this method is
true. Existing analyzer visitors already handle `SetExpr::Values`.

## Change

Override `supports_values_as_table_factor()` to return `true` in the FlowScope
Hive dialect. Do not rewrite source SQL or enable a different dialect for all
Hive requests. This keeps the fix in the shared production analysis path.

Add a parser-level example and a public `analyze()` regression with a short,
synthetic `INSERT OVERWRITE ... SELECT ... FROM VALUES` SQL. Preserve the
112437-character production SQL only in a private local replay file.

## Issue and release boundary

The GitLab issue records audit metadata and the exact failure; it links the
restricted audit detail endpoint for reproduction. Local success, packaging,
deployment, and disappearance of post-deployment failures are separate facts.
The issue stays open until deployment and follow-up audit evidence are checked.
If the regression reveals a different parser or lineage defect, keep the issue
open and extend the fix with a new test before declaring success.

The local packaging step builds `app/dist`, syncs it into the CLI serve embed
directory, and cross-compiles with the repository's glibc 2.17 Zig target.
The package checksum identifies what must be deployed; no deployment is
performed by this task.
