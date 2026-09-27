#!/bin/bash
# =============================================================================
# perf_target.sh —— 「这一趟要 attach 谁、给谁造沙箱」那一层：目标实例的归属与隔离沙箱的装配。
# 自 `perf_preflight.sh` **逐字搬出**（2026-09-27 §218 之后：preflight 涨到 394/400，
# `SourcesSizeAuditTests` 那把 400 行尺子会把"再加一维"直接判红 ⇒ 本仓口径是**拆，不抬线**）。
#
# 切在「测量上下文判据（preflight）vs 被测对象是谁（这里）」这条天然分界上；
# 判据、话术、`die` 的位置逐字未动，`prepare_sandbox` 里那段 python 也是原文照搬。
# 由 `perf_preflight.sh` 自己 source（不是各调用点自己 source）——与 io／verdicts 同一形状：
# 换源点会造出两个入口各拿一半函数。新建本文件同批点进
# `PerfRulerHotspotRatchetTests.rulerScripts`，否则"拆"本身变成免检通道。
# =============================================================================

# 归属行的显示宽度与「同树只许一条链」的判据住在一起：`perf_chain_guard.sh`。
# 为什么不在这里重复一份：两处入口两个数是本仓记账记得最多的一类错（包 10/包 36/包 41）。
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
    echo "    目标实例 pid=$PID，来源：$(path_for_display "$(pid_binary "$PID")")"
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
  echo "    目标实例 pid=$PID（${exe:-未知}），来源：$(path_for_display "$(pid_binary "$PID")")"
  note_target_flavor "$PID"
}

# 录制的墙钟兜底与被测进程存活复核（包 14）。默认值可被夹具改小，不改判定形状。
# ⚠ 余量必须罩得住 finalize：120 s 时 `cert16` 三趟里两趟被砍在 finalize 当中（只剩 16 GB 原始流、
# 无 corespace ⇒ 永不可导出），420 s 时 `cert17` 三趟全部自行停表并导齐九张表（09-27 实盘，#122）。
RECORD_SLACK_S="${RECORD_SLACK_S:-420}"
RECORD_POLL_S="${RECORD_POLL_S:-5}"

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
