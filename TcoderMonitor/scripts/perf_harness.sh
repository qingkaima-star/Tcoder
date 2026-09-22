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
# `$SCRATCH/tcoder-perf-<rev>/`：不带后缀时后一批会静默覆盖前一批，
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
# 一次性产物的落点（AGENTS §1.6）：默认仓库内的 `.scratch/`（已 gitignore），
# 不再往 $TMPDIR 倒 —— 2026-09-21 这台机被别的车道的 21 个孤儿 ktrace 吃掉 103 GB，
# 我们的 xctrace bundle 同样是 GB 级，规矩必须写进工具而不是写进记忆。
# 覆盖方式：`TCODER_SCRATCH=/some/dir ./scripts/perf_harness.sh …`。
SCRATCH="${TCODER_SCRATCH:-$(git rev-parse --show-toplevel)/.scratch}"
# 建不出来就**拒绝录制**，不许把样本根退回全局临时目录。
# 原来这里是"mkdir 失败就把 SCRATCH 指到 TMPDIR"的一行兜底 —— 上面那句
# "不再往 $TMPDIR 倒"立刻被它推翻：一旦 `.scratch` 建不出来（只读挂载、
# 路径被占、仓库在外置盘上休眠），GB 级 trace 就静默落回全局临时目录，
# 正是 103 GB 那次的形状。第 23 项反例当时没抓到它，
# 因为那条只认"绝对临时目录 + 样本名前缀"这种写死形态，不认变量兜底这种形态
# （同一个失效的两副面孔）。这行注释本身也不许把那种字面量抄回来——
# 抄回来就会被那条 grep 命中，判据被自己的说明文字绊倒，今晚已经第三次。
if ! mkdir -p "$SCRATCH" 2>/dev/null || [ ! -w "$SCRATCH" ]; then
  echo "!! 样本根 \$SCRATCH=$SCRATCH 建不出来或不可写 ⇒ 拒绝录制（不退回 \$TMPDIR）。" >&2
  echo "   要么修这个目录，要么显式给一个可写且被 git 忽略的位置：TCODER_SCRATCH=/path/to/dir $0 …" >&2
  exit 2
fi

# 录一档 xctrace 是 GB 级的事。2026-09-21 这台机被一次没自清的取证吃掉 103 GB、
# 可用只剩 4.4 GiB，那种情况下录到一半会**留下半份 trace 且报告读起来像真的**。
# 所以磁盘余量是录制的前置条件，不是事后检查。覆盖：TCODER_MIN_FREE_GIB=60。
require_disk_headroom() {  # 录制前的硬前置：判定**不在这儿**，在 probes 的 disk_headroom_bad
  # 今天两拨人各自实现了一遍这条规矩（我这头的第七维闸门 / 这头的前置 die），
  # 合并时若只是"都留下"，就成了同一条判据的两把尺子——两份迟早分叉。
  # ⇒ 取数与判定只留一份；这里只保留"录制前就停"这个不同**时机**。
  local why
  why=$(disk_headroom_bad "$(disk_free_gib)") && { die "$why：不录制。"; }
  echo "    磁盘余量前置：$(disk_free_gib) GiB ≥ ${TCODER_MIN_FREE_GIB:-20} GiB ✔"
}



REV=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
DIRTY=$(git status --porcelain 2>/dev/null | wc -l | tr -d ' ')
TEMPLATE_HITCH="Animation Hitches"
TEMPLATE_TP="Time Profiler"
TEMPLATE_LAUNCH="App Launch"
SECONDS_HITCHES="${SECONDS_HITCHES:-20}"
SECONDS_TP="${SECONDS_TP:-25}"
SECONDS_LAUNCH="${SECONDS_LAUNCH:-10}"
PERF_BIN="${PERF_BIN:-$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor}"
TRACE_REPORT="$PWD/scripts/trace_report.py"
PULSE_REPORT="$PWD/scripts/perf_framepulse.py"
# selfcheck 档的实现放在旁边那个文件里，只在跑 selfcheck 时 source 进来（同一进程、同一批全局量）。
# 为什么搬出去：本仓 ≤800 行棘轮的分母**含 .sh**（`SourceLanguageCatalog` 认 Shell）、ceiling=0，
# 而 selfcheck 一项一个小函数之后本文件会撞线——搬出去才是修复，拧阈值不是。
SELF_CHECK_SRC="$PWD/scripts/perf_selfcheck.sh"
DOMAIN="com.tcoder.monitor"
# 探针的路径与二进制**不在这里赋**（`perf_probes.sh` 自带默认，按 `BASH_SOURCE` 算）：
# 这里赋一次、那边再赋一次，就是"同一件事两把尺子"的老病。
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
# 测量环境合格性这一层（谁在跑 / 被采的是哪个口径 / 窗口在不在 / 人手静默够不够 /
# 导表与 meta 落盘）住在旁边那个文件里，**无条件 source**：idle / interact / switch /
# selfcheck 四档共用同一批闸门，复制一份判定就是造第二把尺子。
# 为什么搬出去：本仓 ≤800 行棘轮的分母含 `.sh`、ceiling=0，而本 App 自扫还有一条更近的
# 「巨大文件 >400 行」——本文件当时 643 行被点名。搬出去才是修复，拧阈值不是。
# 与 perf_selfcheck.sh 的区别：selfcheck 只在跑那一档时才读，这一层四档都要。
# -----------------------------------------------------------------------------
PREFLIGHT_SRC="$PWD/scripts/perf_preflight.sh"
[ -f "$PREFLIGHT_SRC" ] || die "缺 $PREFLIGHT_SRC（测量环境合格性那一层被拆走了——它不归本文件管）"
# shellcheck source=/dev/null  # 依赖本文件上面刚定义的全局量与 die / run，同进程同作用域
# shellcheck disable=SC1090
. "$PREFLIGHT_SRC"

# =============================================================================
# idle —— 不碰它，量心跳（spec §1 / §3 T2 的那一档）
# =============================================================================
cmd_idle() {
  local out="${1:-$SCRATCH/tcoder-perf-$REV}"
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
           "input_source=${INPUT_SOURCE:-human}" \
    "hitches_seconds=$SECONDS_HITCHES" "tp_seconds=$SECONDS_TP" "coexisting_instances=${COEXIST:-1}" \
    "templates=$TEMPLATE_HITCH + $TEMPLATE_TP" "build_flavor=$TARGET_FLAVOR"
  preflight_context "$out" "$PID"
  # 走到这里说明闸门放行、马上就要真录：清掉**上一次尝试**留下的 REFUSED。
  # 标记描述的是"最近一次尝试"，不是目录的永久属性；不清的话同名目录复用时，
  # 一份合法读数会被过期标记挡在对照表外（report 会退 1）。
  rm -f "$out/REFUSED"
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
  # 每轮收尾固定动作：确认自己起的采集进程真退了 + 扫 $TMPDIR 里的 .ktrace 残骸。
  # 盘满不是"报错退出"那种失败——它会让 xctrace 写不进中间产物，
  # 样本**照样出一份看起来合理的表**，所以必须在代码里做，不能靠人记得。
  post_run_disk_hygiene
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
switch_page_list() {  # → 每行一个页名（**必须按行遍历**）
  # 旧实现在这里 `tr '\n' ' '`，配合下面的 `for page in $pages` 做词分割 ——
  # 而页名里有带空格的：`Git 洞察` 被切成 "Git" + "洞察" 两页，
  # 九页扫描实际只覆盖 8 页，还有一页被用错名字起了一次 App。
  # 实测抓到于 2026-09-21 14:53（日志里同时出现 `--> 4) Git` 与 `--> 5) 洞察`）。
  if [ -n "${PAGES:-}" ]; then
    printf '%s\n' "$PAGES"
  else
    sections
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



cmd_report() {
  local out="${1:-$SCRATCH/tcoder-perf-$REV}"
  [ -d "$out" ] || die "没有这个输出目录：$out"
  # 被闸门拒掉的那趟**不许被 report 当成一趟数据重打**：
  # 它只有 context/meta，喂给汇总表会得到"没有 hitch"形状的漂亮空表。
  [ -f "$out/REFUSED" ] && die "这一趟当时被闸门拒了、没有采数（$out/REFUSED）——
    它不该出现在任何对照表里；要看当时的拒因就读 $out/measurement-context.txt。"
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
  python3 "$TRACE_REPORT" summary "$out" --seconds "$secs"; local src=$?
  [ -s "$out/time-profile.xml" ] && python3 "$TRACE_REPORT" threads "$out/time-profile.xml" --thread "Main Thread"
  [ -d "$out/pages" ] && python3 "$TRACE_REPORT" switches "$out/pages"
  # 显式收尾：上面两条都是 `[ 测试 ] && 命令` 的形状，没有 pages 目录时（idle 档就是没有）
  # 最后一条测试自己返回 1，会把"重打成功"报成"档口失败"。
  # 实测踩过：修尺子那轮 `report` 明明全打出来了，退出码仍是 1，逼得人回头去查 Traceback。
  # 但"如实传 rc"不等于"一律传 0"：summary 判**期间自我矛盾**时给的是 3，
  # 上面那句 `return 0` 会把它一起吞掉 ⇒ 表头翻对了话术、脚本拿到的还是绿灯。
  case "$src" in
    0) return 0 ;;
    3) echo "    ⇒ 以 rc=3 退出：本目录的档位声明与收尾复核互相矛盾，不得作为结论提交。" >&2
       return 3 ;;
    *) return "$src" ;;
  esac
}

# =============================================================================
# probe —— 读 FramePulse 的落盘脉冲（交互期 hitch 的唯一入口，零采样）
# =============================================================================
pulse_context_note() {  # 这份读数的**条件**全部现采，不许抄上一次的说法
  local others; others=$(pgrep -x TcoderMonitor 2>/dev/null | wc -l | tr -d ' ')
  printf '条件：档=pulse（进程内帧脉冲） rev=%s dirty=%s 输入=synth@%sms ≈%dHz，非真人手感 本机 Tcoder 实例数=%s（含本实例） 起法=直接 exec，不是 LaunchServices open\n' \
    "$REV" "$DIRTY" "${SYNTH_GAP_MS:-8}" "$((1000 / ${SYNTH_GAP_MS:-8}))" "$others"
}

cmd_pulse() {  # pulse 档：边投合成滚动边读**帧间隔 p95** —— T1 那条判据的直接对象
  # 为什么要单独一档：xctrace 的 hitches 表只列**超预算**的那些帧，
  # 而验收口径是"p95 帧间隔 ≤ 8.4 ms"——那是**全部帧**的分位数，hitches 表里没有这一列。
  # FramePulse 在 CVDisplayLink 回调里逐帧记间隔，是这条判据唯一的直接仪器。
  local secs="${1:-12}"
  local out="${2:-$SCRATCH/tcoder-perf-$REV-pulse-$(date +%H%M%S)}"
  require_disk_headroom
  mkdir -p "$out/sandbox"
  # shellcheck source=/dev/null
  declare -f ensure_synth_scroller >/dev/null || source scripts/perf_probes.sh
  ensure_synth_scroller || die "合成输入器准备失败 ⇒ pulse 档一趟都不跑（不拿 idle 数冒充交互期）"
  # 【不抢人的鼠标】这一档会 CGWarp 光标到被测窗口再投滚动，人在用机器时这是打扰。
  # 所以先问一次静默探针：**量不到也当"有人在"**（宁可不跑，不蒙一次）。
  local q; q=$(quietest_seconds "$(quiescence_probe)")
  probe_usable "$q" || die "静默探针取不到（拿到「${q:-空}」）⇒ 不知道有没有人在动，不投滚动"
  [ "$(human_input_in_window "$q" "${PULSE_WANT_QUIET:-15}")" = "窗口内没人" ] \
    || die "人手 ${q}s 前还在动（要 ≥${PULSE_WANT_QUIET:-15}s）⇒ 这一档会抢光标，不抢人"
  local file="$out/framepulse.txt"
  echo "==> pulse 档：自己起一个带探针的实例，滚 ${secs}s（产物 $out）"
  TCODER_PERF_PROBE=1 TCODER_PERF_OUT="$file" TCODER_SUPPORT_DIR="$out/sandbox" \
    "$PERF_BIN" >/dev/null 2>&1 &
  local pid=$!
  trap 'kill -TERM "$pid" 2>/dev/null || true' EXIT INT TERM
  sleep 3   # 等窗口出来再投事件，否则"投了但其实没滚动"，那是一份假样本
  # 秒数走 SYNTH_SECS：start_synth_scroller 的第 2 个位置参数**不是**秒数（它内部按
  #   <秒> <pid> <像素> <间隔> 传给投事件器），我第一版按位置传，结果它照默认投了 95 秒，
  #   比本档生命期长 80 秒 ⇒ 实例都没了还在往屏幕上投滚动事件。这类"参数被静默忽略"的错，
  #   只能靠把"实际用了多久"打出来才会露出来，所以下面 echo 里带上秒数。
  SYNTH_SECS=$((secs + 4)) start_synth_scroller "$pid" \
    || { kill -TERM "$pid" 2>/dev/null || true; die "投事件器起不来 ⇒ 本档作废"; }
  sleep "$secs"
  kill -TERM "$pid" 2>/dev/null || true
  trap - EXIT INT TERM
  pulse_context_note | tee "$out/pulse-context.txt"
  [ -s "$file" ] || die "FramePulse 没产出 ⇒ 按未覆盖处理，不许当成「0 hitch = 达标」"
  python3 "$PULSE_REPORT" "$file" --interaction
}

cmd_probe() {
  local file="${1:-}"
  # 【为什么要有 --start】整条自动化里**没有任何地方设过 TCODER_PERF_PROBE=1**，
  # 而 `open` 起的 App 也不继承调用方环境变量 ⇒ 这颗"进程内侧量帧脉冲"的探针
  # 在无人值守链里**根本开不起来**，probe 档于是只能读到一个永远不会出现的 /tmp 文件。
  # 它不牵连 T1/T2 的判决（那两个读的是 xctrace 的 hitches / updates / displays 表），
  # 但"规范里写着的仪器"与"实际接得通的仪器"必须是同一件，所以这里补一条起法。
  if [ "$file" = "--start" ]; then
    local secs="${2:-8}"
    # macOS 自带 bash 3.2 没有 BASHPID（第一次跑就在这行 unbound 死掉，还是 `set -u` 那种
    # "不报错、直接终止"的死法），所以文件名只用 $$ + 秒，够用且不会撞名。
    file="$SCRATCH/tcoder-framepulse-$REV-$$-$(date +%s).txt"
    echo "==> 自己起一个带探针的实例，采 ${secs}s（输出落仓库内 $file，不写 /tmp）"
    TCODER_PERF_PROBE=1 TCODER_PERF_OUT="$file" "$PERF_BIN" >/dev/null 2>&1 &
    local probe_pid=$!
    trap 'kill -TERM "$probe_pid" 2>/dev/null || true' EXIT INT TERM
    sleep "$secs"
    kill -TERM "$probe_pid" 2>/dev/null || true
    trap - EXIT INT TERM
    [ -s "$file" ] || die "探针没产出（$file 不存在或为空）⇒ 要么 env 没传进去，要么这个 build 里 FramePulse 没接上"
    shift 2
    set -- "$file" "$@"
    echo "    起了 pid=$probe_pid，产物 $file（$(wc -l < "$file" | tr -d ' ') 行）"
  fi
  [ "$#" -gt 0 ] && file="$1"
  [ -n "$file" ] || file=$(ls -t "$SCRATCH"/tcoder-framepulse-*.txt /tmp/tcoder-framepulse-*.txt 2>/dev/null | head -1)
  [ -n "$file" ] || die "找不到 FramePulse 产物：用 `probe --start` 现采一趟，或自己带 TCODER_PERF_PROBE=1 起 App"
  case "$file" in
    /tmp/*) echo "    ⚠ 读的是 /tmp 下的旧探针文件——仓库外，可能被系统清理（今晚对照组就是这么丢的）" >&2 ;;
  esac
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
  PERIOD=interaction cmd_idle "${1:-$SCRATCH/tcoder-perf-interact-$REV}"
}

main() {
  local cmd="${1:-}"
  shift || true
  case "$cmd" in
    idle) require_disk_headroom; cmd_idle "$@" ;;
    interact) require_disk_headroom; cmd_interact "$@" ;;
    switch)
      require_disk_headroom
      # 懒加载：switch 档的实现搬在旁边的 `perf_switch.sh`（还 ≤400 行口径），
      # 只有真跑这一档才 source 进来；同一进程 ⇒ 全局量与口径完全不变。
      # shellcheck source=scripts/perf_switch.sh
      . "$(dirname "${BASH_SOURCE[0]}")/perf_switch.sh"
      cmd_switch "$@" ;;
    report) cmd_report "$@" ;;
    probe) cmd_probe "$@" ;;
    pulse) cmd_pulse "$@" ;;
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
