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

selfcheck_chain_guard_one_per_tree() {  # selfcheck_chain_guard_one_per_tree <outdir>
  # 56) 同树只许一条测量链。触发事件是 §BM 烧掉的那一整批：
  #     trap 等 `sleep` 返回 ⇒ 旧链收尾时把新链刚起的实例按路径「收养」掉，新链整批作废。
  local lib bad=0 fake tree rc clash
  lib="$(dirname "${BASH_SOURCE[0]}")/perf_chain_guard.sh"
  [ -f "$lib" ] || { fail "没有 $lib —— 这道闸搬了家就得同步搬反例"; return; }
  tree=$(cd "$(dirname "$0")/../.." && git rev-parse --show-toplevel)
  mkdir -p "$1/chain" || { fail "建不了反例目录 $1/chain"; return; }
  bad=0
  # 反例前提：现场必须没有真的链（有就**判红**，不许悄悄 skip——skip 是一项不会痛的假绿）
  if [ -n "$(pgrep -f 'perf_wait_window\.sh' 2>/dev/null)" ]; then
    fail "现场已有一条 perf_wait_window 在跑，这一项判不了 ⇒ 判红而不是跳过：等它退出再跑"
    return
  fi
  # 之一：场上没有别的链 ⇒ 必须放行（恒拒的闸看起来最尽职，所以这条不可省）
  rc=$(CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain; echo OK" 2>/dev/null)
  [ "$rc" = "OK" ] || { fail "没有别的链却被拒（实得「$rc」）⇒ 这道闸恒拒，等价于永远量不了"; bad=1; }
  # 之二：造一条 cwd 在本树里的假链 ⇒ 必须当场拒，并把 pid 与树点名出来
  ( cd "$tree" && exec bash -c 'exec -a perf_wait_window.sh sleep 6' ) >/dev/null 2>&1 &
  fake=$!
  sleep 1
  clash=$(CHAIN_TREE="$tree" bash -c "source '$lib'; clashing_chains" 2>/dev/null)
  case "$clash" in
    *"$fake"*) : ;;
    *) fail "假链 pid=$fake 没被认出来（实得「$clash」）⇒ 归属判据看不见自己起的链，闸等于没装"; bad=1 ;;
  esac
  kill -TERM "$fake" 2>/dev/null; wait "$fake" 2>/dev/null
  [ -z "$(pgrep -f 'perf_wait_window\.sh' 2>/dev/null)" ] \
    || { fail "假链没收干净 ⇒ 下一次 selfcheck 会被自己上一条残迹判红"; bad=1; }
  # 之三：显式放行口必须**出声**（跨闸不许静默）
  rc=$(ALLOW_CONCURRENT_CHAIN=1 CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain 2>&1" 2>/dev/null)
  case "$rc" in *"ALLOW_CONCURRENT_CHAIN"*) : ;;
    *) fail "ALLOW_CONCURRENT_CHAIN=1 跨闸却一声不吭（实得「$rc」）⇒ 绕过闸门必须留下可见痕迹"; bad=1 ;;
  esac
  [ "$bad" = "0" ] && ok "链闸双向成立：无链放行 / 同树假链被点名拒跑 / 跨闸必须出声（假链已收干净）"
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
