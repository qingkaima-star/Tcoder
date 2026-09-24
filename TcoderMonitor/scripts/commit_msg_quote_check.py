#!/usr/bin/env python3
"""提交正文的 ASCII 双引号自检（AGENTS §1.5 那条规约的秒级尺子）。

为什么要它：本仓反复犯同一件小事——中文句子里用了 ASCII 双引号。
R37 自报前两笔有，我自己 `29e067a` 的标题也有（不再把 no-op 合并报成「已合入」）。
规约禁止 git 钩子与 --no-verify（那是绕过门禁，不是修工具），
所以拦这一条只能靠提交前自己跑一支尺子。

判据（三条，缺一要么被绕过、要么误伤）：
1. 只看 **CJK 邻域**里的 ASCII 双引号：左右各 6 字符内出现中日韩文字才算违规
   ⇒ `grep --include="*.swift"` 这种命令片段（左右都是 ASCII）不报。
2. **反引号整段豁免**：把 `x="y"` 当代码而不是中文句子里的引号；列号不移位（替换成等长空白）。
3. 按**行**报（行号 + 列号 + 原文片段），因为这是要给人改的，只报"共 1 处"没法动手。

已知限度（不吹成已封）：
  * 真代码紧挨中文又没进反引号 ⇒ 会误报。处置是把那段用反引号包住，判据本身不改。
  * 只查双引号；撇号 ' 在中文里合法用法太多，不在射程内。
  * 不查半角逗号/括号等其它中英混排毛病。

用法：
  scripts/commit_msg_quote_check.py <文件>
  git log -1 --format=%B | scripts/commit_msg_quote_check.py -
  scripts/commit_msg_quote_check.py --scan [N]      # 检最近 N 笔正文（现量，默认 30）
退出码：0 干净 / 1 有违规 / 2 用法错或读不到输入。
"""
import re
import subprocess
import sys

CJK = re.compile(r"[\u3000-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]")
BACKTICK_SPAN = re.compile(r"`[^`]*`")
NEIGHBOR = 6


def strip_code_spans(line: str) -> str:
    out = list(line)
    for m in BACKTICK_SPAN.finditer(line):
        for i in range(m.start(), m.end()):
            out[i] = " "
    return "".join(out)


def has_cjk_neighbor(text: str, index: int) -> bool:
    window = text[max(0, index - NEIGHBOR):index] + text[index + 1:index + 1 + NEIGHBOR]
    return bool(CJK.search(window))


def find_violations(text: str):
    hits = []
    for no, raw in enumerate(text.splitlines(), start=1):
        scannable = strip_code_spans(raw)
        for col, ch in enumerate(scannable):
            if ch == '"' and has_cjk_neighbor(scannable, col):
                hits.append((no, col + 1, raw.strip()[:120]))
                break
    return hits


def report(text: str, label: str) -> int:
    if not text.strip():
        print(f"❌ {label}: 读不到任何正文 ⇒ 不许把「没内容」读成「干净」，判用法错")
        return 2
    hits = find_violations(text)
    for no, col, snippet in hits:
        print(f"{label}:{no}:{col}: {snippet}")
    if hits:
        print(f"❌ {label}: 中文语境里的 ASCII 双引号 {len(hits)} 处（一行报一枚）"
              f"—— 引用改走「」，命令片段用反引号包住")
        return 1
    print(f"✓ {label}: 0 处违规（扫 {len(text.splitlines())} 行）")
    return 0


def main(argv):
    if len(argv) < 2:
        print("用法: commit_msg_quote_check.sh <文件|-> 或 --scan [N]")
        return 2
    if argv[1] == "--scan":
        n = int(argv[2]) if len(argv) > 2 and argv[2].isdigit() else 30
        out = subprocess.run(["git", "log", f"-{n}", "--format=%x00%B"],
                             capture_output=True, text=True)
        if out.returncode != 0:
            print(f"❌ git log 失败（rc={out.returncode}）：{out.stderr.strip()[:200]}")
            return 2
        bodies = [b for b in out.stdout.split("\0") if b.strip()]
        if not bodies:
            print("❌ --scan 拿到 0 笔提交正文 ⇒ 判据在空转，不许读成「全部干净」")
            return 2
        worst = 0
        for i, body in enumerate(bodies, start=1):
            worst = max(worst, report(body, f"HEAD~{i - 1}" if i > 1 else "HEAD"))
        print(f"==> 扫最近 {len(bodies)} 笔提交正文")
        return worst
    if argv[1] == "-":
        return report(sys.stdin.read(), "<stdin>")
    path = __import__("pathlib").Path(argv[1])
    if not path.is_file():
        print(f"❌ 读不到文件：{argv[1]}")
        return 2
    return report(path.read_text(encoding="utf-8"), argv[1])


if __name__ == "__main__":
    sys.exit(main(sys.argv))
