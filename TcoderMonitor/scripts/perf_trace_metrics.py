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
    # 分母：spec §1 明写这一行是 **2394 帧**（20 s 窗口 ≈ 120 fps 连出帧）。
    # 缺了它，"0.42% vs 4.97%" 就看着像恶化 12 倍，而两边帧数其实是 10 vs 9。
    "render_total_frames": 2394,
    # §1.3 的结论写在这里而不是只写在注释里：这一整块**取自未受控样本**
    # （当时并发几十个 `swiftc -typecheck` 抢满 15 核），按 §4.1 重测前
    # 只许当"同形状对照列"。判定列因此不许输出"改善/回退"这类从 X 到 Y 的话。
    "controlled": False,
    "uncontrolled_reason": "spec §1.3：run1 采在总工并发几十个 swiftc 抢满 15 核期间",
    "main_thread_samples": 684,
    "main_thread_total_samples": 807,
    "main_thread_share_pct": 84.8,
    "hotspot_top1_pct": 64.3,
    "hotspot_top1": "ViewGraphRootValueUpdater._updateViewGraph",
}


# ----------------------------------------------------------------------------
# 对照列的文字：由 BASELINE **生成**，不许在行里再手抄一遍数字
# ----------------------------------------------------------------------------
# 为什么要生成：§1 那一栏的数字被更正过一整轮（4.05→4.06、4.67→4.77、5 帧→10 帧、
# 0.21%→0.42%，见 spec §1.4），而当时**同一批数字在汇总表里还被手抄成字符串字面量**。
# 手抄那份不会跟着字典走——下一次 §1 再更正，表上就还是旧数，而且旧数看着完全合理。
# 每个函数都只吃 BASELINE 的字段、只做格式化，所以能被 selfcheck 逐条对账。

def base_render_line():
    b = BASELINE
    return "p50 %.2f / p95 %.2f / p99 %.2f / max %.2f" % (
        b["render_p50_ms"], b["render_p95_ms"], b["render_p99_ms"], b["render_max_ms"])


def base_app_update_line():
    v = BASELINE["app_update_ms"]
    return "%.1f~%.1f（%d 次）" % (min(v), max(v), len(v))


def base_hitches_line():
    return "%d 次 / %.2f 每秒" % (BASELINE["hitches"], BASELINE["hitch_per_second"])


def base_hitch_frame_line():
    b = BASELINE
    return "%.2f~%.2f ms (4~7 帧)" % (b["hitch_frame_ms_min"], b["hitch_frame_ms_max"])


def base_hang_line():
    b = BASELINE
    return "%d 次 中位 %.1f / 累计 %.0f ms" % (
        b["potential_hangs"], b["potential_hang_median_ms"], b["potential_hang_total_ms"])


def base_main_thread_line():
    b = BASELINE
    return "%d/%d = %.1f%%" % (b["main_thread_samples"], b["main_thread_total_samples"],
                               b["main_thread_share_pct"])


def base_hotspot_line():
    return "%.1f%% %s / UpdateStack::update" % (
        BASELINE["hotspot_top1_pct"], "_updateViewGraph")

FRAME_BUDGET_MS_DEFAULT = 8.333  # 120 Hz 下单帧预算，实测 Hz 不同时由 --budget-ms 覆盖


def launch_ready_ms(rows):
    """从 life-cycle-period 的 (起始 ms, 时长 ms) 推出"**启动到就绪**"。

    为什么不能直接把全表求和：App 起来之后**一直活到录制窗口结束**，
    表里最后一定有一段"运行期"占掉几乎整个窗口。
    实测 2026-09-21：总览页全表求和 = 10338 ms（≈录制时长 10 s），
    而真正的启动段在 837 ms 处就结束了——旧写法把每页都算成 ≈10 s，
    T4（冷启动 ≤1.0 s）于是**永远不可能达标**。

    规则（可复核、不挑好看的数）：
      · 找出"尾巴段"= 时长超过整表跨度一半的那些段；有就取其中最早的**起点**当就绪点；
      · 没有尾巴段（进程很快就退出）⇒ 取所有段的末端最大值，那本来就是全部启动成本。
    空表返回 None（调用方按"未观测到"处理，不许拿 0 当达标）。
    """
    spans = [(s, d) for s, d in rows if d and d > 0]
    if not spans:
        return None
    horizon = max(s + d for s, d in spans)
    tails = [s for s, d in spans if d > horizon / 2.0]
    if tails:
        return min(tails)
    return horizon


def in_display_regime(achieved_fps, budget_ms, ratio=0.8):
    """实测出帧是否还落在 `budget_ms` 所假设的那个刷新率档内。

    8.333 ms 这个预算**只在 120 Hz 档成立**。外接/内建标称 120 Hz，
    但窗口静止时 ProMotion 会把实际出帧降到 ~50 Hz —— 这时候
    一帧本就该花 ~20 ms，拿 8.333 ms 去判就会把 36 帧判成"超预算"、
    把 HTR 判成"危急·立刻处理"。我今晚就是这么被自己的一份 idle 读数
    唬住了一次（主线程 88.6% 在等事件、整窗零输入，却报"危急"）。
    ⇒ 拿不到出帧数时**保守判为在档内**（不许用"未知"去给坏消息打折）。
    """
    if not achieved_fps or achieved_fps <= 0 or not budget_ms or budget_ms <= 0:
        return True
    # `1000/8.333 = 120.005` 会比真实的 120 Hz 多出一丝，边界上会把 96.0 这种
    # 正好该算"在档内"的值判成越界——所以先把标称 Hz 收一位小数再乘系数。
    implied_hz = round(1000.0 / float(budget_ms), 1)
    return float(achieved_fps) >= implied_hz * ratio


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


def as_int(value, default=0):
    """把 `meta.json` 里的窗口秒数收成 int。

    生产侧是 shell 变量（`perf_harness.sh` 用 `"hitches_seconds=$SECONDS_HITCHES"`
    塞进 meta 的 JSON），所以落盘就是**字符串** `"20"`。平时看不见这个类型差，
    是因为 `perf_harness.sh report` 会补 `--seconds`（argparse 收成 int）；
    一旦按 `trace_report.py` 文件头那种方式自己跑，就退回 meta 的字符串，
    `len(hitch) / "20"` 当场 TypeError。
    认不下来就退回 default，让"窗口未知"那一支如实报未知，而不是把整张表崩掉。
    """
    try:
        return int(float(str(value).strip()))
    except (TypeError, ValueError):
        return default


def regime_note(baseline_frames, baseline_seconds, cur_frames, cur_seconds, ratio_max=2.0):
    """两趟 render 分布是不是**同一种出帧机制**——不同就不许互比比率。

    为什么要有这条：render 的"超预算帧占多少比例"是**分母敏感**的。基线那趟 20 s 出了
    2394 帧（≈120 fps 连出帧，每帧只有 8.3 ms 的呼吸），本次 idle 那趟 20 s 只出 181 帧
    （≈9 fps，每帧之间有的是时间）。同一份代码在两种机制下算出来的百分比不可互比——
    拿 0.42% 对 4.97% 读成"恶化 12 倍"是错的，两边帧数是 10 对 9。

    纯函数、只吃四个数，所以能被 selfcheck 正反两头钉（见 `selfcheck_regime_note`）。
    返回 (可比?, 说明)。窗口/帧数缺任意一个一律按"不可比"处理，不猜。
    """
    if not baseline_frames or not baseline_seconds or not cur_frames or not cur_seconds:
        return False, "分母不全→比率不互比"
    base_fps = float(baseline_frames) / float(baseline_seconds)
    cur_fps = float(cur_frames) / float(cur_seconds)
    lo, hi = sorted([base_fps, cur_fps])
    if hi <= lo * ratio_max:
        return True, ""
    return False, ("出帧机制不同（基线 %.1f fps / 本次 %.1f fps，相差 %.0f 倍）→ 只各判绝对预算"
                   % (base_fps, cur_fps, hi / lo if lo else 0.0))


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
