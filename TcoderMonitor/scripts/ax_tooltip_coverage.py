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
    # `sandbox-*` 是 App 自己的支持目录（reports/ 在那儿），不是读数批次。
    return sorted(p for p in base.glob("*") if p.is_dir() and not p.name.startswith("sandbox-"))


def read_help_entries(path):
    """从一份读数文件里还原 help 值，**两种格式都吃**：

    - 新版（`ax_dump` 已改）：一条 help 一行，值里的换行写成 " ⏎ "；
    - 旧版：help 原样多行打印，于是第 2 行起没有 `HELP` 前缀 —— 那正是
      "扫描边界"整本台账被读成不存在的原因（行式解析吃多行载荷）。
      不回头解析旧文件，就等于让历史那批数一直少报。
    """
    entries = []
    current = None
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("HELP\t"):
            if current is not None:
                entries.append(current)
            current = line.split("\t", 1)[1]
        elif line.startswith("SUMMARY") or not line.strip():
            if current is not None:
                entries.append(current)
                current = None
        elif current is not None:
            current += " ⏎ " + line
    if current is not None:
        entries.append(current)
    return entries


def selfcheck() -> int:
    """正对照：造一份"两种格式混在一起"的读数，逐条还原必须完全一致。

    为什么必须有：`ax_dump` 早先原样打印多行 help，下游按 `^HELP` 逐行读，
    于是每条多行 tooltip **只有第一行进了覆盖率** —— 而 359 vs 236 这个差
    是修完才看见的。行式解析吃多行载荷，本仓已经撞过三次（awk 列位那次是同族）。
    """
    import tempfile
    payload = [
        "HELP\t第一行单条",
        "HELP\t本次扫描有 6 条边界生效 ⏎ 隐藏条目 · 9 个条目 · 行数不适用 ⏎ 语言表未收录的后缀 · 行数未统计",
        "HELP\t旧格式第一条的前半",
        "旧格式第一条的后半（没有 HELP 前缀）",
        "SUMMARY windows=1 visited=3 withHelp=3",
    ]
    want = {"第一行单条",
            "本次扫描有 6 条边界生效", "隐藏条目 · 9 个条目 · 行数不适用",
            "语言表未收录的后缀 · 行数未统计",
            # 这两段就是那个 bug 的显形处：只认 `^HELP` 的解析会把它们整个丢掉
            "旧格式第一条的前半", "旧格式第一条的后半（没有 HELP 前缀）"}
    with tempfile.TemporaryDirectory() as tmp:
        path = Path(tmp) / "probe.txt"
        path.write_text("\n".join(payload) + "\n", encoding="utf-8")
        got = {piece.strip() for entry in read_help_entries(path)
               for piece in entry.split(" ⏎ ") if piece.strip()}
    missing, extra = want - got, got - want
    if missing or extra:
        print(f"!! 解析器 selfcheck 失败：少还原 {missing}，多出 {extra}")
        return 1
    print(f"✅ 解析器 selfcheck 通过：{len(want)} 段多行/单行 help 全部原样还原")
    return 0


def language_audit(argv) -> int:
    """英文态双语残留台账：把每个 help 片段分成三类，**逐条列出来给人判**。

    为什么不是"含中文即缺陷"：项目名、提交标题、文件路径这些**本来就是用户的数据**，
    英文态不翻才对。真正的缺陷是"界面的话术"没查表。所以分三类：
      A 有键没查 —— 这句已经在 `Localizable.strings` 里，说明本该翻而没去查；
      B 未登记的界面话术 —— 没键，但句式像文案（含标点/句式词），要人过一眼再登记；
      C 像数据 —— 路径 / 项目名 / 提交标题 / 纯计数，不翻。
    只报数不判败（报告器）。
    """
    dirs = live_help_dirs(argv)
    evidence = [p for d in dirs for p in sorted(d.glob("*.txt"))]
    if not evidence:
        print("!! 没有取证产物（英文态那趟：AX_LANG=en AX_SET=en ./scripts/ax_tooltip_report.sh）")
        return 1
    catalog = repo_root() / "TcoderMonitor/Resources/en.lproj/Localizable.strings"
    text = catalog.read_text(encoding="utf-8") if catalog.exists() else ""
    keys = set(re.findall(r'^"((?:[^"\\]|\\.)+)"\s*=', text, re.M))
    han = re.compile(r"[一-鿿]")
    counts: dict[str, int] = {}
    for path in evidence:
        for entry in read_help_entries(path):
            for piece in entry.split(" ⏎ "):
                piece = piece.strip()
                if piece and han.search(piece):
                    counts[piece] = counts.get(piece, 0) + 1
    # A 类判据要严：整句等于键，或键带 %N$@ 占位符且片段以键的"首个占位符之前"开头。
    # 上一版用前 14 字互相比对，结果 "相似度" 这种**列名短键**把所有以它开头的整句
    # 都算成"有键没查"—— 那是测量假象，不是缺陷（本仓第三次"分母自己骗人"）。
    def hits_key(fragment: str) -> bool:
        for key in keys:
            if fragment == key:
                return True
            if "%1$" not in key and "%@" not in key:
                continue
            head = re.split(r"%[0-9]*\$?[@ds]", key)[0]
            if len(head) >= 6 and fragment.startswith(head):
                return True
        return False

    a = [k for k in counts if hits_key(k)]
    data = [k for k in counts
            if k not in a and ("/" in k or re.search(r"^(Latest|最新)[：:]", k) or "Tcoder（" in k)]
    b = [k for k in counts if k not in a and k not in data]
    print(f"== 英文态含中文片段 {sum(counts.values())} 次 / 去重 {len(counts)} 句"
          f"（{len(evidence)} 趟）")
    print(f"   A 有键没查 : {len(a)} 句 ← 这是缺陷，且修法只是包一层 localizedCopy")
    print(f"   B 未登记话术: {len(b)} 句 ← 要登记键 + 包查表（或确认是数据后归 C）")
    print(f"   C 像数据   : {len(data)} 句 ← 项目名 / 路径 / 提交标题，不翻是对的")
    for label, group in (("A", a), ("B", b)):
        for k in sorted(group, key=lambda x: -counts[x])[:12]:
            print(f"   {label} {counts[k]:3d}× {k[:76]}")
    return 0


def main(argv):
    if argv and argv[0] == "--language-audit":
        return language_audit(argv[1:])
    if argv and argv[0] == "--selfcheck":
        return selfcheck()
    root = repo_root()
    dirs = live_help_dirs(argv)
    evidence = [p for d in dirs for p in sorted(d.glob("*.txt"))]
    if not evidence:
        print("!! 没有取证产物（先跑 scripts/ax_tooltip_report.sh），本对照表不出数")
        return 1
    live = set()
    for path in evidence:
        for entry in read_help_entries(path):
            for piece in entry.split(" ⏎ "):
                if piece.strip():
                    live.add(piece.strip())

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
