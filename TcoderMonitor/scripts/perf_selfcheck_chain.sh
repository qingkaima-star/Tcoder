#!/bin/bash
# perf_selfcheck_chain.sh —— 反例块：链的归属显示与「同树只许一条测量链」这道闸。
# 由 `perf_selfcheck.sh` 的 for 那一行 source 进来（不要单独执行：它只定义函数，不会自己跑）。
#
# 为什么单独一块（第 6 块）：这两条判据的宿主是 `perf_chain_guard.sh`，
# 而它的函数**只有 source 才点得动**——排程器本体是不能 source 的（source 它就开始等窗口）。
# 判据本体搬去 `_launchers` 那块也不合适：那块量的是"谁起了实例、收尾归谁"，
# 这块量的是"同一棵树能不能起两条链、以及归属行看不看得见真名"。

selfcheck_chain_guard_and_path_display() {  # selfcheck_chain_guard_and_path_display <outdir>
  # 56) 同树链闸 + 57) 归属行的有界显示。两条都是 09-24 现场烧出来的，不是假想题：
  #     §BM 那一批是被"trap 等 sleep 返回 ⇒ 新链的实例被旧链收养掉"烧的；
  #     归属行那一次是 `cut -c1-100` 把 `TcoderMonitor` 切成 `Tcoder`，我照着那行查了三分钟"测错实例"。
  local lib bad=0 fake tree out rc clash long shortp clipped
  lib="$(dirname "${BASH_SOURCE[0]}")/perf_chain_guard.sh"
  [ -f "$lib" ] || { fail "没有 $lib —— 这道闸搬了家就得同步搬反例"; return; }
  declare -f refuse_second_chain >/dev/null || source "$lib"
  bad=0
  tree=$(cd "$(dirname "$0")/../.." && git rev-parse --show-toplevel)
  out="$1/chain"
  mkdir -p "$out" || { fail "建不了反例目录 $out"; return; }

  # (56 之一) 场上没有别的链 ⇒ 必须放行（反向：恒拒的闸看起来最尽职，所以这条不可省）
  if [ -n "$(pgrep -f 'perf_wait_window\.sh' 2>/dev/null)" ]; then
    fail "反例前提不成立：现场已有一条 perf_wait_window 在跑，这一项判不了（等它退出再跑，别改成跳过）"
    return
  fi
  rc=$(CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain; echo OK" 2>/dev/null)
  [ "$rc" = "OK" ] || { fail "场上没有别的链却被拒（实得「$rc」）⇒ 这道闸成了恒拒，等价于永远量不了"; bad=1; }

  # (56 之二) 造一条 cwd 在本树里的假链 ⇒ 必须当场拒，并把 pid 与树点名出来
  ( cd "$tree" && exec bash -c 'exec -a perf_wait_window.sh sleep 6' ) >/dev/null 2>&1 &
  fake=$!
  sleep 1
  clash=$(CHAIN_TREE="$tree" bash -c "source '$lib'; clashing_chains" 2>/dev/null)
  case "$clash" in
    *"$fake"*) : ;;
    *) fail "假链 pid=$fake 没被认出来（实得「$clash」）⇒ 归属判据看不见自己起的链，闸等于没装"; bad=1 ;;
  esac
  kill -TERM "$fake" 2>/dev/null
  wait "$fake" 2>/dev/null
  [ -z "$(pgrep -f 'perf_wait_window\.sh' 2>/dev/null)" ] \
    || { fail "假链没收干净 ⇒ 下一次 selfcheck 会被自己上一条残迹判红"; bad=1; }

  # (56 之三) 显式放行口必须**出声**（不许静默跨闸）
  rc=$(ALLOW_CONCURRENT_CHAIN=1 CHAIN_TREE="$tree" bash -c "source '$lib'; refuse_second_chain 2>&1" 2>/dev/null)
  case "$rc" in *"ALLOW_CONCURRENT_CHAIN"*) : ;;
    *) fail "ALLOW_CONCURRENT_CHAIN=1 跨闸却一声不吭（实得「$rc」）⇒ 绕过闸门必须留下可见痕迹"; bad=1 ;;
  esac

  # (57 之一) 长路径必须**保住结尾的文件名**（这是这次踩的格）
  long="/Users/one/Documents/Tcoder/.worktrees/some-fairly-long-tree-name/TcoderMonitor/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"
  clipped=$(path_for_display "$long")
  case "$clipped" in *TcoderMonitor) : ;;
    *) fail "长归属行又把文件名切掉了（实得「$clipped」）⇒ 读者会以为被测的是另一个可执行文件"; bad=1 ;;
  esac
  [ "${#clipped}" -le 110 ] \
    || { fail "显示长度失控（${#clipped} 字符）⇒ 这行的有界性本来就是它存在的理由"; bad=1; }
  # (57 之二) 短路径必须**一字不改**（不许为了整齐加省略号，那是把读数改形）
  shortp="/a/b/Tcoder.app"
  [ "$(path_for_display "$shortp")" = "$shortp" ] \
    || { fail "短路径被改了形（实得「$(path_for_display "$shortp")」）⇒ 显示函数只能裁长度，不能裁内容"; bad=1; }

  [ "$bad" = "0" ] && ok "链的归属显示与「同树只一条链」都能双向判：无链放行 / 同树假链被点名拒跑 / 跨闸出声 / 长路径保住文件名 / 短路径一字不改"
}
