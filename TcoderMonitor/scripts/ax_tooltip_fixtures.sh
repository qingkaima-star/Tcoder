#!/bin/bash
# ⓘ 分支覆盖夹具（**报告器，不是闸门**）：把"只有走到那个数据态才会出现的 ⓘ"
# 一个个造出来，再让 `ax_tooltip_report.sh` 那套读数器去界面把它们捞回来。
#
# 为什么要它：`ax_tooltip_coverage.py` 第一次只报了 17/37 命中，剩下的"未命中"
# 全都说不上是缺陷 —— 那些 ⓘ 挂在空态 / 警告态 / 未采样态里，沙箱走不到就是量不到。
# 没有这个文件，那句"未命中 14 条"就永远是一句解释；有了它，覆盖率是可复跑的事实。
#
# 六类夹具，每类都对着一段源码条件（不是我猜的，条件写在 `make-report-fixture` 的注释里）：
#   内容类   可解析日志（成簇）／一个目录里两个仓库（放 $TMPDIR，跑完就删）／空仓库
#   报告类   删 logs、删 health、overall=88（与分量加权和 75.24 对不上）、历史两个末点
#   交互类   用 scripts/ax_press.swift 按「暂停」（SwiftUI 按钮的标签在 AXDescription 上）
#   时序类   首帧早拍（进程表未采到、曲线等首个采样点）
#   注册表类 AX_EMPTY_REGISTRY=1（P7-A 之后的首启空态）
#
# 用法: ./scripts/ax_tooltip_fixtures.sh            # 全跑，最后一行给覆盖率
#       KEEP_FIXTURES=1 ...                          # 留着夹具目录便于排查（默认删）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT=$(git rev-parse --show-toplevel)
SCRATCH="${TCODER_SCRATCH:-$ROOT/.scratch}"
BOX="$SCRATCH/tcoder-ax-tooltip"
UUID="11111111-2222-3333-4444-555555555555"
DUMP="$SCRATCH/ax_dump"
PRESS="$SCRATCH/ax_press"
BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"

die() { echo "!! $1"; exit 1; }
[ -x "$BIN" ] || die "缺 $BIN —— 先跑 scripts/build_app.sh release"

# 真报告与它的 projects.json 一起找（被扫路径必须是仓库根本身，否则"改一段报告"
# 会连被扫对象一起换掉，那批读数就不是同一件事了）。找不到就自己起一趟全量批次造。
SOURCE_REPORT=""
SOURCE_PROJECTS=""
for cand in "$BOX"/sandbox-full/reports/*.json "$BOX"/sandbox-*/reports/*.json; do
    [ -f "$cand" ] || continue
    sibling="$(dirname "$(dirname "$cand")")/projects.json"
    [ -f "$sibling" ] && grep -q ""$ROOT"" "$sibling" || continue
    SOURCE_REPORT="$cand"; SOURCE_PROJECTS="$sibling"; break
done
if [ -z "$SOURCE_REPORT" ]; then
    echo "== 没有现成的真报告，先起一趟全量批次造一份（写到批次 source，不动已有证据）"
    AX_SET=source ./scripts/ax_tooltip_report.sh 健康评分 > "$SCRATCH/ax-fixtures-source.log" 2>&1 \
        || die "造真报告这趟没跑成，看 $SCRATCH/ax-fixtures-source.log"
    SOURCE_REPORT="$BOX/sandbox-source/reports/$UUID.json"
    SOURCE_PROJECTS="$BOX/sandbox-source/projects.json"
    [ -f "$SOURCE_REPORT" ] || die "跑完了还是没有 $SOURCE_REPORT"
fi
echo "== 真报告取自 $SOURCE_REPORT"

for tool in ax_dump:scripts/ax_dump.swift ax_press:scripts/ax_press.swift; do
    name=${tool%%:*}; src=${tool#*:}
    if [ ! -x "$SCRATCH/$name" ] || [ "$src" -nt "$SCRATCH/$name" ]; then
        xcrun swiftc -O "$src" -o "$SCRATCH/$name" > "$SCRATCH/$name-compile.log" 2>&1 \
            || die "$name 编译失败，看 $SCRATCH/$name-compile.log"
    fi
done
DUMP="$SCRATCH/ax_dump"; PRESS="$SCRATCH/ax_press"

# 起实例 → 可选按几下 → 读无障碍树 → 只退自己起的、二进制路径核对一致的那个 pid
run_batch() {  # run_batch <批次> <页名> [要按的标题子串...]
    local set="$1" section="$2"; shift 2
    local sandbox="$BOX/sandbox-$set" out="$BOX/$set" pid code
    mkdir -p "$sandbox/reports" "$out"
    : > "$out/.batch"
    export TCODER_SUPPORT_DIR="$sandbox"
    "$BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$section" \
        > "$out/$section.instance.log" 2>&1 &
    pid=$!
    sleep 8
    local needle
    for needle in "$@"; do
        "$PRESS" "$pid" "$needle" || echo "   （「$needle」没按成，这一批到不了那个状态）"
        sleep 2
    done
    "$DUMP" "$pid" > "$out/$section.txt" 2>&1
    code=$?
    if [ $code -ne 0 ]; then
        echo "   !! $set 读数失败 exit=$code：$(tail -1 "$out/$section.txt")"
    else
        echo "   $set → $(tail -1 "$out/$section.txt")"
    fi
    if ps -p "$pid" > /dev/null 2>&1; then
        local who
        who=$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt" && /TcoderMonitor$/ {print $NF; exit}')
        [ "$who" = "$BIN" ] && kill -TERM "$pid" 2>/dev/null \
            || echo "   ⚠ pid $pid 的二进制是「$who」，不是 $BIN —— 不动手"
    fi
}

# 报告类夹具：改真报告的某一段，写进 <批次> 的沙箱（被扫路径仍 = 仓库根，projects.json 跟着真报告走）
report_variant() {  # report_variant <批次> <页名> <变体>
    local set="$1" section="$2" variant="$3" sandbox="$BOX/sandbox-$1"
    mkdir -p "$sandbox/reports"
    python3 - "$SOURCE_REPORT" "$sandbox" "$variant" "$UUID" <<'PY' || die "造 $variant 夹具失败"
import json, sys
source, sandbox, variant, uuid = sys.argv[1:5]
report = json.load(open(source))
if variant == "no-logs":
    report.pop("logs", None)                       # `report?.logs == nil` 那一档
elif variant == "no-health":
    report.pop("health", None)                     # 没有 verdict → HealthNotScoredCard
elif variant == "mismatch":
    report["health"]["overall"] = 88               # 分量加权和仍是 75.24 → 那条警告
elif variant == "no-input":
    # `HealthNoInputCard` 的门槛是"跑完了但一个维度都没算出来"：
    # 光把 overall 置空只会走到 `HealthNotScoredCard` 那一档（第一次就是这么猜错的）。
    report["health"]["overall"] = None
    report["health"]["components"] = []
elif variant == "history":
    report["health"]["overall"] = 75
else:
    sys.exit("不认识变体 " + variant)
json.dump(report, open(f"{sandbox}/reports/{uuid}.json", "w"), ensure_ascii=False, indent=2)
history = ([{"date": "2026-09-19T10:00:00Z", "projectName": "Tcoder", "score": 70},
            {"date": report["generatedAt"], "projectName": "Tcoder", "score": 61}]
           if variant == "history" else None)
path = f"{sandbox}/score-history.json"
if history:
    json.dump([uuid, history], open(path, "w"), ensure_ascii=False, indent=2)
elif __import__("os").path.exists(path):
    __import__("os").remove(path)
PY
    cp "$SOURCE_PROJECTS" "$sandbox/projects.json" || die "复制 $SOURCE_PROJECTS 失败"
    run_batch "$set" "$section"
}

# 内容类夹具：一个带可解析日志的小项目（错误成簇才会点亮「按出现次数排序」那枚 ⓘ）
build_logrepo() {
    local dir="$1"
    rm -rf "$dir"; mkdir -p "$dir/src"
    printf 'enum App { static let name = "fixture" }\n' > "$dir/src/App.swift"
    printf 'let x = 1\nprint(x)\n' > "$dir/src/main.swift"
    : > "$dir/error.log"
    local i
    for i in $(seq 1 12); do
        printf '2026-09-21 10:%02d:01 ERROR database connection refused (attempt %d)\n' "$i" "$i" >> "$dir/error.log"
    done
    for i in $(seq 1 5); do
        printf '2026-09-21 11:%02d:00 ERROR timeout while reading config file\n' "$i" >> "$dir/error.log"
    done
    for i in $(seq 1 30); do
        printf '2026-09-21 12:%02d:00 INFO heartbeat ok\n' "$i" >> "$dir/error.log"
    done
}

# 「一个目录里两个仓库」这条必须在**任何仓库之外**造：选中的目录若在一个仓库工作树里，
# git 会先向上定位到那个仓库（mode = parentDirectory），第 ③ 级向下扫根本走不到。
build_multirepo() {
    local dir="$1" repo
    rm -rf "$dir"; mkdir -p "$dir/alpha" "$dir/beta"
    for repo in alpha beta; do
        ( cd "$dir/$repo" && git init -q . && printf 'let x = 1\n' > f.swift && git add f.swift \
          && GIT_AUTHOR_NAME=夹具 GIT_AUTHOR_EMAIL=fixture@example.invalid \
             GIT_COMMITTER_NAME=夹具 GIT_COMMITTER_EMAIL=fixture@example.invalid \
             git -c commit.gpgsign=false commit -q -m "夹具提交 $repo" ) || return 1
    done
}

# 每一批都从零开始：上一轮手工试探留下的批次名也在这里一起清，
# 否则"套件跑出来的覆盖率"会偷偷依赖桌面上还留着哪些历史目录。
rm -rf "$BOX"/fixture-* "$BOX"/no-logs "$BOX"/no-health "$BOX"/no-input "$BOX"/mismatch \
       "$BOX"/history "$BOX"/paused "$BOX"/early "$BOX"/early-dash "$BOX"/logs \
       "$BOX"/multirepo "$BOX"/multirepo2 "$BOX"/multirepo3 "$BOX"/emptyrepo 2>/dev/null
rm -rf "$BOX"/sandbox-no-logs "$BOX"/sandbox-no-health "$BOX"/sandbox-no-input \
       "$BOX"/sandbox-mismatch "$BOX"/sandbox-history "$BOX"/sandbox-paused \
       "$BOX"/sandbox-early "$BOX"/sandbox-logs "$BOX"/sandbox-multirepo \
       "$BOX"/sandbox-multirepo2 "$BOX"/sandbox-multirepo3 "$BOX"/sandbox-emptyrepo 2>/dev/null

echo "== 报告类"
report_variant no-logs 错误日志 no-logs
report_variant no-health 健康评分 no-health
report_variant mismatch 健康评分 mismatch
report_variant no-input 健康评分 no-input
report_variant history 健康评分 history

echo "== 内容类"
build_logrepo "$BOX/fixture-logrepo" || die "日志夹具没造出来"
python3 - "$BOX/sandbox-logs" "$BOX/fixture-logrepo" "$UUID" <<'PY' || die "写日志夹具的 projects.json 失败"
import json, sys, datetime
sandbox, path, uuid = sys.argv[1:4]
import os; os.makedirs(f"{sandbox}/reports", exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": "日志夹具", "path": path,
                         "addedAt": now, "isDemo": False}], "selectedProjectID": uuid},
          open(f"{sandbox}/projects.json", "w"), indent=2)
PY
run_batch logs 错误日志

mkdir -p "$BOX/sandbox-emptyrepo/reports"
python3 - "$BOX/sandbox-emptyrepo" "$BOX/fixture-emptyrepo" "$UUID" <<'PY' || die "写空仓库夹具失败"
import json, os, sys, datetime, subprocess
sandbox, path, uuid = sys.argv[1:4]
os.makedirs(f"{path}", exist_ok=True)
subprocess.run(["git", "init", "-q", "."], cwd=path, check=False)
os.makedirs(f"{sandbox}/reports", exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": "空仓库夹具", "path": path,
                         "addedAt": now, "isDemo": False}], "selectedProjectID": uuid},
          open(f"{sandbox}/projects.json", "w"), indent=2)
PY
run_batch emptyrepo "Git 洞察"

MULTI=$(mktemp -d "${TMPDIR:-/tmp}/tcoder-multirepo-fixture.XXXXXX")
if build_multirepo "$MULTI"; then
    python3 - "$BOX/sandbox-multirepo" "$MULTI" "$UUID" <<'PY' || die "写多仓夹具失败"
import json, os, sys, datetime
sandbox, path, uuid = sys.argv[1:4]
os.makedirs(f"{sandbox}/reports", exist_ok=True)
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": "多仓夹具", "path": path,
                         "addedAt": now, "isDemo": False}], "selectedProjectID": uuid},
          open(f"{sandbox}/projects.json", "w"), indent=2)
PY
    run_batch multirepo "Git 洞察"
else
    echo "   !! 多仓夹具没造出来 —— 跳过（「只分析了提交数最多的那一个」这一枚 ⓘ 就量不到）"
fi
[ "${KEEP_FIXTURES:-0}" = "1" ] && echo "   留着夹具目录：$MULTI" || rm -rf "$MULTI" "$BOX/fixture-logrepo" "$BOX/fixture-emptyrepo"

echo "== 交互类（按「暂停」）"
mkdir -p "$BOX/sandbox-paused/reports"
cp "$SOURCE_PROJECTS" "$BOX/sandbox-paused/projects.json" || die "复制 $SOURCE_PROJECTS 失败"
cp "$SOURCE_REPORT" "$BOX/sandbox-paused/reports/$UUID.json"
run_batch paused 性能监控 暂停

echo "== 时序类（首帧早拍：进程表未采到、曲线等首个采样点）"
# 这两句各挂在两页上：进程表在「性能监控」、曲线在「总览」。
# 上一版只拍了总览，于是把「未采到」那条从覆盖里掉了出去 —— 早拍要覆盖的是**那一页**，不是随便一页。
mkdir -p "$BOX/sandbox-early/reports"
cp "$SOURCE_PROJECTS" "$BOX/sandbox-early/projects.json" 2>/dev/null || true
mkdir -p "$BOX/early"
for page in 总览 性能监控; do
  for delay in 0.5 1.0; do
    export TCODER_SUPPORT_DIR="$BOX/sandbox-early"
    "$BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$page" >/dev/null 2>&1 &
    pid=$!
    sleep "$delay"
    "$DUMP" "$pid" > "$BOX/early/$page--$delay.txt" 2>&1 || true
    who=$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt" && /TcoderMonitor$/ {print $NF; exit}')
    [ "$who" = "$BIN" ] && kill -TERM "$pid" 2>/dev/null
    echo "   早拍 $page $delay s → $(tail -1 "$BOX/early/$page--$delay.txt")"
  done
done

echo "== 覆盖率"
# 不传参数：让它走自己的默认发现（会排掉 `sandbox-*` 那批 App 支持目录）。
# 上一版把 "$BOX"/* 显式传进去，绕过了那道过滤，于是"批次数"从 14 被报成 27。
./scripts/ax_tooltip_coverage.py 2>/dev/null | head -6
