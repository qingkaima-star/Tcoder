#!/bin/bash
# perf_selfcheck_ledger.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 72/73：**台账装订层**（节号唯一、每节有指路行、指路行文本 == 标题、搬家标题不许以节号开头）。
#
# 为什么这块要进 selfcheck 而不是留在 `/tmp`（台账卷十 §165）：
# 2026-09-26 开第十卷时我用一次性核验抓到三条旧账（10 条双前缀指路行、卷七 17 节只列了 4 行、
# 卷五那行 `## §93 起搬家到第六卷` 造出一个假 §93），三条都改了 —— **然后那把尺随会话消失**。
# 这正是卷七 §107 记过的形状：一条验收落地之后，没有任何尺子检查它还在不在。
# ⇒ 判据搬进 `scripts/ledger_binding_check.py`，本块就是它的**读者**：尺被删、被改坏、
#   或者只会给绿，这两项立刻红。
#
# ⚠ 本块**不测测量链**。尺子本体不带 `perf_` 前缀，所以
#   `PerfRulerHotspotRatchetTests.testRosterCoversEveryScriptOnDisk` 的盘上全集（按前缀取）
#   不会把它算成"没点名的尺"；而本文件带前缀是为了跟同族块放在一起，它住进 `rulerScripts`
#   是因为那里要求"搬进来的反例名额继续被量"（函数 ≤50 行、CC < 16）——不是因为它量帧率。
# =============================================================================

# 共用：造一份"干净"的两节夹具。每次调用重建 ⇒ 臂与臂之间不共享状态。
ledger_fixture_clean() {  # ledger_fixture_clean <目录>
  rm -rf "$1"
  mkdir -p "$1"
  printf '%s\n' '## 本节一览（§1 起）' '' '· §1 甲' '· §2 乙' '' '## §1 甲' '正文' '## §2 乙' '正文' \
    > "$1/整改清单-甲卷.md"
}

# 共用：跑一次尺子，把输出与退出码编成一份可读日志（rc 紧跟命令，别等 printf）。
_ledger_run() {  # _ledger_run <夹具目录>
  local log rc
  log=$(python3 scripts/ledger_binding_check.py --root "$1" 2>&1)
  rc=$?
  printf '%s\nrc=%s\n' "$log" "$rc"
}

# 共用：一次反例算"抓到"，当且仅当 rc=1 **且**日志点到那一类的名。
_ledger_red() {  # _ledger_red <日志> <必须点到的名>
  case "$1" in *"rc=1"*) ;; *) return 1 ;; esac
  case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac
}

selfcheck_ledger_binding_reads_the_real_ledger() {  # 72) 真台账全绿 + 分母自己出声 + 读不到目录要判错
  local bad=0 d="$out/ledger-real" vols blocked sections rows
  mkdir -p "$d"
  if ! python3 scripts/ledger_binding_check.py > "$d/real.txt" 2>&1; then
    fail "真台账被判红 ⇒ 装订层破了，明细在 $d/real.txt（别改判据消红，按它点名的卷/节补指路行）"
    bad=1
  fi
  grep -qF '判定：成立' "$d/real.txt" \
    || { fail "rc=0 却没印出结论那一行 ⇒ '一行都没印'会被下游读成通过（本仓记过的老账）"; bad=1; }
  vols=$(sed -n 's/.*普查 \([0-9][0-9]*\) 本卷册.*/\1/p' "$d/real.txt")
  [ "${vols:-0}" -ge 10 ] \
    || { fail "只数到 ${vols:-0} 本卷册（<10）⇒ 枚举或路径坏了，那句「成立」不作数"; bad=1; }
  # 分母的**第二维**：卷册数够不代表尺看得见 —— 有块的卷数与节总数必须一起出声，
  # 否则"正则失配 → 每卷都数成 0 节 → 全部记成未覆盖 → rc=0"这条路是通的（第 73 项第 5 臂实测过）。
  blocked=$(sed -n 's|.*/ 有块 \([0-9][0-9]*\) 本.*|\1|p' "$d/real.txt")
  sections=$(sed -n 's|.*/ 节 \([0-9][0-9]*\) 处.*|\1|p' "$d/real.txt")
  rows=$(sed -n 's|.*/ 块内行 \([0-9][0-9]*\) 条.*|\1|p' "$d/real.txt")
  [ "${blocked:-0}" -ge 4 ] \
    || { fail "带一览块的卷册只有 ${blocked:-0} 本（<4）⇒ 块判据失配，未覆盖被冒充成通过"; bad=1; }
  [ "${sections:-0}" -ge 70 ] \
    || { fail "节总数只有 ${sections:-0} 处（<70，2026-09-26 现量 77）⇒ 扫节号那一维坏了"; bad=1; }
  [ "${rows:-0}" -ge 50 ] \
    || { fail "块内指路行只有 ${rows:-0} 条（<50，现量 54）⇒ 指路行那一维坏了"; bad=1; }
  # 反向：根目录不存在 ⇒ 必须 rc=1 并说清是分母问题，不许给绿
  if python3 scripts/ledger_binding_check.py --root "$d/没有这个目录" > "$d/miss.txt" 2>&1; then
    fail "根目录不存在却 rc=0 ⇒ 一把读不到东西的尺给了绿灯"
    bad=1
  fi
  grep -qF '分母不成立' "$d/miss.txt" \
    || { fail "拒了，但没说是分母问题 ⇒ 报出来像脚本坏了而不是目录错了"; bad=1; }
  [ "$bad" = "0" ] && ok "装订层普查在真文档上全绿：${vols:-?} 本卷册 / 有块 ${blocked:-?} 本 / ${sections:-?} 节 / ${rows:-?} 行由尺自己出声、读不到目录判错（72）"
}

selfcheck_ledger_binding_names_each_blemish() {  # 73) 三种坏形状各红一次，且点名到卷/节
  local bad=0 d="$out/ledger-fixture" log
  # (1) 基线：干净夹具必须先过 —— 它不过，下面三臂的"红"就全都无意义
  ledger_fixture_clean "$d"
  python3 scripts/ledger_binding_check.py --root "$d" > "$d/base.txt" 2>&1 \
    || { fail "干净夹具自己都过不了（$d/base.txt）⇒ 判据错，三条反例的红不可信"; bad=1; }
  # (2) 少一条指路行 ⇒ 红，并点名是哪一节
  grep -v '^· §2 乙$' "$d/整改清单-甲卷.md" > "$d/tmp.md" && mv "$d/tmp.md" "$d/整改清单-甲卷.md"
  log=$(_ledger_run "$d")
  _ledger_red "$log" "缺指路行" || { fail "删掉 §2 那一行没被点名 ⇒ 缺行会变成静默漂移（实得 $log）"; bad=1; }
  # (3) 指路行带双前缀（§165 现场那 10 条的形状）⇒ 红，且说"与标题不一致"
  #     ⚠ 这里原来用 `python3 -c 'io.open(p,"w").write(io.open(p).read()…)'`：
  #     **`"w"` 那个句柄在实参求值之前就把文件截空了**，于是夹具变成零字节，
  #     尺子回一句「无一览块 → 未覆盖」外加 rc=0 —— 一次假绿（正是这一格要防的事）。
  #     改法：先读后写的顺序交给 awk（流式，不碰原文件），再 mv。
  ledger_fixture_clean "$d"
  awk 'BEGIN{done=0} {if(!done && $0=="· §1 甲"){print "· §1 §1 甲"; done=1; next} print}' \
    "$d/整改清单-甲卷.md" > "$d/tmp.md" && mv "$d/tmp.md" "$d/整改清单-甲卷.md"
  log=$(_ledger_run "$d")
  _ledger_red "$log" "指路行与标题不一致" || { fail "双前缀那种行没被抓到 ⇒ §165 那 10 条会重演（实得 $log）"; bad=1; }
  # (4) 搬家标题以节号开头 ⇒ 既点名禁止形状，又抓到它造出的跨卷重复节号
  ledger_fixture_clean "$d"
  printf '## §1 起搬家到甲卷\n' > "$d/整改清单-乙卷.md"
  log=$(_ledger_run "$d")
  _ledger_red "$log" "搬家标题以节号开头" || { fail "假节号标题没被点名 ⇒ 普查会凭空多出一节（实得 $log）"; bad=1; }
  _ledger_red "$log" "跨卷重复节号" || { fail "假节号造成的重复节号没被抓到 ⇒ 卷五那次重演（实得 $log）"; bad=1; }
  # (5) 集体看不见 ⇒ 不许绿。夹具：只剩一本"没有一览块"的卷（等价于正则或枚举坏掉时的样子）。
  #     这一臂就是上面那条假绿的正面材料：尺子在 09:25 第一版跑它时 rc=0，加了 `blocked==0` 判错才红。
  rm -rf "$d"
  mkdir -p "$d"
  printf '%s\n' '# 一本老卷册（没有一览块，也没有 `## §` 形状）' '' '## 3. 条目表' '- 内容' \
    > "$d/整改清单-老卷.md"
  log=$(_ledger_run "$d")
  _ledger_red "$log" "一本带「本节一览」块的卷册都没数到" \
    || { fail "读不到任何块却给了绿 ⇒ 与『坏掉的尺最擅长产出看着合理的数』同族（实得 $log）"; bad=1; }
  [ "$bad" = "0" ] && ok "装订层四种坏形状各红一次并点名：缺行、双前缀、假节号重复、集体看不见（73）"
}
