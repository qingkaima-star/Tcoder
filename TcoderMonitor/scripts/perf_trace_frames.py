#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""逐帧三张表的判据层（spec §6.1 的 §AC）：表名、每表自己的预算倍率、判定话术。

为什么单独一个模块：`perf_trace_summary.py` 撞上本仓「巨大文件 >400 行」口径
（`.py` 也算实现文件），而这一层是**纯判据**、不 print，切出去最干净。
`summary_frame_table_rows`（要 `fmt_row` 印表）仍住在 summary 那边。
判据、话术、单位错三课的注释逐字未动。
"""

from perf_trace_metrics import disp_values, percentile

PER_TABLE_BUDGETS = (("hitches-framewait", 1.5, "每帧排队等待(ms)"),
                     ("hitches-gpu", 1.0, "每帧 GPU 用时(ms)"),
                     ("hitches-frame-lifetimes", None, "每帧内容寿命(ms)"))


def frame_table_rows(loaded, budget):
    """逐帧三张表 ⇒ [(标签, 现量, 判定)]。**每张表配自己的预算**（spec §6.1 的 §AC）。

    为什么非分开不可：`hitches-frame-lifetimes` 一帧一行，p50 天生就是 **25 ms（≈3 帧）**——
    拿 8.333 ms 去判它，会得到"100% 超预算"这种毫无意义的话（与包 10 的 `hitches-updates`
    同一类单位错）。而 `framewait` 的 p50 ≈ 8.9 ms 是"每帧排队的等待"，
    对 1.5× 帧预算才是有意义的判据；`gpu` 对 1× 帧预算。
    做成纯返回（不 print）是为了能被合成夹具双向钉住（selfcheck 第 42 项）。
    """
    rows = []
    for key, mult, label in PER_TABLE_BUDGETS:
        m = loaded.get(key) or {"present": False}
        # 先判表在不在，**再**去取它的数：`disp_values` 会读 `measure["doc"]`，
        # 而缺席的那个合成字典根本没有 `doc` 这一格（夹具按 `frame_table_rows({})`
        # 一调就 KeyError —— 生产里 `loaded` 总有键，所以这条只有夹具能撞见）。
        if not m.get("present"):
            # 判定列要自己出声：读者扫的是第三列，写「—」就等于把"这张表没导出"藏起来
            # （与 §6.6「缺数据按未覆盖明写」同一条纪律，也是第 42 项现在钉的东西）。
            rows.append((label, "未覆盖（这份 trace 里没有这张表）", "未覆盖 ⇒ 不判"))
            continue
        vals = [v for v in disp_values(m) if v is not None]
        if not vals:
            rows.append((label, "0 帧（表在但没读数）", "0 读数 ⇒ 不判"))
            continue
        p50, p95 = percentile(vals, .5), percentile(vals, .95)
        cur = "p50 %.2f / p95 %.2f / max %.2f（n=%d，一帧 %.2f ms）" % (
            p50, p95, max(vals), len(vals), budget)
        if mult is None:
            rows.append((label, cur, "不判单帧预算：内容寿命天生是几帧（p50 ≈ %.1f 帧）"
                         % (p50 / budget)))
            continue
        bar = budget * mult
        over = sum(1 for v in vals if v > bar)
        rows.append((label, cur,
                     "达标（0 帧超 %.2f ms）" % bar if not over
                     else "%d 帧超 %.2f ms（%.2f%%）" % (over, bar, 100.0 * over / len(vals))))
    return rows
