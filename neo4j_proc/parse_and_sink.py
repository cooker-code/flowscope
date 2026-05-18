"""
主流程（新模型）：
  节点：M_TABLE / M_COL / Cte（移除 Run / Source / Statement / Filter）
  关系：REF_TABLE_COL / REF_COL_LINEAGE / READS_FROM / JOINS_WITH

  Pass 1 — 实体写入（merge_table / merge_cte / merge_col）
  Pass 2 — 基础关系（ownership → REF_TABLE_COL，lineage → REF_COL_LINEAGE，READS_FROM）
  Pass 3 — JOIN / UNION 聚合（JOINS_WITH / UnionGroup）
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, os.path.dirname(__file__))

from neo4j import GraphDatabase

import config
from setup_schema import run_setup
from sink.entities  import merge_table, merge_cte, merge_col
from sink.relations import write_ownership, write_lineage, write_ref_tep, write_reads_from
from sink.joins     import extract_join_pairs, write_joins_with, detect_and_write_unions


# ─── SQL 预处理 ───────────────────────────────────────────────────────────────
_SKIP_LINE_RE = re.compile(
    r"^\s*(set\s+[\w.]+\s*=|add\s+(file|jar|archive)\s+)",
    re.IGNORECASE,
)
_JINJA_RE   = re.compile(r"\{\{.*?\}\}")
_HIVE_VAR_RE = re.compile(r"\$\{[\w.]+\}")


def preprocess_sql(content: str) -> str:
    lines = []
    for line in content.splitlines():
        if _SKIP_LINE_RE.match(line):
            lines.append("")
        else:
            line = _HIVE_VAR_RE.sub("20240101", line)
            lines.append(line)
    return "\n".join(lines)


def _md5(text: str) -> str:
    return hashlib.md5(text.encode("utf-8")).hexdigest()


# ─── FlowScope 服务管理 ───────────────────────────────────────────────────────
_flowscope_proc: subprocess.Popen | None = None


def start_flowscope() -> None:
    global _flowscope_proc
    bin_path = os.path.abspath(config.FLOWSCOPE_BIN)
    if not os.path.isfile(bin_path):
        sys.exit(f"[ERROR] flowscope binary not found: {bin_path}")

    print(f"[flowscope] 启动服务 port={config.FLOWSCOPE_PORT} dialect=hive ...")
    _flowscope_proc = subprocess.Popen(
        [bin_path, "--serve", "--port", str(config.FLOWSCOPE_PORT), "--dialect", "hive"],
        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
    )
    for i in range(30):
        time.sleep(0.5)
        if _flowscope_proc.poll() is not None:
            err = (_flowscope_proc.stderr.read() or b"").decode(errors="replace")
            sys.exit(f"[ERROR] flowscope 进程意外退出: {err[:200]}")
        try:
            urllib.request.urlopen(
                f"http://localhost:{config.FLOWSCOPE_PORT}/api/health", timeout=2
            )
            print(f"[flowscope] 服务就绪 ✓ ({(i+1)*0.5:.1f}s)")
            return
        except Exception:
            pass
    sys.exit("[ERROR] flowscope 服务启动超时")


def stop_flowscope() -> None:
    if _flowscope_proc:
        _flowscope_proc.terminate()
        print("[flowscope] 服务已停止")


def analyze_sql(sql_text: str, file_name: str) -> dict:
    payload = json.dumps({"sql": sql_text, "sourceName": file_name}).encode("utf-8")
    req = urllib.request.Request(
        config.FLOWSCOPE_API,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


# ─── 单文件 Sink ──────────────────────────────────────────────────────────────

def sink_one_file(driver, sql_path: Path) -> None:
    rel_path  = str(sql_path)
    file_name = sql_path.name
    content   = sql_path.read_text(encoding="utf-8", errors="replace")

    if _JINJA_RE.search(content):
        print(f"  [SKIP] {file_name} — 含 Jinja {{{{ }}}} 模板占位符")
        return

    filtered = preprocess_sql(content)
    if not filtered.strip():
        print(f"  [SKIP] {file_name} — 全为 SET/ADD 指令")
        return

    print(f"  [PARSE] {file_name} ...", end=" ", flush=True)
    try:
        result = analyze_sql(filtered, file_name)
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")[:200]
        print(f"HTTP {e.code}: {body}")
        return
    except Exception as e:
        print(f"ERROR: {e}")
        return

    if result.get("summary", {}).get("hasErrors"):
        errs = [i["message"] for i in result.get("issues", []) if i.get("severity") == "error"]
        print(f"WARN 解析有错误: {errs[:2]}")

    sql_md5  = _md5(filtered)
    run_id   = f"run_{sql_md5[:12]}"
    node_map = {n["id"]: n for n in result["nodes"]}

    print(f"nodes={len(result['nodes'])} edges={len(result['edges'])} "
          f"joins={result.get('summary', {}).get('joinCount', 0)}")

    with driver.session(database=config.NEO4J_DATABASE) as session:

        # ── Pass 1: 实体 ──────────────────────────────────────────────────────
        with session.begin_transaction() as tx:
            for node in result["nodes"]:
                ntype = node["type"]
                if ntype in ("table", "view"):
                    merge_table(tx, node, run_id, rel_path)
                elif ntype == "cte":
                    merge_cte(tx, node, run_id)
                elif ntype == "column":
                    merge_col(tx, node, run_id)
            tx.commit()

        # ── Pass 2: 基础关系 ──────────────────────────────────────────────────
        with session.begin_transaction() as tx:
            for edge in result["edges"]:
                if edge["type"] == "ownership":
                    write_ownership(tx, edge, node_map, run_id)
                elif edge["type"] in ("data_flow", "derivation"):
                    write_lineage(tx, edge, node_map, run_id, sql_md5)
            write_ref_tep(tx, result, node_map, run_id, sql_md5)
            write_reads_from(tx, result, node_map, run_id, sql_md5, rel_path)
            tx.commit()

        # ── Pass 3: JOIN / UNION 聚合 ─────────────────────────────────────────
        with session.begin_transaction() as tx:
            join_pairs = extract_join_pairs(result)
            if join_pairs:
                write_joins_with(tx, join_pairs, sql_md5)
            detect_and_write_unions(tx, result, run_id, sql_md5)
            tx.commit()

    print(f"  [OK] {file_name}")


# ─── 主入口 ───────────────────────────────────────────────────────────────────

def main() -> None:
    sql_dir   = Path(config.SQL_DIR).resolve()
    sql_files = sorted(sql_dir.glob("*.sql"))
    if not sql_files:
        sys.exit(f"[ERROR] 未找到 SQL 文件: {sql_dir}")

    print(f"\n{'='*60}")
    print(f" FlowScope → Neo4j Sink  [新模型]")
    print(f" SQL 目录  : {sql_dir}  ({len(sql_files)} 个文件)")
    print(f" Neo4j     : {config.NEO4J_URI}")
    print(f"{'='*60}\n")

    driver = GraphDatabase.driver(
        config.NEO4J_URI,
        auth=(config.NEO4J_USER, config.NEO4J_PASSWORD),
    )
    try:
        driver.verify_connectivity()
        print("[neo4j] 连接成功 ✓\n")
    except Exception as e:
        sys.exit(f"[ERROR] Neo4j 连接失败: {e}")

    print("[schema] 初始化约束 & 索引 ...")
    run_setup(driver)
    print()

    start_flowscope()
    print()

    try:
        for sql_path in sql_files:
            sink_one_file(driver, sql_path)
    finally:
        stop_flowscope()
        driver.close()

    print(f"\n{'='*60}")
    print(f" 全部完成！")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
