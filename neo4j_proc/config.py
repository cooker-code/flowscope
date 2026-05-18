"""
Neo4j 连接配置 & FlowScope API 配置。
优先读取环境变量，便于 CI / 生产切换。
"""
import os

# ─── Neo4j ────────────────────────────────────────────────────────────────────
NEO4J_URI      = os.getenv("NEO4J_URI",      "bolt://localhost:7687")
NEO4J_USER     = os.getenv("NEO4J_USERNAME", "neo4j")
NEO4J_PASSWORD = os.getenv("NEO4J_PASSWORD", "flowscope2026")
NEO4J_DATABASE = os.getenv("NEO4J_DATABASE", "neo4j")

# ─── FlowScope API ────────────────────────────────────────────────────────────
FLOWSCOPE_API  = os.getenv("FLOWSCOPE_API",  "http://localhost:3099/api/analyze")
FLOWSCOPE_BIN  = os.getenv(
    "FLOWSCOPE_BIN",
    # 尝试本地 debug 编译产物
    os.path.join(os.path.dirname(__file__), "../target/debug/flowscope"),
)
FLOWSCOPE_PORT = int(os.getenv("FLOWSCOPE_PORT", "3099"))

# ─── SQL 目录 ─────────────────────────────────────────────────────────────────
SQL_DIR = os.getenv(
    "SQL_DIR",
    os.path.join(os.path.dirname(__file__), "../test-sql"),
)
