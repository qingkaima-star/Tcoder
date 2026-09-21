#!/bin/bash
# 真机自扫打分器：把本仓库当成项目装进 Tcoder.app，让它自己扫自己，再把落盘报告里
# 「综合健康分」与「工程质量（代码口径）」两个读数打回终端。
#
# 为什么要有第四把尺子（e2e_check / verify_pages / capture_pages_isolated 都不够）：
# 那三把都在核对"界面/链路对不对"，没有一个回答"这次改动让 Tcoder 给自己打几分"。
# 而收官阶段每合一包都要知道这个数动没动 —— 手点 App 不可复现，写死进测试又会把
# 产品的分数钉成回归基线（改一行代码就得改测试），所以做成**只出读数的脚本**。
#
# 用法: scripts/self_score.sh [--build]
#   --build              先跑 build_app.sh release（默认不建，用现成 dist，靠 provenance 判新鲜）
#   SCORE_TARGET=<目录>  被扫项目（默认 = git 仓库根，即 dogfooding）
#   SCORE_SANDBOX=<目录> 支持目录沙箱（默认包根 .scratch/tcoder-selfscore-<时间戳>，每次新建；
#                        规矩见 AGENTS §1.6：重活产物不进 $TMPDIR，跑完自清）
#   SCORE_WAIT=<秒>      等报告落盘的上限（默认 300）
#   SCORE_TERM=1         收尾对**本脚本自己起的、二进制路径核对一致的**那一个 pid 发 SIGTERM；
#                        默认只通报 pid 等人工 Cmd+Q。绝不按 bundle id 广播 quit（那会全机生效，
#                        把别的流正在跑的实例一起杀掉 —— 本仓记过这笔账）
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
UUID="11111111-2222-3333-4444-555555555555"
REPO_ROOT=$(git rev-parse --show-toplevel)
TARGET="${SCORE_TARGET:-$REPO_ROOT}"
SANDBOX="${SCORE_SANDBOX:-$PWD/.scratch/tcoder-selfscore-$(date +%Y%m%d-%H%M%S)}"
WAIT="${SCORE_WAIT:-300}"

die() { echo "!! $1"; exit 1; }
[ -d "$TARGET" ] || die "被扫目录不存在: $TARGET"

if [ "${1:-}" = "--build" ]; then
  echo "==> 0/4 重新打包 release"
  ./scripts/build_app.sh release >/dev/null 2>&1 || die "build_app.sh release 失败（细节看 ./scripts/locked_build.sh build）"
fi
[ -x "$BIN" ] || die "找不到 $BIN，先跑 ./scripts/build_app.sh release（或加 --build）"

echo "==> 1/4 二进制来源证明（这分数是哪个头的代码给的）"
if ./scripts/verify_provenance.sh >/tmp/self-score-provenance.log 2>&1; then
  tail -2 /tmp/self-score-provenance.log
else
  echo "    ⚠ dist 与当前 HEAD 不一致 —— 下面读数算「上一个头的分」，别当本次改动的结果用"
  tail -3 /tmp/self-score-provenance.log
fi

echo "==> 2/4 预置沙箱 $SANDBOX（被扫对象 = $TARGET）"
mkdir -p "$SANDBOX/reports" || die "建不了沙箱"
python3 - "$SANDBOX" "$UUID" "$TARGET" <<'PY' || die "写入 projects.json 失败"
import json, sys, datetime
support, uuid, path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(f"{support}/projects.json", "w") as fh:
    json.dump({"projects": [{"id": uuid, "name": "Tcoder（自扫打分）", "path": path,
                             "addedAt": now, "isDemo": False}],
               "selectedProjectID": uuid}, fh, indent=2)
PY

REPORT="$SANDBOX/reports/$UUID.json"
echo "==> 3/4 起实例并等报告落盘（上限 ${WAIT}s）"
TCODER_SUPPORT_DIR="$SANDBOX" "$BIN" -ApplePersistenceIgnoreState YES >"$SANDBOX/instance.log" 2>&1 &
PID=$!
waited=0
until [ -s "$REPORT" ]; do
  sleep 5; waited=$((waited + 5))
  kill -0 "$PID" 2>/dev/null || die "实例 $PID 已退出，报告没落盘（看 $SANDBOX/instance.log）"
  [ "$waited" -ge "$WAIT" ] && die "等 ${WAIT}s 仍无报告：$REPORT"
done
# 报告是一次性写还是分段写未知，尺寸稳定 2 轮再读，免得读到半份
prev=""
for _ in 1 2 3; do
  size=$(stat -f '%z' "$REPORT")
  [ "$size" = "$prev" ] && break
  prev="$size"; sleep 2
done
echo "    报告 $REPORT（$(stat -f '%z' "$REPORT") 字节，等待 ${waited}s）"

python3 - "$REPORT" "$TARGET" <<'PY'
import json, sys
path, target = sys.argv[1], sys.argv[2]
r = json.load(open(path))
h = r.get("health") or {}
print(f"\n被扫对象 = {target}")
print(f"报告生成 = {r.get('generatedAt', h.get('computedAt', '?'))}")
print(f"综合健康分   = {h.get('overall')}")
scope = h.get("codeScope")
if scope is None:
    print("工程质量(代码口径) = 该二进制不产出此字段（dist 落后于源码，加 --build 重跑）")
else:
    print(f"工程质量(代码口径) = {scope.get('overall')}")
    print(f"  计入: {'、'.join(scope.get('includedDimensions') or [])}")
    print(f"  不含: {'、'.join(scope.get('excludedDimensions') or []) or '（无）'}")
    print(f"  口径: {scope.get('note')}")
print(f"结论: {h.get('narrative')}")
print("\n  分  权重  维度        依据")
for c in sorted(h.get("components", []), key=lambda x: x["score"]):
    print(f"{c['score']:>4}  {c['weight']:.4f}  {c['name']:<10} {c.get('detail','')}")
for i in h.get("issues", []): print("  问题:", i)
for i in h.get("recommendations", []): print("  建议:", i)
PY

echo "==> 4/4 收尾"
who=$(ps -p "$PID" -o comm= 2>/dev/null | tr -d ' ')
if [ "${SCORE_TERM:-0}" = "1" ] && [ "$who" = "$BIN" ]; then
  kill -TERM "$PID" 2>/dev/null || true
  echo "    已对本脚本起的 pid $PID 发 SIGTERM"
else
  [ "${SCORE_TERM:-0}" = "1" ] && [ "$who" != "$BIN" ] \
    && echo "    ⚠ pid $PID 的二进制是「$who」不是 $BIN —— 不是本脚本起的，拒绝发信号"
  echo "    待人工退出：pid $PID（沙箱 $SANDBOX，不影响用户项目列表）"
fi
