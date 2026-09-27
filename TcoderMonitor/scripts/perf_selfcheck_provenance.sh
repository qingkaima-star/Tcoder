#!/bin/bash
# perf_selfcheck_provenance.sh —— selfcheck 档的一块反例：第 14 项「被量的二进制归不归这份代码」。
# 由 scripts/perf_selfcheck.sh 的那个 for **source** 进来（不要单独执行：它只定义函数，不会自己跑）。
#
# 为什么单立一块（2026-09-27，#105 第 4 条搬法）：宿主 `perf_selfcheck_gates.sh` 在 §195 接了内容对账臂
# （296→339）、§197 又接了身份维夹具（339→384）之后只剩 16 行余量，下一次加东西必撞 scripts ≤400 行门
# （`SourcesSizeAuditTests`，超限就是全仓测试红）。**搬出去才是修复，抬线不是**（本仓第 14 次写这两个字）。
#
# 这一块的三兄弟问的是同一个问题——"这批读数能算在谁头上"：
#   · `selfcheck_binary_provenance`            第 14 项本体：rev／clean／tree 三个失效方向各钉一次
#   · `provenance_single_ruler_cases`          同一件事只许有一把手尺子（结构钉，由第 14 项调用）
#   · `provenance_content_matches_both_ways`   内容哈希五向（#107 后半，卷十二 §195）
#
# 判据、断言与 ok/fail 文案**逐字未动**；搬前搬后各跑一次 selfcheck，
# **要求是"项数与项号都不变"**（第 14 项还是第 14 项，只是函数定义换了文件）。
# 搬家那一次两边都是 79 项 —— 那是**当时**的读数，不是契约：#116 之后总数已经变 80，
# 拿绝对条数当判据会让每一次新增都变成一次"搬家搬坏了"的假红（同一条教训在文档侧也记过：别把条数抄进正文）。
# ⚠ 新建一块文件要同时进两张名册，否则"拆"本身变成免检通道：
#   ① `PerfRulerHotspotRatchetTests` 的 rulerScripts（函数级那两把尺：≤50 行／CC<16）；
#   ② `perf_selfcheck.sh` 的 _part 名单（source 得到，臂才算在场）——第 79 项专查这三张表对齐。
# =============================================================================
selfcheck_binary_provenance() {  # selfcheck_binary_provenance <outdir>
  # 14) 闸门第六维：**被量的二进制必须就是这份代码**。2026-09-21 实测踩过——
  #     上下文里写 `HEAD=e991c6d`，而 attach 的 `dist/Tcoder.app` 是两小时前从
  #     `41add9e` 建的（中间隔 39 个产物文件）。"e991c6d 的 T2 读数"是假的。
  #     纯函数三个失效方向各钉一次，放行方向也必须钉（不然恒拒的闸门又算白修）。
  if ! declare -f provenance_ok >/dev/null; then
    fail "provenance_ok 不在作用域里（preflight 没被 source），这条自检等于没跑"
    return
  fi
  local H=1111111111111111111111111111111111111111 B=2222222222222222222222222222222222222222 bad=0 why
  # 注意取非的方向：`provenance_ok` 回 0 = "可比"。rev 不同却回 0 才是要防的失效。
  if why=$(provenance_ok "$B" "$H" true); then
    fail "rev 不同却放行了（正是要防的那类归错对象）"; bad=1
  else
    case "$why" in *"产物是 2222222"*"当前代码是 1111111"*) ;;       *) fail "拒因里没带上两个短号，人拿这话查不到现场：$why"; bad=1 ;; esac
  fi
  if provenance_ok "$H" "$H" true; then :; else fail "同一份代码被判不可比——这条闸门会恒拒，量不出任何东西"; bad=1; fi
  if provenance_ok "" "$H" true; then fail "读不到 manifest 却放行"; bad=1; fi
  if provenance_ok "$H" "$H" false; then fail "构建时工作树是脏的却放行——那时连 rev 本身都不可信"; bad=1; fi
  if provenance_ok "$H" "" true; then fail "取不到 HEAD 却放行——无法比对就等于没验"; bad=1; fi
  # 【同一件事只许有一把手尺子】这三条结构钉拆到 `provenance_single_ruler_cases`：
  # 本仓 50 行线（`PerfRulerHotspotRatchetTests`）——拆函数才是修复，抬数字不是。
  provenance_single_ruler_cases
  # 14b) 同一项里再问一句"manifest 说的是不是**眼前这个文件**"（#107 的假绿通道）；
  #      不另开一项：项数 79 是常量，多印一句 ✓ 会让汇总凭空加一项。
  provenance_content_matches_both_ways "$1"
  # tree 放行这一支必须单独钉：它是"假拒"的唯一解药，也是最容易被写歪的一支
  #（写歪的方向是"永远认为相同"或"永远认为不同"，两边都不报错）。
  local T1=1111111111111111111111111111111111111111111111111111111111111111
  local T2=2222222222222222222222222222222222222222222222222222222222222222
  # 用**调用方的形状**验：真实调用一律 `WHY=$(provenance_ok …)`，所以留痕必须在 stdout 里——
  # 对变量的赋值出不了子 shell，上一版就是这样把"必须留痕"变成一句空话的。
  local treenote
  if treenote=$(provenance_ok "$B" "$H" true "$T1" "$T1"); then
    [ -n "$treenote" ] \
      || { fail "靠 tree 放行了却没把理由写到 stdout —— 悄悄放行比拒错更糟"; bad=1; }
  else
    fail "rev 不同但产物码 tree 相同却仍被拒（落地后同步头会被假拒，实测踩过一次）"; bad=1
  fi
  if provenance_ok "$B" "$H" true "$T1" "$T2"; then
    fail "产物码 tree 不同却放行 —— 那就是把身份判据废了"; bad=1
  fi
  if provenance_ok "$B" "$H" true "" "$T1"; then
    fail "缺 tree 信息还走 tree 放行（老 manifest 必须退回严格比 sha）"; bad=1
  fi
  [ "$bad" = "0" ] && ok "二进制出身判定双向都对（sha 相同 / tree 相同可放行且留痕 / 逐维破坏各判拒 ＋ 内容对账：配对放行、错配点名两个 sha 判拒）"
}

provenance_content_matches_both_ways() {  # provenance_content_matches_both_ways <outdir>
  # 14b) 第 14 项只管"rev/tree 对不对"，**没管 manifest 说的是不是眼前这个文件**：
  #      manifest 每棵树只有一份，而 `PERF_BIN` 能指任何 bundle ⇒ 装着 A 的 manifest 量 B 会一路绿灯
  #      （2026-09-27 §191 做双产物 A/B 时撞见，工单 #107）。这里把新那把尺**双向**钉：
  #      配对必须放行、错配必须拒且**两个 sha 都要印出来**（不然人查不到现场）。
  # ⚠ **故意不 `local bad`**：`fail()` 走的是动态作用域，本函数的判红要汇进调用方
  #   （第 14 项）那个 `bad`——上一版我把它 local 了，结果 4 条 ✗ 与 1 条 ✓ 同时印出来，
  #   读日志的人以为这一项过了。**一项红着就不许再印"双向都对"。**
  local dir="$1/content" bin mf want got why
  mkdir -p "$dir" || { fail "建不了夹具目录 $dir"; return; }
  bin="$dir/TcoderMonitor"; mf="$dir/RELEASE_MANIFEST.env"
  printf 'macho-A\n' > "$bin"
  want=$(shasum -a 256 "$bin" | cut -d' ' -f1)
  printf 'TCODER_BINARY_SHA256="%s"\n' "$want" > "$mf"
  # 用**调用方的形状**验（话术必须走 stdout，赋值出不了子 shell 那条老账）
  if why=$(provenance_binary_matches "$bin" "$mf"); then :; else
    fail "配对的二进制被判拒 ⇒ 这条闸门会恒拒，谁都会被它挡在测量外面：${why:-未给原因}"; bad=1
  fi
  printf 'macho-B-different-bytes\n' > "$bin"
  got=$(shasum -a 256 "$bin" | cut -d' ' -f1)
  if why=$(provenance_binary_matches "$bin" "$mf"); then
    fail "manifest 说的是 A 而量的是 B，却放行了 —— #107 那条假绿通道又开了"; bad=1
  else
    case "$why" in
      *"${want:0:12}"*"${got:0:12}"*) ;;                        # 两个短号都在 ⇒ 查得到现场
      *) fail "错配拒了但没点名两个 sha，人拿这话找不到现场：$why"; bad=1 ;;
    esac
  fi
  : > "$dir/empty.env"
  provenance_binary_matches "$bin" "$dir/empty.env" \
    && { fail "manifest 里根本没有那格哈希却放行（读不到不等于通过）"; bad=1; }
  provenance_binary_matches "" "$mf" \
    && { fail "连被量的二进制都不知道是谁却放行"; bad=1; }
  provenance_binary_matches "$dir/不在场" "$mf" \
    && { fail "被量的二进制不在场却放行"; bad=1; }
  # ⚠ 这里**不再 `ok` 一次**：项数是常量（79），多印一句 ✓ 会把汇总数凭空加一项，
  #    而"项数应当是常量、出声次数才是变量"这条规矩就白立了。判定由第 14 项那句 ok 一并出声。
  return "$bad"
}

provenance_single_ruler_cases() {  # 【同一件事只许有一把手尺子】结构钉，由 selfcheck_binary_provenance 调用
  # 我补 provenance 这一维时先是**又写了一份**，才发现 `verify_provenance.sh` 早就在做同一件事。
  # 现在判定住在 `perf_provenance.sh`，两边都 source 它。下面三条把这个结构钉住：
  # 定义处唯一、交付档确实走它、测量档不许留本地副本
  # （漏一天就会分叉，而分叉之后错的那份常在喂结论）。
  local defs
  # 模式必须锚行首：不锚的话它会把我**写在自检里的这串模式本身**当成一处定义
  # （第一版就是这么红的——报错报到自己头上，说明它真的在看内容）。
  defs=$(grep -lr '^provenance_ok() {' scripts/ 2>/dev/null | tr '\n' ' ')
  [ "$defs" = "scripts/perf_provenance.sh " ] \
    || { fail "provenance_ok 的定义不止一处（$defs）——同一判定又长出第二份了"; bad=1; }
  grep -q 'provenance_ok' scripts/verify_provenance.sh \
    || { fail "verify_provenance.sh 不再经过共享判定（大概又手抄了一遍 [ a = b ]）"; bad=1; }
  grep -q 'preflight_manifest_value\|^provenance_ok() {' scripts/perf_preflight.sh \
    && { fail "perf_preflight.sh 里还留着本地副本，删掉、只 source"; bad=1; }
}


# 判"编译在闸门之前、投递在闸门之后"。违规时打印是哪一对，返回 1。
pairing_order_violations() {  # pairing_order_violations <file>
  local f="$1" a p s
  a=$(grep -nE '^[[:space:]]*arm_synth_input([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)
  p=$(grep -nE '^[[:space:]]*preflight_context ' "$f" | head -1 | cut -d: -f1)
  s=$(grep -nE '^[[:space:]]*start_synth_input([[:space:]]|$)' "$f" | head -1 | cut -d: -f1)
  [ -n "$a" ] && [ -n "$p" ] && [ -n "$s" ] \
    || { echo "  三个动作没找齐（arm=${a:-?} preflight=${p:-?} start=${s:-?}）—— 换了名字要一起改这条判据"; return 1; }
  { [ "$a" -lt "$p" ] && [ "$p" -lt "$s" ]; } && return 0
  echo "  顺序不成立：arm=$a preflight=$p start=$s（要求 arm < preflight < start）"
  return 1
}