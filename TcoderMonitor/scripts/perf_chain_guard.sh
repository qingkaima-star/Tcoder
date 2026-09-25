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

chain_tree() {  # ⇒ 这道闸**实际拿去比对**的那棵树。打印与比对必须同一个来源。
  # 为什么单独立一支：09-25 02:09（按该日志 mtime）那次拒绝行印的是 `${CHAIN_TREE:-$PWD}`
  # ＝`…/TcoderMonitor` 子目录，而比对用的是 `…/perf-base`（仓库根）——**同一件事两个数**，
  # 害得事后读日志的人（我）以为"比对的两棵树本来就不等、所以闸是误拒"。
  # 那次到底为什么拒，现在仍然说不清（见 #61），但"消息印的不是被比的那个数"这一条是**已证**的缺陷，
  # 就在这行修掉：印与比共用这一支。
  printf '%s' "${CHAIN_TREE:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
}

is_ours() {  # is_ours <pid> ⇒ 是这个进程自己或它的后代（含命令替换的 fork，无论几层）时返回 0
  # ⚠ 这条是**防御性**的，不是对 02:09 那次的归因：那道闸的调用点只有一层命令替换，
  #    而"自己的 fork 被当成另一条链"需要**两层以上**嵌套（pgrep 与那个 fork 得同时活着）
  #    ⇒ 代码读下来那条路径不成立，所以旧注释里"第一版在这里自我误判"那句是**我把假设写成了结论**，
  #    已在下面 `clashing_chains` 的注释里更正。留着它的理由：真出现两层嵌套时它挡得住。
  local p="${1:-}" g guard=0
  while [ -n "$p" ] && [ "$p" != "0" ] && [ "$p" != "1" ] && [ "$guard" -lt 20 ]; do
    if [ "$p" = "$$" ]; then return 0; fi
    g=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    if [ -z "$g" ] || [ "$g" = "$p" ]; then return 1; fi   # 读不到或自环（pid 复用）⇒ 不认作自己人
    p="$g"; guard=$((guard + 1))
  done
  return 1
}

clashing_chains() {  # ⇒ 每行 "<pid>\t<树>\t<ps 现场>"：与本树同树、或归属不可辨的其它排程器（不含自己）
  # 每一行都挂一段 `ps` 的原始事实（ppid + 命令行前 60 字）。**拒人的那一行必须自带证据**：
  # 09-25 02:09 这道闸把 t14 整批拒了一次（起跑前我数过 `pgrep` 是 0 条链），而它当时只印了
  # 一个 pid 40815 —— 事后没人能说出那到底是什么进程，我也只能说"大概是 fork"。
  # ⚠ 更正：先前这里写着"第一版在这里自我误判（fork 被当成另一条链）"，那是**未证实的假设被写成了结论**。
  #    反例（第 56 项之四）在摘掉 ppid 过滤之后照样全绿；而调用点只有一层命令替换，
  #    自匹配需要两层以上 ⇒ 该机制在这条路径上不成立（代码读出来的，不是猜的）。
  #    那次为什么拒，凭现存的这一行日志**判不了**；下一次再发生就直接读现场那一列。
  local p mine tree pp cmd
  mine=$(chain_tree)
  for p in $(pgrep -f "perf_wait_window\.sh" 2>/dev/null); do
    is_ours "$p" && continue
    pp=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
    tree=$(tree_of_pid "$p")
    if [ "$tree" = "unknown" ] || [ "$tree" = "$mine" ]; then
      cmd=$(ps -o command= -p "$p" 2>/dev/null | cut -c1-60)
      printf '%s\t%s\tppid=%s cmd=%s\n' "$p" "$tree" "${pp:-?}" "${cmd:-已退出}"
    fi
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
  echo "!! 已经有测量链在跑（下面每行是 pid、它归属的树，以及现场 ps），与本树 $(chain_tree) 同树或归属不可辨：" >&2
  # ⚠ 三个字段要**三个变量**接：写成 `read -r pid tree` 时，剩下的整段（含制表符）会全落进 `tree`，
  #    于是现场那一列被粘成"树=…"的一部分——今天新加的判据（selfcheck 第 58 项）第一次跑就抓到它。
  printf '%s\n' "$clash" | while IFS=$'\t' read -r pid tree scene; do
    echo "     pid=$pid  树=$tree  ${scene:-现场未取到}" >&2
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
