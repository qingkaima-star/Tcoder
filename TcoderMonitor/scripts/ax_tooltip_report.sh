#!/bin/bash
# ⓘ 长口径活界面取证（**报告器，不是闸门**）：起 dist 里的真 App 实例 → 等第一轮分析落盘
# → 从进程外数「界面上真的挂着 help 文案的元素有几个、是哪几句」。
#
# 为什么需要它、以及三条已经踩死的弯路，都写在 scripts/ax_dump.swift 头部（合成鼠标 /
# 进程内 NSView.toolTip / 进程内 accessibilityChildren 三种读法为什么都不成立）。
#
# 顶/尾两趟是**互补的两张**：与画面取证 §6.2 同一口径 —— 一轮实测 9 页里 7 页
# top 与 bottom 的元素数一样（SwiftUI 非懒加载的卡全都已在树里），
# 但「总览」134→176、「性能监控」232→234 会变，所以两趟都要。
#
# 用法: scripts/ax_tooltip_report.sh [页名...]
#   AX_TARGET=<目录>    被扫描的项目（默认 = 仓库根，dogfooding）。
#                       想拍「空态那几张卡的 ⓘ」，指一个空目录再跑一趟。
#   AX_SET=<名字>       同一轮取证的子目录名（默认 `full`；空态那趟用 `empty`），
#                       免得两批读数互相覆盖。
#   AX_EMPTY_REGISTRY=1 注册表置空，拍**首启空态**那一档的 ⓘ（那一档不产报告，故不等分析）
#   AX_LANG=en              以英文态读数（只给本脚本起的实例加 `-AppleLanguages`，不动系统语言）
#                           —— 用来量"英文界面上还挂着多少中文 tooltip"这一类双语残留
#   WAIT_BUDGET=<秒>    等第一轮分析落盘的预算（默认 420）
# 产物: $SCRATCH/tcoder-ax-tooltip/<AX_SET>/<页>--<top|bottom>.txt
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

# AGENTS §1.6：一次性产物落仓库内 .scratch，不进 $TMPDIR。
SCRATCH="${TCODER_SCRATCH:-$(git rev-parse --show-toplevel)/.scratch}"
mkdir -p "$SCRATCH" 2>/dev/null || SCRATCH="${TMPDIR:-/tmp}"

BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
# AX_TOOL / AX_COUNT_PATTERN 是**默认不变**的两个口子（2026-09-22 由 WS-CL 加）：
# 换一把读数器（如 `ax_body_text`：同一趟既出 HELP 又出正文 TEXT）时，
# 不必复制这 100 行起停逻辑 —— 复制一份起停就是"同一职责的第二份实现"，必然漂。
AX_TOOL="${AX_TOOL:-ax_dump}"
AX_COUNT_PATTERN="${AX_COUNT_PATTERN:-^HELP}"
AXBIN="$SCRATCH/$AX_TOOL"
AXSRC="$PWD/scripts/$AX_TOOL.swift"
AX_SET="${AX_SET:-full}"
OUT="$SCRATCH/tcoder-ax-tooltip/$AX_SET"
SANDBOX="$SCRATCH/tcoder-ax-tooltip/sandbox-$AX_SET"
TARGET="${AX_TARGET:-$(git rev-parse --show-toplevel)}"
LANG_ARGS=()
if [ "${AX_LANG:-}" = "en" ]; then LANG_ARGS+=(-AppleLanguages "(en)"); fi
UUID="11111111-2222-3333-4444-555555555555"
WAIT_BUDGET="${WAIT_BUDGET:-420}"
LAST_COUNT=-1

[ -x "$BIN" ] || { echo "!! 找不到 $BIN，先跑 scripts/build_app.sh release"; exit 1; }
[ -f "$AXSRC" ] || { echo "!! 找不到 $AXSRC"; exit 1; }
if [ ! -x "$AXBIN" ] || [ "$AXSRC" -nt "$AXBIN" ]; then
  xcrun swiftc -O "$AXSRC" -o "$AXBIN" || { echo "!! ax_dump 编译失败"; exit 1; }
fi

# 盘上规矩（2026-09-21 需求方定的）：重活之前先看可用空间，不足 20 GiB 就停、上报、不硬跑。
AVAIL=$(df -k /System/Volumes/Data | awk 'NR==2{print int($4/1024/1024)}')
if [ "${AVAIL:-0}" -lt 20 ]; then echo "!! 可用 ${AVAIL} GiB < 20 GiB，本取证拒绝开跑"; exit 1; fi
echo "== 可用 ${AVAIL} GiB；被扫对象 = $TARGET；批次 $AX_SET"

if [ $# -gt 0 ]; then SECTIONS=("$@"); else
  SECTIONS=("总览" "代码规模" "复杂度风险" "Git 洞察" "贡献者" "性能监控" "错误日志" "依赖分析" "健康评分")
fi

mkdir -p "$SANDBOX/reports" "$OUT" || exit 1
rm -f "$OUT"/*.txt
if [ "${AX_EMPTY_REGISTRY:-0}" = "1" ]; then
  # 首启空态那一档：注册表里一个项目都没有。P7-A 之后这是产品第一条路，
  # 而它那些 ⓘ（「九页读数全部由它真实算出来」「完成一次采样后会列出占用最高的进程」…）
  # 在任何"有项目"的沙箱里都上不了屏 —— 不单独造这一档，就等于没测过。
  echo "== 注册表置空（AX_EMPTY_REGISTRY=1）：这一批拍的是首启空态那一档"
  python3 - "$SANDBOX" <<'PY' || { echo "!! 写空 projects.json 失败"; exit 1; }
import json, sys
support = sys.argv[1]
with open(f"{support}/projects.json", "w") as fh:
    json.dump({"projects": [], "selectedProjectID": None}, fh, indent=2)
PY
else
python3 - "$SANDBOX" "$UUID" "$TARGET" <<'PY' || { echo "!! 写 projects.json 失败"; exit 1; }
import json, sys, datetime
support, uuid, path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(f"{support}/projects.json", "w") as fh:
    json.dump({"projects": [{"id": uuid, "name": "Tcoder（ⓘ 取证沙箱）", "path": path,
                             "addedAt": now, "isDemo": False}],
               "selectedProjectID": uuid}, fh, indent=2)
PY
fi

source "$(dirname "$0")/wait_for_reports.sh"  # 等分析落盘的那条判据搬进共用文件了：截断尺子当年只写了一句 sleep 20，换大仓就会在界面还空着时读树

retire_own_instance() {  # 只退本脚本自己起的、且二进制路径核对一致的那一个 pid
  local pid="$1" who
  ps -p "$pid" > /dev/null 2>&1 || return 0
  who=$(lsof -p "$pid" 2>/dev/null | awk '$4=="txt" && /TcoderMonitor$/ {print $NF; exit}')
  if [ "$who" = "$BIN" ]; then
    kill -TERM "$pid" 2>/dev/null || true
  else
    echo "   ⚠ pid $pid 的二进制核对成「$who」，不是 $BIN —— 不动手，请人工退出"
  fi
}

dump_one() {  # dump_one <页名> <top|bottom> ；条数写进全局 LAST_COUNT（-1 = 这趟没读到）
  local name="$1" scroll="$2" file="$OUT/$name--$scroll.txt" pid code
  LAST_COUNT=-1
  env TCODER_SUPPORT_DIR="$SANDBOX" TCODER_CAPTURE_SCROLL="$scroll" "$BIN" \
      -ApplePersistenceIgnoreState YES "${LANG_ARGS[@]+"${LANG_ARGS[@]}"}" -selectedDetailSection "$name" \
      > "$OUT/$name--$scroll.instance.log" 2>&1 &
  pid=$!
  sleep 6
  # 空注册表那一档没有"第一轮分析"可等（也不该等满预算），界面是立刻画出来的。
  if [ "${AX_EMPTY_REGISTRY:-0}" = "1" ]; then
    sleep 4
  elif ! wait_for_reports "$pid"; then
    echo "   !! $name/$scroll 没等到数据 —— 读数作废，不算通过"
    retire_own_instance "$pid"
    return 0
  fi
  sleep 3   # 再给界面一次渲染完的时间
  "$AXBIN" "$pid" > "$file" 2>&1
  code=$?
  if [ $code -ne 0 ]; then
    echo "   !! $name/$scroll 读数失败 exit=$code：$(tail -2 "$file" | tr '\n' ' ')"
  else
    LAST_COUNT=$(grep -c "$AX_COUNT_PATTERN" "$file" || true)
    echo "   $name/$scroll → $(tail -1 "$file")"
    [ "$LAST_COUNT" -gt 0 ] || echo "   ⚠ $name/$scroll 一个 help 都没有（visited 非 0 时这才是产品问题）"
  fi
  retire_own_instance "$pid"
}

TOTAL=0
FAILED=0
for name in "${SECTIONS[@]}"; do
  echo "== 页「$name」"
  for scroll in top bottom; do
    TOTAL=$((TOTAL + 1))
    dump_one "$name" "$scroll"
    [ "$LAST_COUNT" -gt 0 ] || FAILED=$((FAILED + 1))
  done
done

echo "== 完成：$TOTAL 趟，读数失败或空 $FAILED 趟 → $OUT"
exit $FAILED
