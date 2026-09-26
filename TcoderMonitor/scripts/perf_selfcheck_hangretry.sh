# selfcheck 反例分块：**挂死补试那一族**（判废类型学、按批封顶、挂死计数抹不掉、meta 键双向）。
# 为什么单独成块（2026-09-27 卷十二 §187）：`perf_selfcheck_launchers.sh` 写到 **399/400**——
# 只差一行就红。口径同上：**拆，不抬线**，整族连着 `hang_retry_*` 三个帮手一起搬，一字未改。
# shellcheck shell=bash

hang_retry_retire() {  # hang_retry_retire <pid…>：发 TERM 并**确认真的退场**（最多 3 s）
  # 为什么要轮询而不是发完信号就算：`kill -0` 在"信号已投递、进程还没死/还没被回收"那一瞬
  # 仍然成功——第一版在这里没有等待，把自己的收尾判成了一条红。等待有上限，
  # 且只认自己记下的那几个 pid（不 pgrep 名字：别人的同名进程不该算到我头上）。
  local h tick alive=""
  for h in "$@"; do kill -TERM "$h" 2>/dev/null || true; done
  for tick in 1 2 3 4 5 6; do
    alive=""
    for h in "$@"; do kill -0 "$h" 2>/dev/null && alive="$alive $h"; done
    [ -n "$alive" ] || break
    sleep 0.5
  done
  for h in $alive; do
    fail "持有者 pid=$h 退了信号却没死 ⇒ 本项自己成了漏实例的那一个"
    bad=1
  done
}

hang_retry_make_refused() {  # 造三份真路径产出的判废现场。读、写调用方的 `bad`（同 `launcher_hygiene_row` 的分工）
  local fx="$1" path0="$PATH" out h holders=""
  mkdir -p "$fx/bin" "$fx/plain" "$fx/with" "$fx/without"
  printf '%s\n' '#!/bin/bash' \
    'case "${FAKE_XC:-ok}" in' \
    '  hang) trap "exit 0" TERM; while :; do sleep 0.2; done ;;' \
    '  die)  kill -TERM "${FAKE_TARGET:-0}" 2>/dev/null; sleep 0.3 ;;' \
    '  *)    exit 0 ;;' \
    'esac' > "$fx/bin/xcrun"
  chmod +x "$fx/bin/xcrun"
  PATH="$fx/bin:$PATH"; export PATH
  local RECORD_SLACK_S=2 RECORD_POLL_S=1
  out="$fx/hang"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; holders="$holders $PID"; FAKE_XC=hang export FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1
  out="$fx/gone"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; holders="$holders $PID"
  FAKE_TARGET="$PID" export FAKE_TARGET; FAKE_XC=die export FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1
  out="$fx/notables"; mkdir -p "$out"
  ( require_covered_evidence "$out" ) >"$out/a.txt" 2>&1
  # 第四类：闸门在**开录之前**就把这一趟拒了 ⇒ 让真闸门自己写那句 REFUSED。
  # `LOAD_MAX=-1` 是判据自己的公开出口（`load_bar` 认它），比"没有负载"严格得多 ⇒ 必然不合格。
  # 抄那句文案就等于再造一份第二入口：阈值一改，反例还拿着旧句子自证。
  out="$fx/gate"; mkdir -p "$out"
  ( LOAD_MAX=-1 preflight_context "$out" "$$" ) >"$out/a.txt" 2>&1 || true
  unset FAKE_XC FAKE_TARGET
  # 自己起的持有者必须自己退（AGENTS 2.1）。**本项第一版就是没退干净**：那个 disown 掉的
  # `sleep 300` 占着 stdout 管道，外面的 `| tail` 永远等不到 EOF，整条反例跑起来像挂死。
  # 按 pid 精确核对，不 pgrep 名字——别人的同名进程不该算到我头上。
  hang_retry_retire $holders
  PATH="$path0"; export PATH
}

hang_retry_type_checks() {  # 判废类型学 + 补试判据：三个方向各判一次。读、写调用方的 `bad`
  local fx="$1" kind
  kind=$(refusal_kind "$fx/hang")
  [ "$kind" = "hang" ] \
    || { fail "真挂死路径产出的 REFUSED 被判成「$kind」⇒ 判废文案与这条判据已分叉，补试从此不触发"; bad=1; }
  [ "$(HANG_RETRIES_USED=0 attempt_verdict "$fx/hang" 1)" = "retry" ] \
    || { fail "挂死、预算未用、rc=1 三样凑齐却不补 ⇒ #55 那条同窗补试是纸面规矩"; bad=1; }
  [ "$(HANG_RETRIES_USED=1 attempt_verdict "$fx/hang" 1)" = "slot" ] \
    || { fail "预算用完还允许再补 ⇒ 退化成「攒够可用为止」那种数据相关的停止规则"; bad=1; }
  [ "$(attempt_verdict "$fx/hang" 0)" = "slot" ] \
    || { fail "成功那一趟也去补 ⇒ 同一个窗口采两遍，两遍会被当成两批独立样本引用"; bad=1; }
  kind=$(refusal_kind "$fx/gone")
  [ "$kind" = "target_gone" ] \
    || { fail "被测进程消失被判成「$kind」⇒ 三类判废的类型学少了一类"; bad=1; }
  [ "$(HANG_RETRIES_USED=0 attempt_verdict "$fx/gone" 1)" = "slot" ] \
    || { fail "被测消失也去补试 ⇒ 补试通道扩到了「这个窗口本来就不行」那一类"; bad=1; }
  kind=$(refusal_kind "$fx/notables")
  [ "$kind" = "empty_tables" ] \
    || { fail "三张表全空被判成「$kind」⇒ 该类的文案改了而这里没跟上"; bad=1; }
  [ "$(HANG_RETRIES_USED=0 attempt_verdict "$fx/notables" 1)" = "slot" ] \
    || { fail "表全空也去补试 ⇒ 同一条通道又宽了一格"; bad=1; }
  kind=$(refusal_kind "$fx/gate")
  [ "$kind" = "context_gate" ] \
    || { fail "闸门开录前就拒跑那一类被判成「$kind」⇒ 小结只能说『不是挂死』，说不出『所以不用补』"\
              "（2026-09-25 t20 那批两次都掉进 other）"; bad=1; }
  [ "$(HANG_RETRIES_USED=0 attempt_verdict "$fx/gate" 1)" = "slot" ] \
    || { fail "根本没开录的一趟也去补试 ⇒ 补试通道又宽了一格（那类拒因与挂死无关）"; bad=1; }
  [ "$(refusal_kind "$fx/plain")" = "none" ] \
    || { fail "没有 REFUSED 的目录不判成 none ⇒ 空目录会被当成某种判废"; bad=1; }
}

hang_retry_tally_checks() {  # 挂死计数与 meta 键：两个方向都要有牙。读、写调用方的 `bad`
  local fx="$1" summary
  # 挂死计数**必须**在补试成功之后照样出声（#55 硬约束①）：否则"重试"会把这一维的
  # 失败率抹成 0——单向朝好看的计数。
  summary=$(batch_hang_summary 2 1 1)
  printf '%s\n' "$summary" | grep -q '挂死：2 趟' \
    || { fail "补试补回来一趟之后挂死计数就不见了（拿到「$summary」）⇒ 单向朝好看的计数"; bad=1; }
  printf '%s\n' "$summary" | grep -q '补回可用 1 趟' \
    || { fail "报了挂死却没报补回几趟 ⇒ 读的人无法判断这批还剩多少可用"; bad=1; }
  printf '%s\n' "$(batch_hang_summary 0 0 0)" | grep -q '0 趟' \
    || { fail "一趟都没挂却报了挂死 ⇒ 反向失准"; bad=1; }
  # `hang_recovered` 只在补试那一趟存在。⚠ 必须 **export 之后再调用**：写成
  #   `HANG_RECOVERED=1 meta_write … "$(hang_recovery_meta_arg)"` 是无效的前缀赋值——
  #   参数表里的命令替换**先于**赋值展开（第一版就这么写的，被自己这条反例当场判红）。
  ( export HANG_RECOVERED=1
    REV=x DIRTY=0 meta_write "$fx/with" "mode=idle" "$(hang_recovery_meta_arg)" )
  unset HANG_RECOVERED
  REV=x DIRTY=0 meta_write "$fx/without" "mode=idle" "$(hang_recovery_meta_arg)"
  grep -q '"hang_recovered"' "$fx/with/meta.json" \
    || { fail "补试趟没把 hang_recovered 落进 meta ⇒ 哪几份读数是补出来的，事后无从复核"; bad=1; }
  grep -q 'hang_recovered' "$fx/without/meta.json" \
    && { fail "没挂过的趟也带上了 hang_recovered ⇒ 这枚键失去区分力（写 0 冒充「没有」的形状）"; bad=1; }
}

selfcheck_hang_retry_policy() {  # 62) 挂死才补、按批封顶、挂死计数抹不掉、meta 键双向
  local fx="$1/hangretry" bad=0
  rm -rf "$fx"
  mkdir -p "$fx"
  hang_retry_make_refused "$fx"
  hang_retry_type_checks "$fx"
  hang_retry_tally_checks "$fx"
  [ "$bad" = "0" ] && ok "挂死才补、按批封顶、补试抹不掉挂死计数、meta 键两个方向都判过（真路径产出的 REFUSED）"
}

selfcheck_switch_cleanup_names_no_target() {  # selfcheck_switch_cleanup_names_no_target <outdir>
  # 67) switch 档收尾那句提示：**没有 pid 就不许叫人去退**。
  #     09-25 21:53 实跑 `switch` 六页，六页全印「请人工 Cmd+Q 这个实例 pid=」而等号后是空的
  #     （xctrace --launch 起的进程随录制结束已退，`pgrep -n` 探不到，跑完场上 0 个实例）。
  #     一句没有对象的行动指令只会让人去找一个不存在的进程；而它落进 meta 的
  #     `cleanup=人工(脚本未退出实例)` 更像把活推给人。这一格此前没有任何读者 ⇒ 错了 6/6 页也没人吵。
  local res
  res=$(bash -c '
    set -u
    d=$(mktemp -d); mkdir -p "$d/empty" "$d/held"
    source scripts/perf_switch.sh || { echo "source 失败"; exit 1; }
    meta_write() { printf "%s\n" "$*" >> "$1/meta.json"; }
    e=$(switch_finish_page "$d/empty" "" 2>&1)
    h=$(switch_finish_page "$d/held" 12345 2>&1)
    ok1=0; case "$e" in *"未探到实例"*) ok1=1 ;; esac
    case "$e" in *"请人工 Cmd+Q"*) ok1=0 ;; esac
    grep -q "cleanup=未探到实例" "$d/empty/meta.json" || ok1=0
    ok2=0; case "$h" in *"pid=12345"*) ok2=1 ;; esac
    rm -rf "$d"
    echo "${ok1}${ok2}"' 2>&1) || res="跑挂了：$(printf '%s' "$res" | tail -1)"
  [ "$res" = "11" ] \
    || { fail "switch 收尾提示两个方向没都判对（拿到「$res」，要 11＝空 pid 只说未探到、有 pid 才点名）"; return; }
  ok "switch 收尾提示两头有牙：没有 pid 就只说「未探到实例」并这样记进 meta，有 pid 才点名让人 Cmd+Q"
}
