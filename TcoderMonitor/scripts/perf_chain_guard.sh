#!/bin/bash
# =============================================================================
# perf_chain_guard.sh —— 「同一棵工作树只许一条测量链在跑」这道闸的**判据本体**。
#
# 为什么单独成一个文件（而不是写在 `perf_wait_window.sh` 里）：
# 排程器是**可执行脚本**（source 它会直接开始等窗口），selfcheck 没法拿它做双向反例。
# 判据搬到这里之后，反例可以 source 一个库文件、只点函数（第 56 项就是这么钉的）。
#
# 触发事件（09-24 19:38，真烧掉一整批 t7/t8）：我 TERM 掉旧链时它正卡在 `sleep 60` 等窗，
# 而 **bash 的 trap 要等当前那条前台命令返回才执行**；等它真收尾时，新链已经 `open` 了新实例，
# 于是「按全路径收养式收尾」（包 34）认下了那个**新**实例并把它 TERM 掉 ⇒ 新链整批作废。
# ⇒ 光把这条写成一段话拦不住下一次，所以做成闸门：第二条链**当场拒起**。
#
# 三条边界（都故意的）：
#   · 归属只认**进程工作目录属于哪棵树**（`lsof -a -d cwd`），不按 bundle id、不按进程名广播
#     （AGENTS -1.3：不给任何别人的进程发信号）；
#   · **归属读不出来的算它一个** ⇒ 宁可拒也不放行：恒拒看得见，恒放行看不见（盲区第 13 类）；
#   · 要跨过去必须显式给 `ALLOW_CONCURRENT_CHAIN=1`，而且**大声出声**。
# =============================================================================
# 【被 source 的库文件不许设 shell 选项】这里不写 `set -u`：
# 一写就会漏进调用方的非交互 shell，未绑定变量时**整个 shell 静默退出**（第 40 项钉的是这条）。

tree_of_pid() {  # tree_of_pid <pid> ⇒ 那个进程 cwd 所属仓库根；读不到 ⇒ 打印 unknown
  local cwd root
  cwd=$(lsof -a -d cwd -p "$1" -Fn 2>/dev/null | sed -n 's/^n//p' | head -1)
  [ -z "$cwd" ] && { echo unknown; return 0; }
  root=$(cd "$cwd" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)
  echo "${root:-unknown}"
}

clashing_chains() {  # ⇒ 每行 "<pid>\t<树>"：与本树同树、或归属不可辨的其它排程器（不含自己）
  local p mine tree
  mine="${CHAIN_TREE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
  for p in $(pgrep -f "perf_wait_window\.sh" 2>/dev/null); do
    [ "$p" = "$$" ] && continue
    tree=$(tree_of_pid "$p")
    if [ "$tree" = "unknown" ] || [ "$tree" = "$mine" ]; then printf '%s\t%s\n' "$p" "$tree"; fi
  done
}

refuse_second_chain() {  # 有第二条链 ⇒ 出声并 exit 3；显式放行 ⇒ 大声通报后 return 0
  local clash
  [ "${ALLOW_CONCURRENT_CHAIN:-0}" = "1" ] && {
    echo "    ⚠ ALLOW_CONCURRENT_CHAIN=1：跳过「同树只许一条测量链」这道闸。" >&2
    echo "      两条链互收养实例 ⇒ 其中一批会整批作废（交接笔记 §BM），后果由下这条命令的人承担。" >&2
    return 0
  }
  clash=$(clashing_chains)
  [ -z "$clash" ] && return 0
  echo "!! 已经有测量链在跑（下面每行是 pid 与它归属的树），与本树 ${CHAIN_TREE:-$PWD} 同树或归属不可辨：" >&2
  printf '%s\n' "$clash" | while IFS=$'\t' read -r pid tree; do
    echo "     pid=$pid  树=$tree" >&2
  done
  echo "   现在起第二条，两条链的收尾会互相把对方的实例按路径「收养」掉 ⇒ 整批作废。" >&2
  echo "   正解：等它自己退；TERM 之后等过一个完整轮询周期（≥70 s）并核对" >&2
  echo "         pgrep -f perf_wait_window.sh 为空、pgrep -x TcoderMonitor 为 0，再起下一批。" >&2
  echo "   （树一栏写 unknown 的那行是故意算进来的：读不到归属就放行，等于给『看不见』发合格证。）" >&2
  exit 3
}

path_for_display() {  # path_for_display <路径> ⇒ 有界一行，但**一定含结尾的文件名**
  # 归属行为什么不许从尾巴上截：可执行文件的名字就在尾巴上。
  # 09-24 21:35 实测——长路径工作树里 `cut -c1-100` 把
  # `.../dist/Tcoder.app/Contents/MacOS/TcoderMonitor` 切成 `.../MacOS/Tcoder`，
  # 读日志的人（我）当场怀疑「测的不是屏上那个实例」，白查三分钟（bundle 里其实只有一个可执行文件）。
  # ⇒ 只许从**中间**裁：头留树、尾留文件名，整行长度照旧有界（第 57 项两头各钉一次）。
  local p="${1:-}"
  if [ "${#p}" -le 100 ]; then printf '%s' "$p"; return 0; fi
  printf '%s…%s' "${p:0:52}" "${p: -47}"
}
