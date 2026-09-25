#!/usr/bin/env bash
# perf_window_gates.sh —— 「等到机器真空下来」这一层的**判据之外**部分：等窗循环 `wait_for`、
# 五条闸各自的 `cond_*` 判定、以及几个取数转发（静默秒数 / 前台名 / 实例数 / 我这一个的 pid /
# 谁占着窗口）。由 `perf_wait_window.sh` **source**，不单独执行。
#
# 2026-09-25 从排程器搬出：#55 的"同窗补试"加进去之后排程器涨到 **404/400**，
# 按本仓口径「拆，不抬线」把这一层搬出去（**逐字节原文**，一个字符没改；
# 拆前拆后各跑一次 `bash -n` 与 selfcheck 全量）。搬的偏偏不是判据本身而是
# "判据外面那层壳"，因为这里还有一条更要紧的好处：
#   **以前要验一条闸门，只能对整份排程器做文本匹配**（第 36 项那族就是这么写的），
#   而排程器一 source 就开始等窗口 —— 反例点不到函数。搬成库之后
#   `cond_*` / `wait_for` 可以被单独 source 来喂夹具（下一步的口子，本次先不扩）。
#
# 【为什么 `cond_instance_ready` **不留在这里**】第一版把整层搬完，selfcheck 当场红：
#   第 29 项要求"会 `open` 起实例的那份脚本必须有 trap 收尾"。这条不是形式主义——
#   09-22 就是因为它漏了 trap，主树留下 6 个 ppid=1 的实例，把所有人的帧率测量
#   从夜里押拒到上午。而"起实例的代码"与"负责收尾的 trap"**必须在同一段进程里**：
#   搬进库之后库自己没法 trap（谁 source 谁遭殃：会盖掉调用方那张已有的 trap），
#   给库开一格"收尾归调用方"的豁免更是把这条判据变成免检通道。
#   ⇒ 于是那个函数留在排程器。**一条守卫把搬家逼回原形，说明守卫是对的。**
#
# ⚠ 这一层的函数**读调用方的全局**（`QUIET_WANT` / `DEADLINE_SECS` / `MY_BIN` /
#   `START_BIN` / `INTERACT_WANT`…，bash 动态作用域）。所以 source 它的人必须先定义那些量，
#   否则第一次调用就在 `set -u` 下报未初始化 —— 那是有意的：闸门不许带着默认值放行。
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

cond_quiet() {  # idle 档：等"整段够久没人动"。参数=门槛秒数，不给就用默认那一档
  local q want; q=$(quiet_seconds); want="${1:-$QUIET_WANT}"
  probe_usable "$q" || { echo "静默探针取不到（拿到「${q:-空}」），不知道有没有人在动，不开录"; return 1; }
  [ "$(human_input_in_window "$q" "$want")" = "窗口内没人" ] && return 0
  echo "人手 ${q}s 前还在动（要 ≥${want}s）"
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
