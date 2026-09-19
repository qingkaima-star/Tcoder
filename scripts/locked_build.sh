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

echo "[lock] acquired; running: swift $*"
swift "$@"
code=$?
[ $code -ne 0 ] && echo "[lock] swift exited with status $code"
exit $code
