"""
Pass 3 — 表-表 JOIN / UNION 关系聚合写入。

:JOINS_WITH  —— 两张表之间的 JOIN 关系（聚合多条 REF_COL_LINEAGE 边）
:UnionGroup  —— UNION 分支中间节点（N-元 UNION 用中介节点避免 C(N,2) 爆炸）
:UNION_BRANCH / :UNION_PRODUCES
"""
from __future__ import annotations
import json
from collections import defaultdict
from datetime import datetime, timezone


def _now() -> str:
    return datetime.now(timezone.utc).isoformat()


def _join_roles(join_type: str) -> tuple[str, str]:
    """根据 JOIN 类型返回 (left_role, right_role)。"""
    jt = (join_type or "").lower().replace(" ", "_")
    if jt in ("inner",):
        return "symmetric", "symmetric"
    if jt in ("left", "left_outer"):
        return "preserved", "null_supplying"
    if jt in ("right", "right_outer"):
        return "null_supplying", "preserved"
    if jt in ("full", "full_outer"):
        return "preserved", "preserved"
    if jt in ("cross",):
        return "cartesian", "cartesian"
    if jt in ("left_semi",):
        return "filter_subject", "filter_only"
    if jt in ("left_anti",):
        return "filter_subject", "filter_only"
    if jt in ("right_semi",):
        return "filter_only", "filter_subject"
    if jt in ("right_anti",):
        return "filter_only", "filter_subject"
    return "symmetric", "symmetric"


def _normalize_join_type(jt: str) -> str:
    """统一枚举值：full outer → full_outer 等。"""
    return (jt or "").lower().strip().replace(" ", "_")


def _table_fqn_from_node(node: dict) -> str | None:
    """从节点提取 db.table_name。"""
    if node["type"] not in ("table", "view"):
        return None
    cn = node.get("canonicalName", {})
    db   = cn.get("catalog") or cn.get("schema") or ""
    name = cn.get("name", "")
    return f"{db}.{name}" if db else name


def _col_owner_fqn(col_node: dict, ownership_map: dict) -> str | None:
    """通过 ownership_map[col_id] → parent node fqn 找到列所属表。"""
    parent = ownership_map.get(col_node["id"])
    if parent:
        return _table_fqn_from_node(parent)
    return None


def extract_join_pairs(result: dict) -> list[dict]:
    """
    从 AnalyzeResult 中提取所有 (left_table, right_table, join_type, join_condition) 元组。

    核心思路：
    - FlowScope 把 JOIN 信息携带在 data_flow/derivation 边的 joinType/joinCondition 字段上。
    - 这些边的源节点可能是 CTE/派生子查询，需要沿 data_flow（无 joinType）链反向追溯到物理表。
    """
    node_map: dict[str, dict] = {n["id"]: n for n in result["nodes"]}

    # ── ownership_map: child_id → parent_node (M_TABLE / Cte)
    ownership_map: dict[str, dict] = {}
    for e in result["edges"]:
        if e["type"] == "ownership":
            parent = node_map.get(e["from"])
            if parent:
                ownership_map[e["to"]] = parent

    # ── data_flow_in: node_id → [source_node_id, ...]（无 joinType）
    data_flow_in: dict[str, list[str]] = defaultdict(list)
    for e in result["edges"]:
        if e["type"] in ("data_flow", "derivation") and not e.get("joinType"):
            data_flow_in[e["to"]].append(e["from"])

    # ── cte_cols_in: cte_id → [col_id, ...]（CTE 拥有的列 / 子节点）
    cte_children: dict[str, list[str]] = defaultdict(list)
    for child_id, parent in ownership_map.items():
        cte_children[parent["id"]].append(child_id)

    def physical_tables_behind(node_id: str, depth: int = 0) -> set[str]:
        """
        递归找到 node_id（可以是 column / cte / table）最终来源的所有物理表 fqn。
        """
        if depth > 10:
            return set()
        node = node_map.get(node_id)
        if not node:
            return set()

        ntype = node.get("type")

        # ① 物理表 — 直接返回
        if ntype in ("table", "view"):
            fqn = _table_fqn_from_node(node) or node.get("label", "")
            return {fqn} if fqn else set()

        # ② CTE / derived subquery — 找其子列，再向上追溯
        if ntype == "cte":
            results: set[str] = set()
            for child_id in cte_children.get(node_id, []):
                results |= physical_tables_behind(child_id, depth + 1)
            # 也尝试直接 data_flow 入边（CTE 本身作为边的目标）
            for src_id in data_flow_in.get(node_id, []):
                results |= physical_tables_behind(src_id, depth + 1)
            return results

        # ③ column — 两路：ownership（所在容器）+ data_flow 入边
        if ntype == "column":
            results: set[str] = set()
            parent = ownership_map.get(node_id)
            if parent:
                results |= physical_tables_behind(parent["id"], depth + 1)
            for src_id in data_flow_in.get(node_id, []):
                results |= physical_tables_behind(src_id, depth + 1)
            return results

        # ④ output 节点等 — 沿 data_flow 向上
        results: set[str] = set()
        for src_id in data_flow_in.get(node_id, []):
            results |= physical_tables_behind(src_id, depth + 1)
        return results

    join_pairs = []
    seen: set[tuple] = set()  # 去重 (left, right, jtype, cond)

    for e in result["edges"]:
        jtype = e.get("joinType")
        jcond = e.get("joinCondition") or ""
        if not jtype:
            continue

        etype = e["type"]
        if etype not in ("data_flow", "derivation", "join_dependency"):
            continue

        right_tables = physical_tables_behind(e["from"])
        left_tables  = physical_tables_behind(e["to"])

        # 排除相同表之间的自引用
        for rt in right_tables:
            for lt in left_tables:
                if lt == rt:
                    continue
                key = (lt, rt, _normalize_join_type(jtype), jcond)
                if key in seen:
                    continue
                seen.add(key)
                join_pairs.append({
                    "left_fqn":    lt,
                    "right_fqn":   rt,
                    "join_type":   _normalize_join_type(jtype),
                    "join_condition": jcond,
                    "has_join_dependency": (etype == "join_dependency"),
                })

    return join_pairs


def write_joins_with(tx, join_pairs: list[dict], sql_md5: str) -> None:
    """
    MERGE :JOINS_WITH 边。
    每个 (left_fqn, right_fqn) 对合并为一条关系，累计 frequency。
    """
    # 先按 (left, right) 聚合，合并 join_conditions + join_types
    grouped: dict[tuple, dict] = {}
    for jp in join_pairs:
        key = (jp["left_fqn"], jp["right_fqn"])
        if key not in grouped:
            grouped[key] = {
                "join_types":   set(),
                "conditions":   [],
                "has_join_dep": False,
                "has_non_equi": False,
                "has_time_join": False,
            }
        grouped[key]["join_types"].add(jp["join_type"])
        if jp["join_condition"]:
            grouped[key]["conditions"].append(jp["join_condition"])
        if jp["has_join_dependency"]:
            grouped[key]["has_join_dep"] = True
        # 简单启发：非等值 = ON 条件含 <, >, <=, >=, !=, <>
        cond = jp.get("join_condition") or ""
        if any(op in cond for op in ["<>", "!=", " < ", " > ", "<=", ">="]):
            grouped[key]["has_non_equi"] = True
        if any(kw in cond.lower() for kw in ["date_add", "date_sub", "interval", "between"]):
            grouped[key]["has_time_join"] = True

    for (left_fqn, right_fqn), info in grouped.items():
        left_db, left_tbl   = _split_fqn(left_fqn)
        right_db, right_tbl = _split_fqn(right_fqn)
        dominant = max(info["join_types"], key=lambda x: x == "left")  # left 优先
        left_role, right_role = _join_roles(dominant)
        conditions = list(dict.fromkeys(info["conditions"]))  # 去重保序

        # 提取 join_keys_json（简单 parse "a.col = b.col"）
        keys = []
        for cond in conditions:
            if "=" in cond and not any(op in cond for op in ["!=", "<=", ">="]):
                parts = cond.split("=", 1)
                keys.append({"left": parts[0].strip(), "right": parts[1].strip(), "on_expr": cond})

        tx.run(
            """
            MATCH (l:M_TABLE {db_name: $ldb, table_name: $ltbl})
            MATCH (r:M_TABLE {db_name: $rdb, table_name: $rtbl})
            MERGE (l)-[j:JOINS_WITH]->(r)
            ON CREATE SET
              j.join_type             = $dominant,
              j.dominant_join_type    = $dominant,
              j.join_type_history     = $jt_list,
              j.left_role             = $l_role,
              j.right_role            = $r_role,
              j.join_keys_json        = $keys,
              j.join_conditions       = $conds,
              j.key_count             = $kc,
              j.has_non_equi          = $non_eq,
              j.has_time_join         = $time_j,
              j.has_join_dependency   = $jdep,
              j.sql_md5_list          = [$md5],
              j.frequency             = 1,
              j.first_seen_at         = $now,
              j.last_seen_at          = $now
            ON MATCH SET
              j.frequency             = j.frequency + 1,
              j.join_type_history     = [x IN j.join_type_history + $jt_list WHERE x IS NOT NULL],
              j.join_conditions       = [x IN j.join_conditions + $conds WHERE x IS NOT NULL],
              j.sql_md5_list          = CASE WHEN $md5 IN j.sql_md5_list
                                             THEN j.sql_md5_list
                                             ELSE j.sql_md5_list + [$md5] END,
              j.has_non_equi          = j.has_non_equi OR $non_eq,
              j.has_time_join         = j.has_time_join OR $time_j,
              j.last_seen_at          = $now,
              j.dominant_join_type    = $dominant
            """,
            ldb=left_db, ltbl=left_tbl,
            rdb=right_db, rtbl=right_tbl,
            dominant=dominant,
            jt_list=list(info["join_types"]),
            l_role=left_role, r_role=right_role,
            keys=json.dumps(keys, ensure_ascii=False),
            conds=conditions,
            kc=len(keys),
            non_eq=info["has_non_equi"],
            time_j=info["has_time_join"],
            jdep=info["has_join_dep"],
            md5=sql_md5, now=_now(),
        )


def detect_and_write_unions(tx, result: dict, run_id: str, sql_md5: str) -> None:
    """
    检测 UNION 拓扑：当同一个 output/cte 列被多个不同源表的 data_flow 边指向时。
    每组产生一个 :UnionGroup 节点 + :UNION_BRANCH / :UNION_PRODUCES 关系。
    """
    node_map = {n["id"]: n for n in result["nodes"]}
    ownership_map: dict[str, dict] = {}
    for e in result["edges"]:
        if e["type"] == "ownership":
            col_node = node_map.get(e["to"])
            parent   = node_map.get(e["from"])
            if col_node and parent:
                ownership_map[e["to"]] = parent

    # dst_col → 多个来源表（按列分组）
    dst_to_tables: dict[str, set] = defaultdict(set)
    dst_to_owner : dict[str, dict] = {}  # dst_col → 所属容器 node

    for e in result["edges"]:
        if e["type"] != "data_flow" or e.get("joinType"):
            continue
        dst_col = node_map.get(e["to"])
        src_owner = ownership_map.get(e["from"])
        dst_owner = ownership_map.get(e["to"])
        if not dst_col or not src_owner:
            continue
        fqn = _table_fqn_from_node(src_owner) or src_owner.get("label", "")
        dst_to_tables[e["to"]].add(fqn)
        if dst_owner and e["to"] not in dst_to_owner:
            dst_to_owner[e["to"]] = dst_owner

    # 找"输出容器"：同一个容器的全部列都有多源
    container_to_col_sources: dict[str, list[set]] = defaultdict(list)
    for col_id, src_tables in dst_to_tables.items():
        if len(src_tables) < 2:
            continue
        owner = dst_to_owner.get(col_id)
        if not owner:
            continue
        container_key = owner["id"]
        container_to_col_sources[container_key].append(src_tables)

    for container_id, col_source_sets in container_to_col_sources.items():
        # 取所有列共同出现的分支集合（交集）
        union_branches = set.intersection(*col_source_sets) if col_source_sets else set()
        if len(union_branches) < 2:
            continue

        container_node = node_map.get(container_id)
        if not container_node:
            continue

        output_fqn = _table_fqn_from_node(container_node) or container_node.get("label", "")
        output_db, output_tbl = _split_fqn(output_fqn)
        ug_id = f"{sql_md5}::{run_id}::{container_id}"

        # 创建 UnionGroup
        tx.run(
            """
            MERGE (ug:UnionGroup {id: $ugid})
            SET
              ug.union_type    = 'union',
              ug.branch_count  = $bc,
              ug.sql_md5       = $md5,
              ug.run_id        = $rid,
              ug.first_seen_at = $now
            """,
            ugid=ug_id, bc=len(union_branches),
            md5=sql_md5, rid=run_id, now=_now(),
        )

        # UNION_BRANCH
        for idx, branch_fqn in enumerate(sorted(union_branches)):
            bdb, btbl = _split_fqn(branch_fqn)
            tx.run(
                """
                MATCH (ug:UnionGroup {id: $ugid})
                MATCH (br:M_TABLE {db_name: $bdb, table_name: $btbl})
                MERGE (br)-[r:UNION_BRANCH {index: $idx}]->(ug)
                ON CREATE SET r.is_first = ($idx = 0)
                """,
                ugid=ug_id, bdb=bdb, btbl=btbl, idx=idx,
            )

        # UNION_PRODUCES
        tx.run(
            """
            MATCH (ug:UnionGroup {id: $ugid})
            MATCH (out:M_TABLE {db_name: $odb, table_name: $otbl})
            MERGE (ug)-[:UNION_PRODUCES]->(out)
            """,
            ugid=ug_id, odb=output_db, otbl=output_tbl,
        )


def _split_fqn(fqn: str) -> tuple[str, str]:
    """'db.table' → ('db', 'table')。"""
    if "." in fqn:
        db, _, tbl = fqn.partition(".")
        return db, tbl
    return "", fqn
