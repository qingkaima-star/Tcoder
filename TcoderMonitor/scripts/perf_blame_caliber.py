#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""「迟到帧到底该怪谁」这一行的判据层（原住 `perf_trace_metrics.phase_blame`）。

搬出来的原因不是"整洁"，是两把门同时压着：加进第三路输入之后 `phase_blame` 的 CC 涨到 18
（尺子自己的门是 CC<16），而宿主文件也顶到 391 行（400 口径）。**拆，不抬线**：
判据、话术、注释逐字搬来，一格一个函数，`phase_blame` 只留"走哪一格"。
⇒ 副作用是好的：每格话术现在能被单独喂夹具（selfcheck 第 27 项的八种形状）。

三条纪律住在这里：
1. **两张表的计数比不等于归因**——窄分布（单位不是占用时长）与比值悬殊（两表不同源）都不给归因；
2. **update 相位没超 ≠ 主线程没被占住**——`potential-hangs` 是第三路输入（#46），
   有 hangs 时不许写"迟到全在渲染/合成侧"；
3. **没有 hangs 时旧话术一字不动**——新维度不许变成"什么都判不成立"的永真绿。
"""

from perf_trace_metrics import interval_shaped


def blocked_note(blocked):
    """主线程被占住的**第三种证据**：`potential-hangs` 里那些测量区间之外的块。

    实测 `03a2219-t2b-idle-run1`：归因行说"主线程只占 4 次"，同一张表里 hangs 是
    5 次 / 累计 2725 ms / 最长 887 ms，两行之间原来没有任何连线。
    """
    vals = [v for v in (blocked or []) if v is not None]
    if not vals:
        return ""
    return ("｜另有主线程阻塞 %d 次 / 累计 %.0f ms（最长 %.1f ms）＝**在 update 相位的测量区间之外**"
            % (len(vals), sum(vals), max(vals)))


def absent_hitch_verdict(note):
    """这一窗没有迟到帧：没 hangs 就是"没什么可判"，有 hangs 要点名"主线程被占住过"。"""
    if not note:
        return "—"
    return "不判：无迟到帧可归因，但主线程这一窗被占住过"


def blame_count_line(over, late):
    """现量列那句话。超预算次数比迟到帧还多时说"倍数"，别说"百分比"（那是 7671% 那种话）。"""
    if over > len(late):
        return "update 超预算 %d 次 vs 迟到 %d 帧（前者是后者的 %.1f 倍）" % (
            over, len(late), float(over) / len(late))
    return "update 超预算 %d 次 vs 迟到 %d 帧（比 %.0f%%）" % (
        over, len(late), 100.0 * over / len(late))


def update_clean_verdict(note):
    """一次 update 都没超预算：只有**同时**没有 hangs 才许把迟到整体归给渲染/合成侧。"""
    if note:      # 这一格是 #46 的正身：旧话术在这里把"相位没超"说成了"主线程没被占住"
        return ("update 相位一次没超，**但**这一窗主线程被占住过 ⇒ "
                "归因未定，先查是谁占住主线程（time-profile 忙样本），"
                "不许写成「迟到全在渲染/合成侧」" + note)
    return "主线程一次都没超 ⇒ 迟到全在渲染/合成侧，别改视图更新常数"


def narrow_table_verdict(ups, budget_ms):
    """update 表是窄分布 ⇒ 它的单位不是占用时长，次数比定不了归因。"""
    return ("不判：该表逐值下限 %.2f ms（≈%.1f 帧）＝按事件节拍计，"
            "它的次数比不能定归因 ⇒ 看 render 相位与 time-profile 的 Main Thread 忙样本"
            % (min(ups), min(ups) / budget_ms))


def unmatched_ratio_verdict(over, late):
    """比值悬殊（>1.5×）：09-23 真数据逼出来的形状——超预算 1841 次 vs 迟到 24 帧（76.7 倍），
    可上屏实测仍是 119~120 帧/秒。三个数只有在"这张表的行数与帧不是一一对应"时才互相自洽
    ⇒ 比值里**没有归因信息**，硬要说"先查主线程"就是拿计数比当证据。"""
    return ("不判：超预算次数是迟到帧的 %.1f 倍 ⇒ 两张表不同源，比值不含归因信息；"
            "归因看 render 相位（本次实测）与 time-profile 的 Main Thread 忙样本"
            % (float(over) / len(late)))


def share_verdict(over, late, note):
    """剩下的两种：几乎一比一（查主线程）与只占一小部分（分开修）。"""
    if 100.0 * over / len(late) >= 80:      # 「一比一」只在两表次数**可比**时才说
        return "几乎一比一 ⇒ 先查主线程 update（视图粗粒度失效那一族）"
    tail = ""
    if note:      # 没有 hangs 的时候不许说"另见 hangs"（那是把不存在的证据指给读者）
        tail = "（这一句只覆盖 update 相位）" + note
    return ("主线程只占 %d 次，其余 %d+ 次要去渲染/合成侧找 ⇒ 两件事分开修%s"
            % (over, max(0, len(late) - over), tail))


def phase_blame(updates, hitch_frames, budget_ms, blocked=None):
    """把"迟到帧"按"主线程 update 是否同时超预算"分开数 —— 决定该去查谁。

    只看 hitch 数会误诊：42 个迟到帧里只有 13 次 update 超预算 ⇒ 多数迟到与主线程无关，
    去优化 `_updateViewGraph` 的常数是白工；反之若几乎一比一，才该查视图更新。
    两边都按"次数"报，**不假装一次迟点对应一次 update**（Brown/Red 会出两行）。
    每格的话术住在各自的函数里（见本文件顶部），这里只决定走哪一格。
    """
    ups = [v for v in (updates or []) if v is not None]
    late = [v for v in (hitch_frames or []) if v is not None]
    note = blocked_note(blocked)
    over = sum(1 for v in ups if v > budget_ms)
    if not late:
        return "本窗口无迟到帧" + note, absent_hitch_verdict(note)
    line = blame_count_line(over, late)
    if over == 0:
        return line, update_clean_verdict(note)
    if interval_shaped(ups, budget_ms):
        return line, narrow_table_verdict(ups, budget_ms)
    if over > 1.5 * len(late):
        return line, unmatched_ratio_verdict(over, late)
    return line, share_verdict(over, late, note)
