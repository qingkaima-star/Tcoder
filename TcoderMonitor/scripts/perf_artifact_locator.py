#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""按批名定位测量产物，并**指明哪一份是权威**——清工作树之前的前置（#89）。

为什么要有这个文件（09-25 22:27 现场）：需求方那笔把不可再生份从 `ws/perf-base/.scratch`
搬走之后，同一条流的产物散在三处——原地、仓库根 `.scratch/`、`.scratch/perf-base-rescue/`；
`blame1-idle-run2` 的 run 目录原地还在（导表齐全）但它的 `hitches.trace` 已经去了 rescue，
`cert7b-idle-run3` 则整批在根 `.scratch` 下。两处同名目录 **inode 不同**（不是硬链接），
而"哪一份是原件"没有任何地方写下来。已有的 `perf_reclaim.py` / 一致性尺 / `report`
都只按**自己那棵树的 `.scratch`** 找 ⇒ 复看要赌、清树更可能删掉唯一那份原件
（`.scratch` 被 gitignore ⇒ 不带 `--force` 的 remove 也不会拦，灭失不惊动任何守卫）。

判据（三条，都是可核对的，不是"我看着办"）：
  · 只有一处 ⇒ 那处就是权威份，退出码 0；
  · 多处且 inode 全同（同一份被数了两遍，例如同一目录传了两遍）⇒ 仍算一份，退出码 0；
  · 多处且 inode 不同 ⇒ **分叉**。报 ⚠、逐处点名，**拒绝替人挑一份**，退出码 2。
    分叉再分三种形状，各说各的话：**互补**（各握有对方没有的条目）／**包含**（一份的名单被另一份包住）
    ／**名单一致**（纯副本）。上一版只有一种话术，于是把「包含」印成了「不重叠」——见 `compare_copies`。
一条都不许静默：扫了几个根、命中几处、每处有没有 `*.trace`，全部打印（分母为 0 就是发现，不是通过）。
"""

import argparse
import json
import os
import subprocess
import sys

TABLE_HINTS = ("meta.json", "hitches.json", "hitches.xml", "summary.txt")


def default_roots():
    """批目录的惯例落点是**树的根** `.scratch`（各脚本 `cd TcoderMonitor` 后写作 `../.scratch`），
    搬家后的在仓库根 `.scratch` 与其子目录里。三个都扫，缺一处就会把"分叉"读成"只有一份"——
    09-25 22:31 第一版正是漏了树根那一处：`blame1-idle-run2` 原地明明还在，它却报"权威份就一处"。
    """
    here = os.path.abspath(os.getcwd())
    out = [os.path.join(here, ".scratch"), os.path.join(os.path.dirname(here), ".scratch")]
    try:
        top = subprocess.run(["git", "worktree", "list", "--porcelain"], capture_output=True,
                             text=True, check=True).stdout.splitlines()
        repo = next((l[len("worktree "):] for l in top if l.startswith("worktree ")), None)
        if repo:
            out.append(os.path.join(repo, ".scratch"))
        else:
            print("    ⚠ `git worktree list` 第一行不是 worktree ⇒ 仓库根没进搜索列表")
    except Exception as e:  # 不在 git 里也要能用：只查本树，并把"没找到仓库根"说出来
        print("    ⚠ 认不出仓库根（%s）⇒ 只扫本树两处 .scratch" % type(e).__name__)
    seen, uniq = set(), []
    for r in out:
        rr = os.path.normpath(r)
        if rr not in seen:
            seen.add(rr)
            uniq.append(rr)   # 不存在的根也留着：扫了几处必须如实报，别悄悄缩分母
    return uniq


def scan_root(root, name):
    """在 root 下**深度 ≤2** 找 basename == name 的目录（覆盖 rescue/这类中间层）。"""
    hits = []
    if not os.path.isdir(root):
        return hits
    for dirpath, dirnames, _ in os.walk(root):
        depth = os.path.relpath(dirpath, root).count(os.sep) if dirpath != root else -1
        if depth >= 2:
            dirnames[:] = []
            continue
        for d in dirnames:
            if d == name:
                hits.append(os.path.join(dirpath, d))
    return hits


def describe(path):
    """一处产物的实况：inode、mtime、trace 束数、导表齐不齐、体积。**不猜，读不到就说读不到**。"""
    st = os.stat(path)
    traces = []
    for dirpath, dirnames, _ in os.walk(path):
        for d in dirnames:
            if d.endswith(".trace"):
                traces.append(os.path.join(dirpath, d))
        if dirpath != path and os.path.relpath(dirpath, path).count(os.sep) >= 1:
            dirnames[:] = []
    du = subprocess.run(["du", "-sk", path], capture_output=True, text=True)
    mib = int(du.stdout.split()[0]) / 1024.0 if du.stdout.strip() else None
    return {
        "path": path, "inode": st.st_ino, "mtime": st.st_mtime,
        "traces": len(traces), "trace_paths": traces,
        "tables": [t for t in TABLE_HINTS if os.path.isfile(os.path.join(path, t))],
        "mib": mib,
    }


def locate(name, roots):
    hits = []
    for r in roots:
        for h in scan_root(r, name):
            hits.append(describe(h))
    return hits


def inventory(path):
    """一份产物**第一层有什么**的名单。只看名单、不钻 `.trace` 内部——比 1 GB 级的东西
    不是这把尺的活，而「没比过内容」这件事本身要在结论里写明白，不许偷偷当成「比过且相同」。
    """
    try:
        return set(os.listdir(path))
    except OSError:
        return set()


def covers(invs):
    """每份产物被**哪些别处**的名单包住：下标 i → 包住 i 的那些下标（自身不算）。
    全部非空 ⇔ 所有名单互相包住 ⇔ 它们**全等**（这条不抄来路：n=3 的链 A⊆B⊆C⊆A 也只能全等）。
    """
    return [[j for j in range(len(invs)) if j != i and invs[i][1] <= invs[j][1]]
            for i in range(len(invs))]


def equal_shape():
    return ["      ⚠ **名单一致、inode 不同** ⇒ 各存一份的副本。**是否逐字相同这把尺没验**"
            "（不钻 `.trace`）⇒ 仍然请人来定权威份，本工具不代挑。"]


def covered_shape(invs, cov):
    lines = []
    for i, js in enumerate(cov):
        if js:
            lines.append("      · 名单上被包住：%s 的每一项在 %s 里都有同名条目 ⇒ 后者是**名单更全**的那一份。"
                         % (invs[i][0]["path"], "、".join(invs[j][0]["path"] for j in js)))
    lines.append("      但这句推不出「可以删了它」：**内容是否逐字相同这把尺没验**（不钻 `.trace`）。")
    return lines


def disjoint_shape(invs):
    lines = []
    for i, (h, inv) in enumerate(invs):
        rest = set().union(*[o for j, (_, o) in enumerate(invs) if j != i])
        lines.append("      · %s 独有（别处没有的条目）：%s"
                     % (h["path"], ", ".join(sorted(inv - rest)) or "（无）"))
    lines.append("      ⚠ **各握有对方没有的东西** ⇒ **哪一份都不能单独删**，"
                 "删错那一半就等于把这批读数判死（导表还在但无法复算，或反之）。")
    return lines


def compare_copies(hits):
    """两份到底差在哪。**三种形状各说各的话**，尤其不许把「一份包住另一份」印成「两份不重叠」：
    09-25 22:44 拿实批次跑 `cert7b-idle-run1` 就被上一版这样骗过一次——那两处导表**都齐全**、
    只差 §149 那对 `*.trace` / `*.trace.moved`，一句「不重叠」会把人推向「删哪份都疼」的错结论。
    （拆成四个小函数不是我勤快：`compare_copies` 第一版 CC=19，被这把尺自己的
      「函数 CC<16」棘轮当场判红 —— 名单进了 `rulerScripts` 就要按名单的规矩活。）
    """
    invs = [(h, inventory(h["path"])) for h in hits]
    if any(not inv for _, inv in invs):
        return ["      ⚠ 有一处列不出名单（目录为空或读不到）⇒ 「互补／包含／一致」三种形状**都判不了**，"
                "这里只报分叉这一件事实，不报谁包住谁。"]
    cov = covers(invs)
    if all(cov):
        return equal_shape()
    if any(cov):
        return covered_shape(invs, cov)
    return disjoint_shape(invs)


def tree_side_line(hits):
    """分叉时**只要有一处在本树**，就必须点名这一条：`report`／一致性尺／回收器都只按
    自己那棵树的 `.scratch` 找产物 ⇒ 删掉本树那一份，这批读数就在现有尺子面前消失，
    **哪怕别处还躺着更全的一份**（09-25 22:44 实跑的 cert7b 正是这个形状：
    本树那份导表齐全但原始 trace 已去了仓库根的 rescue）。
    """
    here = os.path.realpath(os.getcwd())
    mine = [os.path.realpath(p) for p in (os.path.join(here, ".scratch"),
                                          os.path.join(os.path.dirname(here), ".scratch"))]
    # 两边都走 realpath：`os.getcwd()` 给解析过的真路径，而 `--root` 传进来的可能是
    # `/var/…` 这种经符号链接的写法（macOS 上 /var → /private/var），按字符串前缀比会**漏判本树**
    # —— 09-25 22:42 第 69 项第一次跑就是这么红的。同一份路径两种写法，本仓已立案过一回（#53 族）。
    sides = [h["path"] for h in hits
             if any(os.path.realpath(h["path"]).startswith(m + os.sep) for m in mine)]
    if not sides:
        return []
    return ["      ⚠ 本树这一份（%s）是 `report`／一致性尺**唯一认得**的那一份 ⇒ 清树删它 "
            "= 这批读数在现有尺子面前消失，别处那份再全也不会被它们读。" % "、".join(sides)]


def report(name, hits, roots):
    print("== 产物定位：%s（扫了 %d 个根：%s）==" % (name, len(roots), ", ".join(roots)))
    if not hits:
        print("   ✗ 一处都没找到 ⇒ 要么批名不对，要么原件已经没了。"
              "**别把这一行读成『这批没有产物』以外的任何结论**，先去核对批名。")
        return 1
    for h in hits:
        print("   %s" % h["path"])
        print("      inode=%d  trace 束=%d  导表=%s  体积=%s"
              % (h["inode"], h["traces"],
                 "/".join(h["tables"]) or "（一份都没有）",
                 ("%.1f MiB" % h["mib"]) if h["mib"] is not None else "读不到"))
    inodes = sorted({h["inode"] for h in hits})
    if len(inodes) == 1:
        print("   ⇒ 权威份就一处（%s）⇒ 可以按它复看；清树要动它必须先给结论。" % hits[0]["path"])
        return 0
    print("   ⚠ **分叉**：%d 处同名产物、%d 个不同 inode ⇒ 不是硬链接，是各存一份。" % (len(hits), len(inodes)))
    for h in hits:
        has_orig = "有原始 trace(%d)" % h["traces"] if h["traces"] else "无原始 trace"
        has_tables = "有导表(%s)" % "/".join(h["tables"]) if h["tables"] else "无导表"
        print("      · %s ⇒ %s、%s" % (h["path"], has_orig, has_tables))
    for line in compare_copies(hits) + tree_side_line(hits):
        print(line)
    print("      本工具**不替人挑一份**。请人来定权威份并写下来，再决定动不动任何一处。")
    return 2


def main(argv=None):
    ap = argparse.ArgumentParser(description="按批名定位测量产物 + 指明权威份（#89）")
    ap.add_argument("names", nargs="+", help="批名或 run 目录名（如 tcoder-perf-cert7b-idle-run1）")
    ap.add_argument("--root", action="append", dest="roots",
                    help="自定义搜索根（可重复）；不给就用本树 .scratch + 仓库根 .scratch")
    args = ap.parse_args(argv)
    roots = args.roots or default_roots()
    rc = 0
    for n in args.names:
        code = report(n, locate(n, roots), roots)
        rc = max(rc, code)
    return rc


if __name__ == "__main__":
    sys.exit(main())
