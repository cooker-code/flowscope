# flowscope-export

Database export helpers for FlowScope analysis results.

## Overview

`flowscope-export` provides utilities to export `flowscope-core` lineage results to database and report formats. Native DuckDB database-file export is optional; the other exports do not compile DuckDB.

## Features

- `duckdb`: Export lineage to a DuckDB database file. Enable it explicitly with `features = ["duckdb"]`.
- SQL export: Generate DDL + INSERT statements for DuckDB (WASM-friendly).
- Mermaid export: Script/table/column/hybrid diagrams.
- CSV archive: ZIP bundle of structured CSV exports.
- XLSX export: Excel workbook with summary and lineage sheets.
- HTML export: Self-contained report with Mermaid diagrams.
- JSON export: Pretty or compact `AnalyzeResult`.

## Usage

Add it to your project alongside `flowscope-core`:

```toml
[dependencies]
flowscope-core = "0.1.0"
flowscope-export = "0.1.0"
```

To create native DuckDB database files, enable its feature:

```toml
[dependencies]
flowscope-export = { version = "0.1.0", features = ["duckdb"] }
```

## License

Apache 2.0
