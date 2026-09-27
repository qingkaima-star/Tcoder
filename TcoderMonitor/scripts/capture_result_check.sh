#!/bin/bash
# 九页取证的**结果判据**（从 `capture_pages_isolated.sh` 的 4/4 段抽出来，2026-09-27 §207／#116）。
#
# 为什么要抽出来：那三条判据原来住在带主流程的脚本里 ⇒ 谁也没法拿夹具测它
# （`source` 一个会自己跑的脚本 = 执行它，不是检查它）。抽成独立检查器之后，
# selfcheck 第 80 项可以用四格夹具逐条要求它出声（`perf_selfcheck_launchers.sh`）。
#
# 为什么这三条必须有后果（实测过，不是推的）：
#   · `FAILED` 与 `DUP` 在旧写法里**只印不判** —— 印完就往下走，只有"页不齐"会 exit 1；
#   · 而 `capture` 的一条失败路径是 `screencapture` 落了**0 字节文件**后返回 1，
#     那枚空文件留在目录里，`ls *.png | wc -l` 照样数进去 ⇒ 真少一页也仍然"页齐"。
#   ⇒ 所以这里数的是**非空** png，且 `FAILED`/`DUP` 都算失败。
#
# 用法：capture_result_check.sh <截图目录> <应拍页数> <拍砸页数>
#   退出 0 ＝合格；退出 1 ＝不合格（每个原因各印一行 ❌，并列出逐张 sha 供人看）
# 它**只读**那个目录，不写任何东西。
set -uo pipefail

OUT="${1:-}"
EXPECTED="${2:-}"
FAILED="${3:-}"

if [ -z "$OUT" ] || [ -z "$EXPECTED" ] || [ -z "$FAILED" ]; then
  echo "❌ 用法：capture_result_check.sh <截图目录> <应拍页数> <拍砸页数>（三个参数都必填）"
  exit 2
fi
if [ ! -d "$OUT" ]; then echo "❌ 截图目录不存在：$OUT"; exit 2; fi
case "$EXPECTED$FAILED" in
  *[!0-9]*) echo "❌ 页数与失败数必须是非负整数（收到 应拍=$EXPECTED 拍砸=$FAILED）"; exit 2 ;;
esac

# 分母取"本轮实际要拍的那几页"，不是写死 9：`CAPTURE_PAGES` 缩小范围时写死 9 会让
# 补拍永远判败（于是有人去 SKIP，判据就废了）。但**空总体必须判败**。
if [ "$EXPECTED" -eq 0 ]; then
  echo "    ❌ 要拍的页数为 0，本取证不出数"
  exit 1
fi

N=$(find "$OUT" -maxdepth 1 -name '*.png' -size +0 2>/dev/null | wc -l | tr -d ' ')
DUP=$(shasum -a 256 "$OUT"/*.png 2>/dev/null | awk '{print $1}' | sort | uniq -d | wc -l | tr -d ' ')
echo "    产出 $N 张 / $EXPECTED 页，失败 $FAILED 页，内容完全相同的图组数 $DUP"

bad=0
if [ "$N" != "$EXPECTED" ]; then
  echo "    ❌ 页不齐：本轮口径是 $EXPECTED 页，而**非空** png 只有 $N 张（0 字节的截图不算拍到）"
  bad=1
fi
if [ "$FAILED" != "0" ]; then
  echo "    ❌ 有 $FAILED 页被判没拍到（窗口 id 取不到 / 截图文件为空）——本次取证不作数"
  bad=1
fi
if [ "$DUP" != "0" ]; then
  echo "    ❌ 有 $DUP 组字节级完全相同的图：切页没生效（single 模式）或 argv 回落到默认页（argv 模式）"
  bad=1
fi
if [ "$bad" != "0" ]; then
  echo "    逐张指纹如下（供人工比对是哪两页撞了）："
  shasum -a 256 "$OUT"/*.png 2>/dev/null | awk '{printf "      %s  %s\n", substr($1,1,12), $2}'
  exit 1
fi
exit 0
