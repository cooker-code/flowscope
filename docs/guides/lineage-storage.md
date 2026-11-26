# Rust lineage storage and caller policies

FlowScope can parse SQL and asynchronously persist either trusted lineage or
personal query footprints directly to Neo4j. The runtime consists of Rust
FlowScope, SQLite and Neo4j. It does not call neo4j-http-service or Python.
The new `flowscope-storage` crate owns normalization and graph transactions.
Ordinary CLI parsing and WASM do not write a database.

## Start a server

Build the app, copy its output into `crates/flowscope-cli/embedded-app`, then
build the CLI with `serve`, following the normal CLI serve build order. Use
`just build-cli-serve-debug` when `just` is available. Set
`FLOWSCOPE_PARSER_BUILD` at compilation to a unique release/build identifier;
without it the parser package version is recorded.

Copy `docs/examples/lineage-config.json` and adjust the Neo4j URI/environment.
Use an isolated candidate Neo4j instance for validation. The first event
initializes constraints and binds that database to the configured environment.
It does not migrate or replace unmanaged edges in a Python-maintained graph.

Set `FLOWSCOPE_NEO4J_PASSWORD` and `FLOWSCOPE_LINEAGE_ADMIN_TOKEN` in the server's
environment through your normal secret configuration. The bootstrap admin token
must contain at least 32 characters. The JSON contains environment variable
names, never secret values. A service restart uses the configured bootstrap
secret, so retain it in the deployment's secret store.

```bash
mkdir -p data
./target/debug/flowscope --serve --dialect hive --port 3099 \
  --audit-log data/audit.db \
  --lineage-config docs/examples/lineage-config.json
```

The audit path and `stateDb` must identify the same file. A configuration with
no `--lineage-config` preserves the existing parser/audit behavior and does not
start a graph writer. `allowAnonymousParse=true` is an explicit migration
option; anonymous calls can only parse and cannot create any Neo4j event.

Audit logs default to a rolling seven-day retention period, including existing
history. Administrators can change the positive integer day count in
`/policies`, below the caller list, or through `GET/POST /api/audit/settings`
with `{"retentionDays":7}`. Settings persist in the audit SQLite database.
Saving schedules background cleanup; it does not wait for historical deletion.
The worker deletes at most 200 audit rows per transaction after the listener
starts, preserves queued-event audit rows until processing ends, and retries
lock contention. SQL and saved analysis JSON in expired audit rows are deleted;
durable events, policies, credentials, and committed Neo4j lineage remain.
Freed SQLite pages are reused; online cleanup does not run a full `VACUUM`.

Open `/access` and supply your own token. Browser credentials stay in the current
tab's session storage; they are never embedded into the web assets or URLs.
An administrator can open `/policies` to register stable caller identities,
configure their enabled state and default action, and issue tokens. The token
list shows the full usable credential, including after reload or restart, and
omits revoked tokens. Internal token IDs remain available to the API for revoke
and historical references; the UI does not display them as credentials.

Authentication still uses token digests. Full values are stored as authenticated
ciphertext in SQLite and are returned only by the administrator-only policy
list. A 32-byte encryption key is generated beside the state database, at
`<stateDb>.tokens.key` (for example `data/audit.db.tokens.key`). On Unix, the
database and key file both use mode `0600`. Keep that key file with the database
during backup, restore and deployment. Do not include either in release packages.
Startup fails with an actionable error if encrypted values exist but the key is
missing, instead of silently replacing the key.

Legacy tokens stored only as digests cannot be recovered from their IDs. Their
first successful authenticated request captures the supplied value in encrypted
form without changing the token or its ID. Until then, the UI explains that the
full value will be available after the next successful call. Revoking a token
clears its saved ciphertext while retaining the disabled record for history.
Create normal administrator identities for daily operations. The `bootstrap`
identity and secret remain deployment-managed and are not listed as issued tokens.

## Configure behavior

| Caller/policy | Default effect |
| --- | --- |
| scheduler / publish | Queue a trusted source revision and update formal lineage if complete |
| person / record_usage | Record who submitted SQL, referenced tables and read/declared-write roles |
| observe | Keep the complete analysis event without formal or personal-use relations |
| parse_only | Parse and audit in SQLite, no Neo4j writes |

Policy fields are `id`, `name`, `kind`, `enabled`, `action`, `revision`.
The token identifies a caller; that caller's enabled state and default action
determine authorization. There are no caller environment, source or table
allow/deny lists. On startup, legacy scope fields are removed in one SQLite
transaction and each affected policy revision increments once. Existing tokens
remain valid. Personal source context is untrusted and cannot grant publishing
rights.

Save a new policy with revision 0, or edit using its current revision. The API
returns `activeRevision` only after the SQLite transaction commits; each request
and pending event checks committed policies directly. Concurrent edits return
409 and must be reloaded. Saving never automatically publishes historical SQL.
Preview uses the current form and optional historical audit ID without saving,
creating an event, or accessing Neo4j. Preview checks the caller's enabled state
and action. An enabled publish caller still needs valid SQL,
metadata and a newer source version before it can publish.

Disable a caller to reject its requests with 403 while retaining its tokens;
re-enable it to use the same tokens again. To physically delete a caller, send
`DELETE /api/lineage/policies/{id}` with JSON `{"revision": <current revision>}`.
The administrator-only transaction deletes the caller and all its token rows.
Subsequent requests with those tokens return 401. Historical audit rows, events,
policy changes and committed graph data remain. Deleted IDs cannot be reused,
so a newly created caller cannot inherit someone else's historical records.
Use a new ID when registering a replacement. Bootstrap cannot be disabled,
deleted or edited through this API; it is managed by deployment configuration.

Requests may reduce `publish`/`record_usage` to `observe` or `parse_only`.
An observe policy can reduce to parse_only. A parse_only token cannot upgrade.
Disabled identities and explicit privilege escalation return 403. Missing,
invalid and revoked tokens return 401. Personal audit/event access is restricted
to the same identity; administrators can inspect all audit rows. Anonymous legacy
rows are administrator-only. Server file listings are administrator-only.

## Call the same analyze endpoint

A scheduler does not need to send an additional publish request or select a mode
on every call. Its server-side policy selects publish. The caller must supply a
stable source ID and a monotonic numeric sourceVersion string; it must derive
that version from the scheduler's actual release/version order.
These fields identify the task and its graph revision; they are not additional
caller permissions. For example, one scheduler token can publish task 100 and
task 200, and their contributions remain distinct. `sourceSystem` and `sourceId`
use 1–128 ASCII letters, digits, `_`, `-` or `.`. Request environment must match
the deployment's configured Neo4j environment.

```json
{
  "sql": "INSERT OVERWRITE TABLE dw.target SELECT id FROM dw.source",
  "sourceName": "daily_target.hql",
  "schema": {
    "tables": [
      { "schema": "dw", "name": "source", "columns": [{ "name": "id", "dataType": "BIGINT" }] },
      { "schema": "dw", "name": "target", "columns": [{ "name": "id", "dataType": "BIGINT" }] }
    ]
  },
  "lineage": {
    "sourceSystem": "change",
    "sourceId": "123",
    "sourceVersion": "42",
    "analysisRevision": 0,
    "environment": "dev",
    "eventKind": "publish"
  }
}
```

Send this JSON to `POST /api/analyze` with `Authorization: Bearer <scheduler token>`.
The dialect is the server's `--dialect`. `schema` provides a per-request metadata
snapshot, otherwise the server's existing `--schema`/metadata configuration is
used. Missing physical metadata or unresolved INSERT target positions block
formal activation; they do not invent physical fields from aliases. Publish
rejects `hide_ctes=true` and `enable_column_lineage=false`.

A personal caller sends its own token and SQL, without trusted source context:

```json
{
  "sql": "SELECT user_id, SUM(amount) AS amount FROM dw.orders WHERE amount > 10 GROUP BY user_id",
  "sourceName": "个人订单分析"
}
```

Even a personal INSERT or fake `lineage` context cannot update formal lineage.
An explicit personal `storageMode=publish` returns 403. Personal records link
existing formal tables where possible and otherwise create separate
TABLE_REFERENCE nodes. They never create M_TABLE/Physical metadata. Full SQL and
analysis preserve columns, filters, joins, expressions and window details.
`execution_status=not_observed` means this is a parser submission, not evidence
that a database query ran successfully.

## Understand acknowledgement and recovery

The AnalyzeResult JSON body stays compatible. Read its `summary.hasErrors` for
parsing. Graph delivery is separate:

1. Validate identity, source and policy; parse SQL once.
2. Commit the complete event and audit links to SQLite.
3. Return `X-FlowScope-Event-Id`, `X-FlowScope-Action`, and
   `X-FlowScope-Storage-Status: queued`.
4. The Rust worker reconciles any prior Neo4j receipt, checks current policy,
   and applies the graph transaction. An in-flight transaction may finish under
   the policy checked immediately before apply.
5. Query `GET /api/lineage/events/{eventId}` using the same principal or an admin.
   Inspect `parseStatus`, `lineageStatus`, `usageStatus`, `status`, `reason` and
   `attempts`. The audit page shows these states independently.

`committed` only follows a Neo4j commit. `blocked` preserves the old valid graph;
`blocked_policy` means a pending event lost permission. `queued` survives network
failure and service restart. Retries are capped to one attempt per minute after
backoff, not discarded. A 30-second apply timeout is an unknown commit and is
reconciled with the original event ID. A revoked token cannot initiate another
write, but an already committed receipt remains committed on recovery.

Provide an `Idempotency-Key` header for caller retries. It is scoped to the
stable principal and at most 128 characters. Identical content returns the same
event and stored status without duplicate audit rows; changed content conflicts
with 409. A new request without that key is a new observation. Token rotation
keeps the same principal, so it does not split personal identity.

Source revisions compare `(sourceVersion, analysisRevision)` numerically inside
a graph lock. Old versions cannot roll back current lineage. Equal versions
with different content conflict. `eventKind=withdraw` with a newer version removes
only that source's current contributions; other producers remain. A failed new
candidate retains the previous valid lineage. Immutable history remains available.

SQLite's legacy audit result_json can still be truncated for very large results;
`lineage_events.body` retains the complete event without that limit. Use a
persistent disk and one FlowScope writer instance for this first implementation.
Multi-instance outbox coordination, retention management and PostgreSQL storage
are follow-up work, not implemented capabilities.

## Validation and current boundary

The first delivery supports token/policy management, the HTTP entry point,
versioned Neo4j transactions, personal usage, durable recovery, and the policy/audit
UI. It does not connect Change/Mario release feeds, import complete legacy CSV
snapshots, perform production cutover, fetch missing metadata automatically, or
implement PG. Source-specific sync metadata and full legacy rule parity must be
validated before activating those sources. Complex ambiguous joins, cross-file
CrossStatement projections and unsupported statement types are explicitly blocked.
Use the immutable analysis event to diagnose them; do not weaken the quality gate.

Run normal tests:

```bash
cargo test -p flowscope-storage
cargo test -p flowscope-cli --features serve --lib server::lineage::tests
cargo test -p flowscope-cli --features serve --test serve_api --test serve_integration
cargo clippy -p flowscope-storage -p flowscope-cli --features flowscope-cli/serve --all-targets -- -D warnings
```

Create a task-owned Neo4j Community container with Bolt bound only to loopback.
Set `FLOWSCOPE_TEST_NEO4J_URI` (host:port) and
`FLOWSCOPE_TEST_NEO4J_PASSWORD`. The storage integration test requires an empty
database and binds it to `isolated-test`; never use a production graph.

```bash
cargo test -p flowscope-storage --test lineage isolated_neo4j -- --ignored --nocapture
cargo test -p flowscope-cli --features serve --test lineage_http -- --ignored --nocapture
```

For browser regression, start an embedded CLI server with a separate SQLite
file and `environment=isolated-test`. Install Playwright in a disposable tools
directory (not a production dependency) and set `FLOWSCOPE_PLAYWRIGHT_MODULE` to
its module path, `FLOWSCOPE_TEST_BASE_URL`, `FLOWSCOPE_TEST_ADMIN_TOKEN`, and
`FLOWSCOPE_UI_EVIDENCE`. Optionally set `FLOWSCOPE_TEST_BROWSER_EXECUTABLE` to an
installed test browser. Run `node scripts/verify-lineage-ui.cjs`. It verifies the
isolated environment before mutation, uses unique test principals, saves
screenshots, and checks its browser processes and temporary profiles exited.

Frontend checks: `cd app && yarn test:lineage && yarn typecheck && yarn lint && yarn build`. The transport test suite runs in Node without DOM matcher setup.
