#!/bin/bash
# perf_selfcheck_eligibility.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 20~27：**一趟样本有没有资格被引用**（哨兵不许骗过判定、档位声明与复核不许互相矛盾、探针裸可调、
#     样本根要真被忽略、前置要能失败、越档不许印危急、一个 max 不许盖两件事、迟到帧归因）
#
# 为什么搬出来：本仓 ≤800 行棘轮的分母含 `.sh` 且 ceiling=0（`SelfScanDogfoodTests`），宿主 2026-09-21 涨到 835 行把门禁判红过一次——拆开它才是修复，拧阈值不是
# 判据、断言与 ok/fail 文案**逐字未动**；项与项之间只共享宿主的 fails / checked
# 两个计数器（bash 动态作用域）。拆前拆后各跑一次 `./scripts/perf_harness.sh selfcheck`，
# 31 项输出逐字 diff 过才算这刀没切坏。
# =============================================================================
selfcheck_probe_sentinel() {  # selfcheck_probe_sentinel <outdir>
  # 20) "探针取不到"这个哨兵必须是**一条判据**，而且是**数值之外**的一条。
  #     交互档的开录条件是"静默 <3s"，而 `quiescence_probe` 失败时打 `静默=-1.00s`——
  #     -1 在数轴上最小，直接拿它比阈值就等于"量不到 ⇒ 最有人在动 ⇒ 立刻开录"，
  #     一条恒真的闸门。今天写 cond_someone_active 时就是这么错的，靠这条钉住。
  local ok=1
  probe_usable "" && ok=0
  probe_usable "-1" && ok=0
  probe_usable "-1.00" && ok=0
  probe_usable "2.50" || ok=0
  [ "$ok" = "1" ] || { fail "probe_usable 四类输入判错（空/-1/-1.00 须拒、2.50 须放）"; return; }
  # 反向钉：承认哨兵确实会骗过阈值。哪天 awk 改了口径，上面那条的必要性就变了，
  # 这条要一起重写而不是悄悄留一段"防的是不存在的东西"的守卫。
  [ "$(human_input_in_window -1.00 3)" = "窗口内有人" ] \
    || { fail "human_input_in_window 不再被 -1 骗过——第 20 项前半段的理由要重写"; return; }
  # 结构钉：排程器不许长出**第二份静默探针**（两份迟早分叉，这次分叉正好在开录那一刻）。
  # 这条一开始写成"排程器里不许出现 swiftc"——那是个**代理指标**，
  # 今天就被自己的合成输入器（`perf_synth_scroll.swift`，投 CGEvent 的、不是尺子）撞红。
  # 代理指标的后果是：要么守卫被绕过习惯，要么正当事务被拦。改成钉它真正保护的东西：
  # 静默探针的源码名只许出现在 preflight/probes 那边。
  grep -q 'input_quiescence.swift' scripts/perf_wait_window.sh \
    && { fail "perf_wait_window.sh 里又出现静默探针源码——删掉，改成 source preflight 那把尺子"; bad=1; }
  # 反向钉：合成输入器**必须**继续从唯一的源文件编（别哪天在排程器里手抄一份投事件逻辑）
  # 【这条昨天判错过一次，所以换掉它守的东西】原来它要求"perf_wait_window.sh 里必须出现
  # perf_synth_scroll.swift"——那守的是**位置**，不是不变式；09-22 把编译搬进
  # perf_probes.sh（pulse 档要与 interact 档共用同一个输入器）之后，它把正确改动判成红。
  # 真正要守的是：**全仓恰好一个文件编译这个源文件**，别处一律 source 它、不重抄一份。
  # 形状要认得续行：编译写的是 `xcrun swiftc -O … <换行> …perf_synth_scroll.swift`，
  # 单行正则数出 0 处（第一版就这么把对的实现判成"没了"）。
  local builders="" f2
  for f2 in scripts/*.sh; do
    # 自扫排除 selfcheck 自己：这条判据的正文里就写着 `xcrun swiftc` 与那个文件名，
    # 算进去就是"判据被自己的说明文字绊倒"——今晚第四次踩同一类坑。
    case "$f2" in scripts/perf_selfcheck*) continue ;; esac
    grep -q 'xcrun swiftc' "$f2" && grep -q 'perf_synth_scroll\.swift' "$f2" && builders="$builders$f2 "
  done
  [ "$(printf '%s\n' $builders | grep -c . || true)" = "1" ] \
    || { fail "编译合成输入器的文件不是恰好一个（拿到：${builders:-0 个}）⇒ 要么长出第二把尺子，要么实现被搬丢"; bad=1; }
  case " $builders" in
    *" scripts/perf_probes.sh "*) : ;;
    *) fail "perf_probes.sh 里不再编译合成输入器 ⇒ interact / pulse 两档要用的那个二进制从哪来？"; bad=1 ;;
  esac
  ok "哨兵判定四类都对、且它防的失效真实存在；排程器只剩一把尺子"
}

selfcheck_period_eligibility() {  # selfcheck_period_eligibility <outdir>
  # 21) 「声明了什么档」和「收尾复核是否同意」必须一起判。
  #     这两个标记此前只有写的人没有读的人 ⇒ 整窗没人动的 interaction 样本
  #     照样打印「有资格答 T1」。八种形状各钉一次，且**两个否定必须与肯定不同**
  #     （否则这条断言会被一个恒真的实现糊过去）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import period_eligibility as pe
cases = [("clean-idle", {"period": "idle"}),
         ("dirty-idle", {"period": "idle", "contaminated_by_human_input": "1"}),
         ("clean-inter", {"period": "interaction"}),
         ("nobody-inter", {"period": "interaction", "no_human_input_during_window": "1"}),
         ("no-meta", {}),
         # 第三种打回形状：声明与复核**一致**，但窗口里整机在忙（包 18 的窗口内自采）。
         # 为什么必须进来：2026-09-23 20:49 三趟 idle 全被它打回，而表头当时说"互相矛盾"，
         # 于是我去查一个根本不存在的期间谎报 —— 归类错了的拒因比没有拒因更费人。
         ("busy-idle", {"period": "idle", "contaminated_by_foreign_load": "1"}),
         # 同窗双仪器档（归因那一趟，#43/#73）：两档都一律不给资格。它**不是坏样本**，
         # 而是"不是同一把尺量出来的那个量"——被测进程身上多了一枚 1 ms 采样器。
         # 这一维必须由这里读回来（而不是只写在 meta 里）：否则归因档会去填 §1.3 的 3/3。
         ("blame-idle", {"period": "idle", "blame_instrument": "1"}),
         ("blame-inter", {"period": "interaction", "blame_instrument": "1"})]
print("|".join("%s=%s" % (k, "Y" if pe(v)[0] else "N") for k, v in cases))')
  # 注意 `case` 里的 `|` 是**或**不是"与"：写成 `a=Y|b=N` 会被读成两个候选模式，
  # 于是"全串等于预期"永远匹不上——第一版就是这么红的（红得有价值：它当场把实际值打给我看）。
  [ "$r" = "clean-idle=Y|dirty-idle=N|clean-inter=Y|nobody-inter=N|no-meta=Y|busy-idle=N|blame-idle=N|blame-inter=N" ] \
    || { fail "八种形状的资格判定不对（拿到 ${r:-解析失败}）——该打回的样本又能蒙混了"; return; }
  # 反向钉：结论话术要跟着翻转，不能只改退出码、表头还写着"有资格"
  local yes no
  yes=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c \
    'from perf_trace_summary import period_eligibility as pe; print(pe({"period":"interaction"})[1])')
  no=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c \
    'from perf_trace_summary import period_eligibility as pe; print(pe({"period":"interaction","no_human_input_during_window":"1"})[1])')
  case "$yes" in *有资格*) ;; *) fail "干净 interaction 样本的话术里不再有「有资格」：$yes" ;; esac
  case "$no" in *"不可当交互期样本"*) ;; *) fail "没人滚的 interaction 样本话术没翻转（还是「$no」）——退出码判了、表头在骗人" ;; esac
  [ "$yes" != "$no" ] || { fail "两种样本话术一模一样，等于没判"; return; }
  # 反向钉（话术不许替原因说话）：表头那一句**只说打回、不指原因**，原因住在 `period_eligibility`。
  # 钉"不许出现『互相矛盾』"而不是钉"必须出现某句新话"——前者是这次的真错，后者只会逼下一个人改期望。
  local head
  head=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c \
    'from perf_trace_summary import refusal_headline as rh; print(rh())')
  case "$head" in *"互相矛盾"*) fail "表头又把每一种打回都说成「互相矛盾」（拿到「$head」）⇒ 拒因有两处出口，且这一处会指错方向" ;; esac
  case "$head" in *"打回"*"不得作为结论"*) ;; *) fail "打回那一行不再出声（拿到「$head」）——少印一行说明就等于让它蒙混" ;; esac
  ok "期间资格：八种形状各判一次，表头话术跟着翻转，且打回那一行不替原因说话"
}

selfcheck_probe_self_sufficient() {  # selfcheck_probe_self_sufficient <outdir>
  # 22) 今天 T1 采样断在这里：`perf_wait_window.sh` 直接 source 探针族，
  #     而 `QUIESCE_BIN` 只在 `perf_harness.sh` 头部赋过 ⇒ 一进 `set -u` 就
  #     `unbound variable`，脚本在"即将开录"那一刻死掉，人白等一场。
  #     ⇒ 取数原语必须**自带默认**；但**阈值不许跟着搬**（那是判定侧的东西）。
  local raw
  raw=$(bash -c 'set -euo pipefail
                 source scripts/perf_probes.sh 2>/dev/null
                 quiescence_probe' 2>&1)
  # 收尾那一串也一样要能在裸 `set -u` 下调通：今晚 `post_run_disk_hygiene` 引用了一个
  # 已被改名收掉的 `$MIN_FREE_GIB` ⇒ 录制**成功**的一趟被上层记成失败（丢了一份合格读数）。
  local hygiene
  hygiene=$(bash -c 'set -euo pipefail
                     source scripts/perf_preflight.sh 2>/dev/null
                     post_run_disk_hygiene /nonexistent-tcoder-sweep 2>&1' 2>&1)
  case "$hygiene" in
    *"unbound variable"*) fail "收尾磁盘卫生在裸 set -u 下有未初始化量：$hygiene"; return ;;
  esac
  printf '%s\n' "$hygiene" | grep -q '孤儿 trace' \
    || { fail "收尾磁盘卫生没真的跑起来（拿到「$hygiene」）——它不在场就等于每轮都没扫"; return; }
  case "$raw" in
    *"unbound variable"*) fail "探针族在裸 set -u 消费者下仍有未初始化量：$raw"; return ;;
  esac
  local q; q=$(quietest_seconds "$raw")
  [ -n "$q" ] || { fail "裸调探针取不到可解析的静默秒数（拿到「$raw」）"; return; }
  # 光"解析得出数字"不够：探针取不到时打的是 `静默=-1.00s`，**它解析得出来**！
  # 第一版第 22 项就是把这条写在解析层，于是探针路径指错（QUIESCE_SRC 少一段目录、
  # 编译失败退 JIT、JIT 也失败）时它照样绿——一条量不到东西的守卫比没有更坏。
  probe_usable "$q" || { fail "裸调探针只拿到哨兵 $q（编译/路径坏了），第 22 项不许把哨兵当读数"; return; }
  # 反向钉：阈值**不许**住在探针文件里（搬过去就等于把判定混进取数原语）
  bash -c 'set -euo pipefail; source scripts/perf_probes.sh >/dev/null 2>&1; [ -n "${QUIESCE_MIN:-}" ]' \
    && { fail "QUIESCE_MIN 跑进了 perf_probes.sh —— 合格线属于闸门，不该由取数原语带默认"; return; }
  [ "$(bash -c 'set -euo pipefail; source scripts/perf_preflight.sh >/dev/null 2>&1; printf %s "$QUIESCE_MIN"')" = "5" ] \
    || { fail "单独 source perf_preflight.sh 时 QUIESCE_MIN 没兜到 5（阈值默认不在闸门这边了）"; return; }
  ok "探针裸可调（自带默认）、阈值仍只住在闸门（双向都钉）"
}

selfcheck_perf_root_ignored() {  # selfcheck_perf_root_ignored <outdir>
  # 23) "样本落项目内被忽略的目录"这条规矩要有人守：改名、换路径、忘了加忽略，
  #     都会让 GB 级 .trace 静默出现在 `git status` 里（今天就把 tmp/ 暴露过一次）。
  local probe="$SCRATCH/probe-only.trace/contents"
  git check-ignore -q "$probe" \
    || { fail "$SCRATCH 没被 git 忽略（试 $probe）——下一轮取证就会把 trace 摊进版本库"; bad=1; }
  # 反向钉：不许再有人把样本默认值写回全局 /tmp（根名单点 = preflight 的 SCRATCH）
  local strays
  # 模式里那个 `[p]` 不是笔误：写成 `tcoder-perf` 会让这条 grep **先命中本文件里
  # 这串模式本身**（第 20 项的 `^provenance_ok() {` 今天已经为同样的事红过一次）。
  strays=$(grep -ln ':-/tmp/tcoder-[p]erf' scripts/*.sh 2>/dev/null | tr '\n' ' ')
  [ -z "$strays" ] \
    || { fail "这些文件里又出现写死的 /tmp 样本默认值：$strays（只许走 \$SCRATCH）"; bad=1; }
  # 反向钉之二（2026-09-21 补）：不许有"建不出来就把样本根退回全局临时目录"的兜底。
  # 上面那条 grep 抓不到它——形态完全不同，干的却是同一件事（GB 级 trace 落进 $TMPDIR）。
  # 只看代码行：注释里叙述旧写法是"为什么现在不许"的证据，不是口径（这条我自己刚踩）。
  #
  # 【这条差点是永真绿】第一版图案写成 BRE 的 `\$\{?\(TMPDIR\|/tmp\)`，
  # BSD grep 直接报 `invalid repetition count(s)` ⇒ 命中数永远为 0，
  # "真文件 0 命中"看着像通过，其实是图案根本没生效。
  # 现在这条图案是双向验过的：两行旧写法各命中一次、注释与话术行零命中、真文件零命中。
  local fallback
  fallback=$(grep -n 'SCRATCH="\$[({]TMPDIR' scripts/perf_harness.sh 2>/dev/null \
             | grep -v '^[0-9]*:[[:space:]]*#' | tr '\n' ' ')
  [ -z "$fallback" ] \
    || { fail "perf_harness.sh 里样本根还能退回全局临时目录：$fallback"; bad=1; }
  # 光"grep 不到"不够（那是结构钉）：真给一个建不出来的样本根，看它**拒不拒**。
  # 与第 24 项同一套道理——一条永远不会失败的前置，比没有更坏。
  local refusal
  refusal=$(TCODER_SCRATCH=/dev/null/nope-such-dir bash scripts/perf_harness.sh report /nonexistent 2>&1)
  case "$refusal" in
    *"拒绝录制"*) : ;;
    *) fail "样本根建不出来时没有拒绝录制，而是继续跑（拿到：$(printf '%s' "$refusal" | head -1)）"; bad=1 ;;
  esac
  # `${bad:-0}`：我自己刚立的规矩——闸门与判据里的量一律兜底，
  # 否则 `set -u` 下"读一个还没被赋过值的全局"就是**静默中止**（今天已经栽过一次）。
  [ "${bad:-0}" = "0" ] \
    && ok "样本根已被 git 忽略：无第二处写死默认值、无临时目录兜底、建不出来真的拒录"
}

selfcheck_disk_precondition() {  # selfcheck_disk_precondition <outdir>
  # 24) 今晚真发生的事：合并时"磁盘余量"这条判据留下了**两份实现**
  #     （preflight 的第七维 + harness 的 require_disk_headroom），
  #     我把 harness 那份改成委托时先指向了一个**不存在的函数**——
  #     `why=$(disk_headroom_bad …) && die` 里命令找不到 ⇒ rc≠0 ⇒ `&&` 不成立 ⇒
  #     前置**永远放行**，而 selfcheck 一路全绿。一条永真的前置比没有更坏。
  declare -f disk_headroom_bad >/dev/null \
    || { fail "disk_headroom_bad 不在场——所有调它的前置都会静默放行（今天就差一点）"; return; }
  local ok=1
  disk_headroom_bad 400 >/dev/null && ok=0       # 充足 ⇒ 合格
  disk_headroom_bad 3 >/dev/null || ok=0         # 不足 ⇒ 不合格
  disk_headroom_bad "" >/dev/null || ok=0        # 读不到 ⇒ 与不足同等对待
  [ -n "$(disk_headroom_bad 3)" ] || ok=0       # 不合格时要给出人话
  [ "$ok" = "1" ] || { fail "磁盘前置的三种输入（充足/不足/读不到）没各判对一次"; return; }
  # 结构钉：只许有一份实现（两处各写一遍就是这次合并撞出来的分叉）
  grep -Eq 'df +-k( -P)? +/System/Volumes/Data' scripts/perf_harness.sh \
    && { fail "perf_harness.sh 里又自己解析 df 了——删掉，改调 disk_headroom_bad"; bad=1; }
  grep -q 'disk_headroom_bad' scripts/perf_harness.sh \
    || { fail "录制前置不再经过共享判定（大概又手写了一遍 [ free -lt min ]）"; bad=1; }
  [ "${bad:-0}" = "0" ] && ok "磁盘前置三种输入各判对、且全仓只有一份判定"
}

selfcheck_display_regime() {  # selfcheck_display_regime <outdir>
  # 25) 2026-09-21 的现场：一份 idle 读数报 `HTR 18.33 危急·立刻处理`，
  #     但同一份数据里主线程 88.6% 的样本在等事件、整窗零人手输入、实测出帧只有 ~48/s——
  #     窗口静止时 ProMotion 降到 ~50 Hz，一帧本就该花 ~20 ms，
  #     拿 120 Hz 的 8.333 ms 预算去判必然系统性偏坏。**我差点把这句话当结论交出去。**
  # ⇒ 档位词必须先看实际出帧。四个边界各钉一次（含"读不到出帧数"不许用来给坏消息打折）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_metrics import in_display_regime as f
print(",".join("Y" if f(v, 8.333) else "N" for v in (119.7, 96.0, 95.9, 49.8, None, 0)))')
  [ "$r" = "Y,Y,N,N,Y,Y" ] \
    || { fail "实际刷新档位判定不对（拿到 $r，期望 Y,Y,N,N,Y,Y）——档位词会乱印"; return; }
  # 话术钉：喂**合成 loaded**，不依赖现场有没有真样本
  #     （第一版这里写成 `report "$1"`，$1 是自检目录、没有 hitch 表 ⇒
  #      拿到的是"未覆盖"那行，于是这条断言红在**夹具选错**上，不是守卫逻辑错。）
  local words
  words=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import hitch_regime_suffix as h
low = {"displayed-surfaces-per-second": {"json": {"fps_p50": 48}}}
hi = {"displayed-surfaces-per-second": {"json": {"fps_p50": 119.7}}}
# 夹具必须**长得像生产代码给的形状**（load_measure 返回的是 json/doc/present 三件套）：
# 只塞 {"json": None} 会让 fps_counts 去摸不存在的 doc 键，红的其实是夹具。
none = {"displayed-surfaces-per-second": {"json": None, "doc": None, "present": False}}
print("%s|%s|%s" % (bool(h(low, 8.333)), bool(h(hi, 8.333)), bool(h(none, 8.333))))
print(h(low, 8.333))')
  [ "$(printf '%s\n' "$words" | head -1)" = "True|False|False" ] \
    || { fail "越档后缀三态不对（拿到 $(printf '%s' "$words" | head -1)）"; return; }
  printf '%s\n' "$words" | tail -1 | grep -q '不判档' \
    || { fail "越档时话术里没有「不判档」——档位词还在乱印"; return; }
  ok "越档读数改口为「不判档，只记形状」；四边界与三态话术全对"
}

quiescence_chain_probe() {  # quiescence_chain_probe <夹具根绝对路径> → 每行 `档位|recheck|Y/N`
  # 【#127 的端到端腿】真跑**写侧**（`post_window_quiescence` + `meta_write`），再让**读侧**
  # （`period_eligibility`）判那份落盘——夹具只喂探针的形状：
  #   -1.00＝尺子当场掉了／3.00＝窗口里有人在动／99.00＝整窗没人。
  # 为什么不许只测 python 那半：#125 记的就是「臂在真实调用点死在 unbound variable」，
  # 写侧与读侧各自单测都会绿，串起来才钉得住这一格（也是本项能印出 `quiescence_recheck` 现值的唯一腿）。
  local root="$1" tier q
  while IFS='|' read -r tier q; do
    [ -n "$tier" ] || continue
    # `bash -c` 而不是在同进程里改函数：`quiescence_probe` 是全局函数，
    # 本项一 stub 它就会漏给后面的每一项（自检是一项一项顺序跑的）。
    bash -c '
      set -uo pipefail
      tier="$1"; q="$2"; dir="$3"
      source scripts/perf_preflight.sh >/dev/null 2>&1 || { echo "$tier|source-fail|N"; exit 0; }
      REV=selfcheck; DIRTY=0; PERIOD="$tier"
      quiescence_probe() { printf "%s\n" "静默=${q}s"; }
      mkdir -p "$dir"
      meta_write "$dir" "period=$tier" >/dev/null 2>&1
      post_window_quiescence "$dir" 20 >/dev/null 2>&1
      cd scripts && python3 - "$dir" <<PY
import json, sys
from perf_eligibility import period_eligibility as pe
m = json.load(open(sys.argv[1] + "/meta.json", encoding="utf-8"))
ok, _ = pe(m)
print("%s|%s|%s" % (m.get("period"), m.get("quiescence_recheck", "(absent)"), "Y" if ok else "N"))
PY
    ' _ "$tier" "$q" "$root/$tier-$q"
  done <<'ROWS'
interaction|-1.00
idle|-1.00
interaction|3.00
idle|99.00
ROWS
}

selfcheck_quiescence_recheck_states() {  # selfcheck_quiescence_recheck_states <outdir>
  # 71) 【#127】收尾人手复核「没做成」不许被读成「做成且没人动」。
  #     09-27 实测复现的旧形状：探针取不到时 `post_window_quiescence` 只印一行 stdout 就 return，
  #     meta **一个字段都不落**，而资格判据的形状是「没有污染标记就算合格」⇒
  #     交互档拿到「有资格答 T1」、心跳档拿到「只答心跳期」，两句都是绿灯；
  #     同一句还被 `perf_trio_agreement` 读进 §1.3 的 3/3 计数（一把判据、两个读者）。
  #     危害不是假想：判据① 唯一的取证出口是一次稀缺的真人窗口，那一趟若正好撞上尺子掉，
  #     **就会在没有任何一次人手证据的情况下把「交互期 hitch=0」交出去**。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_eligibility import period_eligibility as pe
def m(period, recheck="measured", **kw):
    d = {"period": period}
    if recheck is not None:
        d["quiescence_recheck"] = recheck
    d.update(kw)
    return d
def g(d):
    return "1" if pe(d)[0] else "0"
print("|".join([
    g(m("interaction", window_verdict="窗口内有人", input_source="synth@8ms")),
    g(m("interaction", recheck="unavailable")),
    g(m("idle", recheck="unavailable")),
    g(m("idle", window_verdict="窗口内没人")),
    g(m("idle", contaminated_by_human_input="1")),
    g(m("interaction", no_human_input_during_window="1")),
    g(m("interaction", recheck=None)),
]))')
  [ "$r" = "1|0|0|1|0|0|1" ] \
    || { fail "收尾复核三态七格没各判对（拿到 $r，应为 1|0|0|1|0|0|1）⇒ 第 2、3 条不是 0 就是「未判」又被读成「达标」，" \
              "第 7 条不是 1 就是有人把「缺字段」也判了死（那会追溯改动历史批次，要重新裁而不是顺手改）"; return; }
  # 话术钉：拒因必须点名「没做成」——写成「有人在动」就把排查方向带走了（包 9 那一族）。
  # ⚠ 这一腿必须待在 `$( )` 里：直接 `cd` 会把 cwd 改到 scripts/，
  # 而编排器与后面每一项都按「cwd = TcoderMonitor/」写相对路径（本项第一版就是这么坏的，
  # 症状是**下一段**的 `source scripts/...` 全报 source-fail——红在下一项身上，不在坏掉的那一项）。
  local words
  words=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_eligibility import period_eligibility as pe
print(pe({"period": "interaction", "quiescence_recheck": "unavailable"})[1])')
  printf '%s\n' "$words" | grep -q '没做成' \
    || { fail "拒因那句里没有出现「没做成」⇒ 会被引用成「样本本身脏了」（包 9 指错方向那一族）"; return; }
  local fx got
  fx="$(cd "$1" && pwd)/quiescence-recheck"
  got=$(quiescence_chain_probe "$fx" | sort | tr '\n' ' ')
  [ "$got" = "idle|measured|Y idle|unavailable|N interaction|measured|Y interaction|unavailable|N " ] \
    || { fail "写侧到读侧那条链没走通（拿到 $got）⇒ 要么 unavailable 那一格又没落盘，要么落了盘却没被资格尺读回来"; return; }
  ok "收尾复核未判/做成两态都落盘且被同一把资格尺读回；① ② 各不放过，缺字段不追溯"
}

selfcheck_load_window_uncollected_has_reader() {  # selfcheck_load_window_uncollected_has_reader <outdir>
  # 72) 【#128】`load_in_window=未采到` 这一格必须有**读者**。
  #     写侧其实早就落了（比 #127 那条诚实），但资格判据读的是 `contaminated_by_foreign_load`
  #     与收窗那两个点 ⇒ 零采样那一趟被「缺席」补成「整窗干净」。而 §AP 立这一维的原因正是
  #     「两端看不件中段的编译」：八趟里唯一落在 4.0 ms 红线内的那趟，收窗负载 19.73。
  #     形状＝**标记落地而判据住空集合**（第 38 类）：记了没人读等于没记。为什么单独成一项：
  #     第 52 项（`selfcheck_inwindow_load_verdict`）已经 45 行，再往里加格就撞「函数 ≤50 行」
  #     ⇒ 本仓口径是**新臂另开一格**，不是抬线（卷十三 §212 同族）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_eligibility import period_eligibility as pe
g = lambda m: "1" if pe(m)[0] else "0"
print("|".join([
    g({"period": "interaction", "load_in_window": "未采到"}),
    g({"period": "idle", "load_in_window": "未采到"}),
    g({"period": "idle", "load_samples": "4", "load1_max_in_window": "2.0"}),
    g({"period": "idle"}),
]))')
  [ "$r" = "0|0|1|1" ] \
    || { fail "整窗零采样四格没各判对（拿到 $r，应为 0|0|1|1）⇒ 第 1、2 条不是 0 就是「没采到」又被补成「干净」，" \
              "第 3 条不是 1 就是这条尺把采到了样本的趟也一并拒（恒拒），第 4 条不是 1 就是有人拿它追溯老批次"; return; }
  local words
  words=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_eligibility import period_eligibility as pe
print(pe({"period": "idle", "load_in_window": "未采到"})[1])')
  printf '%s\n' "$words" | grep -q '未采到' \
    || { fail "拒因里没出现「未采到」这个标记值 ⇒ 读的人分不清是尺子没在场还是机器真的空"; return; }
  # 端到端那一腿：真跑写侧（`load_window_verdict` 于一个没有 tsv 的目录），再让读侧判那份落盘。
  local fx got
  fx="$(cd "$1" && pwd)/load-window-uncollected"
  rm -rf "$fx"; mkdir -p "$fx"
  got=$(bash -c '
    set -uo pipefail
    dir="$1"
    source scripts/perf_preflight.sh >/dev/null 2>&1 || { echo "source-fail"; exit 0; }
    REV=selfcheck; DIRTY=0; PERIOD=idle; cores=15
    load_window_verdict "$dir" >/dev/null 2>&1
    cd scripts && python3 - "$dir" <<PY
import json, sys
m = json.load(open(sys.argv[1] + "/meta.json", encoding="utf-8"))
from perf_eligibility import period_eligibility as pe
ok, _ = pe(m)
print("%s|%s" % (m.get("load_in_window", "(缺)"), "Y" if ok else "N"))
PY
    ' _ "$fx")
  [ "$got" = "未采到|N" ] \
    || { fail "写侧到读侧没走通（拿到 $got，应为 未采到|N）⇒ 要么那一格又没落盘，要么落了盘还是没人读"; return; }
  ok "整窗零采样落成显式一格并被资格尺读回：两档都拒、有样本放行、缺格不追溯"
}
