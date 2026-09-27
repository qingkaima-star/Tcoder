#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""perf_comparability.py —— **跨趟能不能放在一起比**这一层（可比条件），由 `perf_trio_agreement.py` import。

为什么单独一个文件（2026-09-27，#129）：`perf_trio_agreement.py` 加进这两枚函数之后涨到 **424 行**，
越过本仓「实现文件（含 `.py`/`.sh`）≤400 行」那把门（`SourcesSizeAuditTests`，与产品自扫的
「巨大文件」同一条口径）。这里只有一个动作可用：**拆文件才是修复**——抬线、往挂账清单塞条目、
把文件挪出扫描面都不算（同族第 8 次）。切在「一致性散布怎么算（那里）vs 这几趟是不是一种条件（这里）」
这条天然缝上，判据一字未改地搬过来。

【这一层管什么】spec 里有两纸**只被写进 meta、从来没人读过**的规矩：
· §7.3 —— release 与 debug 产物的**绝对值永不混比**（落盘格：`build_flavor`）；
· §7.5 —— 采样期间**独占实例**；多实例下取的读数只能与同样多实例的另一批比（落盘格：`coexisting_instances`）。
两格并池比对散布时如果不问，读出来的是"三趟一致/不一致"，而真相是"这三趟根本不该放在一起"。

⚠ **缺格不追溯**：老批次 meta 里没有这两格（盘上现量 8 批）⇒ 空值不参与判定，
只有**观测到不同**或**某一趟自己写着「未知」**才不判。把"缺"一律判死会顺手改动历史读数，
那要另开一次裁定，不该藏在一个修 bug 的 diff 里（与 #127／#128 同一条裁定）。
"""


def comparability_of(meta):
    """meta → 两维可比条件的读数；缺格给 ""（＝这一维不参与判定，不是"合格"）。

    单独一枚是为了让**键名只出现一次**：常驻臂可以直接喂 meta 字典验这两个键
    （`build_flavor`／`coexisting_instances`），改名或漏读会当场红，
    而不必为了测一条映射去造一整套能过 `summary_load` 的表夹具。
    """
    return {"flavor": str(meta.get("build_flavor") or ""),
            "coexist": str(meta.get("coexisting_instances") or "")}


def comparability_precheck(got):
    """并池前问两维「这些趟是不是同一种可比条件」：**条件不同一律不判**。

    → (话术行, 退出码 2) 或 None。#127／#128 是"一趟之内没落盘"，这一条是同一族第三副面具：
    **落了盘、跨趟没人比**。退出码用 2（与"样本不足／混档"同一档）——那是"这把尺没有对象"，
    不是"量出来不一致"，两者不许混成一个红灯。
    """
    dims = (("flavor", "产物口径（release/debug）", "spec §7.3"),
            ("coexist", "共存实例数", "spec §7.5"))
    for key, cn, ref in dims:
        vals = [str(r.get(key) or "") for r in got]
        unknown = [v for v in vals if v.startswith("未知")]
        if unknown:
            return (["   判定：**不判**——有一趟的%s自己写着「%s」（%s）⇒ 按它自己的标签这批就不可比"
                     % (cn, unknown[0][:40], ref)], 2)
        known = [v for v in vals if v]
        if len(set(known)) > 1:
            return (["   判定：**不判**——这些趟的%s不同（%s），%s 要求可比条件一致"
                     % (cn, " / ".join(sorted(set(known))), ref)], 2)
    return None
