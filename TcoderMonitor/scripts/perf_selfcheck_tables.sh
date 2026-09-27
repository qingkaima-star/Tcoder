#!/bin/bash
# =============================================================================
# selfcheck 反例分块：**表格与预算口径这一族**（逐帧三张表各配自己的预算、
# p95 两把尺合判、update 表窄分布不许当主线程忙时、两把预算要真会分歧、
# 输入节奏必须有读者、markdown 表格不许断行）。
# 由 `perf_selfcheck.sh` 的 `_part` 循环 source 进来。
# 自 `perf_selfcheck_eligibility.sh` 与 `perf_selfcheck_ruler_shapes.sh` 逐字节搬出。
# =============================================================================

selfcheck_frame_table_budgets() {  # selfcheck_frame_table_budgets <outdir>
  # 42) 逐帧三张表**各配自己的预算**（§AC）。触发这条的是我自己刚才差一点又犯的老错：
  #     第一版拿 8.333 ms 去判 `hitches-frame-lifetimes`，得到"2431/2431 帧超预算（100%）"——
  #     那句毫无意义（帧内容寿命天生是 3 帧 ≈ 25 ms），与包 10 的 `hitches-updates` 同族。
  #     所以这里反向钉一次：**全 25 ms 的寿命表必须判"不判单帧预算"，且不许出现"超预算"**。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import frame_table_rows
L = {"hitches-framewait": {"present": True, "doc": None, "json": {"values": [8.9] * 98 + [14.0, 15.0]}},
     "hitches-gpu": {"present": True, "doc": None, "json": {"values": [3.4] * 100}},
     "hitches-frame-lifetimes": {"present": True, "doc": None, "json": {"values": [25.0] * 100}}}
# 返回的是 [(标签, 现量, 判定)]：**按标签索引**，别按 L 的键（上一版就在这儿 KeyError，
# 拿到空串被当成判定不符，看着像尺子坏了，其实是夹具自己崩了）。
rows = frame_table_rows(L, 8.333)
d = dict((lbl, verdict) for lbl, _, verdict in rows)
c = dict((lbl, cur) for lbl, cur, _ in rows)
w = [verdict for lbl, _, verdict in rows if "等待" in lbl][0]
e = frame_table_rows({}, 8.333)
z = dict((lbl, verdict) for lbl, _, verdict in frame_table_rows(
        {"hitches-framewait": {"present": True, "doc": None, "json": {"values": []}}}, 8.333))
print("%s|%s|%s|%s|%s|%s" % (
    "不判单帧预算" in d["每帧内容寿命(ms)"] and "超" not in d["每帧内容寿命(ms)"],
    "2 帧超" in w,
    "达标" in d["每帧 GPU 用时(ms)"],
    all("未覆盖" in verdict for _, _, verdict in e),
    "n=100" in c["每帧排队等待(ms)"] and "15.00" in c["每帧排队等待(ms)"],
    "不判" in z["每帧排队等待(ms)"]))')
  [ -n "$r" ] || { fail "夹具里的 python 崩了（拿到空串）⇒ 这不是判据不符，是这条没跑"; return; }
  [ "$r" = "True|True|True|True|True|True" ] \
    || { fail "逐帧表的预算六种形状没各判对（拿到 $r）⇒ 会重新写出「100% 超预算」那种废话"; return; }
  ok "逐帧三张表各配预算：寿命不判单帧、等待对 1.5×、GPU 对 1×，缺表与 0 读数都在判定列出声（六种形状）"
}

selfcheck_p95_crosscheck_shapes() {  # selfcheck_p95_crosscheck_shapes <outdir>
  # 33) 「p95 ≤ 8.4 ms」这一半句现在由**两把尺子合判**，所以合判本身必须能被喂数字验。
  #     为什么必须有这一项：脉冲读的是 CVDisplayLink **回调送达时刻**，不等于上屏时刻；
  #     实测三趟都是 p50 恰好 8.33（＝一个周期）而 p95 落在 8.98~9.26 ⇒ 有一大片帧晚了约 1 ms。
  #     同一串数既能解释成"掉帧"也能解释成"回调偏晚"，**结论相反**——
  #     没有第二种仪器时它是个不可判定命题，而不可判定最容易被写成"未达标"蒙过去。
  #     七种形状各判一次：缺脉冲 / 缺表 / 档位不适用 / 越预算但上屏跟满 / 两侧都好 /
  #     两侧都坏 / 没越预算可上屏没跟上（两把尺子互相矛盾）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_framepulse import crosscheck
p_over = {"expected_interval_ms": 8.33, "frame_p50_ms": 8.33, "frame_p95_ms": 9.18}
p_ok   = {"expected_interval_ms": 8.33, "frame_p50_ms": 8.33, "frame_p95_ms": 8.10}
I = {"period": "interaction"}; D = {"period": "idle"}
c = [("缺脉冲",     crosscheck(None,     8.41, 120.0, 118.0, 120.0, 20, I)),
     ("缺表",       crosscheck(p_over,   8.41, None,  None,  None,  None, I)),
     ("档位不适用", crosscheck(p_over,   8.41, 120.0, 10.0,  12.0,  21, D)),
     ("越预算但上屏跟满", crosscheck(p_over, 8.41, 120.0, 118.0, 120.0, 20, I)),
     ("两侧都好",   crosscheck(p_ok,     8.41, 120.0, 119.0, 120.0, 20, I)),
     ("两侧都坏",   crosscheck(p_over,   8.41, 120.0, 40.0,  60.0,  20, I)),
     ("脉冲好上屏差", crosscheck(p_ok,   8.41, 120.0, 40.0,  60.0,  20, I))]
print("|".join("%s=%d" % (k, code) for k, (_, code) in c))')
  [ "$r" = "缺脉冲=1|缺表=1|档位不适用=2|越预算但上屏跟满=2|两侧都好=0|两侧都坏=1|脉冲好上屏差=2" ] \
    || { fail "合判七种形状的退出码不对（拿到 ${r:-解析失败}）——不可判定的东西又要被写成结论"; return; }
  # 反向钉：不许只改码不改话。「尾巴在回调时序」与「呈现真的缺帧」必须是两句话，
  # 一模一样就等于把两种相反的结论压成一条打印。
  local kept dropped
  kept=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_framepulse import crosscheck
print(" ".join(crosscheck({"expected_interval_ms": 8.33, "frame_p50_ms": 8.33,
                            "frame_p95_ms": 9.18}, 8.41, 120.0, 118.0, 120.0, 20,
                       {"period": "interaction"})[0]))')
  dropped=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_framepulse import crosscheck
print(" ".join(crosscheck({"expected_interval_ms": 8.33, "frame_p50_ms": 8.33,
                            "frame_p95_ms": 9.18}, 8.41, 120.0, 40.0, 60.0, 20,
                       {"period": "interaction"})[0]))')
  case "$kept"    in *"回调时序"*) ;; *) fail "上屏跟满那一支没说出「尾巴在回调时序」（拿到 $kept）" ;; esac
  case "$dropped" in *"呈现真的缺帧"*) ;; *) fail "上屏也差那一支没说出「呈现真的缺帧」（拿到 $dropped）" ;; esac
  [ "$kept" != "$dropped" ] || { fail "两种相反结论印成同一句话，等于没合判"; return; }
  # 不许把"缺表"读成"0 帧每秒"：那是把仪器故障伪装成性能灾难（本仓这类形状记过很多次）。
  case "$r" in *"缺表=0"*) fail "缺表被判成达标" ;; esac
  ok "p95 那半句由两把尺子合判：七种形状各判一次，缺件/不适用/矛盾都不许给结论"
}

selfcheck_update_table_caveat() {  # selfcheck_update_table_caveat <outdir>
  # 34) 那张"update 表"在交互档里的形状**不许被读成主线程忙时**——2026-09-22 22:16 我就是这么误读的，
  #     22:22 被同趟样本里第三把仪器（time-profile：主线程 99.9% 在等事件）推翻。
  #     这条守卫守的是**误读的形状**：逐值贴着一条基线下限、不从现在值铺开。
  #     两个方向都要验：交互档那种必须出提示；空闲档那种（下限 0.76 ms、超预算 0）不许出，
  #     否则就是一遇到这张表就恒报警的懒守卫——那玩意活不过第二次响。
  local both
  both=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from trace_report import caveat_for
tight = [9.31, 9.41, 9.41, 9.6, 10.22, 10.64, 35.12]      # 交互档真样本的形状
wide  = [0.76, 0.86, 1.12, 1.25, 1.27, 1.37, 1.63]        # 空闲档真样本的形状
a = caveat_for("hitches-updates", tight, 8.333)
b = caveat_for("hitches-updates", wide, 8.333)
c = caveat_for("hitches-renders", tight, 8.333)
d = caveat_for("hitches-updates", [], 8.333)
print("%s|%s|%s|%s" % ("Y" if a else "N", "Y" if b else "N", "Y" if c else "N", "Y" if d else "N"))')
  [ "$both" = "Y|N|N|N" ] \
    || { fail "update 表的误读提示判错（拿到 ${both:-解析失败}；要求：窄分布出提示、宽分布/别的表/空表都不出）"; return; }
  # 反向钉：提示必须说清"该去看哪把仪器"，光说"这个数不对"等于没指路。
  local line
  line=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from trace_report import caveat_for
print(caveat_for("hitches-updates", [9.31, 10.22, 10.64], 8.333))')
  case "$line" in *"time-profile"*) ;; *) fail "提示没指出该用哪把仪器（拿到：$line）" ;; esac
  case "$line" in *"9.31"*) ;; *) fail "提示没把\"下限\"这个可复核的数带出来，别人无从复核（拿到：$line）" ;; esac
  ok "update 表的读数形状双向判对：窄分布出提示并指路 time-profile，宽分布/他表/空表都不惊动"
}

selfcheck_cadence_two_budgets() {  # selfcheck_cadence_two_budgets <outdir>
  # 35) 「p95 ≤ 8.4 ms」这半句必须**同时按两个预算报**（名义 120Hz 与实测周期），
  #     而且两把都要有真判例——只印一个就等于测量方偷偷选尺子。
  #     09-22 实测：合成器自己的逐帧起点差给出实测周期 8.376~8.380 ms（≈119.33~119.39 Hz），
  #     名义 120 Hz 的预算因此天生小 0.5%；空闲档 p95 8.52 与交互档 8.51 只差 0.013 ms
  #     ⇒ 残差是面板/仪器地板，不是 App 的卡顿。这种结论只有"两个预算并排印"才站得住。
  local res
  res=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
import os, tempfile
from perf_cadence import report

def xml(path, step_ns, n=1500):
    # 生产解析器（`perf_trace_xml.Doc`）是**按 id 建表再回查**的：
    # 元素没有 `id="N"` 就一个 cell 都拿不到 ⇒ 一份"看起来像"的夹具会静默解析成 0 帧。
    # 所以这里逐行发全局唯一 id，与真产物同形（复用同一个 id 会让所有行都读到第一格）。
    rows = "".join(
        "<row><start-time id=\"%d\" fmt=\"s\">%d</start-time>"
        "<duration id=\"%d\" fmt=\"d\">3000000</duration></row>"
        % (2 * i + 1, i * step_ns, 2 * i + 2) for i in range(n))
    open(path, "w", encoding="utf-8").write("<table><schema name=\"hitches-renders\"/>%s</table>" % rows)

d = tempfile.mkdtemp()
tight, lo, few = os.path.join(d, "a.xml"), os.path.join(d, "b.xml"), os.path.join(d, "c.xml")
xml(tight, 8333333)                       # 精确 8.3333 ms 步进 ⇒ 两个预算都该过
xml(lo, 8500000)                          # 8.500 ms 步进 ⇒ 名义不过、实测过（两把尺子必须分歧）
xml(few, 8333333, n=10)                   # 帧数不足 ⇒ 拒判
a, ca = report(tight); b, cb = report(lo); c, cc = report(few, None, min_frames=1200)
jb = "\\n".join(b)
print("%d|%d|%d|%s|%s" % (ca, cb, cc,
      "both" if ("名义(120Hz)预算" in jb and "实测周期预算" in jb) else "one",
      "split" if ("名义(120Hz)预算 8.417 ms：p95 **未达标**" in jb and "实测周期预算 8.585 ms：p95 达标" in jb) else "same"))')
  [ "$res" = "0|1|2|both|split" ] \
    || { fail "节拍仪器的两个预算没判对（拿到 ${res:-解析失败}；要求 0|1|2|both|split）"
          echo "     ——0=两把都过／1=有超出／2=样本不足，且 8.5ms 那一例必须『名义不过、实测过』"; return; }
  ok "p95 判据两把预算并排印且真会分歧：精确周期=过、8.5ms 步进=名义不过/实测过、样本不足=拒判"
}

selfcheck_input_rate_qualification() {  # selfcheck_input_rate_qualification <outdir>

  # 28) 【标记要有读者】`meta.input_source` 从今晚起带投递节奏（`synth@8ms`），
  #     但"写了没人读"就是第二十三次要防的那个洞——我写完参数那一笔，
  #     报表照旧对 25 Hz 批次印「有资格答 T1」。这一项就是这个读者的读者。
  #     25 Hz 的滚动器每 40 ms 投一拍，比 8.333 ms 的帧预算还宽 ⇒ 出帧上限由仪器决定，
  #     这种读数不许回答"到不到 120Hz"，只许回答"连续输入下有没有 hitch"。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import period_eligibility as pe
c = [("真人","human"),("125Hz","synth@8ms"),("25Hz","synth@40ms"),
     ("旧批次无节奏","synth"),("节奏是垃圾","synth@abc")]
print("|".join("%s=%s" % (k, "Y" if pe({"period":"interaction","input_source":v})[0] else "N")
               for k, v in c))')
  [ "$r" = "真人=Y|125Hz=Y|25Hz=N|旧批次无节奏=N|节奏是垃圾=N" ] \
    || { fail "输入节奏的资格判定不对（拿到 ${r:-解析失败}）——慢节奏样本又能冒充 T1 证据"; return; }
  # 反向钉：不许只改退出码，表头话术必须跟着翻转（第 21 项同一套道理）
  local slow fast
  slow=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c \
    'from perf_trace_summary import period_eligibility as pe; print(pe({"period":"interaction","input_source":"synth@40ms"})[1])')
  fast=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c \
    'from perf_trace_summary import period_eligibility as pe; print(pe({"period":"interaction","input_source":"synth@8ms"})[1])')
  case "$slow" in *"不许交 T1"*) ;; *) fail "25 Hz 样本的表头话术没翻转（还是「$slow」）" ;; esac
  case "$fast" in *"有资格答 T1"*) ;; *) fail "125 Hz 样本被一起挡在门外（「$fast」）——恒拒的闸门只会量产假绿" ;; esac
  [ "$slow" != "$fast" ] || { fail "两种节奏的话术一模一样，等于没判"; return; }
  ok "输入节奏有读者：五种形状各判一次，慢节奏与无节奏都不许冒充 T1 证据"
}

# =============================================================================
# 30) markdown 表格不许有"夹在行中间的裸续行"，也不许多出/少掉格子。
#     立规的触发是我自己：用 Edit 往 §6.1 的一格里塞多行文本，换行把一行物理行拆成四行
#     ⇒ 表格当场塌掉，而 commit 一路"成功"、diff 也看不出问题。
#     第二条（列数必须等于表头）09-23 补：往格子里写 `--filter A|B` 那种**裸竖线**，
#     一行就多出的一格被渲染器**静默丢掉**，看着只像"少了一列"，谁都不会怀疑两张表连体了。
#     范围只扫性能轮自己的文档（并行多流时各家只守自己名下目录）。
#
#     【分母的历史，别写成死的数】09-23 早上 3→4（备忘涨到 810 行撞 ≤800 棘轮，
#     按"拆，不拧阈值"搬出 §N~§U），09-23 晚上 4→5（卷二又涨到 787 行，§AK 起搬进卷三），
  #     09-24 凌晨 5→6（工单本体涨到 795 行，§0.8/§0.8.1/§0.9 搬进 2026-09-24-perf-paydown-order.md）。
  #     三次搬家都是同一把 ≤800 尺子逼的，而每一次漏扫搬出去那份的概率都比上一次高——
  #     所以分母只能由这个循环自己长大，不许任何地方再抄一份份数。
#     这里原来钉着 `[ "$n" = "4" ]`——同一件事的第二处入口，且是个会烂的数：一天搬两次家，
#     它每次都慢一步变成假话，报的"应为 4 份"还会把人往错方向修（拆完卷三被它拦下时，
#     我先怀疑自己搬错文件，才怀疑到那个数写歪了）。要的不变式是"**点名的每份都在**"，
#     那由循环里逐份的 `[ -f ] || fail 少了 $f` 保证，比总数强；总数只留"扫描面不许为空"
#     这一条（空扫描面 = 永真绿）。搬出去的那份**必须继续被扫**，否则"拆文档"就成了
#     让表格断行与列数免检的通道——同一个教训在 `PerfRulerHotspotRatchetTests`
#     的 `rulerScripts` 注释里也写着。
# =============================================================================
selfcheck_md_tables_unbroken() {  # selfcheck_md_tables_unbroken <outdir>
  # 为什么立这条、分母为什么不是死的数：都写在上面的块注释里（这条函数按行被尺子量，
  # 注释住哪儿不改判据；这里只留判据本体）。
  local f bad=0 n=0
  for f in ../docs/superpowers/specs/2026-09-20-performance-120hz-design.md \
           ../docs/superpowers/specs/2026-09-20-perf-baseline-detail.md \
           ../docs/superpowers/plans/2026-09-20-perf-followup-tickets.md \
           ../docs/superpowers/plans/2026-09-21-perf-handoff-notes.md \
           ../docs/superpowers/plans/2026-09-22-perf-handoff-notes-round2.md \
           ../docs/superpowers/plans/2026-09-23-perf-handoff-notes-round3.md \
           ../docs/superpowers/plans/2026-09-24-perf-paydown-order.md; do
    [ -f "$f" ] || { fail "少了 $f——分母变小也是失效，不许静默跳过"; bad=1; continue; }
    n=$((n + 1))
    # 判据与手工核对时用的那条 python 完全同一形状（不是再写一把近似的）：
    # 上一行以 | 开头、本行不以 | 开头且非空、下一行以 | 开头 ⇒ 表格中间混进裸续行。
    local hits
    hits=$(python3 - "$f" <<'PYCHK'
import sys
ls = open(sys.argv[1], encoding='utf-8').read().split('\n')
bad = [str(i + 1) for i in range(1, len(ls) - 1)
       if ls[i - 1].startswith('|') and ls[i + 1].startswith('|')
       and not ls[i].startswith('|') and ls[i].strip()]
print(' '.join(bad))
PYCHK
)
    [ -z "$hits" ] || { fail "$f 的表格里有断行（行号 $hits）——上一版我自己就把 §6.1 压成了一行"; bad=1; }
    # 【09-23 加的第二判】列数必须等于表头。断行只查得出"表中间夹散文"，
    # 查不出**两行糊成一行**（那正是今天我自己造成的：往 §6.1 插新行时把下一行的行首吃进了上一行，
    # 结果一行有 8 格 —— 渲染器会把多出来的格子**静默丢掉**，看起来只是"少了一列"，
    # 谁都不会怀疑那段话其实把两张表的两行连体了）。缺收尾竖线也在这条的射程里。
    # 不处理格子里转义过的 `\|`（下面那个循环里的几份性能文档实测一个都没有；
    # 真要写转义竖线的那天，这条得连判据一起改，别只改注释）。行号按原文取。
    local cols
    cols=$(awk 'function ncell(l,  a, n) { sub(/^\|/, "", l); sub(/\|$/, "", l); n = split(l, a, "|"); return n }
      /^\|/ { if (inblk == 0) { inblk = 1; head = ncell($0) }
              if ($0 ~ /^[|][-: |]+$/) next
              c = ncell($0)
              if (c != head) printf "第%d行%d格≠表头%d格; ", NR, c, head
              next }
      { inblk = 0 }' "$f")
    [ -z "$cols" ] || { fail "$f 的表格列数与表头不符（$cols）⇒ 多出的格会被渲染器丢掉"; bad=1; }
  done
  [ "$n" -gt 0 ] || { fail "一份性能文档都没扫到 ⇒ 表格判据正在空转"; return; }
  [ "$bad" = "0" ] && ok "$n 份性能文档的表格结构完好（无断行、每行列数=表头；分母逐份点名存在）"
}

selfcheck_update_caliber_one_rule() {  # selfcheck_update_caliber_one_rule <outdir>
  # 54) `app-update` 只许有一个口径。09-24 在**同一份 trace** 上量到三个数
  #     （行数 28 / 按(起,时长)去重 17 / 按值去重 16），而 sidecar 的 `values` 还只存最小的 40 个
  #     ⇒ XML 一缺失，回落尺读到的 max 是"第 40 小"，而 T2 的判据量正是这个 max（假绿通道）。
  local r
  r=$( cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 - "$1" <<'PYCHK'
import json, os, subprocess, sys
from perf_trace_metrics import load_measure
from perf_update_caliber import dedupe_pairs, update_caliber_note
fx = os.path.join(sys.argv[1], "caliber-fx"); os.makedirs(fx, exist_ok=True)
# 4 行=3 事件：第 2 行是第 1 行的 Brown/Red 双行，第 3 行与第 1 行同时长但**起点不同**（真事件）
row = '<row><start-time id="%s" fmt="%s">%s</start-time><duration id="%s" fmt="%s">%s</duration></row>'
ref = '<row><start-time ref="1"/><duration ref="2"/></row>'

def run(dirname):   # 让被检的 CLI 自己出 sidecar，不在夹具里复刻它的算法
    xml = os.path.join(dirname, "hitches-updates.xml")
    subprocess.run([sys.executable, "trace_report.py", "durations", xml,
                    "--json", os.path.join(dirname, "hitches-updates.json")],
                   check=True, stdout=subprocess.DEVNULL)
    return json.load(open(os.path.join(dirname, "hitches-updates.json")))


open(os.path.join(fx, "hitches-updates.xml"), "w").write(
    '<table><schema name="hitches-updates"/>\n'
    + row % ("1", "0.1 ms", 100000, "2", "6.00 ms", 6000000) + "\n" + ref + "\n"
    + row % ("3", "2000 ms", 2000000000, "4", "6.00 ms", 6000000) + "\n"
    + row % ("5", "3000 ms", 3000000000, "6", "12.00 ms", 12000000) + "\n</table>\n")
js = run(fx)
xml_col = dedupe_pairs(load_measure(fx, "hitches-updates"))            # 走 XML
side_col = dedupe_pairs({"doc": None, "json": js, "present": True})    # 走 sidecar 的 pairs
bare = dedupe_pairs({"doc": None, "json": {"values": js["values"]}, "present": True})  # 只有裸值
# 回落不许截断：45 行的表，最大值必须还在 `values` 里（曾 [:40] ⇒ 回落尺读到"第 40 小"当 max）
big = os.path.join(fx, "big"); os.makedirs(big, exist_ok=True)
open(os.path.join(big, "hitches-updates.xml"), "w").write(
    '<table><schema name="hitches-updates"/>\n'
    + "".join(row % (str(10 + i), "1 ms", 1000000, str(200 + i), "%d ms" % (i + 1), (i + 1) * 1000000)
              for i in range(45)) + "\n</table>\n")
bigjs = run(big)
print("|".join(str(x) for x in [
    js["n_rows"] == 4 and js["n_events"] == 3 and js["n"] == 3 and js["over_budget"] == 1,
    [round(v, 2) for v in xml_col] == side_col,
    len(bare) == 4 and update_caliber_note({"doc": None, "json": {"values": [1.0]}}) != "",
    len(bigjs["values"]) == 45 and max(bigjs["values"]) == 45.0]))
PYCHK
)
  [ -n "$r" ] || { fail "夹具里的 python 崩了（拿到空串）⇒ 这不是判据不符，是这条没跑"; return; }
  [ "$r" = "True|True|True|True" ] || { fail "app-update 口径四形状没各判对（拿到 $r）⇒ 又会变成『两处入口两个数』"; return; }
  ok "app-update 一个口径：sidecar 与汇总表同 n、双行收成事件、按值并不许少计、回落不再截 40"
}

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
  local fx tp r_none r_bad r_fb out h1
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
  # 75g) 入口根帧不许顶掉「热点第一名」——查的是落盘那格（汇总表的唯一来源），不是散文
  root_plumbing_fixture "$fx/root.xml"
  python3 scripts/trace_report.py threads "$fx/root.xml" --top 3 --json "$fx/root.json" >"$fx/root.txt" 2>&1
  h1=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["hotspot_top1"])' "$fx/root.json" 2>/dev/null)
  [ "$h1" = "hotWork()" ] || out="$out 热点第一名=$h1（要 hotWork()；是入口根帧就是 RUNLOOP_PLUMBING 的结构形状那格被拿掉了）"
  grep -qF "事件循环本体占 83.3%" "$fx/root.txt" || out="$out 剥掉根帧却没印它占多少（剥了要出声，不许静默改榜）"
  rm -rf "$fx"
  [ "$out" = "ok" ] || { fail "threads 的窗口切片不成立：$out"; return; }
  ok "threads 尺六格有牙：全窗自称全窗、窗口筛得对、零命中说「窗口选错」而不是「表是空的」、" \
     "反向区间直接拒、认不到执行体要出声、入口根帧不顶热点第一名（75）"
}
