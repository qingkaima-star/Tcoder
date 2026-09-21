#!/bin/bash
# perf_wait_window.sh —— 「等到机器真空下来，再自动量 T2」的排程器。
#
# 为什么要它：`idle` 档的五条闸门（实例=1、前台是被测 App、有在屏窗口、load 合格、
# 人手静默 ≥5s）在任何一次**手动**尝试里都可能被其中一条挡掉，
# 于是"找一个 5 分钟的窗口"这件事变成人的负担——今天就是这样被挡了两次。
# 这个脚本把"等"从人身上挪到机器上：轮询到条件真的满足，才开录。
#
# 它**不做**的事（都是这一轮踩过或明令禁止的）：
#   · 不 kill、不信号、不按 bundle id 广播退出别的实例（AGENTS -1.3）；
#     只对自己 `open` 起来的那一个 pid 在收尾时发 TERM。
#   · 不用 `IGNORE_CONTEXT_GATE` / `ALLOW_UNQUIESCENT` 绕闸门——绕过去的读数本来就不要。
#     这里只有"等"，没有"放行"。
#   · 不采交互期：T1 必须真人滚 20 秒（`interact` 档），合成滚动两条撤因见规范 §4。
set -u
cd "$(dirname "$0")/.." || exit 1
# 排程器要等的所有条件，必须和录制档闸门**用同一把尺子**——所以直接 source preflight。
# 自己再 pgrep 一遍就是第二份口径：两份迟早分叉，而分叉的方向永远是"排程器以为可以了"。
# shellcheck source=/dev/null
source scripts/perf_preflight.sh
# 【反向的那类 bug】探针函数不存在时 `$(concurrent_heavy_jobs)` 得到空串，
# 于是"没有重活"**永远为真**——一条恒放行闸门比恒拒更危险，因为它连报错都没有。
# 今天刚修过恒拒（前台名比错），这条断言防的是镜像方向。
declare -f concurrent_heavy_jobs >/dev/null || {
  echo "!! scripts/perf_preflight.sh 里没有 concurrent_heavy_jobs —— 这一维看不见东西，拒绝起跑" >&2
  exit 3
}

TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
SAMPLES="${2:-3}"
MODE="${MODE:-idle}"                   # idle=答 T2；interact=答 T1（**必须真人滚**）
DEADLINE_SECS="${3:-1800}"          # 总共最多等多久（默认 30 分钟），超了就如实放弃
LAUNCH_APP="${LAUNCH_APP:-1}"      # 0 = 只等你自己把 App 开到最前面
QUIET_WANT=8                        # 比闸门的 5 s 留一点余量，免得刚过线就开始动
POLL=5
START_BIN="$PWD/dist/Tcoder.app"

started_pid=""
cleanup() {
  # 只收拾自己起的那个；别人的实例一个都不碰。
  if [ -n "$started_pid" ] && kill -0 "$started_pid" 2>/dev/null; then
    local comm; comm=$(ps -o comm= -p "$started_pid" 2>/dev/null | sed 's#.*/##')
    [ "$comm" = "TcoderMonitor" ] && kill -TERM "$started_pid" 2>/dev/null
  fi
}
trap cleanup EXIT INT TERM

quiet_seconds() {  # 整机人手静默；探针取不到就返回 -1（调用方按"不合格"处理，与 preflight 同口径）
  local bin="/tmp/tcoder-quiesce-wait-$$" out
  if [ ! -x "$bin" ]; then
    swiftc -O -target arm64-apple-macos14.0 scripts/input_quiescence.swift -o "$bin" 2>/dev/null || { echo "-1"; return; }
  fi
  out=$("$bin" 2>/dev/null | tail -1)
  printf '%s' "$out" | sed -n 's/.*静默=\([0-9.]*\)s.*/\1/p' | head -1
}

front_app() {
  local asn; asn=$(lsappinfo front 2>/dev/null)
  [ -n "$asn" ] && lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/^"LSDisplayName"="\(.*\)"$/\1/p'
}

instance_count() { pgrep -x TcoderMonitor 2>/dev/null | wc -l | tr -d ' '; }
# 只有"恰好一个实例"还不够：那一个必须是**我这棵树**起的那一个。
# 别人 dist 里的同名的 App 也叫 TcoderMonitor，attach 上去会把别人的构建当成我的读数。
# （`ps -o args=` 在本机被拒，所以用 `pgrep -f` 的全路径匹配来认。）
MY_BIN="$START_BIN/Contents/MacOS/TcoderMonitor"
my_instance_pid() { pgrep -fx "$MY_BIN" 2>/dev/null | head -1; }

wait_for() {  # wait_for <人类可读的条件名> <判定函数>；不满足就一直等，超时按失败退出
  local what="$1" check="$2" waited=0 reason=""
  while :; do
    if reason=$($check); then
      echo "    ✓ $what"
      return 0
    fi
    if [ "$waited" -ge "$DEADLINE_SECS" ]; then
      echo "!! 等了 ${DEADLINE_SECS}s 仍未等到「$what」（最后一次：$reason）——放弃，不绕闸、不采脏样本"
      return 1
    fi
    [ "$waited" -eq 0 ] && echo "    … 还没等到「$what」（$reason），每 ${POLL}s 再看一次"
    sleep "$POLL"; waited=$((waited + POLL))
  done
}

cond_one_instance() {  # 满足则回 0 且不打印；不满足则打印原因再回 1
  local n mine; n=$(instance_count); mine=$(my_instance_pid)
  if [ "$n" = "1" ] && [ -n "$mine" ]; then return 0; fi
  if [ "$n" = "0" ]; then echo "还没有实例在跑"; return 1; fi
  if [ "$n" != "1" ]; then echo "有 $n 个实例（多实例会互相回写全局状态，读数没意义）"; return 1; fi
  echo "唯一那个实例不是本树起的（attach 它会量到别人的构建）"
  return 1
}

cond_quiet() {
  local raw q
  raw=$(quiet_seconds); q=${raw:- -1}
  if python3 -c "import sys; sys.exit(0 if float('$q'.strip() or -1) >= $QUIET_WANT else 1)"; then
    return 0
  fi
  echo "人手 ${q}s 前还在动（要 ≥${QUIET_WANT}s）"
  return 1
}

cond_no_heavy_jobs() {  # 录制档自己会拒这一维，排程器就必须**先等它**，否则只是连续烧掉几次尝试
  # 实测：2026-09-21 12:02 那轮三趟全被拒，拒因就是别人的 `swift-test`/`xctest`
  # （`load1` 只有 5.23/15，旧闸门会**静默收下**这三趟污染样本）。
  declare -f concurrent_heavy_jobs >/dev/null || { echo "探针函数不在场（宁可不量）"; return 1; }
  local pids; pids=$(concurrent_heavy_jobs)
  [ -z "$pids" ] && return 0
  printf '有本仓重活在跑（pid %s：swiftc / swift-test / xctest）' "$pids"
  return 1
}

cond_front_is_ours() {
  local f; f=$(front_app)
  case "$f" in *Tcoder*) return 0;; esac
  printf '前台是「%s」' "${f:-未知}"
  return 1
}

echo "==> 等窗口：$SAMPLES 趟 idle（release 口径，rev=$TAG），最长 ${DEADLINE_SECS}s"
[ -x "$START_BIN/Contents/MacOS/TcoderMonitor" ] || { echo "!! 没有 release 产物 $START_BIN；先跑 scripts/build_app.sh release"; exit 2; }

# 1) 起手先等静默：两档都要——interact 档要的是"录起来之后有人滚"，
#    不是"现在就可以插进去"。人正忙着的时候起 App，只会把别人的焦点抢走。
wait_for "人手静默 ≥${QUIET_WANT}s" cond_quiet || exit 1

# 2) 起一个实例（或复用已有的那一个），并确认前台是它
if [ "$(instance_count)" = "0" ] && [ "$LAUNCH_APP" = "1" ]; then
  open "$START_BIN" && sleep 4
  started_pid=$(my_instance_pid)
  echo "    已起自己的实例 pid=${started_pid:-?}（收尾只 TERM 这一个）"
fi
wait_for "本仓没有重活在跑" cond_no_heavy_jobs || exit 1
wait_for "实例数恰为 1" cond_one_instance || exit 1
wait_for "前台是被测 App" cond_front_is_ours || exit 1

# 3) 逐趟录。每趟之内 preflight 还会重查五条闸——这里只保证"开始的那一刻"是干净的。
fails=0
for i in $(seq 1 "$SAMPLES"); do
  echo "==> 第 $i/$SAMPLES 趟（档=$MODE）"
  # 【每一趟之前都重等一次，而不是开头等一次再连撞三次】
  # 实测 12:20：第 1 趟条件极好（人手已静默 478 s）并成功出数；第 2、3 趟
  # 因为人回来把 ChatGPT 调到最前面而被拒——当时的排程器只会立刻硬撞下一趟，
  # 于是"三趟一致"变成"一次成功两次自撞"。等条件回来才是正确动作。
  # 起 App 只在没有实例时做一次；后面几趟复用同一个实例（重启会让节拍重新预热）。
  if [ "$(instance_count)" = "0" ] && [ "$LAUNCH_APP" = "1" ]; then
    open "$START_BIN" && sleep 4
    started_pid=$(my_instance_pid)
    echo "    已起自己的实例 pid=${started_pid:-?}（收尾只 TERM 这一个）"
  fi
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || break
  wait_for "实例数恰为 1" cond_one_instance || break
  wait_for "前台是被测 App" cond_front_is_ours || break
  if [ "$MODE" = "interact" ]; then
    # 交互期**不等静默**：那一维是 idle 的判据（要的是没人动）。这里改成明确倒计时，
    # 让人知道"从这一刻起滚"，而不是没人动的瞬间开录、然后靠猜。
    echo "    … 5 秒后开录：请从此刻起持续滚动被测窗口，一直滚到本趟结束（约 50 s）"
    sleep 5
  else
    wait_for "人手静默 ≥${QUIET_WANT}s" cond_quiet || break
  fi
  if [ "$MODE" = "interact" ]; then
    # T1 的判据是"交互期 hitch=0"，而合成滚动两条撤因都在 spec §4（进程内滚动不发 NSEvent，
    # T3 暂停根本不会生效）。所以这一档**只有人手能举证**：闸门会反过来要求
    # "这 20 秒里有人动过"，没人滚就被拒——不会伪装成一趟好数据。
    echo "    ★ 接下来这 ~45 秒：请用鼠标滚轮**连续滚动被测窗口**（性能页或代码页都行），"
    echo "      按 120Hz 的体感滚，别停——停在页面顶部空转会被判成「没人在滚」。"
  fi
  if ./scripts/perf_harness.sh "$MODE" "/tmp/tcoder-perf-$TAG-$MODE-run$i"; then
    echo "    ✓ 第 $i 趟完成"
  else
    echo "    ✗ 第 $i 趟被闸门拒绝或失败（不绕、不记）"
    fails=$((fails + 1))
  fi
done

echo "==> 完成：$((SAMPLES - fails))/$SAMPLES 趟可用（档=$MODE）；产物 /tmp/tcoder-perf-$TAG-$MODE-run*/"
echo "    重打读数：./scripts/perf_harness.sh report /tmp/tcoder-perf-$TAG-$MODE-run1"
echo "    （表头会写明测量期间；interact 档才有资格答 T1，idle 档只答心跳期）"
[ "$fails" -lt "$SAMPLES" ] || exit 1
