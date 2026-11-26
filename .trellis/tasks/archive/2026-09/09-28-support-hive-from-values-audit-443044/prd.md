# Support Hive `FROM VALUES` for audit 443044

## Goal

Create a GitLab issue for the FlowScope parser failure in audit 443044, make the
existing Hive analysis entry point accept its `FROM VALUES` row source, and
verify the unchanged original SQL and its lineage locally.

## Confirmed evidence

- Audit 443044 occurred at `2026-09-26T16:42:16.887Z` with dialect `Hive`.
- SQL SHA-256: `b09425f3ca1f7d373f121644b122b995bed764039c43e32e59f8e6c07d132129`.
- The source is `一次性_新客存量模型2.1参数灌数_20260922` and the SQL is 112437 characters.
- The current CLI reproduces `PARSE_ERROR` at line 21, column 45:
  `Expected: joined table, found: ,` after `FROM VALUES`.
- The unchanged SQL parses under the existing Databricks dialect with no errors,
  target `temp.tmk_bpo_new_stock_model_2_0_sql_param_da`, no physical sources,
  and 49 graph edges.

## Requirements

- File the parser defect in `yuanli/flowscope` with the audit ID, time, source,
  hash, error, reproduction, and acceptance criteria. Reference the internal
  audit detail endpoint rather than embedding the full SQL in the issue.
- Enable `VALUES` as a table factor in FlowScope's Hive dialect only. Keep the
  existing rules for identifiers beginning with `_` unchanged; audits 442798,
  443020, and 443036 are outside this task.
- Add a compact regression through the public `analyze()` path. Recheck the
  unchanged original 443044 SQL locally without committing its large contents.
- Record fix and replay evidence in the issue. Leave production verification
  and issue closure pending until a deployed build is read back.
- Produce the Linux CLI serve package compatible with glibc 2.17 and matching
  frontend assets, then remind the user to redeploy the service. Do not
  represent a local package as a production deployment.

## Acceptance Criteria

- [x] GitLab issue exists in `yuanli/flowscope` with a stable link and no SQL body.
- [x] A compact `INSERT ... SELECT ... FROM VALUES` Hive request has zero error
  issues, the expected write target, and no physical source table.
- [x] Original audit 443044 SQL has zero error issues with `dialect=hive`, the
  expected target, no physical source tables, and a nonempty lineage graph.
- [x] Relevant core tests and repository SQL regression pass.
- [x] Issue contains the fix and local replay evidence and remains open for
  deployment and post-deployment audit verification.
- [x] Package exists with matching embedded frontend assets, Linux target and
  glibc versions checked, and checksum reported with a redeployment reminder.

## Notes

- Scope was narrowed by the user to audit 443044 only.
