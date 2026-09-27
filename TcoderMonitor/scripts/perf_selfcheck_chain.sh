#!/bin/bash
# perf_selfcheck_chain.sh —— 反例块：链的归属显示与「同树只许一条链」这道闸。
# 由 `perf_selfcheck.sh` 的 for 那一行 source 进来（不要单独执行：它只定义函数，不会自己跑）。
#
# 为什么单独一块（第 6 块）：这两条判据的宿主是 `perf_chain_guard.sh`，
# 而它的函数**只有 source 才点得动**——排程器本体不能 source（一 source 就开始等窗口）。
#
# 为什么是**两项**不是一项：第一版写成一项 56 行，被尺子自己的「函数 ≤50 行 / CC<16」
# 棘轮当场判红（预合全量里 `perf_selfcheck_chain.selfcheck_chain_guard_and_path_display 56行`）。
# 正解还是拆开而不是抬线（本仓这条红线今天是第六次咬到自己）：
# 链闸三项与显示两项本来就各判各的事——**混在一起时，显示那半坏了会被链闸的绿掩护掉**（盲区第 26 类的镜像）。

chain_clash_line() {  # chain_clash_line <lib> <tree> ⇒ 打印与本树冲突的链（同树或归属不可辨），没有则空
  # 为什么单立两支都用它：第 56 项的**前提**与「之二」问的是同一个问题（"这棵树上还有别的链吗"），
  # 各写一遍 `bash -c source…` 就是"同一件事两把手抄尺子"的老账（口径会分叉）。
  #
  # 【为什么前提要问它、而不是全机 `pgrep -f perf_wait_window`】#111，2026-09-27：
  # 上一版夹具的前提是**全机数 argv**，于是别的流在等窗口（并行开发的常态）、或两棵树同时跑 selfcheck，
  # 这一项就被染红——**夹具的前提比它要测的判据更严，还严在了一个更大的范围上**：
  # 真判据 `clashing_chains` 是按树归属的。换成问它，红的时候还能顺带印出 pid／树／现场
  # （旧版只说"有一条在跑"，读的人得自己猜是哪棵树）。
  CHAIN_TREE="$2" bash -c "source '$1'; clashing_chains" 2>/dev/null
}

selfcheck_chain_guard_one_per_tree() {  # selfcheck_chain_guard_one_per_tree <outdir>
  # 56) 同树只许一条测量链。触发事件是 §BM 烧掉的那一整批：
  #     trap 等 `sleep` 返回 ⇒ 旧链收尾时把新链刚起的实例按路径「收养」掉，新链整批作废。
  local lib bad=0 fake tree rc clash
  lib="$(dirname "${BASH_SOURCE[0]}")/perf_chain_guard.sh"
  [ -f "$lib" ] || { fail "没有 $lib —— 这道闸搬了家就得同步搬反例"; return; }
  tree=$(cd "$(dirname "$0")/../.." && git rev-parse --show-toplevel)
  mkdir -p "$1/chain" || { fail "建不了反例目录 $1/chain"; return; }
  bad=0
  # 反例前提：现场必须没有真的链（有就**判红**，不许悄悄 skip——skip 是一项不会痛的假绿）。
  # 问的是**这道闸自己**（按树），不是全机数一遍 argv —— 为什么，见 `chain_clash_line` 的头（#111）。
  clash=$(chain_clash_line "$lib" "$tree")
  if [ -n "$clash" ]; then
    fail "本树现场已有链（判红而不是跳过）：$(printf '%s' "$clash" | tr '\n' ' ')⇒ 等它退出再跑"
    return
  fi
  # 之一：场上没有别的链 ⇒ 必须放行（恒拒的闸看起来最尽职，所以这条不可省）
  rc=$(CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain; echo OK" 2>/dev/null)
  [ "$rc" = "OK" ] || { fail "没有别的链却被拒（实得「$rc」）⇒ 这道闸恒拒，等价于永远量不了"; bad=1; }
  # 之二：造一条 cwd 在本树里的假链 ⇒ 必须当场拒，并把 pid 与树点名出来
  ( cd "$tree" && exec bash -c 'exec -a perf_wait_window.sh sleep 6' ) >/dev/null 2>&1 &
  fake=$!
  sleep 1
  clash=$(chain_clash_line "$lib" "$tree")
  case "$clash" in
    *"$fake"*) : ;;
    *) fail "假链 pid=$fake 没被认出来（实得「$clash」）⇒ 归属判据看不见自己起的链，闸等于没装"; bad=1 ;;
  esac
  kill -TERM "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
  # 收尾只查**自己那枚 pid**（#111 同因）：旧版"全机再数一遍"会把别人的真链算成我的残迹。
  # 断言的主体是"这个夹具自己留没留东西"，尺子就该量那个 pid——**不是放宽**：自己留的同名进程照样红。
  kill -0 "$fake" 2>/dev/null \
    && { fail "假链 pid=$fake 没收干净 ⇒ 下一次 selfcheck 会被自己上一条残迹判红"; bad=1; }
  # 之三：显式放行口必须**出声**（跨闸不许静默）
  rc=$(ALLOW_CONCURRENT_CHAIN=1 CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain 2>&1" 2>/dev/null)
  case "$rc" in *"ALLOW_CONCURRENT_CHAIN"*) : ;;
    *) fail "ALLOW_CONCURRENT_CHAIN=1 跨闸却一声不吭（实得「$rc」）⇒ 绕过闸门必须留下可见痕迹"; bad=1 ;;
  esac
  # 之四：**从"argv 里就带着脚本名"的那个进程里点这道闸**（没有别的链 ⇒ 必须放行）。
  # 范围要说准：这条钉的是"自我匹配类 bug 的一个形状"，
  # ⚠ 它**抓不到** 18:06 那次真实误拒——我把 ppid 过滤摘掉后这一条照样绿（做过破坏验证才知道）。
  #    那次误拒的成因仍未定，靠的是拒绝行里新加的 `ps` 现场去抓下一次，不是靠这条。
  rc=$(CHAIN_TREE="$tree" bash -c 'exec -a perf_wait_window.sh bash -c "source '"$lib"'; refuse_second_chain; echo OK"' 2>/dev/null)
  [ "$rc" = "OK" ] \
    || { fail "以排程器自身的 argv 形状调用时被自我误判（实得「$rc」）⇒ 闸会拒掉自己这一批"; bad=1; }
  [ "$bad" = "0" ] && ok "链闸双向成立：无链放行 / 同树假链被点名拒跑 / 跨闸必须出声 / 按真实 argv 形状调用时不误伤（拒绝行自带 ps 现场）"
}

selfcheck_path_display_keeps_the_tail() {  # selfcheck_path_display_keeps_the_tail <outdir>
  # 57) 归属行的有界显示。触发事件：09-24 21:35 `cut -c1-100` 把
  #     `.../MacOS/TcoderMonitor` 切成 `.../MacOS/Tcoder`，我照着那行查了三分钟「是不是测错了实例」。
  local long clipped shortp
  long="/Users/one/Documents/Tcoder/.worktrees/some-fairly-long-tree-name/TcoderMonitor/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
  declare -f path_for_display >/dev/null \
    || source "$(dirname "${BASH_SOURCE[0]}")/perf_chain_guard.sh"
  clipped=$(path_for_display "$long")
  case "$clipped" in
    *TcoderMonitor) : ;;
    *) fail "长归属行把文件名切掉了（实得「$clipped」）⇒ 读者会以为被测的是另一个可执行文件"; return ;;
  esac
  if [ "${#clipped}" -gt 110 ]; then
    fail "显示长度失控（${#clipped} 字符）⇒ 有界性本来就是这行存在的理由"
    return
  fi
  # 反向：短路径必须**一字不改**（显示函数只能裁长度，不能裁内容）
  shortp="/a/b/Tcoder.app"
  if [ "$(path_for_display "$shortp")" != "$shortp" ]; then
    fail "短路径被改了形（实得「$(path_for_display "$shortp")」）⇒ 显示层不许动内容"
    return
  fi
  ok "归属行两头都有牙：长路径保住结尾的文件名且不失控、短路径一字不改"
}

selfcheck_chain_message_names_the_compared_tree() {  # selfcheck_chain_message_names_the_compared_tree <outdir>
  # 58) 拒人的那一行必须印它**实际比对**的那个值，并且 `is_ours` 要双向。
  # 触发事件（09-25 02:09，t14 整批被拒）：消息头用的是 `${CHAIN_TREE:-$PWD}` ⇒ 印出来是子目录
  #   `…/TcoderMonitor`，而比对用的是仓库根 `…/perf-base`。**同一件事两个数**，
  #   我照着印出来的那个数读成"两棵树本来就不等 ⇒ 这道闸误拒"，还把这个读法写成代码注释里的结论，
  #   活了好几个小时才被推翻（#61）。修法是印与比共用 `chain_tree`，判据钉的是"这两处必须同形"。
  local lib tree bad=0 printed msg parent
  lib="$(dirname "${BASH_SOURCE[0]}")/perf_chain_guard.sh"
  [ -f "$lib" ] || { fail "没有 $lib —— 这道闸搬了家就得同步搬反例"; return; }
  tree=$(cd "$(dirname "$0")/../.." && git rev-parse --show-toplevel)
  printed=$(CHAIN_TREE="$tree" bash -c "source '$lib'; chain_tree" 2>/dev/null)
  [ "$printed" = "$tree" ] \
    || { fail "chain_tree 没原样交回显式给的树（实得「$printed」）⇒ 印与比又要分叉了"; return; }
  ( cd "$tree" && exec bash -c 'exec -a perf_wait_window.sh sleep 5' ) >/dev/null 2>&1 &
  local fake=$!
  sleep 1
  msg=$(CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain" 2>&1)
  kill -TERM "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
  case "$msg" in
    *"与本树 $tree 同树"*) : ;;
    *) fail "拒人行没印它比对的那棵树（首行实得「$(printf '%s' "$msg" | head -1 | cut -c1-60)」）"; bad=1 ;;
  esac
  # 之二：列出的那一行必须以「树=<比对值>␣␣」开头。为什么用两个空格当分隔来判：**坏的形状正好差在这里**——
  #   `clashing_chains` 是三段制表符分隔，若消息端只用两个变量接，剩下的现场列会被粘进 `tree`，
  #   打印出来就是「树=<路径><TAB>ppid=…」⇒ 判"路径后面紧跟制表符"比判"路径后面还有字"更准，也更难被凑。
  case "$msg" in
    *"树=$tree  "*) : ;;
    *) fail "列出的那行树与比对值不同形（比对「$tree」，消息里找不到「树=<它>␣␣」那一行）⇒ 读者按消息去比永远比不中"
       bad=1 ;;
  esac
  bash -c "source '$lib'; is_ours \$\$" \
    || { fail "is_ours 不认自己 ⇒ 每条链都会把自己算成对手，这道闸就恒拒"; bad=1; }
  parent=$(bash -c "ps -o ppid= -p \$\$ | tr -d ' '")
  if bash -c "source '$lib'; is_ours '$parent'"; then
    fail "is_ours 把自己的**父进程**也算成自己人 ⇒ 真链会被放过（双向的另一半）"
    bad=1
  fi
  [ "$bad" = "0" ] && ok "拒人行印的就是比对的那棵树（消息与判定同形）；is_ours 双向：自己算、父进程不算"
}
