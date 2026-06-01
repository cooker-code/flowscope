# PRD: fix scope leak in resolve_subquery_columns → MULTIPLE_TARGET_TABLES false positive

## Background

When a SQL workload uses `FULL OUTER JOIN` (or any join) with a nested subquery on the right side,
and the inner physical table has the **same alias** as an outer derived subquery, the analyzer
incorrectly reports `MULTIPLE_TARGET_TABLES` error, claiming the inner physical source table is
also a write target.

### Reproduction

```sql
INSERT OVERWRITE TABLE dw_dwd.dwd_eng_device_cpd_da PARTITION(dt='2024-01-01')
SELECT t.oaid
FROM (
    SELECT oaid, lower(md5(oaid)) AS oaid_md5
    FROM src_table WHERE dt = '2024-01-01'
) t                           -- outer derived subquery, alias = "t"
FULL OUTER JOIN
(
    SELECT oaid, lower(md5(oaid)) AS oaid_md5
    FROM (
        SELECT t.oaid
        FROM dw_dwd.dwd_eng_user_device_profile_da t    -- physical table, alias = "t"
        LEFT JOIN dw_dim.dim_eng_user_extend_da ext ON t.user_id = ext.user_id
        WHERE t.dt = '2024-01-01'
        GROUP BY t.oaid
    ) u
) d ON t.oaid_md5 = d.oaid_md5
```

**Actual:** `ERROR MULTIPLE_TARGET_TABLES: Workload writes to multiple physical tables
(dw_dwd.dwd_eng_device_cpd_da, dw_dwd.dwd_eng_user_device_profile_da)`

**Expected:** `target_table = dw_dwd.dwd_eng_device_cpd_da`, zero issues.

## Root Cause

`context.rs:706 resolve_subquery_columns(name)` iterates `scope_stack` from inner → outer:

```rust
for scope in self.scope_stack.iter().rev() {
    if let Some(columns) = scope.subquery_columns.get(name) {
        return Some(columns.as_slice());
    }
}
```

When analyzing the inner subquery `u`, it processes `SELECT t.oaid` where `t` is an alias for
the **physical table** `dw_dwd.dwd_eng_user_device_profile_da`. Since physical tables are stored
in `scope.tables` (not `scope.subquery_columns`), the inner scope has no entry under `t` in
`subquery_columns`. The loop then climbs to the **outer scope**, which DOES have `t` registered
as a derived subquery (the outer `FROM (...) t`). It returns `derived_t`'s column nodes.

This causes `query.rs:1039` to reuse `derived_t.oaid`'s node ID as `source_col_id`, and at lines
1060-1074 a spurious Ownership edge is created:

```
dwd_eng_user_device_profile_da → derived_t.oaid  (Ownership)
```

`classify_physical_tables` then sees `dwd_eng_user_device_profile_da` as owning a column that has
a DataFlow path to the sink, and misclassifies it as a second write target.

## Requirements

1. `resolve_subquery_columns(name)` must **stop at the innermost scope that physically resolves
   `name` as a table** (i.e., `scope.tables` contains `name`). A physical table in the current
   scope must shadow any outer derived subquery of the same name in `subquery_columns`.

2. Alternatively: the caller at `query.rs:1001-1011` must guard the `resolve_subquery_columns`
   call — if `name` resolves to a physical/regular table in the current scope, skip the subquery
   column lookup.

3. The fix must not break existing scope resolution for legitimate CTE/derived-subquery column
   references inherited from outer scopes.

## Acceptance Criteria

- [ ] The SQL in the Reproduction section produces `target_table = dw_dwd.dwd_eng_device_cpd_da`
      with zero issues (no `MULTIPLE_TARGET_TABLES`).
- [ ] A regression test covering the exact pattern is added to
      `crates/flowscope-core/src/analyzer/tests.rs` or `tests/lineage_engine.rs`.
- [ ] All existing tests in `flowscope-core` continue to pass (`cargo test -p flowscope-core`).
- [ ] The fix handles variants: `LEFT JOIN (subquery) t`, plain `FROM (subquery) t`, plus
      additional nesting levels — whenever an outer derived subquery alias shadows an inner
      physical table alias.

## Constraints

- Minimal and targeted fix — do not refactor scope stack or column resolution machinery beyond
  what is needed for this specific escape.
- No changes to public API types or serialization format.
