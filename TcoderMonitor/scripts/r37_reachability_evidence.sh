#!/bin/bash
# WS-R37 取证脚本：那几条「缺证据不给分」的评分支路，真项目走不走得到。
#
# 这一档只做一件事：**造真夹具 → 跑真分析器（无头 CLI 真子进程）→ 把原始字段与
# 那句话原文抄出来**。它不判绿不判红（判定在 Tests/TcoderMonitorTests/
# ScoreBranchReachabilityTests.swift 里，那边才有断言），因为 AGENTS §8 第 6.1 条
# 要的就是「现量原始输出」，一份被断言加工过的读数不算。
#
# ⚠️ 夹具根**必须**在被测仓库之外、且祖先链上没有任何 `.git`：
#    · `ShellGitAnalyzer.resolveRepository` 会向上爬 6 层父目录找仓库，
#      `LogProjectIdentity.projectAnchor` 向上爬 8 层 —— 夹具只要落在
#      `/Users/one/Documents/Tcoder`（含 `.worktrees/**/.scratch`）任何一层，
#      「不是仓库」这一格就永远造不出来，Git 那一维会读到**宿主仓库**的历史
#      （本仓踩过：放在主仓库树内的无关项目夹具继承宿主 git 身份，造出假缺陷）。
#    · 只用 `mktemp` 式的**唯一子目录**并事前拒绝已存在、事后自清，
#      这是另一类坑（`/tmp` 里的孤儿夹具喂假绿）的解法。
#    一次性产物（本脚本的原始输出）落仓库内 `.scratch/`，夹具本体落临时目录。
set -u
cd "$(dirname "$0")/.." || exit 1

BIN="${TCODER_CLI_BIN:-.build/debug/TcoderMonitor}"
[ -x "$BIN" ] || { echo "!! 找不到可执行的被测二进制：$BIN（先跑 ./scripts/locked_build.sh build）"; exit 1; }
SCRATCH="${TCODER_SCRATCH:-$(pwd)/.scratch}"
STAMP="$(date +%Y%m%d-%H%M%S)-$$"
EVIDENCE="$SCRATCH/tcoder-r37-reach-$STAMP"
FIXROOT="${TMPDIR%/}/tcoder-r37-reach-$STAMP"
mkdir -p "$EVIDENCE" || { echo "!! 建不了证据目录 $EVIDENCE"; exit 1; }
if [ -e "$FIXROOT" ]; then echo "!! 夹具根已存在（唯一性子目录失效，拒绝复用别人的夹具）：$FIXROOT"; exit 1; fi
mkdir -p "$FIXROOT" || exit 1
cleanup() { rm -rf "$FIXROOT"; }
trap cleanup EXIT
trap 'cleanup; exit 130' INT

# 夹具里的 git 一律用**自己那一套配置**，不读全局/系统配置（那台机器上的
# user.name、commit.gpgsign、init.defaultBranch 都不该影响夹具形状）。
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
export GIT_AUTHOR_NAME="R37 Fixture" GIT_AUTHOR_EMAIL="fixture@tcoder.local"
export GIT_COMMITTER_NAME="R37 Fixture" GIT_COMMITTER_EMAIL="fixture@tcoder.local"

say() { printf '\n===== %s =====\n' "$*"; }

# 祖先链自证：这条链上有一枚 .git 就不许往下跑（否则 ④ 那一格是假的）。
assert_no_ancestor_git() {
  local d="$FIXROOT"
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    if [ -e "$d/.git" ]; then echo "!! 夹具根祖先带 .git：$d ⇒ ④「不是仓库」造不出来"; return 1; fi
    d="$(dirname "$d")"
  done
  echo "preflight: 夹具根 $FIXROOT 的祖先链上没有 .git"
}

# 一个「别的都正常」的项目底座：源码 + Package.swift（给日志一个产品名）
make_base() { # $1=目录 $2=产品名
  mkdir -p "$1/Sources/$2" "$1/Logs"
  printf 'name: "%s"\n' "$2" > "$1/Package.swift"
  local i
  for i in 1 2 3 4 5 6 7 8; do
    printf 'import Foundation\n\nfunc step%d() -> Int { %d }\n' "$i" "$i" \
      > "$1/Sources/$2/File$i.swift"
  done
}

# 一个真 git 仓库：$1 目录、$2 提交数、$3.. 作者名列表（轮流署名）
make_repo() {
  local dir="$1" count="$2"; shift 2
  local authors=("$@"); [ ${#authors[@]} -gt 0 ] || authors=("R37 Fixture")
  ( cd "$dir" && git init -q -b main && git config commit.gpgsign false
    local i name
    for i in $(seq 1 "$count"); do
      name="${authors[$(( (i - 1) % ${#authors[@]} ))]}"
      printf 'line %s %s\n' "$name" "$i" >> tracked.txt
      git add -A
      GIT_AUTHOR_NAME="$name" GIT_AUTHOR_EMAIL="$(printf '%s' "$name" | tr 'A-Z ' 'a-z-')@tcoder.local" \
        GIT_COMMITTER_NAME="$name" \
        GIT_COMMITTER_EMAIL="$(printf '%s' "$name" | tr 'A-Z ' 'a-z-')@tcoder.local" \
        git commit -qm "commit $i by $name"
    done )
}

# 一份真形状 .ips：**首行 header 紧凑 JSON + 其余整段 body 缩进 JSON**（苹果报告的形状）。
# 这个分段不是审美：`CrashReportParser.ipsJSONSections` 只按第一个换行切两段，
# body 若是「多行多个 JSON 对象」就整体解不开 ⇒ 退化成 header ⇒ 判「解析失败」，
# 崩溃数就变成 0，那一格要说的句子也跟着换一支（实测踩过，故写在这里）。
write_ips() { # $1=路径 $2=进程名 $3=总行数
  python3 - "$1" "$2" "${3:-400}" <<'PY'
import json, sys, datetime
path, proc, total = sys.argv[1], sys.argv[2], int(sys.argv[3])
now = datetime.datetime.now().astimezone()
stamp = now.strftime("%Y-%m-%d %H:%M:%S %z")
head = {"app_name": proc, "app_version": "1.0 (1)", "bug_type": "309",
        "incident_id": "R37INCIDENT0001", "is_first_party": 1, "name": proc,
        "os_version": "macOS 26.5.1 (25F80)", "roots_installed": 0,
        "slice_uuid": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        "timestamp": stamp, "version": 2}
body = {"bug_type": "309", "incident_id": "R37INCIDENT0001", "timestamp": stamp,
        "version": 2, "procName": proc, "parentProc": "launchd",
        "app_version": "1.0 (1)", "os_version": "macOS 26.5.1 (25F80)",
        "exception": {"type": "EXC_CRASH", "signal": "SIGABRT"},
        "termination": {"indicator": "Abort trap: 6"},
        "threads": [{"id": 7, "triggered": True, "frames": [
            {"imageIndex": 0, "symbol": proc + "Store.flush(index: 0)",
             "sourceLineInfo": {"file": "Store.swift", "line": 100}}]}],
        "usedImages": []}
def render():
    return json.dumps(body, indent=2, ensure_ascii=False)
index = 0
while 1 + len(render().split("\n")) < total:
    body["usedImages"].append({"index": index, "name": "libR37Filler%d.dylib" % index, "size": 4096})
    index += 1
text = json.dumps(head, separators=(",", ":")) + "\n" + render() + "\n"
open(path, "w").write(text)
print("ips lines written = %d" % text.count("\n"))
PY
}

# 一份真日志：$1 路径、$2 行数、$3 每几行一条 ERROR（0 = 全 INFO）
write_log() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys, datetime
path, lines, every = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
now = datetime.datetime.now()
out = []
for i in range(lines):
    stamp = (now - datetime.timedelta(seconds=i)).strftime("%Y-%m-%d %H:%M:%S")
    if every and i % every == every - 1:
        out.append(f"{stamp} ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId={i}")
    else:
        out.append(f"{stamp} INFO  [order-service] c.e.s.Health - 心跳序号 {i}")
open(path, "w").write("\n".join(out) + "\n")
PY
}

# 一次完整取证：score 文本 + scan JSON + 原始字段抽取
probe() { # $1=代号 $2=项目目录
  local tag="$1" dir="$2"
  say "$tag · CLI score"
  "$BIN" score "$dir" --window-days=7 > "$EVIDENCE/$tag.score.txt" 2>&1
  echo "rc=$? -> $EVIDENCE/$tag.score.txt"
  cat "$EVIDENCE/$tag.score.txt"
  say "$tag · CLI scan（落盘 JSON）"
  "$BIN" scan "$dir" --compact --out="$EVIDENCE/$tag.scan.json" > "$EVIDENCE/$tag.scan.stdout" 2>&1
  echo "rc=$? -> $EVIDENCE/$tag.scan.json"
  python3 "$DIR_PY" "$EVIDENCE/$tag.scan.json"
}

DIR_PY="$EVIDENCE/dump_fields.py"
cat > "$DIR_PY" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
def show(label, obj, keys):
    print(f"  {label}: " + " · ".join(f"{k}={json.dumps(obj.get(k), ensure_ascii=False)}" for k in keys))
print("  [盘上 JSON 原始字段]")
show("logs", r.get("logs") or {}, ["totalLinesScanned", "crashCount", "crashReportCount",
                                  "crashReportLineCount", "errorCount", "exceptionCount",
                                  "fatalCount", "scannedFiles", "readFailedFiles"])
g = r.get("git")
if g is None:
    print("  git: null（这一路没产出对象）")
else:
    authors = g.get("authors") or []
    basis = sum(a.get("commits", 0) for a in authors)
    print(f"  git: totalCommits={g.get('totalCommits')} commitsAnalyzed={g.get('commitsAnalyzed')} "
          f"authorBasisCommits={basis} activeAuthorCount={len(authors)} "
          f"authors={json.dumps([{'name': a.get('name'), 'commits': a.get('commits')} for a in authors], ensure_ascii=False)}")
h = r.get("health") or {}
present = {c["name"]: c["score"] for c in h.get("components") or []}
allnames = ["代码质量", "复杂度", "重复度", "注释与可维护性", "提交活跃度", "协作分布",
            "运行稳定性", "依赖健康", "测试覆盖"]
print("  [加权总分] overall=" + json.dumps(h.get("overall"), ensure_ascii=False)
      + " · components=" + json.dumps(present, ensure_ascii=False))
print("  [缺席维度 missingDimensions] " + json.dumps([n for n in allnames if n not in present], ensure_ascii=False))
for i, t in enumerate(h.get("recommendations") or [], 1):
    print(f"  [建议{i}] {t}")
PY

assert_no_ancestor_git || exit 1

# ---- ① 只有崩溃报告、零真日志行（RD-49 那一格）--------------------------------
S1="$FIXROOT/R37CrashOnlyApp"
make_base "$S1" "R37CrashOnlyApp"; make_repo "$S1" 9
write_ips "$S1/R37CrashOnlyApp-$(date +%Y-%m-%d-%H%M%S).ips" "R37CrashOnlyApp" 400
probe "shape1-crash-only" "$S1"

# ---- ② 日志有内容但极薄（3 行、0 错误）⇒ isThin 降档 -------------------------
S2="$FIXROOT/R37ThinLogApp"
make_base "$S2" "R37ThinLogApp"; make_repo "$S2" 9
write_log "$S2/Logs/app.log" 3 0
probe "shape2-thin-logs" "$S2"

# ---- ③ Git 仓库但零提交（git init 后什么都没提交）----------------------------
S3="$FIXROOT/R37EmptyRepo"
make_base "$S3" "R37EmptyRepo"
( cd "$S3" && git init -q -b main && git config commit.gpgsign false )
probe "shape3-zero-commit" "$S3"
echo "  独立真值：rev-list --count HEAD = $( cd "$S3" && git rev-list --count HEAD 2>&1 | head -1 )"
echo "  独立真值：git log --no-merges 行数 = $( cd "$S3" && git log --no-merges --oneline 2>/dev/null | wc -l | tr -d ' ' )"

# ---- ③b 「有提交但作者表为空」：作者日期是 5 位数年份，行解析整条丢弃 ----------
S3B="$FIXROOT/R37FarFutureRepo"
make_base "$S3B" "R37FarFutureRepo"
( cd "$S3B" && git init -q -b main && git config commit.gpgsign false
  printf 'x\n' > tracked.txt && git add -A
  GIT_AUTHOR_DATE="@999999999999 +0800" GIT_COMMITTER_DATE="@999999999999 +0800" \
    git commit -qm "commit with a five-digit author year" )
echo "  独立真值：%aI = $( cd "$S3B" && git log -1 --pretty=format:'%aI' )"
echo "  独立真值：rev-list --count HEAD = $( cd "$S3B" && git rev-list --count HEAD )"
probe "shape3b-far-future-date" "$S3B"

# ---- ④ 不是仓库的普通目录 ⇒ Git 那一维整维缺席 -------------------------------
S4="$FIXROOT/R37PlainDirectory"
make_base "$S4" "R37PlainDirectory"
probe "shape4-not-a-repo" "$S4"
echo "  doctor 那一格：$("$BIN" doctor "$S4" | grep -a '是 Git 仓库' || echo '未出声')"

# ---- ⑤ 提交全在同一个作者名下 ⇒ 单人占比那一支 -------------------------------
S5="$FIXROOT/R37SoloAuthor"
make_base "$S5" "R37SoloAuthor"; make_repo "$S5" 12 "Solo Owner"
probe "shape5-single-author" "$S5"
echo "  独立真值：--no-merges 提交数 = $( cd "$S5" && git log --no-merges --oneline | wc -l | tr -d ' ' )" \
     "· 署名数 = $( cd "$S5" && git log --no-merges --pretty=format:'%an' | sort -u | wc -l | tr -d ' ' )"

say "GUI 侧对表用的深夹具（给 Swift 用例复演，脚本这一档不判）"
echo "证据目录：$EVIDENCE"
ls -1 "$EVIDENCE"
