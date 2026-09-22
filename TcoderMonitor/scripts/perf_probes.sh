#!/bin/bash
# perf_probes.sh —— 度量链的**零权限探针族**：只问系统要事实，不做任何判定。
#
# 自 `perf_preflight.sh` 逐字节搬出（本仓 400 行口径：拆文件才是修复，往挂账清单塞条目不算）。
# 分界线是"取数 vs 判定"：这里只负责「整机人手静默多少秒」「前台是谁」「有没有在屏窗口」
# 「有没有并发重活」这类事实；**合格线一律留在 preflight 那边**。
# 分开还有个实际好处：`perf_wait_window.sh` 排程只要事实，不必把闸门一起拖过来。
#
# 全部只读：不 kill、不改系统配置、不请求权限（CGEventSource / lsappinfo / pgrep / ps args）。
# 依赖的调用方变量（$WINLIST / $QUIESCE_SRC / $UUID）仍由 `perf_harness.sh` 在 source 之前设好。
instance_pids() { pgrep -x TcoderMonitor 2>/dev/null || true; }
# 取某 pid 的可执行文件绝对路径。**为什么不用 `ps -o args=`**：本机 `ps` 被系统拒绝
# （`/bin/ps: Operation not permitted`，实测在非沙箱下同样如此），于是原来那行永远取空，
# 而 `TARGET_FLAVOR` 会**默认成 release** —— 等于给一份可能来自 debug 的读数贴上 release 标签，
# 正好违反 spec §7.3「两档绝对值不可混比」。`lsof -p` 在本机可用，`txt` 行就是可执行文件。
pid_binary() {  # pid_binary <pid>
  lsof -p "$1" 2>/dev/null | awk '$4 == "txt" { print $NF; exit }'
}

# ── 探针必须能被**不经过 perf_harness.sh** 的消费者裸调 ────────────────────
# 这些量原先只在 `perf_harness.sh` 头部赋一次；而 `perf_wait_window.sh` 是直接 source
# 本文件的，于是进了 `set -u` 就炸在 `QUIESCE_BIN: unbound variable`
# ——今天 T1 采样断在这里（三轮作废之后第一次真的跑到开录，被我自己的脚本绊倒）。
# 路径按 `BASH_SOURCE` 算而不是 `$PWD`：换个目录跑也不会指错探针源码。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 一次性产物的落点：AGENTS §1.6 的仓库内 `.scratch/`（探针二进制也在这儿，不再 litter /tmp）。
SCRATCH="${SCRATCH:-${TCODER_SCRATCH:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.scratch}}"
WINLIST="${WINLIST:-$HERE/winlist.swift}"
WINLIST_BIN="${WINLIST_BIN:-}"   # 编译产物落 $SCRATCH，见 winlist_probe
QUIESCE_SRC="${QUIESCE_SRC:-$HERE/input_quiescence.swift}"
QUIESCE_BIN="${QUIESCE_BIN:-}"

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
  # 【为什么按内容哈希缓存】原来每个新进程都 `-o /tmp/tcoder-quiesce-$$` 重编一遍：
  # ① 白烧 CPU（编译期间 load 抬高，正好污染我要量的那一维）；
  # ② 更坏的是**多个会话共用 /tmp 这个命名空间**——现场就有 `/tmp/tcoder-quiesce-trial`
  #    是个**目录**（另一路会话起的名字），撞上 `-o` 就"编译失败"，
  #    症状是探针时好时坏地报 `-1.00`，看起来像"机器没人动"却其实是尺子掉了。
  # ③ 默认 module cache 在并发编译下也会偶发失败 ⇒ 显式指一个自己的缓存目录。
  local want bin tmp
  want=$(printf '%s' "$(shasum -a 256 "$QUIESCE_SRC" 2>/dev/null | cut -c1-12)")
  bin="$SCRATCH/tcoder-quiesce-${want:-srcunknown}"
  [ -d "$bin" ] && bin="$bin.$$"          # 别人在那儿放了目录：换一个，绝不硬来
  if [ ! -x "$bin" ]; then
    tmp="$bin.build.$$"
    if xcrun swiftc -O -sdk "$(xcrun --show-sdk-path --sdk macosx)" \
         -target arm64-apple-macos14.0 \
         -module-cache-path /tmp/tcoder-swiftmodulecache \
         "$QUIESCE_SRC" -o "$tmp" 2>/dev/null; then
      mv -f "$tmp" "$bin"                 # 先写临时名再原子替换：并发编译不会留下半个文件
    else
      rm -f "$tmp"
      QUIESCE_WARNED="${QUIESCE_WARNED:-}"
      [ -n "$QUIESCE_WARNED" ] || { echo "    ⚠ 静默探针编译不成，本进程退回 JIT（慢，但口径不变）" >&2; QUIESCE_WARNED=1; }
    fi
  fi
  QUIESCE_BIN="$bin"
  if [ -x "$QUIESCE_BIN" ]; then
    "$QUIESCE_BIN" 2>/dev/null || echo "静默=-1.00s"
  else
    xcrun swift "$QUIESCE_SRC" 2>/dev/null || echo "静默=-1.00s"
  fi
}
quietest_seconds() {  # 从探针那一行里抠出"静默=Xs"的 X
  printf '%s' "${1:-}" | sed -n 's/.*静默=\([0-9.-]*\)s.*/\1/p'
}
concurrent_heavy_jobs() {  # → 空格分隔的 pid；空 = 机器上没有本仓的重活
  # 【为什么不止 swiftc】第一版只 `pgrep -x swiftc`，于是**跑全量门禁的那段时间**
  # （进程叫 swift-test / xctest，编译早已结束）在它眼里是"机器空着"——
  # 而那恰恰是 load 与调度最不干净的时候，量出来的样本会五闸全过。
  # 实测 2026-09-21 11:46：门禁在测时 `swiftc 在场数=0`、load1=4.23，全部门槛放行。
  # 【第四个名字是今天补的】`xctrace` 与上面三个一样是"正在采别人"的重活：
  # 它靠 Task/Drift 反复暂停-恢复被测进程，与被测档的读数**互相污染**（两边都不准）。
  # 实证就在补这条的当下：另一个工程（AiX）正在 `xctrace record --template Animation
  # Hitches --time-limit 12s` 连排，而我的闸门写着"机器空"。
  # 自己的不算：本档在**录制开始之前**问这一维，那时自己还没有 xctrace 在场；
  # 真到了要并跑两档的时候，宁可拒跑等窗口，也不出"两边都不准"的数。
  # `grep -o` 而不是 `sed 's/pid=\([0-9]*\).*/\1/p'`：一行上有两个命中时，
  # 后者的 `.*` 会把第二个一起吃掉 ⇒ 清单**静默少报**（实测两个 pid 只回来一个）。
  # 少报本身不会放错行（判空还是判非空），但它会让上下文里"谁在挡我"只剩一个名字。
  local hits; hits=$(concurrent_heavy_jobs_detail)
  printf '%s\n' "$(printf '%s' "$hits" | grep -o 'pid=[0-9]*' | cut -d= -f2 | tr '\n' ' ')"
}

process_cpu_seconds() {  # `ps -o time=` 的 `MM:SS.ss` / `HH:MM:SS` → 秒（取不到给 0）
  ps -o time= -p "$1" 2>/dev/null | tr -d ' ' \
    | awk -F: 'NF==3{print $1*3600+$2*60+$3} NF==2{print $1*60+$2} NF<2{print 0}' | head -1
}

heavy_job_is_live() {  # heavy_job_is_live <pid> <进程名> → 0=真在干活，算重活
  # 只有 xctrace 需要这一层。实证就在补这条的当下：机器上挂着一个**另一个工程 21 小时前**
  # 留下的 `xctrace record`，%cpu=0.0、cputime 5 秒只走 0.01 秒、`--attach` 的目标进程早没了。
  # 按"在场即重活"处理，这条闸门就**永远不可能满足**——
  # 恒拒的闸门看起来最像尽职，实际是把 T1 唯一一次举证机会无限期押住。
  # 编译类（swiftc / swift-test / xctest）不适用：它们在场本身就是在吃 CPU，不必再看增量。
  [ "$2" != "xctrace" ] && return 0
  local a b
  a=$(process_cpu_seconds "$1")
  sleep "${XCTRACE_LIVENESS_WINDOW:-2}"
  b=$(process_cpu_seconds "$1")
  awk -v a="$a" -v b="$b" 'BEGIN{ exit !(b - a > 0.2) }'
}

disk_free_gib() {  # → 数据卷可用 GiB（整数）；读不到打**空串**（不是 0，也不是 -1）
  # BSD `df` 没有 `-s`：写成 `df -s -k` 会报错、输出为空，
  # 于是"余量不足就不许录"这条前置会**永远静默放行**——正是本仓最恨的永真绿。
  df -k -P /System/Volumes/Data 2>/dev/null | awk 'NR==2 {print int($4/1024/1024)}'
}

disk_headroom_bad() {  # disk_headroom_bad <可用GiB，空串=读不到> → 0=不合格（话术走 stdout）
  # 做成**纯函数**：闸门与录制前置都调它，测试可以直接喂 3 / "" / 400 各判一次。
  # 读不到一律算不合格——拿不到余量就没资格开始一趟 GB 级的录制。
  local free="${1:-}" min="${TCODER_MIN_FREE_GIB:-20}"
  case "$free" in
    ''|*[!0-9]*) printf '读不到 /System/Volumes/Data 的可用空间（df 返回「%s」）' "${free:-空}"
                 return 0 ;;
  esac
  if [ "$free" -lt "$min" ]; then
    printf '可用仅 %s GiB < %s GiB：先清 $SCRATCH 与孤儿 trace，别硬跑到一半' "$free" "$min"
    return 0
  fi
  return 1
}

heavy_job_names() {  # 名单**只在这儿列一次**：闸门取 pid、话术取名字，两边不许各抄一份
  # `swift-frontend` 是**真正的编译工人**：`swiftc` 只是驱动，驱动会把活派给
  # 一堆 `swift-frontend` 子进程，且驱动常在子进程干完之前就退场。
  # 实测 2026-09-21 17:23：`pgrep -x swiftc` = 0、闸门打印「✓ 没有重活在跑」，
  # 而同一时刻 `swift-frontend` 正吃 94.8% CPU。回头看时间线，那大概率是**我自己**
  # 刚为合成输入器起的那次编译（约 20 秒后消失，时长也对得上）——
  # 我第一版把它写成"别的会话在编译"，那是未经核实的归属，已改。
  # 但结论不受归属影响：不管是谁的编译，工人都得在名单里。
  # 少了这个名字，那一趟交互期样本会五闸全过、load1 却 11.22/15。
  printf '%s\n' swiftc swift-frontend swift-test swiftTestDriver xctest xctrace
}

concurrent_heavy_jobs_detail() {  # → `pid=42493 name=xctrace` 一串，只给话术用
  # 为什么单独一个函数：原来话术里硬写着"swiftc / swift-test / xctest"，
  # 名单加了第四个名字之后，那句话就把 xctrace 说成了"本仓编译"——
  # **归属说错比不说更坏**：会让人去找一个根本不存在于本仓的编译。
  local names n p
  names=$(heavy_job_names)
  for n in $names; do
    for p in $(pgrep -x "$n" 2>/dev/null); do
      heavy_job_is_live "$p" "$n" && printf 'pid=%s name=%s ' "$p" "$n"
    done
  done
  printf '\n'
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
human_input_in_window() {  # human_input_in_window <静默秒> <窗口秒> → 分类，便于拿合成数字验判定
  awk -v q="$1" -v w="$2" 'BEGIN{ if (q >= w) print "窗口内没人"; else print "窗口内有人" }'
}
probe_usable() {  # 探针"取不到"必须是**一个词**，两侧档位共用
  # 哨兵是 -1（`quiescence_probe` 编不出来或跑不起来时打 静默=-1.00s）。
  # 它在数轴上是**最小**的静默 ⇒ 任何"静默 < 阈值"的判定（交互档开录）都会被它**骗成合格**。
  # 所以"有没有人在动"之前，先问"这把尺子今天在场吗"。
  local q="${1:-}"
  case "$q" in ''|-1|-1.0|-1.00) return 1 ;; esac
  return 0
}


# =============================================================================
# 合成输入器（CGEvent 投递滚动）—— 从 perf_wait_window.sh 搬进来，因为现在有两个消费者：
# 排程器的 interact 档，和 `perf_harness.sh pulse`（进程内帧脉冲 + 同时投滚动）。
# 留一份实现是底线：编译缓存键、"编译不许挤进闸门与录制之间"、投不出事件就非零退出，
# 两处都得同一份待遇。目标 pid 改成调用方传（pulse 档起的不是"唯一那个实例"）。
# =============================================================================
SYNTH_PID=""
SYNTH_BIN=""
ensure_synth_scroller() {  # **进等待循环之前**把投事件器编好（内容哈希缓存，全机一次）
  # 原来编译写在 start_synth_scroller 里，而它是"开录闸门之后"才调的
  # ⇒ `swiftc` 派出的 `swift-frontend` 还在吃 94.8% CPU 的时候，录制窗口已经开始了。
  # 自己刚起的编译绕过自己刚过的闸门，这种污染比别人的干扰更难发现。
  local want
  want=$(shasum -a 256 scripts/perf_synth_scroll.swift 2>/dev/null | cut -c1-12)
  SYNTH_BIN="${SCRATCH:-$PWD/.scratch}/tcoder-synth-scroll-${want:-unknown}"
  [ -d "$SYNTH_BIN" ] && SYNTH_BIN="$SYNTH_BIN.$$"     # 别人占了这个名字：换，不硬来
  [ -x "$SYNTH_BIN" ] && return 0
  local tmp="$SYNTH_BIN.build.$$"
  xcrun swiftc -O -target arm64-apple-macos14.0 \
      -module-cache-path "${SCRATCH:-$PWD/.scratch}/swiftmodulecache" \
      scripts/perf_synth_scroll.swift -o "$tmp" 2>/dev/null \
    || { rm -f "$tmp"; echo "!! 合成输入器编不出来（scripts/perf_synth_scroll.swift）" >&2; return 1; }
  mv -f "$tmp" "$SYNTH_BIN"
}

start_synth_scroller() {  # 只管"跑起来"：编译不许出现在闸门与录制之间。<目标 pid> [秒]
  # 【第二参数原来根本没人读】写的是 `${SYNTH_SECS:-95}`，注释却承诺 `[秒]`——
  # 09-22 排演时按 12 秒调用，实际投了 95 秒。MEASURE_LAUNCH 那条路要按
  # "hitches + time-profile + 换档空档"来定时长，所以这个参数必须真生效。
  local secs="${2:-${SYNTH_SECS:-95}}"   # 默认覆盖一整趟（hitches 20s + time-profile 25s + 导出与换趟空档）
  [ -x "$SYNTH_BIN" ] || { echo "!! 合成输入器没预备好（应先跑 ensure_synth_scroller）" >&2; return 1; }
  # 被测 pid：优先用本档自己起的那个；attach 模式下用唯一在场的那个
  local tp="${1:-${TARGET_PID:-}}"   # 目标 pid 由调用方给（本函数不再假设"我只有一个实例"）
  [ -n "$tp" ] || { echo "!! 不知道往哪个 pid 投事件 ⇒ 不开录（空转样本比没有样本更坏）" >&2; return 1; }
  # 14 px / 8 ms ⇒ ~125 Hz 的事件节奏；每次改动都记进日志，免得读表的人不知道输入多快
  "$SYNTH_BIN" "$secs" "$tp" "${SYNTH_PX:-14}" "${SYNTH_GAP_MS:-8}" >&2 &
  SYNTH_PID=$!
  echo "    合成输入器 pid=$SYNTH_PID（投 ${secs}s，${SYNTH_PX:-14}px/${SYNTH_GAP_MS:-8}ms ≈ $((1000 / ${SYNTH_GAP_MS:-8})) Hz 事件节奏；meta 记 input_source=synth）"
  return 0
}

stop_synth_scroller() {  # 只停**自己起的那个** pid（绝不按名字 pkill：别人同形状的取证脚本会被误杀）
  [ -n "$SYNTH_PID" ] || return 0
  kill -TERM "$SYNTH_PID" 2>/dev/null || true
  SYNTH_PID=""
}

measured_cleanup() {  # 收尾：只清**自己起的那两个** pid（合成输入器 + 被测实例），绝不按名字/bundle id 广播
  stop_synth_scroller
  [ -n "${MEASURED_PID:-}" ] && kill -TERM "$MEASURED_PID" 2>/dev/null
  return 0
}

# -----------------------------------------------------------------------------
# 把**自己起的**那个实例带到前台：按 pid，绝不遍历、绝不按 bundle id 广播（AGENTS -1.3）。
# 09-22 从 perf_wait_window.sh 搬进来，因为 `MEASURE_LAUNCH=1` 那条路是 harness 自己起实例的，
# 而实测裸 `exec` 起来的实例**不会自己抢到前台**（前台仍是别的 App）——不在前的窗口会被
# 系统节流绘制，实测那份脉冲 2015 帧 / 25 s ≈ 80 帧每秒，与"独占且在前"的 p50=8.33 ms 不是一回事。
# 搬而不是复制：怎么带前台只该有一把尺子（本仓为这类分叉记过不止一次）。
# -----------------------------------------------------------------------------
RAISE_BIN=""
ensure_raiser() {  # 编译"把自己的实例带到前台"的小工具（一次尝试只 raise 一次，见那个文件的头注）
  [ -n "$RAISE_BIN" ] && [ -x "$RAISE_BIN" ] && return 0
  local want dir; want=$(shasum -a 256 "$HERE/perf_raise.swift" 2>/dev/null | cut -c1-12)
  dir="${SCRATCH:-$PWD/.scratch}"; mkdir -p "$dir" 2>/dev/null
  RAISE_BIN="$dir/tcoder-raise-${want:-unknown}"
  [ -x "$RAISE_BIN" ] && return 0
  xcrun swiftc -O -target arm64-apple-macos14.0 \
      -module-cache-path "$dir/swiftmodulecache" "$HERE/perf_raise.swift" -o "$RAISE_BIN.tmp.$$" 2>/dev/null \
    && mv -f "$RAISE_BIN.tmp.$$" "$RAISE_BIN" && return 0
  rm -f "$RAISE_BIN.tmp.$$"; RAISE_BIN=""; return 1
}

raise_to_front() {  # raise_to_front <pid> ⇒ 只负责"发出请求"，成不成由调用方的前台闸判
  local tp="${1:-}"
  [ -n "$tp" ] || { echo "!! 没给 pid ⇒ 不猜该带谁到前台" >&2; return 1; }
  ensure_raiser || { echo "!! raiser 编不出来（scripts/perf_raise.swift）" >&2; return 1; }
  "$RAISE_BIN" "$tp" >/dev/null 2>&1
}

# -----------------------------------------------------------------------------
# 自己起一个"带脉冲记录"的被测实例，让**同一个窗口同时有两把尺子**。
#
# 为什么必须自己起（2026-09-22 想清楚的一件事）：`interact`/`idle` 档一直是
# `require_idle_target` 找**场上已有**的实例再 `xctrace --attach`，
# 而那个实例多半不是带 `TCODER_PERF_PROBE=1` 起的 ⇒ 它体内根本没有 FramePulse 在记，
# 于是"p95 帧间隔 ≤8.4 ms"这半句验收**永远无法与 xctrace 的
# `displayed-surfaces-per-second` 对上** —— 两把尺子来自两个不同窗口，就等于没有交叉核对。
# （今天第一份配对证据反而是 idle 档给的：surfaces p50=119 / p95=120、设备 max 120 Hz，
#   直接推翻了我"idle 静止窗一定降频到 10/s，所以 p95 判不了"那句老话。）
#
# 默认关：`MEASURE_LAUNCH=1` 才走这条路。开了之后：
#   · 用**本树的 release 二进制**起一个实例，`TCODER_PERF_OUT` 指进样本目录、
#     `TCODER_SUPPORT_DIR` 指进样本目录下的沙箱（不污染用户真实数据，也不会与别人互写全局态）；
#   · 只 TERM 自己起的那一个 pid（有 trap；绝不按 bundle id 广播 —— 工单 §K 那条）。
wait_for_seed_scanned() {  # wait_for_seed_scanned <沙箱> [最长秒] ⇒ 验"这个 App 真有内容可滚"
  # 为什么不是固定 sleep：`bootstrapIfNeeded` 从今天起**故意不自动扫描**（批次 P7-A，
  # 用户口径「不能有假数据」）——种一个 `projects.json` 进去，App 只会显示"未扫描"的空态，
  # 永远不会自己扫出报告（实测等 150 s 无产物）。所以"有内容"只能来自**复制真实支持目录**，
  # 而复制完就必须当场验：验不过就是没内容，宁可不录。
  local sb="$1" lim="${2:-${MEASURE_SETTLE:-60}}" waited=0
  while :; do
    if [ -n "$(find "$sb/reports" -maxdepth 1 -name '*.json' -size +200c 2>/dev/null | head -1)" ]; then
      echo "    沙箱里有 $(find "$sb/reports" -maxdepth 1 -name '*.json' -size +200c 2>/dev/null | wc -l | tr -d ' ') 份真报告 ⇒ 被测对象是有内容的 App"
      return 0
    fi
    [ "$waited" -ge "$lim" ] && { echo "!! ${lim}s 内沙箱里没有真报告 ⇒ 不开录（空页的『交互期』不是证据）" >&2; return 1; }
    sleep 5; waited=$((waited + 5))
  done
}

seed_sandbox() {  # seed_sandbox <沙箱> ⇒ 按 MEASURE_SEED_DIR（一个支持目录路径）复制真实数据；不设就是不种
  local sb="$1" src="${MEASURE_SEED_DIR:-}"
  [ -n "$src" ] || return 0
  [ -d "$src" ] || { echo "!! MEASURE_SEED_DIR=$src 不是目录 ⇒ 不起实例（宁可没数，也不要一份空页的『交互期』）" >&2; return 1; }
  mkdir -p "$sb" || return 1
  cp -R "$src/." "$sb/" || { echo "!! 复制真实支持目录失败：$src" >&2; return 1; }
  echo "    已把真实支持目录种进沙箱：$src"
  MEASURED_SEED="$src"
}

launch_measured_instance() {  # launch_measured_instance <样本目录> <二进制>
  local out="$1" bin="$2"
  [ -x "$bin" ] || { echo "!! 二进制不可执行：$bin（先跑 scripts/build_app.sh release）" >&2; return 1; }
  mkdir -p "$out/sandbox" || return 1
  # 被测对象必须是**有内容的 App**：空沙箱里那个页面没有东西可滚（详见 `seed_sandbox` 那段）。
  seed_sandbox "$out/sandbox" || return 1
  MEASURED_PULSE="$out/pulse.txt"
  TCODER_PERF_PROBE=1 TCODER_PERF_OUT="$MEASURED_PULSE" TCODER_SUPPORT_DIR="$out/sandbox" \
    "$bin" -ApplePersistenceIgnoreState YES >/dev/null 2>&1 &
  MEASURED_PID=$!
  # 收尾两条：EXIT 只清；INT/TERM 清完必须真的退（原来三条共用一个写 `return` 的 handler，
  # 两条失效都实测过：日志尾巴溅错误 + TERM 杀不掉它 ⇒ 漏一个孤儿实例压死所有人的闸）。
  # 只清自己起的那两个 pid，绝不按 bundle id 广播（AGENTS -1.3）。
  trap 'measured_cleanup' EXIT
  trap 'measured_cleanup; exit 130' INT TERM
  sleep 4
  if kill -0 "$MEASURED_PID" 2>/dev/null; then
    echo "    自己起的被测实例 pid=$MEASURED_PID（脉冲写 $MEASURED_PULSE，沙箱 $out/sandbox）"
    # 裸 exec 不抢前台（09-22 实测：前台仍是 ChatGPT）⇒ 必须按 pid 主动带一次。
    # 带不动也**不装绿**：preflight 的前台硬闸会照原样拒，这里只负责别让它白拒一场。
    raise_to_front "$MEASURED_PID" || echo "    ⚠ 带前台没成功（交给 preflight 的前台闸判，不绕）"
    sleep 1
    # 种了真实数据就要当场验"确有报告可看"，否则开录那一刻量的还是空态。
    [ -z "${MEASURE_SEED_DIR:-}" ] || wait_for_seed_scanned "$out/sandbox" || return 1
    return 0
  fi
  echo "!! 起的实例 4 秒内就退了 ⇒ 不继续（宁可没数，也不要一份 attach 到别人实例上的假配对）" >&2
  return 1
}

