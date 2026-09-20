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
TRACE_REPORT="$PWD/scripts/trace_report.py"
PULSE_REPORT="$PWD/scripts/perf_framepulse.py"
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

preflight_context() {  # preflight_context <outdir> <pid>
  local out="$1" pid="$2" f="" cores load1 front visible others hard=0
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  [ -n "$load1" ] || load1=0
  f="$out/measurement-context.txt"

  # 前台 App：**先走 `lsappinfo`（零权限）**。原来只用 `osascript` + System Events，
  # 而本机那条路被权限拒（实测 `-10004 发生权限违例`），于是永远得到「未知」、
  # 闸门永远拒跑——一条因为取不到数就永远说"不合格"的闸门，等于没有这把尺子。
  local asn win
  asn=$(lsappinfo front 2>/dev/null || true)
  front=""
  [ -n "$asn" ] && front=$(lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/^"LSDisplayName"="\(.*\)"$/\1/p')
  [ -n "$front" ] || front=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null | tr -d '\n')
  [ -n "$front" ] || front="未知"
  # 窗口在不在屏：走 `winlist.swift`（CGWindowList，**零权限**），与其它三个取证脚本同一把尺子。
  win=$(winlist_probe "$pid")
  if [ -n "$win" ]; then
    visible="有在屏窗口（$(printf '%s' "$win" | cut -d'|' -f2)）"
  else
    visible="无在屏窗口（隐藏/最小化/不在屏）"
  fi
  others=$(pgrep -x swiftc 2>/dev/null | tr '\n' ' ')

  { echo "# 测量上下文（读数只有在这一组条件下才可互比）"
    echo "时间=$(date '+%F %T')  HEAD=$(git rev-parse --short HEAD 2>/dev/null)  工作树改动数=$DIRTY"
    echo "被采pid=$pid  二进制=$TARGET_BINARY  口径=$TARGET_FLAVOR"
    echo "实例数=${COEXIST:-1}  前台App=$front  被测进程visible=$visible"
    echo "load1=$load1  核数=$cores  并发swiftc=${others:-无}"
    echo "hitches_seconds=$SECONDS_HITCHES  tp_seconds=$SECONDS_TP"
  } > "$f" 2>/dev/null || die "写不出 $f"

  echo "    上下文：前台=$front  visible=$visible  load1=$load1/$cores  并发swiftc=${others:-无}"

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
  [ "$hard" = "1" ] && [ "${IGNORE_CONTEXT_GATE:-0}" != "1" ] && die "测量上下文不达标（详见 $f）。IGNORE_CONTEXT_GATE=1 可强行跳过，但那批读数必须标注为『条件不合格』。"
  [ "$hard" = "1" ] && echo "    ⚠ IGNORE_CONTEXT_GATE=1：条件不合格，这批读数不得进任何对比表。" >&2
  echo "    上下文已落 $f"
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

  echo "==> 2/4 录 Time Profiler ${SECONDS_TP}s"
  run rm -rf "$out/time.trace"
  run xcrun xctrace record --template "$TEMPLATE_TP" --attach "$PID" \
    --time-limit "${SECONDS_TP}s" --output "$out/time.trace" --no-prompt --quiet
  [ "$DRY_RUN" = "1" ] || export_table "$out/time.trace" "time-profile" "$out"

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

  echo "==> 4/4 汇总表（与 spec §1 逐列同形状）"
  run python3 "$TRACE_REPORT" summary "$out" --seconds "${SECONDS_HITCHES:-20}"
  [ "$DRY_RUN" = "1" ] || python3 "$TRACE_REPORT" summary "$out" --seconds "$SECONDS_HITCHES" \
    > "$out/summary.txt" 2>&1
  echo "输出目录: $out"
}

# =============================================================================
# switch —— 逐页冷启动（spec §3 T4：到可交互 ≤1.0 s、首帧 ≤3 个显示节拍）
# =============================================================================
cmd_switch() {
  local out="${1:-/tmp/tcoder-perf-$REV}"
  echo "==> switch 档：逐页冷启动（自带沙箱，不写用户的 defaults）"
  [ -x "$PERF_BIN" ] || die "找不到被采二进制 $PERF_BIN（先跑 ./scripts/build_app.sh release，或传 PERF_BIN=）"
  local pages
  if [ -n "${PAGES:-}" ]; then
    pages="$PAGES"
  else
    pages=$(sections | tr '\n' ' ') || die "取不到 SECTIONS：scripts/capture_pages_isolated.sh 不在了？"
  fi
  meta_write "$out" "mode=switch" "binary=$PERF_BIN" "launch_seconds=$SECONDS_LAUNCH" "pages=$pages"

  # 冷启动首帧最容易被"别人的心跳"污染：另一个实例每 1.5s 也在打主线程，
  # 首帧时间会莫名变长。所以默认要求机器上**一个实例都没有**。
  local pre; pre=$(instance_pids)
  if [ -n "$pre" ] && [ "${SWITCH_ALLOW_COEXIST:-0}" != "1" ]; then
    echo "!! 机器上已有 Tcoder 实例在跑（$(printf '%s' "$pre" | tr '\n' ' ')），逐页冷启动会被它们的心跳污染。" >&2
    echo "   请把它们全部 Cmd+Q 后重跑；确实要共存就 SWITCH_ALLOW_COEXIST=1（那批只能标成『共存态』）。" >&2
    die "switch 档拒绝在多实例条件下运行"
  fi
  [ -n "$pre" ] && echo "    ⚠ SWITCH_ALLOW_COEXIST=1：共存态读数不得用于与独占基线对比。" >&2

  local n=0
  for page in $pages; do
    n=$((n + 1))
    local sandbox="$out/sandbox/$(printf '%02d' "$n")-$page" dir="$out/pages/$(printf '%02d' "$n")-$page"
    mkdir -p "$dir"
    echo "--> $n) $page"
    # 正确做法照抄 capture_pages_isolated.sh：TCODER_SUPPORT_DIR 指到自己的沙箱，
    # -ApplePersistenceIgnoreState YES 禁掉窗口恢复，否则第二页起拍到的是第一页的窗口状态。
    if [ "$DRY_RUN" = "1" ]; then
      echo "    \$ TCODER_SUPPORT_DIR=$sandbox $PERF_BIN -ApplePersistenceIgnoreState YES -selectedDetailSection $page"
      echo "    \$ xctrace record --template \"$TEMPLATE_LAUNCH\" --launch -- … --time-limit ${SECONDS_LAUNCH}s"
      continue
    fi
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
# selfcheck —— 不起 App、不碰 xctrace，拿合成夹具验这把尺子自己还活着
# =============================================================================
cmd_selfcheck() {
  local out="${1:-/tmp/tcoder-perf-selfcheck-$REV}"
  echo "==> selfcheck 档：验尺子（合成夹具，零采样，秒级）"
  rm -rf "$out"; mkdir -p "$out"
  local fails=0
  local checked=0
  fail() { echo "  ✗ $1"; fails=$((fails+1)); }
  ok()   { echo "  ✓ $1"; checked=$((checked+1)); }

  # 1) 三层文件都要在、都要编译得过、且没有一个撞本仓 ≤800 行棘轮
  #    （`SelfScanDogfoodTests` 的分母含 .py，ceiling=0：2026-09-20 就是 trace_report.py
  #     长到 819 行把 main 判红的，那次没人提前发现，因为没人跑过它。）
  local f lines pylog="$out/py_compile.log"
  : > "$pylog"
  for f in trace_report.py perf_trace_xml.py perf_trace_metrics.py perf_framepulse.py; do
    [ -f "scripts/$f" ] || { fail "缺 scripts/$f（尺子被拆走了一层）"; continue; }
    lines=$(wc -l < "scripts/$f" | tr -d ' ')
    [ "$lines" -le 800 ] || fail "scripts/$f 已 $lines 行，撞 ≤800 行棘轮——拆开它，别拧阈值"
    python3 -m py_compile "scripts/$f" >> "$pylog" 2>&1 || fail "scripts/$f 编译不过，见 $pylog"
  done
  ( cd scripts && python3 -c 'import perf_trace_metrics, perf_trace_xml' ) 2>> "$pylog" \
    || fail "两个子模块 import 不上（入口靠 sys.path 找同目录模块，改名/挪目录会静默断在这里）"
  rm -rf scripts/__pycache__
  [ "$fails" -eq 0 ] && ok "四把尺子文件齐全，都编译得过，都没超 800 行"

  # 2) switch 档的逐页表：有数据的那页必须真出数，缺项的必须显式写缺
  #    （钉的是 2026-09-20 实修的那个缺陷：cmd_switches 里 `cur` 未定义，
  #     **只有存在逐页子目录时才炸**，夹具为空时它"通过"，于是坏了很久没人知道。）
  local fx="$out/switch-fixture"
  mkdir -p "$fx/01-总览" "$fx/02-性能"
  printf '{"page":"总览","first_frame_ms":412}' > "$fx/01-总览/meta.json"
  printf '{"total_ms":1234.5,"max_period_ms":600.1,"max_period":"Process Launch"}' > "$fx/01-总览/life-cycle-period.json"
  printf '{"page":"性能"}' > "$fx/02-性能/meta.json"
  local rows
  if python3 "$TRACE_REPORT" switches "$fx" > "$out/switch.txt" 2> "$out/switch.err"; then
    rows=$(grep -c '^| ' "$out/switch.txt" || true)
    [ "$rows" -eq 3 ] || fail "switches 只打出 $rows 行表格（应为表头 + 2 页）：$(cat "$out/switch.txt")"
    grep -q '412 ms' "$out/switch.txt" || fail "first_frame_ms 没进表——switch 档唯一要报的就是它"
    grep -q '未观测到' "$out/switch.txt" || fail "缺 meta 的页必须显式写「未观测到」，留空会被读成 0"
    grep -q '未覆盖' "$out/switch.txt" || fail "缺 life-cycle 的页必须显式写「未覆盖」，不能用 0.0 冒充"
    [ "$rows" -eq 3 ] && ok "switches：两页合成夹具，读数与两种缺项三态都对"
  else
    fail "switches 崩了（尺子坏了，读数一律不可信）：$(tail -3 "$out/switch.err" | tr '\n' ' ')"
  fi

  # 3) 空表要报"未采到"，而不是报"n=0 达标"
  printf '<table><schema name="hitches"/><row/></table>\n' > "$out/empty.xml"
  if python3 "$TRACE_REPORT" durations "$out/empty.xml" > "$out/durations.txt" 2>&1 \
     && grep -q 'n=0（未采到）' "$out/durations.txt"; then
    ok "durations：空表如实写「未采到」，没有把 0 帧当成达标"
  else
    fail "durations 对空表的读数不对（要看 $out/durations.txt）"
  fi

  # 4) 垃圾输入必须非零退出：否则"读不到文件"和"真的 0 hitch"在退出码上无法区分
  if python3 "$TRACE_REPORT" durations "$out/根本没有这个文件.xml" > /dev/null 2>&1; then
    fail "拿不存在的 XML 还退 0 —— 那任何一次测量失败都会伪装成「0 次 hitch，完美」"
  else
    ok "缺文件非零退出（测量失败与达标是两种可区分的结果）"
  fi

  # 5) 反向元测试：`cross_check_durations` 这把复核尺必须真的抓得住不一致
  #    （它只在两把解析不一致时才拒绝出数；如果它对什么都不一致，等于永真绿）
  cat > "$out/xcheck.xml" <<'XML'
<table><schema name="hitches-renders"/>
<row><duration id="1" fmt="10.00 ms">10000000</duration></row>
<row><duration ref="1"/></row>
<row><duration id="2" fmt="99.00 ms">99000000</duration></row>
</table>
XML
  local xmsg
  xmsg=$( cd scripts && python3 - "$out/xcheck.xml" <<'PY' 2>&1
import sys
from perf_trace_xml import cross_check_durations
agree, why = cross_check_durations(sys.argv[1], [10.0, 10.0, 99.0])
bad, bad_why = cross_check_durations(sys.argv[1], [10.0, 10.0, 10.0])
if not agree:
    print("两把解析本该一致，却判不一致：%s" % why); sys.exit(1)
if bad:
    print("两把解析本该不一致，却放行：%s" % bad_why); sys.exit(1)
print("%s / %s" % (why, bad_why)); sys.exit(0)
PY
) && ok "cross_check：一致样本放行、错配样本拦截（$xmsg）" \
  || fail "cross_check_durations 这把复核尺失效：$xmsg"

  # 6) 交互期那把尺子（perf_framepulse.py）：0 / 1 / 2 三个退出码必须是三种意思
  #    （格式与产品是否脱钩由 `PerfFramePulseRulerTests` 拿真实摘要行对账，这里只管判定方向）
  printf 'hz=120.0(合成) 期望间隔=8.33ms 帧数=5000 帧间隔p50=8.33 p95=8.40 p99=8.50 max=9.00ms hitch(>1.5x)=0 hitch/s=0.00 心跳拍数=10 心跳最大间隔=1520.0ms 心跳p50=1500.0 p95=1510.0 带hitch的拍=0/10\n' > "$out/pulse-good.txt"
  printf '# 探针没开\n不是摘要行\n' > "$out/pulse-junk.txt"
  local c_idle c_live c_junk
  python3 "$PULSE_REPORT" "$out/pulse-good.txt" > "$out/pulse-idle.txt" 2>&1; c_idle=$?
  python3 "$PULSE_REPORT" "$out/pulse-good.txt" --interaction > "$out/pulse-live.txt" 2>&1; c_live=$?
  python3 "$PULSE_REPORT" "$out/pulse-junk.txt" --interaction > "$out/pulse-junk.txt" 2>&1; c_junk=$?
  [ "$c_idle" -eq 2 ] || fail "健康读数在未声明交互时退出码应为 2（第三种意思），实得 $c_idle"
  [ "$c_live" -eq 0 ] || fail "健康读数声明交互后应判达标（0），实得 $c_live：$(cat "$out/pulse-live.txt")"
  [ "$c_junk" -ne 0 ] || fail "坏数据被判成了达标——一次失败的测量会伪装成「0 hitch，完美」"
  [ "$c_idle" -eq 2 ] && [ "$c_live" -eq 0 ] && [ "$c_junk" -ne 0 ] \
    && ok "framepulse：达标/未达标/坏数据/未确认交互 四种结果互不混淆"

  # 7) 测量期间必须**印在汇总表上**，且 idle 那一档要明说"不许拿去交 T1"
  #    （§1 基线是心跳期量的、T1 要的是交互期，两批数同形状不同含义——不写出来一定会被人混用）
  mkdir -p "$out/period-idle" "$out/period-live"
  printf '{"rev":"合成","hitches_seconds":20,"period":"idle"}' > "$out/period-idle/meta.json"
  printf '{"rev":"合成","hitches_seconds":20,"period":"interaction"}' > "$out/period-live/meta.json"
  python3 "$TRACE_REPORT" summary "$out/period-idle" > "$out/period-idle.txt" 2>&1 || true
  python3 "$TRACE_REPORT" summary "$out/period-live" > "$out/period-live.txt" 2>&1 || true
  # 断言钉的是**那句拒绝**（`不许…交 T1`），不是"测量期间"四个字：
  # 第一版只 grep「只答心跳期」，把拒绝的后半句删掉它照样绿——反向验才抓出来。
  grep -q '不许.*交 T1' "$out/period-idle.txt" \
    || fail "idle 汇总表没写「不许拿去交 T1」——同形状不同含义的两批数一定会被混用"
  grep -q "有资格答 T1" "$out/period-live.txt" \
    || fail "interaction 汇总表没标出来，那 interact 档与 idle 就无法区分"
  grep -q "测量期间：idle" "$out/period-idle.txt" \
    && grep -q "测量期间：interaction" "$out/period-live.txt" \
    && ok "summary：测量期间进表头，两种期间各说各的资格"

  # 8) `migration` 报告：口径必须**从守卫源码里读**，读不到要炸，不许退回 0/0
  #    （工单 §0.1 那张手写表会腐烂——行号会漂；命令化之后各家能自己反复跑）
  local fake="$out/fake-tree"
  mkdir -p "$fake/Tests/TcoderMonitorTests" "$fake/Sources/TcoderMonitor/Views"
  cat > "$fake/Tests/TcoderMonitorTests/PerfInvalidationRatchetTests.swift" <<'SWIFT'
    static let coarsePattern = #"monitor\s*\.\s*(latestSnapshot|history)\b"#
    static let finePattern = #"monitor\s*\.\s*(cpu|pulse)\s*\.\s*value\b"#
    static let coarseCallSiteCeiling = 7
    private static let consumerDirectories = ["Sources/TcoderMonitor/Views"]
SWIFT
  cat > "$fake/Sources/TcoderMonitor/Views/Fake.swift" <<'SWIFT'
  // 文档注释里提到 monitor.latestSnapshot 不算调用点（与守卫同一条豁免）
  Text(monitor.cpu.value.title)
  Chart(monitor.history)
SWIFT
  local mig
  if mig=$(python3 "$TRACE_REPORT" migration --module-root "$fake" 2>&1) \
     && printf '%s' "$mig" | grep -q "粗粒度读点 1 处 / 登记上限 7 处" \
     && printf '%s' "$mig" | grep -q "细粒度读点 1 处"; then
    ok "migration：真扫到 1 处粗读 + 1 处细读、上限取自守卫文件、注释行按同一条豁免"
  else
    fail "migration 报告数不对（口径漂移或扫描失效）：$(printf '%s' "$mig" | head -3)"
  fi
  sed -i '' 's/static let coarsePattern/static let coarsePatternRenamed/' \
    "$fake/Tests/TcoderMonitorTests/PerfInvalidationRatchetTests.swift"
  if python3 "$TRACE_REPORT" migration --module-root "$fake" > /dev/null 2>&1; then
    fail "守卫常量被改名时 migration 仍退 0 —— 它会静默用旧口径报数，正是「第二把尺子」的来路"
  else
    ok "migration：读不到守卫常量就炸（拒绝退回手抄正则）"
  fi

  echo "◇ selfcheck：$checked 项通过，$fails 项失败（产物 $out）"
  [ "$fails" -eq 0 ] || die "尺子坏了 $fails 项——修尺子，别改读数"
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
    selfcheck) cmd_selfcheck "$@" ;;
    *) sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
}
main "$@"
