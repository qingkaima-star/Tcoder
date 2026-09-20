#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xctrace 导出 XML 的解析层：id/ref 解引用 + 独立复核。本仓性能读数的唯一入口。

## 为什么必须有这个文件（口径，不是客套话）

`xcrun xctrace export --xpath` 出来的 XML 用 **id / ref 内部引用做去重**：
同一个值只在**首次出现**的行里带完整文本，之后所有行只写 `<duration ref="2"/>`。
所以直接对 `<duration ...>数字</duration>` 正则计数，会得到
"2340 帧里只有 47 帧"、"每线程 1 个样本" 这类**假读数**（总工在 `465f5a6` 基线实测踩过）。
任何统计都只走 `Doc.rows()`，不要在别处再写一遍 `<duration>` 正则。

## 分层（2026-09-20 拆）

原来三件事挤在 `trace_report.py` 一个文件里，819 行撞了本仓 ≤800 行棘轮
（`SelfScanDogfoodTests`，分母含 `.py`，ceiling=0）。按层拆开后各自独立可测：

    perf_trace_xml.py      本文件：解析层（id/ref、Time Profiler 栈、独立复核）
    perf_trace_metrics.py  统计层与 §1 基线常量
    trace_report.py        子命令与 CLI（perf_harness.sh 调的是它）

数据口径提醒：release 与 debug 的绝对值不可混比（火焰图归因用 debug，交付数用 release），
详见 scripts/perf_harness.sh 头注。
"""

import html
import os
import re


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
