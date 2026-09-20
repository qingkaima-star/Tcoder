#!/bin/bash
# =============================================================================
# perf_selfcheck.sh —— selfcheck 档（拿合成夹具量尺子自己），由 perf_harness.sh
# 在 `selfcheck` 那一档 **source** 进来。**不要单独执行**：它依赖宿主的
# $REV / $TRACE_REPORT / $PULSE_REPORT / $QUIESCE_SRC 与 quiescence_probe /
# quietest_seconds / human_input_in_window / die 这些同进程的量。
#
# 为什么搬出来（不是客套话）：`SelfScanDogfoodTests` 的 ≤800 行棘轮**分母含 `.sh`**
# 且 ceiling=0（`SourceLanguageCatalog` 认 Shell），perf_harness.sh 已经 750 行，
# 把 167 行 / CC 44 的 `cmd_selfcheck` 就地切成十个小函数一定会撞线——
# **搬出来 + 一项一个函数才是修复，拧阈值不是**（2026-09-20 就是 trace_report.py
# 长到 819 行把 main 判红过一次，那次没人提前发现，因为没人跑过 selfcheck 的这一项）。
#
# 每一项的判据、断言与 `ok` / `fail` 文案**逐字未动**；项与项之间只共享 `fails` /
# `checked` 两个计数器（bash 是动态作用域，编排器里的 `local` 在被调函数里照样可见，
# 这一条已单独验过）。拆前拆后的读数对照见 97 号笔记（八节 844 行输出逐字 diff）。
# =============================================================================

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

  selfcheck_ruler_files "$out"      # 1) 三层文件齐全 / 编译得过 / 没撞 ≤800 行棘轮
  selfcheck_switch_fixture "$out"   # 2) switch 档逐页表的三态（读数 / 缺 meta / 缺 life-cycle）
  selfcheck_empty_table "$out"      # 3) 空表要报"未采到"，而不是报"n=0 达标"
  selfcheck_missing_file "$out"     # 4) 垃圾输入必须非零退出
  selfcheck_cross_check "$out"      # 5) 反向元测试：复核尺抓得住不一致
  selfcheck_framepulse "$out"       # 6) 交互期那把尺子的三个退出码
  selfcheck_period_wording "$out"   # 7) 测量期间印在表头上 + 两档各说各的资格
  selfcheck_migration "$out"        # 8) migration 的口径必须从守卫源码里读
  selfcheck_quiescence "$out"       # 10) 人手静默探针（第五维）

  echo "◇ selfcheck：$checked 项通过，$fails 项失败（产物 $out）"
  [ "$fails" -eq 0 ] || die "尺子坏了 $fails 项——修尺子，别改读数"
}

selfcheck_ruler_files() {  # selfcheck_ruler_files <outdir>
  # 1) 三层文件都要在、都要编译得过、且没有一个撞本仓 ≤800 行棘轮
  #    （`SelfScanDogfoodTests` 的分母含 .py，ceiling=0：2026-09-20 就是 trace_report.py
  #     长到 819 行把 main 判红的，那次没人提前发现，因为没人跑过它。）
  local out="$1"
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
}

selfcheck_switch_fixture() {  # selfcheck_switch_fixture <outdir>
  # 2) switch 档的逐页表：有数据的那页必须真出数，缺项的必须显式写缺
  #    （钉的是 2026-09-20 实修的那个缺陷：cmd_switches 里 `cur` 未定义，
  #     **只有存在逐页子目录时才炸**，夹具为空时它"通过"，于是坏了很久没人知道。）
  local out="$1"
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
}

selfcheck_empty_table() {  # selfcheck_empty_table <outdir>
  # 3) 空表要报"未采到"，而不是报"n=0 达标"
  local out="$1"
  printf '<table><schema name="hitches"/><row/></table>\n' > "$out/empty.xml"
  if python3 "$TRACE_REPORT" durations "$out/empty.xml" > "$out/durations.txt" 2>&1 \
     && grep -q 'n=0（未采到）' "$out/durations.txt"; then
    ok "durations：空表如实写「未采到」，没有把 0 帧当成达标"
  else
    fail "durations 对空表的读数不对（要看 $out/durations.txt）"
  fi
}

selfcheck_missing_file() {  # selfcheck_missing_file <outdir>
  # 4) 垃圾输入必须非零退出：否则"读不到文件"和"真的 0 hitch"在退出码上无法区分
  local out="$1"
  if python3 "$TRACE_REPORT" durations "$out/根本没有这个文件.xml" > /dev/null 2>&1; then
    fail "拿不存在的 XML 还退 0 —— 那任何一次测量失败都会伪装成「0 次 hitch，完美」"
  else
    ok "缺文件非零退出（测量失败与达标是两种可区分的结果）"
  fi
}

selfcheck_cross_check() {  # selfcheck_cross_check <outdir>
  # 5) 反向元测试：`cross_check_durations` 这把复核尺必须真的抓得住不一致
  #    （它只在两把解析不一致时才拒绝出数；如果它对什么都不一致，等于永真绿）
  local out="$1"
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
}

selfcheck_framepulse() {  # selfcheck_framepulse <outdir>
  # 6) 交互期那把尺子（perf_framepulse.py）：0 / 1 / 2 三个退出码必须是三种意思
  #    （格式与产品是否脱钩由 `PerfFramePulseRulerTests` 拿真实摘要行对账，这里只管判定方向）
  local out="$1"
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
}

selfcheck_period_wording() {  # selfcheck_period_wording <outdir>
  # 7) 测量期间必须**印在汇总表上**，且 idle 那一档要明说"不许拿去交 T1"
  #    （§1 基线是心跳期量的、T1 要的是交互期，两批数同形状不同含义——不写出来一定会被人混用）
  local out="$1"
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
}

selfcheck_migration() {  # selfcheck_migration <outdir>
  # 8) `migration` 报告：口径必须**从守卫源码里读**，读不到要炸，不许退回 0/0
  #    （工单 §0.1 那张手写表会腐烂——行号会漂；命令化之后各家能自己反复跑）
  local out="$1"
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
}

selfcheck_quiescence() {  # selfcheck_quiescence <outdir>
  # 10) 人手静默探针：闸门新加的那一维必须自己能跑、能解析、判定向两边都咬得住
  #     （§1.3 两批作废基线的坏因就是"有人在动"，而 load / 编译 / 前台三条闸看不见手）
  local out="$1"
  [ -f "$QUIESCE_SRC" ] || fail "缺 scripts/input_quiescence.swift——静默闸是 preflight 的一维，不能删了留着判据"
  local qline qquiet
  qline=$(quiescence_probe)
  qquiet=$(quietest_seconds "$qline")
  if [ -z "$qquiet" ]; then
    fail "静默探针输出解析不出数字（拿到「$qline」）——preflight 那一维会永久取不到数，等于没有这把尺子"
  else
    ok "人手静默探针可跑可解析：距上次人手事件 ${qquiet}s"
  fi
  [ "$(human_input_in_window 2 20)" = "窗口内有人" ] \
    || fail "判定反了：静默 2s / 窗口 20s 应当是「窗口内有人」（idle 档要据此判污染）"
  [ "$(human_input_in_window 60 20)" = "窗口内没人" ] \
    || fail "判定反了：静默 60s / 窗口 20s 应当是「窗口内没人」（interact 档要据此判「没人在滚」）"
  ok "窗口判定双向都对（idle 防污染 / interact 防空滚 两种失效各管一头）"
}
