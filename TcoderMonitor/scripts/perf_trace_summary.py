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

from perf_trace_metrics import (BASELINE, FRAME_BUDGET_MS_DEFAULT, as_int, base_app_update_line, base_hang_line, base_hitch_frame_line, base_hitches_line, base_hotspot_line, base_main_thread_line, base_render_line, dedupe_pairs, disp_values, fmt_row, fps_counts, load_measure, over_budget, percentile, read_json, regime_note)
from perf_trace_xml import cross_check_durations, find_tag


# ----------------------------------------------------------------------------
# 汇总表：与 spec §1 逐列同形状
# ----------------------------------------------------------------------------

def cmd_summary(args):
    d = args.directory
    loaded = summary_load(d)

    meta = read_json(os.path.join(d, "meta.json")) or {}
    # 三个来源都可能是**字符串**（meta 里是 shell 变量、CLI 上 argparse 已经收过 int），
    # 所以要过 `as_int`；少了这一步，绕开 harness 自己跑 summary 会 TypeError 崩表。
    seconds = (as_int(args.seconds) or as_int(meta.get("hitches_seconds"))
               or as_int(meta.get("seconds")))
    summary_header(meta)
    # 预算由第 1 节实测刷新率算出，后面四节都吃它——顺序就是口径，不许重排。
    budget = summary_refresh_row(loaded, args)
    summary_render_rows(loaded, budget, seconds)
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
    # 【对照列的身份必须自己说清楚】§1.3 已判该样本未受控，规则原先只写在
    # `perf_trace_metrics.py` 的注释里——写在注释里的规则等于没有规则：
    # 表一打出来，"§1 基线 | 本次 | 改善" 就是一份从 X 到 Y 的结论。
    # 所以未受控期间，判定列只按**绝对预算**判，对照列降级为"形状参考"。
    # （必须打在表头**之前**：夹在表头和分隔行之间会把 markdown 表格截断。）
    if not BASELINE.get("controlled", True):
        print("   ⚠ 对照列**未受控**（%s）：按 §1.3 只作同形状参考，"
              "**不作任何\u201c从 X 降到 Y\u201d的 X**；判定列因此只判绝对预算。"
              % BASELINE.get("uncontrolled_reason", "原因未登记"))
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


def summary_render_rows(loaded, budget, seconds):
    # 2) render 相位
    render = disp_values(loaded["hitches-renders"])
    base_over = ("%d 帧 (%.2f%%, n=%d)" % (BASELINE["render_over_budget_frames"],
                                          BASELINE["render_over_budget_pct"],
                                          BASELINE["render_total_frames"]))
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
        fmt_row("render 相位 (ms)", base_render_line(), cur,
                ("健康" if percentile(render, .95) <= budget else "超")
                + ("" if agree else "；解析自检不一致→本行仅参考"))
        # 【比率不许裸比】两边分母差一个数量级时，"0.42% → 4.97%" 会被读成恶化 12 倍，
        # 而帧数是 10 → 9。所以：判定只看**本次对绝对预算**，跨趟的话交给 regime_note，
        # 它说不可比就把这句原样贴在判定里，而不是把两列比率抹成一个词。
        _, note = regime_note(BASELINE["render_total_frames"], BASELINE["hitch_seconds"],
                              len(render), seconds)
        verdict = "达标" if pct < 0.1 else "超"
        if not agree:
            verdict = why
        elif note:
            # 只写在判定列里，**不另起一行**：夹进 markdown 表格会把表截断成两张。
            verdict += "；" + note
        fmt_row("render 超预算帧", base_over,
                ("%d 帧 (%.2f%%, n=%d)" % (bad, pct, len(render))) if agree
                else "未报（两把解析不一致）",
                verdict)
    else:
        why = "未覆盖" if not loaded["hitches-renders"]["present"] else "0 帧（未采到）"
        fmt_row("render 相位 (ms)", base_render_line(), why, "—")
        fmt_row("render 超预算帧", base_over, why, "—")


def summary_app_update_row(loaded, budget):
    # 3) app-update 相位（一次 hitch 通常拆成 Brown+Red 两行，同 duration 走 ref）
    upd = dedupe_pairs(loaded["hitches-updates"])
    if upd:
        cur = " ".join("%.1f" % v for v in sorted(upd))
        fmt_row("app-update 单次耗时(ms)", base_app_update_line(),
                (cur[:31] + "…") if len(cur) > 32 else cur,
                "达标" if max(upd) <= budget else "超 %.1f 倍" % (max(upd) / budget))
    else:
        fmt_row("app-update 单次耗时(ms)", base_app_update_line(),
                "无 app-update = 无 hitch" if loaded["hitches-updates"]["present"] else "未覆盖", "—")


def summary_hitch_rows(loaded, seconds, budget):
    # 4) hitch 次数 / 速率
    hitch = disp_values(loaded["hitches"])
    if loaded["hitches"]["present"]:
        rate = (len(hitch) / seconds) if seconds else 0.0
        fmt_row("hitch 次数 / 速率", base_hitches_line(),
                "%d 次 / %ds = %.2f /s" % (len(hitch), seconds, rate),
                "达标(0 次)" if not hitch else ("超(预算 0)" if rate < 1.0 else "严重超(>=1/s)"))
        fmt_row("hitch 帧时长", base_hitch_frame_line(),
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
        fmt_row("hitch 次数 / 速率", base_hitches_line(), "未覆盖", "—")
        fmt_row("hitch 帧时长", base_hitch_frame_line(), "未覆盖", "—")
        fmt_row("Hitch Time Ratio (ms/s)", "%.2f（危急档）" % BASELINE.get("hitch_time_ratio_ms_per_s", 12.9),
                "未覆盖", "—")


def summary_hang_rows(loaded, budget):
    # 5) potential-hangs（主线程被占住多久）
    hangs = disp_values(loaded["potential-hangs"])
    if hangs:
        cur = "%d 次 中位 %.1f / 最大 %.1f / 累计 %.0f ms" % (
            len(hangs), statistics.median(hangs), max(hangs), sum(hangs))
        fmt_row("potential-hangs", base_hang_line(), cur,
                "严重超" if max(hangs) > budget else "达标")
    else:
        fmt_row("potential-hangs", base_hang_line(),
                "0 次" if loaded["potential-hangs"]["present"] else "未覆盖", "—")


def summary_time_profile_rows(loaded):
    # 6) 主线程样本占比 + 热点第一名（这两列只能来自 time-profile）
    tp = (loaded["time-profile"]["json"] or {})
    if tp:
        share = tp.get("share_pct", 0)
        # 「改善 / 回退」是**两个数之间的话**，而 §1.3 已判基线那趟未受控
        # （采在几十个 swiftc 抢满 15 核期间）——它当时 84.8% 不代表"健康态就该 84.8%"。
        # 这里也不换成绝对阈值：84.8%/23.3% 是"主线程占**本进程**样本"的份额，
        # 而 spec 的"空闲 ≤2%"是"主线程占**墙钟**时间"，两个分母不同名，拿一个判另一个
        # 就是换个口径冒充判据。未受控期间只报现量、明写不判趋势。
        trend = ("改善" if share < BASELINE["main_thread_share_pct"] else "回退") \
            if BASELINE.get("controlled", True) else "对照列未受控→不判趋势"
        fmt_row("主线程 CPU 样本占比", base_main_thread_line()
                + ("" if BASELINE.get("controlled", True) else "（未受控）"),
                "%d / %d (%.1f%%)" % (tp.get("samples", 0), tp.get("process_samples", 0), share),
                trend)
        hot = str(tp.get("hotspot_top1", ""))
        # §1 那 64.3% 写的是 "_updateViewGraph / AG::Graph::UpdateStack::update()" 两个符号，
        # 它们是同一条视图图更新链；判定必须都认，否则换个入口符号就误报"已换位"。
        # 【地址不是符号】release 内联/未符号化的帧会解析成 `0x1004faa5b` 这种裸地址，
        # 而"仍是它 / 已换位"是一句**关于是谁**的话——拿地址去判等于凭空断言。
        # 实测 2026-09-21：交付内容三趟的热点是 `92.2% 0x1004faa5b`，旧写法直接报了"已换位"。
        resolved = bool(hot) and not hot.startswith("0x")
        still = resolved and any(tok in hot for tok in ("updateViewGraph", "UpdateStack::update"))
        hot_verdict = ("仍是它" if still else "已换位") if resolved else "不可判（未解析出符号）"
        fmt_row("主线程热点第一名", base_hotspot_line(),
                "%.1f%% %s" % (tp.get("hotspot_top1_pct", 0.0),
                               hot[:26] if resolved else hot[:18] + "（未符号化）"),
                hot_verdict)
    else:
        fmt_row("主线程 CPU 样本占比", base_main_thread_line(), "未覆盖（缺 time-profile.json）", "—")
        fmt_row("主线程热点第一名", base_hotspot_line(), "未覆盖（缺 time-profile.json）", "—")


def summary_fps_row(loaded):
    # 7) 出帧（spec §7.6：静止界面无所谓帧率，这一列只当"东西确实在动"的证据）
    fps = loaded["displayed-surfaces-per-second"]["json"] or fps_counts(loaded["displayed-surfaces-per-second"])
    if fps:
        fmt_row("实测出帧/s", "参考项", "p50 %s / p95 %s / 共 %s 秒"
                % (fps.get("fps_p50"), fps.get("fps_p95"), fps.get("seconds")), "参考")
    else:
        fmt_row("实测出帧/s", "参考项", "未覆盖", "参考")


