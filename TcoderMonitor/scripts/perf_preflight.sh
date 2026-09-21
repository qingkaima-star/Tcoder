#!/bin/bash
# =============================================================================
# perf_preflight.sh —— 「测量环境合不合格」这一层，由 perf_harness.sh 在装载全局量之后
# **无条件 source** 进来。**不要单独执行**：它依赖宿主的 $REV / $DIRTY / $PERF_BIN /
# $WINLIST / $WINLIST_BIN / $QUIESCE_SRC / $QUIESCE_MIN / $UUID / $DRY_RUN / $HITCH_TABLES
# 与 die / run 这些同进程的量（和 perf_selfcheck.sh 同一套路子）。
#
# 为什么搬出来（不是客套话）：本仓 ≤800 行棘轮的分母**含 `.sh`**（`SourceLanguageCatalog`
# 认 Shell）且 ceiling=0，而本 App 自扫还有一条更近的线——「巨大文件 >400 行」，
# `perf_harness.sh` 到 643 行被点名。搬出去才是修复，拧阈值不是。
#
# 搬的判据是**职责**不是行数凑数：这一层回答的是"这一批读数有没有资格被拿出来讲"
# （机器上跑着谁、被采的是 release 还是 debug、窗口在不在屏、人手静默够不够、
# 导表与 meta 怎么落盘）。idle / interact / switch / selfcheck 四档共用同一批闸门，
# 所以它必须被 source 进同一个进程——**复制一份判定就是造第二把尺子**，
# 而两把尺子并存时错的那把常在喂数据（本仓教训，一字未改地记在这里）。
# 每个函数的判据、告警文案、退出码逐字未动（脚本按 bash 函数边界比对过）。
# =============================================================================

# -----------------------------------------------------------------------------
# 页名不自己编：与 capture_pages_isolated.sh 共用一份事实来源，
# 否则两边页名漂移会让 switch 档悄悄测到不存在的页（SwiftUI 会回落到默认页）。
# -----------------------------------------------------------------------------
sections() {
  local line
  line=$(grep -m1 '^SECTIONS=(' scripts/capture_pages_isolated.sh) || return 1
  # 【按引号取，不许按空格拆】旧写法 `tr ' \n'` 会把**引号内部的空格**也当分隔符，
  # 于是 `Git 洞察` 变成 "Git" 与 "洞察" 两页：九页扫描实际只覆盖 8 页，
  # 还有一页是用错名字起的 App。实测抓到于 2026-09-21 14:57（DRY_RUN 里出现 10 行）。
  printf '%s\n' "$line" | grep -o '"[^"]*"' | sed -e 's/^"//' -e 's/"$//'
}

instance_pids() { pgrep -x TcoderMonitor 2>/dev/null || true; }

# 取某 pid 的可执行文件绝对路径。**为什么不用 `ps -o args=`**：本机 `ps` 被系统拒绝
# （`/bin/ps: Operation not permitted`，实测在非沙箱下同样如此），于是原来那行永远取空，
# 而 `TARGET_FLAVOR` 会**默认成 release** —— 等于给一份可能来自 debug 的读数贴上 release 标签，
# 正好违反 spec §7.3「两档绝对值不可混比」。`lsof -p` 在本机可用，`txt` 行就是可执行文件。
pid_binary() {  # pid_binary <pid>
  lsof -p "$1" 2>/dev/null | awk '$4 == "txt" { print $NF; exit }'
}

WINLIST_BIN=""

# 窗口存在性探测。**为什么先编译一次**：`xcrun swift winlist.swift` 是 JIT，实测每次 0.3 s；
# 原来 `switch` 档把它放在"首帧轮询"里（最多 60 次），既慢又把探测开销混进了计时。
# 编译成二进制后稳态实测 39~45 ms，且首次 ~508 ms 的 dyld 冷启动由下面这次预热挡在计时窗外。
winlist_probe() {  # winlist_probe <pid> → 有在屏窗口时打印 `窗口号|标题|宽`，否则空
  local pid="$1"
  if [ -z "$WINLIST_BIN" ]; then
    if xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
         -target arm64-apple-macos14.0 "$WINLIST" -o "/tmp/tcoder-winlist-$$" 2>/dev/null; then
      WINLIST_BIN="/tmp/tcoder-winlist-$$"
      "$WINLIST_BIN" "$pid" >/dev/null 2>&1 || true
    else
      echo "    ⚠ winlist 编译失败 → 退回 JIT（单次 ~300 ms，只影响存在性探测，不影响时长口径）" >&2
    fi
  fi
  if [ -n "$WINLIST_BIN" ]; then
    "$WINLIST_BIN" "$pid" 2>/dev/null | head -1
  else
    xcrun swift "$WINLIST" "$pid" 2>/dev/null | head -1
  fi
}

TARGET_BINARY=""   # 由 require_idle_target 填：实际被采的那个二进制的绝对路径
TARGET_FLAVOR=""   # release / debug —— spec §7.3 要求两档的绝对值永不混比

note_target_flavor() {  # note_target_flavor <pid>
  TARGET_BINARY=$(pid_binary "$1")
  # **认不出就说认不出**：原来 `*) release` 是个兜底，配上取不到路径的 `ps`，
  # 会稳定地把「不知道」说成 release。release 与 debug 的绝对值差着一个量级，
  # 这种默认值是把读数卖给第一个来查的人。
  case "$TARGET_BINARY" in
    "") TARGET_FLAVOR="未知（取不到被采二进制 → release/debug 不可判定，本批读数不得与任何基线比）" ;;
    *".build/debug"*) TARGET_FLAVOR="debug" ;;
    *"/dist/Tcoder.app/"*) TARGET_FLAVOR="release" ;;
    *) TARGET_FLAVOR="未知（路径既非 .build/debug 也非 dist/Tcoder.app：$TARGET_BINARY）" ;;
  esac
  echo "    被采二进制=${TARGET_BINARY:-（取不到）} 口径=$TARGET_FLAVOR"
}

quiescence_probe() {  # → 一行 `… 静默=12.34s`；取不到时打印 静默=-1.00s（调用方按"取不到"处理）
  if [ -z "$QUIESCE_BIN" ]; then
    if xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
         -target arm64-apple-macos14.0 "$QUIESCE_SRC" -o "/tmp/tcoder-quiesce-$$" 2>/dev/null; then
      QUIESCE_BIN="/tmp/tcoder-quiesce-$$"
    else
      echo "    ⚠ 静默探针编译失败，退回 JIT（慢一点，不影响读数口径）" >&2
    fi
  fi
  if [ -n "$QUIESCE_BIN" ]; then
    "$QUIESCE_BIN" 2>/dev/null || echo "静默=-1.00s"
  else
    xcrun swift "$QUIESCE_SRC" 2>/dev/null || echo "静默=-1.00s"
  fi
}

quietest_seconds() {  # 从探针那一行里抠出"静默=Xs"的 X
  printf '%s' "${1:-}" | sed -n 's/.*静默=\([0-9.-]*\)s.*/\1/p'
}

# "产物到底是不是这份代码"的判定**不在本文件里**——它归 scripts/perf_provenance.sh，
# 与 `verify_provenance.sh` 共用同一把手尺子（见那个文件的头注）。
source "$(dirname "${BASH_SOURCE[0]}")/perf_provenance.sh"

preflight_context() {  # preflight_context <outdir> <pid>
  local out="$1" pid="$2" f="" cores load1 front visible others hard=0
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  [ -n "$load1" ] || load1=0
  f="$out/measurement-context.txt"
  front=$(preflight_front_app)
  visible=$(preflight_window_state "$pid")
  others=$(concurrent_heavy_jobs)
  # 运行时漏翻台账（i18n 报告器）会在渲染路径上记键、按 200 次节流写盘。
  # 设了它再量帧率，量的就是台账自己的开销——所以这一维写进上下文，并且直接拒跑。
  i18n_ledger="${TCODER_I18N_RUNTIME_LEDGER:-}"
  # 人手静默：整机 load 与并发编译挡得住"机器在忙"，挡不住"有人在点这个窗口"。
  local qline quiet
  qline=$(quiescence_probe)
  quiet=$(quietest_seconds "$qline")

  # 取二进制的出身（**不是**工作树 HEAD）：闸门第六维与上下文都要用
  BUILD_REV=$(provenance_manifest_value TCODER_GIT_REVISION)
  BUILD_CLEAN=$(provenance_manifest_value TCODER_GIT_CLEAN)
  BUILD_TREE=$(provenance_manifest_value TCODER_PRODUCT_TREE)
  HEAD_TREE=$(provenance_product_tree HEAD)

  preflight_write_context "$out" "$f"
  # 六条硬闸各自读上面那几个量（bash 是动态作用域：本函数的 `local` 在被调函数里照样可见，
  # 拆函数没有改变任何取数顺序，也没有引入新的全局量）。
  preflight_gates
  if [ "$hard" = "1" ] && [ "${IGNORE_CONTEXT_GATE:-0}" != "1" ]; then
    # 被拒的一趟**必须在目录上留下自认字样**：否则 `ls /tmp/tcoder-perf-*` 会看见
    # run1/run2/run3 三个"像样本"的空目录，后来的人很容易把"闸门拒了"读成"量过了"。
    # （今天就真出现了三个只有 context/meta 的目录。）
    printf 'REFUSED\n这一趟没有采数：测量上下文不合格，闸门拒跑。原因见同目录 %s。\n' "$(basename "$f")" \
      > "$out/REFUSED"
    die "测量上下文不达标（详见 $f）。IGNORE_CONTEXT_GATE=1 可强行跳过，但那批读数必须标注为『条件不合格』。"
  fi
  [ "$hard" = "1" ] && echo "    ⚠ IGNORE_CONTEXT_GATE=1：条件不合格，这批读数不得进任何对比表。" >&2
  echo "    上下文已落 $f"
}

concurrent_heavy_jobs() {  # → 空格分隔的 pid；空 = 机器上没有本仓的重活
  # 【为什么不止 swiftc】第一版只 `pgrep -x swiftc`，于是**跑全量门禁的那段时间**
  # （进程叫 swift-test / xctest，编译早已结束）在它眼里是"机器空着"——
  # 而那恰恰是 load 与调度最不干净的时候，量出来的样本会五闸全过。
  # 实测 2026-09-21 11:46：门禁在测时 `swiftc 在场数=0`、load1=4.23，全部门槛放行。
  local names=(swiftc swift-test xctest) out="" n p
  for n in "${names[@]}"; do
    p=$(pgrep -x "$n" 2>/dev/null | tr '\n' ' ')
    [ -n "$p" ] && out="$out$p "
  done
  printf '%s\n' "${out% }"
}

front_is_target() {  # front_is_target <前台App名> → 0=就是被测 App
  # 【今天修掉一个让所有测量永远跑不通的闸门 bug】
  # 旧写法 `[ "$front" != "TcoderMonitor" ]`，而 `lsappinfo` 给的是**显示名 "Tcoder"**；
  # 只有 System Events 那条路给进程名 TcoderMonitor，而本机它被权限拒。
  # 于是三趟全部以「被测窗口不在前台（前台是「Tcoder」）」被拒——**自相矛盾**：
  # 它一边报出前台是 Tcoder，一边说 Tcoder 不算前台。
  # 两种名字都认（显示名 / 进程名），但只认这两个：微信、Chrome 照样必须拒。
  case "$1" in
    Tcoder|TcoderMonitor) return 0 ;;
    *) return 1 ;;
  esac
}

preflight_front_app() {  # → 一行前台 App 名；取不到就是「未知」
  # 前台 App：**先走 `lsappinfo`（零权限）**。原来只用 `osascript` + System Events，
  # 而本机那条路被权限拒（实测 `-10004 发生权限违例`），于是永远得到「未知」、
  # 闸门永远拒跑——一条因为取不到数就永远说"不合格"的闸门，等于没有这把尺子。
  local asn win
  asn=$(lsappinfo front 2>/dev/null || true)
  front=""
  [ -n "$asn" ] && front=$(lsappinfo info -only name "$asn" 2>/dev/null | sed -n 's/^"LSDisplayName"="\(.*\)"$/\1/p')
  [ -n "$front" ] || front=$(osascript -e 'tell application "System Events" to name of first application process whose frontmost is true' 2>/dev/null | tr -d '\n')
  [ -n "$front" ] || front="未知"
  printf '%s\n' "$front"
}

preflight_window_state() {  # preflight_window_state <pid> → 那句 visible 描述
  local win
  # 窗口在不在屏：走 `winlist.swift`（CGWindowList，**零权限**），与其它三个取证脚本同一把尺子。
  win=$(winlist_probe "$1")
  if [ -n "$win" ]; then
    echo "有在屏窗口（$(printf '%s' "$win" | cut -d'|' -f2)）"
  else
    echo "无在屏窗口（隐藏/最小化/不在屏）"
  fi
}

preflight_write_context() {  # preflight_write_context <outdir> <context 文件路径>
  # 这一份上下文是"读数可互比"的凭据：谁后面拿这批数做对比，都得先看见同一组条件。
  local f="$2"
  { echo "# 测量上下文（读数只有在这一组条件下才可互比）"
    echo "时间=$(date '+%F %T')  HEAD=$(git rev-parse --short HEAD 2>/dev/null)  工作树改动数=$DIRTY"
    echo "被采pid=$pid  二进制=$TARGET_BINARY  口径=$TARGET_FLAVOR"
    echo "   产物码 tree=${BUILD_TREE:-未记录}  当前=${HEAD_TREE:-未记录}"
    echo "产物构建rev=${BUILD_REV:-未记录}  构建时树clean=${BUILD_CLEAN:-未记录}  ← 必须与上面 HEAD= 同一份代码，否则读数归错对象"
    [ -n "${PROVENANCE_NOTE:-}" ] && echo "   ※ 归属靠产物码 tree 放行（rev 不同）：${PROVENANCE_NOTE}"
    echo "实例数=${COEXIST:-1}  前台App=$front  被测进程visible=$visible"
    echo "load1=$load1  核数=$cores  并发swiftc=${others:-无}"
    echo "人输入静默=${quiet:-取不到}s  明细=${qline:-（探针没跑起来）}"
    echo "hitches_seconds=$SECONDS_HITCHES  tp_seconds=$SECONDS_TP"
    echo "诊断开关 TCODER_I18N_RUNTIME_LEDGER=${i18n_ledger:-未设（渲染路径零成本）}"
  } > "$f" 2>/dev/null || die "写不出 $f"
  echo "    上下文：前台=$front  visible=$visible  load1=$load1/$cores  并发swiftc=${others:-无}  静默=${quiet:-取不到}s"
}

# 身份两维：被量的到底是不是这份代码、以及采样时有没有开着诊断报告器。
# 拆出来一半是为了不撞 `PerfRulerHotspotRatchetTests` 的 50 行线（拆，不抬数），
# 一半是因为这两条问的是同一个问题："这批读数能算在谁头上"。
preflight_gates_identity() {
  # 【第六维】2026-09-21 实测踩到：`measurement-context.txt` 里的 `HEAD=` 是**工作树**的头，
  # 而我 attach 的那个 `dist/Tcoder.app` 是两小时前 `build_app.sh` 从 `41add9e` 建的，
  # 中间隔了 39 个产物文件（整批 i18n + 我自己的 `PerfReadoutCells` 修复）。
  # 于是"e991c6d 的 T2 读数"这句话从头到尾是假的——量的是旧二进制，只是恰好在新树上按了回车。
  if ! PROVENANCE_WHY=$(provenance_ok "$BUILD_REV" "$(git rev-parse HEAD 2>/dev/null)" "$BUILD_CLEAN" "${BUILD_TREE:-}" "${HEAD_TREE:-}"); then
    echo "!! 二进制与代码不是同一份：${PROVENANCE_WHY} —— 先跑 scripts/build_app.sh release 再量。" >&2
    hard=1
  else
    # 放行也可能带话——那就是"靠 tree 归属"的留痕，必须印进上下文，不许悄悄过。
    PROVENANCE_NOTE="$PROVENANCE_WHY"
  fi
  if [ -n "${i18n_ledger:-}" ]; then
    echo "!! 设了 TCODER_I18N_RUNTIME_LEDGER（=$i18n_ledger）——渲染路径在记漏翻台账并节流写盘；
   这批读数量的是台账的开销，不是 App 的心跳。取消该变量再测。" >&2
    hard=1
  fi
}

preflight_gates() {  # 不合格就置 `hard=1`（调用方按 IGNORE_CONTEXT_GATE 决定炸还是通报）
  # 【bash 的坑】调用**不带括号**：写成 `preflight_gates_identity()` 会被解析成
  # "在 preflight_gates 内部再定义一个函数"，于是这两维**一次都没执行**、也不报错——
  # 一条静默失效的闸门。selfcheck 第 17 项（六维矩阵）抓的就是它。
  preflight_gates_identity
  if [ -n "$others" ]; then
    echo "!! 有本仓的重活在跑（pid $others：swiftc / swift-test / xctest）——" \
         "它会抢满全部核，app-update 相位会被显著抬高。等它跑完再来。" >&2
    hard=1
  fi
  # 负载阈值：默认 1 分钟 load 不超过核数的 1.5 倍（LOAD_MAX=<数> 可覆盖，但覆盖了就要在报告里写）
  if awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l > c*1.5)}'; then
    echo "!! load1=$load1 已是核数($cores)的 1.5 倍以上：整机排队，任何帧节拍读数都不作数。" >&2
    echo "   等负载降下来，或显式 LOAD_MAX=<阈值> 重跑（那必须在报告里注明是降级条件）。" >&2
    hard=1
  fi
  if ! front_is_target "$front" && [ "${ALLOW_UNFRONTMOST:-0}" != "1" ]; then
    echo "!! 被测窗口不在前台（前台是「$front」）。macOS 会节流不在前的窗口绘制，" >&2
    echo "   app-update 会**假性地好看**（实测：同二进制前台 10.8~24.8ms、后台 1.9~3.0ms）。" >&2
    echo "   请把 Tcoder 窗口点到最前面并保持不动，再跑一次；" >&2
    echo "   确实要量后台态就 ALLOW_UNFRONTMOST=1（那批只能标成『后台态』，不得当交互基线）。" >&2
    hard=1
  fi
  case "$visible" in
    无在屏窗口*)
      echo "!! 被测进程没有在屏窗口（$visible）——窗口根本没在画，量不到有意义的心跳期帧。" >&2
      echo "   把窗口恢复出来（取消最小化 / 切到该 Space）再测。" >&2
      hard=1 ;;
  esac
  # 人手静默闸：§1.3 作废的那两批基线，坏因都是"测量期间有人在动"，
  # 而 load / 并发编译 / 前台这三条整机闸**看不见手**。取不到数只通报、不判败
  # （一条因为拿不到数据就永远说不合格的闸，等于没有这把尺子——前台那条就栽过这个跟头）。
  if [ -n "$quiet" ] && [ "$quiet" != "-1.00" ] \
     && awk -v q="$quiet" -v m="$QUIESCE_MIN" 'BEGIN{exit !(q < m)}' \
     && [ "${PERIOD:-idle}" != "interaction" ] \
     && [ "${ALLOW_UNQUIESCENT:-0}" != "1" ]; then
    echo "!! 人手 ${quiet} 秒前还在动（要求静默 ≥${QUIESCE_MIN}s）。这 20 秒里只要有人点一下、" >&2
    echo "   滚一下，读数量的就是『那 20 秒里谁干了什么』，不是『这套代码卡不卡』。" >&2
    echo "   请等人手停下再来；确实要连人一起量（例如就要量交互期）就 $0 interact 那一档。" >&2
    hard=1
  fi
}

human_input_in_window() {  # human_input_in_window <静默秒> <窗口秒> → 分类，便于拿合成数字验判定
  awk -v q="$1" -v w="$2" 'BEGIN{ if (q >= w) print "窗口内没人"; else print "窗口内有人" }'
}

post_window_quiescence() {  # post_window_quiescence <outdir> <窗口秒数>；按 PERIOD 决定"什么样的收尾算合格"
  # 收尾**再问一次**探针：若"距离上次人手事件"仍短于刚录的窗口，说明窗口里有人动过手。
  # idle 档要的是"整窗没人动"；interact 档要的正好相反——没人动那批只能退回当 idle 数。
  local out="$1" window="$2" quiet period="${PERIOD:-idle}" verdict
  quiet=$(quietest_seconds "$(quiescence_probe)")
  [ -n "$quiet" ] && [ "$quiet" != "-1.00" ] || { echo "    （收尾静默探针取不到，污染判定不做）"; return 0; }
  verdict=$(human_input_in_window "$quiet" "$window")
  meta_write "$out" "quiescence_after_seconds=$quiet" "period=$period" "window_verdict=$verdict"
  if [ "$period" = "interaction" ]; then
    if [ "$verdict" = "窗口内没人" ]; then
      meta_write "$out" "no_human_input_during_window=1"
      echo "    ⚠ 整个 ${window}s 窗口里**没有一次人手事件**（距上次 ${quiet}s）——" >&2
      echo "      这批量的是心跳期，不是交互期。要判 T1 必须重跑并真的持续滚动。" >&2
    else
      echo "    复核通过：窗口内确有真人输入（距上次 ${quiet}s < ${window}s），可当交互期样本"
    fi
  elif [ "$verdict" = "窗口内有人" ]; then
    meta_write "$out" "contaminated_by_human_input=1"
    echo "    ⚠ **这批样本被污染**：录制窗口 ${window}s 内人手在 ${quiet} 秒前还在动。" >&2
    echo "      已写进 meta（contaminated_by_human_input=1），不得进前后对比表。" >&2
  else
    echo "    收尾复核：整窗口无人手输入（距上次事件 ${quiet}s ≥ ${window}s）"
  fi
}

require_idle_target() {  # 返回全局 PID；!= 1 个实例即拒跑（除非显式 ATTACH_PID=<pid>）
  local pids n
  pids=$(instance_pids)
  if [ -n "${ATTACH_PID:-}" ]; then
    # 显式指定被采 pid 时不再拦：多实例的读数**只在标注了共存事实之后**才可比较。
    # 这条口子是给人用的，不是给默认路径用的——默认仍然要求独占。
    case "$ATTACH_PID" in
      ''|*[!0-9]*) die "ATTACH_PID 必须是数字 pid，收到：$ATTACH_PID" ;;
    esac
    printf '%s\n' "$pids" | grep -qx "$ATTACH_PID" || die "ATTACH_PID=$ATTACH_PID 不在跑着的实例里（$(printf '%s' "$pids" | tr '\n' ' ')）"
    n=$(printf '%s' "$pids" | grep -c . || true)
    PID="$ATTACH_PID"
    echo "    ⚠ 显式 ATTACH_PID=$PID：本机同时有 $n 个实例（$(printf '%s' "$pids" | tr '\n' ' ')）。"
    echo "      spec §7.5 的「采样期间独占实例」前提**不成立**，这批读数的绝对值只能与同样"
    echo "      多实例条件下取的另一批比，不能直接和 §1 的独占基线比。meta.json 里已记 coexist=$n。"
    COEXIST="$n"
    echo "    目标实例 pid=$PID，来源：$(pid_binary "$PID" | cut -c1-100)"
    note_target_flavor "$PID"
    return 0
  fi
  n=$(printf '%s' "$pids" | grep -c . || true)
  if [ "$n" = "0" ]; then
    die "没有正在运行的 TcoderMonitor 实例，idle 档无法 attach。
   idle 的设计就是**不启动 App**（同一时刻只允许一个人启动 App，且 xctrace 要独占实例），
   请你先手动打开要量的那个产物，或者改用 switch 档（它自己 --launch 且走独立沙箱）。"
  fi
  if [ "$n" -gt 1 ]; then
    die "检测到 $n 个 TcoderMonitor 实例（pid $(printf '%s' "$pids" | tr '\n' ' ')），拒跑。
   原因：spec §7.5 要求采样期间只有被采的那一个实例——多个实例共用
   ~/Library/Application Support/TcoderMonitor 与 defaults 域 $DOMAIN，
   谁后回写谁污染，读数的归属就不成立了。
   本脚本按 AGENTS.md -1.3 不会 kill 任何进程，请人工只留一个（Cmd+Q 掉多余的）。
   确实要在多实例下量某一个 pid：ATTACH_PID=<pid> scripts/perf_harness.sh idle
   （那样取到的数必须标注共存事实，见上面 ATTACH_PID 的警告）。"
  fi
  PID="$pids"
  COEXIST=1
  local exe
  exe=$(basename "$(pid_binary "$PID")")
  echo "    目标实例 pid=$PID（${exe:-未知}），来源：$(pid_binary "$PID" | cut -c1-100)"
  note_target_flavor "$PID"
}

export_table() {  # export_table <trace> <schema> <outdir>
  local trace="$1" schema="$2" out="$3"
  [ "$DRY_RUN" = "1" ] && { echo "    \$ xctrace export --input $(basename "$trace") --xpath '…@schema=\"$schema\"' --output $out/$schema.xml"; return 0; }
  xcrun xctrace export --input "$trace" \
    --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
    --output "$out/$schema.xml" >/dev/null 2>&1
  if [ -s "$out/$schema.xml" ]; then
    echo "    导出 $schema.xml（$(wc -c < "$out/$schema.xml" | tr -d ' ') 字节）"
  else
    rm -f "$out/$schema.xml"
    echo "    ⚠ 表 $schema 在该 trace 里不存在或为空 —— 汇总表会写「未覆盖」，不会编数"
  fi
}

meta_write() {  # meta_write <outdir> <键=值...>
  local out="$1"; shift
  # 目录由本函数自己保证存在：cmd_switch 的 mkdir 在 per-page 循环里，
  # DRY_RUN 下整段被跳过，于是第一次 meta_write 会写进不存在的目录（实测 traceback）。
  mkdir -p "$out" 2>/dev/null || { echo "    ⚠ meta_write 建不了 $out，本条 meta 丢失" >&2; return 0; }
  python3 - "$out/meta.json" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REV" "$DIRTY" "$@" <<'PY'
import json, os, sys
path, ts, rev, dirty = sys.argv[1:5]
data = {"captured_at_utc": ts, "rev": rev, "git_dirty_lines": int(dirty)}
for kv in sys.argv[5:]:
    k, _, v = kv.partition("=")
    data[k] = v
if os.path.isfile(path):
    try:
        data = {**json.load(open(path, encoding="utf-8")), **data}
    except ValueError:
        pass
json.dump(data, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2)
PY
}

prepare_sandbox() {  # prepare_sandbox <dir> <扫描目标>：与 capture_pages_isolated.sh 同一做法
  local sandbox="$1" target="$2"
  mkdir -p "$sandbox/reports" || die "建不了沙箱 $sandbox"
  python3 - "$sandbox" "$UUID" "$target" <<'PY' || die "写 projects.json 失败"
import json, sys, datetime
support, uuid, path = sys.argv[1], sys.argv[2], sys.argv[3]
now = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
json.dump({"projects": [{"id": uuid, "name": "Tcoder（性能沙箱）", "path": path,
                         "addedAt": now, "isDemo": False}],
           "selectedProjectID": uuid},
          open("%s/projects.json" % support, "w"), indent=2)
PY
}

