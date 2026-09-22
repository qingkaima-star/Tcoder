#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""同一档位连测几趟之后，**取值到底一致不一致**（spec §1.3 的那半句，此前没人量）。

## 为什么现在才有这支尺子

§1.3 的协议是「连测 ≥3 趟**且取值一致**」。可此前所有排程器数的都是
"结构性可用的样本数"（产物齐 + 没被 REFUSED + 收尾复核没打回），
于是 2026-09-23 02:35 这一幕是**绿灯着发生的**：

    [interact] rc=0 ⇒ 可用 3/3 趟        ← 三趟都"可用"
    hitch/s   run1 1.20  run2 1.30  run3 18.80    ← 15 倍的散布

三趟同头、同产物、六维上下文逐条合格（load 6.6~10.5 / 15 核，并发重活=无，
静默 239~5028 s），可第 3 趟的 hitch 数是前两趟的 14 倍。
"可用 3/3"这句话在当时的口径下**是真的**，但它被读成了"协议满足"——
而协议要求的那一半（取值一致）从来没被量过。
⇒ 数样本不等于量一致性。这把尺子补的就是那半句。

## 三条规矩

1. **缺件判不判，不判 0**：某一趟没有 `hitches.xml` 就是"未采到"，
   按 `2`（未采到）退出，绝不参与散布计算——否则"少一趟"会被算成"这趟 hitch=0 ⇒ 很稳"。
2. **散布用极差比，且必须把上限印出来**：`max/min`。
   阈值 2.0 是**保守方向**（真实抖动能到 15 倍，见上），写在这里是为了
   下一个想让它绿的人看得见自己在动哪颗螺丝（本仓红线：不许为了好看放宽阈值）。
3. **出帧那一维一起看**：hitch/s 一致但 `displayed-surfaces p50` 差出 10 帧/s 以上，
   也判不一致——两把尺子说的不是同一件事时，不许挑好听的那条报。

用法：
    python3 scripts/perf_trio_agreement.py <run 目录> [<run 目录> …] [--budget-ms 8.333]
退出码：0 一致 / 1 不一致 / 2 样本不足或有缺件（不足时**不许**报"3/3 达标"）。
"""

import argparse
import json
import os
import sys

from perf_trace_metrics import disp_values, fps_counts, percentile
from perf_trace_summary import period_eligibility, summary_load

SPREAD_BAR = 2.0          # hitch/s 极差比上限（保守）
FPS_SPREAD_BAR = 10.0     # 出帧 p50 极差上限（帧/s）


def _seconds(meta):
    for key in ("hitches_seconds", "seconds", "seconds_hitches"):
        v = meta.get(key)
        try:
            if v and float(v) > 0:
                return float(v)
        except (TypeError, ValueError):
            continue
    return 0.0


def read_run(d):
    """一个 run 目录 → dict；读不到 hitch 表 / 没有秒数 / 档位复核不合格 ⇒ None。

    取数一律走 `summary_load`（与报表同一把尺），**不在这里再解析一遍 XML**：
    同一个问题上多一把尺，两把量错的时候没人怀疑新那把。
    """
    if not os.path.isfile(os.path.join(d, "meta.json")):
        return None
    try:
        meta = json.load(open(os.path.join(d, "meta.json"), encoding="utf-8"))
    except (ValueError, OSError):
        return None
    ok, _why = period_eligibility(meta)
    if not ok:                                   # 被收尾复核打回的样本，不参与一致性判定
        return None
    secs = _seconds(meta)
    loaded = summary_load(d)
    if secs <= 0 or not loaded["hitches"]["present"]:
        return None
    late = [v for v in disp_values(loaded["hitches"]) if v is not None]
    rends = [v for v in disp_values(loaded["hitches-renders"]) if v is not None]
    fps = loaded["displayed-surfaces-per-second"]["json"] or fps_counts(loaded["displayed-surfaces-per-second"])
    return {"dir": os.path.basename(d.rstrip("/")), "seconds": secs,
            "hitch_n": len(late), "hitch_per_s": len(late) / secs,
            "period": str(meta.get("period") or "?"),
            "render_p50_ms": percentile(rends, .5) if rends else None,
            "surfaces_p50_fps": (float(fps["fps_p50"]) if fps and fps.get("fps_p50") else None)}


def verdict(runs, dirs):
    """→ (逐行文字, 退出码)。缺件与不足都**不许**伪装成"一致"。"""
    if not runs:
        return ["!! 一个 run 目录都没给 ⇒ 这支尺子没被喂过数据，别把「没输出」当「通过」"], 2
    got = [r for r in runs if r]
    missing = [os.path.basename(str(d).rstrip("/")) for d, r in zip(dirs, runs) if not r]
    lines = ["== 同档连测的一致性（协议：≥3 趟 **且取值一致**）=="]
    for r in got:
        lines.append("   %-44s 档=%-11s %5.1fs  hitch %4d ⇒ %5.2f /s   render p50 %s  出帧 p50 %s"
                     % (r["dir"], r["period"], r["seconds"], r["hitch_n"], r["hitch_per_s"],
                        ("%.2f ms" % r["render_p50_ms"]) if r.get("render_p50_ms") else "—",
                        ("%.0f/s" % r["surfaces_p50_fps"]) if r.get("surfaces_p50_fps") else "—"))
    if missing:
        lines.append("   缺件/读不出：%s ⇒ **不判**（缺的那趟不许当 hitch=0）" % ", ".join(missing))
    if len(got) < 3:
        lines.append("   判定：**样本不足**（只有 %d 趟可用，协议要 ≥3）⇒ 不许报「3/3 达标」" % len(got))
        return lines, 2
    rates = [r["hitch_per_s"] for r in got]
    lo, hi = min(rates), max(rates)
    floor = max(lo, 1.0 / max(r["seconds"] for r in got))   # 0/0：下界兜到"一趟里连一个事件都没有"
    spread = hi / floor
    lines.append("   hitch/s 现量 %.2f ~ %.2f ⇒ 极差比 %.1f×（上限 %.1f×）"
                 % (lo, hi, spread, SPREAD_BAR))
    bad = [] if spread <= SPREAD_BAR else ["hitch/s 极差比 %.1f× > %.1f×" % (spread, SPREAD_BAR)]
    fps = [r["surfaces_p50_fps"] for r in got if r.get("surfaces_p50_fps")]
    if len(fps) >= 2 and (max(fps) - min(fps)) > FPS_SPREAD_BAR:
        bad.append("出帧 p50 极差 %.0f 帧/s > %.0f" % (max(fps) - min(fps), FPS_SPREAD_BAR))
    if len(got) > len(fps):
        bad.append("有 %d 趟没采到出帧表 ⇒ 第二把尺子没对齐，不许只凭 hitch 数判一致"
                   % (len(got) - len(fps)))
    if bad:
        lines.append("   判定：**不一致** —— " + "；".join(bad))
        lines.append("   ⇒ 这一档**不能**报「3/3 达标」。要么继续加趟直到有一组取值一致，"
                     "要么按 spec §1.3 明写「受控重复未满足」。")
        return lines, 1
    lines.append("   判定：一致（两把尺子都在带宽内）。中位 hitch/s %.2f ⇒ 报数时**报中位与范围**，不报均值"
                 % sorted(rates)[len(rates) // 2])
    return lines, 0


def main(argv=None):
    ap = argparse.ArgumentParser(description="同档连测的取值一致性（spec §1.3 那半句）")
    ap.add_argument("runs", nargs="*", help="run 目录（.scratch/tcoder-perf-<rev>-<档>-runN）")
    args = ap.parse_args(argv)
    dirs = [a for a in args.runs if not a.startswith("--")]
    lines, code = verdict([read_run(d) for d in dirs], dirs)
    print("\n".join(lines))
    return code


if __name__ == "__main__":
    sys.exit(main())
