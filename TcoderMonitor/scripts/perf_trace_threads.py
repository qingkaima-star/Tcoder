#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Time Profiler 那一层：按线程数样本 + 热点栈 + JSON 落盘（`trace_report.py threads` 的实现）。

为什么单独一个模块（不是新口径）：本仓 ≤800 行棘轮（`SelfScanDogfoodTests`，分母含 `.py`、
ceiling=0）之外，本 App 自己扫出来还有一条「巨大文件 >400 行」——`trace_report.py` 到 644 行。
按已经成立的两层形状再切一刀（解析层 `perf_trace_xml.py`、统计层 `perf_trace_metrics.py`），
把 CLI 编排层里最大的一块（threads 家族，110 行）挪出来。**判据、格式串、正则逐字未动**，
入口仍是 `python3 scripts/trace_report.py threads <xml>`：同目录模块由 Python 自动进 `sys.path`，
`perf_harness.sh` 与 `selfcheck` 档一个字节都不用改。

【热点第一名为什么必须剥事件循环本体】见 `threads_write_json` 里那段原始注释，未改写。
"""

import collections
import re

from perf_trace_metrics import write_json
from perf_trace_xml import PLUMBING_SHARE_PCT, build_stack_index, is_runloop_plumbing


# ----------------------------------------------------------------------------
# threads：Time Profiler 的按线程样本数与热点栈
# ----------------------------------------------------------------------------

def cmd_threads(args):
    with open(args.xml, "r", encoding="utf-8", errors="replace") as fh:
        text = fh.read()
    per, leaf, anyf, pairs = threads_tally(text)
    if not per:
        print("!! 一个样本都没解出来：确认导出的是 time-profile 表（而不是空的 time-profile）")
        return 1
    target, total, total_all = threads_print(args, per, leaf, anyf, pairs)
    threads_write_json(args, anyf, target, total, total_all)
    return 0


# 【拆分的形状】原先 82 行 / CC 41 挤在一个函数里，按「数样本 → 打印 → 落 JSON」
# 三段切开；四个 Counter 与选线程、排序、截断的表达式**逐字未动**。
def threads_tally(text):
    """逐行数样本：每线程计数 + 叶子帧 / 栈中出现 / 调用对三张榜（都带线程名）。"""
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
    return per, leaf, anyf, pairs


def threads_print(args, per, leaf, anyf, pairs):
    """选定目标线程（名字前缀匹配，匹配不上退回样本最多的那条）并打三张榜。"""
    print("== 线程样本数 ==")
    for tname, cnt in per.most_common(8):
        print("  %6d  %s" % (cnt, tname[:70]))

    cand = [t for t in per if t.startswith(args.thread)]
    target = max(cand, key=lambda t: per[t]) if cand else max(per, key=lambda t: per[t])
    total_all = sum(per.values())
    total = per[target]
    print("\n== %s  %d 样本（占全进程 %.1f%%）==" % (target[:60], total, 100.0 * total / max(1, total_all)))
    threads_print_stack_share(args, anyf, target, total)
    threads_print_leaf_and_pairs(args, leaf, pairs, target)
    return target, total, total_all


def threads_print_stack_share(args, anyf, target, total):
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


def threads_print_leaf_and_pairs(args, leaf, pairs, target):
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


def threads_write_json(args, anyf, target, total, total_all):
    if not args.json:
        return
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


