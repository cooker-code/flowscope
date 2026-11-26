# FlowScope storage contract

## Scope and dependencies

`flowscope-storage` depends on the public `flowscope-core::AnalyzeResult`. Core,
WASM and ordinary CLI operation must not depend on a database driver. The CLI
loads storage through the optional `serve` feature. Production writes are Rust
FlowScope → Neo4j over Bolt, with no Python service or interpreter.

## Public API

- `LineageStore::apply(&StorageEvent) -> Future<Result<ApplyOutcome, StorageError>>`
- `normalize(&StorageEvent) -> Snapshot`: pure conversion, no I/O.
- `Neo4jStore::connect(&Neo4jConfig, password)` initializes constraints and binds
  one database to one deployment environment.
- `Neo4jStore::receipt(&StorageEvent)` reconciles an unknown commit before the
  worker authorizes another mutation.

A future PG adapter implements the same event/normalization contract. Do not
add an unused PG adapter or introduce parser side effects.

## Identity and current graph

`SourceContext` identifies `environment:sourceSystem:sourceId`. `sourceVersion`
is a decimal, nonnegative i64 string; `analysisRevision` is a u32 correction
revision. Compare their numeric pair inside the source transaction lock.
Equal versions with different artifacts conflict; older versions are blocked.

Artifacts include SQL, dialect, parser build, normalized analysis, environment
and source context. Schema `updatedAt` is observational and excluded from
identity; all schema content stays in the full event. Raw SQL MD5 remains a
compatibility attribute and is never a business version.

Neo4j uses `LINEAGE_EVENT`, `LINEAGE_SCOPE`, `LINEAGE_REVISION`, `LINEAGE_FACT`
and `LINEAGE_EDGE` alongside the legacy labels. Indexed `LINEAGE_ENTITY.lineage_key`
identifies every projection endpoint. Each source contributes independent facts.
Acquire shared edge locks in sorted order. Deactivate old facts, insert the new
revision, and rebuild affected relations in one explicit transaction. Roll back
every mutation on any error. Only delete relations with this writer's
`projection_key`; never delete unmanaged legacy edges or shared physical nodes.

Compatibility graph: `M_TABLE`, `M_COL:Physical`, `M_COL:Derived`, `CTE`,
`TEMPLATE`, `SYNC`; `READS_FROM` goes upstream → downstream,
`REF_TABLE_COL` goes column → container, `DERIVES_COL` preserves value
transforms and target positional mapping, `CONTROLS_COL` preserves window roles.
A single-producer table may expose `task_sql_md5`; `producer_scopes` and current
facts remain authoritative when there are multiple producers.

The initial writer is for an isolated candidate database. It does not migrate
or take ownership of an existing Python-maintained production graph.

## Quality boundary

Formal activation requires error-free analysis, a supported single sink,
qualified physical identities, schema-backed physical columns and resolved
INSERT positional mappings. Keep the logical SELECT alias as Derived and use
`node.metadata.insertTarget.column` for the target Physical column. Unknown
metadata, star columns, approximate edges, ambiguous ownership/joins,
unsupported statements and CrossStatement projection block activation while
retaining the prior valid revision and the complete candidate event.

Never generate Physical columns from aliases or implied SELECT-only metadata.
Window controls do not become DERIVES_COL value sources. Do not infer a join
between its operand and the INSERT sink; recover the physical inputs, and block
ambiguous join scope rather than guessing.

## Personal usage

Only a scheduler principal can publish. Personal `record_usage` creates
`QUERY_ACTOR -SUBMITTED_QUERY-> QUERY_EVENT -USES_TABLE-> M_TABLE` when a unique
formal table already exists. Otherwise use an independent `TABLE_REFERENCE`.
It must never create/update formal tables, physical columns, formal facts or
production dependency edges. `usage_role` distinguishes `read` and
`declared_write`. `execution_status=not_observed` means a parser submission,
not verified database execution. Failed parsing can retain a QUERY_EVENT but
must not attach trusted USES_TABLE edges. Full SQL/analysis is linked through
LINEAGE_EVENT and also retained without truncation in the SQLite outbox.

## Driver gotcha and regression checks

Pinned driver: neo4rs 0.8, rustls transport, explicit transactions. Its negative
tiny integer decoder interprets `-1` as `255`. Read the initial source version
sentinels using `toString(...)` and parse i64 in Rust, with an error on malformed
values. Never silently default a failed version decode. The real integration
test must exercise first publication from the `-1` sentinel.

Required tests: position mapping, CTE/UNION, JOIN source endpoints, window
controls, schema gaps, first publish, A→T to B→T, stale/equal versions,
idempotency, personal INSERT, unknown personal tables, shared producers,
withdrawal, concurrent versions, and a constraint failure after old contribution
deactivation proving full rollback. Use a task-owned loopback Neo4j container;
normal unit test runs leave database tests ignored until explicitly configured.
