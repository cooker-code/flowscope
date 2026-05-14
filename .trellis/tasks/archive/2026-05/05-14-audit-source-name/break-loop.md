# Break the Loop: Audit Schema Migration Order

## Bug (latent, caught by the migration test before shipping)

Test `additive_migration_is_idempotent_on_existing_db` failed with:

```
Failed to initialise audit schema: no such column: sql_type in
CREATE INDEX IF NOT EXISTS idx_audit_sql_type ON audit_log(sql_type);
```

### Root cause

`AuditWriter::new()` issued three steps in this order:

1. `execute_batch(CREATE_TABLE_SQL)` — but this batch **also contained
   every `CREATE INDEX` statement**, including `idx_audit_sql_type`.
2. `execute_batch(ADDITIVE_MIGRATIONS[*])` — adds `sql_type`, `source_name`.
3. (nothing)

On a fresh DB this works because step 1 creates the table *and* its
columns *and* the indexes atomically. **On a pre-v2 database** the
`CREATE TABLE IF NOT EXISTS` is a no-op (table already exists, no
`sql_type` column), then the very next `CREATE INDEX … sql_type` fails
because that column doesn't exist yet. Step 2 (which would have added
the column) never runs.

### Category

- A — Missing Spec (no rule said indexes must run after migrations)
- C — Change Propagation Failure (when `sql_type` was added to the schema,
  the migration was added but the **index was put in the wrong phase**,
  silently working only on fresh DBs)

## Fix

Three strict phases, never collapse:

1. `CREATE TABLE IF NOT EXISTS audit_log (...)` — **columns only, no indexes**.
2. Apply each `ALTER TABLE ... ADD COLUMN` migration (swallow
   `duplicate column name`).
3. `CREATE INDEX IF NOT EXISTS ...` — only after step 2 has guaranteed
   every referenced column exists.

`CREATE_TABLE_SQL` and `CREATE_INDEXES_SQL` are now two separate consts
to make this physically un-mixable in the source.

## Why fixes failed (would have)

If I hadn't written the legacy-DB migration test, this would have
shipped — the existing test fixtures and the manual `curl` flow all hit
fresh databases, where the bug is invisible. The bug only triggers on a
real upgrade path (pre-v2 → v3 db file on the dev/prod machine).
First-line lesson: **legacy-schema-restore tests are not optional** for
any schema-touching change.

## Prevention

| Priority | Mechanism | Status |
|----------|-----------|--------|
| P0 | Split `CREATE_TABLE_SQL` from `CREATE_INDEXES_SQL`, with comment forcing the order | DONE |
| P0 | "New Field Checklist" in spec — last item: write a legacy-DB test | DONE |
| P0 | Update `audit-api-spec.md` §2 "Migration order (CRITICAL — strict three-phase)" | DONE |
| P1 | Consider extending the checklist to a generic schema-evolution thinking guide if a third column-adding task lands | TODO |

## Knowledge Capture

- [x] `audit-api-spec.md` — three-phase migration order + new-column checklist
- [x] Comment in `audit.rs` explicitly explains why indexes are separated
- [x] `additive_migration_is_idempotent_on_existing_db` test pins the contract
