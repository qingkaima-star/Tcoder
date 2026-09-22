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
import json
import os
import re
import subprocess
import sys

# 出帧那一半的解析**不在这里重写**：`trace_report.py` 的 `fps` / `displays` 两个子命令
# 已经是全仓唯一吃这两张表的尺子，复制一份就是造第二把尺子（两把迟早分叉）。
XCTRACE_RULER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trace_report.py")

# 一条正则吃完整行：拆成十个独立 search 的话，「p95」这类字段名在
# 「帧间隔p95」与「心跳p95」里各出现一次，先命中哪个取决于顺序——那是个静默错数。
# 【这一条被"两层失配"掩护了很久】source 组原来写的是 `[^)]*`，
# 而生产者在 2026-09 起把取数来源写成 `hz=120.0(CGDisplayCopyDisplayMode(current))`
# ——**里面还有一层括号**，`[^)]*` 停在第一个 `)` 上，后面的 ` 期望间隔=` 就对不上了。
# 为什么长期没人发现：自动化里根本没有一处设过 `TCODER_PERF_PROBE=1`（`open` 也不传 env），
# 于是"探针产物不存在"永远先挡住这条路径，解析器的断裂露不出来。
# ⇒ 一条仪器要**两端都验**：能起、且起得来的东西读得懂。现在改成吃到最后一个 `)`，
#   末尾的 ` 期望间隔=` 就是天然锚点，不需要非贪婪技巧。
SUMMARY_PAT = (r"^hz=(?P<hz>[\d.]+)\((?P<source>.*)\) "
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


def read_display_pair(sample_dir):
    """→ (设备最大 Hz, 上屏 p50/s, 上屏 p95/s, 采样秒数)；取不到的那一项是 None。

    只调 `trace_report.py` 的两个子命令。缺表就是 None，**不许**把它当 0——
    "上屏 0 帧/秒"会被下游读成"掉帧掉光了"，而真相是"这张表没导出"。
    """
    def _run(sub, xml):
        path = os.path.join(sample_dir, xml)
        if not os.path.exists(path):
            return ""
        try:
            r = subprocess.run([sys.executable, XCTRACE_RULER, sub, path],
                               capture_output=True, text=True, timeout=60)
        except (OSError, subprocess.SubprocessError):
            return ""
        return r.stdout if r.returncode == 0 else ""
    disp = _run("displays", "device-display-info.xml")
    fps = _run("fps", "displayed-surfaces-per-second.xml")
    hz = re.search(r"最大刷新率=(\d+)", disp)
    sp = re.search(r"p50=([\d.]+) p95=([\d.]+)", fps)
    n = re.search(r"采样秒数=(\d+)", fps)
    return (float(hz.group(1)) if hz else None,
            float(sp.group(1)) if sp else None,
            float(sp.group(2)) if sp else None,
            int(n.group(1)) if n else None)


def crosscheck(reading, budget, max_hz, surf_p50, surf_p95, seconds, meta):
    """同一窗口里两把尺子的合判（工单 §M：p95 那半句到底算不算掉帧）→ (逐行文字, 退出码)。

    为什么必须有这一层：`FramePulse` 读的是 **CVDisplayLink 回调送达时刻**，不等于"上屏时刻"。
    实测过一批三趟：p50 恰好 8.33（＝一个周期）而 p95 落在 8.98~9.26 ⇒
    **有一大片帧比一个周期晚了约 1 ms**。这 1 ms 是在回调时序上还是在呈现上，
    单靠脉冲这把尺子问不出来；两种解释都给"p95>8.41"这个同一个数，结论却相反。
    退出码：0 两侧一致且都在预算内 / 1 缺件或上屏侧也缺帧 / 2 不适用或两把尺子互相矛盾。
    """
    lines = ["== 同窗交叉核对（CVDisplayLink 回调 vs 真实上屏）=="]
    period = str((meta or {}).get("period") or "").strip()
    if reading is None:
        lines.append("  这一趟没有同窗脉冲（attach 模式下被测实例没开探针）⇒ p95 那半句**不判**。")
        return lines, 1
    if max_hz is None or surf_p50 is None:
        lines.append("  xctrace 那一半缺表（`device-display-info` / `displayed-surfaces-per-second`）"
                     "⇒ 不判：两把尺子只剩一把的时候，谁都不许单独宣布达标或未达标。")
        return lines, 1
    if period != "interaction":
        lines.append("  这一趟 period=%s ⇒ **不适用**：空闲期本来就只出约 10 帧/秒"
                     "（实测 idle 样本 `displayed-surfaces/s p50=10.00`），"
                     "拿「上屏没跟满」去判掉帧会把正常空闲误杀成卡顿。" % period)
        return lines, 2
    kept = surf_p50 >= 0.9 * max_hz
    over = reading["frame_p95_ms"] > budget
    lines.append("  脉冲 p50 %.2f / p95 %.2f ms（期望 %.2f，预算 %.2f）→ 超出 %.2f ms；"
                 "上屏 p50 %.1f / p95 %.1f 帧每秒，设备 %.0f Hz，采样 %s 秒"
                 % (reading["frame_p50_ms"], reading["frame_p95_ms"],
                    reading["expected_interval_ms"], budget,
                    reading["frame_p95_ms"] - reading["expected_interval_ms"],
                    surf_p50, surf_p95, max_hz, seconds))
    if not over and kept:
        lines.append("  合判：**两侧一致**——上屏跟到了 %.0f 帧每秒（≥0.9×%.0f），脉冲也没越预算。"
                     % (surf_p50, max_hz))
        return lines, 0
    if not over and not kept:
        lines.append("  合判：**两把尺子互相矛盾**（脉冲说没越预算，上屏却只出 %.1f 帧每秒）"
                     "⇒ 很可能是这段窗口根本没在重绘（页面不可滚？指针没落在被测窗口上？）。不判。" % surf_p50)
        return lines, 2
    if kept:
        lines.append("  合判：上屏跟满了（%.1f 帧每秒 ≈ %.0f Hz），所以那 %.2f ms 的尾巴**在回调时序上，不是掉帧**。"
                     % (surf_p50, max_hz, reading["frame_p95_ms"] - reading["expected_interval_ms"]))
        lines.append("  ⇒ 但**不许**据此宣布 p95 达标：要把这 %.2f ms 从读数里扣掉，得先单独量出回调送达"
                     "与上屏之间的系统性偏移（工单 §M 要的就是这一步）。在它量出来之前，"
                     "这句话只能写成「无一帧晚到 1.5× 周期；p95 待时序标定」。"
                     % (reading["frame_p95_ms"] - reading["expected_interval_ms"]))
        return lines, 2
    lines.append("  合判：上屏侧也只有 %.1f 帧每秒（< 0.9×%.0f）⇒ **呈现真的缺帧**，未达标。"
                 % (surf_p50, max_hz))
    return lines, 1


def main(argv=None):
    p = argparse.ArgumentParser(description="FramePulse 落盘文件 → 帧间隔判定（＋同窗上屏交叉核对）")
    p.add_argument("pulse_file", nargs="?", default="",
                   help="脉冲文件；带 --sample-dir 时可省，默认取该目录下的 pulse.txt")
    p.add_argument("--sample-dir", default="",
                   help="一趟样本目录：从里面同时读 pulse.txt、meta.json 与两张 xctrace 表，做交叉核对")
    p.add_argument("--interaction", action="store_true",
                   help="声明测量窗口内确实在交互（滚动/拖窗）；不声明则只算 idle 读数")
    p.add_argument("--min-frames", type=int, default=600)
    p.add_argument("--budget-ms", type=float, default=0.0)
    args = p.parse_args(argv)
    pulse = args.pulse_file or (os.path.join(args.sample_dir, "pulse.txt") if args.sample_dir else "")
    if not pulse:
        p.error("既没给脉冲文件也没给 --sample-dir ⇒ 不知道要读谁（故意不猜）")
    try:
        with open(pulse, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        print("!! 读不到 %s（%s）" % (pulse, exc), file=sys.stderr)
        return 1
    reading = parse(text)
    budget = args.budget_ms or (reading["expected_interval_ms"] * 1.01 if reading else 0.0)
    lines, code = verdict(reading, interaction=args.interaction,
                          min_frames=args.min_frames, budget_ms=args.budget_ms)
    if args.sample_dir:
        meta = {}
        try:
            with open(os.path.join(args.sample_dir, "meta.json"), encoding="utf-8") as fh:
                meta = json.load(fh)
        except (OSError, ValueError) as exc:
            print("  ⚠ meta.json 读不到（%s）⇒ 档位声明无从确认，交叉核对按缺件处理" % exc)
        clines, ccode = crosscheck(reading, budget, *read_display_pair(args.sample_dir), meta=meta)
        lines += clines
        # 合判的码优先：脉冲自己"达标"不算数，要看另一把尺子点不点头。
        code = ccode if frames_ok(code) else code
    print("\n".join(lines))
    return code


def frames_ok(code):
    """脉冲那一半只有 0/2 才有资格让合判覆盖它（1 = 坏数据/样本不足，本来就没什么可覆盖的）。"""
    return code in (0, 2)


if __name__ == "__main__":
    sys.exit(main())
