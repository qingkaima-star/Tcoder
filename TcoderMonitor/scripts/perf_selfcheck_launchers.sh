#!/bin/bash
# =============================================================================
# selfcheck 反例分块：**起实例这一族**（谁起的、会不会收尾、按不按 bundle id 广播、
# 录制有没有墙钟兜底）。由 `perf_selfcheck.sh` 的 `_part` 循环 source 进来，
# 自 `perf_selfcheck_gates.sh` 逐字节搬出（本仓 400 行口径：拆文件才是修复）。
# =============================================================================

launcher_hygiene_row() {  # launcher_hygiene_row <name> <该收> <kill> <trap> <广播>；读调用方的 `bad`
  # 该收尾 = 起实例 且（没有会默认跑的 kill 或 异常路径不 trap）；广播退另算一条。
  # 拆出来只为把这条守卫留在 50 行以内（本仓的尺子也被这条量着）——判据一字未动。
  if [ "$2" = "Y" ] && { [ "$3" != "有" ] || [ "$4" = "无" ]; }; then
    fail "$1 起实例但没收干净（kill=$3 trap=$4）⇒ 中断或默认路径就漏 ppid=1 的孤儿"
    bad=1
  fi
  [ "$5" = "否" ] \
    || { fail "$1 按 bundle id 广播退出 ⇒ 只许 TERM 自己起的那个 pid"; bad=1; }
}

selfcheck_launcher_hygiene() {  # selfcheck_launcher_hygiene <outdir>
  # 29) 会 `open` 起 App 实例的 perf_ 脚本必须同时做到两件事：
  #     ① 有 trap 收尾 —— 脚本被中断而没收尾，就会留下一个 ppid=1 的实例，
  #        而"实例数恰为 1"那道闸会被它一路押死（2026-09-22 实测：主树因此漏下 6 个，
  #        所有人的帧率测量从夜里拒到上午）；
  #     ② 收尾只针对自己起的那个 pid，**不许按 bundle id 广播退出**（AGENTS -1.3；
  #        多实例在场时"退掉一个"根本不含"退掉我起的那个"）。
  # 范围只扫 `scripts/perf_*`：并行多流时各家只守自己名下目录，别家的红由别家自己修
  # （§K 已把主树那两个 offender 连同证据报出去了，那才是正确的动作）。
  #
  # 合法形状有**两种**，别把第二种当成漏网（也别拿第二种给第一种开脱）：
  #   ① `open "$APP/…"` 起实例 ⇒ 必须自己 trap 收尾（本循环判的就是这一种）；
  #   ② `xctrace record --launch -- "$PERF_BIN"` 起实例 ⇒ 那个进程是 **xctrace 收养的子进程**，
  #      按 xctrace 的语义随录制结束而死，所以 `perf_switch.sh` 里一个 `open` 都没有，
  #      也就不需要 trap。**这一条我只验到"形状不同"，没验到"确实不泄漏"**：
  #      哪天发现杀 xctrace（含被 -9）之后被测进程还活着，这条就要改成 ① 并补 trap，
  #      不许拿"它是 ②"当长期豁免的借口。
  #      判据仍然成立：谁改用 ① 的形状，这张表当场就把他列出来（第 31 项钉着表有牙）。
  #
  # 【形状由 `perf_launcher_audit.sh` 现扫给出，本项**只判定**】
  # 原来这里自己写了两条 grep（找 `open "$…APP"` 与 `application id`），于是被自己的
  # 说明文字绊倒过一次（第 29 项夹具里的字面量命中同一条 grep，本仓记过这个族），
  # 今天又被**第 31 项的夹具**绊倒一次：我在夹具里写了一句 `open "$APP"` 来讲那个形状，
  # 这条守卫就把 `perf_selfcheck_gates.sh` 判成"会按 bundle id 广播退出"。
  # ⇒ 同一个问题上不许有两把尺子：取数归表，阈值归这里（与 QUIESCE_MIN 那条分工同一个道理）。
  local rep name need killc trapc bcast sites bad=0 seen=0
  # --tsv：制表符事实行（同一把尺，两种视图）。以前这里读的是**给人看的那张表**，
  # 用 `Y[[:space:]]+无` 当"没 trap"——09-23 把 kill / trap 拆成两列之后，同一个正则
  # 会读成"没有 kill"而把 `kill=有 / trap=无` 那种形状**静默放过**。
  # 靠排版对齐的下游解析一律不许再写；改读事实行，列序变了会当场报错而不是变绿。
  rep=$(bash scripts/perf_launcher_audit.sh --tsv 2>&1) \
    || { fail "perf_launcher_audit.sh 跑不动，或一个 App 句柄都没解析出来 ⇒ 本项没有依据可判（不许当通过）"; return; }
  while IFS=$'\t' read -r name need killc trapc bcast sites; do
    case "$name" in perf_*.sh) ;; *) continue ;; esac
    seen=$((seen + 1))
    launcher_hygiene_row "$name" "$need" "$killc" "$trapc" "$bcast"
  done <<EOF
$rep
EOF
  # 分母：表里一条 perf_* 都没有 ⇒ 说明扫描面退化了，本项等于没判（不许静默绿）
  [ "$seen" -gt 0 ] \
    || { fail "实例清单里一个 perf_* 都没有：要么形状改了、要么目录错了 ⇒ 本项不作数"; return; }
  # 表有牙由第 31 项（三夹具双向）负责，这里不再自带一份夹具——两份夹具会同源失效
  [ "$bad" = "0" ] \
    && ok "perf_* 名下起实例的形状都有「默认就会跑的 kill」+「trap」，且不按 bundle id 广播（形状取自审计表 --tsv）"
}

selfcheck_launcher_inventory() {  # selfcheck_launcher_inventory <outdir>
  # 31) `perf_launcher_audit.sh` 这张表**必须能分辨三种形状**：
  #     真起 App 的（要判）/ 起了但会收尾的（不判）/ 只在注释与 echo 里"讲起 App"的（不进表）。
  #     为什么专门钉：前两版正是死在后两类上 —— v1 把讲代码的话判成 offender、
  #     v2 把 `pgrep "$MY_BIN"` 判成起 App，而 v2 的过窄模式（`\{?` 撞上 BSD 的区间语法）
  #     还把今天真漏 8 个孤儿的 `ax_tooltip_report.sh` **整行漏掉**。
  #     ⇒ 一张会漏真凶、又乱点名的表比没有表更坏，所以三个夹具一次跑齐（缺一个就是废守卫）。
  local d="$out/launch-inv" rep guilty clean prose
  mkdir -p "$d/scripts"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    'x=1' '  "$BIN" -ApplePersistenceIgnoreState YES &' > "$d/scripts/guilty.sh"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    'trap "kill -TERM $pid" EXIT INT TERM' '  "$BIN" -ApplePersistenceIgnoreState YES &' > "$d/scripts/clean.sh"
  printf '%s\n' '# 这里讲的是起 App 的形状："$BIN" 与 open "$APP"' \
    'echo "别学它：$BIN 这样起会漏实例"' > "$d/scripts/prose.sh"
  # 不 cd：`--dir` 给绝对路径，工具内部一律按它拼，省得依赖 "$OLDPWD" 这种"恰好对"的东西
  rep=$(bash scripts/perf_launcher_audit.sh --dir="$d/scripts" 2>&1)
  # 分母：工具在"一个句柄都没解析出来"时自己退 1 ⇒ rc 非 0 时下面三条都不作数
  guilty=$(printf '%s' "$rep" | grep -c '^guilty.sh  *Y')
  clean=$(printf '%s' "$rep" | grep -c '^clean.sh')
  prose=$(printf '%s' "$rep" | grep -cE '^(prose.sh|.*一个都没认出|!! 一个")')
  [ "$guilty" = "1" ] \
    || { fail "坏夹具 guilty.sh 没被判成『Y 命令位起 App』（读到 $guilty）⇒ 这张表认不出真凶：$rep"; return; }
  [ "$clean" = "1" ] || fail "有 trap 的 clean.sh 根本没进表（读到 $clean）⇒ 表漏行， offender 数不可信"
  printf '%s' "$rep" | grep -qE '^clean.sh.*Y.*有' \
    || fail "clean.sh 进了表但 trap 没读到『有』⇒ 宽松方向失效"
  [ "$prose" = "0" ] || fail "讲代码的话（prose.sh）被当成会起实例的脚本 ⇒ 假黑，表会失去信誉：$rep"
  ok "实例清单分得清『真起 / 会收尾 / 只是讲』（三夹具双向都验，含漏真凶的反例）"
}

selfcheck_synth_launch_pairing() {  # selfcheck_synth_launch_pairing <outdir>
  # 32) "谁起实例 / 谁投滚动 / 什么时候投"三件事必须配套。
  # 09-22 排演（.scratch/rehearse_synth_pairing.sh）实测出来的两种坏形状，都不是推想：
  #  ① 排程器与录制档**各起一个**实例 ⇒ `pgrep -x` 数到 2 个 ⇒ `require_idle_target` 必拒，
  #     而这一条会让自动重试连撞满上限（每一个稀缺窗口都白烧在同一个确定性拒绝上）；
  #  ② 排程器朝**自己那个**实例投滚动，录制档却 attach 另一个 ⇒ "量的是没在被滚的那个"，
  #     出一份看起来完全正常的假配对（比红更难发现，因为它不报错）。
  # 所以钉三件：排程器里每处 `open "$START_BIN"` 都要在 `HARNESS_LAUNCHES` 的 else 分支里；
  # 录制档里编译（arm）在闸门之前、投递（start）在闸门之后；而且**倒过来必须被抓住**。
  local w=scripts/perf_wait_window.sh g=scripts/perf_window_gates.sh h=scripts/perf_harness.sh bad=0 line found=0 file
  # 2026-09-25 那次搬家把等窗那一层搬进 `perf_window_gates.sh`，`open "$START_BIN"` 一度跟着搬走
  # ⇒ 只扫排程器的这个 while **一行都不进**，整条判据静默变空（第 29 项当场把那次搬家逼回原形，
  #   见库文件头注）。今天这句又回到排程器里了，但**两处都扫 + 分母断言**留着：
  #   扫到 0 处就说明落点变了，判红而不是"没有违例所以绿"——同一族失效今天在第 61 项也补了一条。
  while IFS=: read -r file line _; do
    found=$((found + 1))
    [ -n "$line" ] || continue
    sed -n "$((line > 8 ? line - 8 : 1)),${line}p" "$file" | grep -q 'HARNESS_LAUNCHES' \
      || { fail "$file:$line 起实例却没被『录制档自己起』那条分支挡住 ⇒ 两边各起一个 = 多实例拒跑"; bad=1; }
  done < <(grep -n '^[[:space:]]*open "\$START_BIN"' "$w" "$g" | sed 's/^\([^:]*\):\([0-9]*\):.*/\1:\2:/')
  [ "$found" -gt 0 ] \
    || { fail "$w / $g 里一句 \`open \"\$START_BIN\"\` 都找不到 ⇒ 排程器搬家把这条守卫扫空了，先去认新落点"; bad=1; }
  pairing_order_violations "$h" \
    || { fail "$h 里 arm/start/preflight 的顺序不成立（见上面那行）"; bad=1; }
  # 反向：坏顺序（**投递排在闸门之前**）必须被同一条判据抓住，否则上面那条是永真绿。
  local fx="$out/pairing-reversed.sh"
  printf '%s\n' '  arm_synth_input' '  start_synth_input' '  preflight_context "$out" "$PID"' > "$fx"
  pairing_order_violations "$fx" >/dev/null \
    && { fail "反向失败：把投递挪到闸门**之前**的夹具没被抓到，这条守卫等于没扫"; rm -f "$fx"; return; }
  rm -f "$fx"
  # 每个动作只许有一个调用点：多一处就有一条绕开这张表的旁路。
  [ "$(grep -cE '^[[:space:]]*start_synth_input([[:space:]]|$)' "$h")" = "1" ] \
    || { fail "$h 里 \`start_synth_input\` 的调用点不是恰好一处"; bad=1; }
  [ "$bad" = "0" ] && ok "起实例/投滚动/开录时机三者配套（含把投递排到闸门前的反例也抓得住）"
}

selfcheck_cleanup_opt_in_state() {  # selfcheck_cleanup_opt_in_state <outdir>
  # 37) 实例清单的「kill」那一格必须分得清**三种**收尾形状：无条件 / 躲在默认关掉的开关后面 / 没有。
  #     为什么单独一条：09-23 凌晨那一串孤儿就是这么来的 —— `capture_pages_isolated.sh`
  #     有 trap、也真写了一句 `kill -TERM`，旧表只看"有没有 trap"就判它干净，
  #     而那句 kill 躲在 `CAPTURE_TERM=1` 后面（默认只印"待人工退出"），它在 for 里每页起一个
  #     ⇒ 跑一轮九页漏九个，把所有人"实例数恰为 1"那道闸压死。
  #     反向钉同样要紧：`if [ "$who" = "$BIN" ]` 是**核身份**的门，是好形状，
  #     拿"缩进在 if 里"当判据就会把每一处谨慎收尾都点名 —— 那张表立刻失去信誉。
  local d="$out/cleanup-state" rep tsv off optin guarded nokill seen
  mkdir -p "$d/scripts"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    "trap 'rm -rf /tmp/lockdir' EXIT INT TERM" 'for name in a b c; do' \
    '  env TCODER_SUPPORT_DIR=/tmp "$BIN" -ApplePersistenceIgnoreState YES &' \
    '  pid=$!' '  if [ "${MINE_TERM:-0}" = "1" ] && [ "$pid" -gt 0 ]; then' \
    '    kill -TERM "$pid" 2>/dev/null || true' '  fi' 'done' > "$d/scripts/optin.sh"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    'trap retire EXIT INT TERM' '  "$BIN" -ApplePersistenceIgnoreState YES &' 'pid=$!' \
    'retire() { who=$(ps -p "$pid" -o comm=); if [ "$who" = "TcoderMonitor" ]; then' \
    '  kill -TERM "$pid" 2>/dev/null || true' 'fi' '}' > "$d/scripts/guarded.sh"
  printf '%s\n' 'BIN="$PWD/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"' \
    '  "$BIN" -ApplePersistenceIgnoreState YES &' > "$d/scripts/nokill.sh"
  rep=$(bash scripts/perf_launcher_audit.sh --dir="$d/scripts" 2>&1)
  tsv=$(bash scripts/perf_launcher_audit.sh --dir="$d/scripts" --tsv 2>&1)
  # 分母：一句启动形状都没认出来时，下面三条全是空对空（工具自己会退 1，但别拿"退 1"当判据）
  printf '%s\n' "$tsv" | grep -q . \
    || { fail "夹具没被认出任何启动形状 ⇒ 这一项等于没扫：$rep"; return; }
  # 四条各判一次，**任何一条不中就不许印 ✓**（第一版就是 fail 之后照样走到 ok，
  # 于是一次跑同时留下「✗ offender 数…」和「✓ 收尾形状分得清…」——那是永真绿的亲戚）。
  local bad=0
  optin=$(printf '%s\n' "$tsv" | grep -c $'^optin\.sh\tY\t选装\t有')
  guarded=$(printf '%s\n' "$tsv" | grep -c $'^guarded\.sh\tY\t有\t')
  nokill=$(printf '%s\n' "$tsv" | grep -c $'^nokill\.sh\tY\t无\t无')
  [ "$optin" = "1" ] \
    || { fail "「kill 只在开关后面」的夹具判成别的（读到 $optin）⇒ 09-23 那个形状又看不见了"; bad=1; }
  [ "$guarded" = "1" ] \
    || { fail "核身份的门被误判成「选装」（读到 $guarded）⇒ 表会乱点名，下次没人信它"; bad=1; }
  [ "$nokill" = "1" ] \
    || { fail "一句 kill 都没有的夹具判成别的（读到 $nokill）"; bad=1; }
  seen=$(printf '%s\n' "$tsv" | sed -n 's/^#facts.*opt_in=\([0-9]*\).*/\1/p')
  [ "$seen" = "1" ] \
    || { fail "事实行里的「选装」计数读到 '$seen'（应为 1）⇒ 那一格没被数进账"; bad=1; }
  off=$(printf '%s\n' "$tsv" | sed -n 's/^#facts.*offenders=\([0-9]*\).*/\1/p')
  [ "$off" = "2" ] \
    || { fail "offender 数读到 '$off'（应为 2：optin + nokill，guarded 不算）⇒ 判定式宽了或窄了"; bad=1; }
  [ "$bad" = "0" ] \
    && ok "收尾形状分得清『无条件 / 躲在开关后面 / 没有』，且核身份的门不算选装（三夹具双向）"
}

selfcheck_record_bounded() {  # selfcheck_record_bounded <outdir>
  # 43) 录制要有墙钟兜底 + 被测进程存活复核 + 「一张表都没有」不许被印成完成。
  #     触发条（09-23 10:38→11:50 实测）：被测实例在录制中途消失，而 `--time-limit 20s`
  #     **从不触发**（它计的是采到的时间），xctrace 挂在死目标上一整小时，
  #     整条 M2 收尾链白烧一个稀缺窗口；而那五张表全空的趟照样被印成「✓ 第 1 趟完成」。
  #     真子进程测（不是读代码）：假 `xcrun` 三种行为各判一次（挂死 / 杀掉被测 / 正常收尾）；
  #     「空表不算完成」那三种形状另有一条 #44，见 `selfcheck_covered_evidence`。
  #     假目标一律 `disown`：不脱手就会把 `Terminated: 15  sleep 300` 这种 job-control
  #     噪声印进 selfcheck 的输出，看着像有一项崩了（今天第一次跑就是这样）。
  local fx="$1/recordfx" path0="$PATH" bad=0 out rc left
  rm -rf "$fx"; mkdir -p "$fx/bin"
  printf '%s\n' '#!/bin/bash' \
    'case "${FAKE_XC:-ok}" in' \
    '  hang) trap "exit 0" TERM; while :; do sleep 0.2; done ;;' \
    '  die)  kill -TERM "${FAKE_TARGET:-0}" 2>/dev/null; sleep 0.3 ;;' \
    '  *)    exit 0 ;;' \
    'esac' > "$fx/bin/xcrun"
  chmod +x "$fx/bin/xcrun"
  PATH="$fx/bin:$PATH"; export PATH
  local RECORD_SLACK_S=2 RECORD_POLL_S=1

  out="$fx/hang"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; FAKE_XC=hang export FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1; rc=$?
  left=$(pgrep -f "$fx/bin/xcrun" | wc -l | tr -d ' ')
  [ "$rc" != "0" ] && [ -f "$out/REFUSED" ] && grep -q 墙钟 "$out/REFUSED" \
    || { fail "录制挂死被当成成功（rc=$rc，REFUSED 缺或不含墙钟）⇒ 又会永等"; bad=1; }
  [ "$left" = "0" ] || { fail "墙钟兜底之后场上还剩 $left 个假采集进程 ⇒ 自己起的必须自己退"; bad=1; }
  kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

  out="$fx/died"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; FAKE_TARGET="$PID" export FAKE_TARGET; FAKE_XC=die export FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1; rc=$?
  [ "$rc" != "0" ] && [ -f "$out/REFUSED" ] && grep -q 消失 "$out/REFUSED" \
    || { fail "被测进程中途消失没被判废（rc=$rc）⇒ 五张表全空的样本又会进对比表"; bad=1; }
  kill -0 "$PID" 2>/dev/null || true

  out="$fx/ok"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; FAKE_XC=ok export FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1; rc=$?
  [ "$rc" = "0" ] && [ ! -f "$out/REFUSED" ] \
    || { fail "正常收尾的趟被误判成挂死（rc=$rc）⇒ 墙钟余量太紧，会把好样本全砍光"; bad=1; }
  kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

  PATH="$path0"; export PATH
  unset FAKE_XC FAKE_TARGET
  [ "$bad" = "0" ] && ok "录制有墙钟兜底、被测消失当场判废（挂死 / 目标死 / 正常收尾，三种真子进程形状）"
}

selfcheck_covered_evidence() {  # selfcheck_covered_evidence <outdir>
  # 44) 「一张表都没有」的一趟不许被印成完成（`require_covered_evidence`）。
  #     同一条 #43 的现场：那趟五张表全空却被记成「✓ 第 1 趟完成」——本仓 `set -uo pipefail`
  #     不带 `-e`，失败的 xctrace 一路走到 summary 照样退 0 ⇒ 这句话只能由代码量住。
  #     反向两条也钉：有非空表必须放行、演练档（本来就不导表）不许被判死。
  local fx="$1/coverfx" bad=0 out rc
  rm -rf "$fx"
  out="$fx/empty"; mkdir -p "$out"
  ( require_covered_evidence "$out" ) >"$out/a.txt" 2>&1; rc=$?
  [ "$rc" != "0" ] && [ -f "$out/REFUSED" ] \
    || { fail "一张表都没有的目录被判成可用（rc=$rc）⇒ 排程器那句「完成」又是空口号"; bad=1; }
  echo "<row/>" > "$out/hitches.xml"
  ( require_covered_evidence "$out" ) >"$out/b.txt" 2>&1; rc=$?
  [ "$rc" = "0" ] || { fail "有非空 hitches.xml 的目录仍被判废 ⇒ 这条判据只认不出也判不进"; bad=1; }
  out="$fx/dry"; mkdir -p "$out"
  ( DRY_RUN=1; require_covered_evidence "$out" ) >"$out/c.txt" 2>&1; rc=$?
  [ "$rc" = "0" ] || { fail "演练档被这条判死 ⇒ selfcheck 自己会红"; bad=1; }
  [ "$bad" = "0" ] && ok "空表的一趟判不成完成：缺表判废、有表放行、演练档不误伤（三种形状）"
}

selfcheck_hang_retry_policy() {  # 62) 挂死才补、只补一次、补试不许抹掉挂死计数、meta 键双向
  # 缺陷 #55：录制挂死 4/30 趟 ≈ 13%，一次挂死的真实代价不是那 140 秒墙钟，
  # 而是**把一个稀缺的干净窗口整段扔掉**（今晚 6/30 可用）。补试因此只对"挂死"这一种
  # 判废开放——其余判废（人手静默不够、被测消失、表全空）恰恰说明**这个窗口不行**。
  # ⚠ 喂给判据的 REFUSED 一律由**真路径**产出（假 xcrun 走 record_bounded /
  #   require_covered_evidence），不抄文案：判废文案一改，这里当场读成别的类型而变红，
  #   而不是拿着两份各自成立的字符串继续互证。
  local fx="$1/hangretry" bad=0 out kind summary path0="$PATH" holders=""
  rm -rf "$fx"; mkdir -p "$fx/bin" "$fx/plain" "$fx/with" "$fx/without"
  printf '%s\n' '#!/bin/bash' \
    'case "${FAKE_XC:-ok}" in' \
    '  hang) trap "exit 0" TERM; while :; do sleep 0.2; done ;;' \
    '  die)  kill -TERM "${FAKE_TARGET:-0}" 2>/dev/null; sleep 0.3 ;;' \
    '  *)    exit 0 ;;' \
    'esac' > "$fx/bin/xcrun"
  chmod +x "$fx/bin/xcrun"
  PATH="$fx/bin:$PATH"; export PATH
  local RECORD_SLACK_S=2 RECORD_POLL_S=1

  out="$fx/hang"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; holders="$holders $PID"; FAKE_XC=hang export FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1
  kind=$(refusal_kind "$out")
  [ "$kind" = "hang" ] \
    || { fail "真挂死路径产出的 REFUSED 被判成「$kind」⇒ 判废文案与这条判据已经分叉，补试从此不触发"; bad=1; }
  [ "$(HANG_RETRIES_USED=0 attempt_verdict "$out" 1)" = "retry" ] \
    || { fail "挂死、预算未用、rc=1 这三样凑齐却不补 ⇒ #55 那条同窗补试是纸面规矩"; bad=1; }
  [ "$(HANG_RETRIES_USED=1 attempt_verdict "$out" 1)" = "slot" ] \
    || { fail "预算用完还允许再补 ⇒ 退化成「攒够可用为止」那种数据相关的停止规则"; bad=1; }
  [ "$(attempt_verdict "$out" 0)" = "slot" ] \
    || { fail "成功那一趟也去补 ⇒ 同一个窗口里采两遍，读数会被当两批独立样本引用"; bad=1; }
  kill -TERM "$PID" 2>/dev/null; wait "$PID" 2>/dev/null

  out="$fx/gone"; mkdir -p "$out"
  sleep 300 & PID=$!; disown; holders="$holders $PID"
  FAKE_TARGET="$PID" FAKE_XC=die export FAKE_TARGET FAKE_XC
  ( record_bounded "$out" "$out/x.trace" T 1 ) >"$out/run.txt" 2>&1
  kind=$(refusal_kind "$out")
  [ "$kind" = "target_gone" ] \
    || { fail "被测进程消失被判成「$kind」⇒ 三种判废的类型学少了一类"; bad=1; }
  [ "$(HANG_RETRIES_USED=0 attempt_verdict "$out" 1)" = "slot" ] \
    || { fail "被测消失也去补试 ⇒ 补试通道扩到了「这个窗口本来就不行」那一类"; bad=1; }

  out="$fx/notables"; mkdir -p "$out"
  ( require_covered_evidence "$out" ) >"$out/a.txt" 2>&1
  kind=$(refusal_kind "$out")
  [ "$kind" = "empty_tables" ] \
    || { fail "三张表全空被判成「$kind」⇒ 该类的文案改了而这里没跟上"; bad=1; }
  [ "$(attempt_verdict "$out" 1)" = "slot" ] \
    || { fail "表全空也去补试 ⇒ 同一条通道又宽了一格"; bad=1; }
  [ "$(refusal_kind "$fx/plain")" = "none" ] \
    || { fail "没有 REFUSED 的目录不判成 none ⇒ 空目录会被当成某种判废"; bad=1; }

  # 挂死计数**必须**在补试成功之后照样出声（#55 硬约束①）
  summary=$(batch_hang_summary 2 1 1)
  printf '%s\n' "$summary" | grep -q '挂死：2 趟' \
    || { fail "补试补回来一趟之后挂死计数就不见了（拿到「$summary」）⇒ 单向朝好看的计数"; bad=1; }
  printf '%s\n' "$summary" | grep -q '补回可用 1 趟' \
    || { fail "挂死计数报了、却没报补回几趟 ⇒ 读的人无法判断这批还剩多少可用"; bad=1; }
  printf '%s\n' "$(batch_hang_summary 0 0 0)" | grep -q '0 趟' \
    || { fail "一趟都没挂却报了挂死 ⇒ 反向失准"; bad=1; }

  # meta 那一枚键：两个方向都要有牙（走的是同一个出口 `hang_recovery_meta_arg`）
  # ⚠ 必须 **export 之后再调用**：写成 `HANG_RECOVERED=1 meta_write … "$(hang_recovery_meta_arg)"`
  #   是无效的前缀赋值——参数表里的命令替换**先于**赋值展开，函数看到的还是空值
  #   （第一次就是这么写出来、当场被自己这条反例判红的）。
  ( export HANG_RECOVERED=1
    REV=x DIRTY=0 meta_write "$fx/with" "mode=idle" "$(hang_recovery_meta_arg)" )
  unset HANG_RECOVERED
  REV=x DIRTY=0 meta_write "$fx/without" "mode=idle" "$(hang_recovery_meta_arg)"
  grep -q '"hang_recovered"' "$fx/with/meta.json" \
    || { fail "补试趟没把 hang_recovered 落进 meta ⇒ 哪几份读数是补出来的，事后无从复核"; bad=1; }
  grep -q 'hang_recovered' "$fx/without/meta.json" \
    && { fail "没挂过的趟也带上了 hang_recovered ⇒ 这枚键失去区分力（写 0 冒充「没有」的形状）"; bad=1; }

  # 自己起的持有者必须自己退（AGENTS 2.1）。**这一项的第一版就是没退干净**：
  # 那个 disown 掉的 `sleep 300` 还占着 stdout 管道，外面的 `| tail` 永远等不到 EOF，
  # 整个反例跑起来像挂死。按 pid 精确核对，不 pgrep 名字——别人的同名进程不该算到我头上。
  for h in $holders; do
    kill -TERM "$h" 2>/dev/null || true
    sleep 0.2
    kill -0 "$h" 2>/dev/null && { fail "持有者 pid=$h 退了信号却没死 ⇒ 本项自己成了漏实例的那一个"; bad=1; }
  done
  PATH="$path0"; export PATH
  unset FAKE_XC FAKE_TARGET HANG_RECOVERED
  [ "$bad" = "0" ] && ok "挂死才补、按批封顶、补试抹不掉挂死计数、meta 键两个方向都判过（真路径产出的 REFUSED）"
}
