#!/bin/bash
# 校验 dist/ 里的 .app 确实机械可证明来自某一次提交。
# 用法: scripts/verify_provenance.sh
#
# 为什么要有这把脚本：交付声明"二进制与 HEAD 一致"如果只能靠人眼看时间戳，
# 它就只是一句口号。这里把每一项都做成显式比对，**空值一律判失败**——
# 我踩过一次 `"" == ""` 打印出绿的假校验，所以每一条都必须先非空再相等。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MANIFEST="dist/RELEASE_MANIFEST.env"
APP_DIR="dist/Tcoder Monitor.app"
BIN="${APP_DIR}/Contents/MacOS/TcoderMonitor"

if [ ! -f "$MANIFEST" ] || [ ! -f "$BIN" ]; then
  echo "!! 找不到 $MANIFEST 或二进制，请先跑 ./scripts/build_app.sh release"
  exit 1
fi

# 不用 eval 解析：值里带空格（"dist/Tcoder Monitor.app"），
# 一旦去掉引号再 eval 就会词分割成 `Monitor.app: command not found`。
# WS-E 已经踩过并修过同一个坑，这里只按需要的键逐条取值。
mf_get() {
  grep -E "^TCODER_$1=" "$MANIFEST" | head -1 | sed -E 's/^[^=]+=//; s/^"//; s/"$//'
}
MF_REVISION=$(mf_get GIT_REVISION)
MF_BRANCH=$(mf_get GIT_BRANCH)
MF_CLEAN=$(mf_get GIT_CLEAN)
MF_TIMESTAMP=$(mf_get BUILD_TIMESTAMP)
MF_SHA=$(mf_get BINARY_SHA256)
MF_PRESHA=$(mf_get BINARY_SHA256_PRESIGN)

fail=0
chk() {
  local label="$1" claimed="$2" actual="$3"
  if [ -z "$claimed" ] || [ -z "$actual" ]; then
    echo "  ❌ ${label}（存在空值，比对无效）claimed='${claimed}' actual='${actual}'"; fail=1
  elif [ "$claimed" = "$actual" ]; then
    echo "  ✅ ${label}"
  else
    echo "  ❌ ${label}  claimed='${claimed}'  actual='${actual}'"; fail=1
  fi
}

ACTUAL_SHA=$(shasum -a 256 "$BIN" | cut -d' ' -f1)
HEAD_SHA=$(git rev-parse HEAD)

echo "=== provenance 校验 ==="
chk "交付二进制哈希 == manifest 记录" "$MF_SHA" "$ACTUAL_SHA"
chk "manifest revision == 当前 HEAD" "$MF_REVISION" "$HEAD_SHA"
chk "构建时工作树干净" "$MF_CLEAN" "true"
chk "Info.plist 内 revision == HEAD" \
    "$(plutil -extract TCODERGitRevision raw "${APP_DIR}/Contents/Info.plist" 2>/dev/null)" "$HEAD_SHA"

if [ -z "$MF_PRESHA" ]; then
  echo "  ❌ 缺 presign 值，无法判断哈希是否为签名后重算"; fail=1
elif [ "$MF_PRESHA" = "$ACTUAL_SHA" ]; then
  echo "  ❌ presign == 交付哈希，说明哈希是在签名前算的（签名会改写二进制）"; fail=1
else
  echo "  ✅ presign ≠ 交付哈希（证明确系签名之后重算）"
fi

LIPO=$(lipo -info "$BIN" 2>&1)
if echo "$LIPO" | grep -q "arm64" && ! echo "$LIPO" | grep -qi "x86_64"; then
  echo "  ✅ 架构仅 arm64"
else
  echo "  ❌ 架构异常：$LIPO"; fail=1
fi

echo "---"
echo "  revision : ${MF_REVISION:-?}"
echo "  branch   : ${MF_BRANCH:-?}"
echo "  built at : ${MF_TIMESTAMP:-?}"
echo "  delivered: ${ACTUAL_SHA}"
echo "---"
if [ "$fail" = "0" ]; then
  echo "全部通过：产物可机械证明来自 ${HEAD_SHA}"
else
  echo "存在失败项 —— 不要交付这个产物"
fi
exit "$fail"
