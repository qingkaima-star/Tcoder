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
  echo "!! source 链里没有 concurrent_heavy_jobs（现在住在 scripts/perf_probes.sh）—— 这一维看不见东西，拒绝起跑" >&2
  exit 3
}

TAG="${1:-$(git rev-parse --short HEAD 2>/dev/null || echo unknown)}"
SAMPLES="${2:-3}"
MODE="${MODE:-idle}"                   # idle=答 T2；interact=答 T1
INPUT="${INPUT:-human}"                  # human=等真人滚；synth=自己投 CGEvent 滚动
# ⇒ 两种输入走**同一道**开录闸门与**同一道**收尾复核：闸门读的是
#   `secondsSinceLastEventType`，它本来就不区分事件来自手还是来自 CGEvent 投递。
#   为 synth 单开一条"跳过检查"的分支，就是给将来的自己留一个骗自己的地方。
DEADLINE_SECS="${3:-1800}"          # 总共最多等多久（默认 30 分钟），超了就如实放弃
LAUNCH_APP="${LAUNCH_APP:-1}"      # 0 = 只等你自己把 App 开到最前面
# MEASURE_LAUNCH=1 ⇒ **录制档**自己起被测实例（要让同一个窗口同时有 xctrace 与 FramePulse）。
# 这时排程器必须**不**起实例，两条都是 09-22 排演实测出来的，不是推想：
#   ① `instance_pids()` 是 `pgrep -x TcoderMonitor`，录制档起的裸二进制也算一个
#     ⇒ 排程器起了一个、录制档再起一个 = 2 个 ⇒ `require_idle_target` 必拒（会连撞满重试上限）；
#   ② 排程器投的合成滚动落在**排程器那个实例**上，而 xctrace attach 的是另一个
#     ⇒ 一份"没人被滚却被记成交互期"的假配对。
# 所以这一档把"起实例 + 投滚动"整包让给录制档，排程器只保证场上为零。
# 【不是"给 synth 跳过检查"】上面注释里那条纪律仍然成立：开录检查没有取消，
# 只是搬到滚动真正发生的地方（录制档里"输入器起来了"＋收尾复核"这段窗口里确实在动"）。
HARNESS_LAUNCHES="${MEASURE_LAUNCH:-0}"
QUIET_WANT=8                        # 比闸门的 5 s 留一点余量，免得刚过线就开始动
INTERACT_WANT="${INTERACT_WANT:-3}" # interact 档：静默 <3 s 才算"人正在滚"（滚轮事件间隔通常 <1 s）
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
# 【今天实测的失效】原来三件事共用 `trap cleanup EXIT INT TERM`，而 handler 里没有 exit
# ⇒ bash 跑完 trap 就**回去继续等**：TERM/INT 都杀不掉它（今晚 kill -TERM 两次没反应）。
# 只能 -9，而 -9 会跳过 cleanup ⇒ 我起的那个实例留在场上，变成下一个人的"实例数不为 1"。
# 这条修的就是我自己。
on_signal() {
  cleanup
  echo "!! 收到中断信号 ⇒ 收尾自己起的实例并终止（不绕闸、不给人留坑）" >&2
  exit 130
}
trap cleanup EXIT
trap on_signal INT TERM

quiet_seconds() {  # 整机人手静默。**只转发**，不再自己编一份二进制、自己写一份正则
  # 原来这里是第二把尺子：`swiftc` 单独编到 /tmp/tcoder-quiesce-wait-$$，
  # 解析用 `[0-9.]*` 而 preflight 用 `[0-9.-]*` —— 后者能把哨兵 -1 抠出来，前者抠成空串。
  # 两份迟早分叉，而这次分叉的下游是"要不要开录"。
  quietest_seconds "$(quiescence_probe)"
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

SLOT_HOLD="" SLOT_HOLD_AT=0
slot_holders() {  # 谁占着窗口：把只读诊断搬进拒因里（缓存 60 s，别每 5 s 打一次 lsof）
  local now; now=$(date +%s)
  if [ -z "$SLOT_HOLD" ] || [ $((now - SLOT_HOLD_AT)) -ge 60 ]; then
    SLOT_HOLD=$(./scripts/perf_who_holds_the_slot.sh 2>/dev/null | sed -n '3,20p' \
                | tr -s ' ' | tr '\n' ' @ ')
    SLOT_HOLD_AT=$now
  fi
  # 读不到要说"读不到"，不许留空——空串会被读成"没有实例占着"，那正好是反的。
  printf '%s' "${SLOT_HOLD:-诊断脚本没出东西（不等于场上没有实例）}"
}

wait_for() {  # wait_for <人类可读的条件名> <判定函数>；不满足就一直等，超时按失败退出
  local what="$1" check="$2" waited=0 reason=""
  if [ "$MODE" = "interact" ] && [ "$INPUT" = "synth" ]; then
  ensure_synth_scroller || { echo "!! 合成输入器准备失败 ⇒ 一趟都不跑（不拿 idle 数冒充 T1）" >&2; exit 4; }
fi
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
  # 「为什么量不到」原来只答一句事实、不答下一步该做什么，于是人会以为"再等等就好"。
  # 今晚真实现场是主树漏下 6 个 + 一棵已删树的孤儿 1 个，闸门从夜里一直拒到上午——
  # 把只读诊断接进来，一句话里带上 pid、跑了多久、哪棵树、那棵树还在不在。
  if [ "$n" != "1" ]; then
    echo "有 $n 个实例（多实例会互相回写全局状态，读数没意义）：$(slot_holders)"
    return 1
  fi
  echo "唯一那个实例不是本树起的（attach 它会量到别人的构建）：$(slot_holders)"
  return 1
}

cond_no_instance() {  # MEASURE_LAUNCH=1 那一档用：场上必须**一个都没有**，留给录制档去起那一个
  local n; n=$(instance_count)
  [ "$n" = "0" ] && return 0
  echo "场上有 $n 个实例（这一档的实例由录制档自己起，多一个就是『attach 错人』或『多实例拒跑』）：$(slot_holders)"
  return 1
}

cond_quiet() {  # idle 档：等"整段够久没人动"
  local q; q=$(quiet_seconds)
  probe_usable "$q" || { echo "静默探针取不到（拿到「${q:-空}」），不知道有没有人在动，不开录"; return 1; }
  [ "$(human_input_in_window "$q" "$QUIET_WANT")" = "窗口内没人" ] && return 0
  echo "人手 ${q}s 前还在动（要 ≥${QUIET_WANT}s）"
  return 1
}

cond_someone_active() {  # interact 档：**必须检测到有人正在动**才开录
  # 与 cond_quiet 是同一条尺子的两端（一个问"够久了吗"，一个问"还差得远吗"），
  # 所以取数、哨兵、分类三步全部复用，只有阈值换成交互档的。
  # 这里若写成 `q < INTERACT_WANT` 的裸数值比较，哨兵 -1 会让"量不到"变成"最快开录"——
  # 那条恒真的闸门正是 selfcheck 第 20 项要当场咬住的东西。
  local q; q=$(quiet_seconds)
  probe_usable "$q" || { echo "静默探针取不到（拿到「${q:-空}」），不能凭『大概有人在滚』开录"; return 1; }
  [ "$(human_input_in_window "$q" "$INTERACT_WANT")" = "窗口内有人" ] && return 0
  echo "人手已静默 ${q}s（交互档要 <${INTERACT_WANT}s，也就是**正在滚**）"
  return 1
}

cond_no_heavy_jobs() {  # 录制档自己会拒这一维，排程器就必须**先等它**，否则只是连续烧掉几次尝试
  # 实测：2026-09-21 12:02 那轮三趟全被拒，拒因就是别人的 `swift-test`/`xctest`
  # （`load1` 只有 5.23/15，旧闸门会**静默收下**这三趟污染样本）。
  declare -f concurrent_heavy_jobs >/dev/null || { echo "探针函数不在场（宁可不量）"; return 1; }
  local pids; pids=$(concurrent_heavy_jobs)
  [ -z "$pids" ] && return 0
  printf '%s' "机器上有重活在跑（$(concurrent_heavy_jobs_detail)）——两档互踩，等它结束"
  return 1
}

RAISED_THIS_ATTEMPT=0
# `ensure_raiser` / `raise_to_front` 09-22 搬进 scripts/perf_probes.sh：
# MEASURE_LAUNCH 那条路（harness 自己起实例）也要带前台，而"怎么带前台"不该有两份。

cond_front_is_ours() {
  local f; f=$(front_app)
  case "$f" in *Tcoder*) return 0;; esac
  # 抢不到就如实等；但**每次尝试只主动 raise 一次**：
  # 两条车道互相 raise 就是焦点拉锯，那会让两边的读数同时变成垃圾。
  local tp; tp="${TARGET_PID:-$(my_instance_pid 2>/dev/null | head -1)}"
  if [ "$RAISED_THIS_ATTEMPT" = "0" ] && [ -n "$tp" ]; then
    RAISED_THIS_ATTEMPT=1
    raise_to_front "$tp" \
      && echo "    （已把自己那个实例带到前台一次 pid=$tp；再被抢走就等，不拉锯）"
  fi
  printf '前台是「%s」' "${f:-未知}"
  return 1
}

echo "==> 等窗口：$SAMPLES 趟 ${MODE}（release 口径，rev=$TAG），最长 ${DEADLINE_SECS}s"
[ -x "$START_BIN/Contents/MacOS/TcoderMonitor" ] || { echo "!! 没有 release 产物 $START_BIN；先跑 scripts/build_app.sh release"; exit 2; }

# 1) 起手先等静默：两档都要——interact 档要的是"录起来之后有人滚"，
#    不是"现在就可以插进去"。人正忙着的时候起 App，只会把别人的焦点抢走。
wait_for "人手静默 ≥${QUIET_WANT}s" cond_quiet || exit 1

# 2) 起一个实例（或复用已有的那一个），并确认前台是它
#    MEASURE_LAUNCH=1 时反过来：排程器**不起**，只等场上清零（见上面 HARNESS_LAUNCHES 那段）。
if [ "$HARNESS_LAUNCHES" = "1" ]; then
  echo "    本档：实例与合成滚动都归录制档（MEASURE_LAUNCH=1）⇒ 排程器只保证『场上为零 + 没有重活』"
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || exit 1
  wait_for "场上没有 TcoderMonitor 实例" cond_no_instance || exit 1
else
  if [ "$(instance_count)" = "0" ] && [ "$LAUNCH_APP" = "1" ]; then
    open "$START_BIN" && sleep 4
    started_pid=$(my_instance_pid)
    echo "    已起自己的实例 pid=${started_pid:-?}（收尾只 TERM 这一个）"
  fi
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || exit 1
  wait_for "实例数恰为 1" cond_one_instance || exit 1
  wait_for "前台是被测 App" cond_front_is_ours || exit 1
fi

# 3) 逐趟录。每趟之内 preflight 还会重查五条闸——这里只保证"开始的那一刻"是干净的。
fails=0
for i in $(seq 1 "$SAMPLES"); do
  echo "==> 第 $i/$SAMPLES 趟（档=$MODE）"
  RAISED_THIS_ATTEMPT=0
  # 【每一趟之前都重等一次，而不是开头等一次再连撞三次】
  # 实测 12:20：第 1 趟条件极好（人手已静默 478 s）并成功出数；第 2、3 趟
  # 因为人回来把 ChatGPT 调到最前面而被拒——当时的排程器只会立刻硬撞下一趟，
  # 于是"三趟一致"变成"一次成功两次自撞"。等条件回来才是正确动作。
  # 起 App 只在没有实例时做一次；后面几趟复用同一个实例（重启会让节拍重新预热）。
  # MEASURE_LAUNCH=1 走上面那条分工：排程器清零，录制档起实例 + 朝**它 attach 的那个 pid** 投滚动。
  if [ "$HARNESS_LAUNCHES" = "1" ]; then
    wait_for "本仓没有重活在跑" cond_no_heavy_jobs || break
    wait_for "场上没有 TcoderMonitor 实例" cond_no_instance || break
  else
  if [ "$(instance_count)" = "0" ] && [ "$LAUNCH_APP" = "1" ]; then
    open "$START_BIN" && sleep 4
    started_pid=$(my_instance_pid)
    echo "    已起自己的实例 pid=${started_pid:-?}（收尾只 TERM 这一个）"
  fi
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || break
  wait_for "实例数恰为 1" cond_one_instance || break
  wait_for "前台是被测 App" cond_front_is_ours || break
  if [ "$MODE" = "interact" ]; then
    # 【开录时机：等"有人正在动"，不是等"没人动"】前三轮交互期全作废（`窗口内没人`），
    # 根因不是人不配合，是我的时序自相矛盾：这一档要求窗口里有人滚，
    # 我却**先等 8 秒静默再开录**——开录那一刻恰好最没人动，之后全靠人猜"现在该滚了"。
    # 改成：你只管滚，我检测到你在滚才开录，整段窗口自然落在滚动过程中。
    if [ "$INPUT" = "synth" ]; then
      # 投事件器活着才谈开录：编译失败 / 投递 0 拍都会让它非零退出，
      # 而闸门那边看不到任何"新的输入事件" ⇒ 自然走"等不到人在动"那条放弃路径。
      start_synth_scroller "$(my_instance_pid 2>/dev/null | head -1)" \
        || { echo "!! 合成输入器起不来，本趟不开录" >&2; break; }
    fi
    wait_for "有人正在滚动（静默 <${INTERACT_WANT}s）" cond_someone_active || break
  else
    wait_for "人手静默 ≥${QUIET_WANT}s" cond_quiet || break
  fi
  fi
  if [ "$MODE" = "interact" ]; then
    # T1 的判据是"交互期 hitch=0"，而合成滚动两条撤因都在 spec §4（进程内滚动不发 NSEvent，
    # T3 暂停根本不会生效）。所以这一档**只有人手能举证**：闸门会反过来要求
    # "这 20 秒里有人动过"，没人滚就被拒——不会伪装成一趟好数据。
    echo "    ★ 请**从现在起持续滚动**被测窗口（性能页或代码页都行，按 120Hz 的体感滚，别停）。"
    echo "      我一检测到你正在滚就开录（约 50 s），你不用猜时机、也不用等我发话。"
  fi
  # meta 里的来源要带上**投递节奏**：25 Hz 与 125 Hz 的输入器采出的帧数不是一回事，
  # 不带参数的话，两批不同输入率的样本会被当成同一批混着引用（今晚就差点这么混）。
  INPUT_SOURCE="$INPUT"
  [ "$INPUT" = "synth" ] && INPUT_SOURCE="synth@${SYNTH_GAP_MS:-8}ms"
  export INPUT_SOURCE
  if ./scripts/perf_harness.sh "$MODE" "$SCRATCH/tcoder-perf-$TAG-$MODE-run$i"; then
    echo "    ✓ 第 $i 趟完成"
  else
    echo "    ✗ 第 $i 趟被闸门拒绝或失败（不绕、不记）"
    fails=$((fails + 1))
  fi
done

echo "==> 完成：$((SAMPLES - fails))/$SAMPLES 趟可用（档=$MODE）；产物 $SCRATCH/tcoder-perf-$TAG-$MODE-run*/"
echo "    重打读数：./scripts/perf_harness.sh report $SCRATCH/tcoder-perf-$TAG-$MODE-run1"
echo "    （表头会写明测量期间；interact 档才有资格答 T1，idle 档只答心跳期）"
[ "$fails" -lt "$SAMPLES" ] || exit 1
