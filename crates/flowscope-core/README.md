# flowscope-core

Core SQL lineage analysis engine for FlowScope.

## Overview

`flowscope-core` is a Rust library that performs static analysis on SQL queries to extract table and column-level lineage information. It serves as the foundation for the FlowScope ecosystem, powering the WebAssembly bindings and JavaScript packages.

## Features

- **Multi-Dialect Parsing:** Built on `sqlparser-rs`, supporting PostgreSQL, Snowflake, BigQuery, DuckDB, Redshift, MySQL, SQLite, Databricks, ClickHouse, and Generic ANSI SQL.
- **Deep Lineage Extraction:**
  - Table-level dependencies (SELECT, INSERT, UPDATE, MERGE, COPY, UNLOAD, etc.)
  - Column-level data flow (including transformations)
  - Cross-statement lineage tracking (CREATE TABLE AS, INSERT INTO ... SELECT)
- **dbt/Jinja Templating:** Preprocess SQL with Jinja or dbt-style templates before analysis, with built-in stubs for `ref()`, `source()`, `config()`, `var()`, and `is_incremental()`.
- **Complex SQL Support:** Handles CTEs (Common Table Expressions), Subqueries, Joins, Unions, Window Functions, and lateral column aliases.
- **Schema Awareness:** Utilize provided schema metadata to validate column references and resolve wildcards (`SELECT *`).
- **Type Inference:** Infer expression types with dialect-aware type compatibility checking.
- **SQL Linting:** 72 lint rules across 9 families (AL, AM, CP, CV, JJ, LT, RF, ST, TQ) with AST-driven semantic checks and token-aware formatting checks. Rules include autofix metadata with safe/unsafe classification.
- **Diagnostics:** Returns structured issues (errors, warnings) with source spans for precise highlighting.

## Structure

```
src/
├── analyzer.rs              # Main analysis orchestration
├── analyzer/
│   ├── context.rs           # Per-statement state and scope management
│   ├── schema_registry.rs   # Schema metadata and name resolution
│   ├── visitor.rs           # AST visitor for lineage extraction
│   ├── query.rs             # Query analysis (SELECT, subqueries)
│   ├── expression.rs        # Expression and column lineage
│   ├── select_analyzer.rs   # SELECT clause analysis
│   ├── statements.rs        # Statement-level analysis
│   ├── ddl.rs               # DDL statement handling (CREATE, ALTER)
│   ├── cross_statement.rs   # Cross-statement lineage tracking
│   ├── diagnostics.rs       # Issue reporting
│   ├── input.rs             # Input merging and deduplication
│   └── helpers/             # Utility functions
├── linter/                  # SQL lint engine
│   ├── mod.rs               # Linter orchestration
│   ├── config.rs            # Rule configuration
│   ├── document.rs          # Document model (shared tokens)
│   ├── rule.rs              # Rule trait and context
│   ├── visit.rs             # AST visitor for rules
│   └── rules/               # 72 rule implementations
├── parser/                  # SQL dialect handling
├── types/                   # Request/response types
└── lineage/                 # Lineage graph construction
```

## Usage

```rust
use flowscope_core::{analyze, AnalyzeRequest, Dialect};

fn main() {
    let request = AnalyzeRequest {
        sql: "SELECT u.name, o.id FROM users u JOIN orders o ON u.id = o.user_id".to_string(),
        dialect: Dialect::Postgres,
        schema: None, // Optional schema metadata
        file_path: None,
    };

    let result = analyze(&request);

    // Access table lineage
    for statement in result.statements {
        println!("Tables: {:?}", statement.nodes);
        println!("Edges: {:?}", statement.edges);
    }
}
```

### SQL template fingerprints

Every public `analyze()` entry point (including HTTP, CLI JSON and wasm) adds
`sqlFingerprint` (64 lowercase SHA-256 hex characters) and
`sqlFingerprintVersion: "flowscope-sql-v1"` when the original input can be
tokenized. Old result JSON without these optional fields still deserializes.
Empty/comment-only/resource-only, oversized, or untokenizable inputs omit both
fields; analysis errors remain available through the existing issues/summary.

The v1 contract is **conservative token normalization**, not a claim that all
semantically equivalent SQL has the same fingerprint. It runs before Hive's
lossy compatibility preprocessing and before template rendering:

- Ignore ordinary comments, whitespace, empty semicolon statements and a fixed
  allowlist of Hive resource `SET` assignments (memory, cores, parallelism).
- Normalize unquoted words according to dialect case rules and Hive string
  quote styles. Preserve quoted identifier case, fixed literals, map/array keys,
  expressions, hints, SQL order, and file boundaries/order.
- Normalize simple `${name}`, `{{name}}` and `{{{name}}}` variable names by first
  occurrence. Keep repeated-variable relationships and fixed fragments around
  embedded variables. Macro calls/expressions retain their content.
- Include all `files[].content` followed by inline SQL, matching analysis input
  order. File/display names and imported schema are not SQL template identity.
- Include the SQL dialect and rule version, using length-framed token encoding.

Send unrendered templates: fixed date/number literals cannot safely be inferred
to be runtime parameters. Unknown or semantic SET options (timezone, UDF/object
configuration) remain significant. Resource directives must end with a semicolon
to be ignored. Runtime bindings, parser build, schema and dynamic object resolution
must be tracked separately before reusing a lineage artifact. The fingerprint is
neither a deployment version nor a replacement for existing node IDs/raw hashes;
this addition does not alter the graph, existing preprocessing or audit hashes.
Change the rule version if normalization changes.

### Linting

```rust
use flowscope_core::linter::{Linter, LintConfig, LintDocument};

let config = LintConfig::default();
let linter = Linter::new(config);
let document = LintDocument::new(sql, dialect);
let issues = linter.check_document(&document);
```

## Testing

```bash
cargo test
```

## License

Apache 2.0
