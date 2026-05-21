#!/usr/bin/env python3
"""
Regression test: run the FlowScope CLI against every SQL in `test-sql/` and
verify the analyzer output is healthy.

Healthy means, for each file:
- The CLI exits 0 and emits valid JSON.
- `issues` contains **no errors** (warnings are tolerated but reported).
- `statements` contains **at least one** lineage statement.
  (i.e. session/admin directives like SET/REFRESH/USE/MSCK/ANALYZE that get
   filtered must not leave the script with zero analyzable statements.)

For visibility we also print the key headline fields per file:
sqlType / insertType / targetTable / sourceTables count / statement types.

Optional pinned expectations: if `test-sql/.regression-expect.json` exists,
files mentioned there get exact-match assertions on those fields. Files not
mentioned only run the soft "no errors / has statements" check. This keeps
adding new SQL friction-free: drop a file in `test-sql/` and it joins the
regression with sensible defaults.

Exit code 0 if all files pass, 1 otherwise.

Usage:
    python3 scripts/regression-test-sql.py [--bin path/to/flowscope] [--dialect hive]
"""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent.parent
DEFAULT_SQL_DIR = ROOT / "test-sql"
EXPECT_FILE_NAME = ".regression-expect.json"

GREEN = "\033[32m"
RED = "\033[31m"
YELLOW = "\033[33m"
DIM = "\033[2m"
BOLD = "\033[1m"
RESET = "\033[0m"


@dataclass
class Result:
    file: Path
    passed: bool
    summary: dict[str, Any]
    failures: list[str]
    warnings: list[str]


def resolve_default_bin() -> Path:
    """Prefer release build, fall back to debug, and finally PATH."""
    candidates = [
        ROOT / "target" / "release" / "flowscope",
        ROOT / "target" / "debug" / "flowscope",
    ]
    for cand in candidates:
        if cand.exists() and cand.is_file():
            return cand
    on_path = shutil.which("flowscope")
    if on_path:
        return Path(on_path)
    print(
        f"{RED}error{RESET}: no flowscope binary found. Build first with "
        f"`cargo build -p flowscope-cli --release` or pass --bin.",
        file=sys.stderr,
    )
    sys.exit(2)


def load_expectations(sql_dir: Path) -> dict[str, dict[str, Any]]:
    expect_path = sql_dir / EXPECT_FILE_NAME
    if not expect_path.exists():
        return {}
    try:
        return json.loads(expect_path.read_text())
    except json.JSONDecodeError as e:
        print(f"{RED}error{RESET}: invalid {expect_path}: {e}", file=sys.stderr)
        sys.exit(2)


def analyze(bin_path: Path, sql_file: Path, dialect: str) -> dict[str, Any]:
    """Invoke the CLI and parse JSON. Returns the analyzer result dict."""
    proc = subprocess.run(
        [str(bin_path), str(sql_file), "-d", dialect, "-f", "json"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"CLI exited {proc.returncode}\nstderr:\n{proc.stderr.strip()}"
        )
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        raise RuntimeError(f"invalid JSON from CLI: {e}\nstdout head:\n{proc.stdout[:400]}")


def check_one(
    sql_file: Path,
    bin_path: Path,
    dialect: str,
    expectations: dict[str, Any] | None,
) -> Result:
    failures: list[str] = []
    warnings: list[str] = []
    summary: dict[str, Any] = {}

    try:
        result = analyze(bin_path, sql_file, dialect)
    except (RuntimeError, subprocess.TimeoutExpired) as e:
        return Result(
            file=sql_file,
            passed=False,
            summary={"error": str(e)},
            failures=[f"CLI invocation failed: {e}"],
            warnings=[],
        )

    issues = result.get("issues") or []
    errors_by_code = [i for i in issues if i.get("severity") == "error"]
    warns_by_code = [i for i in issues if i.get("severity") == "warning"]

    target = result.get("targetTable") or {}
    sources = result.get("sourceTables") or []
    stmts = result.get("statements") or []

    summary = {
        "sqlType": result.get("sqlType"),
        "insertType": result.get("insertType"),
        "targetTable": target.get("qualifiedName") or target.get("label"),
        "sourceCount": len(sources),
        "sources": [t.get("qualifiedName") or t.get("label") for t in sources],
        "statementTypes": [s.get("statementType") for s in stmts],
        "errorCount": len(errors_by_code),
        "warningCount": len(warns_by_code),
    }

    if errors_by_code:
        failures.append(
            f"{len(errors_by_code)} error issue(s): "
            + ", ".join(sorted({i.get("code", "?") for i in errors_by_code}))
        )
    if not stmts:
        failures.append("no analyzable statements (all directives filtered? source corrupt?)")
    if warns_by_code:
        warnings.append(
            f"{len(warns_by_code)} warning issue(s): "
            + ", ".join(sorted({i.get("code", "?") for i in warns_by_code}))
        )

    if expectations:
        for key, expected in expectations.items():
            actual = summary.get(key)
            if key == "sources":
                if sorted(actual or []) != sorted(expected):
                    failures.append(f"sources mismatch:\n    expected={sorted(expected)}\n    actual  ={sorted(actual or [])}")
            elif actual != expected:
                failures.append(f"{key} mismatch: expected={expected!r} actual={actual!r}")

    return Result(
        file=sql_file,
        passed=not failures,
        summary=summary,
        failures=failures,
        warnings=warnings,
    )


def render(results: list[Result], sql_dir: Path) -> bool:
    """Print a compact table + per-failure details. Return True if all passed."""
    name_w = max(len(r.file.relative_to(sql_dir).as_posix()) for r in results)
    name_w = max(name_w, 40)

    print()
    print(f"{BOLD}{'file':<{name_w}}  {'sqlType':<7}  {'insert':<10}  {'srcs':>4}  {'stmts':<15}  status{RESET}")
    print(DIM + ("─" * (name_w + 60)) + RESET)
    for r in results:
        name = r.file.relative_to(sql_dir).as_posix()
        s = r.summary
        sql_type = s.get("sqlType", "-") or "-"
        ins = s.get("insertType") or "-"
        src_count = s.get("sourceCount", "-")
        stmts = "/".join(s.get("statementTypes") or []) or "-"
        status_label = f"{GREEN}PASS{RESET}" if r.passed else f"{RED}FAIL{RESET}"
        if r.passed and r.warnings:
            status_label = f"{YELLOW}WARN{RESET}"
        if len(stmts) > 15:
            stmts = stmts[:12] + "..."
        print(
            f"{name:<{name_w}}  {sql_type:<7}  {ins:<10}  {src_count:>4}  {stmts:<15}  {status_label}"
        )

    failed = [r for r in results if not r.passed]
    warned = [r for r in results if r.passed and r.warnings]

    if warned:
        print()
        for r in warned:
            name = r.file.relative_to(sql_dir).as_posix()
            for w in r.warnings:
                print(f"{YELLOW}warn{RESET}  {name}: {w}")

    if failed:
        print()
        for r in failed:
            name = r.file.relative_to(sql_dir).as_posix()
            print(f"{RED}fail{RESET}  {name}:")
            for f in r.failures:
                for line in f.splitlines():
                    print(f"      {line}")

    print()
    print(
        f"{BOLD}summary{RESET}: "
        f"{GREEN}{len(results) - len(failed)} passed{RESET}, "
        f"{RED}{len(failed)} failed{RESET}, "
        f"{YELLOW}{len(warned)} with warnings{RESET}, "
        f"{len(results)} total"
    )
    return not failed


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--bin",
        type=Path,
        default=None,
        help="flowscope CLI binary (default: target/release/flowscope or target/debug/flowscope)",
    )
    parser.add_argument(
        "--dialect",
        default="hive",
        help="SQL dialect to pass to the CLI (default: hive)",
    )
    parser.add_argument(
        "--sql-dir",
        type=Path,
        default=DEFAULT_SQL_DIR,
        help="directory containing *.sql files (default: test-sql/)",
    )
    args = parser.parse_args()

    bin_path = args.bin or resolve_default_bin()
    sql_dir: Path = args.sql_dir
    if not sql_dir.is_dir():
        print(f"{RED}error{RESET}: {sql_dir} is not a directory", file=sys.stderr)
        return 2

    files = sorted(sql_dir.glob("*.sql"))
    if not files:
        print(f"{YELLOW}no *.sql under {sql_dir}{RESET}", file=sys.stderr)
        return 0

    expectations_by_file = load_expectations(sql_dir)

    print(f"{BOLD}flowscope regression{RESET}  bin={bin_path}  dialect={args.dialect}  files={len(files)}")

    results = [
        check_one(
            f,
            bin_path,
            args.dialect,
            expectations_by_file.get(f.name),
        )
        for f in files
    ]
    all_passed = render(results, sql_dir)
    return 0 if all_passed else 1


if __name__ == "__main__":
    sys.exit(main())
