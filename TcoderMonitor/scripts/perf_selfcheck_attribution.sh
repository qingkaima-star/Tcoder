#!/bin/bash
# perf_selfcheck_attribution.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 26 / 27 / 41：**"一个读数怎么被解释成结论"这一层**
#   （26 一个 max 不许同时盖住"整体很快"与"有长尾"、27 迟到帧该怪谁的八种形状、
#    41 FramePulse 的生命期累计不许冒充本窗口）。
#
# 为什么单独成第 11 块：宿主 `perf_selfcheck_eligibility.sh` 到 **388/400**，是 #39 那串里
#  gates 之后最紧的一根（同一族尺寸债第三次到期之后，这是第四次）。
# 按本仓口径「拆，不抬线」整段搬出——**判据、断言与 ok/fail 文案逐字未动**，
# 项与项之间只共享宿主的 `fails` / `checked` 两个计数器（bash 动态作用域）。
# 拆前拆后各跑一次 `./scripts/perf_harness.sh selfcheck`，把输出**归一天生会变的格子**
# （秒级读数 / pid / rev 目录名）之后逐字 diff；这道验收的做法与理由见
# `perf_selfcheck_context.sh` 头注（同一条，昨天刚写过一次）。
#
# ⚠ 本块不含任何"起实例"形状：`perf_launcher_audit.sh` 按物理行扫 `perf_*`，
#   第 29 项靠它，历史上这里因为一行散文被误判过两次。
selfcheck_app_update_split() {  # selfcheck_app_update_split <outdir>
  # 26) `app-update` 那行原来只报 max ⇒ "超 20.2 倍"。同一份数据里 p95 是 3.4 ms：
  #     整体很快 + 一次 168 ms 孤例，被一个数同时说反两次。
  #     现在拆成三种形状各钉一次：整体快 ⇒ 达标；少数孤例 ⇒ 「stall N 个」；
  #     整表贴着一帧（≥20% 行超预算）⇒ **不叫 stall**，只报数并说"单位待核"（09-23 改判）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import app_update_verdict as v
small = [0.5] * 600 + [3.0] * 40
outl = [1.0] * 600 + [168.3]
big = [12.0] * 30 + [30.0] * 10
print("A|%s" % v(small, 8.333)[1][:6])
print("B|%s" % v(outl, 8.333)[1][:14])
print("C|%s" % v(big, 8.333)[1][:14])
print("D|%s" % v(outl, 8.333)[0])')
  printf '%s\n' "$r" | grep -q '^A|达标（没有' \
    || { fail "全是小值时没判成「达标」：$(printf '%s' "$r" | tr '\n' ' ')"; return; }
  printf '%s\n' "$r" | grep -q '^B|主线程 stall 1 个' \
    || { fail "单个 168ms 孤例没被单独点出来（其余 600 个不该跟着背锅）"; return; }
  printf '%s\n' "$r" | grep -q '^C|40/40 行' \
    || { fail "整表超预算还被说成「40 个 stall」（拿到 $(printf '%s' "$r" | grep '^C|' | cut -c3-40)）"\
             "⇒ 上屏跟满 120 帧时这句话与实测矛盾"; return; }
  printf '%s\n' "$r" | grep -q '^B|主线程 stall' \
    || { fail "少数孤例也被一并降格成「不判」⇒ 该查的那个 168ms 没人查了"; return; }
  printf '%s\n' "$r" | grep -q 'p95 1.00' \
    || { fail "分布里没有 p95（拿到 $(printf '%s' "$r" | grep '^D|' | cut -c3-60)）"; return; }
  ok "app-update 判定分得清「整体快 + 一个孤例慢」与「普遍慢」"
}

selfcheck_phase_blame() {  # selfcheck_phase_blame <outdir>
  # 27) 42 个迟到帧里有 13 次 update 超预算 ⇒ 大多数迟到与主线程无关。
  #     这种"该去查谁"的判断必须有一条尺子替人做，否则下一个读表的人会直接去改 update 常数。
  # 第五种形状是 09-23 现场逼出来的：交互档样本 `n=2090 / 下限 9.31 ms` 对上 24 个迟到帧，
  #     旧尺子印出"比 7671%"并下一句"几乎一比一 ⇒ 先查主线程"。那是拿**按事件节拍计**的表
  #     定归因（与 §R 里我自纠的那次误读同一个错，只是换了一支函数）。
  #     ⇒ 窄分布必须**闭嘴指路**，而且这一条与 `caveat_for` 共用同一条数值判据
  #     （`interval_shaped`）——判据抄成第二份的那天，两支函数就会互相打脸。
  # 第六到第八种（09-24 #46）：归因行原来只吃两张表，于是它会把"update 相位没超"说成
  #     "主线程没被占住"——同一张表里 `potential-hangs` 明明印着 5 次 / 2725 ms。
  #     ⇒ 第三路输入必须有，且**第八种是反向的**：hangs 为空时旧话术要一字不动，
  #     否则这条新维度会变成"什么都判不成立"的永真绿。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_blame_caliber import phase_blame as p
a = p([1.0] * 10 + [9.0] * 42, [10.0] * 42, 8.333)[1]     # 一比一 + 宽分布 ⇒ 查主线程
b = p([1.0] * 600 + [168.3], [10.0] * 42, 8.333)[1]       # 只占极少数 ⇒ 分开修
c = p([1.0] * 100, [10.0] * 5, 8.333)[1]                  # 一次都没超 ⇒ 全在合成侧
d = p([1.0], [], 8.333)[1]                                # 无迟到帧 ⇒ 不给任何归因
e = p([9.31] * 2090, [8.33] * 24, 8.333)[1]               # 窄分布 ⇒ 不判，只指路
t = p([1.0] * 1000 + [9.0] * 50, [10.0] * 24, 8.333)      # 宽分布但超预算 2.1 倍 ⇒ 说"倍"且不判归因
H = [441.3, 887.2]                                        # 同一窗口主线程被占住两次的形状
g = p([1.0] * 100, [10.0] * 5, 8.333, H)                  # #46 正身：相位没超 + 有 hangs
h = p([1.0], [], 8.333, H)                                # 无迟到帧 + 有 hangs
i = p([1.0] * 600 + [168.3], [10.0] * 42, 8.333, [])[1]   # 反向：hangs 为空 ⇒ 旧话术一字不动
print("%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
    "先查主线程" in a, "分开修" in b, "全在渲染/合成侧" in c,
    d == "—", "不判" in e and "time-profile" in e,
    "倍" in t[0] and "7671" not in t[0] and t[1].startswith("不判"),
    "归因未定" in g[1] and "别改视图更新常数" not in g[1] and "887" in g[1],
    "不判" in h[1] and "887" in h[0],
    i == b and "阻塞" not in i))')
  [ "$r" = "True|True|True|True|True|True|True|True|True" ] \
    || { fail "迟到帧归因八种形状没各判对（拿到 $r）"; return; }
  ok "迟到帧归因分得清「查主线程 / 分开修 / 全在合成侧 / 无迟到 / 窄分布不判 / 比值悬殊不判 / 有 hangs 不许归给合成侧」"
}

selfcheck_pulse_window_scope() {  # selfcheck_pulse_window_scope <outdir>
  # 41) FramePulse 的摘要行**总数是生命期累计**，不许被当成"本窗口"的读数（09-23 抓到）。
  #     现场：报表一路写着"同窗 FramePulse"，而 `a5298d5-interact-run1` 那份是
  #     `帧数=26941 ≈ 225 s` 对 20 s 的录制窗口 —— 因为 `cmd_idle` 的顺序是
  #     "起实例 → 录 hitches → 录 time-profile → **最后**才读脉冲"。
  #     受影响的不只是措辞：§M 那个"回调比上屏晚约 0.7 ms"的偏移量就是这么算出来的，
  #     所以那条结论今天降级为**未定**，要重测（重测的前置见交接笔记 §AA）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_framepulse import stale_instance as st, verdict
def R(n, hz=120.0):
    return {"refresh_hz": hz, "expected_interval_ms": 1000.0 / hz, "frame_count": n,
            "frame_p50_ms": 8.33, "frame_p95_ms": 9.03, "frame_p99_ms": 9.2,
            "frame_max_ms": 25.0, "hitch_count": 0, "hitch_per_second": 0.0,
            "ticks_with_hitch": 0, "ticks_with_hitch_total": 13, "heartbeat_max_gap_ms": 27.0,
            "refresh_source": "fixture", "summaries": 1, "bad_ticks": []}
a = st(R(2450), 20.0)              # 20 s × 120 Hz ≈ 2400 帧 ⇒ 新鲜
b = st(R(26941), 20.0)             # 225 s 的累计 ⇒ 生命期
c = st(R(26941), 0.0)              # 没给窗口 ⇒ 无从判，也不许硬说它是本窗口
_, code = verdict(R(26941), interaction=True, window_seconds=20.0)
txt, code2 = verdict(R(2450), interaction=True, window_seconds=20.0)
print("%s|%s|%s|%s|%s" % (a, b, c, code, "生命期" in txt))')
  [ "$r" = "False|True|False|2|False" ] \
    || { fail "脉冲的『窗口 vs 生命期』四种形状没各判对（拿到 $r，应为 False|True|False|2|False）" \
             "⇒ 报表会把一份 225 s 的累计读数写成 20 s 窗口的 p95"; return; }
  ok "脉冲读数分得清「本窗口」与「生命期累计」：生命期一律不判窗口，交叉核对也随之停判"
}

# ===== 第 63 项：长 update → 调用栈归因（#43 / #73）=====
#
# 缺陷本体的形状：hitches 与 time-profile 历来是**两次独立录制**，两条时间轴各自都真，
# 把它们并起来 join 出来的栈却属于另一段时间——这类错比报错难发现，因为它看着像一张
# 正常的归因表。09-25 实测：同窗双仪器档才拿到 4153 行带栈样本，其中 985 个样本落在
# 同一个 1061 ms 的块上，第一名叶子帧 `_platform_memcmp` 266 次。
# ⇒ 这一项要钉的不是「能不能算出栈」，而是**四种不许算的情形**：
#   跨窗口 join、把区间外的栈算进来、把别家进程的 Main Thread 顶包、把"没采到"说成"没有"。
# 夹具全部由下面这段 python **造真文件**、再让**真 CLI** 去读（不在 bash 里复刻算法）：
# 判据与实现一旦分叉，红的是这一项，而不是两周后台账里那句话。
blame_attribution_probe() {  # blame_attribution_probe <outdir> → 八格 True/False 向量（空串 = 夹具自己崩了）
  cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 - "$1" <<'PYBLAME'
from perf_trace_xml import RUNLOOP_PLUMBING
import itertools, json, os, subprocess, sys
fx = os.path.join(sys.argv[1], "blame-fx")
NID = itertools.count(1)
WIN = [[2000.0, 1100.0], [2000.0, 1100.0], [7000.0, 50.0]]   # 3 行 = 2 个事件（同一 update 的双行）
HIT, FOREIGN, PLUMB, PID = "LongStringCompare", "ForeignThing", RUNLOOP_PLUMBING[0], "4242"
META = {"pid": PID, "period": "idle", "blame_instrument": "1"}
CLEAN = {"pid": PID, "period": "idle"}                        # 少一枚 blame_instrument ⇒ 跨窗口档
def row(t_ms, func, pid):
    """一个主线程样本行。func 为空串 = 这一刻**没采到栈**（≠ 没在干活，见尺子头注第 2 条）。"""
    a, b, c, d, e, g = [next(NID) for _ in range(6)]
    return ('<row><sample-time id="%d" fmt="t">%d</sample-time>'
            '<thread id="%d" fmt="Main Thread (0x1) (Tcoder, pid: %s)"><tid id="%d" fmt="0x1">1</tid>'
            '<process id="%d" fmt="Tcoder (%s)"><pid id="%d" fmt="%s">%s</pid></process></thread>'
            + (func and ('<tagged-backtrace id="%d" fmt="x"><backtrace id="%d">'
                         '<frame id="%d" name="%s"/></backtrace></tagged-backtrace>' % (g, g, g, func))
               or "") + '</row>') % (a, int(t_ms * 1000000), b, pid, c, d, pid, e, pid, pid)
def write_run(name, samples, meta):
    d = os.path.join(fx, name)
    os.makedirs(d, exist_ok=True)
    [open(os.path.join(d, f), "w").write(t) for f, t in (
        ("blame-time-profile.xml", "<table>%s</table>" % "".join(row(*s) for s in samples)),
        ("hitches-updates.json", json.dumps({"pairs": WIN})), ("meta.json", json.dumps(meta)))]
    return d
def probe(d):
    p = subprocess.run([sys.executable, "perf_update_stacks.py", d],
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    return p.returncode, p.stdout
D = {n: write_run(n, s, m) for n, s, m in (
    ("hit", [(2500.0, HIT, PID)], META), ("outside", [(9000.0, HIT, PID)], META),
    ("foreign", [(9000.0, HIT, PID), (2500.0, FOREIGN, "9999")], META),
    ("nostack", [(2500.0, "", PID)], META), ("plumbing", [(2500.0, PLUMB, PID)], META),
    ("crosswindow", [(2500.0, HIT, PID)], CLEAN), ("notable", [(2500.0, HIT, PID)], META))}
os.remove(os.path.join(D["notable"], "blame-time-profile.xml"))   # 有标记没表 = 采集坏了
R = {n: probe(d) for n, d in D.items()}
print("|".join(str(x) for x in [
    R["hit"][0] == 0 and HIT in R["hit"][1],
    "表 3 行 → 去重成 2 个事件" in R["hit"][1] and R["hit"][1].count("1100.0 ms") == 1,
    HIT not in R["outside"][1] and "取不到" in R["outside"][1],
    FOREIGN not in R["foreign"][1] and "跳过别的进程 1 行" in R["foreign"][1],
    "无栈 1" in R["nostack"][1],
    "管道帧 1" in R["plumbing"][1] and PLUMB not in R["plumbing"][1],
    R["crosswindow"][0] != 0 and "拒绝归因" in R["crosswindow"][1],
    R["notable"][0] != 0 and "采集坏了" in R["notable"][1]]))
PYBLAME
}

selfcheck_update_stack_attribution() {  # selfcheck_update_stack_attribution <outdir>
  # 63) 长 update 归因的八个形状：同窗才 join、双行收成事件、区间外与别家进程不许点名、
  #     没采到栈写「取不到」、管道帧剔掉但照印、跨窗口拒、有标记没表也拒。
  local r
  r=$(blame_attribution_probe "$1")
  [ -n "$r" ] \
    || { fail "归因夹具的 python 崩了（拿到空串）⇒ 这不是判据不符，是这一项根本没跑"; return; }
  [ "$r" = "True|True|True|True|True|True|True|True" ] \
    || { fail "长 update 归因八个形状没各判对（拿到 $r）⇒ 归因表会把别的窗口的栈归给这一刻"; return; }
  ok "长 update 归因认得「同窗才 join、双行收成事件、区间外/别家进程不许点名、没栈写取不到、跨窗口与缺表一律拒跑」"
}

# 63 的第二条腿：归因档的**接线**（不只是尺子会算）。
# 为什么单独立一格：#43 的整条链有两个"定义了没用"的落点 —— ① 那枚附加仪器必须**作为一个参数**
# 进到 xctrace（bash 3.2 的 `set -u` 会把空数组展开直接打死，而词法分裂会把 Time Profiler 拆成两个
# 参数、xctrace 收到 `Time` 就当不认识）；② 导出的表必须落成新名字，
# 否则 `time-profile.xml` 被归因档盖掉 ⇒ 认证档 T2 读到的是另一趟的样本。
blame_wiring_probe() {  # blame_wiring_probe <outdir> → 四格 True/False 向量（空串 = 假 xcrun 没跑起来）
  local fx="$1/blame-wire" log rc=0
  rm -rf "$fx"
  mkdir -p "$fx/bin" "$fx/with" "$fx/plain"
  printf '%s\n' '#!/bin/bash' \
    'printf "argc=%d" "$#"; for a in "$@"; do printf " [%s]" "$a"; done; echo' \
    'while [ $# -gt 0 ]; do' \
    '  if [ "$1" = "--output" ]; then printf "<table/>\n" > "$2"; fi' \
    '  shift' \
    'done' > "$fx/bin/xcrun"
  chmod +x "$fx/bin/xcrun"
  # 局部覆盖：`record_bounded` 的四个全局量在 selfcheck 里由 harness 供给，这里给一套自足的，
  # 被测进程用**本 shell 自己的 pid**（永不消失，也不碰别人的实例）。
  local DRY_RUN=0 RECORD_SLACK_S=1 RECORD_POLL_S=1 PID=$$ PATH="$fx/bin:$PATH"
  log="$fx/argv.log"
  ( record_bounded "$fx/with" "$fx/with/x.trace" "Animation Hitches" 1 "Time Profiler" ) >"$log" 2>&1 || rc=1
  export_table "$fx/with/x.trace" "time-profile" "$fx/with" "blame-time-profile.xml" >>"$log" 2>&1
  ( record_bounded "$fx/plain" "$fx/plain/x.trace" "Animation Hitches" 1 "" ) >"$fx/plain.log" 2>&1 || rc=2
  export_table "$fx/plain/x.trace" "time-profile" "$fx/plain" >>"$fx/plain.log" 2>&1
  [ "$rc" = "0" ] || { printf ''; return; }        # 空串 = 这一项根本没判成，不许当成四条不符
  printf '%s|%s|%s|%s' \
    "$(grep -c -a '\[--instrument\] \[Time Profiler\]' "$log")" \
    "$([ -s "$fx/with/blame-time-profile.xml" ] && [ ! -e "$fx/with/time-profile.xml" ] && echo 1)" \
    "$(grep -c -a -- '--instrument' "$fx/plain.log")" \
    "$([ -s "$fx/plain/time-profile.xml" ] && echo 1)"
}

selfcheck_blame_wiring() {  # selfcheck_blame_wiring <outdir>
  # 63b) 归因档接线四格：附加仪器成**一个**参数、导出改名且不碰认证档那份、
  #      常规档不带 --instrument、常规档仍按 schema 名落盘。
  local r
  r=$(blame_wiring_probe "$1")
  [ -n "$r" ] || { fail "假 xcrun 那一趟没跑完 ⇒ 接线四格一条都没判（不是判据不符）"; return; }
  [ "$r" = "1|1|0|1" ] \
    || { fail "归因档接线四格没各判对（拿到 $r，应为 1|1|0|1）⇒ 要么仪器被词法分裂，要么归因档盖了认证档的表"; return; }
  ok "归因档接线：--instrument 作为一个参数进 xctrace、导出落 blame-time-profile.xml、常规档一字不带"
}
