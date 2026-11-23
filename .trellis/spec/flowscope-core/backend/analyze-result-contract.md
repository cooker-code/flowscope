# Analyze Result Contract

> Scope: `flowscope_core::analyze()` and the serialized `AnalyzeResult`
> consumed by CLI, wasm, TypeScript packages, the demo app, VS Code, and
> downstream services.

## Scenario: Top-Level Physical Table Classification

### 1. Scope / Trigger

This contract applies whenever analyzer changes affect top-level
`AnalyzeResult.target_table` / `AnalyzeResult.source_tables` (JSON:
`targetTable` / `sourceTables`).

These fields are response-contract fields, not UI conveniences. Consumers
should not re-derive them from nodes and edges when `flowscope-core` can
classify them.

### 2. Signatures

Rust:

```rust
pub struct AnalyzeResult {
    pub target_table: Option<TableRef>,
    pub source_tables: Vec<TableRef>,
}
```

JSON:

```json
{
  "targetTable": { "qualifiedName": "db.target", "type": "table" },
  "sourceTables": [{ "qualifiedName": "db.source", "type": "table" }]
}
```

### 3. Contracts

- `targetTable` is the single physical table/view written by the workload.
- `sourceTables` contains every physical table/view read by the workload.
- CTEs, derived-table aliases, virtual output nodes, and columns must not
  appear in `sourceTables`.
- Self-dependent writes must include the same physical relation in both
  `targetTable` and `sourceTables`.
- Repeated reads of the same physical relation are deduplicated.
- Ordering is stable by qualified name, falling back to label.

### 4. Validation & Error Matrix

| Condition | Expected behavior |
|---|---|
| No physical sink | `targetTable` omitted |
| Exactly one physical sink | `targetTable` populated |
| Multiple physical sinks | `targetTable` omitted and `MULTIPLE_TARGET_TABLES` error emitted |
| Physical table read only | table appears in `sourceTables` |
| Physical table written only | table does not appear in `sourceTables` |
| Same physical table read and written | table appears in both fields |
| CTE or derived alias read | alias does not appear in `sourceTables`; underlying physical tables do |

### 4.1 Imported Schema Strictness

`SchemaMetadata.allowImplied=false` makes the supplied `tables` list
authoritative for external source-table resolution. A regular source relation
that is neither imported nor produced/declared by the SQL workload must emit
an `UNKNOWN_TABLE` **error**, so `summary.hasErrors` is true. This includes an
explicitly supplied empty schema: it means no external source tables are
available, not that metadata was omitted.

When schema metadata is absent, or when `allowImplied=true`, analysis remains
symbolic/best-effort: unknown source tables are not promoted to this strict
error. Existing unresolved-reference warnings in partial implied-schema mode
remain warnings. This rule is limited to unresolved regular source relations;
it must not promote unrelated resolver or SQL authoring warnings.

### 5. Good / Base / Bad Cases

Good self-dependent write:

```sql
insert overwrite table dw_ads.dm_eng_user_portrait_label_di
select a.user_id
from (
  select user_id
  from dw_ads.dm_eng_user_portrait_label_di
  where bunch = 'history'
) a;
```

Expected:

- `targetTable.qualifiedName == "dw_ads.dm_eng_user_portrait_label_di"`
- `sourceTables` contains `dw_ads.dm_eng_user_portrait_label_di`
- `sourceTables` does not contain `a`

Base write from another table:

```sql
insert overwrite table dw.tgt
select id from dw.src;
```

Expected: `targetTable = dw.tgt`, `sourceTables = [dw.src]`.

Bad classification:

```json
{
  "targetTable": { "qualifiedName": "dw_ads.dm_eng_user_portrait_label_di" },
  "sourceTables": []
}
```

This loses a real physical read and pushes every downstream consumer to
reconstruct source tables from graph internals.

### 6. Tests Required

For any change to table classification:

- Add or update a direct `flowscope_core::analyze()` regression test.
- Assert `targetTable.qualifiedName`.
- Assert `sourceTables` contains each physical source relation.
- Assert `sourceTables` excludes CTE names and derived aliases.
- For self-dependent writes, assert the physical target relation also appears
  exactly once in `sourceTables`.
- When possible, add a pinned SQL regression expectation for `sourceCount` and
  `sources`.

Canonical regression test:
`test_self_dependent_insert_keeps_target_in_source_tables` in
`crates/flowscope-core/src/analyzer/tests.rs`.

### 7. Wrong vs Correct

#### Wrong

Classify sources as "all physical tables except the sink":

```rust
nodes
    .iter()
    .filter(|n| n.node_type.is_table_or_view() && !sink_ids.contains(n.id.as_ref()))
```

This drops self-dependent physical reads because the same node can be both
source and sink after global graph flattening.

#### Correct

Classify sinks and sources independently from lineage edges:

```rust
// sink: physical endpoint on the `to` side of DataFlow / Derivation
// source: physical endpoint on the `from` side of DataFlow / Derivation /
// JoinDependency
```

This keeps write-only targets out of `sourceTables`, while preserving
self-dependent physical reads.

## SQL template fingerprint

- `AnalyzeResult` adds optional `sqlFingerprint` (lowercase SHA-256 hex) and
  `sqlFingerprintVersion` (`flowscope-sql-v1`). Missing fields on legacy results
  deserialize to `None`; TypeScript and `docs/api_schema.json` keep them optional.
- Compute in shared `analyze()` from original request templates before Hive's
  lossy preprocessing/template rendering. All HTTP, CLI JSON and wasm callers
  receive it without transport-specific implementations.
- V1 is conservative token normalization, not full SQL semantic equivalence:
  ignore ordinary comments, trivia, empty semicolon statements, known resource
  SET assignments and simple parameter names. Keep variable reuse relationships,
  embedded fixed text, business literals, map keys, expressions, hints, dialect,
  file boundaries/order and all participating inline SQL.
- Never hash the existing `parse_json` as template identity: Hive preprocessing
  currently removes map subscripts. `other['ip']` and `other['ua']` must have
  different fingerprints even when legacy graph output is identical.
- Do not infer parameters from fixed dates/numbers or erase macro calls. Unknown
  and semantic settings remain significant. Omit fingerprints on empty, oversized
  or untokenizable input instead of falling back to raw hashes. A fingerprint
  does not certify parse success: inspect the existing summary/issues as well.
- Existing graph IDs, raw audit hashes and downstream `task_sql_md5` are unchanged.
  Parser build, schema and dynamic bindings remain separate artifact context.
- Regression entry points: `tests/sql_fingerprint.rs`, the analyzer compatibility
  unit test, HTTP `serve_api`, TypeScript schema compatibility and `schema_guard`.
  The SQL fixture freezes local warehouse task 22679 for resource/variable-stable
  and source/map-key/business-condition-sensitive comparisons. V1 rules must not
  change silently; update the rule version for incompatible canonicalization.

## INSERT destination column provenance

1. Scope: `analyze()` annotates INSERT output destinations without changing SELECT
   labels or replacing value dependency edges. `Substring` visits its value,
   start and length expressions, including when nested in another function.
2. Contract: the target table's `metadata.insertTargetMapping` has
   `status`, `basis`, `columns` and `outputCount`; each resolved output's
   `metadata.insertTarget` has `table`, `column`, one-based `position` and `basis`.
3. Authority: use explicit INSERT columns before imported/DDL-seeded schema.
   Inferred source columns and SELECT aliases are not authoritative target order.
   Without either authority, omit the new contract for legacy compatibility.
   Exclude static partition columns; dynamic partition values occupy the suffix.
4. Errors: mismatched counts, wildcard/duplicate output identities or conflicting
   mappings across statements must remain unresolved. A column-level conflict
   must also invalidate its target table contract after graph flattening.
5. Example: `SELECT u.user_local` into a target position named `local` keeps the
   SELECT label while annotating the target column as `local`. Consumers must not
   infer target names from the SELECT label once a positional contract exists.
6. Tests: cover nested substring inputs, explicit column order, schema order,
   count mismatch, static/dynamic partitions and multi-statement conflicts. Real
   SQL regression must retain the original SQL and authoritative DDL and verify
   continuous column paths through the loader, not merely matching node labels.
7. Incorrect: silently keep the first statement's mapping on conflict or rename
   SQL outputs to make a target match. Correct: retain expressions/labels, carry
   the positional provenance and reject unresolved mappings in downstream loaders.
