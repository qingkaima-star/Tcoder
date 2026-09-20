#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""汇总表那一层：读一个输出目录，打印与性能 spec §1 **逐列同形状**的对照表。

这一层是 AGENTS.md 第四轮红线 1 点名的那把尺子的"交付面"：
「帧率结论只认 `perf_harness.sh` 的读数」，而 `perf_harness.sh report` 就是把本函数派到前台的。

为什么单独一个模块：`trace_report.py` 被本 App 自己扫成「巨大文件」（>400 行，实测 644）。
按已经成立的两层形状（解析层 `perf_trace_xml.py`、统计层 `perf_trace_metrics.py`）再切一刀，
把最大的一块（summary 家族，183 行）挪出来。**七节的判据、格式串、`fmt_row` 的四列文字与
判定词、以及"预算由第 1 节实测刷新率算出、后面四节都吃它"的顺序，全部逐字未动**——
AGENTS.md 第四轮红线 5（诚实性语义与阈值不许为任何指标放宽）约束的就是这一层。

入口仍是 `python3 scripts/trace_report.py summary <目录>`：同目录模块由 Python 自动进 `sys.path`，
`perf_harness.sh` 与 `selfcheck` 档一个字节都不用改。
"""

import os
import statistics

from perf_trace_metrics import (BASELINE, FRAME_BUDGET_MS_DEFAULT, dedupe_pairs, disp_values,
                                fmt_row, fps_counts, load_measure, over_budget, percentile,
                                read_json)
from perf_trace_xml import cross_check_durations, find_tag


# ----------------------------------------------------------------------------
# 汇总表：与 spec §1 逐列同形状
# ----------------------------------------------------------------------------

def cmd_summary(args):
    d = args.directory
    loaded = summary_load(d)

    meta = read_json(os.path.join(d, "meta.json")) or {}
    seconds = args.seconds or meta.get("hitches_seconds") or meta.get("seconds") or 0
    summary_header(meta)
    # 预算由第 1 节实测刷新率算出，后面四节都吃它——顺序就是口径，不许重排。
    budget = summary_refresh_row(loaded, args)
    summary_render_rows(loaded, budget)
    summary_app_update_row(loaded, budget)
    summary_hitch_rows(loaded, seconds, budget)
    summary_hang_rows(loaded, budget)
    summary_time_profile_rows(loaded)
    summary_fps_row(loaded)
    print("\n（未覆盖 = 该表没导出或导出为空，按 spec §6.6 明写，不许拿相邻档的数冒充。）")
    return 0


# 【拆分的形状】原先这七节从头到尾挤在 `cmd_summary` 一个函数里（131 行 / CC 63，
# 全仓"最大 CC"就是它），拆成「一节一个 `summary_*` 小方法」之后：
# 每一节的判据、格式串、`fmt_row` 的四列文字与判定词**逐字未动**，
# 只有跨节共享的两个量（`loaded` 与 `budget`）改成显式传参。
# 对照证据：`/tmp/x5-before.txt` 与 `/tmp/x5-after.txt` 逐字相同（驱动器见笔记）。
SUMMARY_KEYS = ("hitches", "hitches-updates", "hitches-renders", "potential-hangs",
                "device-display-info", "displayed-surfaces-per-second", "time-profile")


def summary_load(d):
    """七节各取一份读数（XML 优先、脚本顺手写的 JSON 次之、都没有 = 未覆盖）。"""
    loaded = {}
    for key in SUMMARY_KEYS:
        loaded[key] = load_measure(d, key)
    return loaded


def summary_header(meta):
    # 【期间必须出现在表头上】§1 基线是**心跳期**（不去碰它）量的，T1 要的是**交互期**。
    # 两者同形状、不同含义——不在表头写清楚，过两周就有人会拿心跳期的 HTR 去交交互期的结论。
    period = str(meta.get("period") or "idle")
    is_interaction = period == "interaction"

    print("== Tcoder 性能读数（对照 spec §1 基线 rev %s，release 口径）==" % BASELINE["rev"])
    print("   测量期间：%s —— %s" % (period, "有资格答 T1（交互期 hitch = 0）" if is_interaction
                                else "只答心跳期；**不许**拿去交 T1，要判 T1 用 interact 档重录"))
    print("| %-30s | %-28s | %-34s | %s |" % ("指标", "§1 基线", "本次", "判定"))
    print("|" + "-" * 32 + "|" + "-" * 30 + "|" + "-" * 36 + "|" + "-" * 10 + "|")


def summary_refresh_row(loaded, args):
    # 1) 刷新率：预算的分母，必须实测而不是假定 120
    rates = summary_display_rates(loaded)
    disp = loaded["device-display-info"]
    max_hz = max(rates.values()) if rates else (disp["json"] or {}).get("max_hz", 0)
    shown = " / ".join("%s=%dHz" % (k, v) for k, v in list(rates.items())[:2]) if rates else (
        "未覆盖" if not disp["present"] else "表里没读到屏幕")
    budget = args.budget_ms or (1000.0 / max_hz if max_hz else FRAME_BUDGET_MS_DEFAULT)
    fmt_row("内建/外接最大刷新率", "120 / 120 Hz", shown or "未覆盖",
            ("预算 %.3f ms" % budget) if max_hz else "未采")
    return budget


def summary_display_rates(loaded):
    """每块屏的最大刷新率（同一个 uint32 取值式，与 `displays` 子命令一字一样）。"""
    rates = {}
    disp = loaded["device-display-info"]
    if disp["doc"] is not None:
        for row in disp["doc"].rows():
            name = find_tag(row, "metal-object-label") or find_tag(row, "display-name")
            for c in [c for c in row if c.tag == "uint32"]:
                if c.fmt and c.fmt.isdigit() and 10 <= int(c.fmt) <= 1000 and name is not None:
                    rates[name.fmt] = int(c.fmt)
    return rates


def summary_render_rows(loaded, budget):
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


def summary_app_update_row(loaded, budget):
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


def summary_hitch_rows(loaded, seconds, budget):
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


def summary_hang_rows(loaded, budget):
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


def summary_time_profile_rows(loaded):
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


def summary_fps_row(loaded):
    # 7) 出帧（spec §7.6：静止界面无所谓帧率，这一列只当"东西确实在动"的证据）
    fps = loaded["displayed-surfaces-per-second"]["json"] or fps_counts(loaded["displayed-surfaces-per-second"])
    if fps:
        fmt_row("实测出帧/s", "参考项", "p50 %s / p95 %s / 共 %s 秒"
                % (fps.get("fps_p50"), fps.get("fps_p95"), fps.get("seconds")), "参考")
    else:
        fmt_row("实测出帧/s", "参考项", "未覆盖", "参考")


