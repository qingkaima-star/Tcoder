#!/bin/bash
# perf_winlist_probe.sh —— 「这个 pid 有没有窗口在屏上」这一支探针：稳定路径 + 缓存 + 解析。
#
# 自 `perf_probes.sh` 逐字节搬出（同一条目：`SourcesSizeAuditTests` 的 400 行口径覆盖 `scripts/**`，
# 而 09-26 加"整窗在场"那一列读数时把母文件推到 406 行 ⇒ **拆文件才是修复**，
# 改线、往挂账清单塞条目、或把文件挪出扫描面都不算）。
#
# 为什么这一族值得单独一支：它管的不是"取数"而是**取数工具的产物管理**——
# 编译一次、跨进程共享、窗口内只认已存在的产物。这三条都是踩出来的：
#   · 缓存放在 `$WINLIST_BIN` 里会随子 shell 丢失（`$(winlist_probe …)` 调的那次赋值没人认得）；
#   · 在测量窗口内现编 swiftc 会把编译耗时混进被计时的那一段；
#   · 把编译挂进 `record_bounded` 会撞上 selfcheck 第 43 项那个**故意挂死的假 `xcrun`**
#     （09-26 06:2x 实测：整条 selfcheck 挂 10 分钟）⇒ **测量路径里不许出现编译**。
# 依赖的调用方变量（$WINLIST / $SCRATCH）由 `perf_probes.sh` 在 source 之前设好。

winlist_bin_path() {  # 探针二进制的**稳定路径**（同 uid 共享一份，可被 TCODER_WINLIST_BIN 指走）
  # 为什么必须是稳定路径而不是 `…-$$`：`$$` 在子 shell 里还是父进程号，但**父 shell 拿不到子 shell 的赋值**，
  # 而 `preflight_window_state` 恰恰是被 `$(…)` 调的 ⇒ 编好的东西没人认得（2026-09-26 现抓：热身后 WINLIST_BIN 仍为空）。
  printf '%s\n' "${TCODER_WINLIST_BIN:-${TMPDIR:-/tmp}/tcoder-winlist-probe-$(id -u)}"
}
winlist_resolve() {  # 只**认已存在的**产物，绝不在此处编译 ⇒ 给"窗口内采样"这类调用方用
  local b; b=$(winlist_bin_path)
  [ -x "$b" ] && { WINLIST_BIN="$b"; return 0; }
  return 1
}
winlist_ensure_bin() {  # → 打印编译好的在屏探针二进制路径（编不出来就打印空、非零退出）
  # 只允许在**计时窗外**调它（首次编译 ~500 ms～数秒）。反面教训见本文件头第三条。
  local bin; bin=$(winlist_bin_path)
  [ -x "$bin" ] && { printf '%s\n' "$bin"; return 0; }
  local tmp="$bin.tmp.$$"
  xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
      -target arm64-apple-macos14.0 "$WINLIST" -o "$tmp" 2>/dev/null || return 1
  mv -f "$tmp" "$bin" 2>/dev/null || { rm -f "$tmp"; return 1; }
  printf '%s\n' "$bin"
}
winlist_probe() {  # winlist_probe <pid> → 有在屏窗口时打印 `窗口号|标题|宽`，否则空
  # 窗口存在性探测。**为什么先编译一次**：`xcrun swift winlist.swift` 是 JIT，实测每次 0.3 s；
  # 原来 `switch` 档把它放在"首帧轮询"里（最多 60 次），既慢又把探测开销混进了计时。
  # 编译成二进制后稳态实测 39~45 ms，且首次 ~508 ms 的 dyld 冷启动由这次预热挡在计时窗外。
  local pid="$1" bin
  if [ -z "$WINLIST_BIN" ]; then
    bin=$(winlist_ensure_bin || true)          # 计时窗外的首次调用才会真编译（稳定路径 ⇒ 跨进程认得）
    [ -n "$bin" ] || echo "    ⚠ winlist 编译失败 → 退回 JIT（单次 ~300 ms，只影响存在性探测，不影响时长口径）" >&2
    WINLIST_BIN="$bin"
  fi
  if [ -n "$WINLIST_BIN" ]; then
    "$WINLIST_BIN" "$pid" 2>/dev/null | head -1
  else
    xcrun swift "$WINLIST" "$pid" 2>/dev/null | head -1
  fi
}
