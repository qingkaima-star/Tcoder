# =============================================================================
# perf_selfcheck_threads.sh —— selfcheck 反例分块：`trace_report.py threads` 那把尺的行为级臂
#
# 为什么从 `perf_selfcheck_tables.sh` 搬出来（2026-09-27 §211／#118）：
#   ① 给第 75 项加第六格（入口根帧）把那个函数顶到 **CC 16**，被
#      `PerfRulerHotspotRatchetTests.testRulerFunctionsStayBelowTheComplexityBar`
#      在门禁里当场判红（1948 例 1 失败）⇒ 门禁替我做了那个判断：两件事各是一项，别塞。
#   ② 宿主当时 **396/400**，正踩仓库自己的「巨大文件」口径（`FileSystemCodeAnalyzer.mediumFileLines`），
#      而本仓的规约是"拆，不抬线"。
# 搬前搬后**内容是纯搬运**：两枚夹具与第 75 项那五格逐字未动（对 `a919999` 的 diff 只剩
# 头注，以及"第六格搬出去当第 81 项"那一笔——那一笔发生在搬家**之前**，理由就是上面 ①）。
# ⚠ 新建一块文件要同时进两张名册，否则"拆"本身变成免检通道：
#   ① `PerfRulerHotspotRatchetTests` 的 rulerScripts（函数级那两把尺：≤50 行／CC<16）；
#   ② `perf_selfcheck.sh` 的 _part 名单（source 得到，臂才算在场）——第 79 项专查这三张表对齐。
# =============================================================================
threads_window_fixture() {  # 内部工具（不是 item，故不叫 selfcheck_*）：一份两线程 × 四段时间轴的 time-profile 夹具
  # 形状照真件：`sample-time`/`thread` 用 id＋ref 混着引用，另有 `<sentinel/>` 位的替身，
  # 因为切片要读的就是这些行——夹具抄真件形状，臂才可能抓住真问题（第 43 类那一课）。
  cat > "$1" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[9]'><schema name="time-profile"><col><mnemonic>time</mnemonic></col><col><mnemonic>thread</mnemonic></col></schema>
<row><sample-time id="1" fmt="00:00.100.000">100000000</sample-time><thread id="2" fmt="Main Thread (0x1) (TcoderMonitor, pid: 1)"><tid id="3" fmt="0x1">1</tid><process id="4" fmt="TcoderMonitor (1)"><pid id="5" fmt="1">1</pid></process></thread><process ref="4"/><thread-state id="6" fmt="Running">Running</thread-state><weight id="7" fmt="5.00 ms">5000000</weight><tagged-backtrace id="8" fmt="a"><backtrace id="9"><frame id="10" name="alpha" addr="0x1"/><frame id="11" name="main" addr="0x2"/></backtrace></tagged-backtrace></row>
<row><sample-time id="12" fmt="00:00.150.000">150000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="13" fmt="b"><backtrace id="14"><frame ref="10"/><frame ref="11"/></backtrace></tagged-backtrace></row>
<row><sample-time id="15" fmt="00:00.300.000">300000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="16" fmt="c"><backtrace id="17"><frame id="18" name="beta" addr="0x3"/><frame ref="11"/></backtrace></tagged-backtrace></row>
<row><sample-time id="19" fmt="00:00.400.000">400000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace ref="16"/></row>
<row><sample-time id="20" fmt="00:00.500.000">500000000</sample-time><thread id="21" fmt="Worker (0x9) (TcoderMonitor, pid: 1)"><tid id="22" fmt="0x9">9</tid><process ref="4"/></thread><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace ref="16"/></row>
<row><sample-time id="23" fmt="00:00.600.000">600000000</sample-time><thread ref="21"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace ref="16"/></row>
</node></trace-query-result>
XML
}

root_plumbing_fixture() {  # 内部工具：主线程 6 个样本——入口根帧 `.main()` 在 5 个里（83.3 %），真热点 4／次热 2
  # 为什么要单独一份夹具（不复用上面那份）：上面那份的根帧出现在**每一个**样本里（100 %），
  # 会被 `PLUMBING_SHARE_PCT=98` 那道"比例兜底"顺手挡掉 ⇒ 测不到真正那条脆弱面：
  # **按字面名单认底盘**。真出事的就是这条——无头 CLI 把入口改名成 `TcoderEntry.main()`，
  # 名单里的 `App.main()` 不匹配，根帧以 94.1 % 当上"热点第一名"、把真热点挤下榜（cert14probe 实测）。
  # 所以这里故意让根帧只占 83.3 %（低于 98 的兜底），只有**名字**这一道能挡住它。
  # 帧序照真件（leaf 在前、根在最后；本机实测最外两帧＝`static TcoderEntry.main()`／`start`）：
  # 抄反了根帧会同时冒充"叶子帧（自身耗时）"，臂就去抓一个真件里不存在的形状。
  cat > "$1" <<'XML'
<?xml version="1.0"?>
<trace-query-result>
<node xpath='//trace-toc[1]/run[1]/data[1]/table[9]'><schema name="time-profile"><col><mnemonic>time</mnemonic></col><col><mnemonic>thread</mnemonic></col></schema>
<row><sample-time id="1" fmt="00:00.100.000">100000000</sample-time><thread id="2" fmt="Main Thread (0x1) (TcoderMonitor, pid: 1)"><tid id="3" fmt="0x1">1</tid><process id="4" fmt="TcoderMonitor (1)"><pid id="5" fmt="1">1</pid></process></thread><thread-state id="6" fmt="Running">1</thread-state><weight id="7" fmt="1">1</weight><tagged-backtrace id="8" fmt="a"><backtrace id="9"><frame id="10" name="hotWork()" addr="0x1"/><frame id="11" name="specialized static TcoderEntry.main()" addr="0x2"/></backtrace></tagged-backtrace></row>
<row><sample-time id="12" fmt="00:00.200.000">200000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="13" fmt="b"><backtrace id="14"><frame ref="10"/><frame ref="11"/></backtrace></tagged-backtrace></row>
<row><sample-time id="15" fmt="00:00.300.000">300000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="16" fmt="c"><backtrace id="17"><frame ref="10"/><frame ref="11"/></backtrace></tagged-backtrace></row>
<row><sample-time id="18" fmt="00:00.400.000">400000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="19" fmt="d"><backtrace id="20"><frame ref="10"/><frame ref="11"/></backtrace></tagged-backtrace></row>
<row><sample-time id="21" fmt="00:00.500.000">500000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="22" fmt="e"><backtrace id="23"><frame id="24" name="otherWork()" addr="0x3"/><frame ref="11"/></backtrace></tagged-backtrace></row>
<row><sample-time id="25" fmt="00:00.600.000">600000000</sample-time><thread ref="2"/><process ref="4"/><thread-state ref="6"/><weight ref="7"/><tagged-backtrace id="26" fmt="f"><backtrace id="27"><frame ref="24"/></backtrace></tagged-backtrace></row>
</node></trace-query-result>
XML
}

selfcheck_threads_window_grill() {  # 75) threads 那把尺第一次有自己的臂：切片要印得对、零命中要说对原因（#96/#98）
  # 为什么这一项非有不可：`threads` 产出的 `time-profile.json` 是汇总表里
  # 「主线程 CPU 样本占比」与「热点第一名」两列的**唯一来源**，而此前全仓没有一条臂跑过它
  # （只有 `PerfRulerHotspotRatchetTests` 量它的尺寸/名单——那是读文件，不读行为）。
  # 于是本轮给它加 `--window` 时，两处旧话术一查就是假的：
  #   · 零命中 ⇒ 它说"确认导出的是 time-profile 表（而不是空的 time-profile）"，可表根本不空，是窗口选错；
  #   · `--thread` 认不到 ⇒ 它悄悄换成"样本最多的那条"照样出数（要 A 给 B）。
  local fx tp r_none r_bad r_fb out
    # 夹具落**本轮 outdir 之下**，不用 `mktemp -d`、更不用它的 `|| echo /tmp/固定名` 兜底（#113）：
  # 固定名在两棵树／两轮并发时会撞，而收尾那句 `rm -rf "$fx"` 会**删掉别人正在用的夹具**——
  # 同一枚病本仓付过学费：静默探针那把 `/tmp/tcoder-quiesce-$$` 撞上别人放的目录，
  # 症状是"探针时好时坏地报 -1.00"（`perf_probes.sh` 头注记着）。`cmd_selfcheck` 起跑已 `rm -rf` 整个 outdir
  # ⇒ 按轮天然隔离，也顺带满足 AGENTS §1.6「一次性产物不进 $TMPDIR」。全仓其余夹具都是这个形状。
  fx="$1/threads-window-fx"; rm -rf "$fx"; mkdir -p "$fx" \
    || { fail "建不出本轮夹具目录（$fx）——这一项等于没跑，别把没跑当通过"; return; }
  tp="$fx/tp.xml"
  threads_window_fixture "$tp"
  python3 scripts/trace_report.py threads "$tp" --top 1 --leaf 1 --pairs 1 >"$fx/full.txt" 2>&1
  python3 scripts/trace_report.py threads "$tp" --window 100-200 --top 1 --leaf 1 --pairs 1 >"$fx/win.txt" 2>&1
  python3 scripts/trace_report.py threads "$tp" --window 9000-9999 >"$fx/none.txt" 2>&1; r_none=$?
  python3 scripts/trace_report.py threads "$tp" --window 300-200 >"$fx/bad.txt" 2>&1; r_bad=$?
  python3 scripts/trace_report.py threads "$tp" --thread NoSuchThread >"$fx/fb.txt" 2>&1; r_fb=$?
  out="ok"
  grep -qF "窗口：全窗" "$fx/full.txt" || out="$out 全窗没标自己是全窗（印与比不同源）"
  grep -qF "       4  Main Thread" "$fx/full.txt" || out="$out 全窗主线程样本数不是 4（拿到 $(grep -c Main "$fx/full.txt" | tr -d ' ') 行含 Main)"
  grep -qF "窗口：100.0~200.0 ms" "$fx/win.txt" || out="$out 窗口标题没印出区间"
  grep -qF "       2  Main Thread" "$fx/win.txt" || out="$out 窗口没把 300/400 ms 那两枚筛掉（切片没生效）"
  [ "$r_none" = "1" ] || out="$out 窗口零命中=$r_none（要 1）"
  grep -qF "窗口选错" "$fx/none.txt" || out="$out 零命中没说出真正的原因（窗口选错）"
  if grep -qF "而不是空的 time-profile" "$fx/none.txt"; then
    out="$out 零命中还在用旧那句『确认导出的是 time-profile 表』⇒ 对着一份不空的表说它可能空"
  fi
  [ "$r_bad" != "0" ] || out="$out 反向窗口 300-200 被放行 ⇒ 那是一段恒空窗口，比假绿更坏"
  grep -qF "恒空窗口" "$fx/bad.txt" || out="$out 反向窗口没解释为什么拒"
  [ "$r_fb" = "0" ] || out="$out 认不到线程名时不该改变退出码（回退是有意的，但必须出声）"
  grep -qF "不是**你要的那个执行体的" "$fx/fb.txt" || out="$out 悄悄换了执行体（要 A 线程给了 B 线程的数）"
  rm -rf "$fx"
  [ "$out" = "ok" ] || { fail "threads 的窗口切片不成立：$out"; return; }
  ok "threads 尺五格有牙：全窗自称全窗、窗口筛得对、零命中说「窗口选错」而不是「表是空的」、" \
     "反向区间直接拒、认不到执行体要出声（75）"
}

selfcheck_threads_root_frame() {  # 81) 入口根帧不许顶掉「热点第一名」（#118：底盘名单被自家一次改名废掉）
  # 为什么单开一项而不塞进第 75 项：那一项目的就是**窗口切片**，而这一格量的是**底盘识别**；
  # 混在一项里除了让那个函数撞复杂度尺（CC 16 就是本轮门禁实测的红），还会让"哪一格坏了"说不清。
  local fx h1 out
  fx="$1/threads-root-fx"; rm -rf "$fx"; mkdir -p "$fx" \
    || { fail "建不出本轮夹具目录（$fx）——这一项等于没跑，别把没跑当通过"; return; }
  root_plumbing_fixture "$fx/root.xml"
  python3 scripts/trace_report.py threads "$fx/root.xml" --top 3 --json "$fx/root.json" >"$fx/root.txt" 2>&1
  out="ok"
  # 查**落盘那格**而不是印出来的字：披露行本来就点名"被剥掉的是谁"，对整份 stdout grep 会红在那句上。
  h1=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hotspot_top1"])' "$fx/root.json" 2>/dev/null)
  [ "$h1" = "hotWork()" ] || out="$out 热点第一名=$h1（要 hotWork()；是入口根帧就是 RUNLOOP_PLUMBING 的结构形状那格被拿掉了）"
  grep -qF "事件循环本体占 83.3%" "$fx/root.txt" || out="$out 剥掉根帧却没印它占多少（剥了要出声，不许静默改榜）"
  rm -rf "$fx"
  [ "$out" = "ok" ] || { fail "threads 的底盘识别不成立：$out"; return; }
  ok "threads 的入口根帧不顶热点第一名：夹具故意只做 83.3 %（低于 98 的比例兜底），" \
     "⇒ 只有**名字**这一道能挡；剥掉之后还要出声（81）"
}
