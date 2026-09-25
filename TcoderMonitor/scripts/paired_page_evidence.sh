#!/bin/bash
# 配对取证驱动：**深浅 × 顶尾** 四趟 × 九页 = 36 张，并且**逐张判这一张到底是不是那个性态**。
#
# 为什么要有这个驱动（而不是每人现写一遍循环）：
# 交付口径里那句"深浅两态九页全部实拍复核通过"，前几轮是靠一次性 bash 循环拍的 ——
# 命令没进仓，别人（和三个月后的我）无法复跑，也无法证明当时真按四趟拍的。
# 更糟的是这两种事故都不体现在张数上：
#   ① 深浅是翻**全机外观**翻出来的，而拍图锁不保护外观：另一条流一翻，
#      "深色那趟"会整批拍成浅色，36 张一张不少；
#   ② 窗口 id 取错时 `screencapture` 照样落盘 —— 空图也算一张。
# 所以每一趟拍完立刻用 `scripts/page_brightness.swift` 逐张判极性，
# **读不到、无像素、落在两可区间一律判败**，四趟全过才写"通过"。
#
# 用法: scripts/paired_page_evidence.sh [批次名]
#   产物: .scratch/evidence-<rev>-<批次名>/{light,dark}-{top,tail}/ + 每趟一份 PROVENANCE
#         （`<rev>` 与 PROVENANCE 的 `rev=` 都是**被拍二进制自己的**提交号，不是拍图时的 HEAD）
#   EXPECT_PAGES=<n>  每趟应有张数（默认 9）
#   VIEWPORT_PT=<pt>  取证窗口高（默认 1000；本机屏高 1080，请求再高会被 AppKit 钳住）
#   CAPTURE_WINDOW_WIDTH=<pt>  取证窗口宽（不设 = 产品默认 1280；量窄态传 1080 = 本 App 的 minWidth）
#   只重拍变化的那几页：CAPTURE_PAGES="代码规模:健康评分" EXPECT_PAGES=2（冒号分隔，页名里有空格）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

REPO_ROOT=$(git rev-parse --show-toplevel)
SCRATCH="${TCODER_SCRATCH:-$REPO_ROOT/.scratch}"
BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
BRIGHT="$SCRATCH/page_brightness"
BRIGHT_SRC="$PWD/scripts/page_brightness.swift"
# 「这批图拍的是哪个提交」只认**二进制自己的记录**，不认拍图那一刻的 HEAD。
# 直接起因（2026-09-23 18:01 实测）：主树在构建之后又落了一笔只动 docs 的提交，
# `verify_provenance.sh` 按产物码 tree 正常放行（代码确实同源），而旧写法把
# `git rev-parse HEAD` 盖进每趟 PROVENANCE 的 `rev=` —— 16 张图的归属于是被说成一个
# **从没被拍过**的头（拍的是 fa954fa 的二进制，纸上写 bdf53f4）。
# 改成认二进制的头以后，走错方向只会"显得更旧"（保守，判过期），不会"显得更新"（假新鲜）。
source "$PWD/scripts/perf_provenance.sh"
BINARY_COMMIT=$(provenance_manifest_value TCODER_GIT_REVISION)
REV=$(git rev-parse --short "$BINARY_COMMIT" 2>/dev/null)
HEAD_REV=$(git rev-parse --short HEAD)
BATCH="${1:-$REV}"
OUT_ROOT="$SCRATCH/evidence-$REV-$BATCH"
EXPECT="${EXPECT_PAGES:-9}"
VIEWPORT="${VIEWPORT_PT:-1000}"
# 取证窗宽。不设 = 产品自己的 `CaptureWindow.width`（1280）。
# 为什么要开这个口子：本 App 的 `minWidth` 是 1080，而"深浅两态九页全部实拍复核通过"
# 这句话一直**只在 1280 那一档被量过** —— 窄态从没进过取证口径。
# P49 首拍 1080 就在性能页抓到读数被折断（`128 MB/` + `s`），见台账 §6.49。
WIDTH="${CAPTURE_WINDOW_WIDTH:-}"

fail() { echo "!! $1"; exit 1; }

[ -n "$REV" ] || fail "读不到 dist/RELEASE_MANIFEST.env 里的 TCODER_GIT_REVISION —— 先跑 ./scripts/build_app.sh release"
mkdir -p "$OUT_ROOT" || fail "建不了 $OUT_ROOT"

# ── 前置：尺子先自证，再来量界面 ────────────────────────────────────────────
AVAIL=$(df -k /System/Volumes/Data | awk 'NR==2{print int($4/1024/1024)}')
[ "${AVAIL:-0}" -ge 20 ] || fail "可用 ${AVAIL} GiB < 20 GiB，本取证拒绝开跑"
[ -x "$BIN" ] || fail "找不到 $BIN，先跑 ./scripts/build_app.sh release"
[ -f "$BRIGHT_SRC" ] || fail "找不到 $BRIGHT_SRC"
if [ ! -x "$BRIGHT" ] || [ "$BRIGHT_SRC" -nt "$BRIGHT" ]; then
  xcrun swiftc -warnings-as-errors -O "$BRIGHT_SRC" -o "$BRIGHT" || fail "亮度判据编译失败"
fi
"$BRIGHT" selfcheck > "$SCRATCH/page_brightness-selfcheck.log" 2>&1 \
  || fail "亮度判据 selfcheck 没过（见 $SCRATCH/page_brightness-selfcheck.log）—— 尺子不可信，不出数"
echo "== 尺子自证通过；被拍产物 $BIN；输出 $OUT_ROOT"
echo "   归属提交 $REV（二进制自己的记录）；拍图时 HEAD=$HEAD_REV"
[ "$REV" = "$HEAD_REV" ] || echo "   ※ 两者不同 ⇒ 本次靠「产物码 tree 相同」放行，每趟 PROVENANCE 会同时写下 head_at_capture"

# ── 外观：记下原值，无论怎么结束都要还原（这是被反复要求的例外，只动这一项）──
appearance() { osascript -e 'tell application "System Events" to tell appearance preferences to get dark mode' 2>/dev/null; }
ORIGINAL_APPEARANCE=$(appearance)
restore_appearance() {
  [ -z "${1:-}" ] && return 0
  osascript -e "tell application \"System Events\" to tell appearance preferences to set dark mode to $1" 2>/dev/null
  sleep 2
}
trap 'restore_appearance "$ORIGINAL_APPEARANCE"' EXIT INT TERM

PASSES=0
FAILED_PASSES=0
for pass in light-top light-tail dark-top dark-tail; do
  polarity="${pass%%-*}"; scroll="${pass##*-}"
  want_dark=false; [ "$polarity" = "dark" ] && want_dark=true
  [ "$scroll" = "tail" ] && scroll=bottom || scroll=top
  out="$OUT_ROOT/$pass"
  echo "── 趟 $pass（外观=$want_dark 滚动=$scroll）"
  restore_appearance "$want_dark"
  sleep 1
  got=$(appearance)
  [ "$got" = "$want_dark" ] || fail "外观没翻过去（要 $want_dark，读到 $got）—— 这一趟不拍"
  # `CAPTURE_TERM` 默认开：**这条驱动自己起的实例，自己收尾**。
  # AGENTS §2.1（需求方 2026-09-23 定的通则）：谁起的谁退，起跑前后各数一次实例数。
  # 直接起因（2026-09-23 12:04 实测）：本驱动四趟跑完，`pgrep -x TcoderMonitor` 数到 **4 个孤儿**
  # （ppid=1，启动时刻 11:58:53 / 11:59:10 / 11:59:28 / 11:59:45，正好一趟一个），
  # 而 perf 那条流的 `perf_wait_window.sh` 因此已经白等了 1 小时 14 分钟 ——
  # 全机只有一个取证窗口，留着孤儿不是"等人工 Cmd+Q"，是**占着别人的窗口**。
  # 底层脚本仍保留 `CAPTURE_TERM=0` 那条保守路径（只通报 pid），但**只发给自己的 pid、
  # 且先核对二进制路径**，绝不按 bundle id 广播 quit（那会全机生效，误杀别家正在拍的实例）。
  CAPTURE_WINDOW_HEIGHT="$VIEWPORT" CAPTURE_WINDOW_WIDTH="$WIDTH" CAPTURE_SCROLL="$scroll" \
    CAPTURE_TERM="${CAPTURE_TERM:-1}" \
    ./scripts/capture_pages_isolated.sh "$out" > "$OUT_ROOT/$pass.capture.log" 2>&1
  inner=$?
  mkdir -p "$out"
  cat > "$out/PROVENANCE" <<EOF
rev=$REV
commit=$BINARY_COMMIT
head_at_capture=$(git rev-parse --short HEAD)
branch=$(git rev-parse --abbrev-ref HEAD)
pass=$pass
polarity=$polarity
viewport=${VIEWPORT}pt
width=${WIDTH:-product-default}pt
scroll=$scroll
appearance=$want_dark
binary_sha=$(shasum -a 256 "$BIN" | awk '{print $1}')
sandbox=$(grep -o '/[^ ]*capture-sandbox-[^ ]*' "$OUT_ROOT/$pass.capture.log" | head -1)
pkg=$PWD
EOF
  n=$(ls -1 "$out"/*.png 2>/dev/null | wc -l | tr -d ' ')
  if [ "$n" != "$EXPECT" ]; then
    echo "   ❌ 张数 $n ≠ $EXPECT（采集退出码 $inner）：$out"
    tail -6 "$OUT_ROOT/$pass.capture.log" | sed 's/^/      /'
    FAILED_PASSES=$((FAILED_PASSES + 1)); continue
  fi
  if ! "$BRIGHT" check "$polarity" "$out"/*.png > "$OUT_ROOT/$pass.brightness.log" 2>&1; then
    echo "   ❌ 逐张亮度判据没过（$polarity）：$out"
    grep -E "❌|mean=" "$OUT_ROOT/$pass.brightness.log" | sed 's/^/      /'
    FAILED_PASSES=$((FAILED_PASSES + 1)); continue
  fi
  echo "   ✅ $n/$EXPECT 张，逐张极性判定通过（均亮见 $OUT_ROOT/$pass.brightness.log）"
  PASSES=$((PASSES + 1))
done

echo "== 完成：$PASSES/4 趟合格，产物 $OUT_ROOT"
[ "$FAILED_PASSES" = "0" ] || { echo "!! $FAILED_PASSES 趟不合格 —— 本批不算复核通过"; exit 1; }
# 张数**算出来再说**，不写死 36：缩小过页面范围时写死就是在谎报证据规模。
SHOTS=$(find "$OUT_ROOT" -name '*.png' | wc -l | tr -d ' ')
echo "全部四趟合格：$SHOTS 张逐张判过极性，外观已还原为 $ORIGINAL_APPEARANCE"
