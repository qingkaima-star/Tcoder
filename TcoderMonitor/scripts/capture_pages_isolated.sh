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
#   CAPTURE_SANDBOX=<目录>  支持目录沙箱（默认包根 .scratch/…，见 AGENTS §1.6；
#                             只有 CAPTURE_LOCK 仍留 /tmp —— 那把锁是**跨工作树**的，
#                             落到仓库里就变成每棵树各一把，等于没有锁）
#   SWITCH_MODE=argv        每页起一个新实例并用 -selectedDetailSection 传页名（默认 single）
#   SWITCH_MODE=single      只起一个实例，靠 defaults write 实时切页（SwiftUI @AppStorage 会响应）
#   SKIP_PROVENANCE=1       跳过"dist 二进制 == 当前源码"证明（默认不跳，跳了截图就不可信）
#   CAPTURE_TERM=1          收尾对**本脚本自己起的、二进制路径核对一致的**那一个 pid 发 SIGTERM；
#   CAPTURE_LANG=en         以英文取证（只给本脚本起的实例加 -AppleLanguages，不动系统语言）
#                           默认只通报 pid 等人工 Cmd+Q。绝不按 bundle id 广播 quit（那会全机生效）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

APP_DIR="$PWD/dist/Tcoder.app"
BIN="$APP_DIR/Contents/MacOS/TcoderMonitor"
WINLIST="$PWD/scripts/winlist.swift"
OUT="${1:-$PWD/.scratch/tcoder-pages-isolated}"
DOMAIN="com.tcoder.monitor"
UUID="11111111-2222-3333-4444-555555555555"
SWITCH_MODE="${SWITCH_MODE:-single}"
# 九个 DetailSection 的中文 rawValue，顺序即侧边栏顺序
# 页名可以用 `CAPTURE_PAGES` 缩小（冒号分隔 —— 页名里有空格，不能按空白切）。
# 为什么开这个口子：只改了一页的内容时，"重拍整批 36 张"会掩盖"这一页到底对不对"，
# 而补拍那一页 4 张（深浅 × 顶尾）才是针对变了的那个变量。默认仍是九页全拍。
IFS=':' read -r -a SECTIONS <<< "${CAPTURE_PAGES:-总览:代码规模:复杂度风险:Git 洞察:贡献者:性能监控:错误日志:依赖分析:健康评分}"

REPO_ROOT=$(git rev-parse --show-toplevel)
TARGET="${CAPTURE_TARGET:-$REPO_ROOT}"
SANDBOX="${CAPTURE_SANDBOX:-$PWD/.scratch/tcoder-capture-sandbox-$(date +%Y%m%d-%H%M%S)}"

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

# ── 拍图互斥锁（2026-09-20 由双总工裁定加入）──────────────────────────────
# 加入时的直接理由是"收尾那句 `osascript tell application id … to quit` 按 bundle id
# **全机生效**，一家收尾会把另两家正在拍的实例一起退掉"。**那条 quit 已在下面被移除**
# （见 `retire_instance`），但锁仍然保留，因为还剩两条真的互斥：
#   ① 深色/浅色是靠 `osascript … set dark mode` 翻**全机外观**翻出来的，一家翻另一家就白拍；
#   ② 截图取的是屏幕上的真实窗口，两家同屏会互相遮挡。
# 不用 kill/pkill 广播：仓库规约是不向任何进程发信号；要退出也只退**自己起的**那一个。
# 用 `mkdir` 取锁，因为它是原子操作，且不依赖任何额外工具。
CAPTURE_LOCK="${CAPTURE_LOCK:-/tmp/tcoder-capture.lock}"
CAPTURE_LOCK_TIMEOUT="${CAPTURE_LOCK_TIMEOUT:-900}"
_lock_waited=0
while ! mkdir "$CAPTURE_LOCK" 2>/dev/null; do
  if [ "$_lock_waited" -ge "$CAPTURE_LOCK_TIMEOUT" ]; then
    echo "!! 等拍图锁超时 ${CAPTURE_LOCK_TIMEOUT}s（持有者见 $CAPTURE_LOCK/holder）"
    cat "$CAPTURE_LOCK/holder" 2>/dev/null | sed 's/^/     /'
    die "取证没跑成，不是脚本坏了：另一条流正占着拍图"
  fi
  [ "$_lock_waited" -eq 0 ] && echo "==> 拍图锁被占（另一条流正在取证，按 bundle id 的 quit 会全机生效），排队中…"
  sleep 5; _lock_waited=$((_lock_waited + 5))
done
printf 'holder=%s\npid=%s\nout=%s\nsince=%s\n' \
  "${TCODER_STREAM_NAME:-$(basename "$(pwd)")}" "$$" "$OUT" "$(date +%H:%M:%S)" > "$CAPTURE_LOCK/holder"
# 无论正常结束、die 还是被中断，都要放锁，否则下一次要等满超时
trap 'rm -rf "$CAPTURE_LOCK" 2>/dev/null || true' EXIT INT TERM
echo "    已取拍图锁 $CAPTURE_LOCK（$(cat "$CAPTURE_LOCK/holder" | tr '\n' ' ')）"

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

# `CAPTURE_LANG=en` 强制以英文取证（双语 P5 的定宽复量要用）。
# 默认不设 = 跟随系统语言，与历史上所有中文取证**完全同一条命令行**。
LANG_ARGS=()
if [ -n "${CAPTURE_LANG:-}" ]; then
  LANG_ARGS=(-AppleLanguages "($CAPTURE_LANG)")
  echo "    取证语言 = $CAPTURE_LANG（系统语言未改动；只影响本脚本起的实例）"
fi

# `CAPTURE_WINDOW_HEIGHT=1000`（本机屏高 1080pt）把取证窗口开高，
# 于是长页折叠线以下的图表/表格也进证据。不设 = 产品默认 1280×820，
# 与历史上所有取证的命令行**完全一致**。App 侧的读取点与夹取规则见
# `CaptureWindow`（越界一律退回默认，避免拍出一张"看起来通过"的废图）。
SIZE_ENV=()
if [ -n "${CAPTURE_WINDOW_HEIGHT:-}" ]; then
  SIZE_ENV+=(TCODER_CAPTURE_WINDOW_HEIGHT="$CAPTURE_WINDOW_HEIGHT")
  echo "    取证窗口高 = $CAPTURE_WINDOW_HEIGHT pt（产品默认 820；本机屏高 1080）"
fi
if [ -n "${CAPTURE_WINDOW_WIDTH:-}" ]; then
  SIZE_ENV+=(TCODER_CAPTURE_WINDOW_WIDTH="$CAPTURE_WINDOW_WIDTH")
fi
# `CAPTURE_SCROLL=bottom` 让页骨架滚到底再拍 —— 窗口高度被 AppKit 钳在屏幕可见高
# （实测请求 1600pt 只拿到 1050pt），所以最长几页的尾部只能靠滚动进证据。
# 与顶部那一趟是**互补的两张**，不是一张全图。
if [ -n "${CAPTURE_SCROLL:-}" ]; then
  SIZE_ENV+=(TCODER_CAPTURE_SCROLL="$CAPTURE_SCROLL")
  echo "    取证滚动 = $CAPTURE_SCROLL（拍页尾；顶部那一趟另拍）"
fi

launch_instance() {  # launch_instance [页名]；echo pid
  local name="$1"
  if [ "$SWITCH_MODE" = "argv" ]; then
    env "${SIZE_ENV[@]+"${SIZE_ENV[@]}"}" TCODER_SUPPORT_DIR="$SANDBOX" "$BIN" -ApplePersistenceIgnoreState YES "${LANG_ARGS[@]+"${LANG_ARGS[@]}"}" \
      -selectedDetailSection "$name" > "/tmp/tcoder-capture-$(date +%s)-$$.log" 2>&1 &
  else
    env "${SIZE_ENV[@]+"${SIZE_ENV[@]}"}" TCODER_SUPPORT_DIR="$SANDBOX" "$BIN" -ApplePersistenceIgnoreState YES "${LANG_ARGS[@]+"${LANG_ARGS[@]}"}" \
      > "/tmp/tcoder-capture-$(date +%s)-$$.log" 2>&1 &
  fi
  sleep 4
  # 只认本脚本刚起的那个 pid（$!），不从 pgrep 里捞——捞法会把残留实例算进来。
  echo "$!"
}

# 退出实例：**绝不按 bundle id 广播 quit**（那句会命中全机所有实例，包括别的流正在拍的、
# 以及正在做帧测量的那一个——2026-09-20 三家互杀到九页拍成 0 张就是这么来的）。
# 默认只通报 pid 请人工 Cmd+Q；`CAPTURE_TERM=1` 才发信号，且**只发给本脚本自己起的、
# 并且二进制路径核对一致的那一个 pid**（核对失败就只通报，不动手）。
retire_instance() {  # retire_instance <pid> <页名>
  local pid="$1" name="${2:-}" who
  case "$pid" in ''|*[!0-9]*) return 0 ;; esac
  ps -p "$pid" > /dev/null 2>&1 || return 0     # 已经不在了，什么都不做
  who=$(ps -p "$pid" -o comm= 2>/dev/null | tr -d ' ')
  if [ "${CAPTURE_TERM:-0}" = "1" ] && [ "$who" = "$BIN" ]; then
    kill -TERM "$pid" 2>/dev/null || true
    echo "    已对自己起的 pid $pid（$name）发 SIGTERM"
  else
    [ "${CAPTURE_TERM:-0}" = "1" ] && [ "$who" != "$BIN" ] \
      && echo "    ⚠ pid $pid 的二进制是「$who」不是 $BIN —— 不是本脚本起的，拒绝发信号"
    echo "    待人工退出：pid $pid（$name）在 $SANDBOX 沙箱里，不影响用户状态"
  fi
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
  echo "    收尾：只处理本脚本起的那一个 pid（不再按 bundle id 广播 quit）"
  retire_instance "$PID" "九页共用实例"
else
  for name in "${SECTIONS[@]}"; do
    PID=$(launch_instance "$name")
    case "$PID" in
      ''|*[!0-9]*) echo "  $name -> !! 起不来"; FAILED=$((FAILED + 1)); continue ;;
    esac
    wait_for_reports "$PID" 300
    sleep 3
    if ! capture "$PID" "$name"; then FAILED=$((FAILED + 1)); fi
    retire_instance "$PID" "$name"
    sleep 2
  done
fi

# 4) 防"九张其实是同一张"：尺寸一致曾经正是取了旧二进制的破绽。
echo "==> 4/4 结果核对"
N=$(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
DUP=$(shasum -a 256 "$OUT"/*.png 2>/dev/null | awk '{print $1}' | sort | uniq -d | wc -l | tr -d ' ')
EXPECTED_PAGES=${#SECTIONS[@]}
# 分母取"本轮实际要拍的那几页"，不是写死 9：`CAPTURE_PAGES` 缩小范围时写死 9 会让
# 补拍永远判败（于是有人去 SKIP，判据就废了）。但**空总体必须判败** ——
# 0 页配 0 张在旧写法里是"N != 9 → 败"，在新写法里就成了通过，所以显式堵住。
if [ "$EXPECTED_PAGES" -eq 0 ]; then echo "    ❌ 要拍的页数为 0，本取证不出数"; exit 1; fi
echo "    产出 $N 张 / $EXPECTED_PAGES 页，失败 $FAILED 页，内容完全相同的图组数 $DUP"
if [ "$N" != "$EXPECTED_PAGES" ]; then echo "    ❌ 页不齐：本轮口径是 $EXPECTED_PAGES 页"; exit 1; fi
if [ "$DUP" != "0" ]; then
  echo "    ⚠ 存在字节级完全相同的两张图：要么切页没生效，要么两页真的同构。逐个 sha 如下"
  shasum -a 256 "$OUT"/*.png
fi
echo "    沙箱保留在 $SANDBOX（含本次报告，可回读核对）；用户状态未被触碰"
echo "截图目录: $OUT"
