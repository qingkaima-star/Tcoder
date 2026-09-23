#!/bin/bash
# =============================================================================
# perf_measure_io.sh —— 「怎么采、怎么落盘、采完当场复核什么」这一层。
# 自 `perf_preflight.sh` **逐字节搬出**（本仓 400 行口径：拆文件才是修复，
# 往 `hugeFileWorkList` 塞条目不算，挪出扫描面也不算）。
#
# 由 preflight 自己 source，**不单独执行**：`perf_harness.sh` 与 `perf_wait_window.sh`
# 两边都是 source preflight 进来的，搬家若切断这条链就会有两个入口各拿一半函数
# （第 22 项那条夹具正是**单独 source preflight** 来验阈值默认的，它必须照样看得见全部函数）。
# 判据、告警文案、退出码逐字未动。
# =============================================================================

post_window_load() {  # post_window_load <outdir> —— 窗口**结束那一刻**再看一次整机负载
  # 为什么要有它（09-23 10:17 现算出来的形态）：同一台机器、同一份内容，hitch 的**间隔分布**就是争用的指纹：
  #   干净时 p50 ≈ **1800 ms**（每 216 帧一次，基本就是 1.5 s 心跳那一拍）
  #   被争用污染时塌成 **58 ms**（每 7 帧一次，20 s 报 364 个）甚至 **8.3 ms**（**每帧一次**，432 个）
  # 而闸门只在**窗口开始之前**采一次负载与并发重活 ⇒ 别人在窗口中途起一趟编译，这批数照样「合格」。
  # spec §6 第 8 条早写过"五道闸看不见外部争用"，今天第一次量出它长什么样。
  # 阈值一律复用闸门那两个（`concurrent_heavy_jobs` 与 load1 ≤ 1.5×核数），这里不造新数。
  local out="$1" cores load1 jobs
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}'); load1=${load1:-0}
  jobs=$(concurrent_heavy_jobs 2>/dev/null)
  meta_write "$out" "load1_at_end=$load1" "heavy_at_end=${jobs:-无}"
  if [ -n "$jobs" ] || awk -v l="$load1" -v c="$cores" 'BEGIN{exit !(l > c*1.5)}'; then
    meta_write "$out" "contaminated_by_foreign_load=1"
    echo "    ⚠ 窗口结束时整机在忙（load1=$load1/$cores，重活=${jobs:-无}）" >&2
    echo "      ⇒ 这批 hitch 分布会被外部争用主导，**不作数**（闸门只看了窗口开始那一刻）。" >&2
  fi
}

post_window_quiescence() {  # post_window_quiescence <outdir> <窗口秒数>；按 PERIOD 决定"什么样的收尾算合格"
  # 收尾**再问一次**探针：若"距离上次人手事件"仍短于刚录的窗口，说明窗口里有人动过手。
  # idle 档要的是"整窗没人动"；interact 档要的正好相反——没人动那批只能退回当 idle 数。
  local out="$1" window="$2" quiet period="${PERIOD:-idle}" verdict
  quiet=$(quietest_seconds "$(quiescence_probe)")
  probe_usable "$quiet" || { echo "    （收尾静默探针取不到，污染判定不做）"; return 0; }
  verdict=$(human_input_in_window "$quiet" "$window")
  meta_write "$out" "quiescence_after_seconds=$quiet" "period=$period" "window_verdict=$verdict"
  if [ "$period" = "interaction" ]; then
    if [ "$verdict" = "窗口内没人" ]; then
      meta_write "$out" "no_human_input_during_window=1"
      echo "    ⚠ 整个 ${window}s 窗口里**没有一次人手事件**（距上次 ${quiet}s）——" >&2
      echo "      这批量的是心跳期，不是交互期。要判 T1 必须重跑并真的持续滚动。" >&2
    else
      # 这里**不许说"真人"**：探针读的是 `.combinedSessionState`，本来就不区分手与 CGEvent 投递
      # （09-22 实测：合成滚动整窗在投时这行印成了"确有真人输入"，而 meta 写的是 synth@8ms
      #  ——假归属会被引用成"这批是用户亲手滚出来的"）。来源让给 meta 去说。
      echo "    复核通过：窗口内确有输入事件（距上次 ${quiet}s < ${window}s；" \
           "来源见 meta.input_source=${INPUT_SOURCE:-未记录}），可当交互期样本"
    fi
  elif [ "$verdict" = "窗口内有人" ]; then
    meta_write "$out" "contaminated_by_human_input=1"
    echo "    ⚠ **这批样本被污染**：录制窗口 ${window}s 内人手在 ${quiet} 秒前还在动。" >&2
    echo "      已写进 meta（contaminated_by_human_input=1），不得进前后对比表。" >&2
  else
    echo "    收尾复核：整窗口无人手输入（距上次事件 ${quiet}s ≥ ${window}s）"
  fi
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

refuse_sample() {  # refuse_sample <outdir> <原因…>：一趟当场自认没采到数
  # 形状与上面那道上下文闸门一致（同一个 `REFUSED` 文件、同一个读者）：
  # `usable_sample` 与 `perf_trio_agreement` 都按这个文件跳趟。
  # **不再另开一枚 meta 键**：理由写进正文就已经有读者，再开键就是第二个入口。
  printf 'REFUSED\n%s\n' "$2" > "$1/REFUSED"
}

record_bounded() {  # record_bounded <outdir> <trace 路径> <模板> <时长秒>
  # 触发这条的实测（09-23 10:38→11:50）：被测实例在录制中途消失，而 `--time-limit 20s`
  # **从不触发**——它计的是采到的时间，目标没了就没有时间可计。于是 xctrace 挂在死目标上
  # 一整小时（trace 停在 52 KB），整条 M2 收尾链白烧一个稀缺窗口。
  # 导表那一侧的诚实性是好的（五张表全报「未覆盖」、没编数），坏的是没有墙钟上限、
  # 也没有"被测进程活到窗口末尾没有"这一步复核。
  # 本机没有 coreutils 的 `timeout`（那个叫 gtimeout），所以用"后台起 + 轮询 +
  # 只收自己 spawn 的那个 pid"（横切约束 2.1：绝不按名字广播 kill）。
  local out="$1" trace="$2" template="$3" secs="$4" pid rc=0 waited=0
  local limit=$((secs + RECORD_SLACK_S))
  echo "    \$ xcrun xctrace record --template $template --attach $PID --time-limit ${secs}s --output $(basename "$trace")（墙钟上限 ${limit}s）"
  [ "$DRY_RUN" = "1" ] && return 0
  xcrun xctrace record --template "$template" --attach "$PID" \
    --time-limit "${secs}s" --output "$trace" --no-prompt --quiet &
  pid=$!
  while [ "$waited" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || break     # kill -0 只探活，不发信号
    sleep "$RECORD_POLL_S"; waited=$((waited + RECORD_POLL_S))
  done
  local stuck=0
  if kill -0 "$pid" 2>/dev/null; then
    stuck="$waited"
    echo "    ⚠ 录制到墙钟上限 ${limit}s 仍未收尾 ⇒ 只收自己起的采集进程 pid=$pid"
    kill -TERM "$pid" 2>/dev/null
  fi
  wait "$pid" 2>/dev/null || rc=$?
  if ! kill -0 "$PID" 2>/dev/null; then
    refuse_sample "$out" "这一趟判废：被测进程 pid=$PID 在录制期间消失（走了 ${waited}s，卡住 ${stuck}s）——那份 trace 里必然没有数。"
    die "被测进程在录制期间消失 ⇒ 这一趟判废（宁可没数，也不要一份五张表全空的『读数』）"
  fi
  if [ "$stuck" != "0" ]; then
    refuse_sample "$out" "这一趟判废：xctrace 未在墙钟上限 ${limit}s 内自行停表（挂死 ${stuck}s）。"
    die "录制挂死 ⇒ 这一趟判废"
  fi
  [ "$rc" = "0" ] || echo "    ⚠ xctrace record 退出码 $rc（导表那一步会如实报缺哪张表）"
  return 0
}

require_covered_evidence() {  # require_covered_evidence <outdir>：一张表都没行数 ⇒ 这趟不算完成
  # 为什么必须在代码里：`perf_wait_window.sh` 的 `✓ 第 i 趟完成` 只看本脚本的退出码，
  # 而 `set -uo pipefail`（无 -e）让失败的 xctrace 一路走到 summary 照样退 0 ⇒
  # 今天那趟五张表全空也被印成「✓ 完成」，只差没被计进 3/3。
  local out="$1" t
  [ "$DRY_RUN" = "1" ] && return 0     # 演练档本来就不导表，不拿这条判它
  for t in hitches hitches-renders time-profile; do
    [ -s "$out/$t.xml" ] && return 0
  done
  refuse_sample "$out" "这一趟判废：三张关键表（hitches / hitches-renders / time-profile）一张都没有行数。"
  die "采不到任何一张关键表 ⇒ 这趟不许被印成『完成』（见同目录 REFUSED）"
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
