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
  #     照样打印「有资格答 T1」。四种形状各钉一次，且**两个否定必须与肯定不同**
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
         ("busy-idle", {"period": "idle", "contaminated_by_foreign_load": "1"})]
print("|".join("%s=%s" % (k, "Y" if pe(v)[0] else "N") for k, v in cases))')
  # 注意 `case` 里的 `|` 是**或**不是"与"：写成 `a=Y|b=N` 会被读成两个候选模式，
  # 于是"全串等于预期"永远匹不上——第一版就是这么红的（红得有价值：它当场把实际值打给我看）。
  [ "$r" = "clean-idle=Y|dirty-idle=N|clean-inter=Y|nobody-inter=N|no-meta=Y|busy-idle=N" ] \
    || { fail "五种形状的资格判定不对（拿到 ${r:-解析失败}）——该打回的样本又能蒙混了"; return; }
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
  ok "期间资格：五种形状各判一次，表头话术跟着翻转，且打回那一行不替原因说话"
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

selfcheck_app_update_split() {  # selfcheck_app_update_split <outdir>
  # 26) `app-update` 那行原来只报 max ⇒ "超 20.2 倍"。同一份数据里 p95 是 3.4 ms：
  #     整体很快 + 一次 168 ms 孤例，被一个数同时说反两次。
  #     现在拆成三种形状各钉一次：整体快 ⇒ 达标；少数孤例 ⇒ 「stall N 个」；
  #     整表贴着一帧（≥20% 行超预算）⇒ **不叫 stall**，只报数并说"单位待核"（09-23 改判）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import app_update_verdict as v
small = [0.5] * 600 + [3.0] * 40
outl = [1.0] * 600 + [168.3]
big = [12.0] * 30 + [30.0] * 10
print("A|%s" % v(small, 8.333)[1][:6])
print("B|%s" % v(outl, 8.333)[1][:14])
print("C|%s" % v(big, 8.333)[1][:14])
print("D|%s" % v(outl, 8.333)[0])')
  printf '%s\n' "$r" | grep -q '^A|达标（没有' \
    || { fail "全是小值时没判成「达标」：$(printf '%s' "$r" | tr '\n' ' ')"; return; }
  printf '%s\n' "$r" | grep -q '^B|主线程 stall 1 个' \
    || { fail "单个 168ms 孤例没被单独点出来（其余 600 个不该跟着背锅）"; return; }
  printf '%s\n' "$r" | grep -q '^C|40/40 行' \
    || { fail "整表超预算还被说成「40 个 stall」（拿到 $(printf '%s' "$r" | grep '^C|' | cut -c3-40)）"\
             "⇒ 上屏跟满 120 帧时这句话与实测矛盾"; return; }
  printf '%s\n' "$r" | grep -q '^B|主线程 stall' \
    || { fail "少数孤例也被一并降格成「不判」⇒ 该查的那个 168ms 没人查了"; return; }
  printf '%s\n' "$r" | grep -q 'p95 1.00' \
    || { fail "分布里没有 p95（拿到 $(printf '%s' "$r" | grep '^D|' | cut -c3-60)）"; return; }
  ok "app-update 判定分得清「整体快 + 一个孤例慢」与「普遍慢」"
}

selfcheck_phase_blame() {  # selfcheck_phase_blame <outdir>
  # 27) 42 个迟到帧里有 13 次 update 超预算 ⇒ 大多数迟到与主线程无关。
  #     这种"该去查谁"的判断必须有一条尺子替人做，否则下一个读表的人会直接去改 update 常数。
  # 第五种形状是 09-23 现场逼出来的：交互档样本 `n=2090 / 下限 9.31 ms` 对上 24 个迟到帧，
  #     旧尺子印出"比 7671%"并下一句"几乎一比一 ⇒ 先查主线程"。那是拿**按事件节拍计**的表
  #     定归因（与 §R 里我自纠的那次误读同一个错，只是换了一支函数）。
  #     ⇒ 窄分布必须**闭嘴指路**，而且这一条与 `caveat_for` 共用同一条数值判据
  #     （`interval_shaped`）——判据抄成第二份的那天，两支函数就会互相打脸。
  # 第六到第八种（09-24 #46）：归因行原来只吃两张表，于是它会把"update 相位没超"说成
  #     "主线程没被占住"——同一张表里 `potential-hangs` 明明印着 5 次 / 2725 ms。
  #     ⇒ 第三路输入必须有，且**第八种是反向的**：hangs 为空时旧话术要一字不动，
  #     否则这条新维度会变成"什么都判不成立"的永真绿。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_metrics import phase_blame as p, interval_shaped as ish
a = p([1.0] * 10 + [9.0] * 42, [10.0] * 42, 8.333)[1]     # 一比一 + 宽分布 ⇒ 查主线程
b = p([1.0] * 600 + [168.3], [10.0] * 42, 8.333)[1]       # 只占极少数 ⇒ 分开修
c = p([1.0] * 100, [10.0] * 5, 8.333)[1]                  # 一次都没超 ⇒ 全在合成侧
d = p([1.0], [], 8.333)[1]                                # 无迟到帧 ⇒ 不给任何归因
e = p([9.31] * 2090, [8.33] * 24, 8.333)[1]               # 窄分布 ⇒ 不判，只指路
t = p([1.0] * 1000 + [9.0] * 50, [10.0] * 24, 8.333)      # 宽分布但超预算 2.1 倍 ⇒ 说"倍"且不判归因
H = [441.3, 887.2]                                        # 同一窗口主线程被占住两次的形状
g = p([1.0] * 100, [10.0] * 5, 8.333, H)                  # #46 正身：相位没超 + 有 hangs
h = p([1.0], [], 8.333, H)                                # 无迟到帧 + 有 hangs
i = p([1.0] * 600 + [168.3], [10.0] * 42, 8.333, [])[1]   # 反向：hangs 为空 ⇒ 旧话术一字不动
print("%s|%s|%s|%s|%s|%s|%s|%s|%s" % (
    "先查主线程" in a, "分开修" in b, "全在渲染/合成侧" in c,
    d == "—", "不判" in e and "time-profile" in e,
    "倍" in t[0] and "7671" not in t[0] and t[1].startswith("不判"),
    "归因未定" in g[1] and "别改视图更新常数" not in g[1] and "887" in g[1],
    "不判" in h[1] and "887" in h[0],
    i == b and "阻塞" not in i))')
  [ "$r" = "True|True|True|True|True|True|True|True|True" ] \
    || { fail "迟到帧归因八种形状没各判对（拿到 $r）"; return; }
  ok "迟到帧归因分得清「查主线程 / 分开修 / 全在合成侧 / 无迟到 / 窄分布不判 / 比值悬殊不判 / 有 hangs 不许归给合成侧」"
}

selfcheck_pulse_window_scope() {  # selfcheck_pulse_window_scope <outdir>
  # 41) FramePulse 的摘要行**总数是生命期累计**，不许被当成"本窗口"的读数（09-23 抓到）。
  #     现场：报表一路写着"同窗 FramePulse"，而 `a5298d5-interact-run1` 那份是
  #     `帧数=26941 ≈ 225 s` 对 20 s 的录制窗口 —— 因为 `cmd_idle` 的顺序是
  #     "起实例 → 录 hitches → 录 time-profile → **最后**才读脉冲"。
  #     受影响的不只是措辞：§M 那个"回调比上屏晚约 0.7 ms"的偏移量就是这么算出来的，
  #     所以那条结论今天降级为**未定**，要重测（重测的前置见交接笔记 §AA）。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_framepulse import stale_instance as st, verdict
def R(n, hz=120.0):
    return {"refresh_hz": hz, "expected_interval_ms": 1000.0 / hz, "frame_count": n,
            "frame_p50_ms": 8.33, "frame_p95_ms": 9.03, "frame_p99_ms": 9.2,
            "frame_max_ms": 25.0, "hitch_count": 0, "hitch_per_second": 0.0,
            "ticks_with_hitch": 0, "ticks_with_hitch_total": 13, "heartbeat_max_gap_ms": 27.0,
            "refresh_source": "fixture", "summaries": 1, "bad_ticks": []}
a = st(R(2450), 20.0)              # 20 s × 120 Hz ≈ 2400 帧 ⇒ 新鲜
b = st(R(26941), 20.0)             # 225 s 的累计 ⇒ 生命期
c = st(R(26941), 0.0)              # 没给窗口 ⇒ 无从判，也不许硬说它是本窗口
_, code = verdict(R(26941), interaction=True, window_seconds=20.0)
txt, code2 = verdict(R(2450), interaction=True, window_seconds=20.0)
print("%s|%s|%s|%s|%s" % (a, b, c, code, "生命期" in txt))')
  [ "$r" = "False|True|False|2|False" ] \
    || { fail "脉冲的『窗口 vs 生命期』四种形状没各判对（拿到 $r，应为 False|True|False|2|False）" \
             "⇒ 报表会把一份 225 s 的累计读数写成 20 s 窗口的 p95"; return; }
  ok "脉冲读数分得清「本窗口」与「生命期累计」：生命期一律不判窗口，交叉核对也随之停判"
}

selfcheck_trio_agreement() {  # selfcheck_trio_agreement <outdir>
  # 39) 「连测 ≥3 趟**且取值一致」**里的**后半句**必须有尺子量（spec §1.3）。
  #     触发事件是 09-23 02:35 那一幕：`[interact] rc=0 ⇒ 可用 3/3 趟` 打得理直气壮，
  #     而三趟的 hitch/s 是 **1.20 / 1.30 / 18.80**（同头同产物、六维上下文逐条合格）。
  #     "可用"数的是结构（产物齐、没被 REFUSED、复核没打回），**从来没数过一致性**——
  #     于是排程器的 3/3 被所有人读成"协议满足"。数样本 ≠ 量一致。
  local r
  r=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trio_agreement import verdict
def R(n, fps=119.0, secs=20.0, rend=4.1, per="interaction", upd=None):
    return {"dir": "run", "seconds": secs, "hitch_n": int(round(n * secs)),
            "hitch_per_s": n, "period": per, "render_p50_ms": rend,
            "update_max_ms": upd, "surfaces_p50_fps": fps}
a = verdict([R(1.2), R(1.3), R(1.5)], ["a", "b", "c"])[1]                 # 交互档：一致
b = verdict([R(1.2), R(1.3), R(18.8)], ["a", "b", "c"])[1]                # 09-23 真形状：不一致
c = verdict([R(1.2), R(1.3), None], ["a", "b", "x"])[1]                   # 缺件 ⇒ 不判
d = verdict([R(1.2), R(1.3)], ["a", "b"])[1]                              # 不足 ⇒ 不判
e = verdict([R(1.2), R(1.3, fps=88.0), R(1.5)], ["a", "b", "c"])[1]       # hitch 一致但出帧分歧
f = verdict([R(1.2), R(1.3), R(1.5, per="idle")], ["a", "b", "c"])[1]     # 混档 ⇒ 不判
g = verdict([R(0.0, per="idle", upd=1.8), R(0.95, per="idle", upd=2.3),   # idle 档：hitch 0~0.95 是
             R(0.0, per="idle", upd=2.0)], ["a", "b", "c"])[1]            # 正常散布，比 T2 判据量
print("%s|%s|%s|%s|%s|%s|%s" % (a, b, c, d, e, f, g))')
  [ "$r" = "0|1|2|2|1|2|0" ] \
    || { fail "一致性判定七种形状没各判对（拿到 $r，应为 0|1|2|2|1|2|0）⇒ 这条尺会把「3/3」放行"; return; }
  # 第 7 条是**我自己第一版被自己的尺子抓到的**那条：idle 档的 hitch 真值≈0，
  # 拿它做除法散布会把 0.00~0.95 判成"19.0× ⇒ 严重不一致"。判据量必须跟着档位走。
  ok "同档连测的一致性有尺子了：按档取判据量（交互比 hitch/s、idle 比 app-update 最大值），七形状各判一次"
}

