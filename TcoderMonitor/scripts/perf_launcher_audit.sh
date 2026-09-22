#!/bin/bash
# =============================================================================
# perf_launcher_audit.sh —— 点名"哪个脚本会漏下实例"的清单（**只读，不是闸门**）
#
# 为什么要有它（2026-09-22 的现场账）：帧率测量的闸门要求"实例数恰为 1"，而这一天里
# 我三次清场、每次都看见同一形状的残迹 ——
#   12:16 起 4 个、12:50 起 4 个、12:52 起 4 个、13:30 又起 8 个；全部 `ppid=1`、
#   全部落在**别的树**的 `dist/` 上，起它们的外壳脚本早已退出。
# 手工归因做过一次（工单 §K：`ax_tooltip_report.sh` 第 117 行起进程，第 108 行有
# `kill -TERM "$pid"` 但**没有 trap** ⇒ 只有正常路径收尾）。问题是**手工归因是一次性的**：
# 下一轮泄漏还得再查一遍，而每次查证都要吃掉那个本来就不够用的窗口。
# ⇒ 把"谁可能制造孤儿"变成一条随时可跑、每次现扫的清单。
#
# **它判的不是"谁漏了"，是"谁有这个形状"** —— 进程已经孤儿化之后再找凶手找不到
# （父进程 reparent 到 launchd，脚本名不留在进程表里），只能事前扫形状。
#
# 三条边界（都故意的，别"顺手改严"）：
# 1) **默认退出码 0**：并行多流时各家只守自己名下目录（AGENTS）。这份清单的意义是
#    **让被点名的人看得见自己**，不是把别人的红挂到我的门禁上。
#    要判自己家：`--strict` —— 它**只**对 `perf_*` 生效，别家一律不判。
# 2) 只报形状，不推断因果：`trap 有`不等于"这轮不是它漏的"，`trap 无`也不等于"它一定漏"
#    （`xctrace --launch` 那种形状随录制结束而死，本来就不需要 trap）。
# 3) 不碰任何进程：本脚本一律 `grep`，没有 `kill` / `osascript`。
#
# 【前两版是怎么坏的，留这里防止被改宽】
#   v1 全文 grep ⇒ 本清单把**自己**列成"会起实例"，而 `perf_selfcheck_gates.sh` 因为
#      反向夹具里写着那句广播退出的字符串被判成 offender（守卫扫到"讲代码的话"）；
#   v2 认"任何 `$X_BIN`" ⇒ `pgrep -fx "$MY_BIN"`（查实例）、`[ -x "$AXBIN" ]`（判断在不在）、
#      `"$WINLIST_BIN" "$pid"`（问窗口）三处全被当成起 App。
# 两版的代价都不是"多几行噪音"，是**真凶混在假阳性里，从此没人信这张表**。
# 判据因此收窄成：**行首（可带 `env K=V ` / `exec `）就是这个 App 的句柄**。
# 方向是**宁漏勿冤** —— 漏掉的仍然带着命中行进图，人看得见；乱点名的没有下一次。
# =============================================================================
set -uo pipefail

STRICT=0
WATCH_DIR="scripts"
for a in "$@"; do
  case "$a" in
    --strict)  STRICT=1 ;;
    --dir=*)   WATCH_DIR="${a#--dir=}" ;;
    -h|--help) printf '用法: %s [--strict] [--dir=scripts]\n  --strict 只对 perf_* 名下的形状问题返回非零（别家只列不判）\n' "$0"; exit 0 ;;
    *) printf '!! 不认识的参数：%s（故意不猜，猜错就会扫错目录）\n' "$a" >&2; exit 2 ;;
  esac
done

SHAPE_BROADCAST='application[[:space:]]+id'

# 【什么算"App 句柄"】只有被赋成 .app 路径（或 .app/…/MacOS/二进制）的变量名。
# 取**全目录并集**，因为定义和启动经常不在同一个文件：`perf_pulse.sh` 用的 `$PERF_BIN`
# 是 `perf_harness.sh` 里赋的。辅助工具（`WINLIST_BIN` = 查窗口的那个）不含 `.app`，
# 天然进不来 —— 那正是 v2 误报的一类。
APPVARS=''
collect_app_vars() {
  local f
  for f in "$WATCH_DIR"/*.sh; do
    [ -f "$f" ] || continue
    grep -oE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*="[^"]*\.app(/[^"]*)?"' "$f" \
      | sed -E 's/^[[:space:]]*//; s/=.*//'
  done | sort -u | paste -sd'|' -
}

# 只认"命令位"的 ERE。三种真实写法都要认（逐条在仓库里核过）：
#   `open "$APP"`                          e2e_check.sh:65 / verify_pages.sh:57
#   `"$PERF_BIN" >/dev/null 2>&1 &`        perf_pulse.sh:41
#   `env TCODER_SUPPORT_DIR=… "$BIN" \`    ax_tooltip_report.sh:117  ← 今天漏 8 个孤儿的那个
# 而这些必须**不**认：`[ -x "$BIN" ] || {`、`if [ "$who" = "$BIN" ]`、
#   `my_instance_pid() { pgrep -fx "$MY_BIN"; }`、以及 `BIN="…/Tcoder.app"` 这条赋值本身。
# 占位符 @V@ 用整串替换，免得在 shell 里跟 `$`/`\` 混一层转义（本仓为这事炸过多次）。
# 【花括号必须走字符类 `[{]` `[}]`】上一版写 `\{?` / `\}?` 想把 `${V}` 与 `$V` 两种都认，
# 结果 **BSD grep 的 ERE 把 `\{` 当区间语法**，整条模式静默匹配不到任何东西 ⇒
# 今天真漏 8 个孤儿的 `ax_tooltip_report.sh`（第 117 行 `env … "$BIN" \`）反而**从表里消失**。
# 漏报真凶比误报恶劣得多，所以这一条钉在注释里：字符类里的 `{` `}` 才是字面量。
ERE_TEMPLATE='^[[:space:]]*(open[[:space:]]+"?([^"]*\.app|[$][{]?@V@[}]?)|"[$][{]?@V@[}]?"|(env|exec)[[:space:]]+[^|;&]*"[$][{]?@V@[}]?")'
launcher_ere() {
  local v="${APPVARS:-}"
  [ -n "$v" ] || v='ZZZ没有App句柄ZZZ'      # 空并集时宁可什么都认不出，也不拿空交替组乱匹
  printf '%s' "${ERE_TEMPLATE//@V@/($v)}"
}

# 先**把反斜杠续行接成一条逻辑行**再滤噪音：
# 上一版逐行滤，于是夹具里那句
#   `printf '%s\n' 'open "$APP"' \` + 下一行 `'osascript -e "tell application id …" to quit"'`
# 的物理第二行不含 `printf` ⇒ 被当成真代码，`perf_selfcheck_gates.sh` 被误判成"会广播退"。
code_lines() {  # code_lines <file>
  sed -e :a -e '/\\$/N' -e 's/\\\n//; ta' "$1" \
    | grep -vE '^[[:space:]]*#' \
    | grep -vE '(^|[[:space:]])(echo|printf|fail|ok)[[:space:]]'
}

is_xctrace_launcher() {  # xctrace 的参数跨行，所以两半分别认；且必须**真的**在起这个 App
  local body
  body=$(code_lines "$1")
  printf '%s' "$body" | grep -q 'xctrace' \
    && printf '%s' "$body" | grep -q -- '--launch' \
    && printf '%s' "$body" | grep -Eq "[$][{]?($APPVARS)[}]?"
}

# 【每条判定都要点得到行】只有"Y/无"两个字的清单，别人第一句反问就是"你确定？"。
# 编号必须在**原文**上取（`grep -n`）再滤注释；先滤再编号的话行号会漂（本仓记过这个形状）。
pick_line() {  # pick_line <file> ⇒ 第一条命令位启动行的 "行号: 原文"，没有则空
  grep -nE "$(launcher_ere)" "$1" | grep -vE '^[0-9]+:[[:space:]]*#' | head -1 | cut -c1-88
}

classify() {  # classify <file> ⇒ "<该收尾吗 Y|N|?> <形状简述>"
  local f="$1"
  if [ -n "$(pick_line "$f")" ]; then
    printf 'Y 命令位起 App'
  elif is_xctrace_launcher "$f"; then
    printf 'N xctrace(随录制死)'
  else
    printf '? 没认出来'
  fi
}

sourced_by() {  # sourced_by <basename> ⇒ 谁 source 它（只作为图上给人看的事实，不参与判定）
  local base="$1" f
  for f in "$WATCH_DIR"/*.sh; do
    [ "$(basename "$f")" = "$base" ] && continue
    grep -Eq "source[[:space:]]+\"?[^\"']*${base%.sh}" "$f" && { printf '%s' "$(basename "$f")"; return 0; }
  done
  return 1
}

APPVARS=$(collect_app_vars)
if [ -z "$APPVARS" ]; then
  printf '!! 一个"App 句柄"都没解析出来（%s/*.sh 里没人把变量赋成 .app 路径？）\n' "$WATCH_DIR"
  printf '   ⇒ 这份清单**不作数**：启动形状认不出来时，它会安静地报"0 个问题"。\n'
  exit 1
fi

rows=0 offenders=0 mine_unsafe=0
printf '%s\n' "==> 起实例的形状清单（只报形状、不判因果。App 句柄：$(printf '%s' "$APPVARS" | tr '|' ' ')"
printf '%-40s %-3s %-5s %-18s %-24s %s\n' "脚本" "收尾" "trap" "广播退" "形状／谁 source" "命中行"
for f0 in "$WATCH_DIR"/*.sh; do
  [ -f "$f0" ] || continue
  verdict=$(classify "$f0")
  need="${verdict%% *}"; shape="${verdict#* }"
  [ "$need" = "?" ] && continue            # 既不启动也不录制 ⇒ 与本题无关，不进表
  base=$(basename "$f0")
  trap_ok="无";  code_lines "$f0" | grep -q 'trap ' && trap_ok="有"
  bcast="否";   code_lines "$f0" | grep -Eq "$SHAPE_BROADCAST" && bcast="是⇒会退掉别人的"
  # 不因"有兄弟脚本 source 它"而豁免：`ax_tooltip_report.sh` 恰恰既被 source、
  # 也能独立跑（今天它就是被独立跑起来的那一个）。宿主是谁只列在图上，由人判。
  host=""; host=$(sourced_by "$base") && host="被 $host source"
  rows=$((rows + 1))
  if { [ "$need" = "Y" ] && [ "$trap_ok" = "无" ]; } || [ "$bcast" != "否" ]; then
    offenders=$((offenders + 1))
    case "$base" in perf_*) mine_unsafe=$((mine_unsafe + 1)) ;; esac
  fi
  printf '%-40s %-3s %-5s %-18s %-24s %s\n' "$base" "$need" "$trap_ok" "$bcast" \
         "$shape${host:+ + $host}" "$(pick_line "$f0")"
done

printf '◇ 认出 %s 个会起 App/录制的脚本，其中 %s 个是"该收尾却没 trap / 会按 bundle id 广播退"的形状（性能侧名下 %s 个）\n' \
       "$rows" "$offenders" "$mine_unsafe"
[ "$rows" -gt 0 ] \
  || { printf '!! 一个都没认出（%s/*.sh）——目录扫错了还是形状又改了？这份清单此刻**不作数**。\n' "$WATCH_DIR"; exit 1; }
if [ "$STRICT" = 1 ] && [ "$mine_unsafe" -gt 0 ]; then
  printf '!! --strict：性能侧自己名下还有 %s 个"该收尾没收尾"的形状 ⇒ 非零\n' "$mine_unsafe"
  exit 1
fi
exit 0
