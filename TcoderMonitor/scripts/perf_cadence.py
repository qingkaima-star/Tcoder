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
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from perf_trace_xml import Doc                        # noqa: E402
from perf_framepulse import parse as parse_pulse      # noqa: E402

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
    lines.append("  晚到帧(>1.5×实测周期 %.2f ms) %d 个 ⇒ %.2f 帧每秒"
                 % (one_half, sum(1 for x in gaps if x > one_half),
                    sum(1 for x in gaps if x > one_half) / (span / 1000.0)))
    code = 0
    for name, b in bud.items():
        ok = p95 <= b
        code = code if ok else 1
        lines.append("  按%s预算 %.3f ms：p95 %s%s"
                     % ("名义(120Hz)" if name == "nominal" else "实测周期",
                        b, "达标" if ok else "**未达标**",
                        "" if ok else "（超 %.3f ms）" % (p95 - b)))
    if pulse_path and os.path.exists(pulse_path):
        r = parse_pulse(open(pulse_path, encoding="utf-8", errors="replace").read())
        if r:
            bias = r["frame_p95_ms"] - p95
            lines.append("  同窗 FramePulse：p50 %.2f / p95 %.2f ms ⇒ **回调 − 上屏 = %+.2f ms**"
                         "（这就是 §M 要的那个系统性偏移，p50 差 %+.2f ms）"
                         % (r["frame_p50_ms"], r["frame_p95_ms"], bias,
                            r["frame_p50_ms"] - pct(gaps, .5)))
            if abs(bias) > 1.0 and p95 <= bud["measured"]:
                lines.append("  ⇒ 注意：脉冲那把尺子越预算，主要来自仪器偏移而非呈现延迟；"
                             "**但这条不能单独当结论**（两台仪器同源于显示器时钟时才可比）。")
        else:
            lines.append("  ⚠ 脉冲文件读不出摘要行 ⇒ 只有一把仪器，交叉核对**没做成**")
            code = 2
    return lines, code


def main(argv=None):
    ap = argparse.ArgumentParser(description="呈现侧节拍：实测周期 + 两个预算 + 与回调仪器的偏移")
    ap.add_argument("xml")
    ap.add_argument("--pulse", default="")
    ap.add_argument("--min-frames", type=int, default=1200)
    args = ap.parse_args(argv)
    lines, code = report(args.xml, args.pulse or None, args.min_frames)
    print("\n".join(lines))
    return code


if __name__ == "__main__":
    sys.exit(main())
