#!/bin/bash
# Serialize every swift build/test invocation across all concurrent agents.
# SwiftPM's .build directory is not safe for concurrent use, so callers go through here.
# Usage: scripts/locked_build.sh <swift args...>   e.g. scripts/locked_build.sh build
set -u
cd "$(dirname "$0")/.." || exit 1
LOCK_DIR=".build/agents.lock"
mkdir -p .build

holder_alive() {
  [ -f "$LOCK_DIR/pid" ] || return 1
  local pid
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null) || return 1
  [ -n "$pid" ] || return 1
  kill -0 "$pid" 2>/dev/null
}

steal_stale_lock() {
  if [ -d "$LOCK_DIR" ] && ! holder_alive; then
    echo "[lock] reclaiming stale lock (holder pid gone)"
    rm -f "$LOCK_DIR/pid"
    rmdir "$LOCK_DIR" 2>/dev/null
  fi
}

waited=0
while true; do
  steal_stale_lock
  if mkdir "$LOCK_DIR" 2>/dev/null; then break; fi
  [ $((waited % 30)) -eq 0 ] && echo "[lock] waiting; held by pid $(cat "$LOCK_DIR/pid" 2>/dev/null || echo '?')"
  sleep 3
  waited=$((waited+3))
  if [ "$waited" -gt 1200 ]; then
    echo "[lock] waited 1200s, proceeding anyway"
    break
  fi
done

echo $$ > "$LOCK_DIR/pid" 2>/dev/null
cleanup() { rm -f "$LOCK_DIR/pid" 2>/dev/null; rmdir "$LOCK_DIR" 2>/dev/null; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# 2026-09-20 环境事实：本机的工作容器本身已处于一个 sandbox 之中，**嵌套 sandbox 被拒绝**——
# SwiftPM 为自己编译 Package.swift / 执行构建而调用的 `sandbox-exec` 一律报
#   sandbox-exec: sandbox_apply: Operation not permitted
# （实测：`sandbox-exec -p '(version 1)(allow default)' /bin/echo` 可以跑，
#   但任何带 (deny default) 的实际 profile 都 EPERM，所以这不是权限写成 allow-default 就能绕的。）
# `--disable-sandbox` 只关掉 SwiftPM 自己那层沙箱，**不改变任何编译产物**，
# 是本环境下唯一可行的路径，因此在这里默认加上；确实需要保留 SwiftPM 沙箱时设
# TCODER_ALLOW_SWIFTPM_SANDBOX=1。
extra_args=()
if [ "${TCODER_ALLOW_SWIFTPM_SANDBOX:-0}" != "1" ]; then
  case " $* " in
    *" --disable-sandbox "*) ;;
    *) extra_args+=(--disable-sandbox) ;;
  esac
fi

echo "[lock] acquired; running: swift $* ${extra_args[*]:-}"
swift "$@" "${extra_args[@]:-}"
code=$?
[ $code -ne 0 ] && echo "[lock] swift exited with status $code"
exit $code
