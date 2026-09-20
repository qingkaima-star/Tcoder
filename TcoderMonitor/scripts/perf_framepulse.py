#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`FramePulse` 落盘读数 → 帧间隔分布与判定（交互期 hitch 的唯一入口）。

## 为什么单独一层

xctrace 那三档（`idle` / `switch` / `report`）量的是**采样窗口内的历史**，
而本目标最要紧的那条——「**交互期** hitch 帧 = 0、p95 帧间隔 ≤8.4 ms」——
需要一把在 App 里面、跟着真实节拍走的尺子（spec §4 第 2 条）。
`FramePulse` 就是它，可它此前**只产数不读数**：文件写到 /tmp，没有任何东西解析。
一把没有消费者的探针等于没有探针，所以补这一层。

## 格式契约住在产品里，不住在这里

摘要行由 `Services/Performance/FramePulse.swift` 的 `makeSummaryLineLocked()` 产出。
本文件那份正则**不许**照注释手写：`PerfFramePulseRulerTests` 会拿**产品真实产出的那一行**
喂进本文件，格式一改测试就红。改 Swift 侧字段名时同步改这里。

## 三条不许含糊的规矩

1. **没人在交互就不许报「交互期达标」**：本文件判不出有没有人滚动，
   所以交互结论必须由调用方用 `--interaction` 显式声明；不声明就只能标 `idle/未确认`
   （退出码 2，与 0=达标、1=未达标/坏数据三者可区分）。
   spec §4.1 原话：两者都拿不到就明写未覆盖，不许拿 idle 档的数冒充。
2. **样本不足一律拒判**：帧数太少时 p95 毫无意义，宁可乐也不出数。
3. **预算用实测期望间隔，不硬编码 120**：`FramePulse` 自己也是运行时读 Hz（`hz=` 带来源），
   外接 60 Hz 屏时按 8.4 ms 判会把正常节拍误杀。

用法：
    python3 scripts/perf_framepulse.py <脉冲文件> [--interaction] [--min-frames 600] [--budget-ms 0]
退出码：0 达标 / 1 未达标或坏数据 / 2 读数正常但没确认交互。
"""

import argparse
import re
import sys

# 一条正则吃完整行：拆成十个独立 search 的话，「p95」这类字段名在
# 「帧间隔p95」与「心跳p95」里各出现一次，先命中哪个取决于顺序——那是个静默错数。
SUMMARY_PAT = (r"^hz=(?P<hz>[\d.]+)\((?P<source>[^)]*)\) "
               r"期望间隔=(?P<expected>[\d.]+)ms "
               r"帧数=(?P<frames>\d+) "
               r"帧间隔p50=(?P<p50>[\d.]+) p95=(?P<p95>[\d.]+) p99=(?P<p99>[\d.]+) max=(?P<max>[\d.]+)ms "
               r"hitch\(>1\.5x\)=(?P<hitch>\d+) hitch/s=(?P<hps>[\d.]+) "
               r"心跳拍数=(?P<ticks>\d+) 心跳最大间隔=(?P<hbgap>[\d.]+)ms "
               r"心跳p50=[\d.]+ p95=[\d.]+ "
               r"带hitch的拍=(?P<badticks>\d+)/(?P<allticks>\d+)")

# 相位账本行：`tick=3 frames=179 hitch=0 maxGapMs=8.4`
TICK_PAT = (r"tick=(\d+) frames=(\d+) hitch=(\d+) maxGapMs=([\d.]+)")


def parse(text):
    """→ dict（最后一条摘要行的全部字段 + 哪几拍带 hitch），解析不出摘要行则 None。

    返回 None 时调用方必须当「未采到」，**不能**当「0 帧 = 无 hitch = 达标」。
    """
    summaries = [line for line in text.splitlines() if line.startswith("hz=")]
    if not summaries:
        return None
    m = re.match(SUMMARY_PAT, summaries[-1])
    if not m:
        return None
    g = m.groupdict()
    out = {"summaries": len(summaries), "refresh_source": g["source"]}
    for key, field, as_int in (
            ("refresh_hz", "hz", False), ("expected_interval_ms", "expected", False),
            ("frame_count", "frames", True), ("frame_p50_ms", "p50", False),
            ("frame_p95_ms", "p95", False), ("frame_p99_ms", "p99", False),
            ("frame_max_ms", "max", False), ("hitch_count", "hitch", True),
            ("hitch_per_second", "hps", False), ("heartbeat_ticks", "ticks", True),
            ("heartbeat_max_gap_ms", "hbgap", False), ("ticks_with_hitch", "badticks", True),
            ("ticks_with_hitch_total", "allticks", True)):
        out[key] = int(g[field]) if as_int else float(g[field])
    out["bad_ticks"] = [(int(t[0]), int(t[2]), float(t[3]))
                        for t in re.findall(TICK_PAT, text) if int(t[2]) > 0]
    return out


def verdict(reading, interaction=False, min_frames=600, budget_ms=0.0):
    """→ (逐行文字, 退出码)。见文件头「三条不许含糊的规矩」。"""
    if reading is None:
        return (["!! 文件里没有可解析的 FramePulse 摘要行：探针没开（要 TCODER_PERF_PROBE=1）"
                 "还是格式与 `SUMMARY_PAT` 脱钩了？按未覆盖处理，不许把「没数」当成「0 hitch」。"], 1)
    frames = int(reading["frame_count"])
    budget = budget_ms or reading["expected_interval_ms"] * 1.01
    label = "交互期" if interaction else "idle/未确认交互"
    lines = ["== FramePulse 读数（%s 档）==" % label,
             "  刷新率 %.1f Hz（来源 %s）期望间隔 %.2f ms → 判定预算 %.2f ms"
             % (reading["refresh_hz"], reading["refresh_source"],
                reading["expected_interval_ms"], budget),
             "  摘要行数 %d 帧数 %d 帧间隔 p50 %.2f / **p95 %.2f** / p99 %.2f / max %.2f ms"
             % (reading["summaries"], frames, reading["frame_p50_ms"], reading["frame_p95_ms"],
                reading["frame_p99_ms"], reading["frame_max_ms"]),
             "  hitch(>1.5x) %d 次（%.2f /s）落在 %d/%d 拍；心跳最大间隔 %.1f ms"
             % (reading["hitch_count"], reading["hitch_per_second"],
                reading["ticks_with_hitch"], reading["ticks_with_hitch_total"],
                reading["heartbeat_max_gap_ms"])]
    if reading["bad_ticks"]:
        head = ", ".join("tick%d(hitch=%d,maxGap=%.1fms)" % t for t in reading["bad_ticks"][:8])
        lines.append("  带 hitch 的拍：%s%s" % (head, " …" if len(reading["bad_ticks"]) > 8 else ""))
    if frames < min_frames:
        lines.append("  判定：**拒判**——只有 %d 帧（<%d），这点样本量算 p95 没有意义" % (frames, min_frames))
        return lines, 1
    ok = reading["hitch_count"] == 0 and reading["frame_p95_ms"] <= budget
    lines.append("  判定：%s（T1 要的是交互期 hitch=0 且 p95 ≤ 预算 %.2f ms）"
                 % ("达标" if ok else "未达标", budget))
    if not interaction:
        lines.append("  ⚠ 本行只算 idle 读数：测量窗口内没有确认有人滚动/拖窗，"
                     "不得写进「交互期 hitch = 0」的结论。要判 T1 请带 --interaction 重跑。")
        return lines, 2 if ok else 1
    return lines, 0 if ok else 1


def main(argv=None):
    p = argparse.ArgumentParser(description="FramePulse 落盘文件 → 帧间隔判定")
    p.add_argument("pulse_file")
    p.add_argument("--interaction", action="store_true",
                   help="声明测量窗口内确实在交互（滚动/拖窗）；不声明则只算 idle 读数")
    p.add_argument("--min-frames", type=int, default=600)
    p.add_argument("--budget-ms", type=float, default=0.0)
    args = p.parse_args(argv)
    try:
        with open(args.pulse_file, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print("!! 读不到 %s（%s）" % (args.pulse_file, exc), file=sys.stderr)
        return 1
    lines, code = verdict(parse(text), interaction=args.interaction,
                          min_frames=args.min_frames, budget_ms=args.budget_ms)
    print("\n".join(lines))
    return code


if __name__ == "__main__":
    sys.exit(main())
