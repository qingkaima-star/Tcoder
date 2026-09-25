#!/usr/bin/env python3
"""缺陷 #70：被拒那一趟的 GB 级原始 trace，回收器存在但射程没跟着产物搬家。

背景（2026-09-25 量过）：`sweep_orphan_traces` 只扫 `$TMPDIR`，而样本根自那笔
"产物不许再往全局临时目录倒"的改动之后已经搬进仓库 `.scratch/` —— 于是它一直在扫
一个不再有人写字的目录，真正的 215 GiB 残骸一个都没被看过。本文件补齐那半边射程，
打印点仍挂在 `post_run_disk_hygiene`（一个出口，不新开第二处报体积）。

三条不是显然的口径，写在这里而不是散在代码里：
  1. **只碰有 `REFUSED` 的那一趟里的 `*.trace`**。判废趟里 `meta.json` /
     `measurement-context.txt` / `load-in-window.tsv` 都是 KB 级而**是账**（台账靠
     它们解释"这趟为什么不算"），删掉等于销毁拒绝记录。
  2. **"被拒"单独不够，还要"大得不是这个档的正常尺寸"**（同档中位 ×5）。
     被静默探针拒掉的那趟照样能回收重导，那份 trace 值得留；而挂死趟的 trace 是
     "停不下来"这件事的产物，它永远不可能合格 —— 只有这类留在盘上没有任何读者。
     实测：13 个被拒 bundle 里 11 个在线内，两个挂死趟（15.2 / 13.2 GiB）在线外，
     正好 28.3 GiB 是白占的。
  3. **默认只印不删**。删取证原件不可逆，必须显式 `TCODER_RECLAIM=1`；而"印"每轮
     都要发生，因为不印就没人知道在涨（同一条棘轮不报现量的那个教训）。

样本数 < 3 的档**明写不判**：分母太小的散布不是散布（裁 A 那一族的同一个道理）。
"""
from __future__ import annotations

import os
import re
import shutil
import statistics
import subprocess
import sys

RUN_RE = re.compile(r"^tcoder-perf-.+-run\d+$")
OVERSIZE_FACTOR = float(os.environ.get("REFUSED_TRACE_OVERSIZE_FACTOR", "5"))
MIN_TIER_SAMPLE = int(os.environ.get("REFUSED_TRACE_MIN_TIER_SAMPLE", "3"))
KIB_PER_GIB = 1024.0 ** 2


def tier_of(run_name: str) -> str:
    """`tcoder-perf-<rev>-<标签>-<档>-runN` → 档（末段，如 `idle`/`interact`/`switch`）。

    档位是"这档的正常尺寸是多少"的抽样桶，不是批次标签：批次标签每夜都在变，
    拿它当桶的话每桶只剩一两趟，判据会退化成"永远不判"。
    """
    stem = re.sub(r"-run\d+$", "", run_name)
    return stem.rsplit("-", 1)[-1]


def find_run_dirs(root: str) -> list[str]:
    """样本根下**最多两层**里名字像一趟的目录。

    两层是有原因的：`archive-25hz/` 那批是判废之后才被整批挪进去的，只扫一层
    就等于把"先攒着、以后再说"这种形态排除在射程外。
    """
    out: list[str] = []
    try:
        top = [e for e in os.scandir(root) if e.is_dir()]
    except OSError:
        return out
    nested: list = list(top)
    for entry in top:
        try:
            nested += [c for c in os.scandir(entry.path) if c.is_dir()]
        except OSError:
            continue
    for entry in nested:
        if RUN_RE.match(entry.name):
            out.append(entry.path)
    return sorted(out)


def allocated_kib(path: str) -> float:
    """实际占盘（KiB），与 `du -k` 同一个块口径（`st_blocks` 以 512 B 计）。

    故意不用 `st_size` 之和：那会把稀疏文件报成"很大但没占盘"，而本函数的输出是
    "能回收多少 GiB"，报一个盘上不存在的身材等于说谎 —— 夹具也因此只能用真写出来
    的文件，不能用 `truncate` 糊一个大小出来。
    """
    total = 0
    for dirpath, dirnames, filenames in os.walk(path):
        for name in list(dirnames) + filenames:
            try:
                total += os.lstat(os.path.join(dirpath, name)).st_blocks * 512
            except OSError:
                continue
    return total / 1024.0


def refuse_reason(run_dir: str) -> str:
    """`REFUSED` 的第 2 行才是原因（第 1 行是标记本身，抄它会印成「原因：REFUSED」）。"""
    try:
        with open(os.path.join(run_dir, "REFUSED"), encoding="utf-8") as handle:
            lines = [line.strip() for line in handle.read().splitlines() if line.strip()]
    except OSError:
        return "（读不到 REFUSED）"
    return lines[1] if len(lines) > 1 else "（REFUSED 没写原因）"


def is_open(path: str) -> bool:
    """有进程打开着就绝不碰 —— 与 `sweep_orphan_traces` 同一个守卫、同一个理由。"""
    return subprocess.run(["lsof", "--", path],
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0


def collect_bundles(root: str) -> list[dict]:
    """每个 `*.trace` 一条记录：属于哪一趟、哪一档、占多少盘、那趟判没判废。"""
    bundles: list[dict] = []
    for run in find_run_dirs(root):
        refused = os.path.exists(os.path.join(run, "REFUSED"))
        children = sorted(os.scandir(run), key=lambda e: e.name) if os.path.isdir(run) else []
        for child in children:
            if not child.name.endswith(".trace") or not child.is_dir():
                continue
            bundles.append({
                "path": child.path, "name": child.name,
                "run": os.path.basename(run), "tier": tier_of(os.path.basename(run)),
                "gib": allocated_kib(child.path) / KIB_PER_GIB, "refused": refused,
            })
    return bundles


def tier_medians(bundles: list[dict]) -> tuple[dict[str, float], list[tuple[str, int]]]:
    """同档中位数（GiB）+ 样本不足所以不判的档。中位数按**全部**趟算，不分判废与否。"""
    tiers: dict[str, list[float]] = {}
    for item in bundles:
        tiers.setdefault(item["tier"], []).append(item["gib"])
    medians: dict[str, float] = {}
    not_judged: list[tuple[str, int]] = []
    for tier in sorted(tiers):
        sizes = tiers[tier]
        if len(sizes) >= MIN_TIER_SAMPLE:
            medians[tier] = statistics.median(sizes)
        else:
            not_judged.append((tier, len(sizes)))
    return medians, not_judged


def pick_hits(bundles: list[dict], medians: dict[str, float]) -> list[dict]:
    """被拒 ∧ 超过同档尺寸线 ⇒ 可回收。档不判的、没被拒的、被拒但正常的都留下。"""
    hits = []
    for item in bundles:
        median = medians.get(item["tier"])
        if item["refused"] and median is not None and item["gib"] > median * OVERSIZE_FACTOR:
            item["median"] = median
            hits.append(item)
    return sorted(hits, key=lambda i: -i["gib"])


def fmt_size(gib: float) -> str:
    """不到 1 GiB 就换 MiB —— 合成夹具是 KiB/MiB 量级的，印成 `0.0 GiB` 读起来像坏了。"""
    return f"{gib:.1f} GiB" if gib >= 1 else f"{gib * 1024:.0f} MiB"


def report(hits: list[dict], bundles: list[dict], not_judged: list[tuple[str, int]]) -> None:
    refused_total = sum(1 for b in bundles if b["refused"])
    print(f"被拒趟的原始 trace：{len(hits)} 个 bundle 可回收 {fmt_size(sum(i['gib'] for i in hits))}"
          f"（线 = 同档中位 ×{OVERSIZE_FACTOR:g}；被拒 bundle 共 {refused_total} 个，"
          f"其余 {refused_total - len(hits)} 个在尺寸线内或档不判 ⇒ 保留）")
    for item in hits:
        reason = refuse_reason(os.path.dirname(item["path"]))
        print(f"    {item['run']}/{item['name']}  {fmt_size(item['gib'])}"
              f"（同档 {item['tier']} 中位 {fmt_size(item['median'])}）拒因：{reason}")
    for tier, count in not_judged:
        print(f"    档 {tier} 样本 {count} < {MIN_TIER_SAMPLE} ⇒ 不判（分母太小，不拿中位数当判据）")


def delete(hits: list[dict]) -> None:
    for item in hits:
        if is_open(item["path"]):
            print(f"    跳过（仍被进程打开）：{item['path']}")
            continue
        shutil.rmtree(item["path"])
        print(f"    已删 {item['path']}")


def main(argv: list[str]) -> int:
    root = argv[0] if argv else ""
    if not root or not os.path.isdir(root):
        print(f"回收检查：样本根不在（{root or '未给'}）⇒ 这一维没查，别读成「没有残骸」")
        return 0
    bundles = collect_bundles(root)
    medians, not_judged = tier_medians(bundles)
    hits = pick_hits(bundles, medians)
    report(hits, bundles, not_judged)
    if os.environ.get("TCODER_RECLAIM") == "1" and hits:
        delete(hits)
        print("    （TCODER_RECLAIM=1：上面那些原始 bundle 已删；判定与上下文那些 KB 级文件原样留着）")
    elif hits:
        print("    默认不删。要真回收：TCODER_RECLAIM=1 再跑一次（只删 *.trace，判定/上下文不删）")
    return 0


if __name__ == "__main__":
    sys.exit(main([a for a in sys.argv[1:] if not a.startswith("-")]))
