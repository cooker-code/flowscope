"""
Pass 2 — 关系写入：

  REF_TABLE_COL   ownership：(M_TABLE/Cte) → (M_COL)   列归属
  REF_COL_LINEAGE 字段级血缘：(M_COL) → (M_COL)         纯列到列，含转换表达式
  REF_TEP         读取依赖：(M_TABLE/Cte) → (Cte)        含过滤条件，保留 CTE 中间层
  READS_FROM      表级血缘：(M_TABLE) → (M_TABLE)         穿透 CTE，表到表直接依赖

属性前缀统一使用 fs_。
"""
from __future__ import annotations
import json
from collections import defaultdict
from datetime import datetime, timezone


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ─── 节点定位辅助 ─────────────────────────────────────────────────────────────

def _match_container(node: dict, alias: str, run_id: str) -> tuple[str, dict]:
    """生成匹配 M_TABLE 或 Cte 的 MATCH 子句。"""
    ntype = node.get("type")
    if ntype in ("table", "view"):
        cn   = node.get("canonicalName", {})
        db   = cn.get("catalog") or cn.get("schema") or ""
        name = cn.get("name", node.get("label", ""))
        return (
            f"MATCH ({alias}:M_TABLE {{db_name: ${alias}_db, table_name: ${alias}_name}})",
            {f"{alias}_db": db, f"{alias}_name": name},
        )
    if ntype == "cte":
        uid = f"{run_id}::{node['id']}"
        return (
            f"MATCH ({alias}:Cte {{fs_uid: ${alias}_uid}})",
            {f"{alias}_uid": uid},
        )
    return "", {}


def _match_node(alias: str, node: dict, run_id: str) -> tuple[str, dict]:
    """匹配 M_TABLE / Cte / M_COL（物理列或派生列）。"""
    ntype = node.get("type")
    if ntype in ("table", "view"):
        cn   = node.get("canonicalName", {})
        db   = cn.get("catalog") or cn.get("schema") or ""
        name = cn.get("name", node.get("label", ""))
        return (
            f"MATCH ({alias}:M_TABLE {{db_name: ${alias}_db, table_name: ${alias}_name}})",
            {f"{alias}_db": db, f"{alias}_name": name},
        )
    if ntype == "cte":
        uid = f"{run_id}::{node['id']}"
        return (
            f"MATCH ({alias}:Cte {{fs_uid: ${alias}_uid}})",
            {f"{alias}_uid": uid},
        )
    if ntype == "column":
        qn = node.get("qualifiedName")
        cn = node.get("canonicalName", {})
        if qn:
            return (
                f"MATCH ({alias}:M_COL {{db_name: ${alias}_db, "
                f"table_name: ${alias}_tbl, col_name: ${alias}_col}})",
                {
                    f"{alias}_db":  cn.get("catalog") or cn.get("schema") or "",
                    f"{alias}_tbl": cn.get("schema", ""),
                    f"{alias}_col": cn.get("name", ""),
                },
            )
        uid = f"{run_id}::{node['id']}"
        return (
            f"MATCH ({alias}:M_COL {{fs_uid: ${alias}_uid}})",
            {f"{alias}_uid": uid},
        )
    return "", {}


# ─── REF_TABLE_COL（列归属）────────────────────────────────────────────────────

def write_ownership(tx, edge: dict, node_map: dict, run_id: str) -> None:
    src_node = node_map.get(edge["from"])
    dst_node = node_map.get(edge["to"])
    if not src_node or not dst_node:
        return
    src_clause, src_params = _match_node("src", src_node, run_id)
    dst_clause, dst_params = _match_node("dst", dst_node, run_id)
    if not src_clause or not dst_clause:
        return
    tx.run(
        f"""
        {src_clause}
        {dst_clause}
        MERGE (src)-[r:REF_TABLE_COL]->(dst)
        ON CREATE SET r.first_seen_at = $now
        ON MATCH  SET r.updated_time  = $now
        """,
        **src_params, **dst_params, now=_now(),
    )


# ─── REF_COL_LINEAGE（字段级血缘，纯 M_COL → M_COL）─────────────────────────

def write_lineage(tx, edge: dict, node_map: dict, run_id: str, sql_md5: str) -> None:
    src_node = node_map.get(edge["from"])
    dst_node = node_map.get(edge["to"])
    if not src_node or not dst_node:
        return

    # 严格限定：两端都必须是列（M_COL）
    if src_node["type"] != "column" or dst_node["type"] != "column":
        return

    src_clause, src_params = _match_node("src", src_node, run_id)
    dst_clause, dst_params = _match_node("dst", dst_node, run_id)
    if not src_clause or not dst_clause:
        return

    tx.run(
        f"""
        {src_clause}
        {dst_clause}
        MERGE (src)-[r:REF_COL_LINEAGE {{sql_md5: $md5, fs_edge_type: $etype}}]->(dst)
        ON CREATE SET
          r.fs_expr      = $expr,
          r.fs_join_type = $jtype,
          r.fs_join_cond = $jcond,
          r.first_seen_at = $now
        ON MATCH SET
          r.fs_join_type  = $jtype,
          r.fs_join_cond  = $jcond,
          r.updated_time  = $now
        """,
        **src_params, **dst_params,
        md5=sql_md5,
        etype=edge["type"],
        expr=edge.get("expression"),
        jtype=(edge.get("joinType") or "").lower() or None,
        jcond=edge.get("joinCondition"),
        now=_now(),
    )


# ─── REF_TEP（M_TABLE/Cte → Cte，含过滤条件）────────────────────────────────

def write_ref_tep(tx, result: dict, node_map: dict,
                  run_id: str, sql_md5: str) -> None:
    """
    为 (M_TABLE → Cte) 和 (Cte → Cte) 的直接读取关系建边。

    方向：(src) -[:REF_TEP]-> (dst_cte)
    属性：
      filters_json   [{expression, clause_type}]  src 节点上的业务过滤条件（分区字段排除）
      filters_count  过滤条件数
      sql_md5        来源 SQL
    """
    from sink.entities import _is_partition_filter

    # 收集唯一容器→容器的 data_flow/derivation 对
    # 只保留：dst 是 Cte；src 是 M_TABLE 或 Cte
    pairs: dict[tuple, tuple[dict, dict]] = {}

    for e in result["edges"]:
        if e["type"] not in ("data_flow", "derivation"):
            continue
        src = node_map.get(e["from"])
        dst = node_map.get(e["to"])
        if not src or not dst:
            continue

        src_type = src["type"]
        dst_type = dst["type"]

        # dst 必须是 CTE
        if dst_type != "cte":
            continue
        # src 必须是 M_TABLE 或 Cte
        if src_type not in ("table", "view", "cte"):
            continue

        key = (src["id"], dst["id"])
        if key not in pairs:
            pairs[key] = (src, dst)

    # 写入 REF_TEP
    for (src_id, dst_id), (src_node, dst_node) in pairs.items():
        src_clause, src_params = _match_container(src_node, "src", run_id)
        dst_clause, dst_params = _match_container(dst_node, "dst", run_id)
        if not src_clause or not dst_clause:
            continue

        # 过滤条件来自 src 节点的 filters[]，分区字段排除，去重
        filters = []
        seen_expr: set[str] = set()
        for f in src_node.get("filters", []):
            expr = f["expression"]
            if not _is_partition_filter(expr) and expr not in seen_expr:
                seen_expr.add(expr)
                filters.append({"expression": expr, "clause_type": f["clauseType"]})

        tx.run(
            f"""
            {src_clause}
            {dst_clause}
            MERGE (src)-[r:REF_TEP {{sql_md5: $md5}}]->(dst)
            ON CREATE SET
              r.filters_json   = $filters_json,
              r.filters_count  = $filters_count,
              r.first_seen_at  = $now
            ON MATCH SET
              r.filters_json   = $filters_json,
              r.filters_count  = $filters_count,
              r.updated_time   = $now
            """,
            **src_params, **dst_params,
            md5=sql_md5,
            filters_json=json.dumps(filters, ensure_ascii=False),
            filters_count=len(filters),
            now=_now(),
        )


# ─── READS_FROM（纯 M_TABLE → M_TABLE，穿透 CTE 链路）───────────────────────

def write_reads_from(tx, result: dict, node_map: dict,
                     run_id: str, sql_md5: str, sql_path: str) -> None:
    """
    只在 M_TABLE 之间建立 READS_FROM，穿透所有 CTE 中间层。
    方向：(sink_table) -[:READS_FROM]-> (source_table)
    属性：filters_json / filter_count / sql_md5 / sql_path
    """
    from sink.entities import _is_partition_filter

    ownership_map: dict[str, dict] = {}
    for e in result["edges"]:
        if e["type"] == "ownership":
            parent = node_map.get(e["from"])
            if parent:
                ownership_map[e["to"]] = parent

    cte_children: dict[str, list[str]] = defaultdict(list)
    for child_id, parent in ownership_map.items():
        if parent["type"] == "cte":
            cte_children[parent["id"]].append(child_id)

    df_in: dict[str, list[str]] = defaultdict(list)
    for e in result["edges"]:
        if e["type"] in ("data_flow", "derivation"):
            df_in[e["to"]].append(e["from"])

    def src_tables(node_id: str, visited: set | None = None) -> set[str]:
        if visited is None:
            visited = set()
        if node_id in visited:
            return set()
        visited.add(node_id)
        node = node_map.get(node_id)
        if not node:
            return set()
        ntype = node["type"]
        if ntype in ("table", "view"):
            return {node_id}
        result_ids: set[str] = set()
        if ntype == "cte":
            for child_id in cte_children.get(node_id, []):
                for sid in df_in.get(child_id, []):
                    result_ids |= src_tables(sid, visited)
            for sid in df_in.get(node_id, []):
                result_ids |= src_tables(sid, visited)
        elif ntype == "column":
            parent = ownership_map.get(node_id)
            if parent and parent["type"] in ("table", "view"):
                return {parent["id"]}
            for sid in df_in.get(node_id, []):
                result_ids |= src_tables(sid, visited)
        else:
            for sid in df_in.get(node_id, []):
                result_ids |= src_tables(sid, visited)
        return result_ids

    pairs: dict[tuple[str, str], dict] = {}
    for e in result["edges"]:
        if e["type"] not in ("data_flow", "derivation"):
            continue
        dst_node = node_map.get(e["to"])
        if not dst_node:
            continue
        if dst_node["type"] in ("table", "view"):
            dst_table = dst_node
        elif dst_node["type"] == "column":
            parent = ownership_map.get(e["to"])
            dst_table = parent if (parent and parent["type"] in ("table", "view")) else None
        else:
            dst_table = None
        if not dst_table:
            continue
        for src_id in src_tables(e["from"]):
            if src_id == dst_table["id"]:
                continue
            key = (src_id, dst_table["id"])
            if key not in pairs:
                src_node = node_map.get(src_id)
                if src_node:
                    pairs[key] = {"src": src_node, "dst": dst_table}

    for (src_id, dst_id), info in pairs.items():
        src_node = info["src"]
        dst_node = info["dst"]
        src_cn   = src_node.get("canonicalName", {})
        dst_cn   = dst_node.get("canonicalName", {})
        src_db   = src_cn.get("catalog") or src_cn.get("schema") or ""
        src_name = src_cn.get("name", src_node.get("label", ""))
        dst_db   = dst_cn.get("catalog") or dst_cn.get("schema") or ""
        dst_name = dst_cn.get("name", dst_node.get("label", ""))
        if not src_name or not dst_name:
            continue

        filters = []
        seen_expr: set[str] = set()
        for f in src_node.get("filters", []):
            expr = f["expression"]
            if not _is_partition_filter(expr) and expr not in seen_expr:
                seen_expr.add(expr)
                filters.append({"expression": expr, "clause_type": f["clauseType"]})

        tx.run(
            """
            MATCH (src:M_TABLE {db_name: $src_db, table_name: $src_name})
            MATCH (dst:M_TABLE {db_name: $dst_db, table_name: $dst_name})
            MERGE (dst)-[r:READS_FROM {sql_md5: $md5}]->(src)
            ON CREATE SET
              r.filters_json  = $filters_json,
              r.filter_count  = $filter_count,
              r.sql_path      = $path,
              r.first_seen_at = $now
            ON MATCH SET
              r.filters_json  = $filters_json,
              r.filter_count  = $filter_count,
              r.sql_path      = $path,
              r.updated_time  = $now
            """,
            src_db=src_db, src_name=src_name,
            dst_db=dst_db, dst_name=dst_name,
            md5=sql_md5,
            filters_json=json.dumps(filters, ensure_ascii=False),
            filter_count=len(filters),
            path=sql_path,
            now=_now(),
        )
