#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xctrace 导出 XML → 固定形状的性能读数（帧节拍 / hitch / 主线程热点）：子命令与 CLI。

解析层（id/ref 解引用）在 `perf_trace_xml.py`，统计层与 §1 基线常量在
`perf_trace_metrics.py`——三件事原本挤在一个 819 行的文件里，撞了本仓 ≤800 行棘轮
（`SelfScanDogfoodTests`，分母含 `.py`，ceiling=0）。**拆开是修复，拧阈值不是。**
两个模块与本文件同级目录，Python 会自动把脚本所在目录放进 `sys.path`，
所以入口仍是 `python3 scripts/trace_report.py <子命令>`，`perf_harness.sh` 一个字节都不用改。

## 子命令（`perf_harness.sh` 按这些形状调用，改形状要同步改它）

    trace_report.py durations <xml> [--label 名] [--budget-ms 8.333]  # 时长分布 n/p50/p95/p99/max
    trace_report.py threads <xml> [--thread "Main Thread"] [--top 20] [--leaf 12] [--pairs 12]
    trace_report.py displays <xml>                                   # device-display-info：分辨率与最大 Hz
    trace_report.py fps <xml> [--display 名]                          # displayed-surfaces-per-second：出帧
    trace_report.py summary <输出目录> [--seconds N]                    # 出 spec §1 的同形状对照表
    trace_report.py lifecycle <xml>                                   # life-cycle-period：首帧与冷构建周期
    trace_report.py switches <输出目录>                                 # switch 档逐页冷启动

为什么不许直接正则 `<duration>` 计数（假读数的来由）、分位为什么必须按 int(n·p) 取，
分别写在 `perf_trace_xml.py` 与 `perf_trace_metrics.py` 的头注里，那里是唯一口径来源。
数据口径提醒：release 与 debug 的绝对值不可混比，详见 scripts/perf_harness.sh 头注。
"""

import argparse
import collections
import os
import re
import statistics
import sys

from perf_trace_metrics import (BASELINE, FRAME_BUDGET_MS_DEFAULT, dedupe_pairs, disp_values,
                                dist_line, fmt_row, fps_counts, load_measure, over_budget,
                                percentile, read_json, write_json)
from perf_trace_xml import (Doc, PLUMBING_SHARE_PCT, build_stack_index, cross_check_durations,
                            find_tag, is_runloop_plumbing)


# ----------------------------------------------------------------------------
# threads：Time Profiler 的按线程样本数与热点栈
# ----------------------------------------------------------------------------

def cmd_threads(args):
    with open(args.xml, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    _, _, tbs, threads = build_stack_index(text)
    per = collections.Counter()
    leaf = collections.Counter()
    anyf = collections.Counter()
    pairs = collections.Counter()
    for row in re.findall(r"<row>(.*?)</row>", text, re.S):
        tm = re.search(r'<thread (?:id="(\d+)"[^>]*|ref="(\d+)")', row)
        if not tm:
            continue
        tname = threads.get(tm.group(1) or tm.group(2), "?")
        per[tname] += 1
        bm = re.search(r'<tagged-backtrace (?:id="(\d+)"|ref="(\d+)")', row)
        if not bm:
            continue
        stack = tbs.get(bm.group(1) or bm.group(2), [])
        if not stack:
            continue
        leaf[(tname, stack[0])] += 1
        for f in dict.fromkeys(stack):
            anyf[(tname, f)] += 1
        if len(stack) > 1:
            pairs[(tname, stack[0], stack[1])] += 1

    if not per:
        print("!! 一个样本都没解出来：确认导出的是 time-profile 表（而不是空的 time-profile）")
        return 1

    print("== 线程样本数 ==")
    for tname, cnt in per.most_common(8):
        print("  %6d  %s" % (cnt, tname[:70]))

    cand = [t for t in per if t.startswith(args.thread)]
    target = max(cand, key=lambda t: per[t]) if cand else max(per, key=lambda t: per[t])
    total_all = sum(per.values())
    total = per[target]
    print("\n== %s  %d 样本（占全进程 %.1f%%）==" % (target[:60], total, 100.0 * total / max(1, total_all)))
    print("栈中出现频率前 %d（已剥掉事件循环本体帧）：" % args.top)
    shown = 0
    for (tname, f), cnt in anyf.most_common(4000):
        if tname == target and not is_runloop_plumbing(f) and shown < args.top:
            print("  %6d (%5.1f%%)  %s" % (cnt, 100.0 * cnt / total, f[:86]))
            shown += 1
    loop = max(((cnt, f) for (tname, f), cnt in anyf.most_common(4000)
                if tname == target and is_runloop_plumbing(f)), default=None)
    if loop:
        print("  （事件循环本体占 %.1f%%：%s —— 说明主线程绝大部分样本是在**等事件**，不是算不动）"
              % (100.0 * loop[0] / total, loop[1][:48]))
    print("\n叶子帧（自身耗时）前 %d：" % args.leaf)
    shown = 0
    for (tname, f), cnt in leaf.most_common(4000):
        if tname == target and cnt >= 2 and shown < args.leaf:
            print("  %6d  %s" % (cnt, f[:86]))
            shown += 1
    print("\n调用对（leaf <- 上一帧）前 %d：" % args.pairs)
    shown = 0
    for (tname, a, b), cnt in pairs.most_common(4000):
        if tname == target and cnt >= 3 and shown < args.pairs:
            print("  %6d  %s <- %s" % (cnt, a[:44], b[:44]))
            shown += 1

    if args.json:
        ranked = [(f, cnt) for (tname, f), cnt in anyf.most_common(4000) if tname == target]
        # 热点第一名要**剥掉事件循环本体**：RunCurrentEventLoopInMode 这类帧在几乎每个
        # 主线程样本里都有（本机实测 93.3%），拿它当"热点"既没有信息量，
        # 又会把 spec §1 里那个 64.3% _updateViewGraph 挤掉，前后两批就不可比了。
        ranked = [(f, round(100.0 * cnt / max(1, total), 2)) for f, cnt in ranked]
        hotspot = [(f, pct) for f, pct in ranked
                   if not is_runloop_plumbing(f) and pct < PLUMBING_SHARE_PCT]
        write_json(args.json, {
            "thread": target,
            "samples": total,
            "process_samples": total_all,
            "share_pct": round(100.0 * total / max(1, total_all), 2),
            "hotspot_top1": hotspot[0][0] if hotspot else "",
            "hotspot_top1_pct": hotspot[0][1] if hotspot else 0.0,
            "runloop_top1": ranked[0][0] if ranked else "",
            "runloop_top1_pct": ranked[0][1] if ranked else 0.0,
        })
    return 0


# ----------------------------------------------------------------------------
# 时长分布（hitches / hitches-updates / potential-hangs / hitches-renders）
# ----------------------------------------------------------------------------

def cmd_durations(args):
    doc = Doc(args.xml)
    spans = doc.spans()
    values = [d for _, d in spans]
    print("[%-18s] schema=%s %s" % (args.label or os.path.basename(args.xml), doc.schema(), dist_line(values)))
    if values:
        bad, pct = over_budget(values, args.budget_ms)
        print("%22s 累计=%.0f ms 超预算(>%.3f ms)=%d (%.2f%%)"
              % ("", sum(values), args.budget_ms, bad, pct))
        ordered = sorted(round(v, 2) for v in values)
        head = ordered[:20]
        print("%22s 逐值=%s%s" % ("", head, " …（共 %d 个）" % len(ordered) if len(ordered) > 20 else ""))
        if args.with_phases:
            starts = sorted(s for s, _ in spans)
            gaps = [round(b - a, 1) for a, b in zip(starts, starts[1:])]
            print("%22s 事件间隔=%s" % ("", gaps[:16]))
    if args.json:
        write_json(args.json, {
            "label": args.label, "n": len(values),
            "p50": round(percentile(values, 0.5), 3), "p95": round(percentile(values, 0.95), 3),
            "p99": round(percentile(values, 0.99), 3), "max": round(max(values), 3) if values else 0.0,
            "median": round(statistics.median(values), 3) if values else 0.0,
            "total": round(sum(values), 1), "over_budget": over_budget(values, args.budget_ms)[0],
            "values": [round(v, 2) for v in sorted(values)][:40],
        })
    return 0


def cmd_displays(args):
    doc = Doc(args.xml)
    print("== device-display-info ==")
    hz = {}
    for row in doc.rows():
        name = find_tag(row, "metal-object-label") or find_tag(row, "display-name")
        res = find_tag(row, "size-in-pixels")
        builtin = find_tag(row, "boolean")
        rate = None
        uints = [c for c in row if c.tag == "uint32"]
        for c in uints:
            if c.fmt and c.fmt.isdigit() and 10 <= int(c.fmt) <= 1000:
                rate = int(c.fmt)
        if name is None:
            continue
        print("  %-18s %-12s built-in=%-3s 最大刷新率=%s Hz"
              % (name.fmt[:18], res.fmt if res else "?",
                 builtin.fmt if builtin else "?", rate if rate else "?"))
        if rate:
            hz[name.fmt] = rate
    if args.json:
        write_json(args.json, {"displays": hz, "max_hz": max(hz.values()) if hz else 0})
    return 0


def cmd_fps(args):
    doc = Doc(args.xml)
    counts = []
    for row in doc.rows():
        if args.display:
            name = find_tag(row, "display-name")
            if name is not None and args.display not in name.fmt:
                continue
        uints = [c for c in row if c.tag == "uint32"]
        if uints:
            v = uints[0].num()
            if v is not None:
                counts.append(v)
    print("[%-18s] %s" % ("displayed-surfaces/s", dist_line([float(c) for c in counts]).replace("ms", "")))
    if counts:
        print("%22s 采样秒数=%d 首=%s 末=%s" % ("", len(counts), counts[0], counts[-1]))
    if args.json:
        write_json(args.json, {"fps_p50": percentile(counts, 0.5), "fps_p95": percentile(counts, 0.95),
                               "fps_min": min(counts), "fps_max": max(counts), "seconds": len(counts)})
    return 0


# ----------------------------------------------------------------------------
# 汇总表：与 spec §1 逐列同形状
# ----------------------------------------------------------------------------

def cmd_summary(args):
    d = args.directory
    loaded = {}
    for key in ("hitches", "hitches-updates", "hitches-renders", "potential-hangs",
                "device-display-info", "displayed-surfaces-per-second", "time-profile"):
        loaded[key] = load_measure(d, key)

    meta = read_json(os.path.join(d, "meta.json")) or {}
    seconds = args.seconds or meta.get("hitches_seconds") or meta.get("seconds") or 0
    # 【期间必须出现在表头上】§1 基线是**心跳期**（不去碰它）量的，T1 要的是**交互期**。
    # 两者同形状、不同含义——不在表头写清楚，过两周就有人会拿心跳期的 HTR 去交交互期的结论。
    period = str(meta.get("period") or "idle")
    is_interaction = period == "interaction"

    print("== Tcoder 性能读数（对照 spec §1 基线 rev %s，release 口径）==" % BASELINE["rev"])
    print("   测量期间：%s —— %s" % (period, "有资格答 T1（交互期 hitch = 0）" if is_interaction
                                else "只答心跳期；**不许**拿去交 T1，要判 T1 用 interact 档重录"))
    print("| %-30s | %-28s | %-34s | %s |" % ("指标", "§1 基线", "本次", "判定"))
    print("|" + "-" * 32 + "|" + "-" * 30 + "|" + "-" * 36 + "|" + "-" * 10 + "|")

    # 1) 刷新率：预算的分母，必须实测而不是假定 120
    disp = loaded["device-display-info"]
    rates = {}
    if disp["doc"] is not None:
        for row in disp["doc"].rows():
            name = find_tag(row, "metal-object-label") or find_tag(row, "display-name")
            for c in [c for c in row if c.tag == "uint32"]:
                if c.fmt and c.fmt.isdigit() and 10 <= int(c.fmt) <= 1000 and name is not None:
                    rates[name.fmt] = int(c.fmt)
    max_hz = max(rates.values()) if rates else (disp["json"] or {}).get("max_hz", 0)
    shown = " / ".join("%s=%dHz" % (k, v) for k, v in list(rates.items())[:2]) if rates else (
        "未覆盖" if not disp["present"] else "表里没读到屏幕")
    budget = args.budget_ms or (1000.0 / max_hz if max_hz else FRAME_BUDGET_MS_DEFAULT)
    fmt_row("内建/外接最大刷新率", "120 / 120 Hz", shown or "未覆盖",
            ("预算 %.3f ms" % budget) if max_hz else "未采")

    # 2) render 相位
    render = disp_values(loaded["hitches-renders"])
    if render:
        bad, pct = over_budget(render, budget)
        cur = ("p50 %.2f / p95 %.2f / p99 %.2f / max %.2f（n=%d）"
               % (percentile(render, .5), percentile(render, .95), percentile(render, .99),
                  max(render), len(render)))
        # 两条独立解析不一致 ⇒ 这一列不许出数（详见 cross_check_durations 的注释）。
        doc = (loaded["hitches-renders"] or {}).get("doc")
        agree, why = (False, "无 XML 可比对")
        if doc is not None:
            agree, why = cross_check_durations(doc.path, render)
        fmt_row("render 相位 (ms)", "p50 2.73 / p95 4.06 / p99 4.77 / max 25.12", cur,
                ("健康" if percentile(render, .95) <= budget else "超")
                + ("" if agree else "；解析自检不一致→本行仅参考"))
        fmt_row("render 超预算帧", "10 帧 (0.42%)",
                ("%d 帧 (%.2f%%)" % (bad, pct)) if agree else "未报（两把解析不一致）",
                ("达标" if pct < 0.1 else "超") if agree else why)
    else:
        why = "未覆盖" if not loaded["hitches-renders"]["present"] else "0 帧（未采到）"
        fmt_row("render 相位 (ms)", "p50 2.73 / p95 4.06 / p99 4.77 / max 25.12", why, "—")
        fmt_row("render 超预算帧", "10 帧 (0.42%)", why, "—")

    # 3) app-update 相位（一次 hitch 通常拆成 Brown+Red 两行，同 duration 走 ref）
    upd = dedupe_pairs(loaded["hitches-updates"])
    if upd:
        cur = " ".join("%.1f" % v for v in sorted(upd))
        fmt_row("app-update 单次耗时(ms)", "10.8~24.8（7 次）",
                (cur[:31] + "…") if len(cur) > 32 else cur,
                "达标" if max(upd) <= budget else "超 %.1f 倍" % (max(upd) / budget))
    else:
        fmt_row("app-update 单次耗时(ms)", "10.8~24.8（7 次）",
                "无 app-update = 无 hitch" if loaded["hitches-updates"]["present"] else "未覆盖", "—")

    # 4) hitch 次数 / 速率
    hitch = disp_values(loaded["hitches"])
    if loaded["hitches"]["present"]:
        rate = (len(hitch) / seconds) if seconds else 0.0
        fmt_row("hitch 次数 / 速率", "7 次 / 0.35 每秒",
                "%d 次 / %ds = %.2f /s" % (len(hitch), seconds, rate),
                "达标(0 次)" if not hitch else ("超(预算 0)" if rate < 1.0 else "严重超(>=1/s)"))
        fmt_row("hitch 帧时长", "33.33~58.33 ms (4~7 帧)",
                ("%.2f~%.2f ms" % (min(hitch), max(hitch))) if hitch else "无 hitch",
                "超" if hitch and max(hitch) > budget else "达标")
        # Hitch Time Ratio：Apple 的正式指标（tech-talk 10855）——
        # 本实现取 Σ max(0, 帧时长 − 预算) / 秒数，是"晚了多少"的保守上界。
        # 档位（Apple 原文）：<5 无感 / 5~10 可察觉需排查 / >10 危急需立刻处理 / 理想 0。
        htr = (sum(max(0.0, d - budget) for d in hitch) / seconds) if seconds else 0.0
        band = "理想(0)" if not hitch else ("无感" if htr < 5 else ("可察觉·需排查" if htr <= 10 else "危急·立刻处理"))
        fmt_row("Hitch Time Ratio (ms/s)", "%.2f（危急档）" % BASELINE.get("hitch_time_ratio_ms_per_s", 12.9),
                "%.2f（%d 帧迟到，预算 %.3f ms）" % (htr, len(hitch), budget), band)
    else:
        fmt_row("hitch 次数 / 速率", "7 次 / 0.35 每秒", "未覆盖", "—")
        fmt_row("hitch 帧时长", "33.33~58.33 ms (4~7 帧)", "未覆盖", "—")
        fmt_row("Hitch Time Ratio (ms/s)", "%.2f（危急档）" % BASELINE.get("hitch_time_ratio_ms_per_s", 12.9),
                "未覆盖", "—")

    # 5) potential-hangs（主线程被占住多久）
    hangs = disp_values(loaded["potential-hangs"])
    if hangs:
        cur = "%d 次 中位 %.1f / 最大 %.1f / 累计 %.0f ms" % (
            len(hangs), statistics.median(hangs), max(hangs), sum(hangs))
        fmt_row("potential-hangs", "13 次 中位 42.6 / 累计 573 ms", cur,
                "严重超" if max(hangs) > budget else "达标")
    else:
        fmt_row("potential-hangs", "13 次 中位 42.6 / 累计 573 ms",
                "0 次" if loaded["potential-hangs"]["present"] else "未覆盖", "—")

    # 6) 主线程样本占比 + 热点第一名（这两列只能来自 time-profile）
    tp = (loaded["time-profile"]["json"] or {})
    if tp:
        fmt_row("主线程 CPU 样本占比", "684/807 = 84.8%",
                "%d / %d (%.1f%%)" % (tp.get("samples", 0), tp.get("process_samples", 0),
                                       tp.get("share_pct", 0.0)),
                "改善" if tp.get("share_pct", 0) < BASELINE["main_thread_share_pct"] else "回退")
        hot = str(tp.get("hotspot_top1", ""))
        # §1 那 64.3% 写的是 "_updateViewGraph / AG::Graph::UpdateStack::update()" 两个符号，
        # 它们是同一条视图图更新链；判定必须都认，否则换个入口符号就误报"已换位"。
        still = any(tok in hot for tok in ("updateViewGraph", "UpdateStack::update"))
        fmt_row("主线程热点第一名", "64.3% _updateViewGraph / UpdateStack::update",
                "%.1f%% %s" % (tp.get("hotspot_top1_pct", 0.0), hot[:26]),
                "仍是它" if still else "已换位")
    else:
        fmt_row("主线程 CPU 样本占比", "684/807 = 84.8%", "未覆盖（缺 time-profile.json）", "—")
        fmt_row("主线程热点第一名", "64.3% _updateViewGraph", "未覆盖（缺 time-profile.json）", "—")

    # 7) 出帧（spec §7.6：静止界面无所谓帧率，这一列只当"东西确实在动"的证据）
    fps = loaded["displayed-surfaces-per-second"]["json"] or fps_counts(loaded["displayed-surfaces-per-second"])
    if fps:
        fmt_row("实测出帧/s", "参考项", "p50 %s / p95 %s / 共 %s 秒"
                % (fps.get("fps_p50"), fps.get("fps_p95"), fps.get("seconds")), "参考")
    else:
        fmt_row("实测出帧/s", "参考项", "未覆盖", "参考")
    print("\n（未覆盖 = 该表没导出或导出为空，按 spec §6.6 明写，不许拿相邻档的数冒充。）")
    return 0


def cmd_lifecycle(args):
    """App Launch 的 life-cycle-period 表：逐周期时长 + 哪个周期最长。

    表结构随 Xcode 版本变（列名不保证），所以这里**按标签通用地**打出来，
    并且在 --json 里只存两个跨版本稳的量：total_ms 与 max_period_ms。
    """
    doc = Doc(args.xml)
    rows = []
    total = 0.0
    longest = (0.0, "")
    for row in doc.rows():
        dur = find_tag(row, "duration")
        name = (find_tag(row, "lifecycle-period") or find_tag(row, "period")
                or find_tag(row, "string") or find_tag(row, "narrative"))
        d = dur.ms() if dur else None
        if d is None:
            continue
        total += d
        label = name.fmt if name and name.fmt else "?"
        if d > longest[0]:
            longest = (d, label)
        rows.append((label, d, [c.fmt for c in row if c.fmt][:4]))
    print("== life-cycle-period（首帧与冷构建成本）==")
    for label, d, extra in rows[:24]:
        print("  %8.2f ms  %-26s %s" % (d, label[:26], " ".join(extra)[:60]))
    if not rows:
        print("  未解出任何周期——该表为空或列名与预期不符（按未覆盖处理，别拿 0 当达标）")
    print("  合计 %.1f ms / %d 行；最长周期 %.1f ms = %s"
          % (total, len(rows), longest[0], longest[1]))
    if args.json:
        write_json(args.json, {"periods": len(rows), "total_ms": round(total, 2),
                               "max_period_ms": round(longest[0], 2), "max_period": longest[1]})
    return 0


def cmd_switches(args):
    """switch 档逐页汇总：页名 / 首帧 / 冷构建周期合计。"""
    root = args.directory
    dirs = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))) if os.path.isdir(root) else []
    print("== switch 档：逐页冷启动 ==")
    print("| %-14s | %-14s | %-16s | %s |" % ("页", "首帧 ms", "冷构建周期合计 ms", "最长周期"))
    n = 0
    for name in dirs:
        meta = read_json(os.path.join(root, name, "meta.json")) or {}
        life = read_json(os.path.join(root, name, "life-cycle-period.json"))
        page = meta.get("page", name)
        first = meta.get("first_frame_ms", "未观测到")
        first_txt = "未观测到" if first == "未观测到" else "%s ms" % first
        total = "%.1f" % life["total_ms"] if life else "未覆盖"
        longest = "%s %.1f ms" % (str(life.get("max_period", ""))[:14], life.get("max_period_ms", 0.0)) if life else "—"
        print("| %-14s | %-14s | %-18s | %s |" % (page[:14], first_txt[:14], total, longest))
        n += 1
    if n == 0:
        print("!! %s 下没有逐页子目录：switch 档没跑过或跑了 DRY_RUN" % root)
    print("（首帧口径 = 带采样器、窗口出现即算；比裸启动慢，只用于页间横向比较。）")
    return 0


# ----------------------------------------------------------------------------
# migration：把工单 §0.1 那张表变成一条能反复跑的命令
# ----------------------------------------------------------------------------

# 命中符号 → 该换成什么。只是提示，判据不住这里（见下面的口径来源）。
MIGRATION_HINTS = {
    "latestSnapshot": "monitor.pulse.value（或按需读单个格）",
    "history": "monitor.curve.value（窗口已切好，别再 suffix）",
    "topProcesses": "monitor.cpuRanking.value",
    "processesByMemory": "monitor.memoryRanking.value",
    "trackedGroups": "monitor.groupRanking.value",
    "measuredProcessCount": "monitor.ledger.value.measuredCount",
    "processMetricsTruncated": "monitor.ledger.value.metricsTruncated",
    "lastSampleAt": "monitor.pulse.value.sampleAt",
    "allProcesses": "视图零读点：改读 ranking 格",
}

# 【口径只有一个来源】这两条正则与上限**不住在 Python 里**：
# 它们由 `PerfInvalidationRatchetTests` 拥有，这里去把那三行常量读回来。
# 复制一份的正则迟早会与闸门分叉——分叉之后"命令说迁完了、守卫说没迁完"，
# 或者更糟：命令按老规则报 0、守卫按新规则也报 0，谁都不红。
RATCHET_SOURCE = "Tests/TcoderMonitorTests/PerfInvalidationRatchetTests.swift"


def read_guard_ruler(module_root):
    """从守卫源码里取 coarse/fine 正则 + 上限 + 消费方目录。取不到就抛，绝不返回空口径。"""
    path = os.path.join(module_root, RATCHET_SOURCE)
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    got = re.search(r'static let coarsePattern = #"([^"]*)"#', src)
    fine = re.search(r'static let finePattern = #"([^"]*)"#', src)
    ceiling = re.search(r'static let coarseCallSiteCeiling = (\d+)', src)
    dirs = re.search(r'consumerDirectories = \[(.*?)\]', src, re.S)
    missing = [n for n, v in (("coarsePattern", got), ("finePattern", fine),
                              ("coarseCallSiteCeiling", ceiling), ("consumerDirectories", dirs))
               if v is None]
    if missing:
        raise RuntimeError("读不到守卫里的 %s——它被改名或删掉了，本命令的口径就没有单一来源，"
                           "宁可报错也不许退回手抄正则（那会变成第二把尺子）：%s"
                           % (", ".join(missing), path))
    names = re.findall(r'"([^"]+)"', dirs.group(1))
    return got.group(1), fine.group(1), int(ceiling.group(1)), names


def swift_source_files(module_root, relative_dirs):
    for rel in relative_dirs:
        base = os.path.join(module_root, rel)
        for root, _dirs, files in os.walk(base):
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(root, name)


def cmd_migration(args):
    root = args.module_root
    try:
        coarse, fine, ceiling, dirs = read_guard_ruler(root)
    except (OSError, RuntimeError) as exc:
        print("!! %s" % exc, file=sys.stderr)
        return 2
    coarse_re, fine_re = re.compile(coarse), re.compile(fine)
    hits, fine_count, scanned = [], 0, 0
    for path in swift_source_files(root, dirs):
        scanned += 1
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for number, line in enumerate(fh.read().split("\n"), 1):
                if line.strip().startswith("//"):      # 与守卫同一条豁免：整行注释不算调用点
                    continue
                for m in coarse_re.finditer(line):
                    hits.append((os.path.relpath(path, root), number, m.group(1),
                                 MIGRATION_HINTS.get(m.group(1), "读对应的细粒度格")))
                fine_count += len(fine_re.findall(line))
    print("== 细粒度契约迁移进度（口径直接取自 %s）==" % RATCHET_SOURCE)
    print("   扫描 %d 个文件（%s），粗粒度读点 %d 处 / 登记上限 %d 处 / 目标 0，细粒度读点 %d 处"
          % (scanned, " + ".join(dirs), len(hits), ceiling, fine_count))
    if hits:
        print("   剩哪几处（符号是稳定的，行号只是当下位置）：")
        for rel, number, symbol, hint in hits:
            print("     %-46s %-22s → %s" % ("%s:%d" % (rel, number), "monitor." + symbol, hint))
        print("   按文件汇总：%s" % ", ".join("%s×%d" % (k, v) for k, v in
              sorted(collections.Counter(h[0] for h in hits).items())))
    else:
        print("   粗粒度读点已清零——请总工把上限拧成 0 并翻 `consumptionGateOpen`。")
    if args.strict and len(hits) > 0:
        print("!! --strict：还剩 %d 处未迁" % len(hits), file=sys.stderr)
        return 1
    return 0


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(description="xctrace XML → 性能读数（含 id/ref 解引用）")
    sub = p.add_subparsers(dest="cmd", required=True)

    d = sub.add_parser("durations", help="时长分布：hitches / hitches-updates / potential-hangs / renders")
    d.add_argument("xml")
    d.add_argument("--label", default="")
    d.add_argument("--budget-ms", type=float, default=FRAME_BUDGET_MS_DEFAULT)
    d.add_argument("--with-phases", action="store_true", help="额外打印事件间隔（看心跳相位）")
    d.add_argument("--json", default=None)
    d.set_defaults(func=cmd_durations)

    t = sub.add_parser("threads", help="按线程样本数 + 指定线程热点栈")
    t.add_argument("xml")
    t.add_argument("--thread", default="Main Thread")
    t.add_argument("--top", type=int, default=20)
    t.add_argument("--leaf", type=int, default=12)
    t.add_argument("--pairs", type=int, default=12)
    t.add_argument("--json", default=None)
    t.set_defaults(func=cmd_threads)

    s = sub.add_parser("displays", help="device-display-info：分辨率与最大刷新率")
    s.add_argument("xml")
    s.add_argument("--json", default=None)
    s.set_defaults(func=cmd_displays)

    f = sub.add_parser("fps", help="displayed-surfaces-per-second：真实出帧")
    f.add_argument("xml")
    f.add_argument("--display", default="")
    f.add_argument("--json", default=None)
    f.set_defaults(func=cmd_fps)

    m = sub.add_parser("summary", help="读一个输出目录，打印与 spec §1 同形状的对照表")
    m.add_argument("directory")
    m.add_argument("--seconds", type=int, default=0)
    m.add_argument("--budget-ms", type=float, default=0.0)
    m.set_defaults(func=cmd_summary)

    l = sub.add_parser("lifecycle", help="life-cycle-period：首帧与冷构建周期")
    l.add_argument("xml")
    l.add_argument("--json", default=None)
    l.set_defaults(func=cmd_lifecycle)

    w = sub.add_parser("switches", help="switch 档逐页汇总")
    w.add_argument("directory")
    w.set_defaults(func=cmd_switches)

    g = sub.add_parser("migration", help="细粒度契约迁移进度（正则与上限直接取自守卫源码，不复制口径）")
    g.add_argument("--module-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    g.add_argument("--strict", action="store_true", help="还有粗粒度读点就非零退出（给 CI/门禁用）")
    g.set_defaults(func=cmd_migration)
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not os.path.isfile(getattr(args, "xml", None) or "") and getattr(args, "xml", None):
        print("!! 找不到文件: %s" % args.xml, file=sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
