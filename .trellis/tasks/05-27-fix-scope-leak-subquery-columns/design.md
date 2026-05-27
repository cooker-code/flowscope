# Design: fix scope leak in resolve_subquery_columns

## Problem

`resolve_subquery_columns(name)` walks the scope stack from inner → outer, looking for a
subquery whose output columns are registered under `name`. If the inner scope has `name` as a
**physical table** (stored in `scope.tables`), there is no entry in `scope.subquery_columns`,
and the walk continues upward — where an outer scope may have a **different** derived subquery
also named `name`. That mismatch causes column nodes from the outer derived subquery to be
reused for the inner physical table, producing spurious Ownership edges.

## Fix Option A — Guard in `resolve_subquery_columns` (preferred)

Stop the upward walk as soon as a scope where `name` is registered as a **physical table alias**
is encountered. A physical table in scope shadows any outer derived subquery of the same name.

```rust
pub(crate) fn resolve_subquery_columns(&self, name: &str) -> Option<&[OutputColumn]> {
    for scope in self.scope_stack.iter().rev() {
        if let Some(columns) = scope.subquery_columns.get(name) {
            return Some(columns.as_slice());
        }
        // If this scope owns `name` as a regular table/alias (not a subquery),
        // stop the search here — outer scopes must not shadow inner tables.
        if scope.tables.contains_key(name) || scope.aliases.contains_key(name) {
            return None;
        }
    }
    self.aliased_subquery_columns.get(name).map(Vec::as_slice)
}
```

**Why this is correct:**
- If the current scope has `name` in `subquery_columns` → return it (unchanged).
- If the current scope has `name` in `tables` or `aliases` but NOT in `subquery_columns` → it
  is a physical table alias; outer scopes must not override it → return `None`.
- If the current scope has neither → continue walking outward (CTE references inherit fine).

## Fix Option B — Guard at the call site in `query.rs:1001`

Before calling `resolve_subquery_columns(qualifier)`, check whether `qualifier` is a physical
table in the **current** scope. If yes, skip the subquery-column lookup.

This is less robust because there are multiple call sites and the guard logic would need to be
duplicated. Option A is a single-point fix.

## Chosen Fix

**Option A** — modify `resolve_subquery_columns` in `context.rs`.

## Scope of Change

| File | Change |
|------|--------|
| `crates/flowscope-core/src/analyzer/context.rs` | Add early-exit in `resolve_subquery_columns` when a scope has `name` in `tables` or `aliases` |
| `crates/flowscope-core/src/analyzer/tests.rs` | Add regression test |

## Risk Assessment

Low. The change only adds an early-exit to an existing walk. Existing tests cover:
- CTE column inheritance across scopes
- Derived subquery alias resolution
- Self-join alias disambiguation

All these cases pass through `resolve_subquery_columns` without having the same alias in both
`subquery_columns` and `tables` of the same scope, so they are unaffected.
