#!/bin/bash
# 真机自扫打分器：让 Tcoder 扫自己的仓库，把「综合健康分」与「工程质量（代码口径）」
# 两个读数打回终端。
#
# 2026-09-21 起走无头 CLI（`TcoderMonitor score`）。改造前它的形状是：预置沙箱 projects.json →
# **起一个 GUI 实例** → 每 5 秒轮询 reports/<uuid>.json 落盘（上限 300 秒）→ 尺寸稳定 3 轮再读 →
# python 解析 → 通报 pid 等人工 Cmd+Q。改成一次直调之后同样一趟实测 **4 秒**（debug 构建，
# 总体 = 本仓库根），而且不再占那个"全机同一时刻只允许一个人起 App"的取证格。
# 规格：docs/superpowers/specs/2026-09-21-tcoder-cli-design.md
#
# 为什么仍留着这把尺子而不是让各家直接敲二进制：provenance 前置（这分数是哪个头的代码给的）
# 和"只出读数、不设阈值"这两条得有个唯一落点。产品分数一旦被写死进测试，改一行代码就得改测试。
#
# 用法: scripts/self_score.sh [--build]
#   --build              先跑 build_app.sh release（默认不建，用现成 dist，靠 provenance 判新鲜）
#   SCORE_TARGET=<目录>  被扫项目（默认 = git 仓库根，即 dogfooding）
#   SCORE_WAIT=<秒>      CLI 自身的硬上限倍数（默认 2；CLI 内部另有 600 秒兜底）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN="${TCODER_CLI_BIN:-$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor}"
REPO_ROOT=$(git rev-parse --show-toplevel)
TARGET="${SCORE_TARGET:-$REPO_ROOT}"

die() { echo "!! $1"; exit 1; }
[ -d "$TARGET" ] || die "被扫目录不存在: $TARGET"

if [ "${1:-}" = "--build" ]; then
  # 重活之前先看盘（AGENTS §1.6）：读不到余量一律判败，静默放行的前置等于没有前置。
  avail=$(df -sP /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print int($4/1048576)}')
  [ -n "$avail" ] || die "读不到磁盘余量，拒绝跑构建（不静默放行）"
  [ "$avail" -ge 20 ] || die "可用只剩 ${avail} GiB（< 20 GiB），先清盘再构建"
  echo "==> 0/3 重新打包 release（盘上余量 ${avail} GiB）"
  ./scripts/build_app.sh release >/dev/null 2>&1 || die "build_app.sh release 失败（细节看 ./scripts/locked_build.sh build）"
fi
[ -x "$BIN" ] || die "找不到 $BIN，先跑 ./scripts/build_app.sh release（或加 --build）"

# 不含无头 CLI 的旧 dist 会把 `score` 当成普通参数、**真的去起一个 GUI**。所以先探二进制里的
# 字面，不启动它 —— 这条判据本身就是"不写盘、不起界面"那个承诺的兑现。
LC_ALL=C grep -aq "退出码：0 五路全成" "$BIN" \
  || die "dist 二进制不含无头 CLI（早于本次改造）—— 加 --build 重打包，别拿旧 dist 试"

echo "==> 1/3 二进制来源证明（这分数是哪个头的代码给的）"
if ./scripts/verify_provenance.sh >/tmp/self-score-provenance.log 2>&1; then
  tail -2 /tmp/self-score-provenance.log
else
  echo "    ⚠ dist 与当前 HEAD 不一致 —— 下面读数算「上一个头的分」，别当本次改动的结果用"
  tail -3 /tmp/self-score-provenance.log
fi

echo "==> 2/3 无头扫描（被扫对象 = $TARGET）"
s=$(date +%s)
"$BIN" score "$TARGET"
code=$?
echo "==> 3/3 退出码 $code，耗时 $(( $(date +%s) - s ))s"
case $code in
  0) : ;;
  2) echo "    ⚠ 报告可用，但有分析路失败 —— 上面「失败路」那一行说了是哪几路；缺席维度的分不许当结论" ;;
  3) echo "    路径不可用，本次没有任何读数" ;;
  4) echo "    五路全失败或超时 —— 这条读作「什么都没量到」，不读作「这个仓库没有代码」" ;;
  *) echo "    用法错（64）？看 $BIN --help" ;;
esac
exit $code
