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

from perf_trace_metrics import (BASELINE, FRAME_BUDGET_MS_DEFAULT, as_int, base_app_update_line, base_hang_line, base_hitch_frame_line, base_hitches_line, base_hotspot_line, base_main_thread_line, base_render_line, dedupe_pairs, disp_values, fmt_row, fps_counts, input_rate_qualification, load_measure, over_budget, percentile, read_json, regime_note, in_display_regime, phase_blame)
from perf_trace_xml import cross_check_durations, find_tag
# 逐帧三张表的判据层：判据一字未动，只是搬出去还「巨大文件 400 行」口径的债。
from perf_trace_frames import PER_TABLE_BUDGETS, frame_table_rows


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
    summary_frame_table_rows(loaded, budget)
    summary_phase_blame_row(loaded, budget)
    summary_hang_rows(loaded, budget)
    summary_time_profile_rows(loaded)
    summary_fps_row(loaded)
    print("\n（未覆盖 = 该表没导出或导出为空，按 spec §6.6 明写，不许拿相邻档的数冒充。）")
    # 退出码也是判据的一部分：脚本化的比较（"这趟能不能进表"）只看 rc，
    # 光在表头上多打一行 ⚠ 会被下一环当成绿灯放过。
    return 0 if period_eligibility(meta)[0] else 3


# 【拆分的形状】原先这七节从头到尾挤在 `cmd_summary` 一个函数里（131 行 / CC 63，
# 全仓"最大 CC"就是它），拆成「一节一个 `summary_*` 小方法」之后：
# 每一节的判据、格式串、`fmt_row` 的四列文字与判定词**逐字未动**，
# 只有跨节共享的两个量（`loaded` 与 `budget`）改成显式传参。
# 对照证据：`/tmp/x5-before.txt` 与 `/tmp/x5-after.txt` 逐字相同（驱动器见笔记）。
SUMMARY_KEYS = ("hitches", "hitches-updates", "hitches-renders", "potential-hangs",
                "hitches-framewait", "hitches-gpu", "hitches-frame-lifetimes",
                "device-display-info", "displayed-surfaces-per-second", "time-profile")


def summary_load(d):
    """七节各取一份读数（XML 优先、脚本顺手写的 JSON 次之、都没有 = 未覆盖）。"""
    loaded = {}
    for key in SUMMARY_KEYS:
        loaded[key] = load_measure(d, key)
    return loaded


def period_eligibility(meta):
    """档位**声明**与收尾**复核**是否一致 → (样本可用吗, 给表头看的一句话)。

    `perf_preflight.sh` 在录制窗口结束后会**再问一次**人手探针，把结论写进 meta：
      interaction 档 → `no_human_input_during_window=1`：整窗一次人手都没有 ⇒ 那批量的是心跳期；
      idle 档        → `contaminated_by_human_input=1`：窗口里有人动手 ⇒ 样本被污染。
    这两个标记此前**只有写的人、没有读的人**（全仓 grep 只有一个写点），
    于是"没人配合"的那一趟照样能打印「有资格答 T1」。
    ⇒ 写进 meta 不等于被看见；判资格必须把复核读回来。
    """
    period = str(meta.get("period") or "idle")
    # 窗口结束时整机在忙 ⇒ 两档都不作数（争用会把 hitch 间隔压到每帧一次，见交接笔记 §AB）。
    # 与「人手污染」同一条纪律：**写进 meta 的标记必须有读者**，否则等于没记。
    if str(meta.get("contaminated_by_foreign_load") or "") == "1":
        return False, ("窗口结束时负载显示整机在忙（meta.load1_at_end / heavy_at_end）"
                       "⇒ 这批量的是别人占着机器时的帧，不得作为结论提交")
    # 输入来源**与投递节奏**决定这句话能不能说"真人"、能不能答"到不到 120Hz"。
    # 25 Hz 的合成滚动器（每 40 ms 一拍）比 8.333 ms 的帧预算还慢，出帧上限是仪器锁的
    # —— 今晚实测过，那两批差点被当"交互期 hitch 读数"直接引用（现已移出充数）。
    # 混为一谈就是造假证据：合成输入答不了主观手感，慢节奏连"到不到 120Hz"都答不了。
    rate_ok, tag = input_rate_qualification(meta.get("input_source"))
    if period == "interaction":
        if str(meta.get("no_human_input_during_window") or "") == "1":
            return False, ("声明交互期，但收尾复核记着**整窗没一次人手事件** ⇒ 不可当交互期样本，"
                           "要判 T1 得重录并真的持续滚动")
        if not rate_ok:
            return False, (tag + " ⇒ 这一档不许交 T1：判据里的 p95 帧间隔，"
                           "正好是被输入节奏锁死的那一维")
        return True, tag + "有资格答 T1（交互期 hitch = 0）"
    if str(meta.get("contaminated_by_human_input") or "") == "1":
        return False, ("声明心跳期，但收尾复核记着**窗口内有人动手** ⇒ 样本已污染，"
                       "不得进前后对比表")
    return True, "只答心跳期；**不许**拿去交 T1，要判 T1 用 interact 档重录"


def refusal_headline():
    """被打回那一趟，表头该喊的那一句（**不含拒因**）。

    原先这里一律写「档位声明与收尾复核**互相矛盾**」。那是个**指错方向**的话术：
    `contaminated_by_foreign_load` 那批里，声明与复核完全一致（确实是心跳期、确实没人动），
    被打回是因为**整机在忙**。2026-09-23 20:49 三趟 idle 就是这种形状，而那句"互相矛盾"
    把我带去查一个根本不存在的期间谎报——话术把排查方向带走，和漏印一行一样贵。
    ⇒ 拒因只住在 `period_eligibility` 返回的那一句里（表头上一行刚印它），这一行只说"打回"。
    """
    return ("本趟被收尾复核打回 ⇒ 读数只当过程记录，不得作为结论提交；具体拒因就在上一行")


def summary_header(meta):
    # 【期间必须出现在表头上】§1 基线是**心跳期**（不去碰它）量的，T1 要的是**交互期**。
    # 两者同形状、不同含义——不在表头写清楚，过两周就有人会拿心跳期的 HTR 去交交互期的结论。
    period = str(meta.get("period") or "idle")
    eligible, verdict = period_eligibility(meta)

    print("== Tcoder 性能读数（对照 spec §1 基线 rev %s，release 口径）==" % BASELINE["rev"])
    print("   测量期间：%s —— %s" % (period, verdict))
    # 报的是**哪一页**必须跟着数走：今天所有交互档都没设 `MEASURE_SECTION`，
    # 也就是量的都是「总览」——而 §Q 的 14 处里 11 处不在这页上。
    # 不印这一行，下一个人就会拿"总览页的 render p50"去验收"日志页的排序"。
    print("   测量页面：%s" % (meta.get("section") or "未记录（按默认页＝总览处理）"))
    if not eligible:
        # 被打回的样本要**吵**：安静地少打一行说明，就等于让它在表里蒙混过去。
        # 但这一行**不许指名拒因**——原因只住在 `period_eligibility` 那一句里（上一行刚印过）。
        print("   ⚠ " + refusal_headline())
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


def app_update_verdict(values, budget):
    """把"哪些迟到帧是主线程算出来的、哪些不是"分开说 —— 只报 max 会把两者混成一锅。

    两种形状要分开说：**少数孤例**（<20% 行超预算）才配得上「stall N 个」；
    **整表贴着一帧**（≥20%）那是单位问题，不是卡顿清单（09-23 改判，理由见下面那段注释）。

    2026-09-21 的实证：交互期那份读数 `app-update` 打的是 `超 20.2 倍`（max 168.3 ms），
    而 602 个迟到帧的 update 相位 **p95 只有 3.4 ms** —— 绝大多数迟到跟主线程没关系，
    是渲染/合成侧的事；那一次 168 ms 才是真的主线程 stall。
    一行"超 20.2 倍"把这两件事同时盖住了：既夸大了整体，又差点让人漏掉那个孤例。
    """
    vals = [v for v in (values or []) if v is not None]
    if not vals:
        return "无 app-update 记录", "—"
    over = [v for v in vals if v > budget]
    line = "p50 %.2f / p95 %.2f / max %.2f ms（n=%d，超预算 %d 个）" % (
        percentile(vals, .5), percentile(vals, .95), max(vals), len(vals), len(over))
    if not over:
        return line, "达标（没有一个 update 超预算）"
    share = 100.0 * len(over) / len(vals)
    if share >= 20.0:
        # 09-23 改判：**普遍超预算不再叫「N 个 stall」**。同一趟里上屏实测 119~120 帧/秒，
        # 而这张表 88% 的行都超过一帧预算（2090 行、p50 9.89 ms）——
        # 两个数只有在"行数≠迟到帧、单位待核"时才互相自洽。
        # 老话术"主线程 stall 1841 个"正是我刚在归因行撤掉的同一个 over-claim，只是住在另一支函数。
        return line, ("%d/%d 行（%.1f%%）超一帧预算 ⇒ 整表贴着一帧，**不许按「多少个卡顿」读**"
                      "（单位待核，见该表的 ⚠ 行）；最长孤例 %.1f ms = %.1f 倍预算，那一个才单独查"
                      % (len(over), len(vals), share, max(over), max(over) / budget))
    return line, ("主线程 stall %d 个（占 %d 行的 %.1f%%，最长 %.1f ms = %.1f 倍预算）；"
                  "其余 %d 行未超预算（p95 %.2f ms）⇒ 那些迟到与主线程无关"
                  % (len(over), len(vals), share, max(over), max(over) / budget,
                     len(vals) - len(over), percentile(vals, .95)))


def summary_app_update_row(loaded, budget):
    # 3) app-update 相位（一次 hitch 通常拆成 Brown+Red 两行，同 duration 走 ref）
    upd = dedupe_pairs(loaded["hitches-updates"])
    if upd:
        cur, verdict = app_update_verdict(upd, budget)
        fmt_row("app-update 单次耗时(ms)", base_app_update_line(), cur, verdict)
    else:
        fmt_row("app-update 单次耗时(ms)", base_app_update_line(),
                "无 app-update = 无 hitch" if loaded["hitches-updates"]["present"] else "未覆盖", "—")


def hitch_regime_suffix(loaded, budget):
    """越出标称刷新率档时，hitch/HTR 的判定后缀（在档内则空串）。

    【为什么要有这条】预算 8.333 ms 只对 **120 Hz 档**成立。窗口静止时 ProMotion 会把
    实际出帧降到 ~50 Hz，那时一帧本就该花 ~20 ms —— 拿 120 Hz 的尺子去判，
    "超预算帧数"与 HTR 会**系统性偏坏**。2026-09-21 就被这样一份 idle 读数唬过一次
    （HTR 18.33「危急·立刻处理」，而同一份数据里主线程 88.6% 在等事件、整窗零输入）。
    做成纯函数是为了能被合成夹具双向钉住（selfcheck 第 25 项）。
    """
    fps = (loaded or {}).get("displayed-surfaces-per-second") or {}
    # 只有"确实采到过这张表"才去解析它：`json` 缺席就重解析 XML 会让**每一趟 idle**
    # 都为这句话多跑一次 XML，而且合成夹具里没有 `doc` 键时直接 KeyError。
    counts = fps.get("json")
    if not counts and fps.get("present"):
        counts = fps_counts(fps)
    achieved = (counts or {}).get("fps_p50")
    if in_display_regime(achieved, budget):
        return ""
    return "｜实测出帧 %s/s，已不在 %.1f Hz 档 ⇒ 不判档，只记形状" % (achieved, 1000.0 / budget)


def summary_hitch_rows(loaded, seconds, budget):
    # 4) hitch 次数 / 速率
    hitch = disp_values(loaded["hitches"])
    suffix = hitch_regime_suffix(loaded, budget)
    if loaded["hitches"]["present"]:
        rate = (len(hitch) / seconds) if seconds else 0.0
        fmt_row("hitch 次数 / 速率", base_hitches_line(),
                "%d 次 / %ds = %.2f /s" % (len(hitch), seconds, rate),
                "达标(0 次)" if not hitch else (("超(预算 0)" if rate < 1.0 else "严重超(>=1/s)") + suffix))
        fmt_row("hitch 帧时长", base_hitch_frame_line(),
                ("%.2f~%.2f ms" % (min(hitch), max(hitch))) if hitch else "无 hitch",
                ("超" if hitch and max(hitch) > budget else "达标") + suffix)
        # Hitch Time Ratio：Apple 的正式指标（tech-talk 10855）——
        # 本实现取 Σ max(0, 帧时长 − 预算) / 秒数，是"晚了多少"的保守上界。
        # 档位（Apple 原文）：<5 无感 / 5~10 可察觉需排查 / >10 危急需立刻处理 / 理想 0。
        htr = (sum(max(0.0, d - budget) for d in hitch) / seconds) if seconds else 0.0
        band = "理想(0)" if not hitch else ("无感" if htr < 5 else ("可察觉·需排查" if htr <= 10 else "危急·立刻处理"))
        fmt_row("Hitch Time Ratio (ms/s)", "%.2f（危急档）" % BASELINE.get("hitch_time_ratio_ms_per_s", 12.9),
                "%.2f（%d 帧迟到，预算 %.3f ms）" % (htr, len(hitch), budget), band + suffix)
    else:
        fmt_row("hitch 次数 / 速率", base_hitches_line(), "未覆盖", "—")
        fmt_row("hitch 帧时长", base_hitch_frame_line(), "未覆盖", "—")
        fmt_row("Hitch Time Ratio (ms/s)", "%.2f（危急档）" % BASELINE.get("hitch_time_ratio_ms_per_s", 12.9),
                "未覆盖", "—")




def summary_frame_table_rows(loaded, budget):
    """三张逐帧表 + 一行把 `hitches` **降级为旁证**的说明。"""
    for label, cur, verdict in frame_table_rows(loaded, budget):
        fmt_row(label, "—", cur, verdict)
    fmt_row("hitch 行数（下游计数）", "—", "只作旁证，不单独定达标",
            "判 T1 用上面三张逐帧表 + 呈现侧 p95：同一份内容三趟报过 14 / 22 / 364 行，"
            "变的只是流水线延迟档位（§AC）")


def summary_phase_blame_row(loaded, budget):
    # 4b) 迟到帧到底该怪谁：主线程 update 也超预算的，和"主线程没问题、渲染/合成侧慢了"的
    upd = dedupe_pairs(loaded["hitches-updates"])
    late = disp_values(loaded["hitches"])
    line, verdict = phase_blame(upd, late, budget)
    fmt_row("迟到帧归因（update vs render）", "—", line, verdict)


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



