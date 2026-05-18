"""
初始化 Neo4j 约束 & 索引（幂等，可重复运行）。
节点：M_TABLE / M_COL / Cte
关系：REF_TABLE_COL / REF_COL_LINEAGE / REF_TEP / READS_FROM / JOINS_WITH
属性前缀：fs_（原 flowscope_）
"""
from __future__ import annotations
import sys, os
sys.path.insert(0, os.path.dirname(__file__))

from neo4j import GraphDatabase
from config import NEO4J_URI, NEO4J_USER, NEO4J_PASSWORD, NEO4J_DATABASE


CONSTRAINTS = [
    # M_TABLE：(db_name, table_name) 复合唯一键
    """CREATE CONSTRAINT mtable_db_tbl IF NOT EXISTS
       FOR (t:M_TABLE) REQUIRE (t.db_name, t.table_name) IS UNIQUE""",

    # M_COL 派生列：fs_uid 唯一
    """CREATE CONSTRAINT mcol_fs_uid IF NOT EXISTS
       FOR (c:M_COL) REQUIRE c.fs_uid IS UNIQUE""",

    # M_COL 物理列：(db_name, table_name, col_name) 唯一
    """CREATE CONSTRAINT mcol_physical_unique IF NOT EXISTS
       FOR (c:M_COL) REQUIRE (c.db_name, c.table_name, c.col_name) IS UNIQUE""",

    # Cte：fs_uid 唯一（= run_id::node_id）
    """CREATE CONSTRAINT cte_fs_uid IF NOT EXISTS
       FOR (c:Cte) REQUIRE c.fs_uid IS UNIQUE""",
]

INDEXES = [
    # M_TABLE
    "CREATE INDEX mtable_kind  IF NOT EXISTS FOR (t:M_TABLE) ON (t.fs_kind)",
    "CREATE INDEX mtable_fqn   IF NOT EXISTS FOR (t:M_TABLE) ON (t.fs_fqn)",

    # M_COL
    "CREATE INDEX mcol_fqn     IF NOT EXISTS FOR (c:M_COL) ON (c.fs_fqn)",
    "CREATE INDEX mcol_physical IF NOT EXISTS FOR (c:M_COL) ON (c.db_name, c.table_name, c.col_name)",

    # Cte
    "CREATE INDEX cte_subkind  IF NOT EXISTS FOR (c:Cte) ON (c.subkind)",
    "CREATE INDEX cte_run      IF NOT EXISTS FOR (c:Cte) ON (c.run_id)",

    # REF_COL_LINEAGE：字段级血缘（M_COL → M_COL）
    "CREATE INDEX lineage_etype IF NOT EXISTS FOR ()-[r:REF_COL_LINEAGE]-() ON (r.fs_edge_type)",

    # REF_TEP：表/CTE → CTE 的读取关系
    "CREATE INDEX ref_tep_md5   IF NOT EXISTS FOR ()-[r:REF_TEP]-()         ON (r.sql_md5)",

    # JOINS_WITH
    "CREATE INDEX joins_jtype  IF NOT EXISTS FOR ()-[r:JOINS_WITH]-()       ON (r.dominant_join_type)",
    "CREATE INDEX joins_freq   IF NOT EXISTS FOR ()-[r:JOINS_WITH]-()       ON (r.frequency)",

    # READS_FROM：表级血缘（M_TABLE → M_TABLE）
    "CREATE INDEX reads_from_md5  IF NOT EXISTS FOR ()-[r:READS_FROM]-()    ON (r.sql_md5)",
    "CREATE INDEX reads_from_path IF NOT EXISTS FOR ()-[r:READS_FROM]-()    ON (r.sql_path)",
]


def run_setup(driver) -> None:
    with driver.session(database=NEO4J_DATABASE) as session:
        for stmt in CONSTRAINTS:
            session.run(stmt)
            print(f"  [constraint] OK")
        for stmt in INDEXES:
            session.run(stmt)
            print(f"  [index]      OK")
    print("Schema 初始化完成。")


if __name__ == "__main__":
    driver = GraphDatabase.driver(NEO4J_URI, auth=(NEO4J_USER, NEO4J_PASSWORD))
    try:
        driver.verify_connectivity()
        print(f"已连接 Neo4j: {NEO4J_URI}")
        run_setup(driver)
    finally:
        driver.close()
