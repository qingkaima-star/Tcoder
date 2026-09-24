#!/bin/bash
# perf_switch.sh —— `switch` 档（逐页冷启动，答 T4）的实现，从 `perf_harness.sh` 搬出。
#
# 为什么搬：本仓 ≤400 行口径的分母**含 .sh**，而 `perf_harness.sh` 今晚因为
# "rc 要如实传出 + meta 要记输入来源 + 收尾要做磁盘卫生"三件事长到 411 行。
# 这个文件里明写过一次教训：**搬出去才是修复，拧阈值不是**。
# 与 `perf_selfcheck.sh` 同一做法：由 harness 在同一进程里 source 进来，
# 所以 $SCRATCH / $TEMPLATE_LAUNCH / $SECONDS_LAUNCH 这些全局量继续可见、口径不变。
#
# 【为什么 `switch_page_list` 也从 harness 搬进来】自测要能**单独**调它验两个方向
# （合法页名要过、名册外的页名要当场红）。住在 harness 里就只能整档 source，
# 而那是会真去跑一次测量的脚本 ⇒ 判据只能挂在"能被裸 source 的文件"里（与第 22 项同一条规矩）。

switch_record_page() {  # switch_record_page <page> <dir> <sandbox>：一页的全流程（录制 + 导表 + 落 meta）
  local page="$1" dir="$2" sandbox="$3"
  # 正确做法照抄 capture_pages_isolated.sh：TCODER_SUPPORT_DIR 指到自己的沙箱，
  # -ApplePersistenceIgnoreState YES 禁掉窗口恢复，否则第二页起拍到的是第一页的窗口状态。
  prepare_sandbox "$sandbox" "$PWD"
  # 【逐页写测量环境】这一档此前**一个环境量都不落盘**（页级 meta 只有 page/pid/first_frame_ms/window_seen），
  # 后果是现证：2026-09-23 九页量出 2.1~2.6 s，而"这是代码还是机器忙"只能靠我手边三次 `uptime` 快照去猜（§AL）。
  # 取数与判定一律走 `preflight_context` 那把已有的尺（第三参 `launch` 只跳过"前台/在屏"两维——
  # 写上下文那一刻窗口还不存在，不是放宽）；不合格它会当场落 REFUSED 并退，一趟脏数都采不下来。
  preflight_context "$dir" "" launch || die "第 $n 页的环境不合格 ⇒ 不采数（REFUSED 已落在 $dir；同一台机器，后面的页不会自己变好）"
  run rm -rf "$dir/launch.trace"
  local t0 t1
  t0=$(python3 -c 'import time;print(time.time())')
  # xctrace 自己的选项**必须写在 `--launch --` 之前**：`--` 之后的东西整段交给被启动的进程，
  # 所以旧写法把 `--time-limit/--output/--no-prompt/--quiet` 全喂给了 App ——
  # 结果 trace 用默认名掉在仓库里（九个 .trace 目录），页目录空、九页全"未覆盖"，
  # 而退出码仍是 0。实测抓到于 2026-09-21 15:17。
  xcrun xctrace record --template "$TEMPLATE_LAUNCH" \
    --env "TCODER_SUPPORT_DIR=$sandbox" \
    --time-limit "${SECONDS_LAUNCH}s" --output "$dir/launch.trace" --no-prompt --quiet \
    --launch -- "$PERF_BIN" -ApplePersistenceIgnoreState YES -selectedDetailSection "$page"
  t1=$(python3 -c 'import time;print(time.time())')
  # 首帧**不能**用墙钟轮询量。原实现的顺序是：t0 → `xctrace record --launch
  # --time-limit 10s`（阻塞满 10 s）→ 才去轮询窗口出现 → `first = now - t0`，
  # 于是 `first_frame_ms` 恒 ≥ 录制时长，量到的是"录制跑了多久"，不是首帧。
  # 时长一律从 trace 的 life-cycle-period 派生；探测只回答"窗口到底出现过没有"。
  local pid window_seen="未探测到实例"
  pid=$(pgrep -n -x TcoderMonitor 2>/dev/null || true)
  [ -n "$pid" ] && { [ -n "$(winlist_probe "$pid")" ] && window_seen="有在屏窗口" || window_seen="无在屏窗口"; }
  export_table "$dir/launch.trace" "life-cycle-period" "$dir"
  export_table "$dir/launch.trace" "hitches" "$dir"
  xcrun xctrace export --input "$dir/launch.trace" --toc --output "$dir/toc.xml" >/dev/null 2>&1
  python3 "$TRACE_REPORT" lifecycle "$dir/life-cycle-period.xml" \
    --json "$dir/life-cycle-period.json" 2>/dev/null | sed 's/^/    /'
  local launch_total="未观测到"
  if [ -s "$dir/life-cycle-period.json" ]; then
    # 取 ready_ms（剔除运行期尾巴之后的"启动到就绪"），**不是 total_ms**：
    # total_ms 里含 App 活到窗口结束那一段，拿它当首帧会让 T4 永远不可能达标。
    launch_total=$(python3 -c "import json;l=json.load(open('$dir/life-cycle-period.json'));print(l.get('ready_ms') if l.get('ready_ms') is not None else '未观测到')" 2>/dev/null \
                   || echo "未观测到")
  fi
  meta_write "$dir" "page=$page" "pid=$pid" \
    "first_frame_ms=${launch_total}" "first_frame_source=life-cycle-period ready_ms(已剔除运行期尾巴)" \
    "window_seen=$window_seen" \
    "record_wall_s=$(python3 -c "print('%.1f' % ($t1-$t0))")"
  echo "    启动到就绪(trace)=${launch_total} ms；$window_seen；细表见 $dir/life-cycle-period.xml"
  switch_finish_page "$dir" "$pid"
}
cmd_switch() {
  local out="${1:-$SCRATCH/tcoder-perf-$REV}"
  echo "==> switch 档：逐页冷启动（自带沙箱，不写用户的 defaults）"
  [ -x "$PERF_BIN" ] || die "找不到被采二进制 $PERF_BIN（先跑 ./scripts/build_app.sh release，或传 PERF_BIN=）"
  local pages
  pages=$(switch_page_list) || die "取不到 SECTIONS：scripts/capture_pages_isolated.sh 不在了？"
  meta_write "$out" "mode=switch" "binary=$PERF_BIN" "launch_seconds=$SECONDS_LAUNCH" "pages=$pages"

  # 冷启动首帧最容易被"别人的心跳"污染：另一个实例每 1.5s 也在打主线程，
  # 首帧时间会莫名变长。所以默认要求机器上**一个实例都没有**。
  switch_refuse_coexist

  local n=0
  while IFS= read -r page; do
    [ -n "$page" ] || continue
    n=$((n + 1))
    # 目录名里的空格换成下划线（页名本身照原样传给 App，只有路径要规矩）
    local slug="${page// /_}"
    local sandbox="$out/sandbox/$(printf '%02d' "$n")-$slug" dir="$out/pages/$(printf '%02d' "$n")-$slug"
    mkdir -p "$dir"
    echo "--> $n) $page"
    if [ "$DRY_RUN" = "1" ]; then
      echo "    \$ TCODER_SUPPORT_DIR=$sandbox $PERF_BIN -ApplePersistenceIgnoreState YES -selectedDetailSection $page"
      echo "    \$ xctrace record --template \"$TEMPLATE_LAUNCH\" --time-limit ${SECONDS_LAUNCH}s --output … --launch -- <bin> …"
      continue
    fi
    switch_record_page "$page" "$dir" "$sandbox"
    sleep 2
  done <<< "$pages"
  [ "$DRY_RUN" = "1" ] && { echo "（DRY_RUN=1：一条命令都没执行）"; return 0; }
  echo "==> 逐页汇总"
  python3 "$TRACE_REPORT" switches "$out/pages" | tee "$out/switch-summary.txt"
  echo "输出目录: $out"
}

switch_page_list() {  # → 每行一个页名（**必须按行遍历**）
  # 旧实现在这里 `tr '\n' ' '`，配合下面的 `for page in $pages` 做词分割 ——
  # 而页名里有带空格的：`Git 洞察` 被切成 "Git" + "洞察" 两页，
  # 九页扫描实际只覆盖 8 页，还有一页被用错名字起了一次 App。
  # 实测抓到于 2026-09-21 14:53（日志里同时出现 `--> 4) Git` 与 `--> 5) 洞察`）。
  local known; known=$(sections)
  [ -n "$known" ] || return 1          # 取不到 SECTIONS 由调用方那句 die 说话，这里不重复一条话术
  [ -n "${PAGES:-}" ] || { printf '%s\n' "$known"; return 0; }
  # 【自定义清单必须逐个对回名册】2026-09-23 做 T4 的 A/B 时踩的第二条：
  # 按行遍历只解决了"名册自己不被拆"，`PAGES` 却是**整串当一个页名**——
  # `PAGES="总览 性能监控"` 建出 `pages/01-总览 性能监控/`，启动参数成了不存在的页，
  # 于是 SwiftUI 静默回落到默认页，四趟量的全是总览，而屏幕上一个字都没说"第二页没测"。
  # 页名含空格是本产品的常态，所以分隔符只能是换行；认不出名册的页名**当场判败**，
  # 不许让默认页替它背书（一条会静默改写测量对象的参数，比报错危险）。
  local p bad=""
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    grep -qxF -- "$p" <<< "$known" || bad="$bad「$p」"
  done <<< "$PAGES"
  if [ -n "$bad" ]; then
    echo "!! PAGES 里有 App 不认的页名：$bad" >&2
    echo "   不存在的页会被 SwiftUI 静默回落到默认页 ⇒ 那批读数其实只测了默认页，没有资格答九页里的任何一页。" >&2
    echo "   PAGES 按**换行**分隔（页名可以含空格），名册现量：$(printf '%s' "$known" | tr '\n' ' ')" >&2
    return 1
  fi
  printf '%s\n' "$PAGES"
}
