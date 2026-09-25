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
APP_DIR="dist/Tcoder.app"
BIN="${APP_DIR}/Contents/MacOS/TcoderMonitor"

if [ ! -f "$MANIFEST" ] || [ ! -f "$BIN" ]; then
  echo "!! 找不到 $MANIFEST 或二进制，请先跑 ./scripts/build_app.sh release"
  exit 1
fi

# 不用 eval 解析清单：值曾经带空格（旧包名 "Tcoder Monitor.app"），去掉引号再 eval 会
# 词分割成 `Monitor.app: command not found`。包名现在没空格了，但 eval 仍是注入面，
# 规则留着：只按需要的键逐条取值。
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
# rev / 构建时是否干净：判定与测量档共用同一把手尺子（`perf_provenance.sh`），
# 本文件只负责把它的结论翻成 ✅/❌ 那一行；不许在这里再写一遍 `[ "$a" = "$b" ]`。
source "$(dirname "$0")/perf_provenance.sh"
MF_TREE=$(mf_get PRODUCT_TREE)
HEAD_TREE=$(provenance_product_tree HEAD)
PROV_WHY=$(provenance_ok "$MF_REVISION" "$HEAD_SHA" "$MF_CLEAN" "$MF_TREE" "$HEAD_TREE") && prov_ok=1 || prov_ok=0
# prov_ok=1 且 PROV_WHY 非空 ⇒ 是"rev 不同但产物码 tree 相同"的放行，
# 此时 Info.plist 那条不能再拿裸 sha 比 HEAD（它存的是建物的那个提交号）。
PROV_BY_TREE=$([ "$prov_ok" = "1" ] && [ -n "$PROV_WHY" ] && echo 1 || echo 0)

echo "=== provenance 校验 ==="
chk "交付二进制哈希 == manifest 记录" "$MF_SHA" "$ACTUAL_SHA"
if [ "$prov_ok" = "1" ]; then
  echo "  ✅ 产物与当前代码同一份产物码（判定来自 perf_provenance.sh）"
else
  echo "  ❌ 产物与代码不是同一份：$PROV_WHY"; fail=1
fi
if [ "$PROV_BY_TREE" = "1" ]; then
  echo "  ✅ 产物与代码同源（按产物码 tree 归属，rev 不同）：${PROV_WHY}"
  chk "Info.plist 内 revision == 产物 rev" \
      "$(plutil -extract TCODERGitRevision raw "${APP_DIR}/Contents/Info.plist" 2>/dev/null)" "$MF_REVISION"
else
  chk "Info.plist 内 revision == HEAD" \
      "$(plutil -extract TCODERGitRevision raw "${APP_DIR}/Contents/Info.plist" 2>/dev/null)" "$HEAD_SHA"
fi

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
  # 收尾那句必须分两态——**这两种"通过"不是一件事，而只有第二种容易说谎**：
  #   · rev 相同 ⇒ 产物确实是从这个提交建的，"来自 HEAD" 说得出口；
  #   · rev 不同、只按产物码 tree 放行 ⇒ 能证明的只是"与 HEAD 同一份**产品码**"，
  #     那枚二进制自己是从 `${MF_REVISION}` 建的。把这一态也写成"来自 HEAD"，
  #     就是在给 #62 那句「认证 = 交付头」递一张它买不到的收据（报数的人会照着抄）。
  if [ "$PROV_BY_TREE" = "1" ]; then
    echo "全部通过：产物与 ${HEAD_SHA} **同一份产物码**（该二进制自身记的是 ${MF_REVISION}）"
    echo "  ⇒ 只能报「与交付头同一份产品码」，**不许**报「认证/取证 = 交付头 ${HEAD_SHA}」；差的虽只是 docs/scripts，措辞不能替它合并。"
  else
    echo "全部通过：产物可机械证明来自 ${HEAD_SHA}"
  fi
else
  echo "存在失败项 —— 不要交付这个产物"
fi
exit "$fail"
