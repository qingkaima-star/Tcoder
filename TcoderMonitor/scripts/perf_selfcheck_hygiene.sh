#!/bin/bash
# perf_selfcheck_hygiene.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 61：**判废趟的原始 trace 回收**（缺陷 #70）。这一族以前没有任何反例，
#   因为「收尾扫残骸」这条规矩只有 $TMPDIR 那一半被量过（第 22 项）—— 产物搬进
#   仓库 `.scratch/` 之后旧清理器扫的是个不再有人写字的目录，而 215 GiB 的真实
#   残骸不在任何判据的射程里：**守卫全绿，磁盘照涨**。所以这块的分工是：
#   第 22 项管「收尾有没有真的跑起来」，本项管「回收这一维判得对不对、
#   以及它有没有接到那个出口上」。
#
# 双向是硬要求（本仓口径：扫描型判据必须两个方向都红过一次）：
#   反例侧 1 —— 合格趟里放一个巨大的 trace ⇒ **不许**被点名（否则回收器会删掉
#                唯一能解释「这档正常多大」的样本，下一轮的中位数就没有底座）；
#   反例侧 2 —— 被拒但尺寸正常的趟 ⇒ **不许**被点名（那份 trace 还能回收重导）；
#   反例侧 3 —— 样本不足的档 ⇒ 明写不判，且**不许**在该档里点名；
#   正例     —— 被拒 ∧ 超同档线 ⇒ 必须点名，默认只印不删，`TCODER_RECLAIM=1` 才删，
#                删的时候只动 `*.trace`，判定与上下文（REFUSED / meta.json）原样留着。
# 造尺寸用真写出来的字节：回收器量的是实际占盘块数，`truncate` 糊的稀疏文件
# 量不出大小 —— 那把尺子故意不认「看起来大但盘上不存在」的身材。
# =============================================================================

mk_reclaim_run() {  # mk_reclaim_run <样本根> <趟名> <trace KiB> <REFUSED 0|1>
  local d="$1" name="$2" kib="$3" refused="$4" run
  run="$d/$name"
  mkdir -p "$run/hitches.trace"
  dd if=/dev/zero of="$run/hitches.trace/data.bin" bs=1024 count="$kib" status=none
  printf '{"rev":"abc1234"}\n' > "$run/meta.json"
  if [ "$refused" = "1" ]; then
    printf 'REFUSED\n这一趟判废：合成夹具。\n' > "$run/REFUSED"
  fi
  return 0
}

reclaim_fixture() {  # reclaim_fixture <dir>：四个形状各占一处
  local d="$1"
  # idle 档 6 个样本：4 正常 + 1 被拒但正常尺寸 + 1 被拒且巨大（唯一该点名的）
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run1 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run2 8 1
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run3 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run4 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run5 240 1
  # interact 档 4 个样本：其中一个**巨大但没被拒** ⇒ 尺寸线不能单独定罪
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run1 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run2 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run3 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run4 240 0
  # switch 档只有 1 个样本 ⇒ 分母太小，整档不判（哪怕那个 trace 又大又被拒）
  mk_reclaim_run "$d" tcoder-perf-fix-switch-run1 240 1
}

selfcheck_refused_trace_reclaim() {  # 61) 判废趟的 GB 级 trace：该点名的点名、不该动的一个字不动
  local d="$out/reclaim" rc=0 txt="$out/reclaim-print.txt" hygiene listed key orphan=""
  # 顺带钉住一件事（本项自己就是这种失效的最新例子）：**新增一块反例文件必须真的
  # 被宿主的 `_part` 名单 source 到**。函数定义了却没人调用 ⇒ 一项反例静默消失，
  # 而 selfcheck 的项数照样在涨。取不到那一行时 `listed` 只剩空格 ⇒ 每块都算孤儿，
  # 方向是**往红失败**（名单形状变了要当场出声，不能读成"都挂上了"）。
  listed=" $(sed -n 's/^for _part in \(.*\); do$/\1/p' scripts/perf_selfcheck.sh) "
  for key in scripts/perf_selfcheck_*.sh; do
    key=${key##*perf_selfcheck_}; key=${key%.sh}
    case "$listed" in *" $key "*) ;; *) orphan="$orphan $key" ;; esac
  done
  if [ -n "$orphan" ]; then
    fail "反例块没被宿主 source：$orphan ⇒ 里面的项一个字都不会跑"
    rc=1
  fi
  rm -rf "$d"
  reclaim_fixture "$d"
  if ! python3 scripts/perf_reclaim.py "$d" > "$txt" 2>&1; then
    fail "回收尺子跑一趟就非零退出 ⇒ `set -e` 下它会中止整个收尾（第 22 项那个形状）"
    return
  fi
  # ---- 正例：被拒 ∧ 超同档中位线 ⇒ 点名，并把拒因带出来
  if ! grep -qF 'tcoder-perf-fix-idle-run5/hitches.trace' "$txt"; then
    fail "被拒且超同档线的那趟没被点名 ⇒ 回收这一维等于没上线（现读 $(tr '\n' '|' < "$txt")）"
    rc=1
  fi
  if ! grep -qF '1 个 bundle 可回收' "$txt"; then
    fail "点名的个数不是 1（该点的只有一处）⇒ 尺寸线或档位分母算错了"
    rc=1
  fi
  if ! grep -qF '合成夹具' "$txt"; then
    fail "点名了却没带拒因 ⇒ 报出来像脚本自己数了个数，不像在说这趟为什么能删"
  fi
  # ---- 反例侧 1：巨大但**没被拒** ⇒ 不许点名
  if grep -qF 'tcoder-perf-fix-interact-run4' "$txt"; then
    fail "没被拒的巨大 trace 被点名 ⇒ 会删掉唯一解释「这档正常多大」的样本，下一轮中位数失去底座"
    rc=1
  fi
  # ---- 反例侧 2：被拒但尺寸正常 ⇒ 不许点名（还能回收重导，那份 trace 值得留）
  if grep -qF 'tcoder-perf-fix-idle-run2/hitches.trace' "$txt"; then
    fail "被拒但尺寸正常的趟被点名 ⇒ 静默探针拒掉的那趟照样能重导，删它就是销毁可回收的读数"
    rc=1
  fi
  # ---- 反例侧 3：样本不足的档明写不判，且不判就得真的不判
  if ! grep -qF '档 switch 样本 1' "$txt"; then
    fail "只有 1 个样本的档没有明写「不判」⇒ 分母太小的散布会被当成判据（裁 A 同一族）"
    rc=1
  fi
  if grep -qF 'tcoder-perf-fix-switch-run1' "$txt"; then
    fail "样本不足的档仍然点了名 ⇒ 「不判」只是话术，判定照跑"
    rc=1
  fi
  # ---- 默认只印不删
  if [ ! -d "$d/tcoder-perf-fix-idle-run5/hitches.trace" ]; then
    fail "没给 TCODER_RECLAIM 就真删了 ⇒ 回收取证原件必须显式授权"
    rc=1
  fi
  # ---- 出口接线：尺子存在≠每轮都印，收尾那一串里要看得见这一维
  hygiene=$(bash -c 'set -euo pipefail
                     source scripts/perf_preflight.sh 2>/dev/null
                     post_run_disk_hygiene /nonexistent-tcoder-sweep "$1" 2>&1' _ "$d")
  case "$hygiene" in
    *"unbound variable"*)
      fail "回收这一维在裸 set -u 消费者下有未初始化量 ⇒ 收尾会中止、读数会丢：$hygiene"
      rc=1 ;;
  esac
  if ! printf '%s\n' "$hygiene" | grep -qF '1 个 bundle 可回收'; then
    fail "收尾出口没把回收这一维印出来 ⇒ 尺子住在 scripts 里却没人每轮读它"
    rc=1
  fi
  # ---- 显式授权才删，而且只删 *.trace
  if ! TCODER_RECLAIM=1 python3 scripts/perf_reclaim.py "$d" > "$out/reclaim-delete.txt" 2>&1; then
    fail "TCODER_RECLAIM=1 那一趟非零退出"
    rc=1
  fi
  if [ -d "$d/tcoder-perf-fix-idle-run5/hitches.trace" ]; then
    fail "给了 TCODER_RECLAIM=1 却没删 ⇒ 那个开关是装饰品"
    rc=1
  fi
  if [ ! -f "$d/tcoder-perf-fix-idle-run5/REFUSED" ] || [ ! -f "$d/tcoder-perf-fix-idle-run5/meta.json" ]; then
    fail "删 trace 时把判定/上下文一起带走了 ⇒ 台账会读成「这趟不存在」而不是「这趟判废」"
    rc=1
  fi
  if [ ! -d "$d/tcoder-perf-fix-interact-run4/hitches.trace" ] \
     || [ ! -d "$d/tcoder-perf-fix-switch-run1/hitches.trace" ]; then
    fail "不该点名的那两趟被删了 ⇒ 回收动作超出了判定点名的范围"
    rc=1
  fi
  [ "$rc" = "0" ] && ok "判废趟的原始 trace 回收双向有牙：被拒∧超线才点名、默认只印、显式授权才删且只动 *.trace"
}
