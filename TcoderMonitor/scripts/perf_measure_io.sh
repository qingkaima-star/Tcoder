#!/bin/bash
# =============================================================================

# 判废与覆盖那一族函数搬进了 `perf_measure_verdicts.sh`（本仓 400 行口径：拆文件才是修复）。
# **必须由这里 source**：preflight 与 selfcheck 的夹具都是单独 source 本文件的，
# 换源点就会造出第二个入口、各拿一半函数（本文件头注第 7~9 行写的那条链）。
source "$(dirname "${BASH_SOURCE[0]}")/perf_measure_verdicts.sh"  # shellcheck source=/dev/null
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
  # 阈值走 `load_bar`：**不在这里重写一遍式子**——两处式子早晚各判各的（闸门放行、复核说脏）
  if [ -n "$jobs" ] || awk -v l="$load1" -v b="$(load_bar)" 'BEGIN{exit !(l > b)}'; then
    meta_write "$out" "contaminated_by_foreign_load=1"
    echo "    ⚠ 窗口结束时整机在忙（load1=$load1/$cores，重活=${jobs:-无}）" >&2
    echo "      ⇒ 这批 hitch 分布会被外部争用主导，**不作数**（闸门只看了窗口开始那一刻）。" >&2
  fi
  # 两端之外还要问"中段呢"：窗口内那几发的峰值在这里定合格与否（§AP：八趟里只有一趟落在红线内，
  # 而那趟的收窗负载是 19.73——旧复核放行它，就是因为只看两端）。
  load_window_verdict "$out"
}

post_window_quiescence() {  # post_window_quiescence <outdir> <窗口秒数>；按 PERIOD 决定"什么样的收尾算合格"
  # 收尾**再问一次**探针：若"距离上次人手事件"仍短于刚录的窗口，说明窗口里有人动过手。
  # idle 档要的是"整窗没人动"；interact 档要的正好相反——没人动那批只能退回当 idle 数。
  local out="$1" window="$2" quiet period="${PERIOD:-idle}" verdict
  quiet=$(quietest_seconds "$(quiescence_probe)")
  if ! probe_usable "$quiet"; then
    # 【#127 的根治】取不到**不许只印一行**：原来这里什么都不落就 `return 0`，
    # 而唯一的资格判据 `period_eligibility` 的形状是「没有污染标记就算合格」
    # ⇒ 尺子掉下来的那一趟**必然放行**：交互档印「有资格答 T1」、心跳档印「只答心跳期」，
    # 两句都是绿灯，而且同一句还被一致性尺（`perf_trio_agreement`）读进 3/3 的计数。
    # 「探针时好时坏地报 -1.00」不是假想：`quiescence_probe` 编译到 $SCRATCH 下的哈希名，
    # 别的会话在同名位置放个目录就编译失败（`perf_probes.sh` 头注 ①② 记的就是这个形状）。
    # ⇒ 把「未判」落成显式标记，交给资格尺去拒。**只加字段，不加闸门**：
    #   本函数照旧 return 0、样本照旧留盘，拒发生在引用那一刻（不在录制中途灭失一趟）。
    meta_write "$out" "quiescence_recheck=unavailable" "period=$period"
    echo "    （收尾静默探针取不到 ⇒ 人手这一维**未判**，已落 meta.quiescence_recheck=unavailable）" >&2
    echo "      这一趟不得作为判据①/② 的达标证据：既没证「窗口内有人在动」也没证「没人动」。" >&2
    return 0
  fi
  verdict=$(human_input_in_window "$quiet" "$window")
  # `quiescence_recheck=measured` 这一格是**正对照**：没有它，「没写成 unavailable」与
  # 「这段代码根本没跑」在下游长得一模一样（第 46 类「标记要有读者」的正半句）。
  meta_write "$out" "quiescence_recheck=measured" "quiescence_after_seconds=$quiet" \
    "period=$period" "window_verdict=$verdict"
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

export_table() {  # export_table <trace> <schema> <outdir> [落盘文件名覆写]
  # 第 4 个参数**只给归因档用**：同一次双仪器录制里的 time-profile 表，schema 名与
  # 独立那一趟完全相同，若按 schema 落盘会**盖掉认证档的 time-profile.xml**
  # ——两份不同窗口的读数共用一个文件名，是"两个入口一个数"那条老病的文件版。
  # 所以这里必须能改名落盘（`blame-time-profile.xml`），让两把尺各读各的。
  local trace="$1" schema="$2" out="$3" name="${4:-}" err
  [ -n "$name" ] || name="$schema.xml"
  [ "$DRY_RUN" = "1" ] && { echo "    \$ xctrace export --input $(basename "$trace") --xpath '…@schema=\"$schema\"' --output $out/$name"; return 0; }
  # 【缺表的原因要留档（#119）】原来这一行是 `>/dev/null 2>&1`，于是两件**意义相反**的事塌成同一句
  # 「不存在或为空」：① trace 真的坏了（2026-09-27 实测：某趟 `hitches.trace` 13 GB 却打不开，
  # 手动 export 报 `Document Missing Template Error`，树里只有 `RunIssues.storedata`＋`Attachments`、
  # 没有 `instrument_data`）；② 这张表本来零行（被测代码真不卡）。
  # 前者意味着"这趟坏了"、后者意味着"结论是好的"——压成一句就两头都会读错。
  # 只收 **stderr**（stdout 那侧是 xctrace 写的 XML，不能被命令替换吃掉）。
  err=$(xcrun xctrace export --input "$trace" \
      --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
      --output "$out/$name" 2>&1 >/dev/null)
  if [ -s "$out/$name" ]; then
    [ -n "$err" ] && printf '%s\t%s\n' "$schema" "$err" >> "$out/export-errors.txt"   # 有数但出过声，也留
    echo "    导出 $name（$(wc -c < "$out/$name" | tr -d ' ') 字节）"
  else
    rm -f "$out/$name"
    printf '%s\t%s\n' "$schema" "${err:-（xctrace 未出声，落盘为空）}" >> "$out/export-errors.txt"
    echo "    ⚠ 表 $schema 没拿到数（原因见 $out/export-errors.txt）—— 汇总表会写「未覆盖」，不会编数"
  fi
}

record_bounded() {  # record_bounded <outdir> <trace 路径> <模板> <时长秒> [附加仪器]
  # 触发这条的实测（09-23 10:38→11:50）：被测实例在录制中途消失，而 `--time-limit 20s`
  # **从不触发**——它计的是采到的时间，目标没了就没有时间可计。于是 xctrace 挂在死目标上
  # 一整小时（trace 停在 52 KB），整条 M2 收尾链白烧一个稀缺窗口。
  # 导表那一侧的诚实性是好的（五张表全报「未覆盖」、没编数），坏的是没有墙钟上限、
  # 也没有"被测进程活到窗口末尾没有"这一步复核。
  # 本机没有 coreutils 的 `timeout`（那个叫 gtimeout），所以用"后台起 + 轮询 +
  # 只收自己 spawn 的那个 pid"（横切约束 2.1：绝不按名字广播 kill）。
  #
  # 第 5 个参数是**归因档专用**的附加仪器（`BLAME_INSTRUMENT=1` 时传 `Time Profiler`）：
  # 一次录制同时挂两枚仪器，两条时间轴才天然同窗，才允许把长 update 归到栈上（#43）。
  # 它**必须**由资格闸把这一档挡在达标计数之外（`period_eligibility` 读
  # `blame_instrument`），否则就是拿"被采样器改过的条件"去认证"没被改过"。
  local out="$1" trace="$2" template="$3" secs="$4" extra="${5:-}" pid rc=0 waited=0
  local limit=$((secs + RECORD_SLACK_S))
  echo "    \$ xcrun xctrace record --template $template --attach $PID --time-limit ${secs}s${extra:+ --instrument $extra} --output $(basename "$trace")（墙钟上限 ${limit}s）"
  [ "$DRY_RUN" = "1" ] && return 0
  # 参数向量用 `set --` 造，**不用数组**：本机 /bin/bash 是 3.2，`set -u` 下展开空数组
  # 直接 `unbound variable`（实测 rc=127）—— 那会让**每一趟常规录制**死在这一步，
  # 而不是只在归因档出错。前面五位已经取进局部变量，改 `$@` 不丢参数。
  set -- --template "$template" --attach "$PID" --time-limit "${secs}s"
  [ -n "$extra" ] && set -- "$@" --instrument "$extra"
  xcrun xctrace record "$@" --output "$trace" --no-prompt --quiet &
  pid=$!
  waited=$(record_wait_loop "$out" "$pid" "$limit")
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
    wallclock_verdict "$out" "$trace" "$template" "$stuck" "$limit" || die "录制挂死 ⇒ 这一趟判废"
  fi
  [ "$rc" = "0" ] || echo "    ⚠ xctrace record 退出码 $rc（导表那一步会如实报缺哪张表）"
  return 0
}

meta_write() {  # meta_write <outdir> <键=值...>
  local out="$1"; shift
  # 目录由本函数自己保证存在：cmd_switch 的 mkdir 在 per-page 循环里，
  # DRY_RUN 下整段被跳过，于是第一次 meta_write 会写进不存在的目录（实测 traceback）。
  mkdir -p "$out" 2>/dev/null || { echo "    ⚠ meta_write 建不了 $out，本条 meta 丢失" >&2; return 0; }
  # 【`rev` 与 `measured_rev` 是两件事，缺一就会盖错章】
  # `rev` 回答"哪个检出目录跑了这次测量"，`measured_rev` 回答"这份读数归属于哪份内容"。
  # 2026-09-23 做 T4 的 A/B 时现场抓的：换 `PERF_BIN` 去量另一个 rev 的产物，
  # 盘上只有 `rev=`（跑脚本那棵树的 HEAD）⇒ 旧产物的读数被盖上了新 rev 的章，
  # 真相只藏在 run 级的 `binary=` 路径里，而报告读者根本不会去解析路径。
  # 归属那把尺**只此一家**（`provenance_target_rev`，包 5 就是为这件事开的口子），这里不再拼 git 命令。
  local measured
  measured=$(provenance_target_rev 2>/dev/null) \
    || measured=""
  [ -n "$measured" ] || measured="取不到（MEASURE_REV=${MEASURE_REV:-未设}）"
  # 【`measured_rev` 答"是谁"，`main_product_drift` 答"落后 main 几笔产品码"】
  # 只有前一格时，"内部完全一致、对外已经过期"这类判废在**测量侧从来没有读数**
  # （`is-ancestor` 只活在合流侧 `merge_stream.sh`）。这一格把盲区变成数字：
  # 口径、`:/` pathspec、"取不到≠0" 三条都写在 `provenance_main_drift` 的注释里，
  # 本处不复刻判定（同一件事不许有两把手抄尺子）。**只加字段，不加闸门。**
  local drift
  drift=$(provenance_main_drift)
  python3 - "$out/meta.json" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$REV" "$DIRTY" \
    "measured_rev=$measured" "main_product_drift=$drift" "$@" <<'PY'
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
filter_out_pids() {  # filter_out_pids <候选 pid 串> <要排除的 pid 串> → 剩下的（空格分隔）
  # 为什么要有它：**录制窗口里必然有我们自己 spawn 的 xctrace**，而 xctrace 在重活名单里
  # （它暂停/恢复被测进程，确实是最重的争用）。于是"窗口内重活个数"这一维把每一批都判污染
  # ——2026-09-23 22:03 三趟的 heavy 峰值 3/2/3 里就有自己那一个，机器空不空都过不了。
  # 排除只按 **pid** 排（按名字排会把别人那一趟 xctrace 一起放掉，那是关掉一条真判据）。
  local keep="" cand drop x
  for cand in ${1:-}; do
    drop=0
    for x in ${2:-}; do
      [ "$cand" = "$x" ] && { drop=1; break; }
    done
    [ "$drop" = "0" ] && keep="$keep $cand"
  done
  printf '%s\n' "${keep# }"
}

heavy_names_for_pids() {  # heavy_names_for_pids <明细串> <保留的 pid 串> → 只含这些 pid 的 `pid=name` 串
  # 单独一支函数的理由（09-24 #49）：明细列以前用**第二种**过滤法（`grep -vF -x` 去比 `pid=<self>`），
  # 而明细行的形状是 `pid=<self> name=xctrace`，整行永不相等 ⇒ 计数排掉了自己、明细却把自己的
  # 采集进程写成"在场的重活"。归属说错比不说更坏：读 tsv 的人去找一个不存在的干扰源
  # （我自己 12:33 就照着 run4 那行 `pid=32337 name=xctrace` 立过一张错单，两分钟后撤回）。
  local detail="$1" p out=""
  for p in ${2:-}; do
    out="$out$(printf '%s' "$detail" | grep -oE "pid=$p name=[^ ]+" | head -1) "
  done
  printf '%s\n' "${out% }"
}

land_cadence_verdict() {  # land_cadence_verdict <outdir>：把判据① 那半句**落到批次产物里**（#123）
  # 旧写法只在 `perf_report.sh` 里 `… | tail -7 | sed … || true`——判定没有持久读者：
  # 判据① 唯一的取证出口是真人滚 3×30 秒（AGENTS §2.2 禁一切点击/滚动自动化），
  # 那种稀缺窗口拍完若只剩一次 stdout 的尾巴，就等于没量过（`tail -7` 还可能把判定截掉）。
  # ⇒ 全文落 `cadence.txt`、判定行落 `cadence-verdict.txt`；**缺输入也要写**「未采到」，
  #   三态齐（达标／未达标／未采到）才不许把"没输入"读成"过了"。report 档的退出码不改（既定口径）。
  # 住在这一层是因为录制侧（`cmd_idle`）与重打侧（`cmd_report`）都要用同一个出口——两处各写一份必然分叉。
  local out="$1"
  if [ -s "$out/hitches-renders.xml" ]; then
    python3 "$CADENCE_REPORT" "$out/hitches-renders.xml" --pulse "$out/pulse.txt" \
        --verdict-out "$out/cadence-verdict.txt" > "$out/cadence.txt" 2>&1 || true
    [ -s "$out/cadence.txt" ] && tail -7 "$out/cadence.txt" | sed 's/^/    /'
  else
    printf '未采到（缺 hitches-renders.xml ⇒ 帧间隔 p95 这条判据没有输入）\n' > "$out/cadence-verdict.txt"
    echo "    ⓘ 这一趟没有 hitches-renders.xml ⇒ 呈现侧节拍**未采到**（已写进 cadence-verdict.txt，不是达标）"
  fi
}

load_sample_once() {  # load_sample_once <outdir> [自己 spawn 的采集 pid] [被测 pid] —— 追加一行「时刻/load1/重活数/明细/在场/前台」
  # 为什么挂在 `record_bounded` 的轮询里而不是自己起后台子壳：那个 poll 循环本来就在窗口内每 5 s 醒一次，
  # 借它顺手采样**不新增进程**，也就不会有"录制链半路 die 掉、留下一个还在写 tsv 的孤儿"这种形状
  # （`record_bounded` 自己就得对付挂死与被测消失两条路，别再给它加一条）。
  local out="$1" self="${2:-}" tpid="${3:-}" l j pids
  # 分两行声明：同一条 `local` 里引用自己前半段的名字，$out 还是空的
  # （今天在第 49 项的夹具里刚踩过同一条，两处一起改）。⇒ 路径必须单独一步拼。
  local f="$out/load-in-window.tsv"
  [ -n "$out" ] || return 0
  mkdir -p "$out" 2>/dev/null || return 0
  l=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  # 「自己那一个 xctrace 不算外部争用」——不排就等于**每批必判污染**（见 filter_out_pids 的注释）。
  # 取**明细**而不是光取 pid 串：02:16 那两趟的 `heavy_max_in_window` 都是 2，
  # 一个数字分不出"别人在编译"和"我自己那个 xctrace 生了个子进程"，
  # 而这两种结论要做的动作完全相反（等窗口 vs 修尺子）。第三列仍是计数（判定读它），
  # 第四列是 `pid=name` 明细，只有出数的那一行会进 meta，用来回答"刚才是谁"。
  local detail; detail=$(concurrent_heavy_jobs_detail 2>/dev/null)
  pids=$(printf '%s' "$detail" | grep -o 'pid=[0-9]*' | cut -d= -f2 | tr '\n' ' ')
  pids=$(filter_out_pids "$pids" "$self")
  j=$(printf '%s' "$pids" | wc -w | tr -d ' ')
  # 第四列**必须复用第三列那一份已过滤的 pid 集**，不许有第二种过滤法（理由见 `heavy_names_for_pids`）。
  local names; names=$(heavy_names_for_pids "$detail" "$pids")
  # 第 5、6 列是**读数**（#53 裁定 C：只加读数、不动任何阈值）：
  # 「整窗里这个 App 到底在不在屏上」今天没有任何一维记录，而 cert7c-idle-run3 那趟
  # 出帧 p50 从 112 掉到 4，meta 里除时刻与负载外无一维可解释 ⇒ 一趟"几乎不在屏上画"的样本
  # 会同时给出 hitch=0 与 update max 很小（**没在跑所以不卡**）。先让它可被看见，再谈要不要设线。
  local pres; pres=$(sample_presence "$tpid")
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "${l:-0}" "${j:-0}" "${names:-无}" "$pres" >> "$f"
}

sample_presence() {  # sample_presence <被测 pid> → `在屏|前台名` / `不在屏|前台名` / `未知|前台名`
  # **绝不在测量窗口里现编 swiftc**（`winlist_ensure_bin` 的注释记着撞过的挂死）：
  # 只认 `preflight` 在计时窗外编好的那份稳定产物（`winlist_resolve`）；拿不到就记「未知」。
  local tpid="$1" seen on front
  [ -n "$WINLIST_BIN" ] || winlist_resolve || true
  front=$(preflight_front_app)
  if [ -z "$tpid" ] || [ -z "$WINLIST_BIN" ]; then
    printf '未知|%s\n' "$front"; return 0
  fi
  seen=$(winlist_probe "$tpid" | head -1)
  on="不在屏"
  [ -n "$seen" ] && on="在屏"
  # ⚠ 已知歧义：探针**失败**时也返回空 ⇒ 这一格会把"探不到"记成"不在屏"。
  # 正因如此，本维**只作读数、不作判定**（#53 裁 C 就是这么定的）；
  # 哪天要拿它设线，先把这个歧义消掉（区分"探针说了没有"与"探针没说话"）。
  printf '%s|%s\n' "$on" "$front"
}

load_window_verdict() {  # 把**窗口内峰值**判一次并落 meta：两端干净 ≠ 整窗干净（§AP 今天八趟的现证）
  local out="$1" maxl=0 jobs=0 n=0 bar
  local f="$out/load-in-window.tsv"   # 同上：$out 要先声明完再用
  [ -s "$f" ] || { meta_write "$out" "load_in_window=未采到"
                   echo "    ⚠ 窗口内一个负载样本都没采到 ⇒『整窗干净』这句话没有依据（已写进 meta）" >&2
                   return 0; }
  maxl=$(cut -f2 "$f" | sort -g | tail -1); jobs=$(cut -f3 "$f" | sort -g | tail -1)
  # 出数那一行的明细（"刚才是谁"），只给话术用，不参与判定
  who=$(awk -F'\t' -v j="$jobs" '$3==j && $3>0 {print $4; exit}' "$f")
  n=$(wc -l < "$f" | tr -d ' '); bar=$(load_bar)
  meta_write "$out" "load1_max_in_window=${maxl:-0}" "heavy_max_in_window=${jobs:-0}" \
                   "heavy_names_at_peak=${who:-无}" "load_samples=$n" "load_bar_used=$bar"
  # 「整窗在场」这一维**只落读数、不参与判定**（#53 裁 C）。旧批次没有第 5 列 ⇒ 明写"没采到"，
  # 不许让"没有这一格"被下游读成"整窗都在屏"。
  local pon poff puk pnone sum
  pon=$(cut -f5 "$f" 2>/dev/null | cut -d'|' -f1 | grep -c '^在屏$' || true)
  poff=$(cut -f5 "$f" 2>/dev/null | cut -d'|' -f1 | grep -c '^不在屏$' || true)
  puk=$(cut -f5 "$f" 2>/dev/null | cut -d'|' -f1 | grep -c '^未知$' || true)
  pnone=$((n - pon - poff - puk))
  if [ "$pnone" -gt 0 ]; then
    sum="这一维没采到（旧批次没有第 5 列，$pnone/$n 发缺项）"
  else
    sum="在屏 $pon／不在屏 $poff／未知 $puk（共 $n 发）"
  fi
  meta_write "$out" "presence_on=$pon" "presence_off=$poff" "presence_unknown=$puk" \
                   "presence_summary=$sum"
  echo "    窗口内在场读数（**只读数、不判定**）：$sum"
  if awk -v l="${maxl:-0}" -v j="${jobs:-0}" -v b="$bar" 'BEGIN{exit !(l > b || j > 0)}'; then
    meta_write "$out" "contaminated_by_foreign_load=1"
    echo "    ⚠ 窗口内出现过高负载或重活（峰值 load1=$maxl、重活个数峰值 $jobs、采样 $n 次、阈值 $bar）" >&2
    echo "      ⇒ 起窗与收窗都干净也没用：这批量的是别人占着机器时的主线程，不作数。" >&2
  else
    echo "    窗口内负载采样：$n 次，峰值 load1=$maxl ≤ 阈值 $bar、重活峰值 $jobs ⇒ 整窗干净"
  fi
}
