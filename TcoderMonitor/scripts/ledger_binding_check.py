#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""ledger_binding_check.py —— 台账**装订层**的普查尺：节号唯一、每节有指路行、行文本 == 标题。

为什么要有它（台账卷十 §165）：2026-09-26 开第十卷时我顺手写了一次性核验（在 `/tmp`），
第一次跑就点名三条旧账 —— 10 条**双前缀**指路行、卷七 17 节只列了 4 行、
卷五末尾那行搬家标题写成 `## §93 起搬家到第六卷`（各卷开头明令禁止的形状，
它让普查凭空数出一个假 §93）。三条都修好了，但**证明它们的尺随会话消失**——
那正是卷七 §107 记过的形状：一条验收落地后没有尺子检查它还在不在。这把尺就是那个"还在不在"。

**为什么不在 `PerfRulerHotspotRatchetTests.rulerScripts` 里**：那张名单的盘上全集按
`perf_` 前缀取（见 `testRosterCoversEveryScriptOnDisk`），本文件量的不是测量链而是文档装订，
与 `commit_msg_quote_check.py`／`guard_ledger_summary.py` 同类。**它的承载者是 selfcheck 的
`selfcheck_ledger_binding_is_consistent`** —— 那条反例项一跑就会 `--root` 指到夹具，
尺子坏了或被删掉，selfcheck 立刻红。

**射程（不写出来就会被读成"那几卷是空的"）**：
· 只认 `## §NNN 标题` 这种编号形状（卷五起）。卷一~卷四用 `## 58.` 那种老形状，本尺数到 0 节，
  报「未覆盖」而不是缺陷；
· **指路行只在"块内"取**：第一条 `## §` 正文标题之前的 `· §NNN …` 才是行。
  全文件取行会把正文里 `· §164 的另一条歧义…` 这类同形状条目当成指路行（本尺原型就这么假红过一次）；
· 卷头没有「本节一览」块的卷（卷五／卷六，约定晚于它们）记 **未覆盖**，不判缺陷。

用法：`ledger_binding_check.py [--root docs目录] [--pattern 文件名子串]`；全绿 rc=0，任一violated rc=1。
"""
import argparse
import collections
import io
import os
import re
import sys

SECTION_RE = re.compile(r"^## §(\d+) (.*)$")
ROW_RE = re.compile(r"^· §(\d+) (.*)$")
MOVED_RE = re.compile(r"^## §\d+ 起搬家")      # 禁止的形状：搬家标题以节号开头
BLOCK_RE = re.compile(r"^## .*(本节一览|一览)")


def read_lines(path):
    with io.open(path, encoding="utf-8") as handle:
        return handle.read().split("\n")


def volumes(root, pattern):
    """卷册清单：目录下所有含 `pattern` 的 `.md`（新卷在落地那一刻还没被 git 跟踪，所以不查 git）。"""
    return sorted(os.path.join(root, name) for name in os.listdir(root)
                  if name.endswith(".md") and pattern in name)


def scan(path):
    """数一卷的三件事：节（号→标题）、块内指路行、以及禁止形状的搬家标题。"""
    lines = read_lines(path)
    sections = {}
    order = []
    for line in lines:
        hit = SECTION_RE.match(line)
        if hit:
            number = int(hit.group(1))
            sections.setdefault(number, hit.group(2))
            order.append(number)
    body_start = next((i for i, l in enumerate(lines) if SECTION_RE.match(l)), len(lines))
    rows = {int(h.group(1)): h.group(2)
            for line in lines[:body_start] for h in [ROW_RE.match(line)] if h}
    has_block = any(BLOCK_RE.match(l) for l in lines[:body_start])
    forbidden = [i + 1 for i, l in enumerate(lines) if MOVED_RE.match(l)]
    return {"path": path, "sections": sections, "rows": rows, "has_block": has_block,
            "forbidden_move_headings": forbidden}


def findings(found):
    """把一卷的读数折成"缺陷清单"。返回 [(卷, 类别, 说明)]；未覆盖的东西不进这里。"""
    out = []
    name = os.path.basename(found["path"])
    sections, rows = found["sections"], found["rows"]
    if found["forbidden_move_headings"]:
        out.append((name, "搬家标题以节号开头",
                    "第 %s 行 `## §NN 起搬家到…` ⇒ 会被扫节号的普查当成真节（改成 `## 搬家记录：§NN 起在…`）"
                    % found["forbidden_move_headings"]))
    if not found["has_block"]:
        return out                                  # 没有块 ⇒ 整卷未覆盖，不逐节报缺行
    for number in sorted(sections):
        if number not in rows:
            out.append((name, "缺指路行", "§%d 没有 `· §%d …` 那一行" % (number, number)))
        elif rows[number] != sections[number]:
            out.append((name, "指路行与标题不一致",
                        "§%d\n      标题: %s\n      一行: %s" % (number, sections[number], rows[number])))
    for number in sorted(set(rows) - set(sections)):
        out.append((name, "指路行指向不存在的节", "· §%d 而本卷没有 ## §%d" % (number, number)))
    return out


def duplicates(found_list):
    """节号是全局的、卷号只是装订 ⇒ 同一个号出现在两卷就是断链风险。"""
    where = collections.defaultdict(list)
    for found in found_list:
        for number in found["sections"]:
            where[number].append(os.path.basename(found["path"]))
    return {n: v for n, v in where.items() if len(v) > 1}


def report(found_list):
    """逐卷印分母读数 + 一行总账。**有块/无块必须分开印**，否则"节 0"会被读成"那几卷是空的"。

    那行「分母」不是装饰：反例第 73 项第一次跑就把一个洞照出来 —— 夹具卷被我自己写坏成
    空文件之后，尺子报「无一览块 → 记未覆盖」并且 rc=0。**读不到东西给了绿灯**，
    与本仓那条老账（坏掉的尺最擅长产出看着合理的数）同族。总账连同下面的
    `blocked == 0` 判错，就是把这一格从"看起来正常"变成"当场红"。
    """
    blocked = sum(1 for f in found_list if f["has_block"])
    sections = sum(len(f["sections"]) for f in found_list)
    rows = sum(len(f["rows"]) for f in found_list)
    for found in found_list:
        name = os.path.basename(found["path"]).replace("检测正确性整改清单", "")
        print("   %-12s 节 %2d  块内行 %2d  %s" % (
            name, len(found["sections"]), len(found["rows"]),
            "有块" if found["has_block"] else "无一览块 → 记未覆盖（约定晚于本卷）"))
    print("   分母：卷册 %d 本 / 有块 %d 本 / 节 %d 处 / 块内行 %d 条"
          % (len(found_list), blocked, sections, rows))
    return blocked


def default_root():
    """默认量本仓的 `docs/`：本文件 → scripts → TcoderMonitor → 仓库根 ⇒ 换 cwd 也不指错。"""
    here = os.path.dirname(os.path.abspath(__file__))
    return os.path.normpath(os.path.join(here, "..", "..", "docs"))


def main(argv=None):
    parser = argparse.ArgumentParser(description="台账装订层普查：节号唯一、指路行齐、行文本 == 标题")
    parser.add_argument("--root", default=None, help="卷册所在目录（默认本仓 docs/）")
    parser.add_argument("--pattern", default="整改清单", help="文件名子串，用于只取台账卷册")
    args = parser.parse_args(argv)
    root = args.root or default_root()
    try:
        paths = volumes(root, args.pattern)
    except OSError as error:
        print("❌ 数不到卷册目录 %s：%s ⇒ 分母不成立，本次不作数" % (root, error))
        return 1
    if not paths:
        print("❌ %s 下按 %r 数到 0 本卷册 ⇒ 分母不成立，下面的『全绿』一律不作数" % (root, args.pattern))
        return 1
    found_list = [scan(p) for p in paths]
    print("【台账装订层】普查 %d 本卷册（--root %s --pattern %s）" % (len(paths), root, args.pattern))
    blocked = report(found_list)
    if blocked == 0:
        print("判定：**不成立** —— 一本带「本节一览」块的卷册都没数到 ⇒ 枚举或正则坏了，"
              "此时逐卷那句『未覆盖』只是集体看不见，不构成绿（实测过：夹具被写坏成空文件时就是这样）")
        return 1
    problems = [row for found in found_list for row in findings(found)]
    collide = duplicates(found_list)
    for name, kind, detail in problems:
        print("   ❌ %s / %s：%s" % (name, kind, detail))
    for number, places in sorted(collide.items()):
        print("   ❌ 跨卷重复节号 §%d：%s" % (number, places))
    if problems or collide:
        print("判定：**不成立** —— 缺行 %d、多行/文本不符 %d、重复节号 %d"
              % (len([p for p in problems if p[1] == "缺指路行"]),
                 len([p for p in problems if p[1] != "缺指路行"]), len(collide)))
        return 1
    print("判定：成立 ✓ —— 有块的卷册指路行齐且与标题一致、无重复节号、无禁止形状的搬家标题")
    return 0


if __name__ == "__main__":
    sys.exit(main())
