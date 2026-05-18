#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# FlowScope → Neo4j 一键运行脚本
# 使用方式:
#   ./run.sh            # 启动本地 Docker Neo4j + 解析 + 入库
#   ./run.sh --no-docker  # 跳过 Docker，直接连接已有 Neo4j
#   ./run.sh --remote   # 连接远程 Neo4j（bolt://10.13.35.4:7687）
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
NEO4J_PROC="$SCRIPT_DIR"

# ─── 参数解析 ────────────────────────────────────────────────────────────────
USE_DOCKER=true
REMOTE=false
for arg in "$@"; do
  case "$arg" in
    --no-docker) USE_DOCKER=false ;;
    --remote)    REMOTE=true; USE_DOCKER=false ;;
  esac
done

# ─── 颜色输出 ────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log()  { echo -e "${GREEN}[run.sh]${NC} $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()  { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# ─── 依赖检查 ────────────────────────────────────────────────────────────────
log "检查依赖..."
command -v python3 >/dev/null 2>&1 || err "python3 未安装"
python3 -c "import neo4j" 2>/dev/null || {
    warn "neo4j driver 未安装，正在安装..."
    pip3 install neo4j --quiet --break-system-packages 2>/dev/null || pip3 install neo4j --quiet
}

# ─── Neo4j 设置 ──────────────────────────────────────────────────────────────
if [ "$REMOTE" = true ]; then
    export NEO4J_URI="bolt://10.13.35.4:7687"
    export NEO4J_USERNAME="neo4j"
    export NEO4J_PASSWORD="conaN2025-08-01"
    export NEO4J_DATABASE="neo4j"
    log "使用远程 Neo4j: $NEO4J_URI"

elif [ "$USE_DOCKER" = true ]; then
    export NEO4J_URI="bolt://localhost:7687"
    export NEO4J_USERNAME="neo4j"
    export NEO4J_PASSWORD="flowscope2026"
    export NEO4J_DATABASE="neo4j"

    command -v docker >/dev/null 2>&1 || err "Docker 未安装，请先安装 Docker 或使用 --no-docker"

    log "启动 Neo4j Docker 容器..."
    mkdir -p "$NEO4J_PROC/data/neo4j/data"
    mkdir -p "$NEO4J_PROC/data/neo4j/logs"
    mkdir -p "$NEO4J_PROC/data/neo4j/plugins"

    cd "$NEO4J_PROC"
    docker compose up -d

    log "等待 Neo4j 就绪..."
    for i in $(seq 1 30); do
        if docker exec flowscope-neo4j wget -qO- http://localhost:7474 >/dev/null 2>&1; then
            log "Neo4j 就绪 ✓ (${i}s)"
            break
        fi
        sleep 1
        if [ "$i" -eq 30 ]; then
            err "Neo4j 30s 内未就绪，请检查: docker logs flowscope-neo4j"
        fi
    done
else
    # --no-docker：用默认或环境变量配置
    export NEO4J_URI="${NEO4J_URI:-bolt://localhost:7687}"
    export NEO4J_USERNAME="${NEO4J_USERNAME:-neo4j}"
    export NEO4J_PASSWORD="${NEO4J_PASSWORD:-flowscope2026}"
    export NEO4J_DATABASE="${NEO4J_DATABASE:-neo4j}"
    log "使用现有 Neo4j: $NEO4J_URI"
fi

# ─── 运行主流程 ──────────────────────────────────────────────────────────────
export FLOWSCOPE_BIN="$PROJECT_DIR/target/debug/flowscope"
export SQL_DIR="$PROJECT_DIR/test-sql"

log "运行 parse_and_sink.py ..."
cd "$NEO4J_PROC"
python3 parse_and_sink.py

log "完成！访问 Neo4j Browser: http://localhost:7474"
log "  用户名: ${NEO4J_USERNAME}  密码: ${NEO4J_PASSWORD}"
