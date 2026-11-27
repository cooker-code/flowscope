# Analyze identity, policy and durable graph writes

## Entry points

`flowscope --serve --lineage-config <JSON>` enables strict Bearer identity and
same-process Rust Neo4j storage. The JSON contains `stateDb`, `neo4j` and optional
`allowAnonymousParse` (default false), `adminTokenEnv`. `--audit-log`, when also
supplied, must name the same SQLite path. Required secrets are read from the
named environment variables; no raw token or Neo4j password goes in SQLite or
configuration JSON. Without this configuration, existing parse-only CLI/serve
behavior is preserved.

Canonical usage/configuration: `docs/guides/lineage-storage.md`.

## HTTP contract

`POST /api/analyze` preserves the AnalyzeResult body. Optional body additions:
`lineage: SourceContext`, `storageMode` / `storage_mode`, and `schema` (the core
SchemaMetadata shape). A request schema is a snapshot for this analysis only.
The server dialect still comes from CLI configuration.

Return `X-FlowScope-Request-Id`, `X-FlowScope-Event-Id`, `X-FlowScope-Action`,
`X-FlowScope-Storage-Status`. `queued` only means a complete SQLite event and its
audit links committed. It never means Neo4j committed. Parse-only has no graph
event and returns `not_requested`. Replayed idempotency keys return the stored
status. Body `summary.hasErrors`, event `lineageStatus`, and `usageStatus` are
independent. Loopback CORS permits Authorization and Idempotency-Key and exposes
these response headers.

`GET /api/lineage/events/{id}` is restricted to the principal or an administrator.
It returns `parseStatus`, `status`, `lineageStatus`, `usageStatus`, `reason`,
`policyRevision` (the accepted revision), and retry attempts.

## Ingestion monitoring

### Scope / trigger

Apply when changing queue statistics, ingestion throughput or the audit-page
monitor. An empty filtered audit list does not imply an idle writer; historical
quality blocks do not imply pending work.

### Signatures

`GET /api/lineage/metrics` requires the normal Bearer identity. No filter or
pagination parameters change its scope. The response has `scope` (`all`/`own`),
`action` (`publish`/`record_usage`), `sampledAt`, `lastAcceptedAt`, `queued`,
`retrying`, `blocked`, `failed`, `committed`, and `rate`:

```json
{"monitoringSince":"2026-11-27T02:00:00Z","windowSeconds":60,"observedSeconds":60,"warmingUp":false,"confirmedEvents":3,"eventsPerMinute":3.0}
```

The background audit-maintenance worker builds the covering index
`idx_lineage_ingestion_monitor(action,principal_id,status,attempts)` after
listening and cleanup. Do not add a synchronous startup scan or deserialize
`lineage_events.body` to calculate totals.

### Contracts

- Administrators see all formal `publish` events. Schedulers see their own
  `publish` events. Persons see their own `record_usage` events, irrespective of
  the caller's currently reduced default action.
- Counts are events, not per-file audit rows, nodes, edges or attempts.
  `retrying` is the subset of `queued` with `attempts > 0`. `blocked` includes
  `blocked_policy`; neither is queued.
- `lastAcceptedAt` is the latest accepted audit timestamp in the identity scope,
  including observations/parse-only requests. Rejected authentication never
  enters the analyze handler and is absent from this timestamp and audit log.
- Throughput is the count of first local confirmations in the sliding previous
  60 seconds. Increment only after SQLite changes `queued` to `committed` for
  `publish`/`record_usage`. Receipt recovery counts as a confirmation, not proof
  of a new physical Neo4j mutation. Repeated finalization and replay do not count.
- The meter is process-local and uses monotonic time. It resets on restart,
  prunes expired samples, and exposes `eventsPerMinute: null` for the initial
  60-second warm-up. Persistent queue totals survive restart.
- The page polls every five seconds even with zero visible rows; requests do
  not overlap. Activity changes quietly reload the current list query, keeping
  URL filters/page. An activity update during initial loading must still clear
  the loading state when its replacement request completes. Unmount aborts
  requests and removes timers.

### Validation and error matrix

| Condition | Result |
| --- | --- |
| Missing/invalid credential | 401; no global metrics leaked |
| Disabled caller | 403 |
| Storage not configured | 503 |
| Initial 60 seconds | `warmingUp=true`, rate null; show warm-up |
| Complete idle window | rate 0 |
| Transient monitor failure | Keep timestamped last snapshot with stale notice |
| 401/403/404/503 in UI | Clear old snapshot and stop polling |

### Good / base / bad cases

- Good: today's audit list is empty, but the monitor still shows the global
  queue, retry subset and last accepted timestamp.
- Base: two files in one accepted event produce two audit rows and one event.
- Bad: count blocked receipts or retry attempts as successful ingestions, show
  a benchmark as live throughput, expose another person's totals, or infer that
  a successful scheduler run means its HTTP UDF calls succeeded.

### Required tests

Assert warm-up, window expiry, action/owner isolation, duplicate finalization,
per-file/event distinction and covering-index use. Verify real HTTP-to-Neo4j
completion increments once, independent UI polling for an empty queue, stale
error recovery, authentication failure, quiet list reload and cancellation.

### Wrong vs correct

```rust
// Wrong: counts every attempt, including quality blocks and replay.
// meter.record(...); store.apply(&event).await;
// Correct: count only a durable first successful confirmation.
if db.finish(id, "committed", outcome, None).await? {
    meter.record(&event.principal_id, event.action);
}
```

## Policy and management API

- `GET /api/lineage/me`: trusted identity, current action, activeRevision, environment.
- `GET/POST /api/lineage/policies`: admin-only list/save.
- `DELETE /api/lineage/policies/{id} {revision}`: admin-only physical deletion.
- `POST /api/lineage/tokens {principalId}`: admin-only issue, full token also remains
  available in the administrator-only policy list while not revoked.
- `POST /api/lineage/tokens/{id}/revoke`: admin-only revocation.
- `POST /api/lineage/policies/preview {policy,auditId?}`: admin-only,
  no persistence or Neo4j access. A historical event can show analysis quality issues.

A policy has `id`, `name`, `kind` (scheduler/person/admin), `enabled`, `action`,
`revision`. Token → caller → enabled state/default action is the complete
authorization rule. Do not reintroduce source/environment/table permission
fields in the UI or backend. Legacy fields migrate away transactionally on
startup, incrementing affected revisions once without replacing tokens.
Save revision 0 to create; edits must carry the current revision. A transaction
increments it and returns `activeRevision`; runtime authorization reads the
committed policy directly. No cache can report an unswapped revision as active.

Scheduler publish requires task identity/version context; personal record_usage can never
become publish. Any caller may reduce to parse_only. Publish/record_usage may
reduce to observe, while parse_only cannot upgrade to observe. Task context is
for ownership/versioning, not an allow-list: one token can submit multiple
tasks. Source system/ID must be 1–128 ASCII alphanumeric, underscore, hyphen or
period characters; request environment must match the deployment. Self-reported
personal source context cannot confer trust.

Disable preserves the caller and tokens; all subsequent calls return 403.
Re-enable restores use of the same tokens. Physical deletion checks revision,
then deletes tokens and caller in the same SQLite transaction. Old tokens
return 401 and pending events fail policy recheck. Keep audit/events/graph and
policy change history. Retired IDs cannot be reused, preventing identity-based
history access from passing to a new caller. A stale delete returns 409 and a
missing caller returns 404. Deployment-managed bootstrap cannot be edited or
deleted. The UI must display enabled state and require an explicit delete
confirmation describing retained history and graph data.

## SQLite and worker boundary

Use one persistent SQLite file and one FlowScope writer instance. Apply the
existing audit base table → additive migrations → indexes sequence. Add
principal_id/event_id to audit rows; keep anonymous legacy rows unowned.
Token table stores SHA-256 of cryptographically random opaque tokens and a
revocable token ID. Principals remain stable across token rotation.

## Recoverable token display

### Scope / trigger

Apply when changing token storage, policy list responses or the Token management
section in `PolicyPage`. A management ID is not a usable Bearer credential and
must not be displayed in its place.

### Signatures

- `lineage_tokens.secret_ciphertext BLOB NULL` is an additive, idempotent migration.
- `GET /api/lineage/policies` returns only enabled, non-bootstrap tokens, with
  `id`, `principalId`, `enabled`, `createdAt`, and `token: string | null`.
- Issuance and policy-list responses include `Cache-Control: no-store` and require
  a server-verified administrator identity.

### Contracts

The display value is the exact issued `fst_...` credential. Authentication keeps
using its SHA-256 digest. `TokenVault` encrypts recoverable values with AES-256-GCM,
a fresh system-generated nonce, and the token ID as authenticated associated
data. Do not persist raw token values in SQLite, logs or project files.

Generate a 32-byte key at `<stateDb>.tokens.key`, independent of the bootstrap
admin credential so bootstrap rotation preserves issued values. Create it with
Unix mode `0600`, sync it before storing ciphertext, and preserve it across
restart/backup/restore. Never regenerate a missing key when ciphertext exists.

For a legacy hash-only token, capture the supplied value only after its hash,
enabled state and requested action validate successfully. Keep the ID, digest,
caller and permissions unchanged. A not-yet-recovered legacy value is `null`;
show a clear explanation, never substitute the UUID. Revocation disables the
record and clears its ciphertext. Retain its ID for event history but omit the
record from both the API list and the UI.

### Validation and error matrix

| Condition | Result |
| --- | --- |
| Newly issued token / normal restart | Admin list returns the exact full value |
| Scheduler or personal caller requests token list | 403, no credential disclosure |
| Legacy token before successful use | `token: null`, explain next successful use |
| Invalid or revoked credential | 401, no capture |
| Disabled caller or disallowed action | 403, no capture |
| Revocation | Remove from list, saved ciphertext cleared, subsequent auth 401 |
| Key missing with encrypted records | Startup error instructing restoration |
| Corrupt ciphertext or mismatched record ID | Generic `token_secret_unavailable`; no plaintext |

### Good / base / bad cases

- Good: reload the page and copy the same usable credential from an active row.
- Base: an unchanged legacy token becomes visible after its next successful call.
- Bad: display the UUID under Token, claim hash-only values can be recovered,
  rotate old credentials automatically, or expose revoked values.

### Required tests

Verify admin-only access and no-store headers; exact value after restart and
bootstrap rotation; hash-only migration/backfill and repeat startup; ciphertext
confidentiality/integrity/record binding; key permissions and missing-key refusal;
revoke hiding and auth rejection. Browser checks cover full-token wrapping,
reload, no UUID substitution, old-token explanation, immediate revoke removal
and empty state, including narrow viewports and browser resource cleanup.

### Wrong vs correct

```tsx
// Wrong: presents a management record ID as the credential.
<code>{token.id}</code>
// Correct: render the full value or the explicit legacy state.
token.token ? <code>{token.token}</code> : <span>下次成功调用后可显示完整值</span>
```

## Durable event processing

Non-parse-only events store full SQL and full AnalyzeResult in lineage_events,
without the legacy audit result_json truncation. Enqueue and per-file audit
inserts share one SQLite transaction. Do not also send those entries through
the old asynchronous audit channel. Blocking SQLite calls run in spawn_blocking.

Before a new graph mutation, the worker reads a matching Neo4j receipt first,
then checks the current token/principal/enabled/action policy.
A prior committed receipt remains committed after revocation. A queued request
without a receipt can be blocked by a newly saved policy. Authorization takes
effect immediately before apply; a transaction already started may complete.
Transient connection/unknown-commit failures keep the durable event queued and
retry with the same event ID. Reconcile a timeout's unknown commit on replay.

## Authorization and status matrix

| Case | Required result |
| --- | --- |
| Missing/invalid/revoked/deleted credential | 401, no graph event accepted |
| Disabled principal / privilege escalation / wrong deployment environment | 403 |
| Missing context / invalid numeric version / incomplete render options | 400 |
| Same policy revision saved concurrently | 409 |
| Same Idempotency-Key with different content | 409 |
| Incomplete parse/schema | parse outcome preserved, formal status blocked |
| Personal INSERT/fake source context | usage only, no formal mutation |
| Queue commit but Neo4j unavailable | queued, separate from parser success |
| Own audit/event | allowed |
| Another principal's audit/event | 403 |
| Legacy audit rows without owner | administrator only |
| Policy preview | writesGraph=false, no new event or graph mutation |

`/api/files` and `/api/audit/files` require an administrator when storage is
configured. Personal audit list/detail always enforce ownership server-side.
The web app forwards a user-entered session token only to same-origin `/api/`
URLs, never to AI endpoints or remote origins. A personal file-list 403 is an
empty server-files view, so their own audit details can still open.

## Required verification

### Audit graph status contract

#### Scope / trigger

Apply this contract when decorating audit list/detail responses or presenting
the audit table's graph-write outcome. Parser success and graph commit are
independent; absence of historical evidence cannot establish a storage decision.

#### Signatures

`GET /api/audit` and `GET /api/audit/{id}` expose `lineage_status` and
`usage_status`, decorated by `PolicyDb::decorate_audits`. These are response
fields derived from the audit owner/event and event outcome; adding a UI column
does not require another SQLite column.

#### Contracts

| `lineage_status` | Audit label | Meaning |
| --- | --- | --- |
| `committed` | 已入图 | Formal Neo4j write committed |
| `queued` | 待入图 | Durably accepted; pending, processing or retrying, not confirmed committed |
| `blocked`, `blocked_policy` | 未入图 | Analysis, metadata or policy checks prevented writing; show `policy_reason` |
| `failed` | 入图失败 | Graph write failed without a confirmed commit |
| `not_requested` | 未请求入图 | Explicit request policy did not request formal graph updates |
| `unknown` | 入图状态未知 | Historical graph-write evidence is unavailable |

Unowned legacy rows without an event return `unknown` for both status fields.
Owned parse-only rows without an event return `not_requested`. A linked event
and its outcome take precedence over these defaults. An unavailable, null or
unrecognized frontend value is displayed as unknown, never as not requested.
The personal usage column remains independent of the formal graph column.

`queued` covers the active worker attempt as well as waiting/retry. A terminal
`blocked` / `blocked_policy` result does not retry automatically. A quality
rejection can occur even when parsing succeeded, and leaves the prior valid
formal lineage unchanged.

Each blocked/failed row exposes its actual nullable `policy_reason` through the
status badge on hover, keyboard focus, click and touch. Known issue codes receive
Chinese explanations; qualified table/column names and unrecognized codes remain
complete. Compound `incomplete_analysis:` checks may be deduplicated for display,
but the expandable original reason must preserve the full response string.
Missing details say that the backend has not recorded a specific reason.
`neo4j_temporarily_unavailable` is a coarse retry cause, not evidence of a specific
connection, query or timeout failure. Do not infer that a token with publish
permission guarantees a committed graph write.

Use one scrollable, portaled explanation panel at a time so table overflow does
not clip it. Click/touch pins the panel; Escape returns focus. Stop click
propagation on both trigger and portaled contents, including the original-reason
expander, to avoid opening the audit row. Header-legend badges remain static.
Reasons that describe personal-only usage must not become formal-graph reasons
for `not_requested` rows.

#### Validation and error matrix

| Input / condition | Required behavior |
| --- | --- |
| Legacy audit has no owner or event | List and detail both report `unknown` |
| Authenticated parse-only audit has no event | Report `not_requested` |
| Parser success with event `queued` | Display 待入图, not 已入图 |
| Frontend receives missing/null/unrecognized status | Display 入图状态未知 |
| Open click/touch help while a hover tooltip exists | Show one explanation panel |
| Click a row status or expand its original reason | Keep the audit list open |
| Blocked/failed row has no reason | Explicitly show missing backend details |
| Reason contains 120 checks | Keep all items and raw text accessible by scrolling |

#### Good / base / bad cases

- Good: a queued row becomes 已入图 only after a refreshed server response says
  `committed`.
- Base: an old ownerless audit is 入图状态未知; its SQL may have been ingested
  through another path, so this audit cannot answer whether it was written.
- Bad: defaulting every missing event or status to 未请求入图, or treating parser
  success as confirmation of a graph commit.

#### Tests required

- `audit_unknown_history_is_distinct_from_explicit_parse_only` must assert
  unknown historical list/detail values and explicit parse-only values.
- Browser checks cover all six labels, `blocked_policy`, missing/null fallback,
  hover/click/keyboard/touch help, light/dark readability and pending-to-committed
  refresh. Explain unknown as missing evidence, not proof of no graph mutation.
- Reason formatter tests cover compound checks, deduplication, complete targets,
  unknown codes, missing details and long lists. Browser reason checks also cover
  row-navigation isolation, original-reason expansion, a pinned panel surviving
  queued-row polling, and viewport bounds at desktop and 390px touch sizes.

#### Wrong vs correct

```typescript
// Wrong: no evidence is treated as an explicit policy decision.
const label = status ?? 'not_requested';
// Correct: missing evidence stays unknown.
const label = status ?? 'unknown';
```

### Broader lineage verification

Use policy/router unit tests, audit migration tests and existing serve tests.
Run ignored `lineage_http` tests with a task-owned loopback Neo4j to verify
scheduler/personal routing, idempotency, committed receipts across crashes and
revocation, unavailable Neo4j → restart recovery, and current-policy recheck.
Browser checks must cover save/active revision, token issue/hide/revoke, preview,
409, enable/disable/re-enable, delete/cancel/old-token 401, absence of removed
scope fields, personal 403, independent audit statuses, responsive layouts, and owned
browser/context/profile cleanup. Never replace server authorization with hidden
buttons or optimistic frontend save feedback.

### Worker diagnostics and performance

The retry reason stores a safe failure phase/code rather than a generic outage.
Connection/schema preparation, receipt lookup and apply have separate budgets.
See [Indexed, bounded ingestion](../../flowscope-storage/backend/ingestion-performance.md)
for exact signatures, reasons, timeout boundaries and required recovery tests.
