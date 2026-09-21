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

