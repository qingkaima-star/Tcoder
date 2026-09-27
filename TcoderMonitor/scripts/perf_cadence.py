#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""呈现侧节拍（cadence）—— 把「p95 帧间隔 ≤8.4 ms」这半句量准。

## 为什么要有这个文件（2026-09-22 22:55 实测）

`FramePulse` 读的是 **CVDisplayLink 回调送达时刻**，而回调送达比真正上屏系统性偏晚：
同一窗口里两把仪器对同一个物理量给出
`p50 8.33 / p95 9.17`（回调）与 `p50 8.34 / p95 8.51`（合成器逐帧起点差）
⇒ 尾巴里 **0.66 ms 是仪器偏移**，不是帧晚了。工单 §M 要的就是把这个数量出来，
量出来之后才发现第二个问题：

**名义 120 Hz 与实际 vsync 周期不是一回事。** 用合成器自己的时间线反算
（总跨度 ÷ 间隔数）得到 **8.360~8.367 ms ⇒ 119.52~119.62 Hz**，
而 App 里 `CGDisplayCopyDisplayMode(current)` 报的是 `120.0 Hz`（名义值）。
于是"预算 8.41 ms"天生比真实周期的 1.01 倍小 0.4%，
p95 落在 8.51 ms 就"永远未达标"——**空闲档量出来也是 8.519 ms**，与交互档只差 0.013 ms。

⇒ 这个文件因此**同时打印两个预算**（名义与实测温漂），谁都不许只留一个：
只按名义报，会把仪器的时间基误差算成 App 的卡顿；
只按实测报，就是**为了让数字好看而换尺子**（AGENTS 明令禁止）。
两把一起印，剩下的是需求方的口径决定，不是测量方能偷偷做的决定。

用法：
    python3 scripts/perf_cadence.py <hitches-renders.xml> [--pulse <脉冲文件>] [--json 输出]
退出码：0 两台仪器都在各自预算内 / 1 有超出的 / 2 数据不足或两把仪器互相矛盾
"""

import argparse
import io
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_trace_xml import Doc                        # noqa: E402
from perf_framepulse import parse as parse_pulse, stale_instance      # noqa: E402

NOMINAL_HZ = 120.0
SLACK = 1.01                                          # 与 FramePulse 同一条：预算 = 周期 × 1.01


def deltas(path):
    """→ (间隔列表 ms, 帧数, 跨度 ms)。表里的 start/duration 单位就是 ms。"""
    starts = sorted(s for s, _ in Doc(path).spans())
    gaps = [b - a for a, b in zip(starts, starts[1:]) if b > a]
    return gaps, len(starts), (starts[-1] - starts[0] if len(starts) > 1 else 0.0)


def pct(values, q):
    v = sorted(values)
    k = (len(v) - 1) * q
    lo = int(k)
    hi = min(lo + 1, len(v) - 1)
    return v[lo] + (v[hi] - v[lo]) * (k - lo)


def budgets(measured_period_ms):
    """两个预算一起给——**故意不让调用方选**。"""
    return {"nominal": round(1000.0 / NOMINAL_HZ * SLACK, 3),
            "measured": round(measured_period_ms * SLACK, 3)}


def report(path, pulse_path=None, min_frames=1200):
    gaps, frames, span = deltas(path)
    lines = ["== 呈现侧节拍（合成器逐帧起点差；单位 ms）=="]
    if frames < min_frames or not gaps:
        lines.append("  只有 %d 帧 ⇒ 拒判（样本不足时 p95 没有意义，min=%d）" % (frames, min_frames))
        return lines, 2
    period = span / (len(gaps))
    bud = budgets(period)
    p95 = pct(gaps, 0.95)
    lines.append("  帧 %d 个  跨度 %.0f ms  ⇒ **实测均匀周期 %.4f ms ≈ %.3f Hz**"
                 "（名义 %.1f Hz，差 %+.2f%%）"
                 % (frames, span, period, 1000.0 / period, NOMINAL_HZ,
                    (1000.0 / period - NOMINAL_HZ) / NOMINAL_HZ * 100.0))
    lines.append("  间隔 p50 %.2f / **p95 %.2f** / p99 %.2f / max %.2f  标准差 %.3f"
                 % (pct(gaps, .5), p95, pct(gaps, .99), max(gaps),
                    (sum((x - sum(gaps) / len(gaps)) ** 2 for x in gaps) / len(gaps)) ** .5))
    one_half = period * 1.5
    n_gap = sum(1 for x in gaps if x > one_half)
    lines.append("  呈现缺口(起点间隔 >1.5×实测周期 %.2f ms) %d 个 ⇒ %.2f /s；"
                 "**注意这不是 hitch 数**（空闲档没有新内容也算缺口）"
                 % (one_half, n_gap, n_gap / (span / 1000.0)))
    hk = hitches_count(path)
    lines.append("  权威 hitch 数（同目录 `hitches.xml`）：%s"
                 % ("%d 个 ⇒ %.2f /s" % (hk, hk / (span / 1000.0)) if hk is not None else "表不在，不知道"))
    code = 0
    for name, b in bud.items():
        ok = p95 <= b
        code = code if ok else 1
        lines.append("  按%s预算 %.3f ms：p95 %s%s"
                     % ("名义(120Hz)" if name == "nominal" else "实测周期",
                        b, "达标" if ok else "**未达标**",
                        "" if ok else "（超 %.3f ms）" % (p95 - b)))
    if pulse_path and os.path.exists(pulse_path):
        plines, pcode = pulse_crosscheck(pulse_path, gaps, p95, span, bud)
        lines += plines
        if pcode is not None:
            code = pcode
    return lines, code


VERDICT_MARKS = ("按名义", "按实测周期", "权威 hitch 数")


def write_verdict(path, lines, code):
    """把判定那几行**逐字**另落一份文件（#123：判定此前只活在 stdout 的尾巴里）。

    取行按标记，不按行号——行号会随脉冲有无漂移；标记是这些话术自己的名字。
    末行带退出码，读者不必再猜"没印"是"没判"还是"判了没输"。
    """
    keep = [l.strip() for l in lines if any(m in l for m in VERDICT_MARKS)]
    with io.open(path, "w", encoding="utf-8") as fh:
        for line in (keep or ["未采到（节拍尺没给出判定行 ⇒ 帧间隔 p95 这一维当前答不了）"]):
            fh.write(line + "\n")
        fh.write("退出码 %d\n" % code)


def pulse_crosscheck(pulse_path, gaps, p95, span, bud):
    """回调仪器那一侧的交叉核对 → (追加的行, 退出码或 None)。

    从 `report` 里搬出来只因为 `report` 过了「函数 ≤ 50 行」那条尺（第十二次落到这张名单上）。
    **判定、话术、顺序逐字未动**：拆前拆后拿同一批真产物跑五格、输出逐字 diff 为空。
    返回 `None` 表示"这一路不改退出码"——原来那条 `code = 2` 只在读不出摘要行时发生。
    """
    lines = []
    r = parse_pulse(open(pulse_path, encoding="utf-8", errors="replace").read())
    code = None
    if r:
        bias = r["frame_p95_ms"] - p95
        # 「同窗」这两个字我说过一次假的：摘要里的帧总数是**生命期累计**，
        # 而本表只覆盖录制窗口。判据不自己写，走 `perf_framepulse.stale_instance`。
        if stale_instance(r, span / 1000.0):
            lines.append("  同一实例 FramePulse：p50 %.2f / p95 %.2f ms，但那是**生命期累计 %d 帧**"
                         "（本窗口只有 %.0f s ≈ %d 帧）⇒ 这个 %+.2f ms 的差值"
                         "**不是同窗对比，§M 的偏移量按未定处理**"
                         % (r["frame_p50_ms"], r["frame_p95_ms"], int(r["frame_count"]),
                            span / 1000.0, int(r["refresh_hz"] * span / 1000.0), bias))
        else:
            lines.append("  同窗 FramePulse：p50 %.2f / p95 %.2f ms ⇒ **回调 − 上屏 = %+.2f ms**"
                         "（这才是 §M 要的那个系统性偏移，p50 差 %+.2f ms）"
                         % (r["frame_p50_ms"], r["frame_p95_ms"], bias,
                            r["frame_p50_ms"] - pct(gaps, .5)))
        if abs(bias) > 1.0 and p95 <= bud["measured"]:
            lines.append("  ⇒ 注意：脉冲那把尺子越预算，主要来自仪器偏移而非呈现延迟；"
                         "**但这条不能单独当结论**（两台仪器同源于显示器时钟时才可比）。")
    else:
        lines.append("  ⚠ 脉冲文件读不出摘要行 ⇒ 只有一把仪器，交叉核对**没做成**")
        code = 2
    return lines, code


def hitches_count(path):
    """同目录 `hitches.xml` 的权威 hitch 条数；表不在/读不动 ⇒ None（**不许当 0**）。"""
    xml = os.path.join(os.path.dirname(path), "hitches.xml")
    if not os.path.exists(xml):
        return None
    try:
        return len(Doc(xml).spans())
    except Exception:                      # 表形状变了宁可说"不知道"，不要给一个 0
        return None


def stats_of(path, min_frames=1200):
    """单份样本的节拍统计；帧数不足或读不动 ⇒ None（**不许当 0**）。

    ⚠ `gap_rate`（呈现缺口率）**不等于 hitch 数**：空闲档"这一帧没有新内容"是正常的，
    可它的起点间隔照样 >1.5×周期 ⇒ 会被这条算进去（实测空闲三趟 xctrace `hitches` 是 19/0/0，
    而呈现缺口率一律 ~0.86 /s）。所以两个数并排印，相对判据用缺口率时必须带着这个说明——
    否则下一个人会拿它当"卡顿次数"去和 §1 的基线比。
    """
    gaps, frames, span = deltas(path)
    if frames < min_frames or not gaps or span <= 0:
        return None
    p50 = pct(gaps, .5)
    seconds = span / 1000.0
    return {"frames": frames, "span_s": seconds, "p50": p50, "p95": pct(gaps, .95),
            "p99": pct(gaps, .99), "gap_rate": sum(1 for x in gaps if x > p50 * 1.5) / seconds,
            "hitches": hitches_count(path)}


def against_baseline(cur_xml, base_csv):
    """相对地板判据（需求方 2026-09-22 23:20 裁定）。→ (逐行文字, 退出码)。

    为什么换成相对：**实测面板节拍是 119.33~119.39 Hz，不是名义 120.000**，
    于是"p95 ≤ 8.41 ms"在空闲档也做不到（实测空闲 p95 8.52 / 交互 8.51）
    ——那条绝对判据量的是面板与仪器地板，不是 App。
    裁定内容（三条一起用，一条都不许省）：
      ① 交互档**不得劣于**空闲档基线：p95 与晚到帧率**两项都要**不劣于；
      ② 晚到帧(>1.5×实测周期) 的绝对计数继续往下压，"不劣于"不等于"够了"；
      ③ 名义 8.4 ms 那一栏**照旧并报**"未达标（超 X ms）"，换成相对判据不许让它消失。

    【基线必须一次给多份，并给一条噪声带】第一版只比一份基线，23:36 实测当场翻车：
    拿 idle run1 当基线判"不劣于"（-0.013 ms），换 idle run3 判"劣于"（+0.006 ms）
    ——**换一份基线结论就反**，这种判据等于掷硬币。所以这里改成：
    多份基线取**中位数**，并且差值小于"基线自身的散布"时判**分不开**（既不达标也不未达标）。
    退出码：0 不劣于 / 1 劣于 / 2 数据不足或分不开。
    """
    paths = [p for p in base_csv.split(",") if p.strip()]
    cur = stats_of(cur_xml)
    bases = [s for s in (stats_of(p) for p in paths) if s]
    lines = ["== 相对地板判据（对照空闲档基线：中位数 + 噪声带）=="]
    if not cur or len(bases) < 2:
        lines.append("  需要 ≥2 份空闲档基线（拿到 %d 份可用）与一份够帧数的交互档 ⇒ **不判**；"
                     "「没判」不许被读成「过了」" % len(bases))
        return lines, 2
    bp95 = [b["p95"] for b in bases]
    blate = [b["gap_rate"] for b in bases]
    m95, b95, mlate, blate_band = baseline_band(bp95, blate)
    d95, dlate = cur["p95"] - m95, cur["gap_rate"] - mlate
    lines.append("  基线 %d 份：p95 中位 %.3f（散布 %.3f）  呈现缺口率中位 %.2f /s（散布 %.2f）"
                 % (len(bases), m95, b95, mlate, blate_band))
    lines.append("  交互档：p95 %.3f ⇒ %+0.3f ms   呈现缺口率 %.2f /s ⇒ %+0.2f /s"
                 % (cur["p95"], d95, cur["gap_rate"], dlate))

    a95, c95 = one_item(d95, b95)
    alate, clate = one_item(dlate, blate_band)
    lines.append("  两项判定：p95 %s（带宽 ±%.3f ms）  呈现缺口率 %s（带宽 ±%.2f /s）"
                 % (a95, b95, alate, blate_band))
    code = 1 if 1 in (c95, clate) else (2 if 2 in (c95, clate) else 0)
    verdict = {0: "**不劣于基线**（绝对计数仍要继续压：见上 ②）",
               1: "**劣于基线 ⇒ 未达标**",
               2: "**与基线分不开** ⇒ 这条判据当前答不了，加趟数或先压噪声，不许选一 favourable 的说法"}
    lines.append("  裁定口径下的结论：%s" % verdict[code])
    lines.append("  ③ 名义 8.4 ms 那一栏在上面的绝对判据里照旧报，不随本条改口而消失。")
    return lines, code


def baseline_band(bp95, blate):
    """多份基线 → (p95 中位, p95 散布, 缺口率中位, 缺口率散布)。纯算术，不印东西。"""
    return (pct(bp95, .5), max(bp95) - min(bp95),
            pct(blate, .5), max(blate) - min(blate))


def one_item(d, band):
    """一项差值的三态判定 → (话术, 退出码)。带宽就是基线自身的散布（见上面的教训）。"""
    if d > 0 and d > band:
        return "劣", 1
    if abs(d) <= band:
        return "分不开", 2
    return "不劣", 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="呈现侧节拍：实测周期 + 两把预算 + 与回调仪器的偏移 + 相对地板判据")
    ap.add_argument("xml")
    ap.add_argument("--pulse", default="")
    ap.add_argument("--baseline", default="",
                    help="同一次测量里的空闲档 hitches-renders.xml；给了就按相对地板判据下结论")
    ap.add_argument("--min-frames", type=int, default=1200)
    ap.add_argument("--verdict-out", default="",
                    help="把判定那几行另落一份文件（#123：判据① 的持久读者；stdout 一字不动）")
    args = ap.parse_args(argv)
    lines, code = report(args.xml, args.pulse or None, args.min_frames)
    if args.baseline:
        blines, bcode = against_baseline(args.xml, args.baseline)
        lines += blines
        code = bcode if code in (0, 1) else code     # 数据不足优先按"不足"报，不被相对判据盖掉
    print("\n".join(lines))
    if args.verdict_out:
        write_verdict(args.verdict_out, lines, code)
    return code


if __name__ == "__main__":
    sys.exit(main())
