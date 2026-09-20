#!/bin/bash
# =============================================================================
# perf_harness.sh —— Tcoder 性能契约（120Hz）的外部尺子。spec §4.1。
#
# 三档测量，全部**只读**：
#   idle    attach 现有实例，录 Animation Hitches + Time Profiler，量心跳期（spec §1 那一档）
#   switch  逐页冷启动（-selectedDetailSection 中文页名），量首帧与冷构建成本
#   report  读已有输出目录，重打汇总表（不重录，省时间也省磁盘）
#
# ## 为什么这里绝不出现 kill / 信号
# AGENTS.md -1.3：进程监控只读展示。本脚本只 `pgrep` / `ps -p` 只读探活，
# 需要实例自行退出时走 `osascript ... quit`（App 自己的退出事件），不发信号。
# idle 档连 quit 都不需要——它 attach 的是**别人已经开着的**实例。
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
#   scripts/perf_harness.sh switch [输出目录]
#   scripts/perf_harness.sh report <输出目录>
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

TARGET_BINARY=""   # 由 require_idle_target 填：实际被采的那个二进制的绝对路径
TARGET_FLAVOR=""   # release / debug —— spec §7.3 要求两档的绝对值永不混比

note_target_flavor() {  # note_target_flavor <pid>
  TARGET_BINARY=$(ps -o args= -p "$1" 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | cut -d' ' -f1)
  case "$TARGET_BINARY" in
    *debug*) TARGET_FLAVOR="debug" ;;
    *) TARGET_FLAVOR="release" ;;
  esac
  echo "    被采二进制=$TARGET_BINARY 口径=$TARGET_FLAVOR"
}

preflight_context() {  # preflight_context <outdir> <pid>
  local out="$1" pid="$2" f="" cores load1 front visible others hard=0
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  [ -n "$load1" ] || load1=0
  f="$out/measurement-context.txt"

  front=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null | tr -d '\n')
  [ -n "$front" ] || front="未知"
  visible=$(osascript -e "tell application \"System Events\" to get visible of process \"TcoderMonitor\"" 2>/dev/null | tr -d '\n')
  [ -n "$visible" ] || visible="未知"
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
  if [ "$visible" = "false" ]; then
    echo "!! 被测进程处于 hidden 状态，窗口根本没在画。取消隐藏再测。" >&2
    hard=1
  fi
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
    echo "    目标实例 pid=$PID，来源：$(ps -o args= -p "$PID" | cut -c1-100)"
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
  exe=$(ps -o comm= -p "$PID" | sed 's/.*\///')
  echo "    目标实例 pid=$PID（$exe），来源：$(ps -o args= -p "$PID" | cut -c1-100)"
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
  echo "==> idle 档：attach 现有实例录心跳（release 口径；rev=$REV dirty=$DIRTY）"
  [ -x "$TRACE_REPORT" ] || die "缺 scripts/trace_report.py"
  require_idle_target
  mkdir -p "$out" || die "建不了 $out"
  meta_write "$out" "mode=idle" "pid=$PID" "binary=$TARGET_BINARY" \
    "hitches_seconds=$SECONDS_HITCHES" "tp_seconds=$SECONDS_TP" "coexisting_instances=${COEXIST:-1}" \
    "templates=$TEMPLATE_HITCH + $TEMPLATE_TP" "build_flavor=$TARGET_FLAVOR"
  preflight_context "$out" "$PID"

  echo "==> 1/4 录 Animation Hitches ${SECONDS_HITCHES}s（这期间不去碰鼠标键盘，否则量的就不是心跳）"
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
    # 首帧：xctrace 是父进程，被采 pid 只能从"最新起的那个实例"里认（只读 pgrep -n）。
    local pid first="" waited=0
    pid=$(pgrep -n -x TcoderMonitor 2>/dev/null || true)
    if [ -n "$pid" ]; then
      while [ "$waited" -lt 60 ]; do
        if [ -n "$(xcrun swift "$WINLIST" "$pid" 2>/dev/null | head -1)" ]; then
          first=$(python3 -c "import time;print('%.0f' % ((time.time()-$t0)*1000))")
          break
        fi
        sleep 0.2; waited=$((waited + 1))
      done
    fi
    export_table "$dir/launch.trace" "life-cycle-period" "$dir"
    export_table "$dir/launch.trace" "hitches" "$dir"
    xcrun xctrace export --input "$dir/launch.trace" --toc --output "$dir/toc.xml" >/dev/null 2>&1
    meta_write "$dir" "page=$page" "pid=$pid" "first_frame_ms=${first:-未观测到}" \
      "record_wall_s=$(python3 -c "print('%.1f' % ($t1-$t0))")"
    echo "    首帧(带采样器，窗口出现口径)=${first:-未观测到} ms；细表见 $dir/life-cycle-period.xml"
    [ -n "$first" ] && python3 "$TRACE_REPORT" lifecycle "$dir/life-cycle-period.xml" \
      --json "$dir/life-cycle-period.json" 2>/dev/null | sed 's/^/    /'
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

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    idle) cmd_idle "$@" ;;
    switch) cmd_switch "$@" ;;
    report) cmd_report "$@" ;;
    *) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
}
main "$@"
