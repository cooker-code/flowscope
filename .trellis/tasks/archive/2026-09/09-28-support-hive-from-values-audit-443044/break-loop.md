## Bug Analysis: Hive `FROM VALUES` in audit 443044

### 1. Root Cause Category

- **Category**: D (test coverage gap) and E (implicit dialect assumption).
- **Specific cause**: `FlowscopeHiveDialect` inherited the default
  `supports_values_as_table_factor() = false`, so a `FROM VALUES` literal row
  source was not recognized. The analyzer already understood the resulting
  `SetExpr::Values`; the missing parser option prevented that path from running.

### 2. Why Fixes Failed

No earlier code fix was attempted for this audit. The initial parse error
`Expected: joined table, found: ,` pointed at a comma inside the second row,
which could have misdirected triage toward editing the SQL. Inspecting the
source dialect and replaying the same SQL under Databricks isolated the option.

### 3. Prevention Mechanisms

| Priority | Mechanism | Specific action | Status |
| --- | --- | --- | --- |
| P0 | Regression | Test a short Hive `FROM VALUES` query through parser and public `analyze()` path | Done |
| P0 | Production replay | Compare unchanged audit 443044 Hive result with Databricks reference, including graph nodes and edges | Done locally |
| P1 | Documentation | Record the dialect-option boundary in the Hive compatibility spec and changelog | Done |
| P1 | Issue lifecycle | Keep issue open for deployment and subsequent audit verification | Open |

### 4. Systematic Expansion

- **Similar issues**: Other dialect options may reject valid workload syntax
  before the analyzer's existing visitor can see it. Inspect the concrete
  parser capability before adding text preprocessing.
- **Design improvement**: The shared dialect wrapper is the correct place for
  a grammar switch that needs no SQL transformation.
- **Process improvement**: Classify unsupported input syntax separately from
  a FlowScope dialect gap. Audits with underscore-leading aliases are outside
  this fix and require source SQL changes.

### 5. Knowledge Capture

- [x] Update `.trellis/spec/flowscope-core/backend/hive-compat-preprocess.md`.
- [x] Add parser and public analysis regressions.
- [x] Create GitLab issue 1 for rollout verification.
- [ ] Verify the deployed version against a later audit, then close the issue.

The skill's `src/templates/markdown/spec/` template sync target is absent in
this FlowScope repository, so there is no project template to update.
