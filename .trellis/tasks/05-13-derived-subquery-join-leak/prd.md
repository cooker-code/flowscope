# Derived Subquery JOIN Info Leak

## Problem

When a `LEFT JOIN (SELECT ...) b` pattern is analyzed, the outer JOIN's
`current_join_info` (join_type + join_condition) is NOT save/restored
around the recursive `derived_visitor.visit_query(subquery)` call in
`visit_table_factor`'s `TableFactor::Derived` branch.

This causes two visible defects in the lineage graph:

### Defect A: extra JOIN-typed edge inside the derived subquery

A `data_flow` edge `inner_table → derived_b_node` is emitted with
`join_type = LEFT`, so the frontend renders a "LEFT JOIN" label on
what should be a plain internal column-flow edge.

User feedback: "单表对应的cte是不需要join类型的"

### Defect B: extra join_dependency edge from inner table to sink

`query.rs::create_table_node` (line 144) writes
`current_join_info` into `joined_table_info` for any table created
while `current_join_info.join_type.is_some()`. Because the outer LEFT
info is still active inside the recursive subquery visit, the inner
real table (e.g. `dim_eng_mission_da`) is wrongly registered as a
joined table. `add_join_dependency_edges` then synthesizes a
`JoinDependency` skeleton edge from that real table directly to the
sink, bypassing the derived node entirely.

User feedback: "这个绿色点线是不需要的，sql逻辑明确是从cte链路过来的，为什么多出了一根线"

## Root Cause (causal chain)

1. `visit_table_with_joins` sets `current_join_info.join_type = LEFT`
   before recursing into the JOIN's right relation.
2. The right relation is a `TableFactor::Derived` → branch creates
   the derived CTE-like node `b` and recursively
   `derived_visitor.visit_query(subquery)`.
3. Commit `ec99c66` already save/restored `last_operation` around this
   recursive call, but missed `current_join_info`.
4. So during the inner `visit_query`, all reads of `current_join_info`
   (in `create_source_edge`, `create_table_node`, `resolve_cte_reference`)
   still see the outer LEFT state.

The same root cause produces both defects via two different writers:

- `create_source_edge` → stamps `join_type` on `inner_table → b` edge (Defect A)
- `create_table_node` → writes inner_table into `joined_table_info`
  → later `add_join_dependency_edges` emits skeleton edge (Defect B)

## Scope of Fix

`crates/flowscope-core/src/analyzer/visitor.rs`, in
`visit_table_factor`'s `TableFactor::Derived` branch, mirror the
existing `last_operation` save/restore pattern for `current_join_info`.

Minimal change: 2 lines added (save + restore), no control-flow change.

## Acceptance Criteria

1. New regression test in `crates/flowscope-core/tests/lineage_engine.rs`
   covering the user's SQL shape passes.
2. `just test-lineage` and `just test-rust` show no regressions.
3. Audit log on the demo SQL `dwd_eng_frog_user_devices_detail_chapter_finish_da.sql`
   shows:
   - No `data_flow` edge `dim_eng_mission_da → b` carrying `joinType`.
   - No `JoinDependency` edge `dim_eng_mission_da → target`.
   - The `b → target` `data_flow` edge still carries `joinType = LEFT`
     and `joinCondition = "a.mission_id = b.mission_id"` (this is correct).

## Risk

`gitnexus_impact(visit_table_factor, upstream)` = HIGH (impacts 9
`analyze` flows + 6 `analyze_update` + 6 `analyze_merge`).

But the actual edit is purely additive save/restore — no logic change.
Risk is dominated by potential test churn, not behavior change.

## Related

- Commit `ec99c66` — sibling fix for `last_operation` (the other half).
