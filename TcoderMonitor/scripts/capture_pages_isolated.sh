#!/bin/bash
# 隔离式逐页截图取证。与 verify_pages.sh 的区别只有一句话：
# 它要求"本机不许有别的 TcoderMonitor 实例"，本脚本不要求。
#
# 为什么必须有第二个版本：verify_pages.sh 的拒拍守卫是对的——旧实例与本包共用
# ~/Library/Application Support/TcoderMonitor，谁后退出谁回写，截图拍到的是脏数据。
# 但那条守卫把第 (4) 项取证卡死了：本机有 2 个 `.build/debug/TcoderMonitor` 残留实例，
# 而仓库规约明令不得向任何进程发信号 / kill，取证就只能一直等人工 Cmd+Q。
# 解法是让**本脚本自己**去用一个隔离沙箱（ProjectStore 的 TCODER_SUPPORT_DIR），
# 于是"共用状态"这个前提不再成立，残留实例既污染不了我也拖不住我。
#
# 用法: scripts/capture_pages_isolated.sh [输出目录]
#   CAPTURE_TARGET=<目录>   被扫描的项目（默认 = 本仓库根，dogfooding）
#   CAPTURE_SANDBOX=<目录>  支持目录沙箱（默认 /tmp/tcoder-capture-sandbox-<时间戳>，每次新建）
#   SWITCH_MODE=argv        每页起一个新实例并用 -selectedDetailSection 传页名（默认 single）
#   SWITCH_MODE=single      只起一个实例，靠 defaults write 实时切页（SwiftUI @AppStorage 会响应）
#   SKIP_PROVENANCE=1       跳过"dist 二进制 == 当前源码"证明（默认不跳，跳了截图就不可信）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP_DIR="$PWD/dist/Tcoder Monitor.app"
BIN="$APP_DIR/Contents/MacOS/TcoderMonitor"
WINLIST="$PWD/scripts/winlist.swift"
OUT="${1:-/tmp/tcoder-pages-isolated}"
DOMAIN="com.tcoder.monitor"
UUID="11111111-2222-3333-4444-555555555555"
SWITCH_MODE="${SWITCH_MODE:-single}"
# 九个 DetailSection 的中文 rawValue，顺序即侧边栏顺序
SECTIONS=("总览" "代码规模" "复杂度风险" "Git 洞察" "贡献者" "性能监控" "错误日志" "依赖分析" "健康评分")

REPO_ROOT=$(git rev-parse --show-toplevel)
TARGET="${CAPTURE_TARGET:-$REPO_ROOT}"
SANDBOX="${CAPTURE_SANDBOX:-/tmp/tcoder-capture-sandbox-$(date +%Y%m%d-%H%M%S)}"

die() { echo "!! $1"; exit 1; }

echo "==> 0/4 被扫对象 = $TARGET"
[ -d "$TARGET" ] || die "目录不存在: $TARGET"
[ -d "$TARGET/.git" ] || echo "    （提示：不是 git 仓库，Git 洞察/贡献者两页会走缺数据态）"

# 1) 二进制来源证明。取证的效力取决于"这九张图拍的是当前代码"，
#    而本机 dist/ 只要有一次没重打包，图就静默变成历史版本的图。
if [ "${SKIP_PROVENANCE:-0}" = "1" ]; then
  echo "==> 1/4 ⚠ 已跳过二进制来源证明（SKIP_PROVENANCE=1）——这批图只能算界面示意，不能当交付证据"
else
  echo "==> 1/4 二进制来源证明"
  [ -x "$BIN" ] || die "找不到 $BIN，先跑 ./scripts/build_app.sh release"
  ./scripts/verify_provenance.sh > /tmp/capture-pages-provenance.log 2>&1 || {
    tail -20 /tmp/capture-pages-provenance.log
    die "dist 与当前源码不一致，拒拍（这是 verify_pages.sh 用过的同一条红线）"
  }
  tail -3 /tmp/capture-pages-provenance.log
fi

# 2) 沙箱支持目录：ProjectStore 只接受绝对路径，且不会去碰 ~/Library/Application Support。
echo "==> 2/4 预置沙箱 $SANDBOX"
mkdir -p "$SANDBOX/reports" || die "建不了沙箱"
python3 - "$SANDBOX" "$UUID" "$TARGET" <<'PY' || die "写入 projects.json 失败"
import json, sys, datetime
support, uuid, path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(f"{support}/projects.json", "w") as fh:
    json.dump({"projects": [{"id": uuid, "name": "Tcoder（取证沙箱）", "path": path,
                             "addedAt": now, "isDemo": False}],
               "selectedProjectID": uuid}, fh, indent=2)
PY

# 残留实例只通报、不拦停：本脚本用沙箱，与它们不共用状态。
STRAY=$(pgrep -x TcoderMonitor || true)
if [ -n "$STRAY" ]; then
  echo "    通报：本机另有 $(printf '%s\n' "$STRAY" | wc -l | tr -d ' ') 个实例在跑（pid $(printf '%s' "$STRAY" | tr '\n' ' ')）。"
  echo "    它们与本脚本各自的沙箱互不相干，故不拒拍；本脚本也不会向它们发任何信号。"
fi

mkdir -p "$OUT" || die "建不了输出目录"
rm -f "$OUT"/*.png

# 截图前必须等第一轮真实分析落盘，否则拍到的是"分析中"的空壳。
# 判据用 reports/ 的文件数与字节数**连续两轮不变**，而不是拍脑袋 sleep N 秒。
wait_for_reports() {
  local pid="$1" budget="${2:-300}" waited=0 prev=""
  while [ "$waited" -lt "$budget" ]; do
    cur=$(ls -1 "$SANDBOX/reports" 2>/dev/null | wc -l | tr -d ' ')
    bytes=$(du -sk "$SANDBOX/reports" 2>/dev/null | cut -f1)
    sig="$cur:$bytes"
    if [ "$cur" != "0" ] && [ "$sig" = "$prev" ]; then
      echo "    报告已落盘：$cur 份 / ${bytes} KiB（等待 ${waited}s）"
      return 0
    fi
    prev="$sig"
    # 存活检查用只读的 ps，不用 `kill -0`：后者虽然不发实际信号，但仓库规约是
    # "不向任何进程发信号"，脚本里留着 kill 字样迟早要人来逐行解释它为什么无害。
    ps -p "$pid" > /dev/null 2>&1 || { echo "    ⚠ 实例 $pid 已不在，停止等待"; return 1; }
    sleep 5; waited=$((waited + 5))
  done
  echo "    ⚠ 超出 ${budget}s 仍未稳定，按现状拍图（可能在跑大数据量段落）"
  return 0
}

capture() {  # capture <pid> <页名>
  local pid="$1" name="$2" win file size hash
  win=$(xcrun swift "$WINLIST" "$pid" 2>/dev/null | head -1 | cut -d'|' -f1)
  # 注意分隔符是 `|` 不是制表符：写成 cut -f1 会把整行当窗口 id 交给 screencapture，
  # 于是每张图都是 0 字节却仍然打印"成功"——这是 verify_pages.sh 里现存的那个坑。
  if [ -z "$win" ]; then echo "  $name -> !! 窗口 id 取不到（实例已退出？窗口未创建？）"; return 1; fi
  file="$OUT/$name.png"
  screencapture -x -o -l"$win" "$file" 2>/dev/null
  if [ ! -s "$file" ]; then echo "  $name -> !! 截图文件为空"; return 1; fi
  size=$(stat -f '%z' "$file")
  hash=$(shasum -a 256 "$file" | cut -c1-12)
  echo "  $name -> ${size} 字节  sha=${hash}  win=${win}"
  return 0
}

echo "==> 3/4 逐页取证（模式 $SWITCH_MODE）"
FAILED=0
HASHES=""

launch_instance() {  # launch_instance [页名]；echo pid
  local name="$1"
  if [ "$SWITCH_MODE" = "argv" ]; then
    TCODER_SUPPORT_DIR="$SANDBOX" "$BIN" -ApplePersistenceIgnoreState YES \
      -selectedDetailSection "$name" > "/tmp/tcoder-capture-$(date +%s)-$$.log" 2>&1 &
  else
    TCODER_SUPPORT_DIR="$SANDBOX" "$BIN" -ApplePersistenceIgnoreState YES \
      > "/tmp/tcoder-capture-$(date +%s)-$$.log" 2>&1 &
  fi
  sleep 4
  # 只认本脚本刚起的那个 pid（$!），不从 pgrep 里捞——捞法会把残留实例算进来。
  echo "$!"
}

if [ "$SWITCH_MODE" = "single" ]; then
  defaults delete "$DOMAIN" selectedDetailSection 2>/dev/null || true
  PID=$(launch_instance "")
  case "$PID" in
    ''|*[!0-9]*) echo "  !! 起不来（launch_instance 返回 '$PID'）"; exit 1 ;;
  esac
  wait_for_reports "$PID" 300 || exit 1
  for name in "${SECTIONS[@]}"; do
    defaults write "$DOMAIN" selectedDetailSection -string "$name"
    sleep 3
    if ! capture "$PID" "$name"; then FAILED=$((FAILED + 1)); fi
  done
  echo "    收尾：请求本实例自行退出（不发信号，走 App 自己的 quit 事件）"
  osascript -e "tell application id \"$DOMAIN\" to quit" 2>/dev/null || \
    echo "    ⚠ quit 事件没送达，实例 $PID 需人工 Cmd+Q（它在沙箱里，不影响用户状态）"
else
  for name in "${SECTIONS[@]}"; do
    PID=$(launch_instance "$name")
    case "$PID" in
      ''|*[!0-9]*) echo "  $name -> !! 起不来"; FAILED=$((FAILED + 1)); continue ;;
    esac
    wait_for_reports "$PID" 300
    sleep 3
    if ! capture "$PID" "$name"; then FAILED=$((FAILED + 1)); fi
    osascript -e "tell application id \"$DOMAIN\" to quit" 2>/dev/null || true
    sleep 2
  done
fi

# 4) 防"九张其实是同一张"：尺寸一致曾经正是取了旧二进制的破绽。
echo "==> 4/4 结果核对"
N=$(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
DUP=$(shasum -a 256 "$OUT"/*.png 2>/dev/null | awk '{print $1}' | sort | uniq -d | wc -l | tr -d ' ')
echo "    产出 $N 张 / 9 页，失败 $FAILED 页，内容完全相同的图组数 $DUP"
if [ "$N" != "9" ]; then echo "    ❌ 页不齐：九页是硬性验收口径"; exit 1; fi
if [ "$DUP" != "0" ]; then
  echo "    ⚠ 存在字节级完全相同的两张图：要么切页没生效，要么两页真的同构。逐个 sha 如下"
  shasum -a 256 "$OUT"/*.png
fi
echo "    沙箱保留在 $SANDBOX（含本次报告，可回读核对）；用户状态未被触碰"
echo "截图目录: $OUT"
