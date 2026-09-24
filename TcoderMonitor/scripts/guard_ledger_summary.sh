#!/bin/bash
# OWNER: WS-R31 GuardLedger（台账卷三 §62 · RD-64）—— 把这次全量跑落在 .scratch 的守卫读数台账
#        打成一张人读的表。
#
# 为什么必须有它（缺陷本身）：全量跑（无 --filter）会**安静地丢掉**一部分守卫的 print 读数——
# 日志里只看得到"通过 / 失败"、看不到这些判据到底量到了什么 ⇒ 那句"全量 N 例 / 0 失败"
# 不带任何测量证据。守卫（ConflictMarkerGuardTests / BoardLengthReadoutRatchetTests /
# EvidenceFreshnessTests）已把同一批读数**另外落了一份带被测头的账**（见 GuardLedger.swift），
# 这张脚本就是那份账的读出口——它证明"第二条出口真的通"。
#
# 三条硬性要求（本仓吃过"没前置的拒跑等于没前置"）：
#   ① 读不到任何账 ⇒ 出声报错、非零退出，**绝不打一张空表冒充结论**；
#   ② 每一项都要逐行出声（不许静默聚合成一行）；
#   ③ 项数少 = 断言失败的一种：三张应有的账缺任意一张即判败。
set -uo pipefail

# AGENTS §1.6：一次性产物落仓库内 .scratch，不进 $TMPDIR；TCODER_SCRATCH 可覆盖。
SCRATCH="${TCODER_SCRATCH:-}"
if [ -z "$SCRATCH" ]; then
  TOPLEVEL="$(git rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$TOPLEVEL" ]; then
    echo "❌ 取不到仓库根（不在 git 仓库里、也没设 TCODER_SCRATCH）⇒ 无从定位 .scratch，拒绝出表"
    exit 1
  fi
  SCRATCH="$TOPLEVEL/.scratch"
fi
LEDGER_DIR="$SCRATCH/guard-ledger"

# 这次跑**应当**在场的三张账：缺任意一张 = 那条守卫这次没落账 = 断言失败的一种。
REQUIRED=("ConflictMarkerGuardTests" "BoardLengthReadoutRatchetTests" "EvidenceFreshnessTests")

if [ ! -d "$LEDGER_DIR" ]; then
  echo "❌ 读不到台账目录 $LEDGER_DIR ⇒ 没有账可汇总（这不是「都过了」，是根本没落账）"
  exit 1
fi

rows=0
header_printed=0
# 逐张账、逐行出声：列序与 GuardLedger 一致（时间 ⇥ 被测头 ⇥ 守卫名 ⇥ 读数）。
# 表头**推迟到第一行读数之前**才打——读不到账时连表头都不出，避免半张空表被读成结论。
for f in "$LEDGER_DIR"/*.ledger; do
  [ -e "$f" ] || continue
  while IFS=$'\t' read -r c_time c_head c_guard c_reading || [ -n "${c_time:-}" ]; do
    [ -n "${c_guard:-}${c_reading:-}" ] || continue
    if [ "$header_printed" -eq 0 ]; then
      printf '守卫名\t被测头\t时间(UTC)\t读数\n'
      printf -- '----\t----\t----\t----\n'
      header_printed=1
    fi
    printf '%s\t%s\t%s\t%s\n' "$c_guard" "$c_head" "$c_time" "$c_reading"
    rows=$((rows + 1))
  done < "$f"
done

# 应有的账一张都不许缺：缺 = 那条守卫这次没跑 / 没落账，与缺陷同形（读数缺席却不出声）。
missing=0
for g in "${REQUIRED[@]}"; do
  if [ ! -s "$LEDGER_DIR/$g.ledger" ]; then
    echo "❌ 缺守卫「$g」的台账（文件不存在或为空）⇒ 第二条出口对这条守卫没生效"
    missing=$((missing + 1))
  fi
done

if [ "$rows" -eq 0 ]; then
  echo "❌ $LEDGER_DIR 里一张账都读不出行 ⇒ 空表不是结论，拒跑"
  exit 1
fi
if [ "$missing" -ne 0 ]; then
  echo "==> ❌ 应有 ${#REQUIRED[@]} 张账、缺 $missing 张；本次共汇总 $rows 行读数。"
  exit 1
fi
echo "==> ✅ 汇总 $rows 行读数，${#REQUIRED[@]} 张应有的账全部在场（目录 $LEDGER_DIR）。"
