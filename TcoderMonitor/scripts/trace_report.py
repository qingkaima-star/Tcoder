#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""xctrace 导出 XML → 固定形状的性能读数（帧节拍 / hitch / 主线程热点）：子命令与 CLI。

解析层（id/ref 解引用）在 `perf_trace_xml.py`，统计层与 §1 基线常量在
`perf_trace_metrics.py`——三件事原本挤在一个 819 行的文件里，撞了本仓 ≤800 行棘轮
（`SelfScanDogfoodTests`，分母含 `.py`，ceiling=0）。**拆开是修复，拧阈值不是。**

第二轮（WS-X6 规模债，2026-09-21）：≤800 是棘轮，本 App 自扫还有一条「巨大文件 >400 行」，
本文件当时 644 行被点名。于是 CLI 编排层里最大的两块又各自成章——
`threads` 家族在 `perf_trace_threads.py`、`summary` 家族（spec §1 对照表）在
`perf_trace_summary.py`。**判据、格式串、正则、七节顺序逐字未动**，本文件只剩
`durations` / `displays` / `fps` / `lifecycle` / `switches` / `migration` 六个子命令与 CLI。

各模块与本文件同级目录，Python 会自动把脚本所在目录放进 `sys.path`，
所以入口仍是 `python3 scripts/trace_report.py <子命令>`，`perf_harness.sh` 一个字节都不用改。

## 子命令（`perf_harness.sh` 按这些形状调用，改形状要同步改它）

    trace_report.py durations <xml> [--label 名] [--budget-ms 8.333]  # 时长分布 n/p50/p95/p99/max
    trace_report.py threads <xml> [--thread "Main Thread"] [--top 20] [--leaf 12] [--pairs 12]
    trace_report.py displays <xml>                                   # device-display-info：分辨率与最大 Hz
    trace_report.py fps <xml> [--display 名]                          # displayed-surfaces-per-second：出帧
    trace_report.py summary <输出目录> [--seconds N]                    # 出 spec §1 的同形状对照表
    trace_report.py lifecycle <xml>                                   # life-cycle-period：首帧与冷构建周期
    trace_report.py switches <输出目录>                                 # switch 档逐页冷启动

为什么不许直接正则 `<duration>` 计数（假读数的来由）、分位为什么必须按 int(n·p) 取，
分别写在 `perf_trace_xml.py` 与 `perf_trace_metrics.py` 的头注里，那里是唯一口径来源。
数据口径提醒：release 与 debug 的绝对值不可混比，详见 scripts/perf_harness.sh 头注。
"""

import argparse
import collections
import os
import re
import sys

from perf_trace_metrics import (launch_ready_ms, FRAME_BUDGET_MS_DEFAULT, dist_line, interval_shaped, is_window_tail,
                                over_budget, percentile, read_json, window_span_and_tails, write_json)
from perf_trace_summary import cmd_summary
from perf_trace_threads import cmd_threads
from perf_trace_xml import Doc, find_tag
from perf_update_caliber import event_durations, sidecar_payload


# ----------------------------------------------------------------------------
# 时长分布（hitches / hitches-updates / potential-hangs / hitches-renders）
# ----------------------------------------------------------------------------

INTERVAL_SHAPED_TABLES = ("hitches-updates",)


def caveat_for(label, values, budget_ms):
    """这张表的读数**能不能当成"主线程忙了多久"** —— 2026-09-22 22:16 我就是这么误读一次的。

    实测形状（一趟合格的交互档样本，`d73bea4-interact-run1`）：
    `n=1113 p50=10.22 ms`、**逐值下限 9.31 ms**、事件间隔成串是 `8.3, 8.3, 8.3`
    ⇒ 分布不是从 0 铺开的，而是**贴着一帧的基线**；而同一趟的 time-profile 里
    Main Thread 5765 个采样有 99.9% 栈顶是 `TcoderEntry.main()` 事件循环本体（在等，不在忙），
    上屏又是满 120 帧/秒 —— 三者只有在"这行的单位不是占用时长"时才互相自洽。
    所以这里只说**能说的**：这种形状下不许当占用引用；至于它到底是回调间隔还是别的什么，
    留给仪器定义去定（不要靠猜给表贴标签——那正是我这次犯的错的反面）。
    """
    if label not in INTERVAL_SHAPED_TABLES or not values:
        return None
    if not interval_shaped(values, budget_ms):   # 分布从 0 铺开 ⇒ 就是普通的时长，不用提示
        return None                                # 判据住在 `perf_trace_metrics.interval_shaped`，
                                                   # 这里不再抄一份数值（09-23 同一条判据被抄进两支函数，
                                                   # 结果 `phase_blame` 用计数比定了归因）
    return ("⚠ 该表逐值下限 %.2f ms（≈%.1f 帧）且分布极窄 ⇒ **不许当\"主线程忙了多久\"引用**；"
            "主线程占用请看 time-profile 的 Main Thread 忙样本（或明确标注口径待核）"
            % (min(values), min(values) / budget_ms))


def cmd_durations(args):
    doc = Doc(args.xml)
    spans = doc.spans()
    values = [d for _, d in spans]
    events = event_durations(spans)
    print("[%-18s] schema=%s %s" % (args.label or os.path.basename(args.xml), doc.schema(), dist_line(values)))
    if len(events) != len(values):
        # 首行那个 `n` 是**行数**；不点名就会又变成"两处入口两个数"（09-24：28 vs 17 同名 app-update）
        print("%22s 口径：首行 n 是行数 ⇒ 按 (起始,时长) 收成事件=%d 个，超预算 %d 个"
              "（汇总表与一致性尺读的是**事件**口径）"
              % ("", len(events), over_budget(events, args.budget_ms)[0]))
    if values:
        bad, pct = over_budget(values, args.budget_ms)
        print("%22s 累计=%.0f ms 超预算(>%.3f ms)=%d (%.2f%%)"
              % ("", sum(values), args.budget_ms, bad, pct))
        caveat = caveat_for(args.label, values, args.budget_ms)
        if caveat:
            print("%22s %s" % ("", caveat))
        ordered = sorted(round(v, 2) for v in values)
        head = ordered[:20]
        print("%22s 逐值=%s%s" % ("", head, " …（共 %d 个）" % len(ordered) if len(ordered) > 20 else ""))
        if args.with_phases:
            starts = sorted(s for s, _ in spans)
            gaps = [round(b - a, 1) for a, b in zip(starts, starts[1:])]
            print("%22s 事件间隔=%s" % ("", gaps[:16]))
    # sidecar 的字段表住在 `perf_update_caliber.sidecar_payload`（口径判据的唯一住处），
    # 这里不再抄一遍——09-24 之前它自己算了一套行数口径的 `n`，与汇总表的 17 同名不同值。
    if args.json:
        write_json(args.json, sidecar_payload(args.label, spans, values, events, args.budget_ms))
    return 0


def cmd_displays(args):
    doc = Doc(args.xml)
    print("== device-display-info ==")
    hz = {}
    for row in doc.rows():
        name = find_tag(row, "metal-object-label") or find_tag(row, "display-name")
        res = find_tag(row, "size-in-pixels")
        builtin = find_tag(row, "boolean")
        rate = display_row_rate(row)
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


def display_row_rate(row):
    """一行里落在 10~1000 的那个 uint32 就是刷新率；**取最后一个**（照拆分前的覆盖式赋值）。"""
    rate = None
    uints = [c for c in row if c.tag == "uint32"]
    for c in uints:
        if c.fmt and c.fmt.isdigit() and 10 <= int(c.fmt) <= 1000:
            rate = int(c.fmt)
    return rate


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


def lifecycle_periods(doc):
    """life-cycle-period 表 → (逐行摘要, (起始,时长) 序列, 合计, 最长周期)。

    单独一个函数有两个理由：① `cmd_lifecycle` 因此只管"怎么印"，CC 掉回阈值下
    （本仓 `PerfRulerHotspotRatchetTests` 量过 CC20 之后是这么修的：拆，不抬数）；
    ② 解析与呈现分开之后，`launch_ready_ms` 能直接吃 `(起始, 时长)` 序列做单元测试。
    """
    rows, spans = [], []
    total = 0.0
    longest = (0.0, "")
    for row in doc.rows():
        dur = find_tag(row, "duration")
        name = (find_tag(row, "lifecycle-period") or find_tag(row, "period")
                or find_tag(row, "string") or find_tag(row, "narrative"))
        d = dur.ms() if dur else None
        if d is None:
            continue
        start = find_tag(row, "start-time") or find_tag(row, "event-time")
        s_ms = start.ms() if start else None
        spans.append((s_ms if s_ms is not None else 0.0, d))
        total += d
        label = name.fmt if name and name.fmt else "?"
        if d > longest[0]:
            longest = (d, label)
        rows.append((label, d, [c.fmt for c in row if c.fmt][:4]))
    return rows, spans, total, longest


def cmd_lifecycle(args):
    """App Launch 的 life-cycle-period 表：逐周期时长 + 哪个周期最长。

    表结构随 Xcode 版本变（列名不保证），所以这里**按标签通用地**打出来，
    并且在 --json 里只存两个跨版本稳的量：total_ms 与 max_period_ms。
    """
    rows, spans, total, longest = lifecycle_periods(Doc(args.xml))
    print("== life-cycle-period（首帧与冷构建成本）==")
    for label, d, extra in rows[:24]:
        print("  %8.2f ms  %-26s %s" % (d, label[:26], " ".join(extra)[:60]))
    if not rows:
        print("  未解出任何周期——该表为空或列名与预期不符（按未覆盖处理，别拿 0 当达标）")
    ready = launch_ready_ms(spans)
    print("  合计 %.1f ms / %d 行；最长周期 %.1f ms = %s"
          % (total, len(rows), longest[0], longest[1]))
    # 合计里含"活到窗口结束"的运行期，**不能当首帧**；就绪点看下一行。
    print("  启动到就绪 %.1f ms（尾巴段已剔除；合计只作跨度参考）" % ready if ready is not None
          else "  启动到就绪：未解出（表里没有带时长的周期，按未覆盖处理）")
    # 最长周期是"启动成本"还是"活到录制结束的那一段"？用**与 launch_ready_ms 同一条**阈值判（#71）。
    _, horizon = window_span_and_tails(spans)
    tail = is_window_tail(longest[0], horizon)
    if tail:
        print("  ⚠ 最长周期 %s %.1f ms 超过整表跨度 %.1f ms 的一半 ⇒ 它是**跨度**（活到录制结束），"
              "不是成本；拿去算\"冷构建花了多久\"会得到≈窗口长度"
              % (longest[1], longest[0], horizon))
    if args.json:
        write_json(args.json, {"periods": len(rows), "total_ms": round(total, 2),
                               "ready_ms": None if ready is None else round(ready, 2),
                               "max_period_ms": round(longest[0], 2), "max_period": longest[1],
                               "horizon_ms": round(horizon, 2), "max_period_is_window_tail": tail})
    return 0


def cmd_switches(args):
    """switch 档逐页汇总：页名 / 首帧 / 冷构建周期合计。"""
    root = args.directory
    dirs = sorted(d for d in os.listdir(root) if os.path.isdir(os.path.join(root, d))) if os.path.isdir(root) else []
    print("== switch 档：逐页冷启动 ==")
    print("| %-14s | %-14s | %-16s | %s |"
          % ("页", "首帧 ms(页间可比)", "合计 ms(跨度参考)", "最长周期(跨度参考)"))
    n = 0
    for name in dirs:
        meta = read_json(os.path.join(root, name, "meta.json")) or {}
        life = read_json(os.path.join(root, name, "life-cycle-period.json"))
        page = meta.get("page", name)
        first = meta.get("first_frame_ms", "未观测到")
        first_txt = "未观测到" if first == "未观测到" else "%s ms" % first
        total = "%.1f" % life["total_ms"] if life else "未覆盖"
        if not life:
            longest = "—"
        else:
            # 三态：缺键＝这批测量根本没记这一维（老批次），**不许退化成 False**
            # （那等于把"没判过"读成"判过、不是尾巴"，也就是读成成本可用）。
            tail = life.get("max_period_is_window_tail")
            mark = " →窗口末(跨度，非成本)" if tail is True else ("" if tail is False else " (未记该维)")
            longest = "%s %.1f ms%s" % (str(life.get("max_period", ""))[:14],
                                        life.get("max_period_ms", 0.0), mark)
        print("| %-14s | %-14s | %-18s | %s |" % (page[:14], first_txt[:14], total, longest))
        n += 1
    if n == 0:
        print("!! %s 下没有逐页子目录：switch 档没跑过或跑了 DRY_RUN" % root)
    print("（口径：**只有「首帧」是页间可比的量**——它 = 带采样器、窗口出现即算，比裸启动慢。\n"
          "  「合计」与「最长周期」是 life-cycle-period 的**跨度**：App 起来后一直活到录制结束，\n"
          "   标了「→窗口末」的那一格约等于窗口长度减去首帧，**不可当成本**（#71：这条告诫原先\n"
          "   错挂在首帧那一列上，等于把两列不能用的数包装成可用）。）")
    return 0


# ----------------------------------------------------------------------------
# migration：把工单 §0.1 那张表变成一条能反复跑的命令
# ----------------------------------------------------------------------------

# 命中符号 → 该换成什么。只是提示，判据不住这里（见下面的口径来源）。
MIGRATION_HINTS = {
    "latestSnapshot": "monitor.pulse.value（或按需读单个格）",
    "history": "monitor.curve.value（窗口已切好，别再 suffix）",
    "topProcesses": "monitor.cpuRanking.value",
    "processesByMemory": "monitor.memoryRanking.value",
    "trackedGroups": "monitor.groupRanking.value",
    "measuredProcessCount": "monitor.ledger.value.measuredCount",
    "processMetricsTruncated": "monitor.ledger.value.metricsTruncated",
    "lastSampleAt": "monitor.pulse.value.sampleAt",
    "allProcesses": "视图零读点：改读 ranking 格",
}

# 【口径只有一个来源】这两条正则与上限**不住在 Python 里**：
# 它们由 `PerfInvalidationRatchetTests` 拥有，这里去把那三行常量读回来。
# 复制一份的正则迟早会与闸门分叉——分叉之后"命令说迁完了、守卫说没迁完"，
# 或者更糟：命令按老规则报 0、守卫按新规则也报 0，谁都不红。
RATCHET_SOURCE = "Tests/TcoderMonitorTests/PerfInvalidationRatchetTests.swift"


def read_guard_ruler(module_root):
    """从守卫源码里取 coarse/fine 正则 + 上限 + 消费方目录。取不到就抛，绝不返回空口径。"""
    path = os.path.join(module_root, RATCHET_SOURCE)
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    got = re.search(r'static let coarsePattern = #"([^"]*)"#', src)
    fine = re.search(r'static let finePattern = #"([^"]*)"#', src)
    ceiling = re.search(r'static let coarseCallSiteCeiling = (\d+)', src)
    dirs = re.search(r'consumerDirectories = \[(.*?)\]', src, re.S)
    missing = [n for n, v in (("coarsePattern", got), ("finePattern", fine),
                              ("coarseCallSiteCeiling", ceiling), ("consumerDirectories", dirs))
               if v is None]
    if missing:
        raise RuntimeError("读不到守卫里的 %s——它被改名或删掉了，本命令的口径就没有单一来源，"
                           "宁可报错也不许退回手抄正则（那会变成第二把尺子）：%s"
                           % (", ".join(missing), path))
    names = re.findall(r'"([^"]+)"', dirs.group(1))
    return got.group(1), fine.group(1), int(ceiling.group(1)), names


def swift_source_files(module_root, relative_dirs):
    for rel in relative_dirs:
        base = os.path.join(module_root, rel)
        for root, _dirs, files in os.walk(base):
            for name in sorted(files):
                if name.endswith(".swift"):
                    yield os.path.join(root, name)


WEIGHT_SOURCE = "Tests/TcoderMonitorTests/PerfInvalidationRatchetTests+CoarseWeighting.swift"
MONITOR_SOURCE = "Sources/TcoderMonitor/Services/Performance/MachSystemMonitor.swift"
WEIGHT_SETS = ("ungatedCoarseSymbols", "gatedCoarseSymbols",
               "unobservedCoarseSymbols", "aliasCoarseSymbols")
LOAD_BUCKETS = ("ungatedCoarseSymbols", "aliasCoarseSymbols")
MINIMUM_PUBLISH_BODY_LINES = 12


def read_declared_weights(root):
    """守卫里登记的四个集合。**读不到就抛**——退回手抄名单就是造第二把尺子。"""
    path = os.path.join(root, WEIGHT_SOURCE)
    try:
        src = open(path, encoding="utf-8").read()
    except OSError as exc:
        raise RuntimeError("读不到收益分级的来源 %s：%s" % (path, exc))
    sets = {}
    for name in WEIGHT_SETS:
        found = re.search(r"static let %s[^=]*= \[(.*?)\]" % name, src, re.S)
        if found is None:
            raise RuntimeError("读不到守卫里的 %s——被改名或搬走了，宁可报错也不许用旧名单" % name)
        sets[name] = set(re.findall(r'"([^"]+)"', found.group(1)))
    return sets


def publish_body_lines(root):
    """只取 `publish(_:)` 的函数体（每 tick 的写法只由它决定）＋全文件非注释行。
    边界用"下一行正好四个空格 + }"，不做括号计数——在字符串里数括号越界过一次。"""
    mon = open(os.path.join(root, MONITOR_SOURCE), encoding="utf-8").read()
    lines = [l for l in mon.split("\n") if not l.strip().startswith("//")]
    body, started = [], False
    for line in lines:
        if not started:
            started = "func publish(" in line
            continue
        if line == "    }":
            return body, lines
        body.append(line)
    return body, lines


def bucket_from_declarations(sym, symbols, lines):
    """声明层能定性的两种：压根不在观察图里 / 只是别的粗属性的别名。定不出来自 None。"""
    if any("@ObservationIgnored" in l and ("var %s" % sym) in l for l in lines):
        return "unobservedCoarseSymbols"
    others = [o for o in symbols if o != sym]
    if any(re.match(r"\s*var %s\b[^={]*\{\s*\S" % sym, l)
           and any(re.search(r"\b%s\b" % o, l) for o in others) for l in lines):
        return "aliasCoarseSymbols"
    return None


def bucket_from_tick_body(sym, body):
    """每 tick 那一写的形状：裸写 / 闸门写 / 两者都有（"闸门只加了一半"）/ 都没写。"""
    bare = re.compile(r"^\s*(?:self\.)?%s\s*=[^=]" % sym)
    ungated = any(bare.match(l) for l in body)
    gated = any(re.search(r"write\(\s*\\\.%s\b" % sym, l) for l in body)
    if ungated and gated:
        return "冲突"
    if ungated:
        return "ungatedCoarseSymbols"
    if gated:
        return "gatedCoarseSymbols"
    return "未归类"


def classify_symbol(sym, symbols, lines, body):
    """单个粗属性归哪一格。顺序有意：**不在观察图 > 别名 > 每 tick 那一写**——
    `allProcesses` 既被裸写又不在图里，而"不在图里"才是结论（裸写不参与观察的属性不产生失效面）。
    （拆成两个 bucket_* 是因为本仓对尺子有 CC<16 的棘轮，第一段版本正好踩在 16 上。）"""
    return bucket_from_declarations(sym, symbols, lines) or bucket_from_tick_body(sym, body)


def read_weight_ruler(root):
    """现读分类，并**与守卫登记的名单对表**：不一致就交出来，两边各说各话会被 cmd_migration 报 ⚠。"""
    sets = read_declared_weights(root)
    body, lines = publish_body_lines(root)
    if len(body) < MINIMUM_PUBLISH_BODY_LINES:
        raise RuntimeError("只从 publish() 抽到 %d 行，边界判定坏了 → 分级不可信" % len(body))
    symbols = sorted(set().union(*sets.values()))
    derived = dict((sym, classify_symbol(sym, symbols, lines, body)) for sym in symbols)
    declared = dict((sym, name) for name in WEIGHT_SETS for sym in sets[name])
    disagree = sorted(sym for sym in symbols if derived[sym] != declared[sym])
    return symbols, derived, disagree, len(body)


def weighting_readout(root, hits):
    """返回（一行分级说明, 每条读点的标签）。分级读不到时**明说不可用**，不许悄悄少打一维。"""
    try:
        _symbols, derived, disagree, body_lines = read_weight_ruler(root)
    except (OSError, RuntimeError) as exc:
        return "   收益分级**不可用**：%s" % exc, {}
    tags = dict((sy, "承重" if derived[sy] in LOAD_BUCKETS
                 else "顺手" if derived[sy] == "gatedCoarseSymbols" else "出图") for sy in derived)
    load = sum(1 for h in hits if tags.get(h[2]) == "承重")
    note = ("   收益分级（从 publish() 现读 %d 行）：承重 %d 处 / 顺手 %d 处；"
            "顺手那几处的宿主属性走等值闸门，单独迁它们在帧率上测不出差异"
            % (body_lines, load, len(hits) - load))
    if disagree:
        note += ("\n   ⚠ 与守卫登记的名单不一致（有人改了闸门写法却没回来改口径）：%s"
                 % ", ".join("%s=%s" % (d, derived[d]) for d in disagree))
    return note, tags



def cmd_migration(args):
    root = args.module_root
    try:
        coarse, fine, ceiling, dirs = read_guard_ruler(root)
    except (OSError, RuntimeError) as exc:
        print("!! %s" % exc, file=sys.stderr)
        return 2
    coarse_re, fine_re = re.compile(coarse), re.compile(fine)
    hits, fine_count, scanned = [], 0, 0
    for path in swift_source_files(root, dirs):
        scanned += 1
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            for number, line in enumerate(fh.read().split("\n"), 1):
                if line.strip().startswith("//"):      # 与守卫同一条豁免：整行注释不算调用点
                    continue
                for m in coarse_re.finditer(line):
                    hits.append((os.path.relpath(path, root), number, m.group(1),
                                 MIGRATION_HINTS.get(m.group(1), "读对应的细粒度格")))
                fine_count += len(fine_re.findall(line))
    weight_note, tag_of = weighting_readout(root, hits)
    print("== 细粒度契约迁移进度（口径直接取自 %s）==" % RATCHET_SOURCE)
    print("   扫描 %d 个文件（%s），粗粒度读点 %d 处 / 登记上限 %d 处 / 目标 0，细粒度读点 %d 处"
          % (scanned, " + ".join(dirs), len(hits), ceiling, fine_count))
    if weight_note:
        print(weight_note)
    if hits:
        print("   剩哪几处（符号是稳定的，行号只是当下位置）：")
        for rel, number, symbol, hint in hits:
            print("     %-6s %-46s %-22s → %s"
                  % ("[%s]" % tag_of.get(symbol, "?"), "%s:%d" % (rel, number),
                     "monitor." + symbol, hint))
        print("   按文件汇总：%s" % ", ".join("%s×%d" % (k, v) for k, v in
              sorted(collections.Counter(h[0] for h in hits).items())))
    else:
        print("   粗粒度读点已清零——请总工把上限拧成 0 并翻 `consumptionGateOpen`。")
    if args.strict and len(hits) > 0:
        print("!! --strict：还剩 %d 处未迁" % len(hits), file=sys.stderr)
        return 1
    return 0


# ----------------------------------------------------------------------------
# CLI
# ----------------------------------------------------------------------------

def build_parser():
    p = argparse.ArgumentParser(description="xctrace XML → 性能读数（含 id/ref 解引用）")
    sub = p.add_subparsers(dest="cmd", required=True)
    # 两个小节按"吃 XML 文件"与"吃输出目录"分，注册顺序一字未动——
    # argparse 的 --help 子命令列表就是按注册顺序出的，重排等于改读数。
    add_xml_subcommands(sub)
    add_directory_subcommands(sub)
    return p


def add_xml_subcommands(sub):
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


def add_directory_subcommands(sub):
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

    g = sub.add_parser("migration", help="细粒度契约迁移进度（正则与上限直接取自守卫源码，不复制口径）")
    g.add_argument("--module-root", default=os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    g.add_argument("--strict", action="store_true", help="还有粗粒度读点就非零退出（给 CI/门禁用）")
    g.set_defaults(func=cmd_migration)


def main(argv=None):
    args = build_parser().parse_args(argv)
    if not os.path.isfile(getattr(args, "xml", None) or "") and getattr(args, "xml", None):
        print("!! 找不到文件: %s" % args.xml, file=sys.stderr)
        return 2
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
