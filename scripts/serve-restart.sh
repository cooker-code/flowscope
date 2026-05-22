#!/usr/bin/env bash
#
# FlowScope serve mode 重启脚本（服务器侧使用）
#
# 行为：
#   1. 优雅 kill 现有进程（pid 文件 → 端口占用进程 双重兜底）
#   2. nohup 后台启动新进程
#   3. 等待端口就绪并调用 /api/health 验证
#   4. 任何阶段失败 → 退出码 ≠ 0，便于上游/CI 检查
#
# 用法：
#   ./scripts/serve-restart.sh                # 用默认参数重启
#   PORT=8080 ./scripts/serve-restart.sh      # 覆盖端口
#   AUDIT_LOG=/data/audit.db ./scripts/serve-restart.sh
#
# 配套停止脚本：./scripts/serve-stop.sh
#

set -euo pipefail

# ============================================================
# 配置（环境变量可覆盖）
# ============================================================
BIN="${BIN:-./flowscope}"
PORT="${PORT:-7681}"
HOST="${HOST:-0.0.0.0}"
WATCH_DIR="${WATCH_DIR:-/tmp/sql}"
AUDIT_LOG="${AUDIT_LOG:-data/audit.db}"
LOG_FILE="${LOG_FILE:-logs/flowscope-serve.log}"
PID_FILE="${PID_FILE:-logs/flowscope-serve.pid}"
HEALTH_PATH="${HEALTH_PATH:-/api/health}"
HEALTH_TIMEOUT_SEC="${HEALTH_TIMEOUT_SEC:-30}"
SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-10}"

# ============================================================
# 工具函数
# ============================================================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"
}

die() {
  log "ERROR: $*" >&2
  exit 1
}

# ============================================================
# 1. 前置检查
# ============================================================
log "step 1/5  前置检查"

[[ -x "$BIN" ]] || die "二进制不可执行: $BIN（检查 chmod +x 和路径）"

mkdir -p "$WATCH_DIR" "$(dirname "$AUDIT_LOG")" "$(dirname "$LOG_FILE")" "$(dirname "$PID_FILE")"

# 服务器是否有 curl（健康检查需要）
if ! command -v curl >/dev/null 2>&1; then
  log "  WARN: 未找到 curl，将跳过 /api/health 验证"
  SKIP_HEALTH=1
else
  SKIP_HEALTH=0
fi

# ============================================================
# 2. 停掉现有进程
# ============================================================
log "step 2/5  停掉现有进程"

stop_pid() {
  local pid="$1"
  local label="$2"

  if ! kill -0 "$pid" 2>/dev/null; then
    log "  $label PID=$pid 已不存在，跳过"
    return 0
  fi

  log "  $label PID=$pid 发送 SIGTERM"
  kill -TERM "$pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= SHUTDOWN_TIMEOUT_SEC )); then
      log "  $label PID=$pid 超过 ${SHUTDOWN_TIMEOUT_SEC}s 未退出，发 SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
      sleep 1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done

  log "  $label PID=$pid 已退出"
}

# 来源 1：pid 文件
if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "${OLD_PID:-}" ]]; then
    stop_pid "$OLD_PID" "pid-file"
  fi
  rm -f "$PID_FILE"
fi

# 来源 2：占用端口的进程（兜底，处理 pid 文件丢失/手动启动等情况）
if command -v lsof >/dev/null 2>&1; then
  PORT_PIDS="$(lsof -ti:"$PORT" 2>/dev/null || true)"
elif command -v ss >/dev/null 2>&1; then
  PORT_PIDS="$(ss -ltnp 2>/dev/null | awk -v p=":$PORT" '$4 ~ p {
    match($0, /pid=[0-9]+/); print substr($0, RSTART+4, RLENGTH-4)
  }' | sort -u)"
elif command -v fuser >/dev/null 2>&1; then
  PORT_PIDS="$(fuser -n tcp "$PORT" 2>/dev/null | tr -s ' ' '\n' | grep -E '^[0-9]+$' || true)"
else
  PORT_PIDS=""
  log "  WARN: 无 lsof/ss/fuser，跳过端口占用检查"
fi

if [[ -n "$PORT_PIDS" ]]; then
  for pid in $PORT_PIDS; do
    stop_pid "$pid" "port-$PORT"
  done
fi

# ============================================================
# 3. 启动新进程
# ============================================================
log "step 3/5  启动新进程"
log "  bin       = $BIN"
log "  host:port = $HOST:$PORT"
log "  watch     = $WATCH_DIR"
log "  audit-log = $AUDIT_LOG"
log "  log-file  = $LOG_FILE"

# 滚动旧日志，避免无限增长
if [[ -f "$LOG_FILE" ]]; then
  mv "$LOG_FILE" "${LOG_FILE}.$(date '+%Y%m%d-%H%M%S').bak"
fi

nohup "$BIN" --serve \
  --watch "$WATCH_DIR" \
  --host "$HOST" \
  --port "$PORT" \
  --audit-log "$AUDIT_LOG" \
  > "$LOG_FILE" 2>&1 &

NEW_PID=$!
echo "$NEW_PID" > "$PID_FILE"

log "  PID=$NEW_PID 已写入 $PID_FILE"

# ============================================================
# 4. 等待启动 + 健康检查
# ============================================================
log "step 4/5  等待启动 (timeout=${HEALTH_TIMEOUT_SEC}s)"

waited=0
while (( waited < HEALTH_TIMEOUT_SEC )); do
  # 进程死了立即报错
  if ! kill -0 "$NEW_PID" 2>/dev/null; then
    log "ERROR: 新进程已退出，日志尾部："
    tail -n 30 "$LOG_FILE" >&2 || true
    rm -f "$PID_FILE"
    exit 2
  fi

  # 健康检查（无 curl 则降级为只检查进程存活）
  if (( SKIP_HEALTH == 1 )); then
    sleep 2
    log "  进程存活（未配 curl，跳过 health 校验）"
    break
  fi

  if curl -fsS --max-time 2 "http://127.0.0.1:${PORT}${HEALTH_PATH}" >/dev/null 2>&1; then
    log "  /api/health OK"
    break
  fi

  sleep 1
  waited=$((waited + 1))
done

if (( waited >= HEALTH_TIMEOUT_SEC )); then
  log "ERROR: ${HEALTH_TIMEOUT_SEC}s 内未通过健康检查，日志尾部："
  tail -n 30 "$LOG_FILE" >&2 || true
  exit 3
fi

# ============================================================
# 5. 汇报
# ============================================================
log "step 5/5  启动成功"
log "  PID       = $NEW_PID  (cat $PID_FILE)"
log "  日志      = tail -f $LOG_FILE"
log "  健康检查  = curl http://${HOST}:${PORT}${HEALTH_PATH}"
log "  停止命令  = ./scripts/serve-stop.sh   或   kill \$(cat $PID_FILE)"
