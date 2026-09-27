#!/bin/bash
# =============================================================================
# perf_measure_verdicts.sh —— 「这一趟当场怎么判」那一层：判废、分类、重试裁决、覆盖点名。
# 自 `perf_measure_io.sh` **逐字搬出**（2026-09-27 §212／#117：给 `export_table` 补"缺表原因留档"
# 再加两支配函数之后，宿主涨到 **428 行**，越过仓库自己那把「巨大文件」口径
# `FileSystemCodeAnalyzer.mediumFileLines = 400` ⇒ 本仓规约是**拆，不抬线**，不是往名单里塞条目）。
#
# 由 `perf_measure_io.sh` 自己 source（不是由调用方各自 source）：
# `perf_preflight.sh` 与 `perf_selfcheck_windows.sh` 都是**单独 source io 那一层**的，
# 换源点就会造出两个入口各拿一半函数——那正是 io 头注第 7~9 行警告过的形状。
# 判据、告警文案、退出码逐字未动；新建这块文件当场进 `PerfRulerHotspotRatchetTests.rulerScripts`
# （函数级 ≤50 行／CC<16 那两把尺），否则"拆"本身变成免检通道。
# =============================================================================

# 【idle 档那族表的名单：唯一住处搬进这一层（#125）】
# 它原先住在 `perf_harness.sh`，而 `criterion2_batch_line` 的**真实调用点** `perf_wait_window.sh`
# 不经过 harness ⇒ `set -u` 下展开未定义数组当场 `unbound variable`、循环一次不跑，
# 于是 `cert17` 三趟都带表却被印成「含 ② 那一族表的 0 趟」（2026-09-27 实盘，假零）。
# 消费它的两处（`require_covered_evidence`／`run_covers_criterion2`）都在本层，名单就跟着搬来本层。
# spec §4.1 的六张表；包 13（§AC）补的三张**一帧一行**的表——不导出来，T1 就只剩 `hitches`
# 那一个下游计数，而它同一份内容能报 14 / 22 / 364 行，判据不能建在那上面。
HITCH_TABLES=(hitches hitches-updates hitches-renders potential-hangs
              hitches-framewait hitches-gpu hitches-frame-lifetimes
              device-display-info displayed-surfaces-per-second)

record_probe_schema() {  # record_probe_schema <模板名> → 该档用来验产物的那张表名
  # 为什么从模板派生而不是调用方各写一份：`record_bounded` 有两个 caller（hitches / time-profile），
  # 写死的第二份迟早与模板分叉——而分叉的方向永远是"探测错了表 ⇒ 可用的样本被判成挂死"。
  case "$1" in
    *Hitches*|*hitches*) echo hitches ;;
    *)                   echo time-profile ;;
  esac
}

trace_probe_usable() {  # trace_probe_usable <trace> <schema> <探针落盘名> → 0 产物能导出该表格（**零行也算**）
  # 【#121 的判据】墙钟到点不等于没采到：本机实测 `Animation Hitches` 录 20 s，
  # finalize 会花掉几分钟（原始 trace 一度 14 GB），而**那趟数据是完整的**——
  # `cert16-idle-run1` 被我按墙钟砍掉之后，手动导出仍然成功，`hitches` 表 1010 B／0 行
  # ＝「零卡顿」的正常形状（与 cert9a-idle-run1 那枚好样本同尺寸）。
  # 只看时钟判挂死 ⇒ 这台机器上**永远拿不到判据② 的样本**（本次实测 3/3 全被判废）。
  # ⇒ 到点之后**先看产物再判**：能导出表格就照常走导表那一步；导不出（或干脆没有 trace）才判废。
  # ⚠ 探测自己也要有墙钟，否则只是把挂死从录制挪到探测；且只收自己 spawn 的那个 pid。
  local trace="$1" schema="$2" probe="$3" pid rc=0 waited=0
  [ -e "$trace" ] || return 1     # 假 xcrun 那几格根本不会造 trace ⇒ 不启动探测器，旧行为原样
  xcrun xctrace export --input "$trace" \
      --xpath "/trace-toc/run[@number=\"1\"]/data/table[@schema=\"$schema\"]" \
      --output "$probe" >/dev/null 2>&1 &
  pid=$!
  while [ "$waited" -lt "${PROBE_BOUND_S:-90}" ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 2; waited=$((waited + 2))
  done
  if kill -0 "$pid" 2>/dev/null; then kill -TERM "$pid" 2>/dev/null; rc=1; fi
  wait "$pid" 2>/dev/null || rc=1
  if [ -s "$probe" ] && grep -q "<schema" "$probe"; then
    rc=0
  else
    rc=1
  fi
  rm -f "$probe"
  return "$rc"
}

record_wait_loop() {  # record_wait_loop <outdir> <采集 pid> <墙钟秒> → 印实际等了多久
  # 从 `record_bounded` 里抽出来是因为那个函数加进"判产物"这一枝之后顶到 59 行，
  # 而本仓「函数 ≤50 行」那把尺第十五轮刚红过两条（卷十三 §212）——拆函数，不抬线。
  # 循环本来就每 `RECORD_POLL_S` 秒在窗口内醒一次 ⇒ 顺手采一发整机负载：
  # 没有这一发，闸门只看得到"起窗前"和"收窗时"两个点，中段起的那趟编译看不见（§AP）。
  local out="$1" pid="$2" limit="$3" waited=0
  while [ "$waited" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || break     # kill -0 只探活，不发信号
    sleep "$RECORD_POLL_S"; waited=$((waited + RECORD_POLL_S))
    load_sample_once "$out" "$pid" "$PID"
  done
  printf '%s' "$waited"
}

wallclock_verdict() {  # wallclock_verdict <outdir> <trace> <模板> <卡住秒> <墙钟秒> → 0 产物可用／1 判废
  # 【#121：墙钟到点之后，判废要由产物说话】墙钟是 #14 为"永等 72 分钟"造的，但本机
  # `Animation Hitches` 录 20 s 的 **finalize 就要几分钟**（原始 trace 一度 14 GB），
  # 于是"到点"与"没采到"被同一把尺混判——2026-09-27 实测 `cert16` 三趟全被判废，
  # 而被砍掉那趟的 trace 手动导出仍然成功（`hitches` 表在、0 行＝零卡顿的正常形状）。
  # ⇒ 时钟只负责"停下来看"；导不出表格（或压根没有 trace）才真是挂死。
  local out="$1" trace="$2" template="$3" stuck="$4" limit="$5" schema
  schema=$(record_probe_schema "$template")
  if trace_probe_usable "$trace" "$schema" "$out/.trace-probe.xml"; then
    echo "    ✓ 墙钟到点（${stuck}s）但产物已能导出 $schema 表格 ⇒ 不判挂死，照常走导表那一步"
    echo "      （finalize 比墙钟慢 ≠ 没采到；判据见 #121，常驻臂 selfcheck 第 85 项四格）"
    return 0
  fi
  refuse_sample "$out" "这一趟判废：xctrace 未在墙钟上限 ${limit}s 内自行停表（挂死 ${stuck}s），且产物里导不出 $schema 表格。"
  return 1
}

refuse_sample() {  # refuse_sample <outdir> <原因…>：一趟当场自认没采到数
  # 形状与上面那道上下文闸门一致（同一个 `REFUSED` 文件、同一个读者）：
  # `usable_sample` 与 `perf_trio_agreement` 都按这个文件跳趟。
  # **不再另开一枚 meta 键**：理由写进正文就已经有读者，再开键就是第二个入口。
  printf 'REFUSED\n%s\n' "$2" > "$1/REFUSED"
}

# 【判废原因里"用来分类那半句"命名成常量（#117）】
# `refusal_kind` 只能按**文案**分类（这是上面那条「不开第二枚键」的决定换来的代价）。
# 本轮要加第二类"表族缺失"，如果让分类去猜一句新散文，那就是第四次栽在
# **语义守卫挂文本代理**上：写者换个词，读者静默降级成 `other`。
# ⇒ 写者与读者共用这两个名字；判据本身仍然只有 `REFUSED` 一个落点。
#   （另两类 `挂死`／`在录制期间消失`／`测量上下文不合格` 仍由各自写者的原句供给，
#     第 62 项拿**真路径**产出的 REFUSED 喂它们——迁移那三类不在本轮范围内，别顺手改。）
REFUSE_KIND_EMPTY_TABLES="一张都没有行数"      # 三张关键表全空（既有类）
REFUSE_KIND_NO_CRITERION="判据表整族缺失"      # 新增：这一档答不了它自己存在的理由（同归 empty_tables）

refusal_kind() {  # refusal_kind <outdir> → hang / target_gone / empty_tables / context_gate / other / none
  # 只读 `REFUSED` 的**原因行**：那是 `refuse_sample` 唯一的落点，另开一枚机读键就是
  # 第二个入口（两份迟早分叉，而分叉的方向永远是"看起来更宽松的那一份"）。
  # ⚠ 这是**按文案匹配**：改上面那三句判废文案会把它降级成 `other` ⇒ 少补一次重试
  #   （方向安全：绝不会把坏样本放进来）。第 62 项反例喂给它的是**真路径产出的** REFUSED
  #   （假 xcrun 走 `record_bounded`、真闸门走 `preflight_context`），
  #   所以文案与判据一分叉那一项当场红。
  # `context_gate` 是 2026-09-25 t20 批补上的第四类：那一趟**根本没开录**就被闸门拒了
  #   （当晚两次都掉进 `other`，小结只能说"不是挂死"、说不出"为什么不用补"）。
  local file="$1/REFUSED" reason
  [ -f "$file" ] || { echo none; return 0; }
  reason=$(sed -n '2p' "$file")
  case "$reason" in
    *挂死*)               echo hang ;;
    *在录制期间消失*)      echo target_gone ;;
    *"$REFUSE_KIND_EMPTY_TABLES"*)   echo empty_tables ;;
    *"$REFUSE_KIND_NO_CRITERION"*)   echo empty_tables ;;   # 表族缺失不是"再试一次"能救的（同 #55 判据）
    *测量上下文不合格*)     echo context_gate ;;
    *)                    echo other ;;
  esac
}

attempt_verdict() {  # attempt_verdict <outdir> <这一趟的退出码> → retry（同窗补一次）/ slot（占掉一个计划槽位）
  # #55 的判据：**只有录制挂死**值得在同窗原地补一次——挂死时环境往往仍然干净，
  # 而一次挂死的真实代价不是那 140 秒，是**把一个稀缺的干净窗口整段扔掉**。
  # 别的判废原因（人手静默不够、被测进程消失、表全空）都不补：那些恰恰说明**这个窗口不行**，
  # 补一次只会把同一份坏条件再量一遍。
  # 预算**按批封顶**（默认 1 次，`HANG_RETRY_BUDGET` 可调）：每条挂死都免费补一次
  # = "攒够可用为止"那种数据相关的停止规则，那正是单向朝好看的计数那一族。
  local out="$1" rc="$2"
  [ "$rc" = "0" ] && { echo slot; return 0; }
  [ "$(refusal_kind "$out")" = "hang" ] || { echo slot; return 0; }
  if [ "${HANG_RETRIES_USED:-0}" -lt "${HANG_RETRY_BUDGET:-1}" ]; then
    echo retry; return 0
  fi
  echo slot        # 挂死但预算已用完 ⇒ 照旧占槽位，而挂死计数仍要加（见 batch_hang_summary）
}

hang_recovery_meta_arg() {  # 补试那一趟要往 meta 里加的整枚参数；没挂过的趟**一个字节都不吐**
  # 为什么是**函数**而不是在调用点直接写 `${HANG_RECOVERED:+…}`：反例（第 62 项）必须喂同一个
  # 出口。写在调用点的话，反例只能自己抄一份表达式——那份副本和真的那处一起腐烂，没人管。
  # 也不用"键值写 0"：那会让每一趟都带一枚 `hang_recovered`，哪些读数是补出来的反而分不出。
  printf '%s' "${HANG_RECOVERED:+hang_recovered=$HANG_RECOVERED}"
}

batch_hang_summary() {  # batch_hang_summary <挂死趟数> <用掉的补试次数> <补试补回来的可用趟数>
  # 挂死计数**必须照印**，哪怕补试全部成功：重试是为了"别把好窗口扔了"，
  # **不是**为了把这一维的失败率抹成 0。
  local hangs="$1" used="$2" recovered="$3" budget="${HANG_RETRY_BUDGET:-1}"
  if [ "$hangs" = "0" ]; then
    echo "    录制挂死：0 趟（这一批一趟都没挂）"
    return 0
  fi
  echo "    录制挂死：$hangs 趟 ⇒ 同窗补试 $used 次（本批封顶 $budget 次），补回可用 $recovered 趟"
  echo "      补试不换窗口、不顺延预热（同一枚实例、同一个 measured_rev）；挂死那几趟的 REFUSED 原样留在盘上，一致性尺照旧跳它们"
}

criterion1_missing() {  # criterion1_missing <outdir> → 空＝四张齐；否则空格分隔的缺表名
  # 【#130】判据① 的权威读数只来自这三张**一帧一行**的表 + 呈现侧 `hitches-renders` 的 p95（包 13／§AC）：
  # `hitches` 那一枚下游计数同一份内容能报 14 / 22 / 364 行，判据不能建在它上面。
  # ⚠ 这四个名字**必须都在 `HITCH_TABLES` 里**（导表那一步的唯一名单）——
  # 手抄一份子清单迟早与导表分叉，而分叉的方向永远是"看起来更宽松的那一份"（#117 同一课）。
  # 判"在不在"沿用 `require_covered_evidence` 的**文件存在性**口径：零 hitch 的完美一趟照样落表，
  # 按行数判会把"真不卡"误杀成"这趟坏了"。
  local c1 miss=""
  for c1 in hitches-renders hitches-framewait hitches-gpu hitches-frame-lifetimes; do
    [ -f "$1/$c1.xml" ] || miss="$miss $c1"
  done
  printf '%s' "$miss"
}

require_covered_evidence() {  # require_covered_evidence <outdir>：这一档答不了它自己存在的理由 ⇒ 不算完成
  # 为什么必须在代码里：排程器那句"这一趟完成"的 ✓ 只看本脚本的退出码，
  # 而 `set -uo pipefail`（无 -e）让失败的 xctrace 一路走到 summary 照样退 0 ⇒
  # 今天那趟五张表全空也被印成「✓ 完成」，只差没被计进 3/3。
  # 【#117：从"有没有任意一张表"改成"判据要的那一族在不在"】
  # 旧写法只查 `hitches / hitches-renders / time-profile` 里**任意一张**非空 ⇒
  # 2026-09-27 实测：交付头上那趟 `cert14probe-idle-run2` 九张 hitch 族表**一张都没落盘**
  # （它的 `hitches.trace` 13 GB 打不开，见 #119），只靠 `time-profile.xml` 就"落定"了，
  # 而 summary 里判据② 那四行全印「未覆盖」。⇒ **「落定 N 趟」不等于「② 有 N 个样本」**，
  # 这个混用让 #47 那句"四趟可用"从写下那天起就是前一种口径。
  # 判"在不在"用**文件存在性**而不是行数：零 hitch 的完美一趟照样落表（cert9a-idle-run1 实测
  # `hitches.xml` 1010 B／`hitches-updates.xml` 2064 B／`potential-hangs.xml` 686 B），
  # 按行数判会把"真不卡"误杀成"这趟坏了"——反向阈值要先问失败值在哪端。
  local out="$1" t hit=0 tp=0
  # 【这两条判废为什么自己 `return 1`、不写 `die`】本仓有条明文规约：闸门说不合格就是不合格，
  # 不许依赖被调函数里的 `die`——`die` 缺席时它只是"回 1 就完了"，而本函数在判废之后**还有两条分支**，
  # 于是判废会一路走到末尾的 `return 0`。09-27 冒烟实测到这个形状（只 source preflight、
  # 环境里没有 `die` 时，缺表的目录 rc=0）。⇒ 自己出声、自己退 1，
  # 怎么停由调用点决定（`perf_harness.sh` 那句 `|| die` 就是它的停法）。
  [ "$DRY_RUN" = "1" ] && return 0     # 演练档本来就不导表，不拿这条判它
  for t in "${HITCH_TABLES[@]}"; do    # 表名单一来源：就是导表那一步用的那份，不手抄
    [ -f "$out/$t.xml" ] && { hit=1; break; }
  done
  [ -f "$out/time-profile.xml" ] && tp=1
  if [ "$hit" = "0" ] && [ "$tp" = "0" ]; then
    refuse_sample "$out" "这一趟判废：三张关键表（hitches / hitches-renders / time-profile）$REFUSE_KIND_EMPTY_TABLES。"
    echo "!! 采不到任何一张关键表 ⇒ 这趟不许被印成『完成』（见同目录 REFUSED）" >&2
    return 1
  fi
  if [ "$hit" = "0" ]; then
    refuse_sample "$out" "$REFUSE_KIND_NO_CRITERION：这一趟没有判据② 要的任何一张表（${HITCH_TABLES[*]}），time-profile 有数也答不了 ②；缺表原因见 $out/export-errors.txt。"
    echo "!! 缺判据② 那一族表 ⇒ 这趟不许计进 ② 的样本数（见同目录 REFUSED）" >&2
    return 1
  fi
  # 【#130：交互档还要有判据① 那一族逐帧表】上面那一支只要求"8 张里命中一张"——
  # 09-22 那批交互样本正是从这个口子"落定"的：表族没导全，报表只能说
  # 「每帧 GPU 用时：未覆盖（这份 trace 里没有这张表）」，而那一趟照样被计进「落定 N 趟」。
  # 判据① 唯一出口是一次稀缺的真人窗口 ⇒ 窗口拍完才发现缺表＝白烧。
  # ⚠ 只对新录的趟生效：不拿今天这条闸去**追认**已落盘的老批次（写 REFUSED 等于用后来才有的
  #   尺子改写历史，还会灭掉唯一样本——#117 末尾那条纪律同样适用于这里）。
  if [ "${PERIOD:-idle}" = "interaction" ]; then
    local miss1
    miss1=$(criterion1_missing "$out")
    if [ -n "$miss1" ]; then
      refuse_sample "$out" "$REFUSE_KIND_NO_CRITERION：交互档缺判据① 要的逐帧表（$miss1），这一趟答不了 ①；缺表原因见 $out/export-errors.txt。"
      echo "!! 交互档缺判据① 那族逐帧表（缺：$miss1）⇒ 这趟不许计进 ① 的样本数（见同目录 REFUSED）" >&2
      return 1
    fi
  fi
  [ "$tp" = "1" ] || echo "    ⚠ 缺 time-profile：② 答得了，但「主线程 CPU 样本占比／热点第一名」两列会写未覆盖（不判废）"
  return 0
}

run_covers_criterion2() {  # run_covers_criterion2 <outdir> → yes / no：这一趟的产物里有没有判据② 能读的那一族表
  # 为什么单独一支函数：排程器收尾要数「这批里含 ② 表的有几趟」（§210 定的过渡规矩：
  # 「落定 N 趟」以前一直被当「② 有 N 个样本」用，而 #117 量出两者能差 5 倍）。
  # 它**不重新判**"这趟好不好"——那只由 `require_covered_evidence` 判一次；这里只回答
  # "② 的那族表在不在"，读者拿它做分母，不再开第二个判据入口。
  local out="$1" t
  # 【名单没接通不许回 `no`（#125）】`no` 会被读者理解成「查过、这趟没表」，
  # 而真相是「我连查都没查」——`cert17` 那句假零就是这么来的（数组未定义 ⇒ 循环空转）。
  # 这里把它变成一个**不同的字符串**，让调用侧的计数器与话术都区分开。
  [ -n "${HITCH_TABLES[*]:-}" ] || { echo "名单没接通"; return 0; }
  for t in "${HITCH_TABLES[@]}"; do
    [ -f "$out/$t.xml" ] && { echo yes; return 0; }
  done
  echo no
}

criterion2_batch_line() {  # criterion2_batch_line <run 目录...>：印一行「这批含 ② 表几趟／缺族判废几趟」
  # 「落定」与「含 ②」是两个数：前者由排程器的 ✓ 给，后者由这里给。#117 之前没有后面那一格，
  # 于是交付头上"落定 2 趟"读起来像"② 有 2 个样本"，实际含表的是 **0 趟**（另 5 趟挂死）。
  local d n=0 m=0 k=0 u=0 reason cover
  for d in "$@"; do
    [ -d "$d" ] || continue
    n=$((n + 1))
    cover=$(run_covers_criterion2 "$d")
    [ "$cover" = "yes" ] && m=$((m + 1))
    [ "$cover" = "名单没接通" ] && u=$((u + 1))
    if [ -f "$d/REFUSED" ]; then
      reason=$(sed -n '2p' "$d/REFUSED")
      case "$reason" in
        *"$REFUSE_KIND_NO_CRITERION"*) k=$((k + 1)) ;;
      esac
    fi
  done
  echo "    判据② 覆盖：这批 $n 个 run 目录里含 ② 那一族表的 **$m 趟**；因缺整族被判废 $k 趟" \
       "（缺表原因逐趟在 export-errors.txt，#119）"
  # 这一格专门拦 #125 那种失效：`0 趟` 既可能是"真没表"，也可能是"名单没接通 ⇒ 根本没查"。
  [ "$u" = "0" ] || echo "    ✗ 有 $u 趟**没查成**（表名单 HITCH_TABLES 在该调用路径下不可见）" \
                        "⇒ 上面那个 $m 不构成证据，别读成『这批采不到 ②』（#125）" >&2
}
