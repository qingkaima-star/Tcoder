#!/usr/bin/env python3
# 新老两条路的**逐项对表**：GUI 落盘那份 `reports/<uuid>.json` vs 无头 `tcoder scan --out`。
#
# 为什么要有这把尺子（2026-09-22 由 WS-CL 落档）：`self_score.sh` 换成一次 CLI 调用之后，
# "两条路读数一致"这句话不能靠嘴说 —— 而单测只能证明同一进程里的函数返回值一致。
# 实测正是这把对表抓出两个真缺陷：F10（退出码第 3 档在真二进制里挂死）与
# F11（热点榜尾部不可复现：排序只有两把主键 + `sorted` 不稳定）。
#
# 用法: scripts/report_parity.py <GUI 报告.json> <CLI 报告.json> <被扫总体目录>
#   退出码 0 = 逐项一致；1 = 有不可容忍的不等（逐条打印）。
# 本脚本**只读**两个 JSON，不写任何文件；输出重定向交调用方
# （按 AGENTS §1.6，一次性产物落仓库内 `.scratch/`）。
"""GUI 落盘报告 vs 无头 CLI `scan --out` 的逐项对表（取证 ①④）。

两边喂的是**同一个被扫总体**。允许不同的只有两类，且必须**逐条点名**、不许静默：
  · 时间戳：字段名以 `At` 结尾（generatedAt / attemptedAt / computedAt / analyzedAt …）
  · 项目身份：**只有 `project.id` 与 `project.name` 两格** —— GUI 那趟读的是沙箱里预置的
    projects.json（固定 UUID、名字「Tcoder（自扫打分）」），CLI 那趟就地造一个 MonitoredProject。
    ⚠️ **`project.path` 不在免检里**（2026-09-25 收窄，缺陷 #64）：原来这里写的是整族前缀
    `project.`，等于把**两格真不同**与**所有还没被看的格**一起免掉，而 #60 那枚"同一份代码在
    两棵树里给出两种路径拼写"的缺陷主角正是 `project.path` —— 它当时被这条前缀**静默容忍**掉了。
    现量凭证（收窄前先核过）：main 全量日志里 `project.*` 只出现过 id 与 name 两格，
    `project.path` **一次都没进过不等清单** ⇒ 收窄是"把盲区变成判据"，不是给自己找红。
除这两类之外，任何一处不等都算**两条路读数不一致**，逐条打印并判败。
"""
import json
import subprocess
import sys

# 逐格点名的项目身份免检键（**精确匹配**，不许再用前缀——前缀就是"整族免检"的那个洞本身）。
IGNORED_PROJECT_KEYS = ("project.id", "project.name")

# 逐条点名的"每次运行必然不同"字段。**每条必须写清为什么天然不同** ——
# 不加理由的容忍项等于把对表尺子锯短（`ProvenanceParityToleranceTests` 机器拦这条）。
# 键 = 叶子字段名，值 = 理由（理由里点出"谁来正向钉住它"）。
TOLERATED_NAMES = {
    # `code.durationMs` 是这次扫描自己用了多少毫秒 —— 它是计时读数，不是判定，
    # 拿它当"两条路不一致"来报，等于把机器负载报成缺陷（本轮 load average 10）。
    "durationMs": "本次扫描耗时，每次运行必然不同（读数而非判定）",
    # R5c（2026-09-22）：溯源块落盘后 GUI↔CLI 必然不同的两格。
    # `provenance.producedBy` 这一格**记的就是"哪个入口产的"**，两边相同反倒是对表假绿。
    "producedBy": "字段语义即「哪个入口产的」：gui 与 cli 必然不同（写它的两处各有一条点名用例）",
    # `provenance.toolVersion` = 构建配置 + 宿主 bundle。GUI 侧那份在测试里由 xctest 宿主装配
    # （`Bundle.main` 是测试运行器），CLI 侧那份是 SwiftPM 直跑的二进制 —— bundle 段天然不同。
    # ⚠️ 保留的边界：构建口径段（" · " 之前）**不许**不同，混 debug/release 是真缺陷，
    #    但该断言只能起在装配处，本脚本不重复实现（避免第三把尺子）。
    "toolVersion": "构建配置 + 宿主 bundle：两侧宿主不同是事实而非分叉（bundle 段之外由装配侧用例钉）",
}


def is_tolerated(path):
    leaf = path.rsplit(".", 1)[-1].split("[", 1)[0]
    return leaf.endswith("At") or leaf in TOLERATED_NAMES or path in IGNORED_PROJECT_KEYS


def walk(a, b, path=""):
    """返回 (不可容忍的不等, 按口径容忍的清单)。"""
    hard, soft = [], []
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            p = f"{path}.{k}" if path else k
            # ⚠️ 缺席那一侧要点名对：`k not in a`（a=GUI）说的是 **GUI 没有、只有 CLI 有**。
            # 这两句原先写反了（2026-09-24 RD-31×RD-60 那次对表就是被它带偏方向的：
            # 真缺键的是 GUI 侧那份测试装配副本，打印出来却像 CLI 侧没量到。
            # 判败/判容忍的分类与计数都不受影响，改的只是这条读数说谁）——
            # 方向由 `ProvenanceParityToleranceTests.test_absenceLabelsNameTheSideThatActuallyMisses` 钉住。
            if k not in a:
                (soft if is_tolerated(p) else hard).append(f"{p}: 只有 CLI 有（GUI 缺）")
                continue
            if k not in b:
                (soft if is_tolerated(p) else hard).append(f"{p}: 只有 GUI 有（CLI 缺）")
                continue
            h, s = walk(a[k], b[k], p)
            hard += h
            soft += s
    elif isinstance(a, list) and isinstance(b, list):
        if len(a) != len(b):
            hard.append(f"{path}: 长度 {len(a)} vs {len(b)}")
        for i, (x, y) in enumerate(zip(a, b)):
            h, s = walk(x, y, f"{path}[{i}]")
            hard += h
            soft += s
    else:
        if a != b:
            (soft if is_tolerated(path) else hard).append(f"{path}: {a!r} vs {b!r}")
    return hard, soft


def main(gui_path, cli_path, target):
    head = subprocess.run(["git", "-C", target, "rev-parse", "--short", "HEAD"],
                          capture_output=True, text=True).stdout.strip()
    files = int(subprocess.run(["git", "-C", target, "ls-files", "*.swift"],
                               capture_output=True, text=True).stdout.count("\n"))
    with open(gui_path, encoding="utf-8") as fh:
        gui = json.load(fh)
    with open(cli_path, encoding="utf-8") as fh:
        cli = json.load(fh)

    # 分母：两份读数必须出自同一个总体才可比，先各自打印再比内容。
    # 注意：`verdict` 是**计算属性**（读 `overall` 的那把唯一合法入口），不在 JSON 里；
    # 落盘 schema 里的字段是 `overall` 与 `codeScope.overall`。这里按 schema 字段打印。
    for tag, r in (("GUI", gui), ("CLI", cli)):
        code = r.get("code") or {}
        h = r.get("health") or {}
        cs = h.get("codeScope") or {}
        print(f"{tag}: 文件 {code.get('totalFiles')} · 码行 {code.get('codeLines')} · "
              f"热点榜 {len(code.get('topComplexFunctions') or [])} 项 · "
              f"综合 {h.get('overall')} · 代码口径 {cs.get('overall')} · "
              f"分量 {len(h.get('components') or [])} 个 · 缺席路 {r.get('failedSections')}")
    print(f"总体：{target} · HEAD {head} · 仓库内 .swift {files} 个")

    hard, soft = walk(gui, cli)
    print(f"逐项不等（判败）：{len(hard)} 处 · 按口径容忍（时间戳 / project 身份）：{len(soft)} 处")
    for d in hard[:40]:
        print("   ✗", d)
    for d in soft:
        print("   ℹ︎", d)
    print("结论：" + ("两条路读数逐项一致 ✅" if not hard else f"有 {len(hard)} 处不一致 ❌"))
    return 1 if hard else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1], sys.argv[2], sys.argv[3]))
