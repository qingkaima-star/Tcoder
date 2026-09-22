#!/usr/bin/env python3
"""屏上**正文**（非 ⓘ）里的中文整句台账（**报告器，不是闸门**）。

回答 F13 那个问题：`Services/` 里拼好、经 `Text(变量)` 直接铺在页面上的句子，
到底有多少**真的上了屏**、分别住在哪个文件。此前只有 python 静态粗筛
（"含汉字、又不落在任何 UI 入口前缀上"= 32 文件 / 327 处），那个数既包含根本不上屏的
日志 tag，也漏掉运行时拼出来的句子 —— **没有仪器才只能粗筛**。

判据与 `ax_tooltip_coverage.py --language-audit` **同一把尺子**：
分类函数直接从那个模块 import（不在这里再实现一遍 —— 两份尺子必然漂）。

用法: ./scripts/ax_body_audit.py [--all] [取证目录...]
     不传参数 = `$SCRATCH/tcoder-ax-body/*`
     读的是 `ax_body_text.swift` 产出的 `TEXT<TAB>role<TAB>属性<TAB>值` 行。
"""
import os
import re
import subprocess
import sys
from collections import Counter, defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from ax_tooltip_coverage import catalog_keys, hits_key, repo_root  # 同一把尺子

HAN = re.compile(r"[一-鿿]")
# 明显是"数据"而不是"话术"的形状：路径、日期时间、纯计数、项目名。
DATA_SHAPE = re.compile(r"^(/|\./|~|20[0-9]{2}-|Tcoder（)|:[0-9]{2}:[0-9]{2}$")


def live_dirs(argv):
    if argv:
        return [Path(a) for a in argv if Path(a).is_dir()]
    scratch = os.environ.get("TCODER_SCRATCH") or (repo_root() / ".scratch")
    base = Path(scratch) / "tcoder-ax-body"
    return sorted([p for p in base.glob("*") if p.is_dir()])


def read_text_rows(path):
    """还原 (role, attr, text) 三元组。值里的换行在写入时已折成 ' ⏎ '。"""
    rows = []
    for line in path.read_text(encoding="utf-8").splitlines():
        if not line.startswith("TEXT\t"):
            continue
        parts = line.split("\t", 3)
        if len(parts) == 4:
            rows.append((parts[1], parts[2], parts[3]))
    return rows


def code_sites(fragment, sources):
    """把一句屏上文本回指到源码落点：拿最长的一段连续汉字去 grep 静态字面量。"""
    runs = [r for r in re.findall(r"[一-鿿]{6,}", fragment) if not r.startswith("Tcoder")]
    if not runs:
        return []
    needle = max(runs, key=len)
    hits = []
    for path in sorted(sources.rglob("*.swift")):
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        if needle in text:
            hits.append(str(path.relative_to(repo_root())))
    return hits


def main(argv):
    show_all = "--all" in argv
    dirs = live_dirs([a for a in argv if a != "--all"])
    evidence = [p for d in dirs for p in sorted(d.glob("*.txt"))]
    if not evidence:
        print("!! 没有正文读数产物（先跑 AX_TOOL=ax_body_text AX_COUNT_PATTERN='^TEXT' "
              "./scripts/ax_tooltip_report.sh）")
        return 1
    sources = repo_root() / "TcoderMonitor/Sources"
    keys = catalog_keys()
    counts = Counter()
    for path in evidence:
        for _role, _attr, text in read_text_rows(path):
            for piece in text.split(" ⏎ "):
                piece = piece.strip()
                if piece and HAN.search(piece):
                    counts[piece] += 1
    a = [k for k in counts if hits_key(k, keys)]
    data = [k for k in counts if k not in a
            and (DATA_SHAPE.search(k) or "/" in k or len(k) <= 4)]
    b = [k for k in counts if k not in a and k not in data]
    print(f"== 屏上正文含中文片段 {sum(counts.values())} 次 / 去重 {len(counts)} 句"
          f"（{len(evidence)} 趟，来自 {len(dirs)} 个批次）")
    print(f"   A 有键没查 : {len(a)} 句 ← 包一层 localizedCopy 就完事")
    print(f"   B 未登记话术: {len(b)} 句 ← 要登记键 + 包查表（F13 说的那一类）")
    print(f"   C 像数据   : {len(data)} 句 ← 路径 / 项目名 / 时间戳，不翻是对的")
    by_file = defaultdict(int)
    for label, group in (("A", a), ("B", b)):
        for k in sorted(group, key=lambda x: -counts[x])[:None if show_all else 12]:
            sites = code_sites(k, sources)
            tag = sites[0] if sites else "（静态里 grep 不到：运行时拼的）"
            for s in sites[:1]:
                by_file[s] += 1
            print(f"   {label} {counts[k]:3d}× {k[:60]}\n        ↳ {tag}")
    if show_all:
        print("-- 按落点文件汇总（A/B 两类，只统计 grep 得到落点的）")
        for f, n in sorted(by_file.items(), key=lambda x: -x[1]):
            print(f"   {n:3d} 句  {f}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
