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
#   · 交互档（MODE=interact）两种输入都行：`INPUT=human` 等真人滚；`INPUT=synth` 由**录制档**
#     朝它自己 attach 的那个 pid 投 CGEvent 滚动（14px/8ms ≈ 125 Hz）。
#     规范 §4 原来那两条撤因已被 09-22 实测推翻一条（CGEvent 不会被静默丢弃）、
#     另一条只适用于"让 App 自己滚"那种进程内方案，与本档无关。
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
# 同一族：闸门的本体搬进 `perf_chain_guard.sh`（经 preflight 的 source 链进来）。
# 它不在，第二条链就会被**静默放行**（函数名打错时 bash 报 127 但主流程照跑），
# 那正是 §BM 烧掉一整批时缺的那道闸——所以看不见就拒跑，别"默认通过"。
declare -f refuse_second_chain >/dev/null || {
  echo "!! source 链里没有 refuse_second_chain（住在 scripts/perf_chain_guard.sh）—— 同树链数看不见，拒绝起跑" >&2
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
# 起跑线要分两档：**复用你已经开着的实例**只要 8 s 余量；**排程器自己起 App 并顶到前台**要 180 s。
# 2026-09-23 14:57 实测（交接笔记 §AJ）：按 8 s 起的那一次，窗口一弹出来就被需求方当场关掉 ⇒
# 三趟一趟没录成，还白抢了三次前台。「挂着等它自己空出来」在这里不成立——场上是有人在用这台机器的，
# 再挂下去就是拿测量去打扰人，而被打扰的人会杀掉我们的实例，两边都拿不到数。
# 这一格只许往上抬（抬到分钟级才是"真的没人用"），压低到闸门以下就是给自己放行。
LAUNCH_QUIET_WANT="${LAUNCH_QUIET_WANT:-180}"
INTERACT_WANT="${INTERACT_WANT:-3}" # interact 档：静默 <3 s 才算"人正在滚"（滚轮事件间隔通常 <1 s）
POLL=5
START_BIN="$PWD/dist/Tcoder.app"

started_pid=""
started_pids=""                      # **这一批起过的每一个**（不是一个）
launches_done=0                      # 本次排程已经起过几次 App（上限见下面 LAUNCH_MAX）
LAUNCH_MAX="${LAUNCH_MAX:-2}"        # 只封顶"反复弹窗"这件事，不封顶等窗口：等待本身仍然到 DEADLINE 才放弃
cleanup() {
  # 只收拾自己起的那些；别人的实例一个都不碰。
  # 【今晚漏两次的那格】原来只记 `started_pid` 一个，而一批里最多允许起 LAUNCH_MAX=2 次
  # （第 2 趟之后场上被录制档收干净 ⇒ 第 3 趟重新起一个，`started_pid` 被覆盖）
  # ⇒ **前一个再也没有人收**，变成下一个人的"实例数不为 1"。22:03 与 22:35 两批各漏一个，
  # 22:44 我自己的 `switch` 档就被这漏下来的那个拒跑（同一台机器上第二个受害者是我）。
  local p comm
  for p in $started_pids; do
    kill -0 "$p" 2>/dev/null || continue
    comm=$(ps -o comm= -p "$p" 2>/dev/null | sed 's#.*/##')
    [ "$comm" = "TcoderMonitor" ] && kill -TERM "$p" 2>/dev/null
  done
  started_pids=""
  # 【今晚第三次泄漏的真相：不是覆盖，是**收养**】闸门按可执行路径认"场上有且只有我这一个实例"，
  # 于是**上一批**留下的同树实例被这一批直接接手录心跳，而它从没进过 `started_pids` ⇒ 收尾谁都不退它。
  # 实测（09-24 02:10）：pid 85518 已经跑了 **2 小时 16 分**才被我按路径手工收掉，
  # 而它同时把别人挡在"实例数不为 1"那条闸门外（那棵树的主人当时就量不了）。
  # 修法只按**全路径**认（`pgrep -fx`），绝不按 bundle id 广播退出 —— AGENTS 横切约束 2.1 的判归属只认路径。
  for p in $(pgrep -fx "$MY_BIN" 2>/dev/null); do
    kill -0 "$p" 2>/dev/null && kill -TERM "$p" 2>/dev/null
  done
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


# 等窗那一层（`wait_for` / 四个 `cond_*` / 取数转发）2026-09-25 搬进 `perf_window_gates.sh`：
# 本文件加进 #55 的同窗补试之后涨到 **404/400**，按本仓口径「拆，不抬线」。
# **`cond_instance_ready` 特意留下**——它里面有那句 `open "$START_BIN"`，而收尾的 trap 在
# 本文件：第 29 项就是为这件事把我这一刀逼回原形（详情写在库文件头注里）。
# 这一层从此还可以被反例单独 source（以前要验一条闸门只能文本匹配整份排程器）。
source "$(dirname "${BASH_SOURCE[0]}")/perf_window_gates.sh"

cond_instance_ready() {  # 场上恰有"我这一个"实例才算好；一个都没有就**当场起**（起之前用高的那条静默门槛）
  # 【为什么"要不要起"必须留在等待循环里】2026-09-23 16:47 现场：起跑那一瞬别人主树的实例还在
  # （场上=1，但不是本树起的）⇒ 一次性的判断落成"不起"；三分钟后它退场，排程器却继续在
  # 「实例数恰为 1」上等到超时，屏幕上还印着那个**已经消失的 pid**。人以为在排队，其实永远等不到。
  local n; n=$(instance_count)
  if [ "$n" != "0" ]; then cond_one_instance; return; fi
  cond_quiet "$LAUNCH_QUIET_WANT" || return 1
  # 【起手机会要有上限】这条判断现在每 5 秒重跑一次；万一"认到自己那个实例"这一步失败，
  # 不加封顶就等于**每 5 秒把 App 提到前台一次**——那不是测量，是对着别人干活的地方反复弹窗。
  # 到顶就停手并报出来，让人来看，而不是自己一直试。
  if [ "${launches_done:-0}" -ge "$LAUNCH_MAX" ]; then
    echo "    已经起过 $LAUNCH_MAX 次仍没拿到『只有我这一个实例』的状态 ⇒ 停手，不每 5 秒重弹一次窗口"
    return 1
  fi
  # **挨着 open 的那道闸不许挪走**：`MEASURE_LAUNCH=1` 那一档的实例归录制档起，
  # 排程器多起一个就是"两边各起一个 ⇒ 多实例拒跑"或"attach 错人"（第 32 项按
  # "guard 与 open 相隔 8 行以内"这个形状认它，也是它真该在的位置——最后一道闸）。
  if [ "$HARNESS_LAUNCHES" = "1" ]; then cond_no_instance; return; fi
  launches_done=$((launches_done + 1))
  open "$START_BIN" && sleep 4
  started_pid=$(my_instance_pid)
  # `open` 是异步的：4 秒没看见不等于起不来。今晚 22:35 与 00:34 两批就栽在这里——
  # 认不到 pid 就直接 `return 1`，而那个 App 半秒后照样出现在场上
  # ⇒ **谁都不负责它**，它变成下一个人的"实例数不为 1"（包 24 修的是"只记最后一个"，
  # 这条是它的兄弟洞：一个都没记上）。
  for _wait in 1 2 3 4 5 6; do
    [ -n "$started_pid" ] && break
    sleep 1
    started_pid=$(my_instance_pid)
  done
  if [ -z "$started_pid" ]; then
    # 撤销这次获取：只 TERM 全路径正好等于 $MY_BIN 的进程——**路径就是归属**，
    # 别人那棵树的同产物流程不匹配这一条（这与包 26 用路径判归属是同一个道理）。
    echo "    !! 起了却没认到 pid ⇒ 撤销这次获取（只收全路径匹配本树产物那些），不把无主实例留给别人" >&2
    for _stray in $(pgrep -fx "$MY_BIN" 2>/dev/null); do kill -TERM "$_stray" 2>/dev/null; done
    return 1
  fi
  started_pids="$started_pids $started_pid"
  echo "    已起自己的实例 pid=${started_pid}（本批累计起过：${started_pids}；收尾逐个 TERM）"
  return 0
}

refuse_second_chain   # 同树只许一条链（§BM 那一坑的闸门版；要并行必须显式 ALLOW_CONCURRENT_CHAIN=1 且出声）

echo "==> 等窗口：$SAMPLES 趟 ${MODE}（release 口径，rev=$TAG），最长 ${DEADLINE_SECS}s"
[ -x "$START_BIN/Contents/MacOS/TcoderMonitor" ] || { echo "!! 没有 release 产物 $START_BIN；先跑 scripts/build_app.sh release"; exit 2; }

# 1) 起手先等静默：两档都要——interact 档要的是"录起来之后有人滚"，
#    不是"现在就可以插进去"。人正忙着的时候起 App，只会把别人的焦点抢走。
#    【"要自己起 App"的高门槛不在这里判】它住在 `cond_instance_ready` 里——**紧挨着 open 那一行**，
#    因此每一趟、每一次重试都算数。写在起跑处会漏：起跑时场上还有别人的实例（就不抬），
#    别人的实例随后退场，后面那次真正的弹窗口就只按 8 秒过关了（§AJ 那晚的形状）。
wait_for "人手静默 ≥${QUIET_WANT}s" cond_quiet || exit 1

# 2) 起一个实例（或复用已有的那一个），并确认前台是它
#    MEASURE_LAUNCH=1 时反过来：排程器**不起**，只等场上清零（见上面 HARNESS_LAUNCHES 那段）。
if [ "$HARNESS_LAUNCHES" = "1" ]; then
  echo "    本档：实例与合成滚动都归录制档（MEASURE_LAUNCH=1）⇒ 排程器只保证『场上为零 + 没有重活』"
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || exit 1
  wait_for "场上没有 TcoderMonitor 实例" cond_no_instance || exit 1
else
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || exit 1
  if [ "$LAUNCH_APP" = "1" ]; then
    wait_for "场上有且只有我这一个实例" cond_instance_ready || exit 1
  else
    wait_for "实例数恰为 1" cond_one_instance || exit 1
  fi
  wait_for "前台是被测 App" cond_front_is_ours || exit 1
fi

# 3) 逐趟录。每趟之内 preflight 还会重查五条闸——这里只保证"开始的那一刻"是干净的。
#    【为什么是 while 而不是 for 1..N】#55：录制挂死的那一趟**不该占掉一个计划槽位**——
#    挂死时环境往往仍然干净，占掉槽位等于把一个稀缺的干净窗口整段扔掉。
#    判据不在这里：`attempt_verdict`（住在 perf_measure_io.sh，有第 62 项反例）只回答
#    "要不要同窗补一次"，这里只做记账；预算按批封顶，默认 1 次。
fails=0
slot=0; attempt=0; oks=0
HANGS=0
HANG_RETRY_BUDGET="${HANG_RETRY_BUDGET:-1}"
HANG_RETRIES_USED=0
RECOVERED=0
PENDING_RETRY=0
while [ "$slot" -lt "$SAMPLES" ]; do
  attempt=$((attempt + 1))
  retrying=0
  [ "$PENDING_RETRY" = "1" ] && retrying=1
  PENDING_RETRY=0
  tag_retry=""
  [ "$retrying" = "1" ] && tag_retry="（同窗补试，不占槽位）"
  # ⚠ 这里不能印「已落定 $slot 趟」：`slot` 在**判废那一支也 +1**（第 272 行），
  # 于是 #120 那批会印「计划 3 趟、已落定 1/2 趟」而收尾是「0/3 趟真的出了产物」——
  # 同一批两个数、中途那句还是好看的。⇒ 老实说"占掉几个槽位"，出产物另给一格。
  echo "==> 第 $attempt 次尝试（档=$MODE，计划 $SAMPLES 趟、已占槽位 $slot 趟／其中真出产物 $oks 趟）$tag_retry"
  # 只有补试那一趟才给 meta 带 `hang_recovered=1`：**没挂的趟不许出现这个字段**，
  # 所以这里 `unset` 而不是写 0 —— `${VAR:+…}` 见 "0" 也算"有值"，写 0 会让每一趟都带上它。
  if [ "$retrying" = "1" ]; then export HANG_RECOVERED=1; else unset HANG_RECOVERED; fi
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
  wait_for "本仓没有重活在跑" cond_no_heavy_jobs || break
  if [ "$LAUNCH_APP" = "1" ]; then
    wait_for "场上有且只有我这一个实例" cond_instance_ready || break
  else
    wait_for "实例数恰为 1" cond_one_instance || break
  fi
  wait_for "前台是被测 App" cond_front_is_ours || break
  # 【#120：预热这一维现在**等**】2026-09-27 现量：`cert15` 三趟全被录制档的 context_gate 拒在
  # 「被测实例只跑了 5s/6s/7s（预热线 120s）」——排程器不等它，于是把一个干净窗口烧了三次。
  # 与上面「录制档会拒的维度，排程器必须先等」同一条判据。
  # ⚠ 只加在**有实例可等**的这一支：`HARNESS_LAUNCHES=1`（MEASURE_LAUNCH 冷启动档）此刻场上
  #   还没有实例（由录制档起），等预热等于等一个不存在的 pid，而那一档本来就在测启动本身。
  wait_for "被测实例已过预热线（${WARMUP_MIN_SECONDS:-120}s）" cond_instance_warm || break
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
  sample_dir="$SCRATCH/tcoder-perf-$TAG-$MODE-run$attempt"
  ./scripts/perf_harness.sh "$MODE" "$sample_dir"; run_rc=$?
  kind="$(refusal_kind "$sample_dir")"
  verdict="$(HANG_RETRIES_USED="$HANG_RETRIES_USED" HANG_RETRY_BUDGET="$HANG_RETRY_BUDGET" \
             attempt_verdict "$sample_dir" "$run_rc")"
  if [ "$run_rc" = "0" ]; then
    slot=$((slot + 1)); oks=$((oks + 1))
    if [ "$retrying" = "1" ]; then
      RECOVERED=$((RECOVERED + 1))
      echo "    ✓ 第 $attempt 次尝试完成（补试补回来的一趟；挂死那一趟仍记在挂死计数里）"
    else
      echo "    ✓ 第 $attempt 次尝试完成"
    fi
  elif [ "$verdict" = "retry" ]; then
    HANGS=$((HANGS + 1)); HANG_RETRIES_USED=$((HANG_RETRIES_USED + 1)); PENDING_RETRY=1
    echo "    ✗ 第 $attempt 次尝试录制挂死 ⇒ 同窗原地补一次（不占槽位、不顺延预热、不绕任何闸）"
  else
    [ "$kind" = "hang" ] && HANGS=$((HANGS + 1))
    slot=$((slot + 1)); fails=$((fails + 1))
    echo "    ✗ 第 $attempt 次尝试被闸门拒绝或失败（判废类型=$kind，不绕、不记）"
  fi
done

# 挂死计数**必须**在补试之后照样出声（#55 硬约束①）：否则"重试"会把这一维的
# 失败率抹成 0 —— 单向朝好看的计数是 §20 那一族盲区，这里点名的就是这个形状。
batch_hang_summary "$HANGS" "$HANG_RETRIES_USED" "$RECOVERED"

# 「可用」这两个字不许由排程器说：它只知道**开录那一刻**闸门没拦，
# 而窗口内的自采复核（包 18）会在事后把整批打回。2026-09-23 20:49 实测：
# 这里印「3/3 趟可用」，同一批在 report/一致性那里是「0 趟可用」——
# 同一个词两个意思，读的人拿到的是相反结论。资格只由判的地方出声。
# 【同一族的第二处，2026-09-25 顺手改掉】原来印的是 `$SAMPLES - $fails`：闸门等不到而
# `break` 出去的那些趟**既不算成功也不算失败**，于是"计划 3 趟、只跑了 1 趟就散场"
# 会印成「3/3 没被拦下」。现在印真数出来的成功趟数，分母照旧是计划数。
echo "==> 采集跑完：$oks/$SAMPLES 趟真的出了产物（档=$MODE，尝试 $attempt 次）；**能不能进表由 report 档与同档一致性判**；产物 $SCRATCH/tcoder-perf-$TAG-$MODE-run*/"
# 【#117：第二个数】「落定 N 趟」过去一直被读成「判据② 有 N 个样本」，而这两件事能差 5 倍
# （交付头上那批：落定 2 趟、含 ② 表 0 趟）。§210 定的过渡规矩现在由代码出，不靠我记得写。
criterion2_batch_line "$SCRATCH"/tcoder-perf-"$TAG"-"$MODE"-run*
echo "    重打读数：./scripts/perf_harness.sh report $SCRATCH/tcoder-perf-$TAG-$MODE-run1"
echo "    （表头会写明测量期间；interact 档才有资格答 T1，idle 档只答心跳期）"
[ "$oks" -gt 0 ] || exit 1
