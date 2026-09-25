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

## 第四条（09-24 需求方裁定 A）：idle 档不再比每趟极值的极差比

`app-update` 的 max 是**极值统计量**：同一趟内部自助重抽（k=1→12）期望 max 就能涨 1.2~1.8 倍，
所以"重复到一致"对它是**不会终止的协议**——多一趟只会把极差比撑得更大（实测五趟 2.1×）。
⇒ idle 档改比**每趟自身分布**的 p90 与均值（两把都要过带宽）。
"留一趟之后合并 p95"那一版我实现过又撤回：留一池子两两重叠，极差比会随趟数构造性地收敛到 1，
那是比极值判据更坏的"永真绿"（理由写在 `per_run_quantiles`）。
max 仍在报表里逐趟判达标、仍是"最长孤例单独查"那条纪律的输入，**只是不再当重复性判据**。
"""

import argparse
import json
import os
import sys

from perf_trace_metrics import disp_values, fps_counts, percentile
from perf_update_caliber import dedupe_pairs
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


def _meta_or_none(d):
    """一个 run 目录 → 可用的 meta；缺文件、解不动、或被收尾复核打回 ⇒ None。

    分出去只为了让 `read_run` 留在复杂度门内（CC<16、≤50 行），判据一字未动：
    解不动 JSON 与"档位复核不合格"本来就是同一件事（这一趟不参与），归到一个出口更清楚。
    """
    path = os.path.join(d, "meta.json")
    if not os.path.isfile(path):
        return None
    try:
        meta = json.load(open(path, encoding="utf-8"))
    except (ValueError, OSError):
        return None
    # 被收尾复核打回的样本，不参与一致性判定
    if not period_eligibility(meta)[0]:
        return None
    return meta


def _run_reading(d, loaded, secs):
    """把一行的现量凑成 dict。**缺件的格子给 None，不给 0**：
    0 会被下一行读成"这趟测到了 0 帧/0 ms"，而真相是没采到。
    """
    late = [v for v in disp_values(loaded["hitches"]) if v is not None]
    rends = [v for v in disp_values(loaded["hitches-renders"]) if v is not None]
    upd = [v for v in dedupe_pairs(loaded["hitches-updates"]) if v is not None]
    surfaces = loaded["displayed-surfaces-per-second"]
    fps = surfaces["json"] or fps_counts(surfaces)
    return {"dir": os.path.basename(d.rstrip("/")), "seconds": secs,
            "hitch_n": len(late), "hitch_per_s": len(late) / secs,
            "render_p50_ms": percentile(rends, .5) if rends else None,
            "update_values": upd,
            "update_max_ms": max(upd) if upd else None,
            "surfaces_p50_fps": (float(fps["fps_p50"]) if fps and fps.get("fps_p50") else None)}


def read_run(d):
    """一个 run 目录 → dict；读不到 hitch 表 / 没有秒数 / 档位复核不合格 / **有 REFUSED** ⇒ None。

    取数一律走 `summary_load`（与报表同一把尺），**不在这里再解析一遍 XML**：
    同一个问题上多一把尺，两把量错的时候没人怀疑新那把。

    ⚠ `REFUSED` 这一维本文件的头注一直写着"没被 REFUSED"，可代码里没有那个读者——
    09-24 我自己拿一个临时探针数"这趟合格吗"时就把它读成了合格（那一趟前台是别的 App，
    闸门当场拒收并落了 `REFUSED`）。**写进磁盘的标记必须有读者**（与包 7 同一条纪律）：
    挂死的录制会留下上一次的表文件，"表在 + REFUSED 在"就是这格漏的入口。
    """
    meta = _meta_or_none(d)
    if meta is None:
        return None
    if os.path.isfile(os.path.join(d, "REFUSED")):
        return None
    secs = _seconds(meta)
    loaded = summary_load(d)
    if secs <= 0 or not loaded["hitches"]["present"]:
        return None
    reading = _run_reading(d, loaded, secs)
    reading["period"] = str(meta.get("period") or "?")
    return reading


def _spread(vals, unit, bar):
    """极差比 + 一句人话。返回 (比值, 超没超)。"""
    lo, hi = min(vals), max(vals)
    floor = lo if lo > 0 else max(1.0 / 20.0, 1e-6)   # 下界为 0 时不除零：按"一趟一个事件"兜
    ratio = hi / floor
    return ratio, (ratio > bar), "%s 现量 %.2f ~ %.2f ⇒ 极差比 %.1f×（上限 %.1f×）" % (
        unit, lo, hi, ratio, bar)


def _roster_lines(got, missing):
    """把每一趟的现量逐行印出来（缺件的那几趟点名，但不进散布）。"""
    lines = []
    for r in got:
        lines.append("   %-44s 档=%-11s %5.1fs  hitch %4d ⇒ %5.2f /s   render p50 %s  update max %s  出帧 p50 %s"
                     % (r["dir"], r["period"], r["seconds"], r["hitch_n"], r["hitch_per_s"],
                        ("%.2f ms" % r["render_p50_ms"]) if r.get("render_p50_ms") else "—",
                        ("%.2f ms" % r["update_max_ms"]) if r.get("update_max_ms") else "—",
                        ("%.0f/s" % r["surfaces_p50_fps"]) if r.get("surfaces_p50_fps") else "—"))
    if missing:
        lines.append("   缺件/读不出/被复核打回/被当场拒收（有 REFUSED）：%s ⇒ **不参与**散布"
                     "（缺的那趟不许当 hitch=0）" % ", ".join(missing))
    return lines


def per_run_quantiles(runs):
    """每一趟**只用自己的事件**算两个分位 ⇒ ([p90…], [均值…])；一趟空 ⇒ 该位给 None。

    裁定 A 落地时我先写了"留一趟之后合并分布的 p95"，**那版是错的、我自己撤回**：
    k 个留一池子两两重叠 k−2 趟的数据，极差比会随趟数天然收敛到 1，
    等于把"重不重复"这个检验变成构造上永真 —— 比原来的极值判据更糟（那条至少是保守地难）。
    ⇒ 现在两把尺子都用**互不重叠**的每趟自身分布：p90 看形状、均值看整体，
    两者都必须在带宽内才算一致（一条松一条紧时不许挑好听的那条报，与"出帧那一维"同一条纪律）。
    """
    p90, means = [], []
    for one in runs:
        vals = one["update_values"]
        p90.append(percentile(vals, .90) if vals else None)
        means.append(sum(vals) / len(vals) if vals else None)
    return p90, means


def _one_stat_spread(vals, label, bar):
    """一把尺子的散布 ⇒ (告警, 要印的行)。空值不参与，但**参与数不够要出声**。"""
    bad, out = [], []
    have = [v for v in vals if v is not None]
    if len(have) < len(vals):
        bad.append("有 %d 趟 update 表是空的 ⇒ %s 这条尺子没吃到它，不许报一致"
                   % (len(vals) - len(have), label))
    if not have:
        return bad, out
    ratio, over, text = _spread(have, "每趟 %s(ms)" % label, bar)
    out.append("   " + text)
    if over:
        bad.append("每趟 %s 极差比 %.1f× > %.1f×" % (label, ratio, bar))
    return bad, out


def _idle_checks(got):
    """idle 档的三行 + 两把尺子 ⇒ (告警, 要印的行, 主判据量的现量)。

    拆出来只为一句：两把尺子并排判的循环把 `_judge_spread` 的 CC 顶到 24（门 CC<16）。
    **拆，不抬线**（本仓第三次为同一把门让路，前两次的注释就写在尺子名单里）。
    """
    p90, means = per_run_quantiles(got)
    bad, out = [], []
    for label, vals in (("p90", p90), ("均值", means)):
        one_bad, one_out = _one_stat_spread(vals, label, SPREAD_BAR)
        bad += one_bad
        out += one_out
    mx = [r["update_max_ms"] for r in got if r.get("update_max_ms") is not None]
    if mx:
        out.append("   旁证：每趟 max %s ⇒ 极值只逐趟判达标，**不当重复性判据**"
                   "（n≈14 时自助重抽 k=1→12 期望 max 就能涨 1.2~1.8 倍，见交接笔记 §BH）"
                   % "/".join("%.2f" % v for v in sorted(mx)))
    return bad, out, [v for v in p90 if v is not None]


def _judge_spread(got, period):
    """按档位取判据量做散布 ⇒ (告警清单, 要印的行, 判据量名, 该量的现量)。

    【判据量按档位分】这是第一版被我自己的尺子抓出来的错：拿 hitch/s 的极差比去量
    **idle 档**，得到"0.00 ~ 0.95 ⇒ 19.0× ⇒ 不一致"——而 idle 档的 hitch 本来就该在 0 附近
    （静止窗口 ProMotion 还会降频，spec §6.2 明写那一档只记形状不判档）。
    一个真值≈0 的量做除法散布，任何噪声都是"严重不一致"。
    ⇒ 每个档位只比**该档的判据量**：`interaction` 比 hitch/s；`idle` 见 `_idle_checks`
    （每趟自身 p90 与均值两把尺，T2 的达标判据 max 逐趟判、不再当重复性判据）。
    """
    bad, out = [], []
    if period == "idle":
        bad, out, q = _idle_checks(got)
        name = "每趟 p90(ms)"
    else:
        q = [r["hitch_per_s"] for r in got]
        name, bar = "hitch/s", SPREAD_BAR
        if len(q) < len(got):
            bad.append("有 %d 趟没采到该档判据量（%s）⇒ 尺子没对齐，不许只凭另一半报一致"
                       % (len(got) - len(q), name))
        ratio, over, text = _spread(q, name, bar)
        out.append("   " + text)
        if over:
            bad.append("%s 极差比 %.1f× > %.1f×" % (name, ratio, bar))
    fps = [r["surfaces_p50_fps"] for r in got if r.get("surfaces_p50_fps")]
    if len(fps) >= 2 and (max(fps) - min(fps)) > FPS_SPREAD_BAR:
        bad.append("出帧 p50 极差 %.0f 帧/s > %.0f" % (max(fps) - min(fps), FPS_SPREAD_BAR))
    return bad, out, name, q


def verdict(runs, dirs):
    """→ (逐行文字, 退出码)。缺件与不足都**不许**伪装成"一致"。

    判据量的选择与散布怎么算都在 `_judge_spread` 里（连同一句"为什么 idle 档不比 hitch"），
    这里只管三件事：够不够 3 趟、档位齐不齐、结论落在哪个退出码。混档一律不判。
    """
    if not runs:
        return ["!! 一个 run 目录都没给 ⇒ 这支尺子没被喂过数据，别把「没输出」当「通过」"], 2
    got = [r for r in runs if r]
    missing = [os.path.basename(str(d).rstrip("/")) for d, r in zip(dirs, runs) if not r]
    lines = ["== 同档连测的一致性（协议：≥3 趟 **且取值一致**）=="] + _roster_lines(got, missing)
    if len(got) < 3:
        lines.append("   判定：**样本不足**（只有 %d 趟可用，协议要 ≥3）⇒ 不许报「3/3 达标」" % len(got))
        return lines, 2
    periods = set(r["period"] for r in got)
    if len(periods) > 1:
        lines.append("   判定：**不判**——这些趟的档位不同（%s），混档比散布没有意义"
                     % " / ".join(sorted(periods)))
        return lines, 2
    bad, out, name, q = _judge_spread(got, periods.pop())
    lines += out
    if bad:
        lines.append("   判定：**不一致** —— " + "；".join(bad))
        lines.append("   ⇒ 这一档**不能**报「3/3 达标」。要么加趟/排掉被打回的那趟再看一次，"
                     "要么按 spec §1.3 明写「受控重复未满足」。")
        return lines, 1
    lines.append("   判定：一致（两把尺子都在带宽内）。中位 %s %.2f ⇒ 报数时**报中位与范围**，不报均值"
                 % (name, sorted(q)[len(q) // 2]))
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
