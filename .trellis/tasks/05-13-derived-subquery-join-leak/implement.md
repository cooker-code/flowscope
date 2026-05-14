# Implementation Notes — Derived Subquery JOIN Info Leak

## Outcome

Status: **DONE** — fix landed in working tree, tests + snapshot + spec updated.

## What Was Changed

1. **`crates/flowscope-core/src/analyzer/visitor.rs`** (`visit_table_factor`'s `TableFactor::Derived` branch)
   - **Register derived node into `joined_table_info`** when it appears as a JOIN's right operand (must happen BEFORE clearing `current_join_info`).
   - **Save+clear `current_join_info`** around the recursive `derived_visitor.visit_query(subquery)` call (mirrors the existing `last_operation` save/restore from commit `ec99c66`).
   - **Restore `current_join_info`** after recursion so that the subsequent `create_source_edge(node_id, outer_target)` call still sees the outer JOIN context.

2. **`crates/flowscope-core/tests/lineage_engine.rs`**
   - New regression test `left_join_derived_subquery_does_not_leak_join_info_to_inner_table` covering:
     - **Defect A**: no `join_type` on edges originating from inner real tables.
     - **Defect B**: no `JoinDependency` edge from inner table to sink.
     - Positive: derived node → sink retains `join_type = LEFT`.

3. **`crates/flowscope-core/tests/snapshots/snapshots__run_postgres_snapshot_test@postgres_lateral_join.snap`**
   - Updated to reflect corrected semantics for `JOIN LATERAL (SELECT ...) emp ON true`:
     - Spurious `inner_table → output` `join_dependency` edge removed.
     - JOIN labels migrated off internal column flows onto the correct outgoing column flows from the derived node.
     - `joinCount = 1` preserved (now backed by the derived `emp` node instead of the wrongly-registered inner table).

4. **`.trellis/spec/flowscope-core/backend/analyzer-visitor-context.md`** (new)
   - Captures the convention: any ambient `StatementContext` field read as side input by deeper visitors must be save/restored around recursive subquery visits.

## Validation

| Check | Result |
|---|---|
| New regression test | **PASS** |
| `cargo test -p flowscope-core` (full crate) | **PASS** (436 lineage + 26 snapshot + others) |
| Workspace `cargo test --workspace` | **PASS** except 2 pre-existing failures (`dali_merge_using_join_with_schema_refs`, `dali_bulk_column_refs_with_schema`) — verified to fail on `c85d5d4` as well |
| `cargo clippy -p flowscope-core` | 12 errors — all in files **not touched by this change** (e.g. `st_008.rs`); verified identical count with stashed working tree |
| `gitnexus_detect_changes --scope all` | `affected_processes: 0`, risk **LOW** (no symbol-level interface change) |
| End-to-end on real SQL (`dwd_eng_frog_user_devices_detail_chapter_finish_da.sql` via running `flowscope --serve`) | Only the **expected** `derived_b → target` `data_flow` edge carries `joinType: LEFT`. The two defective edges from the user report are **both gone**. |

## Files Outside Scope (Not Modified)

- `crates/flowscope-cli/src/server/api.rs`, others — have pre-existing `cargo fmt --check` violations unrelated to this task.
- `dali_compat_oracle.rs` MERGE tests — pre-existing failures unrelated to this task.

## Follow-up Suggestions (Not Done Here)

- Resolve the 2 pre-existing `dali_*` MERGE test failures separately.
- Resolve the 12 pre-existing clippy errors separately.
- Consider extracting the derived-subquery handler into a dedicated function for clarity (currently inline in `visit_table_factor`).
