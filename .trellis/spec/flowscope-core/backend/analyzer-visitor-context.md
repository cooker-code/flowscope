# Analyzer Visitor — Context State Management

> Conventions for managing the per-statement visitor context in
> `flowscope-core::analyzer` (especially `LineageVisitor` and friends).

---

## Scope

This document captures the rules for managing mutable per-statement
context fields on `StatementContext` (`crates/flowscope-core/src/analyzer/context.rs`)
that act as **ambient state read by side effects in deeper visitor
calls** — most importantly `current_join_info` and `last_operation`.

It is written because two independent bugs (commit `ec99c66` for
`last_operation`, then this task for `current_join_info`) shared the
same root cause: **outer-scope ambient state leaking into the recursive
analysis of a derived subquery**.

---

## The Convention (TL;DR)

> **When you recursively call into a nested analyzer/visitor whose
> semantics belong to a different lexical scope, save-and-restore every
> ambient `StatementContext` field that the inner visitor's helpers
> read as side input.**

Today this is exactly two fields:

| Field | Read by (writers of derived data) | Symptom if leaked |
|---|---|---|
| `ctx.last_operation` | `create_source_edge` (stamps `operation`) | Inner edges get a wrong `operation` label (e.g. `LEFT_JOIN` on a flow that isn't a JOIN) |
| `ctx.current_join_info` | `create_source_edge` (stamps `join_type`/`join_condition`); `create_table_node` and `resolve_cte_reference` (register node into `joined_table_info`) | Inner edges get a wrong `join_type` label; **inner tables get registered as joined operands**, which then makes `add_join_dependency_edges` synthesize spurious skeleton edges to the sink |

If a future PR adds a new ambient field with the same shape, **add it
to the save/restore block**, do not leave it for the next bug to find.

---

## Required Pattern (Derived Subquery)

`visit_table_factor`'s `TableFactor::Derived` branch is the canonical
example. The structure must be:

```rust
TableFactor::Derived { subquery, alias, .. } => {
    // 1. Create the derived node FIRST, while `current_join_info`
    //    still reflects the OUTER JOIN context (so we can register
    //    the derived node itself into `joined_table_info`).
    let derived_node_id = alias_name.as_ref().map(|name| {
        let id = self.ctx.add_node(Node { /* ... */ });

        // The derived node IS the joined relation when it appears
        // as the right operand of an outer JOIN. Register it now,
        // before we clear `current_join_info`.
        if self.ctx.current_join_info.join_type.is_some() {
            self.ctx
                .joined_table_info
                .insert(id.clone(), self.ctx.current_join_info.clone());
        }
        id
    });

    // 2. Save+clear EVERY ambient state field, then recurse.
    let saved_operation = self.ctx.last_operation.take();
    let saved_join_info = std::mem::take(&mut self.ctx.current_join_info);

    let mut derived_visitor = LineageVisitor::new(
        self.analyzer,
        self.ctx,
        derived_node_id.as_ref().map(|id| id.to_string()),
    );
    derived_visitor.visit_query(subquery);

    // 3. Restore so subsequent siblings in the SAME FROM/JOIN list
    //    still see the outer context (e.g. `create_source_edge`
    //    below relies on `current_join_info` being intact).
    self.ctx.last_operation = saved_operation;
    self.ctx.current_join_info = saved_join_info;

    // 4. NOW issue the outer source edge (uses restored ambient state).
    if let Some(outer_target) = self.target_node.as_deref() {
        self.analyzer.create_source_edge(self.ctx, &node_id, Some(outer_target));
    }
}
```

The order **(register derived → save/clear → recurse → restore → emit
outer source edge)** is intentional. Reordering it breaks at least one
of the two defects below.

---

## Anti-Pattern (and Why It Bites)

### Don't: skip save/restore on a recursive subquery visit

```rust
// WRONG — outer current_join_info leaks into the subquery
let mut derived_visitor = LineageVisitor::new(self.analyzer, self.ctx, ...);
derived_visitor.visit_query(subquery);
```

#### What goes wrong

For SQL like:

```sql
INSERT INTO target
SELECT a.user_id
FROM   (SELECT user_id, mission_id FROM source_a) a
LEFT JOIN (SELECT mission_id FROM source_b) b
       ON a.mission_id = b.mission_id
WHERE  b.mission_id IS NOT NULL;
```

Two visible defects appear in the lineage graph:

**Defect A — Join label leaks onto internal column flow**

`source_b → b` (a plain internal `data_flow` edge inside the subquery)
gets stamped with `join_type = LEFT` by `create_source_edge`, so the
UI renders an unwanted "LEFT JOIN" label.

**Defect B — Inner table gets registered as a joined operand**

`create_table_node` reads the leaked `current_join_info` and writes
`source_b` into `ctx.joined_table_info`. Later,
`add_join_dependency_edges` walks `joined_table_info` and synthesizes a
`JoinDependency` edge from `source_b` directly to `target`, completely
bypassing the derived `b` node. This is **the green dotted line a user
will rightly complain about**, because the SQL clearly flows through
the CTE-like derived node, not directly from the inner table.

#### Why a `last_operation`-only fix is incomplete

Commit `ec99c66` added the same save/restore but only for
`last_operation`. That alone fixed the wrong `operation` label, but
**did nothing for `join_type` / `joined_table_info`**, because those
are governed by a different ambient field (`current_join_info`). The
remaining half of the bug surfaced as the user-visible defects above.

---

## Gotcha: Derived Nodes Are Not Self-Registering

Plain tables register themselves into `joined_table_info` via
`create_table_node` (`query.rs`):

```rust
if ctx.current_join_info.join_type.is_some() {
    ctx.joined_table_info.insert(id.clone(), ctx.current_join_info.clone());
}
```

CTE instances register via `resolve_cte_reference` similarly.

But derived nodes are created **directly** in `visit_table_factor` with
`ctx.add_node(...)` — there's no equivalent registration step on that
path. **The caller must perform it explicitly** (see step 1 of the
pattern above).

Without that explicit registration, the derived node disappears from
`joined_table_info`, and `count_joins` / complexity scoring drop the
JOIN entirely. (The previous code "carried" the JOIN by accident, via
the inner-table leak — which is exactly what Defects A and B are
about.)

---

## Tests Required (Assertion Points)

For any change to derived-subquery handling, the regression test must
assert **both** halves:

```rust
// Defect A: no join_type on edges from inner tables of the subquery.
let leaked: Vec<&Edge> = stmt.edges.iter()
    .filter(|e| e.from == inner_table_id && e.join_type.is_some())
    .collect();
assert!(leaked.is_empty(), "join_type leaked into subquery: {leaked:?}");

// Defect B: no JoinDependency edge from inner table to sink.
let extra = stmt.edges.iter().find(|e|
    e.edge_type == EdgeType::JoinDependency
    && e.from == inner_table_id
    && e.to == sink_id
);
assert!(extra.is_none(), "spurious join-dep edge: {extra:?}");

// Positive: derived node → sink retains its join_type.
let legit = stmt.edges.iter()
    .find(|e| e.from == derived_node_id && e.to == sink_id)
    .expect("derived → sink edge missing");
assert_eq!(legit.join_type, Some(JoinType::Left));
```

Canonical regression test:
`left_join_derived_subquery_does_not_leak_join_info_to_inner_table`
in `crates/flowscope-core/tests/lineage_engine.rs`.

---

## Wrong vs Correct (Side-by-Side)

### Wrong

```rust
// Save only last_operation; current_join_info leaks.
let saved_op = self.ctx.last_operation.take();
let mut visitor = LineageVisitor::new(self.analyzer, self.ctx, ...);
visitor.visit_query(subquery);
self.ctx.last_operation = saved_op;
```

Symptom: inner-table edges carry a stale `join_type`, and the inner
table appears in `joined_table_info` for the wrong reason.

### Correct

```rust
let saved_op = self.ctx.last_operation.take();
let saved_join = std::mem::take(&mut self.ctx.current_join_info);
let mut visitor = LineageVisitor::new(self.analyzer, self.ctx, ...);
visitor.visit_query(subquery);
self.ctx.last_operation = saved_op;
self.ctx.current_join_info = saved_join;
```

Symptom: subquery internals are analyzed in a neutral context; outer
JOIN metadata is restored before the outer source edge is emitted.

---

## Related

- `crates/flowscope-core/src/analyzer/visitor.rs::visit_table_factor`
  (the `TableFactor::Derived` branch)
- `crates/flowscope-core/src/analyzer/query.rs` lines ~144, ~410, ~437
  (the three readers of `current_join_info`)
- `crates/flowscope-core/src/analyzer/statements.rs::add_join_dependency_edges`
  (consumer of `joined_table_info`)
- Commit `ec99c66` — sibling fix for `last_operation` (the other half
  of the same pattern)
