#!/usr/bin/env python3
"""长 update 的调用栈归因（缺陷 #43 / #73 的落地件）：把 `hitches-updates` 的
`(起始ms, 时长ms)` 配对与 **同一个窗口** 的 time-profile 样本对齐，回答
"这 598 ms 里主线程到底在跑什么"。

三条不是显然的口径，写在这里而不是散在代码里：

1. **同窗是硬前提，不是偏好。** 历史上 hitches 与 time-profile 是**两次独立录制**
   （`hitches.trace` / `time.trace`），把两条时间轴并起来是一次跨窗口猜测：
   两边数字各自都真，对到的栈却属于另一段时间——这类错比报错难发现得多，
   因为它看着像一张正常的归因表。⇒ 只有 meta 里带 `blame_instrument=1` 的那一趟
   （一次录制里同时有 hitches 家族与 Time Profiler，见 `perf_harness.sh` 的
   `BLAME_INSTRUMENT=1`）才允许 join，其余**拒绝出数**。
2. **窗口里 0 个样本要说「取不到」，不许说「没有栈」。** Time Profiler 是 1 ms 采样，
   一个 120 ms 的块完全可能一个样本都不落到；"没样本"是**没查到**，
   写成"没有栈"就是"没查"冒充"没有"（本仓守卫静默失效清单第 1 类）。
3. **叶子帧一律剔掉 RunLoop 管道帧**，用 `perf_trace_xml.is_runloop_plumbing` ——
   同一条判据不许在这儿再抄一份名单。剔掉多少要照印，因为"这一格被剔了"本身是信息。
"""
from __future__ import annotations

import collections
import json
import os
import re
import sys

from perf_trace_xml import Doc, build_stack_index, is_runloop_plumbing
from perf_update_caliber import unique_event_spans   # 行→事件的口径只此一家（#44 的根治）

MIN_MS_DEFAULT = 100.0
ROW_RE = re.compile(r"<row>(.*?)</row>", re.S)


def cell_of(doc: Doc, row: str, tag: str):
    """一行里某个标签的**已解引用**列值；复用 Doc 的注册表，不自己写第二把尺子。"""
    m = re.search(r'<%s (?:id="(\d+)"[^>]*|ref="(\d+)")' % tag, row)
    if not m:
        return None
    return doc.registry.get((tag, m.group(1) or m.group(2)))


def stack_leaf(doc: Doc, row: str, tbs: dict):
    """这一行的叶子帧名；没有栈（或被系统合并）时回 None，由调用方如实报"取不到"。"""
    m = re.search(r'<tagged-backtrace (?:id="(\d+)"|ref="(\d+)")', row)
    if not m:
        return None
    seq = tbs.get(m.group(1) or m.group(2)) or []
    return seq[0] if seq else None


def main_thread_samples(xml_path: str, pid: str = "") -> tuple[list, int, int]:
    """→ (主线程样本 [(时刻ms, 叶子帧或 None)], 解出的总行数, 因进程不符而跳过的行数)。

    `pid` 不是可选装饰：time-profile 会采到整机，而**别的进程的 "Main Thread" 也叫这个名字**。
    没有 pid 就当"全局主线程"用，并且要出声（调用方会打一行提示）。
    """
    doc = Doc(xml_path)
    _, _, tbs, _threads = build_stack_index(doc.text)
    out: list = []
    skipped_other_pid = 0
    total = 0
    for row in ROW_RE.findall(doc.text):
        total += 1
        th = cell_of(doc, row, "thread")
        if th is None or not th.fmt.startswith("Main Thread"):
            continue
        if pid and ("pid: %s" % pid) not in th.fmt:
            skipped_other_pid += 1
            continue
        st = cell_of(doc, row, "sample-time")
        ns = st.num() if st is not None else None
        if ns is None:
            continue
        out.append((ns / 1_000_000.0, stack_leaf(doc, row, tbs)))
    return out, total, skipped_other_pid


def read_run(run_dir: str):
    """→ (事件区间, 行数, 被测 pid, 是否同窗双仪器档)。

    行→事件走 `unique_event_spans`（Brown / Red 两行算一个事件）——**不归因侧自造**：
    #44 那次的病根就是同一份 trace 两处入口给出两个数。
    """
    meta_path = os.path.join(run_dir, "meta.json")
    meta = {}
    if os.path.isfile(meta_path):
        try:
            meta = json.load(open(meta_path, encoding="utf-8"))
        except ValueError:
            meta = {}
    rows = []
    upd = os.path.join(run_dir, "hitches-updates.json")
    if os.path.isfile(upd):
        rows = [tuple(p) for p in (json.load(open(upd, encoding="utf-8")).get("pairs") or [])]
    instrument = str(meta.get("blame_instrument") or "").strip()
    return unique_event_spans(rows), len(rows), str(meta.get("pid") or ""), bool(instrument)


def blame(windows: list, samples: list, min_ms: float) -> list:
    """每个 ≥min_ms 的 update 一条：窗口内主线程样本的叶子帧分布。"""
    rows = []
    for start, dur in windows:
        if dur < min_ms:
            continue
        inside = [leaf for t, leaf in samples if start <= t <= start + dur]
        kept = [f for f in inside if f and not is_runloop_plumbing(f)]
        rows.append({
            "start": start, "dur": dur,
            "samples": len(inside), "unknown": sum(1 for f in inside if not f),
            "plumbing": len(inside) - len(kept) - sum(1 for f in inside if not f),
            "top": collections.Counter(kept).most_common(3),
        })
    return sorted(rows, key=lambda r: -r["dur"])


def report(rows: list, windows: list, samples: list, n_raw_rows: int, total_rows: int,
           skipped: int, pid: str, min_ms: float) -> None:
    below = len(windows) - len(rows)
    # 两个数都要印：一次配对给"表里有多少行"，一次给"合并后剩多少个事件"。
    # 只印后者会让人以为这个趟的 update 就是那么点（#44 的口径分叉就这么来的）。
    print("长 update 归因（只看 ≥ %.0f ms 的块；hitches-updates 表 %d 行 → 去重成 %d 个事件；"
          "主线程样本 %d 个 / time-profile 表内共 %d 行%s）"
          % (min_ms, n_raw_rows, len(windows), len(samples), total_rows,
             "，跳过别的进程 %d 行" % skipped if skipped else ""))
    if not pid:
        print("    ⚠ meta 里没有 pid ⇒ 无法按进程过滤主线程，这份归因是「全机主线程」口径，别当单进程结论用")
    if not rows:
        print("    这一趟没有 ≥ %.0f ms 的 update（共 %d 个块，全部低于线）"
              "⇒ 没有要归因的块，不是「没数据」" % (min_ms, len(windows)))
        return
    for r in rows:
        span = "[%8.1f → %8.1f] %7.1f ms  主线程样本 %d 个" % (
            r["start"], r["start"] + r["dur"], r["dur"], r["samples"])
        if not r["samples"]:
            print(span + " ⇒ 窗口内一个样本都没落到：**取不到**（1 ms 采样的空隙，不等于没在干活）")
            continue
        print(span + "（无栈 %d、RunLoop 管道帧 %d）" % (r["unknown"], r["plumbing"]))
        for name, cnt in r["top"]:
            print("      %3d× %s" % (cnt, name[:110]))
    print("    另有 %d 个 < %.0f ms 的块未列（要它们就 --min-ms 更小，但短块基本必然采不到栈）"
          % (below, min_ms))


def main(argv: list) -> int:
    run_dir = argv[0] if argv else ""
    min_ms = MIN_MS_DEFAULT
    if "--min-ms" in argv:
        min_ms = float(argv[argv.index("--min-ms") + 1])
    if not run_dir or not os.path.isdir(run_dir):
        print("用法: perf_update_stacks.py <一趟的产物目录> [--min-ms 100]（目录里要有 "
              "hitches-updates.json + blame-time-profile.xml + meta.json）")
        return 2
    windows, n_raw_rows, pid, same_window = read_run(run_dir)
    xml = os.path.join(run_dir, "blame-time-profile.xml")
    if not same_window:
        # 两个窗口的时间轴并起来 = 把"另一段时间的栈"归给这一刻。数字都真，结论是假的。
        print("!! 这一趟不是同窗双仪器档（meta 里没有 blame_instrument=1）⇒ **拒绝归因**。")
        print("   hitches 与 time-profile 是两次独立录制时，join 出来的是跨窗口的猜测。")
        print("   要这一格的数据，请用 BLAME_INSTRUMENT=1 起一趟（那一档不参与达标判定）。")
        return 1
    if not os.path.isfile(xml):
        print("!! 缺 %s ⇒ 归因做不了（有标记没表 = 采集坏了，不是「这一程没栈」）" % xml)
        return 1
    if not windows:
        print("!! hitches-updates.json 里没有 pairs ⇒ 没有 (起始, 时长) 可配，拒绝出数")
        return 1
    samples, total_rows, skipped = main_thread_samples(xml, pid)
    if not samples:
        print("!! 一个主线程样本都没解出来：确认导出的是 time-profile 表而不是空表（表内 %d 行）"
              % total_rows)
        return 1
    report(blame(windows, samples, min_ms), windows, samples, n_raw_rows,
           total_rows, skipped, pid, min_ms)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
