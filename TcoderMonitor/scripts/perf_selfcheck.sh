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
  selfcheck_weight_ruler "$out"     # 11) 收益分级：现读、缺料要喊、名单对不上要报⚠
  selfcheck_front_name "$out"       # 12) 前台名判定：显示名/进程名都认，别家一律拒
  selfcheck_render_regime "$out"    # 13) render 比率只在同一种出帧机制下互比
  selfcheck_binary_provenance "$out" # 14) 被量的二进制必须就是这份代码（rev 对齐）
  selfcheck_baseline_text_is_derived "$out"  # 15) 对照列文字不许是字典的第二份手抄
  selfcheck_heavy_jobs_probe "$out"  # 16) 并发重活：三个名字都要认，输出必须是 pid 清单

  echo "◇ selfcheck：$checked 项通过，$fails 项失败（产物 $out）"
  [ "$fails" -eq 0 ] || die "尺子坏了 $fails 项——修尺子，别改读数"
}

weight_fixture() {  # weight_fixture <fake根> —— 造一棵最小假树：两处裸写 + 一处闸门写
  local fake="$1"
  mkdir -p "$fake/Tests/TcoderMonitorTests" "$fake/Sources/TcoderMonitor/Views" \
           "$fake/Sources/TcoderMonitor/Services/Performance"
  cat > "$fake/Tests/TcoderMonitorTests/PerfInvalidationRatchetTests.swift" <<'SWIFT'
    static let coarsePattern = #"monitor\s*\.\s*(latestSnapshot|history|topProcesses)\b"#
    static let finePattern = #"monitor\s*\.\s*(pulse|curve)\s*\.\s*value\b"#
    static let coarseCallSiteCeiling = 7
    static let consumerDirectories = ["Sources/TcoderMonitor/Views"]
SWIFT
  weight_declare "$fake" '["latestSnapshot", "history"]' '["topProcesses"]'
  cat > "$fake/Sources/TcoderMonitor/Services/Performance/MachSystemMonitor.swift" <<'SWIFT'
    private func publish(_ batch: SampleBatch) {
        var stats = PublishStats()
        let leads = batch.leads
        latestSnapshot = batch.snapshot
        history = frames
        write(\.topProcesses, leads.cpuRanking, &stats)
        var a1 = 0
        var a2 = 0
        var a3 = 0
        var a4 = 0
        var a5 = 0
        var a6 = 0
        var a7 = 0
        stats.ticks += 1
        lastPublishStats = stats
    }
SWIFT
  printf 'extension Row { var a: Any { monitor.latestSnapshot } }\n' > "$fake/Sources/TcoderMonitor/Views/Fake.swift"
  printf 'extension Row { var b: Any { monitor.history } }\n' >> "$fake/Sources/TcoderMonitor/Views/Fake.swift"
  printf 'extension Row { var c: Any { monitor.topProcesses } }\n' >> "$fake/Sources/TcoderMonitor/Views/Fake.swift"
}

weight_declare() {  # weight_declare <fake根> <ungated 名单> <gated 名单>
  cat > "$1/Tests/TcoderMonitorTests/PerfInvalidationRatchetTests+CoarseWeighting.swift" <<SWIFT
    static let ungatedCoarseSymbols: Set<String> = $2
    static let gatedCoarseSymbols: Set<String> = $3
    static let unobservedCoarseSymbols: Set<String> = []
    static let aliasCoarseSymbols: Set<String> = []
SWIFT
}

selfcheck_weight_ruler() {  # selfcheck_weight_ruler <outdir>
  # 11) `migration` 新打的"承重 / 顺手"这一维也是扫描型判据，照本仓规矩双向钉：
  #     正例证明算得对，两条反例证明它**不会静默装好**。三步各自成函数（本仓对尺子的
  #     ≤50 行 / CC<16 棘轮会管这里，第一次跑就被它点名了）。
  local fake="$1/fake-weight"
  weight_fixture "$fake"
  selfcheck_weight_positive "$fake"
  selfcheck_weight_missing_source "$fake"
  selfcheck_weight_divergence "$fake"
}


selfcheck_weight_positive() {  # <fake根>：正例——两类都算出来
  local wout
  wout=$(python3 "$TRACE_REPORT" migration --module-root "$1" 2>&1)
  if printf '%s' "$wout" | grep -q '收益分级（从 publish() 现读' \
     && printf '%s' "$wout" | grep -q '\[承重\]' \
     && printf '%s' "$wout" | grep -q '\[顺手\]'; then
    ok "收益分级：合成夹具里算出承重与顺手两类"
  else
    fail "收益分级在合成夹具上没算对（应当既认出裸写、也认出闸门写）：$(printf '%s' "$wout" | head -3)"
  fi
}

selfcheck_weight_missing_source() {  # <fake根>：反例一——分级来源没了要喊，不许少打一维
  rm -f "$1/Tests/TcoderMonitorTests/PerfInvalidationRatchetTests+CoarseWeighting.swift"
  if python3 "$TRACE_REPORT" migration --module-root "$1" 2>&1 | grep -q '收益分级\*\*不可用\*\*'; then
    ok "分级来源缺失时报「不可用」，不静默少打一维"
  else
    fail "分级文件被删掉后它没喊——读的人会以为这一维本来就是空的"
  fi
}

selfcheck_weight_divergence() {  # <fake根>：反例二——两侧分叉必须报 ⚠
  # 第一版我把"声明"和"源码"两侧一起改了，两边自然一致、⚠ 永远出不来，
  # 是 selfcheck 自己判红才揭出这条废反例。要测的恰恰是**只动声明这一侧**。
  weight_declare "$1" '["history"]' '["topProcesses", "latestSnapshot"]'
  if python3 "$TRACE_REPORT" migration --module-root "$1" 2>&1 | grep -q '与守卫登记的名单不一致'; then
    ok "改了闸门写法却没回来改口径时，它报 ⚠ 而不是各说各话"
  else
    fail "两份口径已经分叉却没报出来——这条分级会静默腐烂"
  fi
}

selfcheck_front_name() {  # selfcheck_front_name <outdir>
  # 12) 这条是 02:43 那次"三趟全被拒"的直接产物：闸门一边报「前台是 Tcoder」一边说不在前台。
  #     判据抽成纯函数 `front_is_target`，所以这里能双向钉，不需要真去抢前台。
  # `front_is_target` 由 perf_harness.sh 顶部 source 进来，这里直接调；
  # 但先断言它真的在——不然"函数不存在"会被 for 循环当成"全都拒了"而一路绿灯。
  if ! declare -f front_is_target >/dev/null; then
    fail "front_is_target 不在当前作用域里（preflight 没被 source），这条自检等于没跑"
    return
  fi
  local ok=1
  for name in Tcoder TcoderMonitor; do
    if ! front_is_target "$name"; then
      fail "前台是「$name」应当判合格（显示名与进程名都要认）"; ok=0
    fi
  done
  for name in 微信 "Google Chrome" "" Finder; do
    if front_is_target "$name"; then
      fail "前台是「${name:-空}」必须被拒——否则这条闸门等于没在守"; ok=0
    fi
  done
  [ "$ok" = "1" ] && ok "前台名判定双向都对（显示名/进程名认，其余一律拒）"
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
  #
  #    夹具的 meta.json **照生产侧的形状写**：`perf_harness.sh` 是用 shell 变量塞的
  #    （`"hitches_seconds=$SECONDS_HITCHES"`），落盘就是字符串 `"20"`。
  #    原先这里写的是数字 20，于是尺子在"整数秒"下自测全绿、真产物一跑就 TypeError——
  #    夹具与生产者不同形，等于自测在量另一个程序（2026-09-21 实测）。
  #    同理不再 `|| true`：吞掉退出码就把"崩表"降级成了"看不见"。
  local out="$1"
  mkdir -p "$out/period-idle" "$out/period-live"
  printf '{"rev":"合成","hitches_seconds":"20","period":"idle"}' > "$out/period-idle/meta.json"
  printf '{"rev":"合成","hitches_seconds":"20","period":"interaction"}' > "$out/period-live/meta.json"
  # 光有 meta 不够：没有 hitches 表时那条除法根本走不到，夹具会"因为没数据而绿"。
  # 2 个 hitch / 20 s ⇒ 速率必为 0.10 /s——这个数同时钉住"秒数真的被当分母用了"
  # （秒数被认成 0 会印 0.00 /s，认成字符串会 TypeError）。
  cat > "$out/period-idle/hitches.xml" <<'XML'
<table><schema name="hitches"/>
<row><start-time id="1" fmt="00:00.000.000">0</start-time><duration id="2" fmt="10.00 ms">10000000</duration></row>
<row><start-time id="3" fmt="00:01.000.000">1000000000</start-time><duration id="4" fmt="20.00 ms">20000000</duration></row>
</table>
XML
  python3 "$TRACE_REPORT" summary "$out/period-idle" > "$out/period-idle.txt" 2>&1 \
    || { fail "字符串秒的 meta 让汇总表崩了（生产侧就是字符串）：$(tail -2 "$out/period-idle.txt")"; return; }
  python3 "$TRACE_REPORT" summary "$out/period-live" > "$out/period-live.txt" 2>&1 || true
  grep -q '0\.10 /s' "$out/period-idle.txt" \
    || { fail "hitch 速率不是 0.10 /s（2 次 / 20 s）——秒数没被当分母用：$(grep -n 'hitch 次数' "$out/period-idle.txt" | head -1)"; return; }
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

selfcheck_render_regime() {  # selfcheck_render_regime <outdir>
  # 13) render 的"比率只有同一种出帧机制才许互比"——纯函数，正反两头都钉。
  #     为什么要有这条：报表把 §1 的 `0.42%` 和本次的 `4.97%` 并排打出来，读的人
  #     得出"恶化 12 倍"，而两边帧数其实是 10 对 9——差的是分母（基线 20 s 连出
  #     2394 帧≈120fps，本次同窗口只出 181 帧≈9fps）。比率的分母一旦被机制换掉，
  #     减法就不许尺子替人做。缺分母一律按"不可比"，不猜。
  local out="$1" r
  cat > "$out/regime_case.py" <<'PY'
from perf_trace_metrics import as_int, regime_note
same, n1 = regime_note(2394, 20, 2400, 20)   # 同机制（120fps 对 120fps）→ 可比、不解释
diff, n2 = regime_note(2394, 20, 181, 20)    # 真产物那一对：120fps 对 9fps → 不可比
miss, n3 = regime_note(2394, 20, 181, 0)     # 窗口秒数缺失 → 不可比
assert same and not n1, "同机制被判成不可比（会白白废掉对照列）：%s" % n1
assert (not diff) and "倍" in n2, "跨机制没拦住、或话里没给倍数：%s" % n2
assert not miss, "分母不全却当成可比——正是要防的那类裸比"
assert as_int("20") == 20 and as_int(20) == 20 and as_int("abc") == 0, "as_int 没收敛"
print("ok")
PY
  r=$(PYTHONPATH="$(dirname "$TRACE_REPORT")" python3 "$out/regime_case.py" 2>&1)
  if [ "$r" = "ok" ]; then
    ok "render 机制判定双向都对（同机制放行 / 跨机制拦住并报倍数 / 缺分母不可比）"
  else
    fail "render 机制判定坏了：$(printf '%s' "$r" | tail -2)"
  fi
}

selfcheck_binary_provenance() {  # selfcheck_binary_provenance <outdir>
  # 14) 闸门第六维：**被量的二进制必须就是这份代码**。2026-09-21 实测踩过——
  #     上下文里写 `HEAD=e991c6d`，而 attach 的 `dist/Tcoder.app` 是两小时前从
  #     `41add9e` 建的（中间隔 39 个产物文件）。"e991c6d 的 T2 读数"是假的。
  #     纯函数三个失效方向各钉一次，放行方向也必须钉（不然恒拒的闸门又算白修）。
  if ! declare -f provenance_ok >/dev/null; then
    fail "provenance_ok 不在作用域里（preflight 没被 source），这条自检等于没跑"
    return
  fi
  local H=1111111111111111111111111111111111111111 B=2222222222222222222222222222222222222222 bad=0 why
  # 注意取非的方向：`provenance_ok` 回 0 = "可比"。rev 不同却回 0 才是要防的失效。
  if why=$(provenance_ok "$B" "$H" true); then
    fail "rev 不同却放行了（正是要防的那类归错对象）"; bad=1
  else
    case "$why" in *"产物是 2222222"*"当前代码是 1111111"*) ;;       *) fail "拒因里没带上两个短号，人拿这话查不到现场：$why"; bad=1 ;; esac
  fi
  if provenance_ok "$H" "$H" true; then :; else fail "同一份代码被判不可比——这条闸门会恒拒，量不出任何东西"; bad=1; fi
  if provenance_ok "" "$H" true; then fail "读不到 manifest 却放行"; bad=1; fi
  if provenance_ok "$H" "$H" false; then fail "构建时工作树是脏的却放行——那时连 rev 本身都不可信"; bad=1; fi
  if provenance_ok "$H" "" true; then fail "取不到 HEAD 却放行——无法比对就等于没验"; bad=1; fi
  # 【同一件事只许有一把手尺子】我补这一维时先是**又写了一份**，才发现
  # `verify_provenance.sh` 早就在做同一件事。现在判定住在 `perf_provenance.sh`，
  # 两边都 source 它。下面三条把这个结构钉住：定义处唯一、交付档确实走它、
  # 测量档不许留本地副本（漏一天就会分叉，而分叉之后错的那份常在喂结论）。
  local defs
  # 模式必须锚行首：不锚的话它会把我**写在自检里的这串模式本身**当成一处定义
  # （第一版就是这么红的——报错报到自己头上，说明它真的在看内容）。
  defs=$(grep -lr '^provenance_ok() {' scripts/ 2>/dev/null | tr '\n' ' ')
  [ "$defs" = "scripts/perf_provenance.sh " ] \
    || { fail "provenance_ok 的定义不止一处（$defs）——同一判定又长出第二份了"; bad=1; }
  grep -q 'provenance_ok' scripts/verify_provenance.sh \
    || { fail "verify_provenance.sh 不再经过共享判定（大概又手抄了一遍 [ a = b ]）"; bad=1; }
  grep -q 'preflight_manifest_value\|^provenance_ok() {' scripts/perf_preflight.sh \
    && { fail "perf_preflight.sh 里还留着本地副本，删掉、只 source"; bad=1; }
  [ "$bad" = "0" ] && ok "二进制出身判定五向都对，且定义唯一（verify 与 preflight 共用 perf_provenance.sh）"
}

selfcheck_baseline_text_is_derived() {  # selfcheck_baseline_text_is_derived <outdir>
  # 15) 对照列的文字必须由 `BASELINE` **生成**，不许在 `fmt_row(...)` 里再抄一份数字。
  #     为什么单独一条：§1 那批数被更正过一整轮（4.05→4.06、4.67→4.77、5 帧→10 帧、
  #     0.21%→0.42%，spec §1.4），而当时字典与 `fmt_row` 里的字面量是**两份**。
  #     下次再更正只会改到一处——表上留着旧数，而旧数看着完全合理，没人会起疑。
  local out="$1" r
  cat > "$out/derived_case.py" <<'PYCASE'
import io, sys
from perf_trace_metrics import (BASELINE, base_app_update_line, base_hang_line,
                                base_hitch_frame_line, base_hitches_line, base_hotspot_line,
                                base_main_thread_line, base_render_line)
src = io.open(sys.argv[1], encoding="utf-8").read()
# 扫"除注释行以外的整份文件"，而不是只扫含 fmt_row( 的行：
# 后者会漏掉**续行**上的字面量（`fmt_row("x", base_line(),` 的下一行才是抄死的那串），
# 而换行位置是格式化决定的人不会去盯的东西。注释行放过——那里的旧数是历史叙述，不是口径。
printed = [ln for ln in src.splitlines() if not ln.strip().startswith("#")]
drift = [x for x in ("2.73", "4.06", "25.12", "10.8~24.8", "684/807", "84.8%", "42.6",
                     "573 ms", "0.42%", "33.33~58.33", "64.3%", "7 次 / 0.35")
         if any(x in ln for ln in printed)]
if drift:
    print("对照列里还有手抄数字（字典一改就分叉）：%s" % ", ".join(drift)); sys.exit(1)
cases = (("render_p95_ms", 9.99, base_render_line),
         ("main_thread_share_pct", 12.5, base_main_thread_line),
         ("app_update_ms", [1.5, 2.5], base_app_update_line),
         ("potential_hangs", 77, base_hang_line),
         ("hitches", 41, base_hitches_line),
         ("hotspot_top1_pct", 33.3, base_hotspot_line),
         ("hitch_frame_ms_max", 99.9, base_hitch_frame_line))
for key, sentinel, fn in cases:
    old = BASELINE[key]
    BASELINE[key] = sentinel
    try:
        text = fn()
    finally:
        BASELINE[key] = old
    probe = str(sentinel[1] if isinstance(sentinel, list) else sentinel)
    if probe not in text:
        print("改 %s 没让对照文字动（它是抄的，不是生成的）：%s" % (key, text)); sys.exit(1)
    if fn() == text:
        print("改 %s 前后文字一样（生成器压根没读字典）" % key); sys.exit(1)
print("ok")
PYCASE
  r=$(PYTHONPATH="$(dirname "$TRACE_REPORT")" python3 "$out/derived_case.py" \
        "$(dirname "$TRACE_REPORT")/perf_trace_summary.py" 2>&1)
  if [ "$r" = "ok" ]; then
    ok "对照列文字由 BASELINE 生成（打印行无手抄数，且改字典 7 处字段文字都会跟着动）"
  else
    fail "对照列与字典脱钩：$(printf '%s' "$r" | tail -2)"
  fi
}

selfcheck_heavy_jobs_probe() {  # selfcheck_heavy_jobs_probe <outdir>
  # 16) "机器空不空"这一维自己也要能跑、能解析、清单不能被偷偷削短。
  #     （§1.3 那两批作废基线的坏因之一就是"有东西在跑而闸门看不见"：
  #      第一版只认 swiftc，全量门禁在跑时它读成"空"。）
  if ! declare -f concurrent_heavy_jobs >/dev/null; then
    fail "concurrent_heavy_jobs 不在作用域里——这一维等于没人守"
    return
  fi
  local out
  out=$(concurrent_heavy_jobs)
  case "$out" in
    *[!0-9\ ]*) fail "并发重活探针输出不是 pid 列表（拿到「$out」）——话术会跟着一起胡说" ;;
    *) ok "并发重活探针可跑可解析（现在：${out:-机器空}）" ;;
  esac
  # 清单被削回只认 swiftc 的话，本仓全量门禁期间就会假装机器空着——钉住三个名字。
  local n missing=""
  for n in swiftc swift-test xctest; do
    grep -q "\b$n\b" <(declare -f concurrent_heavy_jobs) || missing="$missing $n"
  done
  [ -z "$missing" ] \
    && ok "探针覆盖 swiftc / swift-test / xctest 三种重活" \
    || fail "探针不再认识这些重活：${missing# }——全量门禁在跑时会被读成机器空"
}
