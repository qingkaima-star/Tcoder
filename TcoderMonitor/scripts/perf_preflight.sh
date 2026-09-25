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
source "$(dirname "${BASH_SOURCE[0]}")/perf_probes.sh"  # 探针族搬出去了，见那个文件的头注
source "$(dirname "${BASH_SOURCE[0]}")/perf_measure_io.sh"  # 采集与落盘那一层，见那个文件的头注
source "$(dirname "${BASH_SOURCE[0]}")/perf_chain_guard.sh"  # 「同树只一条链」＋归属行的有界显示（`path_for_display`）
# 收尾磁盘卫生这一族 2026-09-25 整族搬进 `perf_reclaim.sh`（本文件当时 378/400，
# 就地补第 ④ 条就是把尺寸债再推一笔）。第 22 项反例照旧 source 本文件就调得到。
source "$(dirname "${BASH_SOURCE[0]}")/perf_reclaim.sh"
# ── 磁盘卫生：第七维（2026-09-21 把这台机器吃到只剩 4.4 GiB 之后加的）────────
# 根因不在我的样本目录，而在 **xctrace 的中间产物**：`instruments*.ktrace`
# 默认落在 `$TMPDIR`，而采集进程被 kill、超时或崩溃时**不会自己清**。
# 现场是 21 个孤儿共 103 GB。⇒ 四条硬规矩进代码，不靠我记得：
#   ① 样本根目录 = 仓库内 `.scratch/`（AGENTS §1.6 的一次性产物落点，已 gitignore；
#      不再用全局 /tmp，也不再靠 $TMPDIR）
#   ② 每轮收尾固定扫残留 + 确认自己起的采集进程真退了
#   ③ 可用低于阈值就**拒跑**（与其余六维同形状、同一个 hard 标记）
#   ④ 判废那一趟留下的 GB 级原始 trace 每轮报一次可回收体积（缺陷 #70：① 把产物
#      搬进仓库之后，② 的扫残留就一直只扫一个不再有人写字的目录）
SCRATCH="${SCRATCH:-$(git rev-parse --show-toplevel)/.scratch}"
# 阈值与判定都在 `disk_headroom_bad`（环境变量 TCODER_MIN_FREE_GIB 可覆盖）
QUIESCE_MIN="${QUIESCE_MIN:-5}"  # 静默合格线（与 perf_harness.sh 同值）。写在闸门这边，
# 是因为**阈值**属于判定、不属于取数；排程器单独 source 本文件时也要有默认值可走。

sections() {
  local f=scripts/capture_pages_isolated.sh line blob
  # 【读"生产者的形状"，不是读我记得的形状】2026-09-22 实测失效一次：本函数原来钉的是
  # `^SECTIONS=(`，而 main 把 capture_pages_isolated.sh 改写成
  # `IFS=':' read -r -a SECTIONS <<< "${CAPTURE_PAGES:-总览:…}"` ⇒ grep 命中 0 行、
  # 于是**九页变成 0 页**，而当时除了 selfcheck 第 18 项没人会看见。
  # 判据：解析别的文件的字面量时，**取不到内容必须报错并说明去哪儿看**，不许静默返回空——
  # "空"在下游和"真的没有页"长得一模一样。
  line=$(grep -m1 'read -r -a SECTIONS' "$f" 2>/dev/null) \
    || { echo "!! sections：$f 里没有 'read -r -a SECTIONS' 这一行了——页名的生产方式又改了，" \
                "去那文件看它现在的形状（本函数故意不返回空，免得 0 页被下游读成「没有页可拍」）" >&2; return 1; }
  blob=$(printf '%s' "$line" | sed -e 's/.*:-//' -e 's/}".*//')
  [ -n "$blob" ] || { echo "!! sections：找到那行却抠不出冒号串（默认值被搬走了？）：$line" >&2; return 1; }
  # 【按冒号取】页名内部允许有空格（「Git 洞察」），所以既不许按空格拆，
  # 也不许按引号取——现在引号只包住整串，不再一个个包住页名。
  printf '%s\n' "$blob" | tr ':' '\n'
}







# "产物到底是不是这份代码"的判定**不在本文件里**——它归 scripts/perf_provenance.sh，
# 与 `verify_provenance.sh` 共用同一把手尺子（见那个文件的头注）。
source "$(dirname "${BASH_SOURCE[0]}")/perf_provenance.sh"

preflight_gather() {  # 只取数：判据住 `preflight_gates*`，写盘住 `preflight_write_context`
  # 【这里的赋值**一律不带 local**】值要落回调用方 `preflight_context` 的那几个 local
  # （bash 动态作用域）。在这里 local 一下，六条闸门就各自拿到空串——
  # 那条"探针函数不在场就恒放行"的老路是它的近亲。
  cores=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  load1=$(sysctl -n vm.loadavg 2>/dev/null | tr -d '{}' | awk '{print $1}')
  [ -n "$load1" ] || load1=0
  front=$(preflight_front_app)
  visible=$(preflight_window_state "$pid")
  # 启动档：拿一个还不存在的 pid 去问"有没有在屏窗口"，答案必然是"没有"——那是探针在说它没被问对，
  # 不是被测进程的事实。写成一句人话，免得上下文里留下一个看着像实测的"无在屏窗口"。
  [ "$PREFLIGHT_TIER" = "launch" ] && visible="启动档：此刻窗口尚未建立"
  others=$(concurrent_heavy_jobs)
  # 第七维·预热：被测实例跑了多久（读不到留「取不到」，**不回落成 0**——0 会被读成"刚起来"）。
  uptime_secs=$(instance_uptime_seconds "${pid:-}" || true)
  free_gib=$(disk_free_gib)
  mkdir -p "$SCRATCH" 2>/dev/null || true   # 样本根目录：项目内、.gitignore 已忽略
  other_detail=$(concurrent_heavy_jobs_detail)
  # 运行时漏翻台账（i18n 报告器）会在渲染路径上记键、按 200 次节流写盘。
  # 设了它再量帧率，量的就是台账自己的开销——所以这一维写进上下文，并且直接拒跑。
  i18n_ledger="${TCODER_I18N_RUNTIME_LEDGER:-}"
  # 人手静默：整机 load 与并发编译挡得住"机器在忙"，挡不住"有人在点这个窗口"。
  qline=$(quiescence_probe)
  quiet=$(quietest_seconds "$qline")
  # 取二进制的出身（**不是**工作树 HEAD）：闸门第六维与上下文都要用
  BUILD_REV=$(provenance_manifest_value TCODER_GIT_REVISION)
  BUILD_CLEAN=$(provenance_manifest_value TCODER_GIT_CLEAN)
  BUILD_TREE=$(provenance_manifest_value TCODER_PRODUCT_TREE)
  # 【"被测内容"可以是别的 rev —— 但归属必须照样算清楚】包 5 的前置。
  # 为什么需要：§Q 那 14 处还掉之后，要回答"从多少降到多少"，就必须能再量一次**改动前**那份内容；
  # 而 `MEASURE_REV` 未设时一切照旧（比 HEAD），设了就必须比它——**这条覆盖不许变成跳过判定**。
  TARGET_REV=$(provenance_target_rev)
  HEAD_TREE=$(provenance_product_tree "${MEASURE_REV:-HEAD}")
}

# 第七维·预热（`instance_uptime_seconds` / `preflight_gates_warmup`）住在旁边那个文件，
# 由**本文件**自己 source 进来（不是调用方拼）：selfcheck 里有「单独 source preflight」那条路，
# 它必须照样看得见全部函数 —— 两个入口各拿一半函数是这条链上写死不许发生的形状。
# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/perf_warmup.sh"

preflight_context() {  # preflight_context <outdir> <pid> [档]   档=measure(默认) | launch(冷启动)
  local out="$1" pid="$2" f="" cores load1 front visible others other_detail free_gib hard=0
  local quiet qline i18n_ledger uptime_secs
  # 动态作用域：`preflight_gather`（取数）与 `preflight_gates`（判定，含被 selfcheck 第 17 项
  # **单独调用**那条路）读写的都是上面这几个 local，所以拆函数既没改取数顺序，也没引入新全局量；
  # 启动档的"跳过两维"只影响从本函数进来的调用，矩阵那条不传第三参 ⇒ 行为一字不变。
  local PREFLIGHT_TIER="${3:-measure}"
  f="$out/measurement-context.txt"
  preflight_gather
  preflight_write_context "$out" "$f"
  # 六条硬闸各自读上面那几个量（bash 是动态作用域：本函数的 `local` 在被调函数里照样可见，
  # 拆函数没有改变任何取数顺序，也没有引入新的全局量）。
  preflight_gates
  if [ "$hard" = "1" ] && [ "${IGNORE_CONTEXT_GATE:-0}" != "1" ]; then
    # 被拒的一趟**必须在目录上留下自认字样**：否则 `ls $SCRATCH/tcoder-perf-*` 会看见
    # run1/run2/run3 三个"像样本"的空目录，后来的人很容易把"闸门拒了"读成"量过了"。
    # （今天就真出现了三个只有 context/meta 的目录。）
    printf 'REFUSED\n这一趟没有采数：测量上下文不合格，闸门拒跑。原因见同目录 %s。\n' "$(basename "$f")" \
      > "$out/REFUSED"
    echo "!! 测量上下文不达标（详见 $f）。IGNORE_CONTEXT_GATE=1 可强行跳过，但那批读数必须标注为『条件不合格』。" >&2
    # 【只 return，不 die】`die` 住在**宿主**脚本里：单独 source 本文件（自测、排程器、手工排查）时它不在场，
    # 2026-09-23 实测 `die: command not found` 之后这条"拒跑"分支**以 rc=0 走完**——
    # 缺一个函数就把闸门从"拒"翻成"放"，是所有失效方向里最坏的那种。
    # 于是判定只负责说"不合格 + 回 1"，**退不退由调用方决定**（三处调用点各自 `|| die`/`|| return 1`）。
    return 1
  fi
  [ "$hard" = "1" ] && echo "    ⚠ IGNORE_CONTEXT_GATE=1：条件不合格，这批读数不得进任何对比表。" >&2
  echo "    上下文已落 $f"
}





warmup_reading_note() {  # warmup_reading_note <已跑秒数> → 预热这一维的一句人话（可单测，不碰外部命令）
  # 旧写法把「低于线 ⇒ 量到的是启动首扫」钉在行尾**当常量后缀**印，于是跑了 212 s 的样本
  # 也被印成"首扫"（09-25 11:48 实测：cert7b 三趟的上下文里全都带着这句假话）。
  # 这份文件是"读数只有在这一组条件下才可互比"的凭据本身——条件行说谎，可互比就是空的。
  # 同时修掉数字重印：`${v:+${v}s}${v:-取不到}` 在 v 非空时会把同一个数印两遍（"212s212"）。
  local up="${1:-}" line="${WARMUP_MIN_SECONDS:-120}"
  case "$up" in
    ''|*[!0-9]*) printf '取不到 ⇒ 预热这一维未判（读不到运行时长，不许回落成 0 再判）'; return ;;
  esac
  if [ "$up" -ge "$line" ]; then
    printf '%ss（≥ 预热线 %ss ⇒ 量的是稳态心跳）' "$up" "$line"
  else
    printf '%ss（低于预热线 %ss ⇒ 量到的是启动首扫，不是稳态心跳）' "$up" "$line"
  fi
}

preflight_write_context() {  # preflight_write_context <outdir> <context 文件路径>
  # 这一份上下文是"读数可互比"的凭据：谁后面拿这批数做对比，都得先看见同一组条件。
  local f="$2"
  # 下面五个都是**宿主脚本**的全局（`perf_harness.sh` 才定义）：本文件被单独 source 时
  # 它们不在场，而 `set -u` 下读到未初始化量是**当场中止整个 shell**。
  # 更糟的是这一整块原本带 `2>/dev/null` ⇒ 中止那句 "unbound variable" 被丢进黑洞，
  # 现场只剩"什么都没印、REFUSED 没落盘"（2026-09-25 t20 那批之后我自己踩出来：
  # 独立调用 `preflight_context` 想造一份真判废，结果它一个字没说就死了）。
  # ⇒ 两条一起改：读法全部给 `${…:-取不到}` 的活路，**并且把块级 2>/dev/null 摘掉**
  #    （写不出文件由后面那个 `|| die` 负责报，不该由黑洞负责）。
  { echo "# 测量上下文（读数只有在这一组条件下才可互比）"
    echo "时间=$(date '+%F %T')  HEAD=$(git rev-parse --short HEAD 2>/dev/null)  工作树改动数=${DIRTY:-取不到}"
    echo "被采pid=$pid  二进制=${TARGET_BINARY:-取不到}  口径=${TARGET_FLAVOR:-取不到}"
    echo "   产物码 tree=${BUILD_TREE:-未记录}  被测内容(${MEASURE_REV:-HEAD})=${HEAD_TREE:-未记录}"
    echo "产物构建rev=${BUILD_REV:-未记录}  构建时树clean=${BUILD_CLEAN:-未记录}  ← 必须与上面 HEAD= 同一份代码，否则读数归错对象"
    [ -n "${PROVENANCE_NOTE:-}" ] && echo "   ※ 归属靠产物码 tree 放行（rev 不同）：${PROVENANCE_NOTE}"
    echo "实例数=${COEXIST:-1}  前台App=$front  被测进程visible=$visible"
    echo "被测实例已跑=$(warmup_reading_note "${uptime_secs:-}")"
    echo "load1=$load1  核数=$cores  并发重活=${other_detail:-无}"
    echo "人输入静默=${quiet:-取不到}s  明细=${qline:-（探针没跑起来）}"
    echo "hitches_seconds=${SECONDS_HITCHES:-取不到}  tp_seconds=${SECONDS_TP:-取不到}"
    echo "诊断开关 TCODER_I18N_RUNTIME_LEDGER=${i18n_ledger:-未设（渲染路径零成本）}"
  } > "$f" || die "写不出 $f"
  echo "    上下文：前台=$front  visible=$visible  load1=$load1/$cores  并发重活=${other_detail:-无}  静默=${quiet:-取不到}s  磁盘可用=${free_gib:-取不到}GiB"
}

# 身份两维：被量的到底是不是这份代码、以及采样时有没有开着诊断报告器。
# 拆出来一半是为了不撞 `PerfRulerHotspotRatchetTests` 的 50 行线（拆，不抬数），
# 一半是因为这两条问的是同一个问题："这批读数能算在谁头上"。
preflight_gates_identity() {
  # 【第六维】2026-09-21 实测踩到：`measurement-context.txt` 里的 `HEAD=` 是**工作树**的头，
  # 而我 attach 的那个 `dist/Tcoder.app` 是两小时前 `build_app.sh` 从 `41add9e` 建的，
  # 中间隔了 39 个产物文件（整批 i18n + 我自己的 `PerfReadoutCells` 修复）。
  # 于是"e991c6d 的 T2 读数"这句话从头到尾是假的——量的是旧二进制，只是恰好在新树上按了回车。
  # `${TARGET_REV:-…}` 的兜底不是洁癖：自测里 `preflight_gates` 是**被单独调用**的，
  # 那时"收集上下文"那一步没跑过 ⇒ 现场再派生一次。宁可算两遍，也不拿空值当"取不到 HEAD"。
  if ! PROVENANCE_WHY=$(provenance_ok "$BUILD_REV" "${TARGET_REV:-$(provenance_target_rev)}" "$BUILD_CLEAN" "${BUILD_TREE:-}" "${HEAD_TREE:-}"); then
    echo "!! 二进制与代码不是同一份：${PROVENANCE_WHY} —— 先跑 scripts/build_app.sh release 再量。" >&2
    hard=1
  else
    # 放行也可能带话——那就是"靠 tree 归属"的留痕，必须印进上下文，不许悄悄过。
    PROVENANCE_NOTE="$PROVENANCE_WHY"
  fi
  # 归属是谁的就必须写出来：不设 `MEASURE_REV` 时这一行等于"HEAD"，设了则一眼能看出
  # "这一批读数算在另一个 rev 头上"（旧形状里这句话是**隐形的**，读上下文的人只能猜）。
  echo "    归属内容：${MEASURE_REV:-HEAD} → ${TARGET_REV:-取不到（rev 写错了？）}"
  if [ -n "${i18n_ledger:-}" ]; then
    echo "!! 设了 TCODER_I18N_RUNTIME_LEDGER（=$i18n_ledger）——渲染路径在记漏翻台账并节流写盘；
   这批读数量的是台账的开销，不是 App 的心跳。取消该变量再测。" >&2
    hard=1
  fi
}

preflight_gates_disk() {  # 【第七维：磁盘】判定只有一份（probes 的 disk_headroom_bad）
  # 盘满最坏的后果不是失败退出，而是 xctrace 写不进中间产物、
  # **样本照样出一份看起来合理的数** ⇒ 读不到余量与余量不足同等对待。
  local why
  if why=$(disk_headroom_bad "${free_gib:-}"); then
    echo "!! $why——一趟 trace 轻则几百 MB、重则十几 GB，" \
         "且 $TMPDIR 里的 .ktrace 中断不会自己清。先清盘再来，不硬跑。" >&2
    hard=1
  fi
}

preflight_gates_contention() {  # 【并发重活】判据（认哪些名字、活性怎么算）住在 probes，这里只判"有没有"
  if [ -n "$others" ]; then
    # ${…:-} 不是洁癖：这一维在合成夹具里被单维破坏时，别的量可能是空的，
    # 而 `set -u` 下引用未声明变量会**静默中止整条闸门**（今天就是这样把 selfcheck 打断的，
    # 现场看起来像"探针输出正常、后面凭空没了"）。
    echo "!! 机器上有重活在跑（${other_detail:-只拿到 pid $others，没拿到名字}）——" \
         "它会抢满全部核，app-update 相位会被显著抬高。等它跑完再来。" >&2
    hard=1
  fi
}

load_bar() {  # 负载阈值的**唯一**口径：默认 核数×1.5，`LOAD_MAX=<数>` 显式覆盖
  # 单独一个函数的理由：这条式子原本在**两处**各写了一遍（闸门里 `c*1.5`、
  # 收尾复核里又 `c*1.5`），而注释说的 `LOAD_MAX` 出口两处都没实现。
  # 两个入口迟早分叉，而分叉的方向永远是"闸门放行了、收尾复核却说脏"（或反过来）。
  local c="${cores:-}"
  [ -n "$c" ] || c=$(sysctl -n hw.ncpu 2>/dev/null || echo 8)
  awk -v c="$c" -v o="${LOAD_MAX:-}" 'BEGIN{ if (o != "") print o+0; else print c*1.5 }'
}

preflight_gates_load() {  # 【整机负载】阈值只写一次：测量档与启动档共用（冷启动同样怕排队）
  # 默认 1 分钟 load 不超过核数的 1.5 倍。`LOAD_MAX=<数>` 是**写在这条判据旁边的公开出口**，
  # 但 2026-09-23 17:17 实测它是个**空头的旋钮**：注释说可覆盖，代码里阈值写死成 `c*1.5`，
  # 我拿 `LOAD_MAX=5` 去要一个更严的窗口，它照旧按 22.5 放行（现场：load1=13.44/15 那趟量出 24.8 ms，
  # 而同一个二进制在 load 4.6 起的那趟量出 1.59 ms ⇒ 这条闸在 1.5× 核数上太宽，心跳档根本用不了）。
  # 判据与它印出来的数字必须同源：所以下面把真正生效的那个数回显出来，不许"印 22.5、判 5"。
  local bar; bar=$(load_bar)
  if awk -v l="$load1" -v b="$bar" 'BEGIN{exit !(l > b)}'; then
    echo "!! load1=$load1 超过阈值 $bar（核数 $cores；默认 = 核数×1.5，$([ -n "${LOAD_MAX:-}" ] && echo "本次由 LOAD_MAX 显式覆盖" || echo "未设 LOAD_MAX")）" >&2
    echo "   整机在排队 ⇒ 任何帧节拍与主线程占用读数都不作数。等负载降下来；" >&2
    echo "   要收紧就 LOAD_MAX=<更小的数>（那批要在报告里注明条件更严），要放宽就在报告里注明是降级条件。" >&2
    hard=1
  fi
}

preflight_gates_window() {  # 【窗口形状两维：前台 + 在屏】只有"窗口已经在画"的档才判
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
}

preflight_gates_quiescence() {  # 【人手静默】§1.3 作废的那两批基线，坏因都是"测量期间有人在动"，
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

preflight_gates() {  # 不合格就置 `hard=1`（调用方按 IGNORE_CONTEXT_GATE 决定炸还是通报）
  # 【bash 的坑】调用**不带括号**：写成 `preflight_gates_identity()` 会被解析成
  # "在 preflight_gates 内部再定义一个函数"，于是这两维**一次都没执行**、也不报错——
  # 一条静默失效的闸门。selfcheck 第 17 项（六维矩阵）抓的就是它。
  # 各维取数仍是调用方的 `local`（bash 动态作用域穿得过这层组合），
  # 所以矩阵"单维破坏 ⇒ 拒"的形状一字未动地继续成立。
  preflight_gates_identity
  preflight_gates_contention
  preflight_gates_disk
  preflight_gates_load
  # 【启动档（冷启动）没有"窗口形状"这两维】`PREFLIGHT_TIER=launch` 由 `preflight_context` 的第三参设。
  # 理由不是放宽，而是**那一刻被测窗口还不存在**：App 是紧接着由 xctrace 拉起来的，
  # 拿"前台是不是 Tcoder / 有没有在屏窗口"去判它，得到的是一条永远不可能通过的闸门
  # （同一条教训在 `provenance_target_rev` 的注释里已经付过一次学费）。
  # 跳过要**出声**，而且上下文文件里那两行照样写实测值（`visible` 在启动档被明写成"窗口尚未建立"，
  # 不留一个看着像实测的"无在屏窗口"）；其余五维——身份 / 并发重活 / 盘 / load / 人手静默——照判。
  if [ "${PREFLIGHT_TIER:-measure}" = "launch" ]; then
    echo "    （启动档：前台与在屏两维不参与判定——写上下文时窗口还没建起来；" \
         "身份/并发重活/盘/load1/人手静默五维照判）" >&2
  else
    preflight_gates_window
  fi
  preflight_gates_quiescence
  preflight_gates_warmup
}

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
RECORD_SLACK_S="${RECORD_SLACK_S:-120}"
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
