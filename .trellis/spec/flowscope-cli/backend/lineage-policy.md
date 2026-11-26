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

## Policy and management API

- `GET /api/lineage/me`: trusted identity, current action, activeRevision, environment.
- `GET/POST /api/lineage/policies`: admin-only list/save.
- `DELETE /api/lineage/policies/{id} {revision}`: admin-only physical deletion.
- `POST /api/lineage/tokens {principalId}`: admin-only issue, raw token returned once.
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

Use policy/router unit tests, audit migration tests and existing serve tests.
Run ignored `lineage_http` tests with a task-owned loopback Neo4j to verify
scheduler/personal routing, idempotency, committed receipts across crashes and
revocation, unavailable Neo4j → restart recovery, and current-policy recheck.
Browser checks must cover save/active revision, token issue/hide/revoke, preview,
409, enable/disable/re-enable, delete/cancel/old-token 401, absence of removed
scope fields, personal 403, independent audit statuses, responsive layouts, and owned
browser/context/profile cleanup. Never replace server authorization with hidden
buttons or optimistic frontend save feedback.
