# PRD: Audit log review page + lineage deep link + storage indicator

## Goals

1. **Audit list page** at `/audit`: filterable table + pagination; row opens lineage at `/?auditId=<id>`.
2. **Lineage page** (`/`): when `auditId` query param present, replace `FileSelector` trigger with `SqlPreviewCapsule` (drawer with full SQL + link back to `/audit`).
3. **Header**: in serve mode, replace watched-folder path with `StorageIndicator` (icon + storage type + truncated path; hidden when audit disabled).
4. **Backend**: extend `GET /api/audit` and `GET /api/config` per executable contracts below.

## API contract

### `GET /api/audit`

Existing: `limit` (default 50, max 500), `offset`, `from`, `to`, `endpoint`.

**New query params:**

| Param | Type | Semantics |
|-------|------|-----------|
| `sql_type` | string? | Exact match on `audit_log.sql_type` |
| `success` | bool? | `true` / `false` → `success = 1` / `0` |
| `file_name` | string? | `file_name LIKE '%' || input || '%'` (substring) |
| `keyword` | string? | `LOWER(sql_text) LIKE LOWER('%' || input || '%')` |

Empty strings treated as absent. List response still omits `sql_text` / `result_json`.

### `GET /api/config`

New optional field:

```json
"audit_storage": {
  "type": "sqlite",
  "location": "/path/to/audit.db",
  "enabled": true
}
```

When `--audit-log` not set: `enabled: false`, `type` and `location` may be `null`.

## UI acceptance

- [ ] `/audit` shows filters + table + pagination; disabled audit shows empty state message.
- [ ] Click row or "Open lineage" navigates to `/?auditId=N`.
- [ ] On `/` with `auditId`, toolbar shows capsule; opening drawer shows full SQL; "Back to audit list" goes to `/audit`.
- [ ] After deep link, editor shows SQL and graph uses `result_json` when present (no redundant analyze).
- [ ] Header shows SQLite + path when audit enabled; nothing when disabled.
- [ ] `just check` passes.

## Related spec

- `.trellis/spec/flowscope-cli/backend/audit-api-spec.md`
- `.trellis/spec/flowscope-app/frontend/ui-change-protocol.md`
