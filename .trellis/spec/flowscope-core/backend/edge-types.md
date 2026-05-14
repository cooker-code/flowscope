# Lineage Graph Edge Types

> Canonical reference for the edge types produced by `flowscope-core`'s
> lineage analyzer. Source of truth for both the Rust analyzer
> (`crates/flowscope-core/src/types/response.rs`) and the React renderer
> (`packages/react/src/constants.ts`, `Legend.tsx`).

---

## Scope

Defines:

- The 5 `EdgeType` variants emitted by the analyzer.
- When each one is created (decision points in the code).
- How each one is rendered in the React UI (color, line style, legend label).
- Which two types are **structural / not drawn** in the user-facing legend.

This document is the contract between analyzer (writer) and renderer
(reader). Adding a new edge type, or changing how an existing one is
emitted, must update this file.

---

## The 5 EdgeType Variants

```rust
// crates/flowscope-core/src/types/response.rs:759
pub enum EdgeType {
    Ownership,        // Table/CTE owns columns
    DataFlow,         // Data flows from one column/relation to another
    Derivation,       // Output derived from inputs (with transformation)
    JoinDependency,   // Join-only dependency from a source to output
    CrossStatement,   // Cross-statement dependency
}
```

| Variant | JSON (`type` field) | In Legend? | Visual |
|---|---|---|---|
| `Ownership` | `ownership` | No (structural) | — |
| `DataFlow` | `data_flow` | Yes | Solid grey line |
| `Derivation` | `derivation` | Yes | Dashed (`6 4`) purple line |
| `JoinDependency` | `join_dependency` | Yes | Dotted (`2 2`) green line |
| `CrossStatement` | `cross_statement` | No (only in multi-statement views) | — |

---

## Visual Specifications

Defined in `packages/react/src/constants.ts` (`COLORS.edges` + `EDGE_STYLES`):

| Variant | Light theme color | Dark theme color | `strokeDasharray` | Width |
|---|---|---|---|---|
| `DataFlow` | `#94A3B8` (slate-400) | `#8292AA` (blue-grey) | none (solid) | 2 |
| `Derivation` | `#8B5CF6` (violet) | `#A78BFA` | `6 4` (dashed) | 2 |
| `JoinDependency` | `#10B981` (emerald) | `#34D399` | `2 2` (dotted) | 2 |

Legend strings (in `packages/react/src/components/Legend.tsx`):

| Variant | Title | Subtitle |
|---|---|---|
| `DataFlow` | "Data flow" | "Direct movement" |
| `Derivation` | "Derivation" | "Transformation" |
| `JoinDependency` | "Join dependency" | "Join-only filter" |

---

## When Each Edge Is Created

### DataFlow vs Derivation — single decision point

The choice between these two is made by **whether the edge carries an `expression`**:

```rust
// crates/flowscope-core/src/analyzer/query.rs:1077
let edge_type = if params.expression.is_some() {
    EdgeType::Derivation
} else {
    EdgeType::DataFlow
};
```

**Rule**: Plain column passthrough → `DataFlow`. Any expression (function,
arithmetic, `CASE WHEN`, aggregate, `CAST`, `COALESCE`, etc.) → `Derivation`.

### JoinDependency — sink-side bookkeeping

Emitted by `add_join_dependency_edges` in
`crates/flowscope-core/src/analyzer/statements.rs:351`:

```text
For each node in `ctx.joined_table_info`:
  if it has NO DataFlow/Derivation edge whose target (directly or via owned
     columns) reaches the sink:
    emit a JoinDependency edge from that node to the sink.
```

In plain English: a table that **participates in a JOIN but does not
contribute any column** to the output gets a `JoinDependency` edge so it
still appears connected to the sink in the graph.

The edge usually carries `join_type` (`LEFT` / `INNER` / etc.) and
`join_condition` (the ON clause text).

### Ownership — purely structural

Emitted whenever a column node is created beneath a relation. Connects
`relation → column`. The UI uses this to determine container/membership,
not to draw a visible edge.

### CrossStatement — dbt and multi-file lineage

Emitted by cross-statement linking when a node (e.g., a dbt model relation
referenced via `ref(...)`) appears across statements/files. Carries
`[producer_index, consumer_index]` in `statementIds`.

---

## Worked Examples

### Example 1 — pure DataFlow

```sql
SELECT user_id, name FROM users;
```

Emits, among others:

- `users.user_id → output.user_id` — `DataFlow`, `expression = None`
- `users.name → output.name` — `DataFlow`, `expression = None`

### Example 2 — Derivation (transformations)

```sql
SELECT UPPER(name) AS upper_name, a + b AS sum_ab FROM t;
```

- `t.name → output.upper_name` — `Derivation`, `expression = "UPPER(name)"`
- `t.a → output.sum_ab` — `Derivation`, `expression = "a + b"`
- `t.b → output.sum_ab` — `Derivation`, `expression = "a + b"`

### Example 3 — JoinDependency (join-only table)

```sql
SELECT u.id FROM users u
LEFT JOIN orders o ON u.id = o.user_id;
```

- `users.id → output.id` — `DataFlow`
- `orders → output` — `JoinDependency`, `join_type = LEFT`,
  `join_condition = "u.id = o.user_id"`

`orders` contributes no column to the output, so it is connected via
`JoinDependency` rather than `DataFlow`.

### Example 4 — Derivation propagation in `transform.rs`

When the analyzer collapses an intermediate node (e.g., a virtual output
column folded into an INSERT target), the resulting bypass edge is
`Derivation` if **either** the incoming or outgoing edge was a
`Derivation`:

```rust
// crates/flowscope-core/src/analyzer/transform.rs:226
let edge_type = if out_edge.edge_type == EdgeType::Derivation
    || in_edge.edge_type == EdgeType::Derivation
{
    EdgeType::Derivation
} else {
    out_edge.edge_type
};
```

This means transformation provenance is **preserved through node
collapse** — once derivation enters the chain, it sticks.

---

## Invariants

1. `Ownership` edges always go **relation → column** (never the reverse).
2. `DataFlow` and `Derivation` represent **per-row data movement**;
   `JoinDependency` does NOT (it indicates only a JOIN-time presence).
3. `CrossStatement` is the only type whose `statementIds` may contain a
   **producer/consumer pair** rather than a single statement index;
   intra-statement edges may carry multiple statement indices but must
   all be statements in which the same `(from, to, kind)` triple appears.
4. Only `DataFlow`, `Derivation`, and `JoinDependency` can carry
   `join_type` / `join_condition`. `Ownership` and `CrossStatement` must
   not.

See `crates/flowscope-core/src/types/response.rs:543` for the formal
docstring on the `statementIds` invariant.

---

## Anti-Patterns

### Don't: emit `DataFlow` for transformations

```rust
// WRONG
ctx.add_edge(Edge {
    edge_type: EdgeType::DataFlow,
    expression: Some("CAST(x AS INT)".into()),
    ..Default::default()
});
```

`expression.is_some()` MUST imply `edge_type == Derivation`. Otherwise
the React renderer renders it as solid grey ("Data flow"), losing the
"this column was transformed" signal in the UI.

### Don't: synthesize `JoinDependency` for tables that already feed the sink

Before emitting a `JoinDependency`, check `contributes_to_output` exactly
the way `add_join_dependency_edges` does. Otherwise the graph gets a
duplicate edge (both a green dotted `JoinDependency` and a grey solid
`DataFlow` from the same table to the same sink), and the JOIN metadata
ends up on the wrong path.

See the regression test
`left_join_derived_subquery_does_not_leak_join_info_to_inner_table`
in `crates/flowscope-core/tests/lineage_engine.rs` for a case where a
derived subquery's inner table was being incorrectly marked as a JOIN
operand and triggered this exact failure mode.

---

## States (UI overlay, not an edge type)

The legend's "States" section colors the **selection state** of nodes,
not edges:

| State | Visual | Meaning |
|---|---|---|
| `Selected` | Filled blue circle (`#4C61FF`) | The node the user clicked |
| `Related` | Hollow blue circle | Upstream/downstream blast radius of the selection |
| `Recursive` | Hollow orange circle (`COLORS.recursive`) | Recursive CTE / self-join node (potential cycle) |

These are layered on top of any edge type and do not change which
`EdgeType` is rendered between nodes.

---

## Related

- `crates/flowscope-core/src/types/response.rs` — enum + JSON contract
- `crates/flowscope-core/src/analyzer/query.rs:1077` — DataFlow/Derivation decision
- `crates/flowscope-core/src/analyzer/statements.rs:351` — JoinDependency emission
- `crates/flowscope-core/src/analyzer/transform.rs:226` — derivation propagation through collapse
- `packages/react/src/constants.ts` — colors + dasharrays
- `packages/react/src/components/Legend.tsx` — legend rendering
- `.trellis/spec/flowscope-core/backend/analyzer-visitor-context.md` —
  visitor context save/restore rules (relevant when emitting these edges
  inside derived subqueries)
