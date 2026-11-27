# Indexed, bounded ingestion

## 1. Scope / trigger

Applies to Neo4j schema initialization, publication/replacement/withdrawal,
personal usage, and the durable worker's timeouts. Audit 651353 exposed repeated
full LINEAGE_FACT scans on every affected edge and unbounded sequential Bolt
round trips. A successful parse does not imply a graph commit.

## 2. Signatures

- `Neo4jStore::connect(config, password)` creates these RANGE indexes and awaits
  each named index ONLINE (`CALL db.awaitIndex($name, 60)`):
  - `flowscope_fact_edge`: `LINEAGE_FACT(edge_key)`
  - `flowscope_fact_scope_active`: `LINEAGE_FACT(scope_key, active)`
  - `flowscope_scope_target`: `LINEAGE_SCOPE(target_key, withdrawn)`
- `LineageStore::apply(&StorageEvent)` retains a single explicit transaction.
- `StorageError::database_code() -> Option<&str>` exposes only Neo4j's code.
- `PolicyDb::retry(id: String, reason: String)` stores the phase-specific reason
  in `lineage_events.last_error`, increments attempts, and schedules backoff.

## 3. Contracts

Entity/fact identities, relation types, version pairs, content hashes, receipts
and API status fields remain unchanged. `BATCH_SIZE=256` bounds UNWIND inputs;
all batches belong to the same transaction. Group entities by their existing
kind-specific MERGE keys. Validate affected row counts for facts/projections.
Acquire the globally sorted affected edge locks with explicit `ORDER BY key`
before changing active facts. UNWIND alone does not guarantee ordering.

Read affected histories in batches using the edge index. Keep the previous
`ORDER BY f.fact_key` metadata selection and deduplicate active SQL hashes and
source scopes. `frequency` counts distinct active SQL MD5s, not submissions.
Delete only managed `projection_key` relations using indexed endpoints; preserve
other producers, unmanaged legacy edges and physical nodes.

Personal batches can only attach USES_TABLE to existing M_TABLE or create
TABLE_REFERENCE; they must not introduce formal graph entities/facts.

The worker remains single-consumer because SQLite `next()` has no claim/lease.
Schema preparation has a 120-second connection budget, receipts 8 seconds, and
apply 30 seconds. Do not raise apply timeout as a substitute for index/batch work.
A timed-out commit remains unknown until the same event's receipt is reconciled.

## 4. Validation & error matrix

| Condition | Result |
| --- | --- |
| Missing password | queued, `neo4j_password_missing` |
| Connect/schema preparation exceeds budget | queued, `neo4j_connect_timeout` |
| Receipt exceeds budget | queued, `neo4j_receipt_timeout` |
| Apply exceeds 30 seconds | queued, `neo4j_apply_timeout` |
| Retryable driver error | queued, `neo4j_{connect|receipt|apply}_failed[:Neo4jCode]` |
| Policy database recheck fails | queued, `policy_recheck_failed` |
| Policy disabled/revoked, no committed receipt | blocked_policy |
| Statement/schema error during apply | failed, no repeated temporary retry |
| Missing batch endpoint or invalid relation kind | error and full rollback |
| SQLite finish fails after graph commit | log state-save phase, leave queued; receipt recovery |

Log safe event ID, phase/code, and successful apply `elapsed_ms`. Never persist
raw driver messages, authentication headers, passwords or SQL in retry reasons.
The old `neo4j_temporarily_unavailable` cannot identify a historical failure stage.

## 5. Good / base / bad cases

- Good: 130-column publication crosses entity/fact/projection batch boundaries,
  then replaces and withdraws with exact fact and endpoint counts.
- Base: replay preserves the same receipt and event counts; another producer
  retains a shared relation after one source replaces/withdraws.
- Bad: a constraint failure after deactivation must restore the previous active
  graph, with no receipt for the failed candidate.

## 6. Tests required

Run loopback-only native tests explicitly against a task-owned Neo4j:
`tests/lineage.rs` and `tests/throughput.rs::isolated_wide_batches_preserve_endpoints_and_withdraw`.
Run CLI HTTP recovery/policy/receipt tests and the retry-stage persistence test.
Ordinary test runs keep destructive/DB benchmarks ignored.

For performance, freeze old and candidate executables before measuring; verify
artifacts belong to the intended code (shared Cargo target caches can retain
mixed worktree outputs). Use the same SQL/analysis and initial graph, including
background facts, for each trial. Report sample count, build profile, first
publication vs replacement, min/max and median. Separate apply time, HTTP
acceptance time, queue-to-commit time, and measured short queue throughput.
Never report parsing audit `duration_ms` as ingestion latency or extrapolate a
small loopback debug sample into production capacity.

## 7. Wrong vs correct

Wrong: fact_key uniqueness exists, so every fact lookup is considered indexed;
refresh each edge with a label scan; start more identical `next()` loops.

Correct: inspect the actual `edge_key` and `(scope_key,active)` plans, prepare
matching indexes, batch inside one transaction, and retain the single worker
until concurrency has a tested atomic claim/order contract.
