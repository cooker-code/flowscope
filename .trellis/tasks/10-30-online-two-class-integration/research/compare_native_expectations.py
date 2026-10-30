#!/usr/bin/env python3
"""Compare independent provable target-field roots with formal native results."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def norm(value: str) -> str:
    return value.lower().removeprefix("hive.")


def analyze(actual: dict) -> tuple[dict[tuple[str, str], str], dict[tuple[str, str], str], dict[str, set[str]]]:
    nodes = {node["id"]: node for node in actual["nodes"]}
    owners: dict[str, str] = {}
    value_reverse: dict[str, list[str]] = defaultdict(list)
    for edge in actual["edges"]:
        if edge["type"] == "ownership" and nodes.get(edge["from"], {}).get("type") == "table":
            owners[edge["to"]] = edge["from"]
        if edge["type"] in {"data_flow", "derivation"}:
            value_reverse[edge["to"]].append(edge["from"])
    physical: dict[tuple[str, str], str] = {}
    targets: dict[tuple[str, str], str] = {}
    for column, table in owners.items():
        table_name = nodes[table].get("qualifiedName", "")
        label = str(nodes[column].get("label", ""))
        physical[(norm(table_name), label.lower())] = column
        mapping = (nodes[column].get("metadata") or {}).get("insertTarget")
        if mapping:
            targets[(norm(mapping["table"]), str(mapping["column"]).lower())] = column
    ancestors: dict[str, set[str]] = {}
    for target in targets.values():
        seen = {target}
        stack = [target]
        while stack:
            node = stack.pop()
            for parent in value_reverse[node]:
                if parent not in seen:
                    seen.add(parent)
                    stack.append(parent)
        ancestors[target] = seen
    return physical, targets, ancestors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--expectations", type=Path, required=True)
    parser.add_argument("--actual-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    items = json.loads(args.expectations.read_text(encoding="utf-8"))["items"]
    result = {"target_mapping": [], "provable_value_roots": [], "not_compared": []}
    for item in items:
        audit_id = str(item["audit_id"])
        actual_path = args.actual_dir / f"{audit_id}.json"
        if not actual_path.exists():
            result["not_compared"].append({"audit_id": audit_id, "reason": "NO_FORMAL_RESULT"})
            continue
        actual = json.loads(actual_path.read_text(encoding="utf-8"))
        if any(issue.get("severity") == "error" for issue in actual.get("issues", [])):
            result["not_compared"].append({"audit_id": audit_id, "reason": "FORMAL_PARSE_FAILURE"})
            continue
        physical, targets, ancestors = analyze(actual)
        for statement in item["expectation"]["statements"]:
            if statement["statement_kind"] != "insert":
                continue
            target_table = statement["target_table"]
            for output in statement["output_columns"]:
                expected_target = output.get("target_column")
                if expected_target:
                    target_id = targets.get((norm(target_table), expected_target.lower()))
                    result["target_mapping"].append({
                        "audit_id": audit_id, "position": output["position"], "target_table": target_table,
                        "target_column": expected_target, "status": "MATCH" if target_id else "MISSING_TARGET_MAPPING",
                    })
                # Only independent roots with no stated uncertainty are compared.
                if output["unresolved_references"] or output["window_control_unresolved"] or not output["physical_sources"] or not expected_target:
                    continue
                target_id = targets.get((norm(target_table), expected_target.lower()))
                for root in output["physical_sources"]:
                    table, column = root.rsplit(".", 1)
                    source_id = physical.get((norm(table), column.lower()))
                    status = "MATCH" if target_id and source_id and source_id in ancestors[target_id] else (
                        "SOURCE_NODE_MISSING" if source_id is None else "TARGET_MAPPING_MISSING" if target_id is None else "VALUE_PATH_MISSING"
                    )
                    result["provable_value_roots"].append({
                        "audit_id": audit_id, "position": output["position"], "target_column": expected_target,
                        "physical_root": root, "status": status,
                    })
    for key in ("target_mapping", "provable_value_roots", "not_compared"):
        result[key].sort(key=lambda row: (int(row["audit_id"]), row.get("position", 0), row.get("physical_root", "")))
    result["summary"] = {
        key: {status: sum(row.get("status") == status for row in result[key]) for status in sorted({row.get("status") for row in result[key] if row.get("status")})}
        for key in ("target_mapping", "provable_value_roots")
    }
    args.out.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result["summary"], ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
