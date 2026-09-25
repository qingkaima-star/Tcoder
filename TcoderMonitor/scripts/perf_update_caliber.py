#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""`hitches-updates` 的**事件口径**：一次 app update 为什么会出两行，以及怎么收成一行。

## 为什么要单独一支

2026-09-24 在同一份 trace 上量到三个数（`.scratch/tcoder-perf-03a2219-t2b-idle-run1`）：

| 读法                        | n   | 超 8.333 ms | 用它的地方                          |
|-----------------------------|-----|-------------|-------------------------------------|
| 原始行数                    | 28  | 8           | `trace_report.py` 落的 sidecar `n`  |
| 按 (起始, 时长) 去重        | 17  | 4           | 汇总表 + 一致性尺                   |
| 按**值**去重（旧的 JSON 回落） | 16 | —           | 只在 XML 读不出时                    |

三个数共用一个名字 `app-update`，于是"两处入口两个数"根本不是笔误，是**三条口径没有唯一归属**。
更要紧的是第三条：把相等的时长并掉会少计真实事件，而少计只会让「超预算 N 个」**变小**——
单向朝好看错。旧的 JSON 回落还额外踩了一格：sidecar 的 `values` 只存最小的 40 个
（`trace_report.py` 当时把给人看的首屏样例直接写进了机器读的字段），
所以 XML 一缺失，那支回落尺读到的 `max` 是"第 40 小的时长"，而 T2 的判据量正是这个 `max`。

⇒ 这个文件是这条规则的**唯一住处**：报表、一致性尺、sidecar 三个消费者都调它，
    对不上时只剩一个可疑点。判据方向也一并钉死：**宁可多计，不许少计。**
"""


import statistics

from perf_trace_metrics import over_budget, percentile


def unique_event_spans(pairs):
    """(起始, 时长) 行 → 事件区间列 `[(起始, 时长)]`：同一起始同一时长才算重复（Brown / Red 两行）。

    去重这件事**只有这一把尺**（#44 那次"同一份 trace 两处入口两个数"的根治）。
    归因侧需要留下起始时刻去对 time-profile 的时间轴，所以这里另开一个"保起始"的出口，
    而 `event_durations` 就是它的一列投影——两条规则不可能各长一份。

    【键的边界，写在被量的那一处】键是**四舍五入后**的（起始, 时长）：09-25 拿真表逐列读过，
    一条 update 之所以占两行，是因为它带多枚 `event-concept`（Brown ＋ Red），
    第二行只有那一列不同、帧 id 那列是空的 ⇒ 合并是对的。
    代价是这一格：**同时刻同时长、但帧 id 不同**的两枚事件会被并成一个。
    真撞上那一格时要做的是给键加一列（在这里加，不在调用方各加一份），不是拿它当巧合。
    """
    seen, out = set(), []
    for start, duration in pairs:
        key = (round(start, 1), round(duration, 2))
        if key not in seen:
            seen.add(key)
            out.append((start, duration))
    return out


def event_durations(pairs):
    """(起始, 时长) 行 → 事件时长列。口径同上，只是把起始丢掉。"""
    return [duration for _, duration in unique_event_spans(pairs)]


def dedupe_pairs(measure):
    """一个读数（`load_measure` 的结果）→ 事件时长列。

    XML 优先；其次 sidecar 的 `pairs`（同一个键、同一条规则）；
    两者都没有 ⇒ **不去重**，把行数原样给出，并让 `update_caliber_note` 去标注这份 n 是行数。
    """
    if measure.get("doc") is not None:
        return event_durations(measure["doc"].spans())
    js = measure.get("json")
    if js and js.get("pairs"):
        return event_durations([(p[0], p[1]) for p in js["pairs"]])
    if js and "values" in js:
        return [float(v) for v in js["values"]]
    return []


def update_caliber_note(measure):
    """口径回落要出声：只剩裸 `values` 时那份 n 是**行数**，双行会各计一次。"""
    js = (measure or {}).get("json") or {}
    if (measure or {}).get("doc") is None and js and not js.get("pairs"):
        return "｜口径回落：无 (起始,时长) 配对 ⇒ n 与超预算按行数读（双行各计一次）"
    return ""


def sidecar_payload(label, spans, values, events, budget_ms):
    """sidecar 的字段表：事件口径为主、行数点名、配对留着给回落尺用同一条规则。

    住在这里而不是 `trace_report.py`：那支 CLI 已挂在 400 行口径的账上（`hugeFileWorkList`），
    而"哪些数算同一个口径"本来就是本文件的判据——搬来这里，写侧只剩一次 `write_json`。
    """
    return {
        "label": label, "n": len(events), "n_rows": len(values), "n_events": len(events),
        "budget_ms": budget_ms,
        "p50": round(percentile(events, 0.5), 3), "p95": round(percentile(events, 0.95), 3),
        "p99": round(percentile(events, 0.99), 3), "max": round(max(events), 3) if events else 0.0,
        "median": round(statistics.median(events), 3) if events else 0.0,
        "total": round(sum(events), 1), "over_budget": over_budget(events, budget_ms)[0],
        "values": [round(v, 2) for v in sorted(values)],
        "pairs": [[round(s, 1), round(v, 2)] for s, v in spans],
    }
