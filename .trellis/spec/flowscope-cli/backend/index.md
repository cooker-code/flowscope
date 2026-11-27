# Backend Development Guidelines

> Best practices for backend development in this project.

---

## Overview

This directory contains guidelines for backend development. Fill in each file with your project's specific conventions.

---

## Guidelines Index

| Guide | Description | Status |
|-------|-------------|--------|
| [Directory Structure](./directory-structure.md) | Module organization and file layout | To fill |
| [Database Guidelines](./database-guidelines.md) | SQLite via rusqlite — patterns, migrations, gotchas | ✅ Filled |
| [Lineage policy](./lineage-policy.md) | Bearer identity, durable events and graph storage | ✅ Filled |
| [Audit API Spec](./audit-api-spec.md) | SQLite schema, field semantics, API contracts, wrong/correct | ✅ Filled |
| [Audit retention](./audit-retention.md) | Global seven-day retention, background maintenance and query performance | ✅ Filled |
| [Error Handling](./error-handling.md) | Error types, handling strategies | To fill |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns | To fill |
| [Logging Guidelines](./logging-guidelines.md) | Structured logging, log levels | To fill |

> Note: Hive SQL preprocessing was previously documented here. It has been moved to
> [`flowscope-core/backend/hive-compat-preprocess.md`](../../flowscope-core/backend/hive-compat-preprocess.md)
> because it runs inside `flowscope_core::analyze` (not in cli middleware). All
> API/wasm/cli callers receive it automatically when `dialect=hive`.
>
> `flowscope --schema <ddl>` is intentionally different: the Hive workload
> preprocessor removes DDL statements, so the CLI loads Hive schema files with
> `sqlparser::dialect::HiveDialect` before running workload analysis. A
> `CREATE EXTERNAL TABLE` table-level `COMMENT` may use the narrowly-scoped
> parser compatibility fallback. Before that fallback, a Hive DDL literal may
> normalize only an odd-length backslash run immediately before a single quote
> into SQL doubled-quote syntax. The scanner must leave even runs, quoted
> identifiers, double-quoted text, and line/block comments unchanged. All
> table columns and partition columns must come from the parsed AST, never from
> a consumer-side regex reconstruction.

---

## How to Fill These Guidelines

For each guideline file:

1. Document your project's **actual conventions** (not ideals)
2. Include **code examples** from your codebase
3. List **forbidden patterns** and why
4. Add **common mistakes** your team has made

The goal is to help AI assistants and new team members understand how YOUR project works.

---

**Language**: All documentation should be written in **English**.
