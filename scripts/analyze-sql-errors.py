#!/usr/bin/env python3
"""
分析 CSV 中所有解析错误 SQL 的根因，归因汇总后输出报告。

用法:
    python3 scripts/analyze-sql-errors.py [CSV文件路径] [--port 3099] [--concurrency 8]
    python3 scripts/analyze-sql-errors.py --use-existing-issues   # 直接用 CSV 中已有 issues
"""
import argparse
import csv
import json
import re
import subprocess
import sys
import time
from collections import defaultdict, Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib import request as urllib_request, error as url_error

ROOT = Path(__file__).resolve().parent.parent


# ─── API ──────────────────────────────────────────────────────────────────────

def check_service(port: int) -> bool:
    try:
        req = urllib_request.Request(f"http://localhost:{port}/api/health")
        with urllib_request.urlopen(req, timeout=3):
            return True
    except Exception:
        # fallback: try analyze endpoint with a trivial query
        try:
            payload = json.dumps({"sql": "SELECT 1", "source_name": "ping",
                                  "template_mode": "raw"}).encode()
            req = urllib_request.Request(
                f"http://localhost:{port}/api/analyze",
                data=payload, headers={"Content-Type": "application/json"}, method="POST",
            )
            with urllib_request.urlopen(req, timeout=3):
                return True
        except Exception:
            return False


def start_service(port: int) -> bool:
    """尝试启动本地 flowscope serve 进程（debug binary）"""
    binary = ROOT / "target" / "debug" / "flowscope"
    if not binary.exists():
        return False
    audit_db = ROOT / "data" / "audit.db"
    audit_db.parent.mkdir(exist_ok=True)
    subprocess.Popen(
        [str(binary), "--serve", f"--port={port}", f"--audit-log={audit_db}"],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    for _ in range(20):
        time.sleep(1)
        sys.stdout.write(".")
        sys.stdout.flush()
        if check_service(port):
            print()
            return True
    print()
    return False


def analyze_sql(sql: str, source_name: str, port: int) -> dict:
    payload = json.dumps({
        "sql": sql,
        "hide_ctes": False,
        "enable_column_lineage": False,
        "template_mode": "raw",
        "source_name": source_name,
    }).encode()
    req = urllib_request.Request(
        f"http://localhost:{port}/api/analyze",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib_request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())
    except url_error.HTTPError as e:
        body = e.read().decode(errors="replace")
        return {"issues": [], "_http_error": f"{e.code}: {body[:200]}"}
    except Exception as e:
        return {"issues": [], "_error": str(e)}


# ─── 错误归因规则 ──────────────────────────────────────────────────────────────

CATEGORIES = [
    {
        "id": "trailing_comma",
        "name": "FROM/JOIN 子句尾部多余逗号",
        # CSV:  Expected: joined table, found: ,
        # API:  Expected: ), found: ,
        "pattern": re.compile(r"Expected: (joined table|\)), found: ,"),
        "root_cause": (
            "SELECT 列表或 FROM/JOIN 子句末尾存在多余逗号，"
            "如 `SELECT a, b,\nFROM ...` 或 `JOIN t1, t2,\nWHERE ...`"
        ),
        "fix": "删除 SELECT 列表、FROM 子句或 JOIN 列表末尾的多余逗号",
    },
    {
        "id": "dot_notation",
        "name": "三段式表名 catalog.database.table",
        # CSV:  Expected: joined table, found: .
        # API:  Expected: ), found: .
        "pattern": re.compile(r"Expected: (joined table|\)), found: \."),
        "root_cause": (
            "使用了 Spark/Trino 风格的三段式命名 `catalog.db.table`，"
            "HiveQL 解析器只支持两段 `db.table`"
        ),
        "fix": "将三段式 `catalog.db.table` 改为两段式 `db.table`，或注册 catalog 别名",
    },
    {
        "id": "jinja_template",
        "name": "Jinja2 双花括号模板变量 {{...}}",
        # CSV:  Expected: an expression, found: {
        # API:  Expected: identifier, found: {
        "pattern": re.compile(r"Expected: (an expression|identifier), found: \{"),
        "root_cause": (
            "SQL 包含 `{{variable}}` 或 `{{expr as alias}}` Jinja2 风格模板占位符，"
            "解析器遇到 `{` 时无法识别为合法 SQL 表达式"
        ),
        "fix": (
            "执行前先用正则替换 `{{...}}` 占位符，"
            "或将模板变量改为 `${variable}` HiveQL 原生语法，"
            "或将 `template_mode` 改为支持 Jinja2 的模式"
        ),
    },
    {
        "id": "subquery_alias",
        "name": "子查询缺少别名 / 嵌套子查询 AS 解析失败",
        # CSV:  Expected: joined table, found: as/AS
        # API:  Expected: ), found: as/AS
        "pattern": re.compile(r"Expected: (joined table|\)), found: [Aa][Ss](\s|$)"),
        "root_cause": (
            "子查询后接 AS 时解析器认为此处应是 joined table，"
            "常见于深度嵌套子查询、复杂 CTE，或子查询之间缺少逗号分隔"
        ),
        "fix": (
            "确保每个子查询都有别名，检查嵌套层数是否过深；"
            "复杂 CTE 可拆分为多个 WITH 块或独立临时视图"
        ),
    },
    {
        "id": "array_subscript",
        "name": "数组下标访问语法 array[n]",
        # CSV:  Expected: ), found: (
        # API:  Expected: end of statement, found: <token> （解析提前终止）
        "pattern": re.compile(
            r"(Expected: \), found: \()|(Expected: end of statement, found:)"
        ),
        "root_cause": (
            "使用了 `split(col,'-')[1]` 等内联数组下标访问，"
            "HiveQL 解析器在函数调用括号内不支持 `[index]` 语法"
        ),
        "fix": (
            "改用 `array_element(split(col,'-'), 1)` 函数，"
            "或先用 LATERAL VIEW POSEXPLODE 展开数组再过滤位置"
        ),
    },
    {
        "id": "case_in_from",
        "name": "FROM 子句位置出现 CASE WHEN",
        # CSV:  Expected: joined table, found: when/WHEN
        # API:  Expected: ), found: when/WHEN
        "pattern": re.compile(
            r"Expected: (joined table|\)), found: [Ww][Hh][Ee][Nn]"
        ),
        "root_cause": (
            "CASE WHEN 表达式出现在解析器期望表名的位置，"
            "通常是子查询内部缺少 FROM 关键字，"
            "或外层逗号分隔导致 CASE 被误识别为 joined table"
        ),
        "fix": (
            "检查 CASE WHEN 前方是否缺少 FROM 关键字，"
            "或将 CASE WHEN 移到 SELECT 列表而非 FROM 子句"
        ),
    },
]


def classify_issue(message: str) -> str:
    for cat in CATEGORIES:
        if cat["pattern"].search(message):
            return cat["id"]
    return "unknown"


# ─── 主流程 ────────────────────────────────────────────────────────────────────

def main() -> None:
    parser = argparse.ArgumentParser(description="分析 CSV 中 SQL 解析错误的根因")
    parser.add_argument("csv_file", nargs="?",
                        help="CSV 文件路径（默认自动查找 csv/*.csv）")
    parser.add_argument("--port", type=int, default=3099,
                        help="flowscope serve 端口（默认 3099）")
    parser.add_argument("--concurrency", type=int, default=8,
                        help="并发 API 请求数（默认 8）")
    parser.add_argument("--use-existing-issues", action="store_true",
                        help="直接使用 CSV 中已有的 issues 字段，不调用 API")
    args = parser.parse_args()

    # ── 找 CSV 文件 ───────────────────────────────────────────────────────────
    if args.csv_file:
        csv_path = Path(args.csv_file)
    else:
        candidates = list((ROOT / "csv").glob("*.csv"))
        if not candidates:
            print("❌ 未找到 CSV 文件，请通过参数指定路径:")
            print("   python3 scripts/analyze-sql-errors.py path/to/file.csv")
            sys.exit(1)
        csv_path = sorted(candidates, key=lambda p: p.stat().st_mtime)[-1]
        print(f"📂 自动选取 CSV: {csv_path.relative_to(ROOT)}")

    if not csv_path.exists():
        print(f"❌ 文件不存在: {csv_path}")
        sys.exit(1)

    # ── 读取 CSV ──────────────────────────────────────────────────────────────
    rows = []
    with open(csv_path, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        for row in reader:
            if row.get("file_content", "").strip():
                rows.append(row)

    if not rows:
        print("❌ CSV 中没有包含 file_content 的行")
        sys.exit(1)
    print(f"📋 共读取 {len(rows)} 条 SQL 记录")

    # ── 检查 / 启动服务 ────────────────────────────────────────────────────────
    if not args.use_existing_issues:
        if check_service(args.port):
            print(f"✅ 本地服务已运行（port {args.port}）")
        else:
            print(f"🚀 尝试自动启动本地服务（port {args.port}）", end="", flush=True)
            if start_service(args.port):
                print(f"✅ 服务启动成功")
            else:
                print()
                print("⚠️  无法自动启动服务，请手动运行：")
                print(f"   ./target/debug/flowscope --serve --port {args.port} --audit-log data/audit.db")
                print("   启动后重新执行此脚本，或加 --use-existing-issues 使用 CSV 中已有数据")
                sys.exit(1)

    # ── 分析 SQL ──────────────────────────────────────────────────────────────
    results: list[tuple[dict, list]] = []

    if args.use_existing_issues:
        print("📖 使用 CSV 中已有 issues 字段（跳过 API 调用）")
        for row in rows:
            raw = row.get("issues", "")
            try:
                issues = json.loads(raw) if raw.strip() else []
            except (json.JSONDecodeError, AttributeError):
                issues = []
            results.append((row, issues))
    else:
        print(f"🔍 调用 API 分析（并发={args.concurrency}）...")

        def _task_name(row: dict, idx: int) -> str:
            return (
                row.get("task_name")
                or row.get("mario_template_name")
                or row.get("table_name")
                or f"row_{idx}"
            )

        with ThreadPoolExecutor(max_workers=args.concurrency) as executor:
            future_map = {
                executor.submit(
                    analyze_sql,
                    row["file_content"],
                    _task_name(row, i),
                    args.port,
                ): row
                for i, row in enumerate(rows)
            }
            done = 0
            for future in as_completed(future_map):
                row = future_map[future]
                resp = future.result()
                issues = resp.get("issues", []) if isinstance(resp, dict) else []
                results.append((row, issues))
                done += 1
                if done % 5 == 0 or done == len(rows):
                    pct = done / len(rows) * 100
                    print(f"  进度: {done}/{len(rows)} ({pct:.0f}%)", end="\r")
        print()

    # ── 归因统计 ──────────────────────────────────────────────────────────────
    cat_counts: Counter[str] = Counter()
    cat_examples: dict[str, list[str]] = defaultdict(list)
    unknown_messages: list[str] = []

    for row, issues in results:
        if not issues:
            continue
        for issue in issues:
            if issue.get("severity") != "error":
                continue
            msg = issue.get("message", "")
            cat_id = classify_issue(msg)
            cat_counts[cat_id] += 1
            task_name = (
                row.get("task_name")
                or row.get("mario_template_name")
                or row.get("table_name", "")
            )
            if len(cat_examples[cat_id]) < 3:
                cat_examples[cat_id].append(task_name)
            if cat_id == "unknown":
                unknown_messages.append(msg[:120])

    if not cat_counts:
        print("\n✅ 未发现任何解析错误（或所有 SQL 均已正常解析）")
        return

    # ── 打印报告 ──────────────────────────────────────────────────────────────
    total_errors = sum(cat_counts.values())
    cats_sorted = sorted(cat_counts.items(), key=lambda x: -x[1])

    print()
    print("=" * 80)
    print(f"  SQL 解析错误归因报告  |  {len(rows)} 条 SQL，{total_errors} 个错误")
    print("=" * 80)

    for rank, (cat_id, count) in enumerate(cats_sorted, 1):
        cat = next((c for c in CATEGORIES if c["id"] == cat_id), None)
        pct = count / total_errors * 100
        print(f"\n{'─' * 80}")
        if cat:
            print(f"  {rank}. [{count} 个 / {pct:.0f}%]  {cat['name']}")
            print(f"     根因:  {cat['root_cause']}")
            print(f"     修复:  {cat['fix']}")
        else:
            print(f"  {rank}. [{count} 个 / {pct:.0f}%]  未知错误类型")
            for m in list(dict.fromkeys(unknown_messages))[:5]:
                print(f"     - {m}")
        examples = cat_examples.get(cat_id, [])
        if examples:
            print(f"     示例任务: {', '.join(examples)}")

    print(f"\n{'─' * 80}")

    # ── 保存 Markdown 报告 ────────────────────────────────────────────────────
    report_path = ROOT / "data" / "sql-error-report.md"
    report_path.parent.mkdir(exist_ok=True)
    _write_markdown_report(report_path, csv_path, rows, total_errors, cats_sorted,
                           cat_examples, unknown_messages)
    print(f"\n📄 Markdown 报告已保存: {report_path.relative_to(ROOT)}")


def _write_markdown_report(
    path: Path,
    csv_path: Path,
    rows: list,
    total_errors: int,
    cats_sorted: list,
    cat_examples: dict,
    unknown_messages: list,
) -> None:
    lines = [
        "# SQL 解析错误归因报告\n",
        f"- **CSV 文件**: `{csv_path.name}`\n",
        f"- **SQL 总数**: {len(rows)}\n",
        f"- **错误总数**: {total_errors}\n\n",
        "## 汇总\n\n",
        "| 排名 | 错误类型 | 数量 | 占比 | 修复方法 |\n",
        "|------|----------|-----:|-----:|----------|\n",
    ]
    for rank, (cat_id, count) in enumerate(cats_sorted, 1):
        cat = next((c for c in CATEGORIES if c["id"] == cat_id), None)
        pct = count / total_errors * 100
        if cat:
            lines.append(
                f"| {rank} | {cat['name']} | {count} | {pct:.0f}% | {cat['fix']} |\n"
            )
        else:
            lines.append(f"| {rank} | 未知类型 | {count} | {pct:.0f}% | 手动排查原始 message |\n")

    lines.append("\n## 详细说明\n\n")
    for rank, (cat_id, count) in enumerate(cats_sorted, 1):
        cat = next((c for c in CATEGORIES if c["id"] == cat_id), None)
        pct = count / total_errors * 100
        if cat:
            lines += [
                f"### {rank}. {cat['name']}（{count} 个，占 {pct:.0f}%）\n\n",
                f"**根因**：{cat['root_cause']}\n\n",
                f"**修复**：{cat['fix']}\n\n",
            ]
            examples = cat_examples.get(cat_id, [])
            if examples:
                lines.append(f"**受影响任务示例**：{', '.join(examples)}\n\n")
        else:
            lines += [
                f"### {rank}. 未知错误类型（{count} 个）\n\n",
                "**原始错误信息**（前 5 条）：\n\n",
            ]
            for m in list(dict.fromkeys(unknown_messages))[:5]:
                lines.append(f"- `{m}`\n")
            lines.append("\n")

    path.write_text("".join(lines), encoding="utf-8")


if __name__ == "__main__":
    main()
