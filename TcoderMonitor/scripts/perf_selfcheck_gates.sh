#!/bin/bash
# perf_selfcheck_gates.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 14/15/16/17/18/19：**前置与闸门**（二进制归对对象、对照列文字派生、并发重活认 pid、七维闸门矩阵、
#     九页页名逐条、首帧剔除运行期尾巴）
#
# 为什么搬出来：本仓 ≤800 行棘轮的分母含 `.sh` 且 ceiling=0（`SelfScanDogfoodTests`），宿主 2026-09-21 涨到 835 行把门禁判红过一次——拆开它才是修复，拧阈值不是
# 判据、断言与 ok/fail 文案**逐字未动**；项与项之间只共享宿主的 fails / checked
# 两个计数器（bash 动态作用域）。拆前拆后各跑一次 `./scripts/perf_harness.sh selfcheck`，
# 31 项输出逐字 diff 过才算这刀没切坏。
# =============================================================================
selfcheck_py_rulers_compile() {  # selfcheck_py_rulers_compile <outdir>
  # 36) 每一支 `.py` 尺子都必须能被**编译器**读懂。
  #     为什么单列一条：09-22 一晚第 6 次踩同一个坑——中文文案里出现 ASCII 双引号，
  #     Swift 侧截断过、bash 侧静默丢内容过、这次轮到 python：
  #     `perf_cadence.py` 写完看着没错，跑起来才 `SyntaxError: invalid syntax`
  #     （`"…不许拿"没判"当"过了""` 被切成三段）。这类错**根本不该靠人记得**，
  #     编译器免费判，那就每次让它判。
  #     用内建 `compile()` 而不是 `py_compile`：后者会往 scripts/ 里写 `__pycache__`
  #     ——为跑守卫而在被扫目录里造文件，等于自己污染自己的分母（本仓为这类形状记过好几次）。
  local res
  res=$(python3 -c '
import glob, sys
bad = []
for f in sorted(glob.glob("scripts/*.py")):
    try:
        compile(open(f, encoding="utf-8").read(), f, "exec")
    except SyntaxError as e:
        bad.append("%s:%s" % (f.split("/")[-1], e.lineno))
print("%d|%d|%s" % (len(glob.glob("scripts/*.py")), len(bad), ",".join(bad)))')
  local files broke
  files=${res%%|*}; res=${res#*|}; broke=${res%%|*}
  [ "$broke" = "0" ] || { fail ".py 尺子编不过：${res#*|}（$broke/$files 支）"; return; }
  [ "$files" -ge 1 ] || { fail "一支 .py 尺子都没扫到——glob 或工作目录错了，这条等于没扫"; return; }
  # 反向钉：坏形状必须被抓到，否则上面那条判据是摆设。
  mkdir -p "$out/pyfix"
  printf '%s\n' 'x = "中文里"夹了"ASCII 引号"' > "$out/pyfix/broken.py"
  local caught
  caught=$(python3 -c '
import sys
try:
    compile(open(sys.argv[1], encoding="utf-8").read(), sys.argv[1], "exec")
    print("clean")
except SyntaxError:
    print("caught")' "$out/pyfix/broken.py")
  [ "$caught" = "caught" ] \
    || { fail "反向失败：夹了 ASCII 引号的 .py 没被抓到（拿到 ${caught:-解析失败}）⇒ 上面那条是摆设"; return; }
  rm -rf "$out/pyfix"
  ok "$files 支 .py 尺子全部能被 compile() 读懂（含一句故意写坏的反例，确实会炸）"
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
  # 【同一件事只许有一把手尺子】这三条结构钉拆到 `provenance_single_ruler_cases`：
  # 本仓 50 行线（`PerfRulerHotspotRatchetTests`）——拆函数才是修复，抬数字不是。
  provenance_single_ruler_cases
  # tree 放行这一支必须单独钉：它是"假拒"的唯一解药，也是最容易被写歪的一支
  #（写歪的方向是"永远认为相同"或"永远认为不同"，两边都不报错）。
  local T1=1111111111111111111111111111111111111111111111111111111111111111
  local T2=2222222222222222222222222222222222222222222222222222222222222222
  # 用**调用方的形状**验：真实调用一律 `WHY=$(provenance_ok …)`，所以留痕必须在 stdout 里——
  # 对变量的赋值出不了子 shell，上一版就是这样把"必须留痕"变成一句空话的。
  local treenote
  if treenote=$(provenance_ok "$B" "$H" true "$T1" "$T1"); then
    [ -n "$treenote" ] \
      || { fail "靠 tree 放行了却没把理由写到 stdout —— 悄悄放行比拒错更糟"; bad=1; }
  else
    fail "rev 不同但产物码 tree 相同却仍被拒（落地后同步头会被假拒，实测踩过一次）"; bad=1
  fi
  if provenance_ok "$B" "$H" true "$T1" "$T2"; then
    fail "产物码 tree 不同却放行 —— 那就是把身份判据废了"; bad=1
  fi
  if provenance_ok "$B" "$H" true "" "$T1"; then
    fail "缺 tree 信息还走 tree 放行（老 manifest 必须退回严格比 sha）"; bad=1
  fi
  [ "$bad" = "0" ] && ok "二进制出身判定双向都对（sha 相同 / tree 相同可放行且留痕 / 逐维破坏各判拒）"
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
  # 清单被削回只认 swiftc 的话，本仓全量门禁期间就会假装机器空着——钉住四个名字。
  # `xctrace` 是 2026-09-21 补的：另一个工程同时在录 Animation Hitches，
  # 而这一维当时读成"机器空"。两档 xctrace 互踩，量出来的两边都不准。
  local n missing=""
  for n in swiftc swift-frontend swift-test swiftTestDriver xctest xctrace; do
    grep -q "\b$n\b" <(declare -f heavy_job_names) || missing="$missing $n"
  done
  # xctrace 那一维必须认"真在采"，不能认"在场"：机器上此刻就挂着一个别的工程
  # 21 小时前留下的停着的 xctrace（%cpu=0），按在场即拒会让这条闸门永远不可满足。
  # 两个方向都用**合成进程**钉：空转一个烧 CPU 的 bash、一个睡觉的 bash，
  # 名字都由调用方指给函数看 —— 验的是分支逻辑，不依赖现场有没有真 xctrace。
  local busy idle liveness=1
  bash -c 'while :; do :; done' & busy=$!
  sleep 1 & idle=$!
  heavy_job_is_live "$busy" xctrace || liveness=0     # 在吃 CPU ⇒ 必须算重活
  heavy_job_is_live "$idle" xctrace && liveness=0     # 停着 ⇒ 不许算重活
  heavy_job_is_live "$idle" swiftc || liveness=0      # 编译类不看增量，在场即重活
  kill -TERM "$busy" "$idle" 2>/dev/null
  [ "$liveness" = "1" ] \
    || fail "xctrace 活性判定不对（烧 CPU 的没算重活 / 停着的算了重活 / 编译类看了增量）"
  # 话术不许再硬编码名单：那正是"加了 xctrace 却把它说成本仓编译"的来源
  declare -f concurrent_heavy_jobs_detail >/dev/null \
    && grep -q 'concurrent_heavy_jobs_detail' <(declare -f preflight_context) \
    || missing="$missing 话术未走带名字的明细版"
  [ -z "$missing" ] \
    && ok "探针覆盖 6 类重活（含编译工人 swift-frontend），话术带真名字" \
    || fail "探针不再认识这些重活：${missing# }——全量门禁在跑时会被读成机器空"
}

selfcheck_gate_matrix() {  # selfcheck_gate_matrix <outdir>
  # 17) 七维闸门合成矩阵：喂一份"全合格"的假上下文，要求
  #     ① 全合格 ⇒ 放行；② 每一维单独破坏 ⇒ 拒。
  #     为什么必须有：前五维各自都修过一次 bug，但没有一个测试证明"闸门既能放行也会拒"。
  #     恒拒（前台名比错）与恒放行（探针函数不在场）都不报错，只能靠这张矩阵抓。
  if ! declare -f preflight_gates >/dev/null; then
    fail "preflight_gates 不在作用域里——这张矩阵没跑"
    return
  fi
  local head_sha hard_all=0
  head_sha=$(git rev-parse HEAD 2>/dev/null)
  # 一份"全合格"的上下文（各维取数都是本文件的 local，动态作用域里直接覆盖）
  gate_feed() {
    others=""; BUILD_REV="$head_sha"; BUILD_CLEAN="true"; front="Tcoder"
    visible="有在屏窗口（Tcoder）"; load1=3; cores=15; quiet=30; qline="静默=30s"
    other_detail=""
    COEXIST=1; SECONDS_HITCHES=20; SECONDS_TP=25; i18n_ledger=""
    BUILD_TREE=""; HEAD_TREE=""; hard=0; free_gib=400
  }
  gate_feed; preflight_gates >/dev/null 2>&1
  [ "$hard" = "0" ] || { fail "六维全合格却被拒 ⇒ 又造出一条永远不可能通过的闸门"; hard_all=1; }
  gate_feed; others="1234";   preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "有并发重活却放行"; hard_all=1; }
  gate_feed; BUILD_REV=$(printf 'f%.0s' $(seq 1 40)); preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "产物 rev 与代码不符却放行（归错对象那一族的入口）"; hard_all=1; }
  gate_feed; BUILD_CLEAN="false"; preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "构建时工作树是脏的却放行"; hard_all=1; }
  gate_feed; front="Finder";  preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "前台不是被测 App 却放行"; hard_all=1; }
  gate_feed; load1=99;        preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "load1 超阈值却放行"; hard_all=1; }
  gate_feed; i18n_ledger="/tmp/x.log"; preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "设着漏翻台账还放行——那批量的是台账的开销"; hard_all=1; }
  gate_feed; free_gib=3;    preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "盘只剩 3 GiB 还放行——盘满时 trace 写不进去，样本会静默变形"; hard_all=1; }
  gate_feed; free_gib="";   preflight_gates >/dev/null 2>&1
  [ "$hard" = "1" ] || { fail "磁盘可用取不到（空值）却放行——取不到必须按不合格处理"; hard_all=1; }
  [ "$hard_all" = "0" ] && ok "七维闸门矩阵：全合格放行、逐维破坏各判一次拒（含空值判败）"
}

selfcheck_page_list_shape() {  # selfcheck_page_list_shape <outdir>
  # 18) 九页的页名必须**逐条完整**：`Git 洞察` 这种带空格的页名是这条的活靶子。
  #     旧实现按空格拆（`tr ' ' '\n'`），把九页拆成 10 项、少一页，而扫描一路"成功"跑完。
  local n line
  n=$(sections 2>/dev/null | wc -l | tr -d ' ')
  [ "$n" = "9" ] || { fail "SECTIONS 解析出 $n 条页名（应为 9）——逐页扫描会漏页或重页"; return; }
  line=$(sections 2>/dev/null | tr '\n' '|')
  case "$line" in
    *Git\ 洞察*) ok "九页页名完整（含带空格的「Git 洞察」）" ;;
    *) fail "页名里没有完整的「Git 洞察」（拿到 $line）——空格又被当成分隔符了" ;;
  esac
}

selfcheck_launch_ready() {  # selfcheck_launch_ready <outdir>
  # 19) "启动到就绪"必须剔除"活到窗口结束"的运行期尾巴。
  #     旧写法直接求和 ⇒ 每页都算成 ≈录制时长（实测总览页 10338 ms / 真值 837 ms），
  #     T4（冷启动 ≤1.0 s）于是**永远不可能达标**——一条不可能达标的判据比没有更坏。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_metrics import launch_ready_ms
# 真产物形状：一堆小段 + 一段很长的运行期尾巴
with_tail = [(0.0, 377.7), (377.7, 5.7), (383.4, 192.3), (837.4, 9550.2)]
no_tail = [(0.0, 300.0), (300.0, 200.0), (500.0, 120.0)]
a = launch_ready_ms(with_tail); b = launch_ready_ms(no_tail); c = launch_ready_ms([])
d = launch_ready_ms([(0.0, 0.0), (5.0, 40.0)])
print("%s|%s|%s|%s" % (a, b, c, d))')
  case "$r" in
    837.4|837.40|837.4*) ;;
    *) fail "有尾巴的表没取到尾巴起点（拿到 $r，期望就绪点 837.4 ms）——又在拿求和冒充首帧"; return ;;
  esac
  echo "$r" | grep -q "|620" || { fail "没有尾巴的表应当取末端 620 ms（拿到 $r）"; return; }
  echo "$r" | grep -q "|None" || { fail "空表必须返回 None（按未覆盖处理，不许算 0 ms 达标）"; return; }
  ok "launch_ready_ms 三向都对（剔尾巴 / 无尾巴取末端 / 空表为 None）"
}

provenance_single_ruler_cases() {  # 【同一件事只许有一把手尺子】结构钉，由 selfcheck_binary_provenance 调用
  # 我补 provenance 这一维时先是**又写了一份**，才发现 `verify_provenance.sh` 早就在做同一件事。
  # 现在判定住在 `perf_provenance.sh`，两边都 source 它。下面三条把这个结构钉住：
  # 定义处唯一、交付档确实走它、测量档不许留本地副本
  # （漏一天就会分叉，而分叉之后错的那份常在喂结论）。
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
}


selfcheck_launcher_hygiene() {  # selfcheck_launcher_hygiene <outdir>
  # 29) 会 `open` 起 App 实例的 perf_ 脚本必须同时做到两件事：
  #     ① 有 trap 收尾 —— 脚本被中断而没收尾，就会留下一个 ppid=1 的实例，
  #        而"实例数恰为 1"那道闸会被它一路押死（2026-09-22 实测：主树因此漏下 6 个，
  #        所有人的帧率测量从夜里拒到上午）；
  #     ② 收尾只针对自己起的那个 pid，**不许按 bundle id 广播退出**（AGENTS -1.3；
  #        多实例在场时"退掉一个"根本不含"退掉我起的那个"）。
  # 范围只扫 `scripts/perf_*`：并行多流时各家只守自己名下目录，别家的红由别家自己修
  # （§K 已把主树那两个 offender 连同证据报出去了，那才是正确的动作）。
  #
  # 合法形状有**两种**，别把第二种当成漏网（也别拿第二种给第一种开脱）：
  #   ① `open "$APP/…"` 起实例 ⇒ 必须自己 trap 收尾（本循环判的就是这一种）；
  #   ② `xctrace record --launch -- "$PERF_BIN"` 起实例 ⇒ 那个进程是 **xctrace 收养的子进程**，
  #      按 xctrace 的语义随录制结束而死，所以 `perf_switch.sh` 里一个 `open` 都没有，
  #      也就不需要 trap。**这一条我只验到"形状不同"，没验到"确实不泄漏"**：
  #      哪天发现杀 xctrace（含被 -9）之后被测进程还活着，这条就要改成 ① 并补 trap，
  #      不许拿"它是 ②"当长期豁免的借口。
  #      判据仍然成立：谁改用 ① 的形状，这张表当场就把他列出来（第 31 项钉着表有牙）。
  #
  # 【形状由 `perf_launcher_audit.sh` 现扫给出，本项**只判定**】
  # 原来这里自己写了两条 grep（找 `open "$…APP"` 与 `application id`），于是被自己的
  # 说明文字绊倒过一次（第 29 项夹具里的字面量命中同一条 grep，本仓记过这个族），
  # 今天又被**第 31 项的夹具**绊倒一次：我在夹具里写了一句 `open "$APP"` 来讲那个形状，
  # 这条守卫就把 `perf_selfcheck_gates.sh` 判成"会按 bundle id 广播退出"。
  # ⇒ 同一个问题上不许有两把尺子：取数归表，阈值归这里（与 QUIESCE_MIN 那条分工同一个道理）。
  local rep name need killc trapc bcast sites bad=0 seen=0
  # --tsv：制表符事实行（同一把尺，两种视图）。以前这里读的是**给人看的那张表**，
  # 用 `Y[[:space:]]+无` 当"没 trap"——09-23 把 kill / trap 拆成两列之后，同一个正则
  # 会读成"没有 kill"而把 `kill=有 / trap=无` 那种形状**静默放过**。
  # 靠排版对齐的下游解析一律不许再写；改读事实行，列序变了会当场报错而不是变绿。
  rep=$(bash scripts/perf_launcher_audit.sh --tsv 2>&1) \
    || { fail "perf_launcher_audit.sh 跑不动，或一个 App 句柄都没解析出来 ⇒ 本项没有依据可判（不许当通过）"; return; }
  while IFS=$'\t' read -r name need killc trapc bcast sites; do
    case "$name" in perf_*.sh) ;; *) continue ;; esac
    seen=$((seen + 1))
    # 该收尾 = 起实例 且（没有会默认跑的 kill 或 异常路径不 trap）；广播退另算一条
    if [ "$need" = "Y" ] && { [ "$killc" != "有" ] || [ "$trapc" = "无" ]; }; then
      fail "$name 起实例但没收干净（kill=$killc trap=$trapc）⇒ 中断或默认路径就漏 ppid=1 的孤儿"
      bad=1
    fi
    [ "$bcast" = "否" ] \
      || { fail "$name 按 bundle id 广播退出 ⇒ 只许 TERM 自己起的那个 pid"; bad=1; }
  done <<EOF
$rep
EOF
  # 分母：表里一条 perf_* 都没有 ⇒ 说明扫描面退化了，本项等于没判（不许静默绿）
  [ "$seen" -gt 0 ] \
    || { fail "实例清单里一个 perf_* 都没有：要么形状改了、要么目录错了 ⇒ 本项不作数"; return; }
  # 表有牙由第 31 项（三夹具双向）负责，这里不再自带一份夹具——两份夹具会同源失效
  [ "$bad" = "0" ] \
    && ok "perf_* 名下起实例的形状都有「默认就会跑的 kill」+「trap」，且不按 bundle id 广播（形状取自审计表 --tsv）"
}

selfcheck_synth_launch_pairing() {  # selfcheck_synth_launch_pairing <outdir>
  # 32) "谁起实例 / 谁投滚动 / 什么时候投"三件事必须配套。
  # 09-22 排演（.scratch/rehearse_synth_pairing.sh）实测出来的两种坏形状，都不是推想：
  #  ① 排程器与录制档**各起一个**实例 ⇒ `pgrep -x` 数到 2 个 ⇒ `require_idle_target` 必拒，
  #     而这一条会让自动重试连撞满上限（每一个稀缺窗口都白烧在同一个确定性拒绝上）；
  #  ② 排程器朝**自己那个**实例投滚动，录制档却 attach 另一个 ⇒ "量的是没在被滚的那个"，
  #     出一份看起来完全正常的假配对（比红更难发现，因为它不报错）。
  # 所以钉三件：排程器里每处 `open "$START_BIN"` 都要在 `HARNESS_LAUNCHES` 的 else 分支里；
  # 录制档里编译（arm）在闸门之前、投递（start）在闸门之后；而且**倒过来必须被抓住**。
  local w=scripts/perf_wait_window.sh h=scripts/perf_harness.sh bad=0 line
  while IFS=: read -r line _; do
    [ -n "$line" ] || continue
    sed -n "$((line > 8 ? line - 8 : 1)),${line}p" "$w" | grep -q 'HARNESS_LAUNCHES' \
      || { fail "$w:$line 起实例却没被『录制档自己起』那条分支挡住 ⇒ 两边各起一个 = 多实例拒跑"; bad=1; }
  done < <(grep -n '^[[:space:]]*open "\$START_BIN"' "$w")
  pairing_order_violations "$h" \
    || { fail "$h 里 arm/start/preflight 的顺序不成立（见上面那行）"; bad=1; }
  # 反向：坏顺序（**投递排在闸门之前**）必须被同一条判据抓住，否则上面那条是永真绿。
  local fx="$out/pairing-reversed.sh"
  printf '%s\n' '  arm_synth_input' '  start_synth_input' '  preflight_context "$out" "$PID"' > "$fx"
  pairing_order_violations "$fx" >/dev/null \
    && { fail "反向失败：把投递挪到闸门**之前**的夹具没被抓到，这条守卫等于没扫"; rm -f "$fx"; return; }
  rm -f "$fx"
  # 每个动作只许有一个调用点：多一处就有一条绕开这张表的旁路。
  [ "$(grep -cE '^[[:space:]]*start_synth_input([[:space:]]|$)' "$h")" = "1" ] \
    || { fail "$h 里 \`start_synth_input\` 的调用点不是恰好一处"; bad=1; }
  [ "$bad" = "0" ] && ok "起实例/投滚动/开录时机三者配套（含把投递排到闸门前的反例也抓得住）"
}

# 判"编译在闸门之前、投递在闸门之后"。违规时打印是哪一对，返回 1。
pairing_order_violations() {  # pairing_order_violations <file>
  local f="$1" a p s
  a=$(grep -nE '^[[:space:]]*arm_synth_input([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)
  p=$(grep -nE '^[[:space:]]*preflight_context ' "$f" | head -1 | cut -d: -f1)
  s=$(grep -nE '^[[:space:]]*start_synth_input([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$p" ] && [ -n "$s" ] \
    || { echo "  三个动作没找齐（arm=${a:-?} preflight=${p:-?} start=${s:-?}）—— 换了名字要一起改这条判据"; return 1; }
  { [ "$a" -lt "$p" ] && [ "$p" -lt "$s" ]; } && return 0
  echo "  顺序不成立：arm=$a preflight=$p start=$s（要求 arm < preflight < start）"
  return 1
}

selfcheck_launcher_inventory() {  # selfcheck_launcher_inventory <outdir>
  # 31) `perf_launcher_audit.sh` 这张表**必须能分辨三种形状**：
  #     真起 App 的（要判）/ 起了但会收尾的（不判）/ 只在注释与 echo 里"讲起 App"的（不进表）。
  #     为什么专门钉：前两版正是死在后两类上 —— v1 把讲代码的话判成 offender、
  #     v2 把 `pgrep "$MY_BIN"` 判成起 App，而 v2 的过窄模式（`\{?` 撞上 BSD 的区间语法）
  #     还把今天真漏 8 个孤儿的 `ax_tooltip_report.sh` **整行漏掉**。
  #     ⇒ 一张会漏真凶、又乱点名的表比没有表更坏，所以三个夹具一次跑齐（缺一个就是废守卫）。
  local d="$out/launch-inv" rep guilty clean prose
  mkdir -p "$d/scripts"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    'x=1' '  "$BIN" -ApplePersistenceIgnoreState YES &' > "$d/scripts/guilty.sh"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    'trap "kill -TERM $pid" EXIT INT TERM' '  "$BIN" -ApplePersistenceIgnoreState YES &' > "$d/scripts/clean.sh"
  printf '%s\n' '# 这里讲的是起 App 的形状："$BIN" 与 open "$APP"' \
    'echo "别学它：$BIN 这样起会漏实例"' > "$d/scripts/prose.sh"
  # 不 cd：`--dir` 给绝对路径，工具内部一律按它拼，省得依赖 "$OLDPWD" 这种"恰好对"的东西
  rep=$(bash scripts/perf_launcher_audit.sh --dir="$d/scripts" 2>&1)
  # 分母：工具在"一个句柄都没解析出来"时自己退 1 ⇒ rc 非 0 时下面三条都不作数
  guilty=$(printf '%s' "$rep" | grep -c '^guilty.sh  *Y')
  clean=$(printf '%s' "$rep" | grep -c '^clean.sh')
  prose=$(printf '%s' "$rep" | grep -cE '^(prose.sh|.*一个都没认出|!! 一个")')
  [ "$guilty" = "1" ] \
    || { fail "坏夹具 guilty.sh 没被判成『Y 命令位起 App』（读到 $guilty）⇒ 这张表认不出真凶：$rep"; return; }
  [ "$clean" = "1" ] || fail "有 trap 的 clean.sh 根本没进表（读到 $clean）⇒ 表漏行， offender 数不可信"
  printf '%s' "$rep" | grep -qE '^clean.sh.*Y.*有' \
    || fail "clean.sh 进了表但 trap 没读到『有』⇒ 宽松方向失效"
  [ "$prose" = "0" ] || fail "讲代码的话（prose.sh）被当成会起实例的脚本 ⇒ 假黑，表会失去信誉：$rep"
  ok "实例清单分得清『真起 / 会收尾 / 只是讲』（三夹具双向都验，含漏真凶的反例）"
}

selfcheck_cleanup_opt_in_state() {  # selfcheck_cleanup_opt_in_state <outdir>
  # 37) 实例清单的「kill」那一格必须分得清**三种**收尾形状：无条件 / 躲在默认关掉的开关后面 / 没有。
  #     为什么单独一条：09-23 凌晨那一串孤儿就是这么来的 —— `capture_pages_isolated.sh`
  #     有 trap、也真写了一句 `kill -TERM`，旧表只看"有没有 trap"就判它干净，
  #     而那句 kill 躲在 `CAPTURE_TERM=1` 后面（默认只印"待人工退出"），它在 for 里每页起一个
  #     ⇒ 跑一轮九页漏九个，把所有人"实例数恰为 1"那道闸压死。
  #     反向钉同样要紧：`if [ "$who" = "$BIN" ]` 是**核身份**的门，是好形状，
  #     拿"缩进在 if 里"当判据就会把每一处谨慎收尾都点名 —— 那张表立刻失去信誉。
  local d="$out/cleanup-state" rep tsv off optin guarded nokill seen
  mkdir -p "$d/scripts"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    "trap 'rm -rf /tmp/lockdir' EXIT INT TERM" 'for name in a b c; do' \
    '  env TCODER_SUPPORT_DIR=/tmp "$BIN" -ApplePersistenceIgnoreState YES &' \
    '  pid=$!' '  if [ "${MINE_TERM:-0}" = "1" ] && [ "$pid" -gt 0 ]; then' \
    '    kill -TERM "$pid" 2>/dev/null || true' '  fi' 'done' > "$d/scripts/optin.sh"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    'trap retire EXIT INT TERM' '  "$BIN" -ApplePersistenceIgnoreState YES &' 'pid=$!' \
    'retire() { who=$(ps -p "$pid" -o comm=); if [ "$who" = "TcoderMonitor" ]; then' \
    '  kill -TERM "$pid" 2>/dev/null || true' 'fi' '}' > "$d/scripts/guarded.sh"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    '  "$BIN" -ApplePersistenceIgnoreState YES &' > "$d/scripts/nokill.sh"
  rep=$(bash scripts/perf_launcher_audit.sh --dir="$d/scripts" 2>&1)
  tsv=$(bash scripts/perf_launcher_audit.sh --dir="$d/scripts" --tsv 2>&1)
  # 分母：一句启动形状都没认出来时，下面三条全是空对空（工具自己会退 1，但别拿"退 1"当判据）
  printf '%s\n' "$tsv" | grep -q . \
    || { fail "夹具没被认出任何启动形状 ⇒ 这一项等于没扫：$rep"; return; }
  # 四条各判一次，**任何一条不中就不许印 ✓**（第一版就是 fail 之后照样走到 ok，
  # 于是一次跑同时留下「✗ offender 数…」和「✓ 收尾形状分得清…」——那是永真绿的亲戚）。
  local bad=0
  optin=$(printf '%s\n' "$tsv" | grep -c $'^optin\.sh\tY\t选装\t有')
  guarded=$(printf '%s\n' "$tsv" | grep -c $'^guarded\.sh\tY\t有\t')
  nokill=$(printf '%s\n' "$tsv" | grep -c $'^nokill\.sh\tY\t无\t无')
  [ "$optin" = "1" ] \
    || { fail "「kill 只在开关后面」的夹具判成别的（读到 $optin）⇒ 09-23 那个形状又看不见了"; bad=1; }
  [ "$guarded" = "1" ] \
    || { fail "核身份的门被误判成「选装」（读到 $guarded）⇒ 表会乱点名，下次没人信它"; bad=1; }
  [ "$nokill" = "1" ] \
    || { fail "一句 kill 都没有的夹具判成别的（读到 $nokill）"; bad=1; }
  seen=$(printf '%s\n' "$tsv" | sed -n 's/^#facts.*opt_in=\([0-9]*\).*/\1/p')
  [ "$seen" = "1" ] \
    || { fail "事实行里的「选装」计数读到 '$seen'（应为 1）⇒ 那一格没被数进账"; bad=1; }
  off=$(printf '%s\n' "$tsv" | sed -n 's/^#facts.*offenders=\([0-9]*\).*/\1/p')
  [ "$off" = "2" ] \
    || { fail "offender 数读到 '$off'（应为 2：optin + nokill，guarded 不算）⇒ 判定式宽了或窄了"; bad=1; }
  [ "$bad" = "0" ] \
    && ok "收尾形状分得清『无条件 / 躲在开关后面 / 没有』，且核身份的门不算选装（三夹具双向）"
}
