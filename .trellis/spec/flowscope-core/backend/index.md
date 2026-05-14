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
| [Database Guidelines](./database-guidelines.md) | ORM patterns, queries, migrations | To fill |
| [Error Handling](./error-handling.md) | Error types, handling strategies | To fill |
| [Quality Guidelines](./quality-guidelines.md) | Code standards, forbidden patterns | To fill |
| [Logging Guidelines](./logging-guidelines.md) | Structured logging, log levels | To fill |
| [Analyzer Visitor Context](./analyzer-visitor-context.md) | Save/restore rules for ambient visitor state (`current_join_info`, `last_operation`) when recursing into derived subqueries | Filled |
| [Edge Types](./edge-types.md) | Canonical contract for the 5 `EdgeType` variants (DataFlow / Derivation / JoinDependency / Ownership / CrossStatement): when emitted, how rendered, invariants | Filled |
| [Hive Compatibility Preprocess](./hive-compat-preprocess.md) | 13-step preprocessing pipeline that runs inside `flowscope_core::analyze` when `dialect=hive`. Normalizes SET/ADD directives, placeholders, double-quote strings, `arr[n]`, `! IN`, `GROUPING SETS`, etc. so the parser can ingest real-world Hive SQL. | Filled |

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
