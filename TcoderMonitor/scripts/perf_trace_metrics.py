#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""统计层与 §1 基线常量：分位数、超预算、读盘与对照表行格式。

分位数定义（与 §1 基线可比，不许悄悄换算法）：
`percentile()` 用 **int(n·p) 取整下标**（与 §1 基线脚本 `parse.py` 同一口径）。
换成分位定义 = 前后两批数字不可比 = 回归门禁失效。
Swift 侧 `Services/Performance/FramePulse.swift` 也照同一取法，两边必须一字对齐。
"""

import json
import os
import sys

from perf_trace_xml import Doc

# §1 基线常量（spec: docs/superpowers/specs/2026-09-20-performance-120hz-design.md §1）
# 取自产物 465f5a6（release、无界基座之前）——只作对照列，不参与任何判定逻辑。
BASELINE = {
    "rev": "465f5a6",
    "hitches": 7,
    "hitch_seconds": 20,
    "hitch_per_second": 0.35,
    "hitch_time_ratio_ms_per_s": 11.67,  # 工具实测（run1，20s）；Apple 危急档门限是 >10
    "hitch_frame_ms_min": 33.33,
    "hitch_frame_ms_max": 58.33,
    "app_update_ms": [10.8, 11.1, 13.2, 15.0, 16.0, 18.6, 24.8],
    "potential_hangs": 13,
    "potential_hang_median_ms": 42.6,
    "potential_hang_max_ms": 59.8,
    "potential_hang_total_ms": 573.0,
    # ⚠ 本节全部数字取自 run1（2026-09-20 15:03，release，rev 465f5a6），
    #   而 spec §1.3 已判定该样本**测量条件未受控**（当时总工正在并发跑几十个
    #   `swiftc -typecheck` 抢满 15 核 → app-update 与 hangs 被抬高）。
    #   它现在只作"同形状对照列"存在，等按 §4.1 协议重测后整块替换；
    #   在此之前，任何"从 X 降到 Y"的结论都不许引用本块当 X。
    "render_p50_ms": 2.73,
    "render_p95_ms": 4.06,     # 原记 4.05：手算漏了 <duration ref> → 见 spec §1.4
    "render_p99_ms": 4.77,     # 原记 4.67，同上
    "render_max_ms": 25.12,
    "render_over_budget_frames": 10,   # 原记 5：漏计的 54 行 ref 里正好有 5 帧
    "render_over_budget_pct": 0.42,    # 原记 0.21
    "main_thread_samples": 684,
    "main_thread_total_samples": 807,
    "main_thread_share_pct": 84.8,
    "hotspot_top1_pct": 64.3,
    "hotspot_top1": "ViewGraphRootValueUpdater._updateViewGraph",
}

FRAME_BUDGET_MS_DEFAULT = 8.333  # 120 Hz 下单帧预算，实测 Hz 不同时由 --budget-ms 覆盖


def percentile(values, p):
    """int(n·p) 下标取法——与 §1 基线脚本同口径，换算法等于换门禁。"""
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(len(ordered) * p))]


def dist_line(values):
    if not values:
        return "n=0（未采到）"
    ordered = sorted(values)
    return ("n=%d p50=%.2f p95=%.2f p99=%.2f max=%.2f ms"
            % (len(ordered), percentile(ordered, 0.5), percentile(ordered, 0.95),
               percentile(ordered, 0.99), ordered[-1]))


def over_budget(values, budget_ms):
    bad = [v for v in values if v > budget_ms]
    return len(bad), (100.0 * len(bad) / len(values) if values else 0.0)


# ----------------------------------------------------------------------------
# 落盘与对照表行格式
# ----------------------------------------------------------------------------

def read_json(path):
    if not os.path.isfile(path):
        return None
    try:
        with open(path, encoding="utf-8") as fh:
            return json.load(fh)
    except (ValueError, OSError):
        return None


def write_json(path, payload):
    parent = os.path.dirname(os.path.abspath(path))
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(payload, fh, ensure_ascii=False, indent=2)


def fmt_row(name, baseline, measured, verdict):
    print("| %-30s | %-28s | %-34s | %s |" % (name, baseline, measured, verdict))


# ----------------------------------------------------------------------------
# 一个读数的三种来源
# ----------------------------------------------------------------------------

def load_measure(d, key):
    """一个读数可以有三种来源：导出的 XML（最准）、脚本顺手写的 JSON、都没有=未覆盖。"""
    xml = os.path.join(d, key + ".xml")
    doc = None
    if os.path.isfile(xml) and os.path.getsize(xml) > 0:
        try:
            doc = Doc(xml)
        except Exception as exc:  # 导出被截断也要如实报，而不是让整张表崩
            print("!! 解析 %s 失败：%s" % (xml, exc), file=sys.stderr)
    js = read_json(os.path.join(d, key + ".json"))
    if js is not None and "_doc" in js:
        js = None
    return {"doc": doc, "json": js, "present": doc is not None or js is not None}


def dedupe_pairs(measure):
    """按 (起始, 时长) 去重后的时长列。

    hitches-updates 里一次 app update 会出两行（Brown / Red 两个 containment-level），
    不去重就打不赢 spec §1 那列"7 个值"的形状。
    """
    if measure["doc"] is not None:
        seen, out = set(), []
        for s, v in measure["doc"].spans():
            key = (round(s, 1), round(v, 2))
            if key in seen:
                continue
            seen.add(key)
            out.append(v)
        return out
    js = measure["json"]
    if js and "values" in js:
        return sorted(set(float(v) for v in js["values"]))
    return []


def fps_counts(measure):
    """displayed-surfaces-per-second → 每秒出帧数分布。"""
    if measure["doc"] is None:
        return None
    counts = []
    for row in measure["doc"].rows():
        uints = [c for c in row if c.tag == "uint32"]
        if uints:
            v = uints[0].num()
            if v is not None:
                counts.append(v)
    if not counts:
        return None
    return {"fps_p50": percentile(counts, 0.5), "fps_p95": percentile(counts, 0.95),
            "fps_min": min(counts), "fps_max": max(counts), "seconds": len(counts)}


def disp_values(measure):
    """读数的时长列（ms）。XML 优先，其次 JSON 的 values。"""
    if measure["doc"] is not None:
        return [v for _, v in measure["doc"].spans()]
    js = measure["json"]
    if js and "values" in js:
        return [float(v) for v in js["values"]]
    return []
