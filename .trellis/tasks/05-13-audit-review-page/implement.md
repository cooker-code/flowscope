# Implement: audit log review page

## Done

- Extended `GET /api/audit` with `sql_type`, `success`, `file_name`, `keyword` (see `AuditLogListFilters` in `audit.rs`).
- Extended `GET /api/config` with `audit_storage`.
- Added `serve_api` tests for filters + config.
- App: `react-router-dom`, `/audit` (`AuditPage`), `/?auditId=` deep link, `SqlPreviewCapsule`, `StorageIndicator`, `useLoadAuditRecord`.
- `project-store`: synthetic backend files for audit-only keys in `backendFileContentOverrides`; fixed active-file effect to honor override-only IDs.

## Validation

- `cargo fmt --all -- --check`
- `cargo test -p flowscope-cli --features serve --test serve_api`
- `cd app && yarn typecheck && yarn lint`
