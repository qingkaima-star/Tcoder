#!/usr/bin/env bash
# 收尾磁盘卫生这一族，从 `perf_preflight.sh` 搬出来（2026-09-25，缺陷 #70 那一笔）。
#
# 为什么搬而不是就地加：preflight 已经 378/400，而 #70 要补的是"每轮收尾固定几件事"
# 这一族里缺的那件事 —— 判废趟的 GB 级原始 trace 从来没人回收过。就地加两条函数就是把
# 那个文件推到 400 线外（同一个尺寸债在这条分支上已经到期过两次，见 #39）。
# 搬过来的东西**逐字未动**（`sweep_orphan_traces` / `post_run_disk_hygiene` 的判定与文案
# 都是原样），第 22 项反例仍然是 source `perf_preflight.sh` 之后调得到，因为下面这行
# source 就在 preflight 里。
#
# 只被 source，不直接执行。

# 判据本体在 `perf_reclaim.py`（同档中位数、×5 尺寸线、样本不足不判都在那儿）。
# 这里只留"每轮收尾印一行"这个动作：一个出口，别新开第二处报体积。
report_refused_traces() {  # report_refused_traces [<样本根>]：印"被拒趟还能回收多少盘"，默认不删
  local root="${1:-${SCRATCH:-${TCODER_SCRATCH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.scratch}}}"
  local ruler
  ruler="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/perf_reclaim.py"
  # 尺子或解释器不在场要**出声**：读成"没有残骸"就是这条守卫最坏的失效形状。
  if [ ! -f "$ruler" ] || ! command -v python3 >/dev/null 2>&1; then
    printf 'trace 回收：读不到 %s 或没有 python3 ⇒ 这一维没查（不是"没有残骸"）\n' "$ruler"
    return 0
  fi
  # `|| printf` 不是装饰：`set -e` 下 python 非零退出会**中止整个收尾**，
  # 那正是第 22 项抓到过的形状（丢一份合格读数，比留残骸更坏）。
  python3 "$ruler" "$root" || printf 'trace 回收：这一维没跑成（rc≠0），下次开录前手动跑一次它\n'
}

trace_path_in_use() {  # trace_path_in_use <路径>；返回 0 = 有进程正在用（含"里面某个文件被打开"）
  # 只看退出码不够：`lsof +D` 找到东西也返回 1 ⇒ 只能数表体行数。
  # 更要紧的是 `lsof -- <目录>` **看不见开在里面的文件**，而"正在录"就是把 trace
  # 文件开在目录里 —— 2026-09-25 实测：开一个 `sleep < dir/data.bin`，前者 0 行、
  # 后者 1 行。原来那一行守卫挡不住它声称要挡的那件事。
  local path="$1" rows
  rows=$(lsof -- "$path" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  [ "$rows" != "0" ] && return 0
  [ -d "$path" ] || return 1
  rows=$(lsof +D "$path" 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')
  [ "$rows" != "0" ]
}

sweep_orphan_traces() {  # 只删**没有任何进程打开着**的 .ktrace 中间产物
  # 为什么先看 lsof：正在录的那趟也会在自己的 $TMPDIR 里留 .ktrace，
  # 无差别删会把**正在进行的采集**打断（那是比留残骸更坏的修法）。
  local root="${1:-${TMPDIR:-/tmp}}" f kept=0 deleted=0
  [ -d "$root" ] || { printf '孤儿 trace：目标目录不在（%s），跳过\n' "$root"; return 0; }
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if trace_path_in_use "$f"; then kept=$((kept + 1)); continue; fi
    rm -rf -- "$f" && deleted=$((deleted + 1))
  done < <(find "$root" -maxdepth 1 \( -name 'instruments*.ktrace' -o -name '*.ktrace' \) 2>/dev/null)
  printf '孤儿 trace：删 %d 个、仍被进程打开而保留 %d 个（根 %s）\n' "$deleted" "$kept" "$root"
}

post_run_disk_hygiene() {  # 每轮收尾固定三件事：进程真退了没 + $TMPDIR 残骸 + 判废趟还能回收多少盘
  local left
  # `|| true` 不是装饰：`pgrep` 在"没有 xctrace"时退出码是 1，
  # 而 `set -e` 会让整个收尾**在那一行中止** —— 于是"机器干净"这种最好的情况
  # 反而跳过了扫残骸。新加的第 22 项收尾检查就是把它抓出来的东西。
  left=$(pgrep -x xctrace 2>/dev/null | tr '\n' ' ' || true)
  [ -n "$left" ] && echo "    ⚠ 还有 xctrace 在场（pid ${left% }）——先别开下一趟" >&2
  printf '    %s\n' "$(sweep_orphan_traces "${1:-${TMPDIR:-/tmp}}")"
  printf '    %s\n' "$(report_refused_traces "${2:-}")"
  # 阈值名收敛到 TCODER_MIN_FREE_GIB 时漏改了这行：`set -u` 下它直接**中止收尾**，
  # 于是"录成功的一趟"被上层记成失败（今晚就是这样丢了一份合格的心跳期读数）。
  echo "    磁盘可用 $(disk_free_gib) GiB（低于 ${TCODER_MIN_FREE_GIB:-20} 就不开新趟）"
}
