"""
Pass 1 — 实体写入：M_TABLE / M_COL / Cte
属性前缀统一使用 fs_（原 flowscope_）。
全部使用 MERGE（幂等），现有元数据字段不覆盖。
"""
from __future__ import annotations
import re
from datetime import datetime, timezone


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


# ─── 分区字段识别（热点保护）─────────────────────────────────────────────────
_PARTITION_COL_RE = re.compile(
    r"^\s*(?:\w+\.)?"
    r"(dt|ds|p_date|partition_date|stat_date|log_date|etl_date|biz_date)"
    r"\s*(=|>=|<=|>|<|between|in)\s*",
    re.IGNORECASE,
)

def _is_partition_filter(expr: str) -> bool:
    return bool(_PARTITION_COL_RE.match(expr.strip()))


# ─── M_TABLE ──────────────────────────────────────────────────────────────────

def merge_table(tx, node: dict, run_id: str, sql_path: str) -> None:
    cn   = node.get("canonicalName", {})
    db   = cn.get("catalog") or cn.get("schema") or ""
    name = cn.get("name", node.get("label", ""))
    fqn  = node.get("qualifiedName") or (f"{db}.{name}" if db else name)

    tx.run(
        """
        MERGE (t:M_TABLE {db_name: $db, table_name: $name})
        ON CREATE SET
          t.fs_kind           = $kind,
          t.fs_fqn            = $fqn,
          t.fs_res_src        = $res_src,
          t.fs_sql_path       = $path,
          t.fs_run_id         = $run_id,
          t.fs_first_seen_at  = $now,
          t.fs_last_seen_at   = $now,
          t.fs_sql_count      = 1
        ON MATCH SET
          t.fs_kind           = $kind,
          t.fs_fqn            = $fqn,
          t.fs_sql_path       = $path,
          t.fs_run_id         = $run_id,
          t.fs_last_seen_at   = $now,
          t.fs_sql_count      = coalesce(t.fs_sql_count, 0) + 1
        """,
        db=db, name=name, fqn=fqn,
        kind=node["type"],
        res_src=node.get("resolutionSource", "unknown"),
        path=sql_path, run_id=run_id, now=_now(),
    )


# ─── Cte ──────────────────────────────────────────────────────────────────────

def merge_cte(tx, node: dict, run_id: str) -> None:
    node_id = node["id"]
    subkind = "with_cte" if node_id.startswith("cte_") else "derived_subquery"
    uid     = f"{run_id}::{node_id}"
    body    = node.get("bodySpan") or {}
    spans   = node.get("nameSpans", [])

    tx.run(
        """
        MERGE (c:Cte {fs_uid: $uid})
        SET
          c.label             = $label,
          c.subkind           = $subkind,
          c.run_id            = $run_id,
          c.body_span_start   = $bstart,
          c.body_span_end     = $bend,
          c.decl_span_start   = $dstart,
          c.decl_span_end     = $dend,
          c.occurrence_count  = $occ,
          c.fs_node_id        = $node_id,
          c.first_seen_at     = $now
        """,
        uid=uid, label=node.get("label", ""), subkind=subkind,
        run_id=run_id,
        bstart=body.get("start"), bend=body.get("end"),
        dstart=(node.get("span") or {}).get("start"),
        dend=(node.get("span") or {}).get("end"),
        occ=len(spans), node_id=node_id, now=_now(),
    )


# ─── M_COL ────────────────────────────────────────────────────────────────────

def _col_kind(node: dict) -> str:
    if node.get("aggregation"):
        return "aggregated_column"
    if node.get("expression"):
        return "derived_column"
    if node.get("qualifiedName"):
        return "physical_column"
    return "projected_column"


def merge_col(tx, node: dict, run_id: str) -> None:
    cn       = node.get("canonicalName", {})
    col_name = cn.get("name", node.get("label", ""))
    tbl_name = cn.get("schema", "")
    db_name  = cn.get("catalog") or cn.get("schema") or ""
    qn       = node.get("qualifiedName")
    kind     = _col_kind(node)
    agg      = node.get("aggregation") or {}
    is_physical = bool(qn and tbl_name)

    if is_physical:
        tx.run(
            """
            MERGE (c:M_COL {db_name: $db, table_name: $tbl, col_name: $col})
            ON CREATE SET
              c.fs_uid         = $uid,
              c.fs_kind        = $kind,
              c.fs_fqn         = $fqn,
              c.fs_res_src     = $res,
              c.fs_expr        = $expr,
              c.fs_agg_fn      = $agg_fn,
              c.fs_agg_gk      = $agg_gk,
              c.fs_agg_dist    = $agg_dt,
              c.fs_first_seen  = $now,
              c.fs_last_seen   = $now
            ON MATCH SET
              c.fs_uid         = $uid,
              c.fs_kind        = $kind,
              c.fs_fqn         = $fqn,
              c.fs_expr        = $expr,
              c.fs_agg_fn      = $agg_fn,
              c.fs_agg_gk      = $agg_gk,
              c.fs_agg_dist    = $agg_dt,
              c.fs_last_seen   = $now
            """,
            db=db_name, tbl=tbl_name, col=col_name,
            uid=f"{run_id}::{node['id']}",
            kind=kind, fqn=qn or "",
            res=node.get("resolutionSource", "unknown"),
            expr=node.get("expression"),
            agg_fn=agg.get("function"),
            agg_gk=agg.get("isGroupingKey"),
            agg_dt=agg.get("distinct"),
            now=_now(),
        )
    else:
        uid = f"{run_id}::{node['id']}"
        props = dict(
            fs_uid=uid,
            col_name=col_name or node.get("label", ""),
            fs_kind=kind,
            fs_expr=node.get("expression"),
            fs_agg_fn=agg.get("function"),
            fs_agg_gk=agg.get("isGroupingKey"),
            fs_agg_dist=agg.get("distinct"),
            run_id=run_id,
            fs_first_seen=_now(),
        )
        if tbl_name:
            props["table_name"] = tbl_name
        if db_name:
            props["db_name"] = db_name
        set_pairs = ", ".join(f"c.{k} = ${k}" for k in props)
        tx.run(
            f"MERGE (c:M_COL {{fs_uid: $fs_uid}}) SET {set_pairs}",
            **props,
        )
