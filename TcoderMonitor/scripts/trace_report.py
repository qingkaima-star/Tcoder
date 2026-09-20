#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xctrace 导出 XML → 固定形状的性能读数（帧节拍 / hitch / 主线程热点）。

## 为什么必须有这个文件（口径，不是客套话）

`xcrun xctrace export --xpath` 出来的 XML 用 **id / ref 内部引用做去重**：
同一个值只在**首次出现**的行里带完整文本，之后所有行只写 `<duration ref="2"/>`。
所以直接对 `<duration ...>数字</duration>` 正则计数，会得到
"2340 帧里只有 47 帧"、"每线程 1 个样本" 这类**假读数**（总工在 `465f5a6` 基线实测踩过）。
本文件的唯一入口是 `Doc`：先把 `id -> (标签, fmt, 原始值)` 建成注册表，
再逐行按 id/ref 解析，**任何统计都只走 `Doc.rows()`**。

## 子命令（`perf_harness.sh` 按这些形状调用，改形状要同步改它）

    trace_report.py durations <xml> [--label 名] [--budget-ms 8.333]  # 时长分布 n/p50/p95/p99/max
    trace_report.py threads <xml> [--thread "Main Thread"] [--top 20] [--leaf 12] [--pairs 12]
    trace_report.py displays <xml>                                   # device-display-info：分辨率与最大 Hz
    trace_report.py fps <xml> [--display 名]                          # displayed-surfaces-per-second：出帧
    trace_report.py summary <输出目录> [--seconds N]                    # 出 spec §1 的同形状对照表

## 分位数定义（与 §1 基线可比，不许悄悄换算法）

`percentile()` 用 **int(n·p) 取整下标**（与 §1 基线脚本 `parse.py` 同一口径）。
换成分位定义 = 前后两批数字不可比 = 回归门禁失效。

数据口径提醒：release 与 debug 的绝对值不可混比（火焰图归因用 debug，交付数用 release），
详见 scripts/perf_harness.sh 头注。
"""

import argparse
import collections
import html
import json
import os
import re
import statistics
import sys

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
    "main_thread_samples": 684,
    "main_thread_total_samples": 807,
    "main_thread_share_pct": 84.8,
    "hotspot_top1_pct": 64.3,
    "hotspot_top1": "ViewGraphRootValueUpdater._updateViewGraph",
}

FRAME_BUDGET_MS_DEFAULT = 8.333  # 120 Hz 下单帧预算，实测 Hz 不同时由 --budget-ms 覆盖


# ----------------------------------------------------------------------------
# 解析层：id/ref 去重
# ----------------------------------------------------------------------------

class Cell:
    """一行里的一个列值：fmt 给人看，raw 给算术。"""

    __slots__ = ("tag", "fmt", "raw")

    def __init__(self, tag, fmt, raw):
        self.tag = tag
        self.fmt = fmt
        self.raw = raw

    def num(self):
        try:
            return int(self.raw)
        except (TypeError, ValueError):
            return None

    def ms(self):
        v = self.num()
        return None if v is None else v / 1_000_000.0

    def __repr__(self):
        return "<%s %r>" % (self.tag, self.fmt)


class Doc:
    """一份导出 XML。注册表按 id 建，行内 ref 一律回查——这是本文件存在的理由。"""

    def __init__(self, path):
        self.path = path
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            self.text = fh.read()
        self.registry = {}
        self._build_registry()
        self._rows = None

    # xctrace 的 id 是元素属性，形如 <duration id="2" fmt="33.33 ms">33333333</duration>
    _ID_PAT = re.compile(r'<([a-zA-Z][\w.-]*)\s+id="(\d+)"([^>]*)>(.*?)</\1>', re.S)
    _ID_PAT_EMPTY = re.compile(r'<([a-zA-Z][\w.-]*)\s+id="(\d+)"([^>]*)/>')
    _ROW_PAT = re.compile(r"<row>(.*?)</row>", re.S)
    _REF_PAT = re.compile(r'<([a-zA-Z][\w.-]*)\s+ref="(\d+)"[^>]*/>')
    _FMT_PAT = re.compile(r'\bfmt="([^"]*)"')

    def _build_registry(self):
        for m in self._ID_PAT.finditer(self.text):
            tag, eid, attrs, body = m.group(1), m.group(2), m.group(3), m.group(4)
            fmt = self._FMT_PAT.search(attrs)
            self.registry.setdefault((tag, eid), Cell(tag, fmt.group(1) if fmt else "", strip_tags(body)))
        for m in self._ID_PAT_EMPTY.finditer(self.text):
            tag, eid, attrs = m.group(1), m.group(2), m.group(3)
            fmt = self._FMT_PAT.search(attrs)
            self.registry.setdefault((tag, eid), Cell(tag, fmt.group(1) if fmt else "", ""))

    def rows(self):
        """返回 [[Cell, ...], ...]：每行按出现顺序给出**已解引用**的列值。"""
        if self._rows is None:
            rows = []
            for body in self._ROW_PAT.findall(self.text):
                cells = []
                for m in self._REF_PAT.finditer(body):
                    c = self.registry.get((m.group(1), m.group(2)))
                    if c is not None:
                        cells.append(c)
                for m in self._ID_PAT.finditer(body):
                    c = self.registry.get((m.group(1), m.group(2)))
                    if c is not None:
                        cells.append(c)
                for m in self._ID_PAT_EMPTY.finditer(body):
                    c = self.registry.get((m.group(1), m.group(2)))
                    if c is not None:
                        cells.append(c)
                rows.append(dedupe_cells(cells))
            self._rows = rows
        return self._rows

    def column(self, tag):
        """整列取值（按标签名，如 'duration'）；refs 也算进来了。"""
        out = []
        for row in self.rows():
            for c in row:
                if c.tag == tag:
                    out.append(c)
                    break
        return out

    def spans(self):
        """(start_ms, duration_ms) 序列——hitches / hangs 这类表都要它。"""
        out = []
        for row in self.rows():
            start = find_tag(row, "start-time") or find_tag(row, "event-time")
            dur = find_tag(row, "duration")
            if start is not None and dur is not None:
                s, d = start.num(), dur.num()
                if s is not None and d is not None:
                    out.append((s / 1_000_000.0, d / 1_000_000.0))
        return out

    def schema(self):
        m = re.search(r'<schema name="([\w-]+)"', self.text)
        return m.group(1) if m else os.path.basename(self.path)


def strip_tags(s):
    return re.sub(r"<[^>]*>", "", s).strip()


def dedupe_cells(cells):
    """同一个 id 在一行里只算一次（如 <process id=3> 与嵌套的 <pid id=4>）。"""
    seen, out = set(), []
    for c in cells:
        key = id(c)
        if key in seen:
            continue
        seen.add(key)
        out.append(c)
    return out


def find_tag(row, tag):
    for c in row:
        if c.tag == tag:
            return c
    return None


# ----------------------------------------------------------------------------
# 统计层
# ----------------------------------------------------------------------------

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


def cross_check_durations(xml_path, tool_values):
    """用一条**独立的、笨到不会错**的逐行正则重解析同一份 XML，与 `Doc` 的结果比对。

    为什么要第二条解析路：`Doc` 的 id/ref 解引用一旦把某行的列错配到别的行，
    输出的仍然是"行数正确、分位数看着也正常"的表——**它不会自己报错，只会静默给错数**。
    实测就是这一条救回来的：`hitches-renders` 两把解析都是 n=2394，
    但判超预算的帧 `Doc` 给 10、逐行重解析给 5，且那 5 个值在 `Doc` 的结果里各出现两次
    ——即有 5 行的时长被错配到了别的行。不一致时报"未报"，绝不挑一个好看的数用。

    返回 (是否一致, 说明文字)。文件读不到时返回 (False, ...)，让调用方标未覆盖。
    """
    try:
        with open(xml_path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError as exc:
        return False, "读不到 %s（%s）" % (os.path.basename(xml_path), exc)
    first = {}
    for m in re.finditer(r'<duration id="(\d+)"[^>]*>(\d+)</duration>', text):
        first.setdefault(m.group(1), m.group(2))
    per_row = []
    for row in re.findall(r"<row>(.*?)</row>", text, re.S):
        m = re.search(r'<duration (?:id="\d+"[^>]*>(\d+)</duration>|ref="(\d+)"/>)', row)
        if not m:
            continue
        raw = m.group(1) or first.get(m.group(2))
        if raw is not None:
            per_row.append(int(raw) / 1_000_000.0)
    a, b = sorted(round(v, 6) for v in per_row), sorted(round(v, 6) for v in tool_values)
    if len(a) != len(b):
        return False, "行数不一致：逐行重解析 %d，Doc 解析 %d" % (len(a), len(b))
    diff = [(i, a[i], b[i]) for i in range(len(a)) if abs(a[i] - b[i]) > 1e-6]
    if diff:
        shown = ", ".join("%.3f↔%.3f" % (x[1], x[2]) for x in diff[:6])
        return False, "%d 处时长不一致：%s%s" % (
            len(diff), shown, "…" if len(diff) > 6 else "")
    return True, "两把解析一致（n=%d）" % len(a)


def over_budget(values, budget_ms):
    bad = [v for v in values if v > budget_ms]
    return len(bad), (100.0 * len(bad) / len(values) if values else 0.0)


# ----------------------------------------------------------------------------
# 栈解析（Time Profiler）
# ----------------------------------------------------------------------------

RUNLOOP_PLUMBING = (
    "RunCurrentEventLoopInMode", "ReceiveNextEventCommon", "_BlockUntilNextEventMatchingListInMode",
    "_DPSBlockUntilNextEventMatchingListInMode", "_DPSNextEvent", "_nextEventMatchingEventMask",
    "CFRunLoopRun", "_CFRunLoopRunSpecific", "-[NSApplication run", "NSApplicationMain",
    "NSMessagePort", "___chkstk_darwin", "start", "libsystem_pthread", "thread_start",
    # App 入口链与链接器产物：每个样本都有，且不指向任何可改的代码
    "runApp", "App.main()", "$main()", "nextEventMatchingMask", "<deduplicated_symbol>",
    "dispatch_main_queue_callback", "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__",
)


PLUMBING_SHARE_PCT = 98.0  # 出现率 >=98% 的帧算"底盘"，不区分样本，也就不含信息


def is_runloop_plumbing(name):
    """事件循环本体 / App 入口链帧：几乎每个主线程样本都含它。

    拿它当"热点第一名"既没有信息量（它永远在），又会把真正可归因的那一帧
    （`465f5a6` 实测是 64.3% 的 `_updateViewGraph`）挤掉，前后两批就不可比了。
    """
    return any(tok in name for tok in RUNLOOP_PLUMBING)


def build_stack_index(text):
    """Time Profiler 的 frame / backtrace / tagged-backtrace 也走 id/ref，同样要解引用。"""
    frames = {}
    # 帧名里的 < > 在 XML 中是实体（&lt; / &gt;），不解开既读不动也让禁用词匹配不上
    for m in re.finditer(r'<frame id="(\d+)" name="([^"]*)"', text):
        frames[m.group(1)] = html.unescape(m.group(2))
    for m in re.finditer(r'<frame id="(\d+)"[^>]*fmt="([^"]*)"', text):
        frames.setdefault(m.group(1), html.unescape(m.group(2)))
    bts = {}
    for m in re.finditer(r'<backtrace id="(\d+)"[^>]*>(.*?)</backtrace>', text, re.S):
        seq = []
        for f in re.finditer(r'<frame (?:id="(\d+)"|ref="(\d+)")', m.group(2)):
            fid = f.group(1) or f.group(2)
            if fid in frames:
                seq.append(frames[fid])
        bts[m.group(1)] = seq
    tbs = {}
    for m in re.finditer(r'<tagged-backtrace id="(\d+)"[^>]*>(.*?)</tagged-backtrace>', text, re.S):
        b = re.search(r'<backtrace (?:id="(\d+)"|ref="(\d+)")', m.group(2))
        if b:
            tbs[m.group(1)] = bts.get(b.group(1) or b.group(2), [])
    threads = {m.group(1): m.group(2)
               for m in re.finditer(r'<thread id="(\d+)" fmt="([^"]*)"', text)}
    return frames, bts, tbs, threads


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


def cmd_summary(args):
    d = args.directory
    loaded = {}
    for key in ("hitches", "hitches-updates", "hitches-renders", "potential-hangs",
                "device-display-info", "displayed-surfaces-per-second", "time-profile"):
        loaded[key] = load_measure(d, key)

    meta = read_json(os.path.join(d, "meta.json")) or {}
    seconds = args.seconds or meta.get("hitches_seconds") or meta.get("seconds") or 0

    print("== Tcoder 性能读数（对照 spec §1 基线 rev %s，release 口径）==" % BASELINE["rev"])
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
        fmt_row("Hitch Time Ratio (ms/s)", "11.67（危急档）", "未覆盖", "—")

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
        print("| %-14s | %-14s | %-18s | %s |" % (page[:14], cur[:14], total, longest))
        n += 1
    if n == 0:
        print("!! %s 下没有逐页子目录：switch 档没跑过或跑了 DRY_RUN" % root)
    print("（首帧口径 = 带采样器、窗口出现即算；比裸启动慢，只用于页间横向比较。）")
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
    return p


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not os.path.isfile(getattr(args, "xml", None) or "") and getattr(args, "xml", None):
        print("!! 找不到文件: %s" % args.xml, file=sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
