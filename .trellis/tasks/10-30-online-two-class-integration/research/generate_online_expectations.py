#!/usr/bin/env python3
"""Generate independent, raw-SQL lineage expectations for the 46 in-scope SQL files.

This research-only runner deliberately consumes SQLGlot plus read-only DDL JSON;
it never imports FlowScope result JSON and never connects to Neo4j.  It writes a
complete JSON expectation and a flattened CSV suitable for a later native/WASM
and isolated-graph comparison.
"""

from __future__ import annotations

import argparse
import contextlib
import csv
import hashlib
import io
import json
from collections import Counter
from pathlib import Path
from typing import Any

import sqlglot

from batch.sql_lineage_expectations import analyze_original_sql, load_ddl_schemas


def ddl_column_defs(create: Any) -> list[Any]:
    """Return declared data plus PARTITIONED BY fields without inferring any field."""
    if not isinstance(create.this, sqlglot.exp.Schema):
        return []
    columns = list(create.this.expressions)
    partition = next(create.find_all(sqlglot.exp.PartitionedByProperty), None)
    if partition is not None and isinstance(partition.this, sqlglot.exp.Schema):
        known = {column.name.lower() for column in columns}
        columns.extend(column for column in partition.this.expressions if column.name.lower() not in known)
    return columns


def load_all_schemas(evidence_root: Path) -> tuple[dict[str, tuple[str, ...]], list[str], dict[str, dict[str, str]]]:
    """Load frozen DDL and the later, read-only current-DDL supplements."""
    with contextlib.redirect_stdout(io.StringIO()):
        schemas, _, _ = load_ddl_schemas(evidence_root / "ddl")
    used = [str(evidence_root / "ddl")]
    ddl_records: dict[str, dict[str, str]] = {}
    for path in sorted((evidence_root / "ddl").glob("*.json")):
        item = json.loads(path.read_text(encoding="utf-8"))
        if item.get("status") == "SUCCESS" and item.get("ddl"):
            ddl_records[f"{item['database']}.{item['table']}".lower()] = {
                "path": str(path), "ddl": str(item["ddl"]), "table_type": str(item.get("tableType") or ""),
            }
    for path in sorted((evidence_root / "cases/online-two-category-fix/current-ddl").glob("*.json")):
        item = json.loads(path.read_text(encoding="utf-8"))
        if item.get("status") != "SUCCESS" or not item.get("ddl"):
            continue
        create = sqlglot.parse_one(str(item["ddl"]), read="hive")
        if isinstance(create.this, sqlglot.exp.Schema):
            columns = tuple(column.name for column in create.this.expressions)
        elif isinstance(create.expression, sqlglot.exp.Query):
            # CREATE VIEW has no declared Schema wrapper.  Its defining SELECT
            # gives the actual exposed column names, which is enough for source
            # ownership/ambiguity resolution; it does not assert view internals.
            columns = tuple(projection.output_name for projection in create.expression.selects)
        else:
            raise RuntimeError(f"DDL既非表Schema也非可读View查询: {path}")
        schemas[f"{item['database']}.{item['table']}"] = columns
        # Current read-only DDL deliberately wins over the frozen collection.
        ddl_records[f"{item['database']}.{item['table']}".lower()] = {
            "path": str(path), "ddl": str(item["ddl"]), "table_type": str(item.get("tableType") or ""),
        }
        used.append(str(path))
    # Keep `schemas` data-only: the existing expectation module uses it to
    # determine INSERT target positions, where static partition fields must
    # not consume a SELECT output position.  The caller builds an expanded,
    # partition-aware `column_sets` only for source-column resolution.
    return schemas, used, ddl_records


def output_status(output: dict[str, Any], *, require_target: bool) -> str:
    """Do not downgrade an unknown reference to a passing output."""
    if output["unresolved_references"]:
        return "UNVERIFIABLE_AST_SCOPE"
    if output["window_control_unresolved"]:
        return "UNVERIFIABLE_WINDOW_CONTROL"
    if require_target and output.get("target_column") is None:
        return "UNVERIFIABLE_TARGET_POSITION"
    return "PROVABLE"


def schema_table_metadata(table: str, source: dict[str, str]) -> dict[str, Any]:
    """Translate only declared DDL metadata to FlowScope's SchemaMetadata shape.

    CREATE VIEW output types are deliberately omitted: the view DDL declares the
    names through its SELECT but not an independent physical type contract.
    """
    create = sqlglot.parse_one(source["ddl"], read="hive")
    parts = table.split(".")
    schema = parts[-2] if len(parts) >= 2 else None
    entry: dict[str, Any] = {"name": parts[-1], "columns": []}
    if schema:
        entry["schema"] = schema
    if isinstance(create.this, sqlglot.exp.Schema):
        for column in ddl_column_defs(create):
            item: dict[str, Any] = {"name": column.name}
            kind = column.args.get("kind")
            if kind is not None:
                item["dataType"] = kind.sql(dialect="hive")
            entry["columns"].append(item)
    elif isinstance(create.expression, sqlglot.exp.Query):
        entry["columns"] = [{"name": projection.output_name} for projection in create.expression.selects]
    else:
        raise RuntimeError(f"DDL既非表Schema也非可读View查询: {source['path']}")
    return entry


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--evidence-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    root = args.evidence_root
    manifest = json.loads((root / "cases/online-two-category-fix/non-php-manifest.json").read_text(encoding="utf-8"))
    schemas, ddl_files, ddl_records = load_all_schemas(root)
    column_sets = {table.lower(): set(columns) for table, columns in schemas.items()}
    for table, source in ddl_records.items():
        create = sqlglot.parse_one(source["ddl"], read="hive")
        if isinstance(create.this, sqlglot.exp.Schema):
            column_sets[table] = {column.name for column in ddl_column_defs(create)}
        elif isinstance(create.expression, sqlglot.exp.Query):
            column_sets[table] = {projection.output_name for projection in create.expression.selects}
    output_rows: list[dict[str, Any]] = []
    csv_rows: list[dict[str, Any]] = []
    counters: Counter[str] = Counter()
    missing_source_tables: dict[str, set[int]] = {}
    schema_exports: list[dict[str, Any]] = []
    schema_dir = args.output_dir / "schemas"
    metadata_dir = args.output_dir / "schema-metadata"

    for item in manifest:
        if not item["in_scope"]:
            continue
        audit_id = int(item["audit_id"])
        sql_path = Path(item["sql_path"])
        raw_sql = sql_path.read_text(encoding="utf-8")
        actual_sha = hashlib.sha256(raw_sql.encode()).hexdigest()
        if actual_sha != item["sql_sha256"]:
            raise RuntimeError(f"原SQL哈希变化: {audit_id}")
        # SQLGlot writes compatibility notices directly in some complex expressions;
        # suppress only that tool chatter, never its returned unresolved contracts.
        with contextlib.redirect_stdout(io.StringIO()):
            expectation = analyze_original_sql(
                raw_sql,
                task_category="change",
                schemas=schemas,
                schema_version_proven=False,
                column_sets=column_sets,
            )
        data = expectation.as_dict()
        required_tables: set[str] = set()
        for statement in data["statements"]:
            if statement.get("target_table"):
                required_tables.add(statement["target_table"])
            for source_table in statement["source_tables"]:
                required_tables.add(source_table)
                if source_table.lower() not in column_sets:
                    missing_source_tables.setdefault(source_table, set()).add(audit_id)
            statement_is_insert = statement["statement_kind"] == "insert"
            for level, outputs in (("top", statement["output_columns"]), ("scope", statement["scope_outputs"])):
                for output in outputs:
                    status = output_status(output, require_target=statement_is_insert and level == "top")
                    counters[f"{level}_{status}"] += 1
                    record = {
                        "audit_id": audit_id,
                        "category": item["category"],
                        "secondary_category": item["secondary_category"],
                        "sql_sha256": actual_sha,
                        "statement_index": statement["statement_index"],
                        "statement_kind": statement["statement_kind"],
                        "level": level,
                        "scope_id": output.get("scope_id", "TOP"),
                        "scope_owner": output.get("owner_label", "TOP"),
                        "output_position": output["position"],
                        "output_name": output.get("output_name"),
                        "target_table": statement.get("target_table"),
                        "target_column": output.get("target_column"),
                        "physical_sources": json.dumps(output["physical_sources"], ensure_ascii=False),
                        "window_controls": json.dumps(output.get("window_controls", []), ensure_ascii=False),
                        "unresolved_references": json.dumps(output["unresolved_references"], ensure_ascii=False),
                        "window_control_unresolved": json.dumps(output.get("window_control_unresolved", []), ensure_ascii=False),
                        "expectation_status": status,
                    }
                    csv_rows.append(record)
        selected = []
        missing_ddl = []
        for table in sorted(required_tables):
            source = ddl_records.get(table.lower())
            if source is None:
                missing_ddl.append(table)
            else:
                selected.append((table, source))
        if missing_ddl:
            raise RuntimeError(f"缺少原始DDL，不能导出 schema.sql: {audit_id}: {missing_ddl}")
        schema_dir.mkdir(parents=True, exist_ok=True)
        metadata_dir.mkdir(parents=True, exist_ok=True)
        schema_path = schema_dir / f"{audit_id}.sql"
        schema_path.write_text(
            "\n\n".join(
                f"-- source: {source['path']}\n-- physical relation: {table}\n{source['ddl'].rstrip(';')};"
                for table, source in selected
            ) + "\n",
            encoding="utf-8",
        )
        metadata = {
            "tables": [schema_table_metadata(table, source) for table, source in selected],
            "allowImplied": False,
        }
        metadata_path = metadata_dir / f"{audit_id}.json"
        metadata_path.write_text(json.dumps(metadata, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        schema_exports.append({
            "audit_id": audit_id,
            "schema_sql": str(schema_path),
            "schema_metadata_json": str(metadata_path),
            "relations": [{"table": table, "ddl_json": source["path"], "ddl_sha256": hashlib.sha256(source["ddl"].encode()).hexdigest(), "table_type": source["table_type"]} for table, source in selected],
            "view_ddl_is_raw": True,
        })
        output_rows.append({
            "audit_id": audit_id,
            "audit_ids": item["audit_ids"],
            "category": item["category"],
            "secondary_category": item["secondary_category"],
            "source_name": item["source_name"],
            "sql_path": str(sql_path),
            "sql_sha256": actual_sha,
            "expectation": data,
        })

    args.output_dir.mkdir(parents=True, exist_ok=True)
    summary = {
        "method": "SQLGlot 30.25.0 Hive AST plus read-only DDL; FlowScope output is not consumed",
        "in_scope_sql": len(output_rows),
        "schemas_loaded": len(schemas),
        "ddl_evidence_files": ddl_files,
        "flattened_output_records": len(csv_rows),
        "coverage": dict(sorted(counters.items())),
        "missing_source_tables": {table: sorted(ids) for table, ids in sorted(missing_source_tables.items())},
        "schema_exports": schema_exports,
        "schema_export_contract": "Each schema SQL concatenates only original read-only DDL. CREATE VIEW remains raw CREATE VIEW. SchemaMetadata uses declared table column names/types; view output names come only from its actual defining SELECT and view types are omitted, never inferred from workload SQL.",
        "raw_sql_sha256_verified": True,
    }
    (args.output_dir / "online-two-class-expectations.json").write_text(
        json.dumps({"summary": summary, "items": output_rows}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    with (args.output_dir / "online-two-class-expectations.csv").open("w", encoding="utf-8", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(csv_rows[0]))
        writer.writeheader()
        writer.writerows(csv_rows)
    (args.output_dir / "online-two-class-expectations-summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(json.dumps(summary, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
