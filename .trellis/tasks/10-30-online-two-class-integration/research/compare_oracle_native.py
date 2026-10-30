#!/usr/bin/env python3
"""Exact Physical-root set comparison: independent official oracle vs native graph."""
from __future__ import annotations

import argparse
import json
from collections import defaultdict
from pathlib import Path


def norm(value: str) -> str:
    return value.lower().removeprefix("hive.")


def target_ancestor_physical(result: dict) -> dict[int, set[str]]:
    nodes = {node["id"]: node for node in result["nodes"]}
    owners: dict[str, str] = {}
    reverse: dict[str, list[str]] = defaultdict(list)
    for edge in result["edges"]:
        if edge["type"] == "ownership" and nodes.get(edge["from"], {}).get("type") == "table":
            owners[edge["to"]] = edge["from"]
        if edge["type"] in {"data_flow", "derivation"}:
            reverse[edge["to"]].append(edge["from"])
    physical = {
        column: f"{norm(nodes[table].get('qualifiedName', ''))}.{str(nodes[column].get('label', '')).lower()}"
        for column, table in owners.items()
    }
    targets = {
        (nodes[column].get("metadata") or {}).get("insertTarget", {}).get("position"): column
        for column in owners
        if (nodes[column].get("metadata") or {}).get("insertTarget")
    }
    output: dict[int, set[str]] = {}
    for position, target in targets.items():
        seen = {target}
        stack = [target]
        while stack:
            current = stack.pop()
            for parent in reverse[current]:
                if parent not in seen:
                    seen.add(parent)
                    stack.append(parent)
        # Target's own Physical node is an endpoint, not an input root.
        output[position] = {physical[node] for node in seen if node in physical and node != target}
    return output


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--oracle", type=Path, required=True)
    parser.add_argument("--native-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    oracle = json.loads(args.oracle.read_text(encoding="utf-8"))
    rows = []
    for item in oracle["items"]:
        audit_id = str(item["audit_id"])
        result = json.loads((args.native_dir / f"{audit_id}.json").read_text(encoding="utf-8"))
        actual = target_ancestor_physical(result)
        for statement in item["statements"]:
            for output in statement["outputs"]:
                expected = {norm(root) for root in output["physical_column_roots"]}
                observed = actual.get(output["output_position"], set())
                rows.append({
                    "audit_id": audit_id, "position": output["output_position"], "output_name": output["output_name"],
                    "expected": sorted(expected), "actual": sorted(observed),
                    "missing": sorted(expected - observed), "extra": sorted(observed - expected),
                    "status": "MATCH" if expected == observed else "MISMATCH",
                })
    summary = {"MATCH": sum(row["status"] == "MATCH" for row in rows), "MISMATCH": sum(row["status"] == "MISMATCH" for row in rows)}
    args.out.write_text(json.dumps({"summary": summary, "rows": rows}, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(summary, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
