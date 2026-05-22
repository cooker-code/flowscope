#!/usr/bin/env bash
#
# FlowScope serve mode 停止脚本（服务器侧使用）
#
# 行为：
#   1. 读 pid 文件优雅 stop
#   2. 找端口占用进程兜底
#   3. 已停止时返回 0（幂等）
#

set -euo pipefail

PORT="${PORT:-7681}"
PID_FILE="${PID_FILE:-logs/flowscope-serve.pid}"
SHUTDOWN_TIMEOUT_SEC="${SHUTDOWN_TIMEOUT_SEC:-10}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

stop_pid() {
  local pid="$1"
  local label="$2"

  if ! kill -0 "$pid" 2>/dev/null; then
    log "  $label PID=$pid 不存在"
    return 0
  fi

  log "  $label PID=$pid 发送 SIGTERM"
  kill -TERM "$pid" 2>/dev/null || true

  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if (( waited >= SHUTDOWN_TIMEOUT_SEC )); then
      log "  $label PID=$pid 超时未退出，SIGKILL"
      kill -KILL "$pid" 2>/dev/null || true
      sleep 1
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  log "  $label PID=$pid 已退出"
}

stopped_any=0

if [[ -f "$PID_FILE" ]]; then
  OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [[ -n "${OLD_PID:-}" ]]; then
    stop_pid "$OLD_PID" "pid-file"
    stopped_any=1
  fi
  rm -f "$PID_FILE"
fi

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
fi

if [[ -n "$PORT_PIDS" ]]; then
  for pid in $PORT_PIDS; do
    stop_pid "$pid" "port-$PORT"
    stopped_any=1
  done
fi

if (( stopped_any == 0 )); then
  log "未发现运行中的 flowscope 服务"
else
  log "停止完成"
fi
