#!/bin/bash
# 逐页截图取证：让 App 以指定页面启动，抓窗口截图，确认九个视图都真的渲染出内容。
# 依赖 ProjectDetailView 的 @AppStorage("selectedDetailSection")。
set -uo pipefail
cd "$(dirname "$0")/.."

APP="dist/Tcoder Monitor.app"
# 窗口列举器随仓库走，不放 /tmp：重启即失效会让取证静默退化成"无窗口"
WINLIST="$PWD/scripts/winlist.swift"
OUT="${1:-/tmp/tcoder-pages}"
SECTIONS=("总览" "代码规模" "复杂度风险" "Git 洞察" "贡献者" "性能监控" "错误日志" "依赖分析" "健康评分")

# 前置 0（放在构建之前，被拦时不白跑一次编译）：
# Application Support 与 defaults 域全机唯一，任何非本包实例都可能在退出时回写污染数据，
# 现在拍图拍到的是脏数据。规约禁止向进程发信号，所以只能拒拍并交人工 Cmd+Q。
if [ "${ALLOW_EXTRA_INSTANCES:-0}" != "1" ]; then
  STRAY=$(pgrep -x TcoderMonitor || true)
  if [ -n "${STRAY}" ]; then
    echo "!! 检测到 $(echo "${STRAY}" | wc -l | tr -d ' ') 个非本包 TcoderMonitor 实例：pid $(echo ${STRAY} | tr '\n' ' ')"
    echo "!! 它们与本包共用 ~/Library/Application Support/TcoderMonitor，此时截图必脏 —— 拒绝取证。"
    echo "!! 请人工 Cmd+Q 后重试（本脚本不向任何进程发信号）。确需强拍：ALLOW_EXTRA_INSTANCES=1"
    exit 1
  fi
  echo "==> 前置 0 通过：无其他 TcoderMonitor 实例"
fi

# 取证门禁：截图前必须从当前源码重新构建并跑绿测试。
# 曾经因为拿旧 dist 二进制截图，把九张几乎同尺寸的图当成"九页均已验证"。
# 九张图尺寸几乎一致，就是取了旧二进制的最直接破绽。
if [ "${SKIP_VERIFY_GATE:-0}" != "1" ]; then
  echo "==> 门禁 1/2 从当前源码构建"
  if ! ./scripts/build_app.sh release; then
    echo "!! 构建失败，拒绝取证（现在的工作区不足以产出可信截图）"; exit 1
  fi
  echo "==> 门禁 2/2 跑单元测试"
  if ! ./scripts/locked_build.sh test > /tmp/tcoder-verify-test.log 2>&1; then
    echo "!! 测试未通过，拒绝取证。失败摘要："
    grep -E "error:|failed \(|XCTAssert" /tmp/tcoder-verify-test.log | head -15
    exit 1
  fi
  tail -3 /tmp/tcoder-verify-test.log
  echo "==> 门禁通过，dist 已与当前源码一致"
fi

mkdir -p "$OUT"
rm -f "$OUT"/*.png
FAILED=0

for name in "${SECTIONS[@]}"; do
  osascript -e 'tell application id "com.tcoder.monitor" to quit' 2>/dev/null || true
  sleep 1
  # 只取 dist 里那个 bundle。`open` 出去的 App 与直接跑 .build/debug 的调试实例
  # 同名不同源，pgrep -x TcoderMonitor 会把调试实例也抓进来——那样截到的
  # 就不是本次构建的窗口，selectedDetailSection 也写不到那个进程头上。
  defaults write com.tcoder.monitor selectedDetailSection -string "$name"
  defaults write com.tcoder.monitor ApplePersistenceIgnoreState -bool YES
  open "$APP"
  sleep 7
  PID=$(pgrep -f "dist/Tcoder Monitor.app/Contents/MacOS/TcoderMonitor" | head -1 || true)
  if [ -z "$PID" ]; then echo "  $name -> !! 未找到本次 dist 实例（有无响应退出的调试实例残留？）"; continue; fi
  WIN=$(xcrun swift "$WINLIST" "$PID" 2>/dev/null | head -1 | cut -d'|' -f1)
  # 分隔符必须是 `|`：winlist.swift 打印的是 `窗口号|标题|宽度`，
  # 而 `cut -f1` 默认按制表符切，会把整行原样交给 screencapture -l，
  # 于是每张图都拍不出文件、只打印 "0 字节"，脚本却照样跑到最后。
  if [ -z "$WIN" ]; then echo "  $name -> !! 无窗口"; continue; fi
  file="$OUT/${name}.png"
  screencapture -x -o -l"$WIN" "$file" 2>/dev/null
  size=$(stat -f '%z' "$file" 2>/dev/null || echo 0)
  # 空白窗口和渲染出内容的窗口，PNG 体积差得很远，用它做粗筛
  echo "  $name -> ${size} 字节"
  if [ "$size" -lt 20000 ]; then
    # 20KB 以下基本只可能是"窗口没拍出来"。以前这里只打印不判失败，
    # 于是九行全打 0 字节、脚本仍以 exit 0 收场——取证脚本最坏的失效就是这种。
    echo "    ↑ 体积过小，判这页没拍到"; FAILED=$((FAILED + 1))
  fi
done

osascript -e 'tell application id "com.tcoder.monitor" to quit' 2>/dev/null || true
defaults delete com.tcoder.monitor selectedDetailSection 2>/dev/null || true
echo "截图目录: $OUT"
N=$(ls -1 "$OUT"/*.png 2>/dev/null | wc -l | tr -d ' ')
echo "产出 $N 张 / 9 页，判失败 $FAILED 页"
if [ "$N" != "9" ] || [ "$FAILED" != "0" ]; then
  echo "==> ❌ 九页不齐或有页没拍到，本次取证不作数"
  exit 1
fi
