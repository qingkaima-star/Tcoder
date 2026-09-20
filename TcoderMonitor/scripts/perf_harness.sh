#!/bin/bash
# =============================================================================
# perf_harness.sh —— Tcoder 性能契约（120Hz）的外部尺子。spec §4.1。
#
# 四档测量（idle / interact / switch，report 是重打）+ 两档不采数的（selfcheck 连 App 都不起、
# probe 只读已有脉冲文件）：
#   idle       attach 现有实例，录 Animation Hitches + Time Profiler，量心跳期（spec §1 那一档）
#   interact   录法同 idle，唯一区别是**录制期间人持续滚动** ⇒ 才有资格答 T1（交互期 hitch=0）
#   switch     逐页冷启动（-selectedDetailSection 中文页名），量首帧与冷构建成本
#   report     读已有输出目录，重打汇总表（不重录，省时间也省磁盘）
#   probe      读 `FramePulse` 落盘的脉冲文件 → 交互期 p95 与 hitch 判定（T1 的唯一入口）
#   selfcheck  不采任何东西：拿合成夹具把尺子自己量一遍（见 cmd_selfcheck）
#
# ## 为什么这里绝不出现 kill / 信号
# AGENTS.md -1.3：进程监控只读展示。本脚本只 `pgrep` / `lsof` 只读探活。
# **2026-09-20 更正**：这里原先写着"需要退出时走 `osascript ... quit`"——那句已经作废。
# 实测 `tell application id "com.tcoder.monitor" to quit` 是**按 bundle id 全机命中**，
# 不分工作树也不分沙箱，会连带杀掉别人正在跑的实例（第三轮取证事故，两家互杀到 0 张图）。
# 现在 switch 档默认**只打印 pid**，由人工 Cmd+Q；确需自动退出时 `SWITCH_TERM=1`
# 才对自己 `$!` 起的那一个 pid 发 SIGTERM（用户 2026-09-20 明确授权，且绝不广播）。
# idle 档连退出都不需要——它 attach 的是**别人已经开着的**实例。
#
# ## 为什么开头就要拦住多实例
# xctrace 按名字 attach 会挑错进程；而 spec §7.5 要求采样期间只有被采的那一个实例
# （`Application Support` 与 `defaults` 域全机唯一，多实例互相回写会让读数失去意义）。
# 所以 `pgrep -x TcoderMonitor` 数量 != 1 时 idle 直接拒跑，只说明原因，不做任何处置。
#
# ## release 与 debug 的绝对值不可混比（spec §7.3）
# release 产物符号可读但内联更激进：**火焰图归因看 debug，交付数看 release**。
# 本脚本默认采 release（dist/Tcoder.app）；采 debug 时读数只能与 debug 基线比。
# 汇总表里的每一列都必须来自同一档产物，跨档拼表等于造假。
#
# ## 输出目录必须带短 HEAD 后缀
# `/tmp/tcoder-perf-<rev>/`：不带后缀时后一批会静默覆盖前一批，
# 于是"改前 vs 改后"最后只剩一列数，回归门禁当场失效。
#
# 用法:
#   scripts/perf_harness.sh idle [输出目录]
#   scripts/perf_harness.sh interact [输出目录]    # 录制期间人持续滚动
#   scripts/perf_harness.sh switch [输出目录]
#   scripts/perf_harness.sh report <输出目录>
#   scripts/perf_harness.sh probe [脉冲文件] [--interaction]   # 缺省取 /tmp 上最新那份
#   scripts/perf_harness.sh selfcheck          # 不采数据，只验尺子自己还活着
# 传参（都有默认值，别改默认值来"让它过"）:
#   SECONDS_HITCHES=20   idle 档 Animation Hitches 录制秒数
#   SECONDS_TP=25        idle 档 Time Profiler 录制秒数（spec §1 主线程样本就是 25 s 档）
#   SECONDS_LAUNCH=10    switch 档每页录制秒数
#   PERF_BIN=<路径>      被采二进制（默认 dist/Tcoder.app/Contents/MacOS/TcoderMonitor）
#   PAGES="总览 性能监控" switch 档只测这几页（默认取 capture_pages_isolated.sh 的九页）
#   DRY_RUN=1            只打印将执行的命令，一条都不跑（用于自检命令拼得对不对）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REV=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
TEMPLATE_HITCH="Animation Hitches"
TEMPLATE_TP="Time Profiler"
TEMPLATE_LAUNCH="App Launch"
SECONDS_HITCHES="${SECONDS_HITCHES:-20}"
SECONDS_TP="${SECONDS_TP:-25}"
SECONDS_LAUNCH="${SECONDS_LAUNCH:-10}"
PERF_BIN="${PERF_BIN:-$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor}"
WINLIST="$PWD/scripts/winlist.swift"
QUIESCE_SRC="$PWD/scripts/input_quiescence.swift"
QUIESCE_BIN=""
QUIESCE_MIN="${QUIESCE_MIN:-5}"
TRACE_REPORT="$PWD/scripts/trace_report.py"
PULSE_REPORT="$PWD/scripts/perf_framepulse.py"
# selfcheck 档的实现放在旁边那个文件里，只在跑 selfcheck 时 source 进来（同一进程、同一批全局量）。
# 为什么搬出去：本仓 ≤800 行棘轮的分母**含 .sh**（`SourceLanguageCatalog` 认 Shell）、ceiling=0，
# 而 selfcheck 一项一个小函数之后本文件会撞线——搬出去才是修复，拧阈值不是。
SELF_CHECK_SRC="$PWD/scripts/perf_selfcheck.sh"
DOMAIN="com.tcoder.monitor"
UUID="11111111-2222-3333-4444-555555555555"
DRY_RUN="${DRY_RUN:-0}"
# idle 档要导出的六张表（spec §4.1）；time-profile 来自第二份 trace，单独导。
HITCH_TABLES=(hitches hitches-updates hitches-renders potential-hangs
              device-display-info displayed-surfaces-per-second)

die() { echo "!! $1" >&2; exit 1; }

run() {  # 打印并执行；DRY_RUN=1 时只打印
  echo "    \$ $*"
  [ "$DRY_RUN" = "1" ] && return 0
  "$@"
}

# -----------------------------------------------------------------------------
# 页名不自己编：与 capture_pages_isolated.sh 共用一份事实来源，
# 否则两边页名漂移会让 switch 档悄悄测到不存在的页（SwiftUI 会回落到默认页）。
# -----------------------------------------------------------------------------
sections() {
  local line
  line=$(grep -m1 '^SECTIONS=(' scripts/capture_pages_isolated.sh) || return 1
  echo "$line" | sed -e 's/^SECTIONS=(//' -e 's/)[^)]*$//' | tr -d '"' | tr ' ' '\n' \
    | sed '/^$/d'
}

instance_pids() { pgrep -x TcoderMonitor 2>/dev/null || true; }

# 取某 pid 的可执行文件绝对路径。**为什么不用 `ps -o args=`**：本机 `ps` 被系统拒绝
# （`/bin/ps: Operation not permitted`，实测在非沙箱下同样如此），于是原来那行永远取空，
# 而 `TARGET_FLAVOR` 会**默认成 release** —— 等于给一份可能来自 debug 的读数贴上 release 标签，
# 正好违反 spec §7.3「两档绝对值不可混比」。`lsof -p` 在本机可用，`txt` 行就是可执行文件。
pid_binary() {  # pid_binary <pid>
  lsof -p "$1" 2>/dev/null | awk '$4 == "txt" { print $NF; exit }'
}

WINLIST_BIN=""

# 窗口存在性探测。**为什么先编译一次**：`xcrun swift winlist.swift` 是 JIT，实测每次 0.3 s；
# 原来 `switch` 档把它放在"首帧轮询"里（最多 60 次），既慢又把探测开销混进了计时。
# 编译成二进制后稳态实测 39~45 ms，且首次 ~508 ms 的 dyld 冷启动由下面这次预热挡在计时窗外。
winlist_probe() {  # winlist_probe <pid> → 有在屏窗口时打印 `窗口号|标题|宽`，否则空
  local pid="$1"
  if [ -z "$WINLIST_BIN" ]; then
    if xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
         -target arm64-apple-macos14.0 "$WINLIST" -o "/tmp/tcoder-winlist-$$" 2>/dev/null; then
      WINLIST_BIN="/tmp/tcoder-winlist-$$"
      "$WINLIST_BIN" "$pid" >/dev/null 2>&1 || true
    else
      echo "    ⚠ winlist 编译失败 → 退回 JIT（单次 ~300 ms，只影响存在性探测，不影响时长口径）" >&2
    fi
  fi
  if [ -n "$WINLIST_BIN" ]; then
    "$WINLIST_BIN" "$pid" 2>/dev/null | head -1
  else
    xcrun swift "$WINLIST" "$pid" 2>/dev/null | head -1
  fi
}

TARGET_BINARY=""   # 由 require_idle_target 填：实际被采的那个二进制的绝对路径
TARGET_FLAVOR=""   # release / debug —— spec §7.3 要求两档的绝对值永不混比

note_target_flavor() {  # note_target_flavor <pid>
  TARGET_BINARY=$(pid_binary "$1")
  # **认不出就说认不出**：原来 `*) release` 是个兜底，配上取不到路径的 `ps`，
  # 会稳定地把「不知道」说成 release。release 与 debug 的绝对值差着一个量级，
  # 这种默认值是把读数卖给第一个来查的人。
  case "$TARGET_BINARY" in
    "") TARGET_FLAVOR="未知（取不到被采二进制 → release/debug 不可判定，本批读数不得与任何基线比）" ;;
    *".build/debug"*) TARGET_FLAVOR="debug" ;;
    *"/dist/Tcoder.app/"*) TARGET_FLAVOR="release" ;;
    *) TARGET_FLAVOR="未知（路径既非 .build/debug 也非 dist/Tcoder.app：$TARGET_BINARY）" ;;
  esac
  echo "    被采二进制=${TARGET_BINARY:-（取不到）} 口径=$TARGET_FLAVOR"
}

quiescence_probe() {  # → 一行 `… 静默=12.34s`；取不到时打印 静默=-1.00s（调用方按"取不到"处理）
  if [ -z "$QUIESCE_BIN" ]; then
    if xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
         -target arm64-apple-macos14.0 "$QUIESCE_SRC" -o "/tmp/tcoder-quiesce-$$" 2>/dev/null; then
      QUIESCE_BIN="/tmp/tcoder-quiesce-$$"
    else
      echo "    ⚠ 静默探针编译失败，退回 JIT（慢一点，不影响读数口径）" >&2
    fi
  fi
  if [ -n "$QUIESCE_BIN" ]; then
    "$QUIESCE_BIN" 2>/dev/null || echo "静默=-1.00s"
  else
    xcrun swift "$QUIESCE_SRC" 2>/dev/null || echo "静默=-1.00s"
  fi
}

quietest_seconds() {  # 从探针那一行里抠出"静默=Xs"的 X
  printf '%s' "${1:-}" | sed -n 's/.*静默=\([0-9.-]*\)s.*/\1/p'
}

preflight_context() {  # preflight_context <outdir> <pid>
  local out="$1" pid="$2" f="" cores load1 front visible others hard=0
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  [ -n "$load1" ] || load1=0
  f="$out/measurement-context.txt"
  front=$(preflight_front_app)
  visible=$(preflight_window_state "$pid")
  others=$(pgrep -x swiftc 2>/dev/null | tr '\n' ' ')
  # 人手静默：整机 load 与并发编译挡得住"机器在忙"，挡不住"有人在点这个窗口"。
  local qline quiet
  qline=$(quiescence_probe)
  quiet=$(quietest_seconds "$qline")

  preflight_write_context "$out" "$f"
  # 四条硬闸各自读上面那几个量（bash 是动态作用域：本函数的 `local` 在被调函数里照样可见，
  # 拆函数没有改变任何取数顺序，也没有引入新的全局量）。
  preflight_gates
  [ "$hard" = "1" ] && [ "${IGNORE_CONTEXT_GATE:-0}" != "1" ] && die "测量上下文不达标（详见 $f）。IGNORE_CONTEXT_GATE=1 可强行跳过，但那批读数必须标注为『条件不合格』。"
  [ "$hard" = "1" ] && echo "    ⚠ IGNORE_CONTEXT_GATE=1：条件不合格，这批读数不得进任何对比表。" >&2
  echo "    上下文已落 $f"
}

preflight_front_app() {  # → 一行前台 App 名；取不到就是「未知」
  # 前台 App：**先走 `lsappinfo`（零权限）**。原来只用 `osascript` + System Events，
  # 而本机那条路被权限拒（实测 `-10004 发生权限违例`），于是永远得到「未知」、
  # 闸门永远拒跑——一条因为取不到数就永远说"不合格"的闸门，等于没有这把尺子。
  local asn win
  asn=$(lsappinfo front 2>/dev/null || true)
  front=""
  [ -n "$asn" ] && front=$(lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/^"LSDisplayName"="\(.*\)"$/\1/p')
  [ -n "$front" ] || front=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null | tr -d '\n')
  [ -n "$front" ] || front="未知"
  printf '%s\n' "$front"
}

preflight_window_state() {  # preflight_window_state <pid> → 那句 visible 描述
  local win
  # 窗口在不在屏：走 `winlist.swift`（CGWindowList，**零权限**），与其它三个取证脚本同一把尺子。
  win=$(winlist_probe "$1")
  if [ -n "$win" ]; then
    echo "有在屏窗口（$(printf '%s' "$win" | cut -d'|' -f2)）"
  else
    echo "无在屏窗口（隐藏/最小化/不在屏）"
  fi
}

preflight_write_context() {  # preflight_write_context <outdir> <context 文件路径>
  # 这一份上下文是"读数可互比"的凭据：谁后面拿这批数做对比，都得先看见同一组条件。
  local f="$2"
  { echo "# 测量上下文（读数只有在这一组条件下才可互比）"
    echo "时间=$(date '+%F %T')  HEAD=$(git rev-parse --short HEAD 2>/dev/null)  工作树改动数=$DIRTY"
    echo "被采pid=$pid  二进制=$TARGET_BINARY  口径=$TARGET_FLAVOR"
    echo "实例数=${COEXIST:-1}  前台App=$front  被测进程visible=$visible"
    echo "load1=$load1  核数=$cores  并发swiftc=${others:-无}"
    echo "人输入静默=${quiet:-取不到}s  明细=${qline:-（探针没跑起来）}"
    echo "hitches_seconds=$SECONDS_HITCHES  tp_seconds=$SECONDS_TP"
  } > "$f" 2>/dev/null || die "写不出 $f"
  echo "    上下文：前台=$front  visible=$visible  load1=$load1/$cores  并发swiftc=${others:-无}  静默=${quiet:-取不到}s"
}

preflight_gates() {  # 不合格就置 `hard=1`（调用方按 IGNORE_CONTEXT_GATE 决定炸还是通报）
  if [ -n "$others" ]; then
    echo "!! 有 swiftc 在跑（$others）——它会抢满全部核，app-update 相位会被显著抬高。等它跑完再来。" >&2
    hard=1
  fi
  # 负载阈值：默认 1 分钟 load 不超过核数的 1.5 倍（LOAD_MAX=<数> 可覆盖，但覆盖了就要在报告里写）
  if awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l > c*1.5)}'; then
    echo "!! load1=$load1 已是核数($cores)的 1.5 倍以上：整机排队，任何帧节拍读数都不作数。" >&2
    echo "   等负载降下来，或显式 LOAD_MAX=<阈值> 重跑（那必须在报告里注明是降级条件）。" >&2
    hard=1
  fi
  if [ "$front" != "TcoderMonitor" ] && [ "${ALLOW_UNFRONTMOST:-0}" != "1" ]; then
    echo "!! 被测窗口不在前台（前台是「$front」）。macOS 会节流不在前的窗口绘制，" >&2
    echo "   app-update 会**假性地好看**（实测：同二进制前台 10.8~24.8ms、后台 1.9~3.0ms）。" >&2
    echo "   请把 Tcoder 窗口点到最前面并保持不动，再跑一次；" >&2
    echo "   确实要量后台态就 ALLOW_UNFRONTMOST=1（那批只能标成『后台态』，不得当交互基线）。" >&2
    hard=1
  fi
  case "$visible" in
    无在屏窗口*)
      echo "!! 被测进程没有在屏窗口（$visible）——窗口根本没在画，量不到有意义的心跳期帧。" >&2
      echo "   把窗口恢复出来（取消最小化 / 切到该 Space）再测。" >&2
      hard=1 ;;
  esac
  # 人手静默闸：§1.3 作废的那两批基线，坏因都是"测量期间有人在动"，
  # 而 load / 并发编译 / 前台这三条整机闸**看不见手**。取不到数只通报、不判败
  # （一条因为拿不到数据就永远说不合格的闸，等于没有这把尺子——前台那条就栽过这个跟头）。
  if [ -n "$quiet" ] && [ "$quiet" != "-1.00" ] \
     && awk -v q="$quiet" -v m="$QUIESCE_MIN" 'BEGIN{exit !(q < m)}' \
     && [ "${PERIOD:-idle}" != "interaction" ] \
     && [ "${ALLOW_UNQUIESCENT:-0}" != "1" ]; then
    echo "!! 人手 ${quiet} 秒前还在动（要求静默 ≥${QUIESCE_MIN}s）。这 20 秒里只要有人点一下、" >&2
    echo "   滚一下，读数量的就是『那 20 秒里谁干了什么』，不是『这套代码卡不卡』。" >&2
    echo "   请等人手停下再来；确实要连人一起量（例如就要量交互期）就 $0 interact 那一档。" >&2
    hard=1
  fi
}

human_input_in_window() {  # human_input_in_window <静默秒> <窗口秒> → 分类，便于拿合成数字验判定
  awk -v q="$1" -v w="$2" 'BEGIN{ if (q >= w) print "窗口内没人"; else print "窗口内有人" }'
}

post_window_quiescence() {  # post_window_quiescence <outdir> <窗口秒数>；按 PERIOD 决定"什么样的收尾算合格"
  # 收尾**再问一次**探针：若"距离上次人手事件"仍短于刚录的窗口，说明窗口里有人动过手。
  # idle 档要的是"整窗没人动"；interact 档要的正好相反——没人动那批只能退回当 idle 数。
  local out="$1" window="$2" quiet period="${PERIOD:-idle}" verdict
  quiet=$(quietest_seconds "$(quiescence_probe)")
  [ -n "$quiet" ] && [ "$quiet" != "-1.00" ] || { echo "    （收尾静默探针取不到，污染判定不做）"; return 0; }
  verdict=$(human_input_in_window "$quiet" "$window")
  meta_write "$out" "quiescence_after_seconds=$quiet" "period=$period" "window_verdict=$verdict"
  if [ "$period" = "interaction" ]; then
    if [ "$verdict" = "窗口内没人" ]; then
      meta_write "$out" "no_human_input_during_window=1"
      echo "    ⚠ 整个 ${window}s 窗口里**没有一次人手事件**（距上次 ${quiet}s）——" >&2
      echo "      这批量的是心跳期，不是交互期。要判 T1 必须重跑并真的持续滚动。" >&2
    else
      echo "    复核通过：窗口内确有真人输入（距上次 ${quiet}s < ${window}s），可当交互期样本"
    fi
  elif [ "$verdict" = "窗口内有人" ]; then
    meta_write "$out" "contaminated_by_human_input=1"
    echo "    ⚠ **这批样本被污染**：录制窗口 ${window}s 内人手在 ${quiet} 秒前还在动。" >&2
    echo "      已写进 meta（contaminated_by_human_input=1），不得进前后对比表。" >&2
  else
    echo "    收尾复核：整窗口无人手输入（距上次事件 ${quiet}s ≥ ${window}s）"
  fi
}

require_idle_target() {  # 返回全局 PID；!= 1 个实例即拒跑（除非显式 ATTACH_PID=<pid>）
  local pids n
  pids=$(instance_pids)
  if [ -n "${ATTACH_PID:-}" ]; then
    # 显式指定被采 pid 时不再拦：多实例的读数**只在标注了共存事实之后**才可比较。
    # 这条口子是给人用的，不是给默认路径用的——默认仍然要求独占。
    case "$ATTACH_PID" in
      ''|*[!0-9]*) die "ATTACH_PID 必须是数字 pid，收到：$ATTACH_PID" ;;
    esac
    printf '%s\n' "$pids" | grep -qx "$ATTACH_PID" || die "ATTACH_PID=$ATTACH_PID 不在跑着的实例里（$(printf '%s' "$pids" | tr '\n' ' ')）"
    n=$(printf '%s' "$pids" | grep -c . || true)
    PID="$ATTACH_PID"
    echo "    ⚠ 显式 ATTACH_PID=$PID：本机同时有 $n 个实例（$(printf '%s' "$pids" | tr '\n' ' ')）。"
    echo "      spec §7.5 的「采样期间独占实例」前提**不成立**，这批读数的绝对值只能与同样"
    echo "      多实例条件下取的另一批比，不能直接和 §1 的独占基线比。meta.json 里已记 coexist=$n。"
    COEXIST="$n"
    echo "    目标实例 pid=$PID，来源：$(pid_binary "$PID" | cut -c1-100)"
    note_target_flavor "$PID"
    return 0
  fi
  n=$(printf '%s' "$pids" | grep -c . || true)
  if [ "$n" = "0" ]; then
    die "没有正在运行的 TcoderMonitor 实例，idle 档无法 attach。
   idle 的设计就是**不启动 App**（同一时刻只允许一个人启动 App，且 xctrace 要独占实例），
   请你先手动打开要量的那个产物，或者改用 switch 档（它自己 --launch 且走独立沙箱）。"
  fi
  if [ "$n" -gt 1 ]; then
    die "检测到 $n 个 TcoderMonitor 实例（pid $(printf '%s' "$pids" | tr '\n' ' ')），拒跑。
   原因：spec §7.5 要求采样期间只有被采的那一个实例——多个实例共用
   ~/Library/Application Support/TcoderMonitor 与 defaults 域 $DOMAIN，
   谁后回写谁污染，读数的归属就不成立了。
   本脚本按 AGENTS.md -1.3 不会 kill 任何进程，请人工只留一个（Cmd+Q 掉多余的）。
   确实要在多实例下量某一个 pid：ATTACH_PID=<pid> scripts/perf_harness.sh idle
   （那样取到的数必须标注共存事实，见上面 ATTACH_PID 的警告）。"
  fi
  PID="$pids"
  COEXIST=1
  local exe
  exe=$(basename "$(pid_binary "$PID")")
  echo "    目标实例 pid=$PID（${exe:-未知}），来源：$(pid_binary "$PID" | cut -c1-100)"
  note_target_flavor "$PID"
}

export_table() {  # export_table <trace> <schema> <outdir>
  local trace="$1" schema="$2" out="$3"
  [ "$DRY_RUN" = "1" ] && { echo "    \$ xctrace export --input $(basename "$trace") --xpath '…@schema=\"$schema\"' --output $out/$schema.xml"; return 0; }
  xcrun xctrace export --input "$trace" \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
    --output "$out/$schema.xml" >/dev/null 2>&1
  if [ -s "$out/$schema.xml" ]; then
    echo "    导出 $schema.xml（$(wc -c < "$out/$schema.xml" | tr -d ' ') 字节）"
  else
    rm -f "$out/$schema.xml"
    echo "    ⚠ 表 $schema 在该 trace 里不存在或为空 —— 汇总表会写「未覆盖」，不会编数"
  fi
}

meta_write() {  # meta_write <outdir> <键=值...>
  local out="$1"; shift
  # 目录由本函数自己保证存在：cmd_switch 的 mkdir 在 per-page 循环里，
  # DRY_RUN 下整段被跳过，于是第一次 meta_write 会写进不存在的目录（实测 traceback）。
  mkdir -p "$out" 2>/dev/null || { echo "    ⚠ meta_write 建不了 $out，本条 meta 丢失" >&2; return 0; }
  python3 - "$out/meta.json" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REV" "$DIRTY" "$@" <<'PY'
import json, os, sys
path, ts, rev, dirty = sys.argv[1:5]
data = {"captured_at_utc": ts, "rev": rev, "git_dirty_lines": int(dirty)}
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    data[k] = v
if os.path.isfile(path):
    try:
        data = {**json.load(open(path, encoding="utf-8")), **data}
    except ValueError:
        pass
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

prepare_sandbox() {  # prepare_sandbox <dir> <扫描目标>：与 capture_pages_isolated.sh 同一做法
  local sandbox="$1" target="$2"
  mkdir -p "$sandbox/reports" || die "建不了沙箱 $sandbox"
  python3 - "$sandbox" "$UUID" "$target" <<'PY' || die "写 projects.json 失败"
import json, sys, datetime
support, uuid, path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": "Tcoder（性能沙箱）", "path": path,
                         "addedAt": now, "isDemo": False}],
           "selectedProjectID": uuid},
          open("%s/projects.json" % support, "w"), indent=2)
PY
}

# =============================================================================
# idle —— 不碰它，量心跳（spec §1 / §3 T2 的那一档）
# =============================================================================
cmd_idle() {
  local out="${1:-/tmp/tcoder-perf-$REV}"
  # period 决定这一批读数**有资格回答哪个问题**：idle 只能答"心跳期"，T1（交互期 hitch=0）
  # 只认 period=interaction 的样本。写进 meta 是为了让 report 阶段还能看见它——
  # 否则过两天没人记得当时到底碰没碰鼠标，就会拿心跳期的数去交交互期的结论。
  local period="${PERIOD:-idle}"
  PERIOD="$period"   # 让 preflight / 收尾复核这些被调函数看得见同一档，不靠调用点的隐式作用域
  [ "$period" = "interaction" ] \
    && echo "==> interact 档：**录制期间请持续滚动/拖窗**，停下就不算交互期" \
    || echo "==> idle 档：attach 现有实例录心跳（release 口径；rev=$REV dirty=$DIRTY）"
  [ -x "$TRACE_REPORT" ] || die "缺 scripts/trace_report.py"
  require_idle_target
  mkdir -p "$out" || die "建不了 $out"
  meta_write "$out" "mode=idle" "period=$period" "pid=$PID" "binary=$TARGET_BINARY" \
    "hitches_seconds=$SECONDS_HITCHES" "tp_seconds=$SECONDS_TP" "coexisting_instances=${COEXIST:-1}" \
    "templates=$TEMPLATE_HITCH + $TEMPLATE_TP" "build_flavor=$TARGET_FLAVOR"
  preflight_context "$out" "$PID"
  # 四个步骤各自成函数：录哪张表、导哪张表、什么时候问人手探针，顺序就是口径，
  # 拆完仍是 1/4 → 2/4 → 3/4 → 4/4 这一条直线，一步没重排。
  idle_record_hitches "$out" "$period"
  idle_record_time_profiler "$out"
  idle_parse_tables "$out"
  idle_write_summary "$out"
}

idle_record_hitches() {  # idle_record_hitches <outdir> <period>
  local out="$1" period="$2"
  if [ "$period" = "interaction" ]; then
    echo "==> 1/4 录 Animation Hitches ${SECONDS_HITCHES}s（**这 ${SECONDS_HITCHES}s 请持续滚动被测窗口**）"
  else
    echo "==> 1/4 录 Animation Hitches ${SECONDS_HITCHES}s（这期间不去碰鼠标键盘，否则量的就不是心跳）"
  fi
  run rm -rf "$out/hitches.trace"
  run xcrun xctrace record --template "$TEMPLATE_HITCH" --attach "$PID" \
    --time-limit "${SECONDS_HITCHES}s" --output "$out/hitches.trace" --no-prompt --quiet
  for t in "${HITCH_TABLES[@]}"; do
    [ "$DRY_RUN" = "1" ] || export_table "$out/hitches.trace" "$t" "$out"
  done
  # 录制窗口一结束就问一次人手探针：这是"这批能不能进对比表"的判据，必须在导表之后、
  # 在下一个窗口（Time Profiler）开始之前问，否则两个窗口的静默读数会互相顶包。
  [ "$DRY_RUN" = "1" ] || post_window_quiescence "$out" "$SECONDS_HITCHES"
}

idle_record_time_profiler() {  # idle_record_time_profiler <outdir>
  local out="$1"
  echo "==> 2/4 录 Time Profiler ${SECONDS_TP}s"
  run rm -rf "$out/time.trace"
  run xcrun xctrace record --template "$TEMPLATE_TP" --attach "$PID" \
    --time-limit "${SECONDS_TP}s" --output "$out/time.trace" --no-prompt --quiet
  [ "$DRY_RUN" = "1" ] || export_table "$out/time.trace" "time-profile" "$out"
}

idle_parse_tables() {  # idle_parse_tables <outdir>：3/4 那一节，按表名派发到对应子命令
  local out="$1"
  echo "==> 3/4 解析（id/ref 解引用在 trace_report.py 里，这里不重复实现）"
  if [ "$DRY_RUN" != "1" ]; then
    [ -s "$out/time-profile.xml" ] && python3 "$TRACE_REPORT" threads "$out/time-profile.xml" \
      --thread "Main Thread" --json "$out/time-profile.json" | tee "$out/threads.txt"
    for t in "${HITCH_TABLES[@]}"; do
      case "$t" in
        hitches|hitches-updates|hitches-renders|potential-hangs)
          [ -s "$out/$t.xml" ] && python3 "$TRACE_REPORT" durations "$out/$t.xml" \
            --label "$t" --with-phases --json "$out/$t.json" | sed 's/^/    /' ;;
        device-display-info)
          [ -s "$out/$t.xml" ] && python3 "$TRACE_REPORT" displays "$out/$t.xml" \
            --json "$out/$t.json" | sed 's/^/    /' ;;
        displayed-surfaces-per-second)
          [ -s "$out/$t.xml" ] && python3 "$TRACE_REPORT" fps "$out/$t.xml" \
            --json "$out/$t.json" | sed 's/^/    /' ;;
      esac
    done
    [ -f "$out/hitches.trace/corespace" ] || echo "    （trace 已留在 $out，需要复看用 Instruments 打开）"
  fi
}

idle_write_summary() {  # idle_write_summary <outdir>：4/4 汇总表（与 spec §1 逐列同形状）
  local out="$1"
  echo "==> 4/4 汇总表（与 spec §1 逐列同形状）"
  run python3 "$TRACE_REPORT" summary "$out" --seconds "${SECONDS_HITCHES:-20}"
  [ "$DRY_RUN" = "1" ] || python3 "$TRACE_REPORT" summary "$out" --seconds "$SECONDS_HITCHES" \
    > "$out/summary.txt" 2>&1
  echo "输出目录: $out"
}

# =============================================================================
# switch —— 逐页冷启动（spec §3 T4：到可交互 ≤1.0 s、首帧 ≤3 个显示节拍）
# =============================================================================
switch_page_list() {  # → 页名串：PAGES 优先，否则取 capture_pages_isolated.sh 的 SECTIONS
  if [ -n "${PAGES:-}" ]; then
    printf '%s\n' "$PAGES"
  else
    sections | tr '\n' ' '
  fi
}

switch_refuse_coexist() {  # 冷启动最容易被"别人的心跳"污染：默认要求机器上一个实例都没有
  local pre; pre=$(instance_pids)
  if [ -n "$pre" ] && [ "${SWITCH_ALLOW_COEXIST:-0}" != "1" ]; then
    echo "!! 机器上已有 Tcoder 实例在跑（$(printf '%s' "$pre" | tr '\n' ' ')），逐页冷启动会被它们的心跳污染。" >&2
    echo "   请把它们全部 Cmd+Q 后重跑；确实要共存就 SWITCH_ALLOW_COEXIST=1（那批只能标成『共存态』）。" >&2
    die "switch 档拒绝在多实例条件下运行"
  fi
  [ -n "$pre" ] && echo "    ⚠ SWITCH_ALLOW_COEXIST=1：共存态读数不得用于与独占基线对比。" >&2
}

switch_finish_page() {  # switch_finish_page <dir> <pid>：收尾，默认只报告该退哪个 pid
  local dir="$1" pid="$2"
  # 收尾：绝不用 `tell application id "<bundle id>" to quit` —— 它按 bundle id **全机生效**，
  # 会把用户自己开着的实例一起退掉（实测踩过：留下 7 个残留，且随时可能误伤）。
  # 默认只报告该退哪个 pid，由人 Cmd+Q；确实要自动收，必须显式授权 SWITCH_TERM=1，
  # 且只对本脚本自己起的那个 pid 发 SIGTERM —— 这是对 AGENTS.md -1.3「不发信号」的**有意偏离**，
  # 授权与后果都要写进 meta，不留成"看起来是脚本自己会清理"的假象。
  if [ "${SWITCH_TERM:-0}" = "1" ]; then
    kill -TERM "$pid" 2>/dev/null \
      && echo "    已按授权 SIGTERM 自己起的实例 pid=$pid" \
      || echo "    ⚠ SIGTERM 失败：pid=$pid 需人工 Cmd+Q"
    meta_write "$dir" "cleanup=SIGTERM(授权 SWITCH_TERM=1)"
  else
    echo "    提示：采完请人工 Cmd+Q 这个实例 pid=$pid（脚本按 bundle id 退出会误伤其它实例，故不自作主张）"
    meta_write "$dir" "cleanup=人工(脚本未退出实例)"
  fi
}

switch_record_page() {  # switch_record_page <page> <dir> <sandbox>：一页的全流程（录制 + 导表 + 落 meta）
  local page="$1" dir="$2" sandbox="$3"
  # 正确做法照抄 capture_pages_isolated.sh：TCODER_SUPPORT_DIR 指到自己的沙箱，
  # -ApplePersistenceIgnoreState YES 禁掉窗口恢复，否则第二页起拍到的是第一页的窗口状态。
  prepare_sandbox "$sandbox" "$PWD"
  run rm -rf "$dir/launch.trace"
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  xcrun xctrace record --template "$TEMPLATE_LAUNCH" \
    --env "TCODER_SUPPORT_DIR=$sandbox" \
    --launch -- "$PERF_BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$page" \
    --time-limit "${SECONDS_LAUNCH}s" --output "$dir/launch.trace" --no-prompt --quiet
  t1=$(python3 -c 'import time;print(time.time())')
  # 首帧**不能**用墙钟轮询量。原实现的顺序是：t0 → `xctrace record --launch
  # --time-limit 10s`（阻塞满 10 s）→ 才去轮询窗口出现 → `first = now - t0`，
  # 于是 `first_frame_ms` 恒 ≥ 录制时长，量到的是"录制跑了多久"，不是首帧。
  # 时长一律从 trace 的 life-cycle-period 派生；探测只回答"窗口到底出现过没有"。
  local pid window_seen="未探测到实例"
  pid=$(pgrep -n -x TcoderMonitor 2>/dev/null || true)
  [ -n "$pid" ] && { [ -n "$(winlist_probe "$pid")" ] && window_seen="有在屏窗口" || window_seen="无在屏窗口"; }
  export_table "$dir/launch.trace" "life-cycle-period" "$dir"
  export_table "$dir/launch.trace" "hitches" "$dir"
  xcrun xctrace export --input "$dir/launch.trace" --toc --output "$dir/toc.xml" >/dev/null 2>&1
  python3 "$TRACE_REPORT" lifecycle "$dir/life-cycle-period.xml" \
    --json "$dir/life-cycle-period.json" 2>/dev/null | sed 's/^/    /'
  local launch_total="未观测到"
  if [ -s "$dir/life-cycle-period.json" ]; then
    launch_total=$(python3 -c "import json;print(json.load(open('$dir/life-cycle-period.json')).get('total_ms','未观测到'))" 2>/dev/null \
                   || echo "未观测到")
  fi
  meta_write "$dir" "page=$page" "pid=$pid" \
    "first_frame_ms=${launch_total}" "first_frame_source=life-cycle-period(trace 派生，非墙钟)" \
    "window_seen=$window_seen" \
    "record_wall_s=$(python3 -c "print('%.1f' % ($t1-$t0))")"
  echo "    启动到就绪(trace)=${launch_total} ms；$window_seen；细表见 $dir/life-cycle-period.xml"
  switch_finish_page "$dir" "$pid"
}

cmd_switch() {
  local out="${1:-/tmp/tcoder-perf-$REV}"
  echo "==> switch 档：逐页冷启动（自带沙箱，不写用户的 defaults）"
  [ -x "$PERF_BIN" ] || die "找不到被采二进制 $PERF_BIN（先跑 ./scripts/build_app.sh release，或传 PERF_BIN=）"
  local pages
  pages=$(switch_page_list) || die "取不到 SECTIONS：scripts/capture_pages_isolated.sh 不在了？"
  meta_write "$out" "mode=switch" "binary=$PERF_BIN" "launch_seconds=$SECONDS_LAUNCH" "pages=$pages"

  # 冷启动首帧最容易被"别人的心跳"污染：另一个实例每 1.5s 也在打主线程，
  # 首帧时间会莫名变长。所以默认要求机器上**一个实例都没有**。
  switch_refuse_coexist

  local n=0
  for page in $pages; do
    n=$((n + 1))
    local sandbox="$out/sandbox/$(printf '%02d' "$n")-$page" dir="$out/pages/$(printf '%02d' "$n")-$page"
    mkdir -p "$dir"
    echo "--> $n) $page"
    if [ "$DRY_RUN" = "1" ]; then
      echo "    \$ TCODER_SUPPORT_DIR=$sandbox $PERF_BIN -ApplePersistenceIgnoreState YES -selectedDetailSection $page"
      echo "    \$ xctrace record --template \"$TEMPLATE_LAUNCH\" --launch -- … --time-limit ${SECONDS_LAUNCH}s"
      continue
    fi
    switch_record_page "$page" "$dir" "$sandbox"
    sleep 2
  done
  [ "$DRY_RUN" = "1" ] && { echo "（DRY_RUN=1：一条命令都没执行）"; return 0; }
  echo "==> 逐页汇总"
  python3 "$TRACE_REPORT" switches "$out/pages" | tee "$out/switch-summary.txt"
  echo "输出目录: $out"
}

cmd_report() {
  local out="${1:-/tmp/tcoder-perf-$REV}"
  [ -d "$out" ] || die "没有这个输出目录：$out"
  echo "==> report 档：重打 $out 的汇总表（不重录）"
  local secs
  secs=$(python3 - "$out/meta.json" <<'PY' 2>/dev/null || echo 20
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("hitches_seconds", 20))
except Exception:
    print(20)
PY
)
  python3 "$TRACE_REPORT" summary "$out" --seconds "$secs"
  [ -s "$out/time-profile.xml" ] && python3 "$TRACE_REPORT" threads "$out/time-profile.xml" --thread "Main Thread"
  [ -d "$out/pages" ] && python3 "$TRACE_REPORT" switches "$out/pages"
}

# =============================================================================
# probe —— 读 FramePulse 的落盘脉冲（交互期 hitch 的唯一入口，零采样）
# =============================================================================
cmd_probe() {
  local file="${1:-}"
  [ -n "$file" ] || file=$(ls -t /tmp/tcoder-framepulse-*.txt 2>/dev/null | head -1)
  [ -n "$file" ] || die "找不到 /tmp/tcoder-framepulse-*.txt：探针没开。开法是 TCODER_PERF_PROBE=1 起 App"
  echo "==> probe 档：读 $file"
  echo "    交互期结论只有在测量窗口内**真的有人在滚动/拖窗**时才成立，"
  echo "    所以判 T1 要自己带 --interaction 声明；不带就只会得到 idle 读数（退出码 2，不是达标）。"
  python3 "$PULSE_REPORT" "$file" "${@:2}"
}

# =============================================================================
# interact —— 交互期那一档（T1 唯一有资格的样本）：录法同 idle，区别只在"人在滚"
# =============================================================================
cmd_interact() {
  # 不复制一份录制逻辑，只换 period 与提示语——两档共享同一实现，
  # 才不会哪天只修了 idle 那一半、两档的口径悄悄分叉。
  PERIOD=interaction cmd_idle "${1:-/tmp/tcoder-perf-interact-$REV}"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    idle) cmd_idle "$@" ;;
    interact) cmd_interact "$@" ;;
    switch) cmd_switch "$@" ;;
    report) cmd_report "$@" ;;
    probe) cmd_probe "$@" ;;
    selfcheck)
      # 只在真跑 selfcheck 时才 source：其余四档不读这个文件，也就不会被它拖住。
      [ -f "$SELF_CHECK_SRC" ] || die "缺 $SELF_CHECK_SRC（selfcheck 档被拆走了——它不归本文件管，见 97 号笔记）"
      # shellcheck source=/dev/null  # 依赖本文件的 $REV / $TRACE_REPORT / $die 等同进程量
      source "$SELF_CHECK_SRC"
      cmd_selfcheck "$@" ;;
    *) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
}
main "$@"
