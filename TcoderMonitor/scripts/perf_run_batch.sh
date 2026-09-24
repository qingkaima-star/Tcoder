#!/bin/bash
# =============================================================================
# perf_run_batch.sh —— 把"跑一整批 T2 认证测量"从一次性手棒搬成有主的东西。
#
# 用法: MODE=idle scripts/perf_run_batch.sh <批次标签> [趟数=6] [等窗上限=1800]
#   SKIP_BUILD=1   复用已有 dist 产物（只核对归属，不重打包）——同批内复用产物走这个，别重打包
#   RUNS/DEADLINE  也可用同名环境变量给（位置参数优先）
#
# 为什么要搬进 `scripts/`（缺陷 #56 的根治动作）：
#   `.scratch/run_t2_*.sh` 那一族是我一次一批现写的一次性棒，**没有 trap**——
#   棒被 TERM 之后，它起的 GUI 实例与子棒都留在场上（09-24 夜里 t17 就留了一格 `REFUSED` 残骸，
#   更早还留过一棵已删工作树的 11 小时孤儿）。而"实例数恰为 1"是第七维闸门，
#   孤儿会把后面每一批一路押死。审计表（`perf_launcher_audit.sh` + selfcheck 第 29 项）
#   只扫 `scripts/perf_*` ⇒ 住在 `.scratch/` 里的棒**根本不在任何尺子的射程内**：
#   写在这里，起实例就必须同时被"有 kill、有 trap、不许按 bundle id 广播退"这三条钉着。
#
# 三条自己的规矩（都是这一轮付过学费的）：
#   · 归属只按**全路径**认自己起的那些（AGENTS -1.3：不给别人的进程发信号）；
#   · 起跑前与收尾后各数一次实例并打出来（需求方 2.1：自己起的自己退）；
#   · 批次的可用数**交给 `perf_trio_agreement.py` 现算**，不在这里手打 run1..runN 的区间
#     （§BP：手打区间把 8 个产物目录数成 6 个，把已达标的批次报成未达标）。
# =============================================================================
set -uo pipefail
cd "$(dirname "$0")/.."        # → TcoderMonitor/

TAG="${1:-}"; RUNS="${2:-${RUNS:-6}}"; DEADLINE="${3:-${DEADLINE:-1800}}"
[ -n "$TAG" ] || { echo "!! 用法: $0 <批次标签> [趟数] [等窗上限]" >&2; exit 2; }
MODE="${MODE:-idle}"
START_BIN="$PWD/dist/Tcoder.app"
MY_BIN="$START_BIN/Contents/MacOS/TcoderMonitor"
SCRATCH="$PWD/../.scratch"
started_any=""

mine() { pgrep -fx "$MY_BIN" 2>/dev/null || true; }        # 只认这一条全路径，不按 bundle id 广播

nap() {  # nap <秒> —— **分片**睡。为什么不用一条 `sleep 400`：
  # bash 的 trap 要等**当前那条前台命令返回**才执行，长 sleep 会把收尾拖到它结束为止
  # ——09-25 06:44 我自己拿这一条把新脚本验了一遍：预热用 `sleep "${WARMUP_SECONDS:-200}"`，
  # TERM 之后 12 秒实例还在场（等价于 §BM 那条"杀一条链会杀掉下一条链的实例"的形状，只是这次是漏收）。
  # 分片之后最坏延迟就是一片（5 s），trap 才真的算有。
  local left="${1:-0}"
  while [ "$left" -gt 0 ]; do sleep 5; left=$((left - 5)); done
}

retire_mine() {  # 收尾：只退我自己按全路径认出的那些；一个都不碰别人的
  local p n=0
  for p in $(mine); do
    kill -TERM "$p" 2>/dev/null && n=$((n + 1))
  done
  [ "$n" -gt 0 ] && echo "    退掉自己起的实例 $n 个（全路径匹配，不广播）" >&2
  return 0
}
trap 'retire_mine; exit 143' INT TERM       # 被中断也先把实例收干净（第 29 项判的就是这一条）

wait_for_lock() {  # 别人的全量在跑就别抢机器（两档互踩：窗内重活那一维会把自己那批打回）
  local waited=0
  while pgrep -f "locked_build.sh test" >/dev/null 2>&1; do
    nap 20; waited=$((waited + 20))
    [ "$waited" -ge 1800 ] && { echo "!! 等了 30 分钟还有别家全量在跑 ⇒ 这一批不开了" >&2; return 1; }
  done
  echo "==> 锁已让出（等了 ${waited}s）"
}

build_product() {  # 出 release 产物；SKIP_BUILD=1 时只核对归属
  if [ "${SKIP_BUILD:-0}" != "1" ]; then
    ./scripts/build_app.sh release || { echo "!! 构建失败，后面都不做" >&2; return 1; }
  fi
  grep -E 'TCODER_GIT_REVISION|TCODER_GIT_CLEAN|TCODER_BINARY_SHA256=' dist/RELEASE_MANIFEST.env || {
    echo "!! 没有 dist/RELEASE_MANIFEST.env ⇒ 归属无从核对，这一批不测" >&2; return 1; }
  echo "    被测产品码 Sources tree=$(git rev-parse --short=12 HEAD:TcoderMonitor/Sources)"
}

warm_and_hold() {  # 起一个实例并预热（第七维 ≥120 s）；把 pid 交给调用方打印
  echo "    起跑前实例数=$(mine | grep -c . || true)"
  open "$START_BIN" || { echo "!! open 失败 ⇒ 没有可测实例" >&2; return 1; }
  sleep 5
  started_any=$(mine | head -1)
  echo "    我起的实例 pid=${started_any:-取不到}（按全路径认）"
  nap "${WARMUP_SECONDS:-200}"
  echo "    预热后运行时长=$(ps -o etime= -p "${started_any:-0}" 2>/dev/null | tr -d ' ')"
}

report_batch() {  # 可用性判据不在这里自算：按目录枚举交给一致性尺，退出码就是判定的答案
  local dirs
  dirs=$(ls -d "$SCRATCH"/tcoder-perf-"$TAG"-"$MODE"-run* 2>/dev/null | sort -V)
  [ -n "$dirs" ] || { echo "!! 一个产物目录都没有 ⇒ 这一批没量到东西（不等于达标）" >&2; return 1; }
  echo "==> 落盘 $(printf '%s\n' "$dirs" | grep -c .) 个目录，交给 perf_trio_agreement.py 判可用与一致"
  printf '%s\n' "$dirs" | sed 's#.*/tcoder-perf#  #'
  # shellcheck disable=SC2086
  python3 scripts/perf_trio_agreement.py $dirs
}

wait_for_lock || exit 1
echo "==> 出产物（SKIP_BUILD=${SKIP_BUILD:-0}）"
build_product || exit 1
echo "==> 起实例并预热"
warm_and_hold || exit 1
echo "==> 量 $RUNS 趟 $MODE（tag=$TAG，等窗上限 ${DEADLINE}s）"
MODE="$MODE" LAUNCH_APP=0 bash scripts/perf_wait_window.sh "$TAG" "$RUNS" "$DEADLINE"
sched_rc=$?
echo "SCHED-RC=$sched_rc"
report_batch
verdict_rc=$?
retire_mine
sleep 3
echo "    收尾后实例数=$(mine | grep -c . || true)   计划趟数=$RUNS / 等窗退出码=$sched_rc / 一致性判定退出码=$verdict_rc"
echo "DONE-BATCH"
