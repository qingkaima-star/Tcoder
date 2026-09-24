#!/bin/bash
# =============================================================================
# perf_selfcheck_trap.sh —— 反例块：trap **到不到得了**（而不是"有没有 trap 这一行"）。
# 由 `perf_selfcheck.sh` 的 for 那一行 source 进来（不要单独执行：它只定义函数）。
#
# 为什么单独成第 7 块：宿主 `perf_selfcheck_launchers.sh` 已经 396/400 行，按「拆，不抬线」搬出来；
# 更要紧的是层次不同——第 29 项是**文本级**审计（`perf_launcher_audit.sh` 现扫形状：有没有 kill、有没有 trap），
# 而这条是**行为级**：真起子进程去量"TERM 之后多久收尾"。
#
# 触发事件（09-25 06:44，我自己刚写的新棒被自己的判据放过了一次）：
#   `perf_run_batch.sh` 有 trap、审计表那一格印着「kill=有 trap=有」，全绿；
#   而它预热用的是 `sleep "${WARMUP_SECONDS:-200}"` —— TERM 之后 **12 秒实例还在场**
#   （bash 的 trap 要等当前那条前台命令返回才执行）。也就是说：文本级审计在这里必然瞎，
#   而 §BM 那条"杀链会杀到下一条链的实例"的坑，靠的正是"收尾会迟到"这件事。
# ⚠ 射程说清楚：`sleep "$secs"`（值来自参数、没有默认值）这类**文本判不了**，
#   这一项只判"字面量或 `${VAR:-默认}` 大于一片"的形状；其余靠调用侧统一走 `nap`。别把它读成"全都管到了"。
# =============================================================================

selfcheck_long_sleep_defers_the_trap() {  # selfcheck_long_sleep_defers_the_trap <outdir>
  # 59) 行为反例＋正例：单发长 sleep 会把 trap 拖过一整窗；分片睡在 8 秒内收到。
  local out="$1" bad=0 slow fast sp fp
  slow="$out/trap_long.txt"; fast="$out/trap_chunked.txt"
  bash -c 'trap "echo caught > \"$1\"; exit" TERM; sleep 40' _ "$slow" >/dev/null 2>&1 &
  sp=$!
  sleep 1; kill -TERM "$sp" 2>/dev/null; sleep 3
  if kill -0 "$sp" 2>/dev/null; then
    ok "反例形状成立：单发长 sleep 里 trap 被拖住（这正是长 sleep 不许留在有 trap 的棒里的物理依据）"
    kill -9 "$sp" 2>/dev/null; wait "$sp" 2>/dev/null
  else
    fail "长 sleep 的那一支竟然在 3 秒内退了 ⇒ 这台机器的 bash 不需要分片睡；这一项的前提变了，去看语义再改判据"
    bad=1
  fi
  bash -c 'trap "echo caught > \"$1\"; exit" TERM; n=40; while [ "$n" -gt 0 ]; do sleep 1; n=$((n - 1)); done' _ "$fast" >/dev/null 2>&1 &
  fp=$!
  sleep 1; kill -TERM "$fp" 2>/dev/null
  for _ in 1 2 3 4 5 6 7 8; do [ -s "$fast" ] && break; sleep 1; done
  [ -s "$fast" ] || { fail "分片睡也没在 9 秒内收尾（实得「$(ls -l "$fast" 2>/dev/null)」）⇒ 收尾纪律不成立"; bad=1; }
  wait "$fp" 2>/dev/null
  [ "$bad" = "0" ] && ok "trap 的时效性两半都验到：长 sleep 确实拖住（反例）、分片睡 8 秒内确实收尾（正例）"
}

selfcheck_trapped_scripts_have_no_long_sleep() {  # selfcheck_trapped_scripts_have_no_long_sleep <outdir>
  # 60) 有 trap 的 `perf_*.sh` 里不许留"能睡过一整窗"的 sleep：字面量 >30，或 `${VAR:-默认}` 的默认值 >30。
  # ⚠ 两条自己踩过的坑都写在这里，免得下一个人重踩：
  #   · **行尾注释要先剥掉**再匹配——本文件与 `perf_run_batch.sh` 的注释里就写着
  #     `为什么不用一条 sleep 400` / `sleep "${WARMUP_SECONDS:-200}"`，不剥就是自己判自己红（盲区第 27 类的亲戚：
  #     提示是断言不是观测，判据也一样：扫到注释里的字面量不等于代码里有一处）；
  #   · 报红必须走 `fail`。第一版这里用 `printf … >&2`，结果这一项**既没 ok 也没 fail**，
  #     被"每项必须出声"那条判据（第 33 项）当场判成"一声不吭"——被跳过的判据比红的更危险。
  local dir bad=0 f hits names=""
  dir="$(dirname "${BASH_SOURCE[0]}")"
  for f in "$dir"/perf_*.sh; do
    [ -f "$f" ] || continue
    grep -qE '^[[:space:]]*trap .* (INT|TERM)' "$f" || continue
    hits=$(sed -e 's/#.*//' "$f" | grep -nE 'sleep[[:space:]]+([3-9][0-9]|[0-9]{3,})|sleep[[:space:]]+"?\$\{[A-Za-z_]+:-([3-9][0-9]|[0-9]{3,})')
    if [ -n "$hits" ]; then
      printf '!! %s 有 trap 却留着长 sleep（剥掉行尾注释之后仍命中）：\n%s\n' "$(basename "$f")" "$(printf '%s\n' "$hits" | head -3)" >&2
      names="$names $(basename "$f")"
      bad=1
    fi
  done
  if [ "$bad" = "1" ]; then
    fail "这些带 trap 的棒里有长 sleep，trap 会被拖到它返回之后：$names"
  else
    ok "带 trap 的 perf_ 脚本里没有长 sleep（要长等就走 nap 分片，行为证据见第 59 项）"
  fi
}
