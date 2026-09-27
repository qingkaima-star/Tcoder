# selfcheck 反例分块：**三把尺一致性与打回率**这一族（`selfcheck_trio_*` 与它的两个探针、
# 判废不并池、越档不判档）。
# 为什么单独成块（2026-09-27 卷十二 §187）：`perf_selfcheck_eligibility.sh` 写到 **398/400**，
# 再往里加一臂就会在当天把「文件 ≤400 行」那把门撑红。本仓对这把门只有一句口径：**拆，不抬线**。
# 搬的是整族（连着它们各自的头注），**一字未改**；搬完 `bash -n` 三块全过、
# selfcheck 前后 78 项逐字对齐（差异只有探针秒数）。
# shellcheck shell=bash

selfcheck_trio_agreement() {  # selfcheck_trio_agreement <outdir>
  # 39) 「连测 ≥3 趟**且取值一致」**里的**后半句**必须有尺子量（spec §1.3）。
  #     触发事件是 09-23 02:35 那一幕：`[interact] rc=0 ⇒ 可用 3/3 趟` 打得理直气壮，
  #     而三趟的 hitch/s 是 **1.20 / 1.30 / 18.80**（同头同产物、六维上下文逐条合格）。
  #     "可用"数的是结构（产物齐、没被 REFUSED、复核没打回），**从来没数过一致性**——
  #     于是排程器的 3/3 被所有人读成"协议满足"。数样本 ≠ 量一致。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trio_agreement import verdict
def R(n, fps=119.0, secs=20.0, rend=4.1, per="interaction", upd=None, vals=None):
    return {"dir": "run", "seconds": secs, "hitch_n": int(round(n * secs)),
            "hitch_per_s": n, "period": per, "render_p50_ms": rend, "update_values": vals or [],
            "update_max_ms": upd, "surfaces_p50_fps": fps}
TIGHT = [1.0 + 0.02 * i for i in range(14)]          # 一趟稳态心跳：p90 1.24 / max 1.26
WIDE_MAX = [1.0 + 0.02 * i for i in range(13)] + [9.9]   # 同一形状，只多一枚孤例 max
def idle(vals, upd):
    return R(0.0, per="idle", upd=upd, vals=vals)
a = verdict([R(1.2), R(1.3), R(1.5)], ["a", "b", "c"])[1]                 # 交互档：一致
b = verdict([R(1.2), R(1.3), R(18.8)], ["a", "b", "c"])[1]                # 09-23 真形状：不一致
c = verdict([R(1.2), R(1.3), None], ["a", "b", "x"])[1]                   # 缺件 ⇒ 不判
d = verdict([R(1.2), R(1.3)], ["a", "b"])[1]                              # 不足 ⇒ 不判
e = verdict([R(1.2), R(1.3, fps=88.0), R(1.5)], ["a", "b", "c"])[1]       # 出帧分歧：裁定 A 起**只印不判**
f = verdict([R(1.2), R(1.3), R(1.5, per="idle")], ["a", "b", "c"])[1]     # 混档 ⇒ 不判
g = verdict([idle(TIGHT, 1.26), idle(TIGHT, 1.30), idle(TIGHT, 1.34)], ["a", "b", "c"])[1]
h = verdict([idle(TIGHT, 1.26), idle(TIGHT, 1.30),                      # 真形状：另一趟带 12 ms 尾巴
             idle(TIGHT[:4] + [12.0] * 4 + TIGHT[4:], 12.0)], ["a", "b", "c"])[1]
i = verdict([idle(TIGHT, 1.26), idle([], None), idle(TIGHT, 1.34)], ["a", "b", "c"])[1]
j = verdict([idle(TIGHT, 1.26), idle(WIDE_MAX, 9.9), idle(TIGHT, 1.34)], ["a", "b", "c"])[1]
print("%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % (a, b, c, d, e, f, g, h, i, j))')
  # 第 10 条在 #124 之前是 0（三趟散布一致就放行，其中一趟 max 9.9 ms），现在是 **1**：
  # ⇒ 这条改动是本项的**预期改口**，不是回归——9.9 ms 越过 T2 的 4.0 ms 线，散布尺仍说"一致"，
  #   而认证出口从此由判据② 把关（第 87 项钉住这句话印在产物里）。把 4.0 那格偷偷改回不判 ⇒ 第 10 条变 0，当场红。
  # 第 5 条在 2026-09-26 裁定 A 之前是 1（出帧分歧判不一致），现在是 **0**：
  # 这一格就是那纸裁定的守卫 —— 有人把出帧那一维偷偷改回判据、或反过来把它整维删掉不印，
  # 都会在这里红（改回判据 ⇒ 第 5 条变 1；删掉不印 ⇒ 下面那句 ok 之外另有 grep 钉着参考行）。
  [ "$r" = "0|1|2|2|0|2|0|1|1|1" ] \
    || { fail "一致性判定十种形状没各判对（拿到 $r，应为 0|1|2|2|0|2|0|1|1|1）⇒ " \
              "第 5 条不是 0 就是出帧那一维又被当成判据（或干脆不印了），其余任一条不对都是这条尺会把「3/3」放行"; return; }
  trio_collapse_probe | grep -q '参考项:有 小n:塌 大n:不塌' \
    || { fail "三格缺一：参考项不印＝把出帧那维的读数藏起来；小n 不报「塌陷」＝n≤10 时「每趟 p90 就是该趟 max」这一格没人出声（§173）；大n 乱报＝把不是极值的也说成极值"; return; }
  # 第 7 条是**我自己第一版被自己的尺子抓到的**那条：idle 档的 hitch 真值≈0，
  # 拿它做除法散布会把 0.00~0.95 判成"19.0× ⇒ 严重不一致"。判据量必须跟着档位走。
  # 第 10 条钉的是 09-24 需求方裁定 A：`max` 极差比 7.9× 而 p90/均值都在带宽内 ⇒ **判一致**；
  # 同一条夹具把尾巴加进 p90（第 8 条）就必须变红 —— 两条一对，才证明这条不是"怎么都放行"。
  ok "同档连测的一致性有尺子了：按档取判据量（交互比 hitch/s、idle 比每趟自身 p90 与均值），十形状各判一次（含极值不当判据的正反一对）"
}

trio_collapse_probe() {  # → 印三格：参考项印没印、小 n 批认不认「p90 就是 max」、大 n 批别乱认
  # 从 `selfcheck_trio_agreement` 拆出来的：那一格加上第 10 条之后本体 51 行，
  # 撞 `PerfRulerHotspotRatchetTests` 的「尺子函数 ≤50 行」。**拆，不抬线**（同下面的 `trio_pooling_probe`）。
  (cd "$(dirname "$TRACE_REPORT")" && python3 -c '
from perf_trio_agreement import _judge_spread
def R(n, f=120.0): return {"update_values": [1.0]*n, "update_max_ms": 1.3, "surfaces_p50_fps": f}
def has(runs, w): return w in " ".join(_judge_spread(runs, "idle")[1])
print("参考项:" + ("有" if has([R(14, 119.0), R(14, 88.0)], "参考项") else "无"),
      "小n:" + ("塌" if has([R(6), R(8)], "本批全部如此") else "无"),
      "大n:" + ("不塌" if has([R(14), R(16)], "不是极值") else "无"))')
}

trio_pooling_probe() {  # trio_pooling_probe <outdir> → 造四份夹具、调判定，印一行复合读数
  # 这一半本来长在 `selfcheck_refused_not_pooled` 里：归因档那两格把函数本体顶到 **51 行**，
  # 越过 `PerfRulerHotspotRatchetTests` 那条"尺子函数 ≤50 行"的闸门（21:12 门禁现场判红）。
  # **拆，不抬线** —— 本仓为同一把门让路是第四次，前几次的注释就写在尺子名单里。
  cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 - "$1" <<'PYCHK'
import json, os, sys
from perf_trio_agreement import read_run
root = sys.argv[1]
xml = ('<table><schema name="hitches"/>\n'
       '<row><start-time id="1" fmt="0.1 ms">100000</start-time>'
       '<duration id="2" fmt="9.00 ms">9000000</duration></row>\n</table>\n')
for name in ("clean", "refused"):
    d = os.path.join(root, "trio-" + name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "hitches.xml"), "w").write(xml)
    json.dump({"period": "idle", "hitches_seconds": 20, "input_source": "human"},
              open(os.path.join(d, "meta.json"), "w"))
open(os.path.join(root, "trio-refused", "REFUSED"), "w").write("REFUSED\n闸门当场拒收\n")
# 归因档两格（09-25 20:32 的现场：三趟里两趟是"按设计不参与"、一趟真被拒，
# 旧出口把两种东西印成同一句话，下一个人会去修根本没坏的采集）：
#   · 只有 blame 标记 ⇒ 认成 bydesign，并且整批都是它时判"不适用"（不是失败）
#   · blame + REFUSED 同时在场 ⇒ 必须认成 refused（更该先看见的那格赢，别让"按设计"盖住真坏的）
for name, extra in (("blame", {"blame_instrument": 1}), ("both", {"blame_instrument": 1})):
    d = os.path.join(root, "trio-" + name)
    os.makedirs(d, exist_ok=True)
    open(os.path.join(d, "hitches.xml"), "w").write(xml)
    meta = {"period": "idle", "hitches_seconds": 20, "input_source": "human"}
    meta.update(extra)
    json.dump(meta, open(os.path.join(d, "meta.json"), "w"))
open(os.path.join(root, "trio-both", "REFUSED"), "w").write("REFUSED\n闸门当场拒收\n")
from perf_trio_agreement import _why_out, verdict
# 只对"没参与"的那几趟问原因（clean 那趟本来就可用，不该被拿去分类）
kinds = ",".join(_why_out(os.path.join(root, "trio-" + n))[0]
                 for n in ("refused", "blame", "both"))
lines, code = verdict([None, None],
                      [os.path.join(root, "trio-blame")] * 2)
got_clean = read_run(os.path.join(root, "trio-clean")) is not None
got_refused = read_run(os.path.join(root, "trio-refused")) is None
got_blame_out = read_run(os.path.join(root, "trio-blame")) is None
print("%s|%s|%s|%s|%s" % (got_clean, got_refused, got_blame_out, kinds, code))
PYCHK
}

selfcheck_refused_not_pooled() {  # selfcheck_refused_not_pooled <outdir>
  # 55) **被闸门当场拒收的那一趟必须不被池化**，而且"按设计不参与"不许被印成"这一趟坏了"。
  #     头注一直写着"没被 REFUSED"，可代码里原先没有那个读者——我拿临时探针数"这趟合格吗"时
  #     就把一个 REFUSED 的目录读成了合格（挂死的录制会留下上一次的表文件，"表在 + REFUSED 在"就是入口）。
  local rf rf1
  rf=$(trio_pooling_probe "$1")
  rf1=$(printf '%s\n' "$rf" | head -1)
  [ "$rf1" = "True|True|True|refused,bydesign,refused|3" ] \
    || { fail "REFUSED／归因档这两维没被分开读（拿到「$rf1」，应为 " \
              "True|True|True|refused,bydesign,refused|3）⇒ 被拒的一趟会混进散布，" \
              "或按设计的归因档被印成坏了"; return; }
  ok "被当场拒收的那一趟混不进散布，且归因档与它分得开：同一份表 + meta，加 REFUSED 的被排除、" \
     "只有 blame 标记的判「按设计不参与」（整批如此 ⇒ 不适用 rc=3）、blame+REFUSED 同场时按被拒算"
}

# 合成读数的组内打回率计数（#53 裁定尺）。**判据不在这里重算** ——
# 这个 helper 只造读数，分类全部走交付里那两把尺（`_judge_spread` 与 `sweep`）。
trio_fpr_counts_probe() {  # trio_fpr_counts_probe <形态：same-fps-spread / one-slow-run>
  python3 - "$1" <<'PY'
import os
import sys
sys.path.insert(0, os.path.join("scripts"))
import perf_trio_false_reject as fpr


def one(fps, vals):
    return {"dir": "probe", "seconds": 20.0, "update_values": vals,
            "surfaces_p50_fps": fps, "update_max_ms": max(vals),
            "hitch_per_s": 0.0, "hitch_n": 0}


flat = [1.0] * 20
if sys.argv[1] == "same-fps-spread":
    # 出帧 100/104/108/112（极差 12 > 参考线）而两把主尺完全相同 ⇒ 裁定 A 起四组三元**全过**
    runs = [one(100, flat), one(104, flat), one(108, flat), one(112, flat)]
else:
    # 出帧全都一样（这一维不拦），但其中一趟的 update 分布是别人的 4 倍 ⇒ 1 过、3 别处也拦
    runs = [one(105, flat), one(105, flat), one(105, flat), one(105, [4.0] * 20)]
counts, _examples = fpr.sweep(runs, 3)
print("%d %d %d" % (counts[fpr.PASS], counts[fpr.FPS_ONLY], counts[fpr.ELSEWHERE]))
PY
}

selfcheck_trio_false_reject_counts_are_exact() {  # 74) 打回率尺：三分类要数得准、分母不成立要判错、口径句不许掉
  local bad=0 d="$out/trio-fpr" got
  mkdir -p "$d"
  got=$(trio_fpr_counts_probe same-fps-spread 2>"$d/a.err")
  [ "$got" = "4 0 0" ] \
    || { fail "出帧极差 12、两把主尺完全相同的一批合成读数，四组三元应数成 4 过／0 只被出帧拦／0 别处（实得「$got」，" \
              "明细 $d/a.err）⇒ 出帧那一维又回到判据里了（2026-09-26 裁定 A 被推翻就是这一格先红）"; bad=1; }
  got=$(trio_fpr_counts_probe one-slow-run 2>"$d/b.err")
  [ "$got" = "1 0 3" ] \
    || { fail "出帧一致而有一趟 update 慢 4 倍的一批，应数成 1 过／0 只被出帧拦／3 别处也拦（实得「$got」，" \
              "明细 $d/b.err）⇒ 那一维会被误算成『没拦过任何东西』"; bad=1; }
  # 反向：喂不够趟数必须**不出数**（假 0 比不报更贵）
  if python3 scripts/perf_trio_false_reject.py "$d/没有这趟1" "$d/没有这趟2" > "$d/c.txt" 2>&1; then
    fail "只给两个目录却 rc=0 ⇒ 一支没被喂够数据的尺给了结论"
    bad=1
  fi
  grep -qF '本次不作数' "$d/c.txt" \
    || { fail "拒了但没说是分母不成立 ⇒ 报出来像脚本坏了而不是数据不够"; bad=1; }
  # 口径那一句不许被删：它挡的是「把组内抽样读成全产品抖动率」这种过头读法
  grep -qF '不是全产品抖动率' scripts/perf_trio_false_reject.py \
    || { fail "尺子里那句口径 caveat 不见了 ⇒ 这两个比例会被读成产品抖动率"; bad=1; }
  [ "$bad" = "0" ] && ok "打回率尺三分类数得准（裁定 A 后：出帧分歧那批 4/0/0 就是「出帧不许再当判据」的哨兵；update 慢 4 倍那批 1/0/3 证明它不是怎么都放行）、喂不够趟数不出数、caveat 在位（74）"
}

trio_heartbeat_probe() {  # trio_heartbeat_probe → 一行复合读数：三种档位/形状下判据② 各判成什么
  # 夹具形状照 `read_run` 的产物（`update_values` 有值、`update_max_ms` 是它的 max），
  # 不然臂去抓一个真件里不存在的形状（#118 那一课）。
  cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 - <<'PYCHK'
from perf_trio_agreement import HEARTBEAT_BUDGET_MS, verdict
VALS = [1.0 + 0.02 * i for i in range(14)]          # 稳态心跳：p90 1.24 / max 1.26
def R(maxms, per="idle"):
    return {"dir": "run", "seconds": 20.0, "hitch_n": 0, "hitch_per_s": 0.0, "period": per,
            "render_p50_ms": 4.1, "update_values": VALS, "update_max_ms": maxms,
            "surfaces_p50_fps": 119.0}
ok_l, ok_c = verdict([R(3.9), R(3.8), R(3.95)], ["a", "b", "c"])
bad_l, bad_c = verdict([R(3.9), R(6.0), R(3.95)], ["a", "b", "c"])
na_l, na_c = verdict([R(3.9, "interaction"), R(3.8, "interaction"), R(3.95, "interaction")],
                     ["a", "b", "c"])
pass_line = "每趟 max 都在 T2 的"
fail_line = "判据②：**不成立**"
skip_line = "这一档不参与"
claim = "都过 T2 的 4.0 ms 线"
print("%d|%d|%d|%s|%s|%s|%s|%s" % (
    ok_c, bad_c, na_c,
    "Y" if pass_line in "".join(ok_l) else "N",
    "Y" if fail_line in "".join(bad_l) else "N",
    "Y" if skip_line in "".join(na_l) else "N",
    "Y" if claim in "".join(na_l) else "N",
    "Y" if "%.1f" % HEARTBEAT_BUDGET_MS in "".join(bad_l) else "N"))
PYCHK
}

selfcheck_heartbeat_line_has_a_machine_reader() {  # 87) 判据② 的 4.0 ms 线要有机器读者（#124）
  # 现场：报表那句「达标（没有一个 update 超预算）」按的是**一帧 8.333 ms**（`FRAME_BUDGET_MS_DEFAULT`），
  # 而目标口径 4.0 ms 此前只活在文档里由人读 ⇒ max 落进 4.0~8.33 之间时报表照旧绿、② 已不成立。
  # 认证出口（一致性尺）是那句「3/3 达标」的最后一道闸，所以判据挂在这里；`cert17` 三趟 max
  # 1.38／1.64／2.23 ms 都在线内，本项当时现打 code=0（这条改动没把已成立的认证判死）。
  local r
  r=$(trio_heartbeat_probe)
  # 逐格读法：0|1|0 三种形状的码；第 4 格＝通过句在；第 5 格＝6.0 ms 那批点名「不成立」；
  # 第 6 格＝交互档明说「不参与」；第 7 格＝**不许**在没判过的档位上声称过了 4.0 线（第 34 类：
  # 免责声明绑错对象比没有更危险）；第 8 格＝失败话术里带着那条线的数值。
  [ "$r" = "0|1|0|Y|Y|Y|N|Y" ] \
    || { fail "判据② 的 4.0 ms 线在认证出口上没判对（拿到 $r，应为 0|1|0|Y|Y|Y|N|Y）⇒ " \
              "第 2 格不是 1＝这条线仍然没有机器读者（报表那句按一帧预算判）；" \
              "第 3 格不是 0＝交互档被心跳期的线误判；第 7 格是 Y＝给没判过的档位盖了合规章"; return; }
  ok "判据② 的 4.0 ms 线第一次有机器读者：越线那批判 1 并点名线值、在界内判 0、" \
     "交互档明说「不参与」且不许声称过线（87）"
}
