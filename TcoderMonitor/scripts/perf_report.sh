#!/bin/bash
# =============================================================================
# perf_report.sh —— report / probe 两档（读已有样本出表、探一下盘上的事实）。
# 自 `perf_harness.sh` **逐字节搬出**：本仓「巨大文件 >400 行」口径把 .sh 也算实现文件，
# 而这份分支一天比一天厚；**拆文件才是修复**，往挂账清单塞条目不算。
#
# **懒加载**（与 `perf_switch.sh` 同一做法）：只有真跑 report / probe 才 source 进来，
# 同一进程 ⇒ 全局量（$REV / $SCRATCH / $TRACE_REPORT）与口径完全不变。
# 判据、告警文案、退出码逐字未动。
# =============================================================================

cmd_report() {
  local out="${1:-$SCRATCH/tcoder-perf-$REV}"
  [ -d "$out" ] || die "没有这个输出目录：$out"
  # 被闸门拒掉的那趟**不许被 report 当成一趟数据重打**：
  # 它只有 context/meta，喂给汇总表会得到"没有 hitch"形状的漂亮空表。
  [ -f "$out/REFUSED" ] && die "这一趟当时被闸门拒了、没有采数（$out/REFUSED）——
    它不该出现在任何对照表里；要看当时的拒因就读 $out/measurement-context.txt。"
  echo "==> report 档：重打 $out 的汇总表（不重录）"
  local secs
  secs=$(python3 - "$out/meta.json" <<'PY' 2>/dev/null || echo 20
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("hitches_seconds", 20))
except Exception:
    print(20)
PY
)
  python3 "$TRACE_REPORT" summary "$out" --seconds "$secs"; local src=$?
  [ -s "$out/time-profile.xml" ] && python3 "$TRACE_REPORT" threads "$out/time-profile.xml" --thread "Main Thread"
  [ -d "$out/pages" ] && python3 "$TRACE_REPORT" switches "$out/pages"
  # 同窗交叉核对：p95 那半句要的是"回调时序 vs 真实上屏"两把尺子合判（工单 §M / selfcheck 第 33 项）。
  # 只在样本里真有脉冲时印；没有就明写"这一趟答不了"，**不许**沉默跳过——
  # 跳过与答不出是两件事，前者会被下一个人读成"量过了"。退出码不改（合判是给**人**读的结论）。
  # 节拍这一把是**独立于回调时间戳**的（合成器逐帧起点差），所以没有脉冲也要印：
  # 09-22 就是靠它才发现名义 120 Hz 与实测 119.33~119.39 Hz 差 0.5%，
  # 而"p95 未达标"的残差（0.04~0.10 ms）小于两台仪器的分歧（0.66 ms）。
  if [ -s "$out/hitches-renders.xml" ]; then
    python3 "$CADENCE_REPORT" "$out/hitches-renders.xml" --pulse "$out/pulse.txt" 2>&1 | tail -7 | sed 's/^/    /' || true
  fi
  if [ -s "$out/pulse.txt" ]; then
    python3 "$PULSE_REPORT" --sample-dir "$out" --interaction 2>&1 | tail -3 | sed 's/^/    /' || true
  else
    echo "    ⓘ 这一趟没有同窗脉冲（attach 模式起的实例没带 TCODER_PERF_PROBE）⇒ p95 那半句未采到，不是达标"
  fi
  # 显式收尾：上面两条都是 `[ 测试 ] && 命令` 的形状，没有 pages 目录时（idle 档就是没有）
  # 最后一条测试自己返回 1，会把"重打成功"报成"档口失败"。
  # 实测踩过：修尺子那轮 `report` 明明全打出来了，退出码仍是 1，逼得人回头去查 Traceback。
  # 但"如实传 rc"不等于"一律传 0"：summary 判**期间自我矛盾**时给的是 3，
  # 上面那句 `return 0` 会把它一起吞掉 ⇒ 表头翻对了话术、脚本拿到的还是绿灯。
  case "$src" in
    0) return 0 ;;
    3) echo "    ⇒ 以 rc=3 退出：本目录的档位声明与收尾复核互相矛盾，不得作为结论提交。" >&2
       return 3 ;;
    *) return "$src" ;;
  esac
}

# =============================================================================
# probe —— 读 FramePulse 的落盘脉冲（交互期 hitch 的唯一入口，零采样）
# =============================================================================
cmd_probe() {
  local file="${1:-}"
  # 【为什么要有 --start】整条自动化里**没有任何地方设过 TCODER_PERF_PROBE=1**，
  # 而 `open` 起的 App 也不继承调用方环境变量 ⇒ 这颗"进程内侧量帧脉冲"的探针
  # 在无人值守链里**根本开不起来**，probe 档于是只能读到一个永远不会出现的 /tmp 文件。
  # 它不牵连 T1/T2 的判决（那两个读的是 xctrace 的 hitches / updates / displays 表），
  # 但"规范里写着的仪器"与"实际接得通的仪器"必须是同一件，所以这里补一条起法。
  if [ "$file" = "--start" ]; then
    local secs="${2:-8}"
    # macOS 自带 bash 3.2 没有 BASHPID（第一次跑就在这行 unbound 死掉，还是 `set -u` 那种
    # "不报错、直接终止"的死法），所以文件名只用 $$ + 秒，够用且不会撞名。
    file="$SCRATCH/tcoder-framepulse-$REV-$$-$(date +%s).txt"
    echo "==> 自己起一个带探针的实例，采 ${secs}s（输出落仓库内 $file，不写 /tmp）"
    TCODER_PERF_PROBE=1 TCODER_PERF_OUT="$file" "$PERF_BIN" >/dev/null 2>&1 &
    local probe_pid=$!
    trap 'kill -TERM "$probe_pid" 2>/dev/null || true' EXIT INT TERM
    sleep "$secs"
    kill -TERM "$probe_pid" 2>/dev/null || true
    trap - EXIT INT TERM
    [ -s "$file" ] || die "探针没产出（$file 不存在或为空）⇒ 要么 env 没传进去，要么这个 build 里 FramePulse 没接上"
    shift 2
    set -- "$file" "$@"
    echo "    起了 pid=$probe_pid，产物 $file（$(wc -l < "$file" | tr -d ' ') 行）"
  fi
  [ "$#" -gt 0 ] && file="$1"
  [ -n "$file" ] || file=$(ls -t "$SCRATCH"/tcoder-framepulse-*.txt /tmp/tcoder-framepulse-*.txt 2>/dev/null | head -1)
  [ -n "$file" ] || die "找不到 FramePulse 产物：用 `probe --start` 现采一趟，或自己带 TCODER_PERF_PROBE=1 起 App"
  case "$file" in
    /tmp/*) echo "    ⚠ 读的是 /tmp 下的旧探针文件——仓库外，可能被系统清理（今晚对照组就是这么丢的）" >&2 ;;
  esac
  echo "==> probe 档：读 $file"
  echo "    交互期结论只有在测量窗口内**真的有人在滚动/拖窗**时才成立，"
  echo "    所以判 T1 要自己带 --interaction 声明；不带就只会得到 idle 读数（退出码 2，不是达标）。"
  python3 "$PULSE_REPORT" "$file" "${@:2}"
}
