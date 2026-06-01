# Implement: fix scope leak in resolve_subquery_columns

## Ordered Checklist

- [ ] 1. Edit `context.rs:resolve_subquery_columns` — add early exit when scope owns `name` as physical table/alias
- [ ] 2. Add regression test in `tests.rs` — full outer join nested subquery, same alias inner physical table
- [ ] 3. Run `cargo test -p flowscope-core` — all tests must pass
- [ ] 4. Verify the original SQL from `test-sql/multarget.sql` produces single target, zero MULTIPLE_TARGET_TABLES issues

## Validation Commands

```bash
cargo test -p flowscope-core                        # all unit tests
cargo test -p flowscope-core "full_outer_join"      # regression test
cargo test -p flowscope-core --test lineage_engine  # integration tests
```

## Rollback

Revert the single edit to `context.rs:resolve_subquery_columns`. No migration or config change needed.
