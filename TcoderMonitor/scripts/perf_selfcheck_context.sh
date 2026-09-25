#!/bin/bash
# perf_selfcheck_context.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 38 / 40 / 53：**"这批量的是哪份内容、在什么条件下量的"**这一族判据
#   （38 补测改动前基线的 rev 归属、40 MEASURE_SECTION 要真的进到启动那一行、
#    53 第七维·预热：首扫尾巴不许伪装成稳态心跳）。
#
# 为什么单独成第 10 块：宿主 `perf_selfcheck_gates.sh` 到 **395/400**，是 #39 那根最紧的弦。
# 按本仓口径「拆，不抬线」把这三项整段搬出——**判据、断言与 ok/fail 文案逐字未动**，
# 项与项之间只共享宿主的 `fails`/`checked` 两个计数器（bash 动态作用域）。
# 拆前拆后各跑一次 `./scripts/perf_harness.sh selfcheck`，把输出**归一天生会变的格子**
# （秒级读数 / pid / rev 目录名）之后逐字 diff——这道验收的价值恰恰在于它是逐字的
# （同族做法见 `perf_selfcheck_windows.sh` 头注）。
#
# ⚠ 这一族搬的都是**闸门自身**的反例，所以本文件里不出现任何"起实例"的形状
#   （`perf_launcher_audit.sh` 是按物理行扫 `perf_*` 的，第 29 项就靠它；
#    历史上 `perf_selfcheck_gates.sh` 曾因一行散文被误判成"会广播退"两次）。
selfcheck_measure_rev_attribution() {  # selfcheck_measure_rev_attribution <outdir>
  # 38) `MEASURE_REV`（工单包 5）只允许改"**归属比的是谁**"，不许改成"不比"。
  #     为什么单独钉：还掉 §Q 那 14 处之后，交付要回答"从 X 降到 Y"，
  #     而 X 只能是**重新量出来的**（spec §1.3 明令旧日志里的数不许当 X）。
  #     一旦"补测改动前基线"这条路只能靠绕开归属闸门，那它一定会被绕——
  #     所以这条路必须是"**照样判、只是判另一个 rev**"。
  local pf=scripts/perf_preflight.sh bad=0 other
  grep -qF 'TARGET_REV=$(provenance_target_rev)' "$pf" \
    || { fail "$pf 不再从 `provenance_target_rev` 取被测 rev ⇒ 派生又长出第二份"; bad=1; }
  grep -qF 'provenance_ok "$BUILD_REV" "${TARGET_REV:-$(provenance_target_rev)}"' "$pf" \
    || { fail "归属又拿 raw HEAD 比 ⇒ 拿别的 rev 的读数会算到 HEAD 头上（那是假归属）"; bad=1; }
  dn=$(grep -c '^provenance_target_rev() {' scripts/*.sh | awk -F: '{s+=$NF} END{print s+0}')
  [ "$dn" = "1" ] || { fail "被测 rev 的派生有 $dn 处定义（应为 1）⇒ 两处迟早分叉"; bad=1; }
  grep -qF 'provenance_product_tree "${MEASURE_REV:-HEAD}"' "$pf" \
    || { fail "tree 那一侧没跟着换 ⇒ 两半比的是不同对象，比谁都可能假放行"; bad=1; }
  source scripts/perf_provenance.sh
  if provenance_ok "abc1234" "" true "t1" "t2"; then
    fail "被测 rev 取不到（空串）却放行 ⇒ rev 写错就等于免检"; bad=1
  fi
  if provenance_ok "abc1234" "$(git rev-parse HEAD)" true ""; then
    fail "产物与被测 rev 不同、又没给 tree，却放行"; bad=1
  fi
  other=$(git rev-parse HEAD~1 2>/dev/null)
  if [ -n "$other" ] && provenance_ok "${other:0:7}" "$(git rev-parse HEAD)" true; then
    fail "相邻两个提交被判成同一份代码（比 sha 那条路宽了）"; bad=1
  fi
  # rev 不存在 ⇒ 必须空值（调用方按 fail-closed 处理）。
  # 【这里原来还写过一条"HEAD 与 HEAD~1 的 tree 必须不同"，那是**我判错的判据**】
  # HEAD~1 是 `b66ea39`，只动 docs ⇒ 两棵子树逐字节相同，而"tree 相同就放行"正是包 4
  # 立这条规则的目的（免得一行文档逼一次 46 秒重建 + 一整轮假拒）。
  # 把设计当缺陷钉下去，红得很响，但错在我这边——留在这里防止有人再加回同一条。
  local a
  a=$(provenance_product_tree HEAD)
  [ -n "$a" ] || { fail "HEAD 的产物码 tree 指纹取不到（Sources/Resources 布局改了？）"; bad=1; }
  [ -z "$(provenance_product_tree 没有这个rev 2>/dev/null)" ] \
    || { fail "不存在的 rev 竟然给出 tree 指纹 ⇒ 拼出来的路径会像真有一个产物"; bad=1; }
  # `perf_measure_rev.sh` 取不到 rev 必须**非零且不印 env 行**（第一版死在子 shell 里，rc=0）
  local out; out=$(bash scripts/perf_measure_rev.sh env 没有这个rev 2>/dev/null); rc=$?
  { [ "$rc" != "0" ] && [ -z "$out" ]; } \
    || { fail "perf_measure_rev.sh 取不到 rev 还是出了货（rc=$rc 输出「$out」）⇒ 空串会拼出一个看起来存在的产物路径"; bad=1; }
  [ "$bad" = "0" ] && ok "补测改动前基线这条路照样判归属：MEASURE_REV 只改比谁、不改比不比（含空值判败与子 shell 反例）"
}

selfcheck_section_wiring() {  # selfcheck_section_wiring <outdir>
  # 40) `MEASURE_SECTION` 必须**真的进到启动那一行**（包 11 / 任务 #25）。
  #     为什么单列：补丁第一次 `git apply` 成功、`bash -n` 也过、selfcheck 43 项全绿，
  #     可启动行还是 `"$bin" -ApplePersistenceIgnoreState YES &` —— 数组定义了却没被用，
  #     于是"按页测"这句话是**假的**：跑出来的还是默认页。
  #     ⇒ 形状类判据（"定义了变量"）不够，必须钉到**使用点**上；反例夹具证明这条判据不是摆设。
  # 【这条判据第一次跑就抓到我自己写错文件名】`sm` 原本写成 `.sh`，
  # 于是它报「不读 meta.section」——那句话本身是对的，只是理由错了（读的人住在 `.py` 里）。
  # 留在这里：判据报错时先复核"我指的是哪个文件"，别急着改判据的宽严。
  local pb=scripts/perf_probes.sh hm=scripts/perf_harness.sh sm=scripts/perf_trace_summary.py bad=0 body
  body=$(awk '/^launch_measured_instance\(\)/,/^}/' "$pb")
  wiring_ok() {  # 启动行引用 sec_args 的展开（不是"文件里出现过这个名字"）
    printf '%s' "$1" | grep -Eq '"\$bin"[^&]*\$\{sec_args\[@\]'
  }
  wiring_ok "$body" \
    || { fail "$pb 的启动行没用 sec_args ⇒ 传了 MEASURE_SECTION 也还是默认页"; bad=1; }
  if printf '%s\n' '  "$bin" -ApplePersistenceIgnoreState YES >/dev/null >&1 &' \
       | sed 's/>&1/2>\&1/' | { body=$(cat); wiring_ok "$body"; } ; then
    fail "反向夹具（没接线的启动行）被判成合格 ⇒ 这条判据是摆设"
    bad=1
  fi
  grep -qF 'section=${MEASURE_SECTION:-' "$hm" \
    || { fail "$hm 没把页名落进 meta ⇒ 报表无从知道自己量的哪一页（§Z 的按页验收又回空）"; bad=1; }
  grep -q 'meta.get("section")' "$sm" \
    || { fail "$sm 不读 meta.section ⇒ 页维度有写没读（同第 28 项那条老账）"; bad=1; }
  [ "$bad" = "0" ] && ok "MEASURE_SECTION 三处接线齐（启动行真的用它 / meta 落盘 / 报表读回），且没接线的形状会被抓"
}

selfcheck_warmup_dimension() {  # selfcheck_warmup_dimension <outdir>
  # 第七维·预热：etime 解析 + 未预热要拒 + 启动档不参与。
  # 样例照 `ps -o etime=` 的真排版喂（前置空格），**正反两个方向都要**：
  # 只测拒的一面，"永远拒"这种同样坏的形状就抓不住。
  # ⚠ 顺带钉住一条更一般的规矩：**被 source 的库不许设 shell 选项**——
  #   这个分片自己就是靠"单独 source preflight"跑的，一旦哪层库加了 `set -u`，
  #   整条链会在第一个未绑定变量处静默退出（实测过：拒跑分支不再落 REFUSED、rc=127）。
  local bad=0 got
  got=$(bash -c '
    ps() { printf "  %s\n" "$FAKE"; }          # 覆盖外部命令：喂夹具，跑的仍是函数本体
    source scripts/perf_preflight.sh || { echo "source preflight 失败"; exit 1; }
    for pair in "01:23:83" "12:34:56:45296" "1-02:03:04:93784" "00:07:7"; do
      FAKE="${pair%:*}"; want="${pair##*:}"
      got=$(instance_uptime_seconds 12345)
      [ "$got" = "$want" ] || { echo "解析错：$FAKE ⇒ $got（要 $want）"; exit 1; }
    done
    FAKE="abc"; [ "$(instance_uptime_seconds 12345)" = "取不到" ] || { echo "坏排版没判成取不到"; exit 1; }
    uptime_secs=30; hard=0; PREFLIGHT_TIER=measure; preflight_gates_warmup >/dev/null 2>&1
    [ "$hard" = "1" ] || { echo "低于预热线却没有拒跑"; exit 1; }
    uptime_secs=300; hard=0; preflight_gates_warmup >/dev/null 2>&1
    [ "$hard" = "0" ] || { echo "已预热却被拒"; exit 1; }
    uptime_secs=5; hard=0; PREFLIGHT_TIER=launch; preflight_gates_warmup >/dev/null 2>&1
    [ "$hard" = "0" ] || { echo "启动档被预热线拒了"; exit 1; }
    exit 0' 2>&1) || bad=1
  [ "$bad" = "0" ] || { fail "预热这一维不成立：$got"; return; }
  ok "预热维成立：四种 etime 排版逐个对得上、坏排版判「取不到」（不回落成 0）、未预热判拒、已预热判放、启动档不参与"
}

selfcheck_main_drift_reading() {  # selfcheck_main_drift_reading <outdir>
  # 64) 「落后 main 几笔产品码」这一格（第 25 类盲区的测量侧出口）。
  #     五个形状各钉一次。为什么必须有真 git 夹具：这把尺的两种坏法都是**静默**的——
  #     pathspec 少了 `:/` 会永远报 0（"总是最新"），rev 打错会回空串（"不知道"），
  #     两者看起来都像正常输出。
  local fx="$1/driftfx" c base got same sub bogus pp
  rm -rf "$fx"; mkdir -p "$fx/TcoderMonitor/Sources" "$fx/docs"
  # 绝对路径：四格都要在**别的 cwd** 里 source 同一个库，否则"换目录仍是 1"那一格是假的。
  pp=$(cd scripts && pwd)/perf_provenance.sh
  c="git -C $fx -c user.name=selfcheck -c user.email=selfcheck@local"
  git -C "$fx" init -q -b main . >/dev/null 2>&1 \
    || { fail "夹具仓库起不来 ⇒ 本项一条都没判（不是判据不符）"; return; }
  $c commit -q --allow-empty -m base
  echo a > "$fx/TcoderMonitor/Sources/a.swift"; $c add -A; $c commit -q -m product-earlier
  base=$(git -C "$fx" rev-parse HEAD)
  echo d > "$fx/docs/d.md"; $c add -A; $c commit -q -m docs-only           # 纯 docs：不该计入
  echo b > "$fx/TcoderMonitor/Sources/a.swift"; $c add -A; $c commit -q -m product-later
  got=$(cd "$fx" && source "$pp"; provenance_main_drift "$base")
  same=$(cd "$fx" && source "$pp"; provenance_main_drift main)
  bogus=$(cd "$fx" && source "$pp"; provenance_main_drift nosuchrev999)
  sub=$(cd "$fx/TcoderMonitor" && source "$pp"; provenance_main_drift "$base")
  [ "$got" = "1" ] && [ "$same" = "0" ] && [ "$bogus" = "未取到" ] && [ "$sub" = "1" ] \
    || { fail "读数四形状不对（落后=$got 期望1｜同码=$same 期望0｜乱rev=$bogus 期望未取到｜子目录=$sub 期望1）" \
             "⇒ 少 `:/` 会永远报 0，那种坏法是静默的"; return; }
  local note
  note=$(cd "$(dirname "$TRACE_REPORT")" && PYTHONPATH=. python3 -c '
from perf_trace_summary import freshness_note as f
print("%s|%s|%s" % ("不知道" in f(""), "同码" in f("0"), "3 笔" in f("3") and "不绑" in f("3")))')
  [ "$note" = "True|True|True" ] \
    || { fail "表头那句三态不对（拿到 ${note:-解析失败}）⇒ 「没查到」会被印成「没落后」"; return; }
  ok "基线新鲜度：只数产品码（1 不是 2）、同码报 0、乱 rev 报未取到、换 cwd 仍是 1，表头三态各说各的"
}
