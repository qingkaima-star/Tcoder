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
WINLIST="${WINLIST:-$HERE/winlist.swift}"
WINLIST_BIN="${WINLIST_BIN:-}"
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
  local names n out="" p
  names=$(heavy_job_names)
  for n in $names; do
    p=$(pgrep -x "$n" 2>/dev/null | tr '\n' ' ')
    [ -n "$p" ] && out="$out$p "
  done
  printf '%s\n' "${out% }"
}

heavy_job_names() {  # 名单**只在这儿列一次**：闸门取 pid、话术取名字，两边不许各抄一份
  printf '%s\n' swiftc swift-test xctest xctrace
}

concurrent_heavy_jobs_detail() {  # → `pid=42493 name=xctrace` 一串，只给话术用
  # 为什么单独一个函数：原来话术里硬写着"swiftc / swift-test / xctest"，
  # 名单加了第四个名字之后，那句话就把 xctrace 说成了"本仓编译"——
  # **归属说错比不说更坏**：会让人去找一个根本不存在于本仓的编译。
  local names n p
  names=$(heavy_job_names)
  for n in $names; do
    for p in $(pgrep -x "$n" 2>/dev/null); do printf 'pid=%s name=%s ' "$p" "$n"; done
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
