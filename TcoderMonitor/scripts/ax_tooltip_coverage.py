#!/usr/bin/env python3
"""ⓘ 句子覆盖率对照表（**报告器，不是闸门**，退出码只表示"表出没出来"）。

左边：源码里写进 `CopyHelpBadge("…")` / `…, help: "…"` 槽位的那一句（静态应到清单）。
右边：真 App 跑起来后从进程外读到的无障碍 help 文案（实到清单，若干趟的并集）。

为什么不判成败：一处 ⓘ 只在该页被打开、那段卡片没折叠、且**数据态对得上**时才会上屏。
所以"未命中"通常是**这次的沙箱没走到那条分支**（例：有日志分析结果的项目不会显示
「该项目还没有日志分析结果」那张卡的 ⓘ），不是"句子丢了"。要把它变成命中，
用 `AX_TARGET=<空目录> AX_SET=empty` 再跑一趟报告器，两个批次一起传进来即可。
命中的判据也别理解成"完全相等"：整句是插值的（`"共 \\(n) 个…"`）静态侧取不出唯一汉字串，
单独计一类"无法静态匹配"，既不算命中也不算缺。

用法: ./scripts/ax_tooltip_coverage.py [取证目录...]
     不传参数 = `$SCRATCH/tcoder-ax-tooltip/*`（有哪个批次算哪个）。
"""
import os
import re
import subprocess
import sys
from pathlib import Path

BADGE = re.compile(r'CopyHelpBadge\(\s*"((?:[^"\\]|\\.)*)"')
HELPSLOT = re.compile(r'help:\s*"((?:[^"\\]|\\.)*)"')
HAN_RUN = re.compile(r'[一-鿿]{6,}')


def repo_root() -> Path:
    out = subprocess.run(["git", "rev-parse", "--show-toplevel"],
                         capture_output=True, text=True, check=True)
    return Path(out.stdout.strip())


def static_sites(sources: Path):
    """扫出所有静态写死的 ⓘ 句子，返回 [(文件:行, 原句)]。"""
    found = []
    for path in sorted(sources.rglob("*.swift")):
        for index, line in enumerate(path.read_text(encoding="utf-8").split("\n"), start=1):
            if line.strip().startswith("//"):
                continue
            for pattern in (BADGE, HELPSLOT):
                for match in pattern.finditer(line):
                    found.append((f"{path.name}:{index}", match.group(1)))
    return found


def skeleton(literal: str):
    """去掉插值之后，仍能唯一认出这一句的最长汉字串；一个都没有就判"无法静态匹配"。"""
    plain = re.sub(r'\\\([^)]*\)', '', literal).replace('\\n', ' ')
    runs = HAN_RUN.findall(plain)
    return max(runs, key=len) if runs else None


def live_help_dirs(argv):
    if argv:
        return [Path(a) for a in argv]
    root = Path(os.environ.get("TCODER_SCRATCH") or repo_root() / ".scratch")
    base = root / "tcoder-ax-tooltip"
    return sorted(p for p in base.glob("*") if p.is_dir())


def main(argv):
    root = repo_root()
    dirs = live_help_dirs(argv)
    evidence = [p for d in dirs for p in sorted(d.glob("*.txt"))]
    if not evidence:
        print("!! 没有取证产物（先跑 scripts/ax_tooltip_report.sh），本对照表不出数")
        return 1
    live = set()
    for path in evidence:
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("HELP\t"):
                live.add(line.split("\t", 1)[1])

    sites = static_sites(root / "TcoderMonitor/Sources/TcoderMonitor")
    hit, missed, unmatched = 0, [], []
    for where, literal in sites:
        key = skeleton(literal)
        if key is None:
            unmatched.append((where, literal))
        elif any(key in text for text in live):
            hit += 1
        else:
            missed.append((where, key))

    print(f"== 批次 {len(dirs)} 个 / 取证 {len(evidence)} 趟，实到 help 文案去重后 {len(live)} 条")
    print(f"== 静态应到 {len(sites)} 处：活界面上查到 {hit}，未命中 {len(missed)}，"
          f"整句都是插值·无法静态匹配 {len(unmatched)}")
    for where, key in missed:
        print(f"   未命中  {where}  「{key}」")
    for where, literal in unmatched:
        print(f"   无法静态匹配 {where}  {literal[:44]}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
