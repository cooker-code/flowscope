# Audit retention and query maintenance

## 1. Scope / trigger

Apply to audit settings, historical deletion, type normalization, list queries,
and serve startup/shutdown. Durable lineage events have separate retry and
idempotency responsibilities and are outside audit retention.

## 2. Signatures

- Administrator GET/POST /api/audit/settings: `{"retentionDays":7}`.
- SQLite singleton `audit_settings(id=1,retention_days INTEGER NOT NULL)`,
  initialized with 7 using INSERT OR IGNORE; reopen must preserve saved values.
- `AuditWriter::maintain(stop)`: listener-bound background worker.
- `audit_retention::cleanup_batch(path,now)`: at most 200 rows per transaction.
- `idx_audit_sql_type_ts ON audit_log(sql_type,ts)`: built after listening and
  initial cleanup, never added to the synchronous historical startup scan.

## 3. Contracts

Use a positive u32 day count whose subtraction from UTC now yields a supported
nonnegative year. Strict `ts < cutoff` deletes expired audit rows and their SQL
and result JSON; equality stays. Use existing millisecond ISO UTC formatting.
The default applies to old databases as well as new ones.

Preserve audits linked to queued events until the event becomes terminal.
Do not delete events, caller/token/policy history, or committed graph data.
No-lineage audit databases must clean up without referring to nonexistent tables.

Settings writes run on a separate connection in spawn_blocking and notify
maintenance only after persistence succeeds. HTTP save must not await deletion.
Cleanup precedes type normalization, avoids loading expired JSON, commits small
batches, retries lock contention and stops between batches. Idle maintenance
wakes on configuration saves and otherwise runs every minute. Use WAL; do not
execute online full VACUUM or reuse the audit writer mutex for maintenance.

List count, filtering, paging and event metadata share a read snapshot when
lineage is configured. Batch metadata joins must not read event bodies.
Positive graph-status filters can select matching event IDs then use
idx_audit_event; retain outcome precedence, owner limits and unknown semantics.
Do not replace precise counts with guesses as a performance shortcut.

## 4. Validation and error matrix

| Input/state | Behavior |
| --- | --- |
| New database | retentionDays=7 |
| Reopen configured database | Preserve saved day count |
| Zero or unrepresentable cutoff | HTTP 400, previous setting unchanged |
| Negative/fraction/string/out-of-u32 JSON | HTTP 422 |
| Missing credential / non-admin | HTTP 401 / 403, no change |
| Missing management runtime / audit disabled | HTTP 503 |
| Queued event with expired audit | Preserve audit until processing ends |
| Writer holds transaction | Short maintenance busy timeout; retry later |
| Stop signal | Finish current bounded operation; no subsequent batch |
| Expired deleted ID | Detail 404; list count reflects deletion |

## 5. Good / base / bad cases

- Base: retain the last seven rolling days, not seven calendar date labels.
- Good: changing 7 to 3 commits settings immediately and wakes cleanup.
- Good: a WITH query still classifies from analyzed sqlType, independently of CTE.
- Bad: deleting lineage_events along with audit rows loses retry/idempotency state.
- Bad: creating large indexes or parsing all historical JSON before binding the
  listener repeats the historical startup outage.

## 6. Required tests

- Retention defaults, reopen, invalid input and administrator privilege boundary.
- Cutoff before/equal/after; pending-event protection and terminal cleanup.
- Bounded deletion, no event tables, lock contention, wakeup and cancellation.
- Real audit 652177 fixture classifies SELECT while statementType remains WITH.
- EXPLAIN from a fresh query connection uses the composite covering index with
  no temporary result sort. An already-open SQLite connection can cache schema
  for EXPLAIN; model the real per-request connection lifecycle.
- Large same-data before/after HTTP benchmark: retain total counts and page IDs,
  separately measure effects of indexes and historical deletion.
- Embedded-page tests: server default, save/reload, draft isolation, failure,
  invalid values, keyboard and narrow viewport; verify owned process exit.

## 7. Wrong vs correct

```rust
// Wrong: serving must wait for all expired rows and saved JSON.
cleanup_entire_history(&path)?;
let listener = TcpListener::bind(addr).await?;

// Correct: short independent maintenance operations after binding.
let listener = TcpListener::bind(addr).await?;
tokio::spawn(async move { audit.maintain(stop).await });
```

Page controls must read the saved server value. A failed GET must not display
an invented 7-day setting as though it were active.
