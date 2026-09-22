#!/bin/bash
# perf_pulse.sh —— `perf_harness.sh pulse` 那一档的实现，由它在 dispatch 时 **source** 进来。
#
# 为什么单独一个文件：本仓 ≤400 行棘轮（SourcesSizeAuditTests）的分母含 `.sh`，
# 加完 pulse 之后宿主涨到 423 行。**拆，不挂账**——挂账清单是"只减不增"的，
# 往里加一条等于给自己开免检口（这一轮已经因此被 ≤800 那条判红过两次）。
#
# 这一档存在的理由（详见工单 §M）：用户口径是"p95 帧间隔 ≤ 8.4 ms"，那是**全部帧**的分位数，
# 而 xctrace 的 hitches 表只列超预算的帧 ⇒ 逐帧记间隔的 FramePulse 是唯一直接仪器。
# 它依赖宿主的 $REV / $DIRTY / $SCRATCH / $PERF_BIN / $PULSE_REPORT 与
# quiescence_probe / quietest_seconds / probe_usable / human_input_in_window /
# ensure_synth_scroller / start_synth_scroller / die / require_disk_headroom 这些同进程的量。
# =============================================================================

pulse_context_note() {  # 这份读数的**条件**全部现采，不许抄上一次的说法
  local others; others=$(pgrep -x TcoderMonitor 2>/dev/null | wc -l | tr -d ' ')
  printf '条件：档=pulse（进程内帧脉冲） rev=%s dirty=%s 输入=synth@%sms ≈%dHz，非真人手感 本机 Tcoder 实例数=%s（含本实例） 起法=直接 exec，不是 LaunchServices open\n' \
    "$REV" "$DIRTY" "${SYNTH_GAP_MS:-8}" "$((1000 / ${SYNTH_GAP_MS:-8}))" "$others"
}

cmd_pulse() {  # pulse 档：边投合成滚动边读**帧间隔 p95** —— T1 那条判据的直接对象
  # 为什么要单独一档：xctrace 的 hitches 表只列**超预算**的那些帧，
  # 而验收口径是"p95 帧间隔 ≤ 8.4 ms"——那是**全部帧**的分位数，hitches 表里没有这一列。
  # FramePulse 在 CVDisplayLink 回调里逐帧记间隔，是这条判据唯一的直接仪器。
  local secs="${1:-12}"
  local out="${2:-$SCRATCH/tcoder-perf-$REV-pulse-$(date +%H%M%S)}"
  require_disk_headroom
  mkdir -p "$out/sandbox"
  # shellcheck source=/dev/null
  declare -f ensure_synth_scroller >/dev/null || source scripts/perf_probes.sh
  ensure_synth_scroller || die "合成输入器准备失败 ⇒ pulse 档一趟都不跑（不拿 idle 数冒充交互期）"
  # 【不抢人的鼠标】这一档会 CGWarp 光标到被测窗口再投滚动，人在用机器时这是打扰。
  # 所以先问一次静默探针：**量不到也当"有人在"**（宁可不跑，不蒙一次）。
  local q; q=$(quietest_seconds "$(quiescence_probe)")
  probe_usable "$q" || die "静默探针取不到（拿到「${q:-空}」）⇒ 不知道有没有人在动，不投滚动"
  [ "$(human_input_in_window "$q" "${PULSE_WANT_QUIET:-15}")" = "窗口内没人" ] \
    || die "人手 ${q}s 前还在动（要 ≥${PULSE_WANT_QUIET:-15}s）⇒ 这一档会抢光标，不抢人"
  local file="$out/framepulse.txt"
  echo "==> pulse 档：自己起一个带探针的实例，滚 ${secs}s（产物 $out）"
  TCODER_PERF_PROBE=1 TCODER_PERF_OUT="$file" TCODER_SUPPORT_DIR="$out/sandbox" \
    "$PERF_BIN" >/dev/null 2>&1 &
  local pid=$!
  trap 'kill -TERM "$pid" 2>/dev/null || true' EXIT INT TERM
  sleep 3   # 等窗口出来再投事件，否则"投了但其实没滚动"，那是一份假样本
  # 秒数走 SYNTH_SECS：start_synth_scroller 的第 2 个位置参数**不是**秒数（它内部按
  #   <秒> <pid> <像素> <间隔> 传给投事件器），我第一版按位置传，结果它照默认投了 95 秒，
  #   比本档生命期长 80 秒 ⇒ 实例都没了还在往屏幕上投滚动事件。这类"参数被静默忽略"的错，
  #   只能靠把"实际用了多久"打出来才会露出来，所以下面 echo 里带上秒数。
  SYNTH_SECS=$((secs + 4)) start_synth_scroller "$pid" \
    || { kill -TERM "$pid" 2>/dev/null || true; die "投事件器起不来 ⇒ 本档作废"; }
  sleep "$secs"
  pulse_context_note | tee "$out/pulse-context.txt"
  kill -TERM "$pid" 2>/dev/null || true
  trap - EXIT INT TERM
  [ -s "$file" ] || die "FramePulse 没产出 ⇒ 按未覆盖处理，不许当成「0 hitch = 达标」"
  python3 "$PULSE_REPORT" "$file" --interaction
}

