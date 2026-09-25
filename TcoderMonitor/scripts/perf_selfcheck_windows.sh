#!/bin/bash
# perf_selfcheck_windows.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 48/49/51/52：**冷启动档与窗口负载判定**（页名要逐条过名册、归属必须写给"被测内容"、
#     公开的 LOAD_MAX 出口要真的改判、窗口内采样必须能定合格/不合格，含"没采到"那一格）。
#
# 为什么单独成第 8 块：宿主 `perf_selfcheck_launchers.sh` 又涨回 **396/400**——
#   `perf_selfcheck_trap.sh` 那一刀（`81213d7`）搬走 67 行之后它重新长了回来，
#   同一个尺寸债第二次到期。按本仓口径「拆，不抬线」把这四项整段搬出，
#   **判据、断言与 ok/fail 文案逐字未动**；项与项之间只共享宿主的 fails / checked 两个计数器
#   （bash 动态作用域）。拆前拆后各跑一次 `./scripts/perf_harness.sh selfcheck`，
#   61 项输出逐字 diff 过才算这刀没切坏。
# =============================================================================
selfcheck_switch_page_names() {  # 48) 冷启动档的页名：名册里的要过、名册外的要当场红
  # 今天的现场：`PAGES="总览 性能监控"` 被当成**一个**不存在的页 ⇒ App 静默回落到默认页，
  # 四趟量的全是总览，而屏幕上没有任何一处说"你要的第二页没测"。页名含空格是本产品常态。
  local pf=scripts/perf_preflight.sh sw=scripts/perf_switch.sh bad=0 d="$out/page-names"
  mkdir -p "$d"
  # 用 printf 造**真换行**：`$'…'` 只在源码字面量里展开，作为变量传下去就是一个
  # 以美元符开头的普通字符串 ⇒ 合法清单会被我自己误判成"名册外的页名"。
  local want
  want=$(printf '总览\nGit 洞察')
  bash -c 'source scripts/perf_preflight.sh >/dev/null 2>&1
           source scripts/perf_switch.sh >/dev/null 2>&1
           PAGES="$1" switch_page_list' _ "$want" > "$d/ok.txt" 2>"$d/ok.err" \
    || { fail "两个合法页名（含带空格的 `Git 洞察`）被判不合格 ⇒ 九页里再有一页改名就整档跑不了"; bad=1; }
  [ "$(wc -l < "$d/ok.txt" | tr -d ' ')" = "2" ] \
    || { fail "合法清单不是两行（实得 $(wc -l < "$d/ok.txt" | tr -d ' ') 行：$(tr '\n' '|' < "$d/ok.txt")）⇒ 按行遍历又断了"; bad=1; }
  grep -qxF 'Git 洞察' "$d/ok.txt" \
    || { fail "带空格的页名被拆开了 ⇒ 第 27 项那条老账（`Git` + `洞察`）复活"; bad=1; }
  if bash -c 'source scripts/perf_preflight.sh >/dev/null 2>&1
               source scripts/perf_switch.sh >/dev/null 2>&1
               PAGES="$1" switch_page_list' _ "总览 性能监控" > "$d/bad.txt" 2>"$d/bad.err"; then
    fail "名册外的页名被判合格 ⇒ 它会被 SwiftUI 静默换成默认页，那批读数没有资格答任何一页"
    bad=1
  fi
  grep -qF '不认的页名' "$d/bad.err" \
    || { fail "拒是拒了，却没说是哪个页名不认 ⇒ 报出来像脚本坏了而不是参数错了"; bad=1; }
  [ "$bad" = "0" ] && ok "冷启动页名逐个对回名册：含空格的名不被拆、名册外的当场红且点名（不许静默回落）"
}

selfcheck_switch_attribution_and_refusal() {  # 49) 冷启动档另两件：归属写给"被测内容"、没有 die 也要拒
  # `local` 会先把名字**遮蔽成未设**再逐个赋值 ⇒ 同一条 `local` 里引用自己前半段的名字，
# 在 `set -u` 下就是 unbound（今天撞过一次：`local d=… m="$d/…"`）。
  local bad=0 d="$out/attr" full
  local m="$d/meta"
  mkdir -p "$m"
  full=$(git rev-parse HEAD)
  # (1) `measured_rev`：归属那一格必须跟着 `MEASURE_REV` 走，而不是跟着"跑脚本那棵树"的 HEAD。
  #     今天的现场：换 `PERF_BIN` 量旧产物时，页级 meta 仍写着新 rev ⇒ 旧读数被盖上新章。
  REV=abc123 DIRTY=0 MEASURE_REV=HEAD~1 meta_write "$m" "page=探测"
  local got
  got=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('measured_rev',''))" \
         "$m/meta.json" 2>/dev/null)
  [ "$got" = "$(git rev-parse HEAD~1)" ] \
    || { fail "meta 的 measured_rev 没跟着 MEASURE_REV（实得「$got」）⇒ 归属还是那棵树的 HEAD"; bad=1; }
  # (2) 没设 MEASURE_REV ⇒ 必须等于 HEAD（不许留空、也不许写"取不到"）
  rm -f "$m/meta.json"
  REV="$full" DIRTY=0 meta_write "$m" "page=探测"
  got=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('measured_rev',''))" \
         "$m/meta.json" 2>/dev/null)
  [ "$got" = "$full" ] \
    || { fail "不设 MEASURE_REV 时 measured_rev 不等于 HEAD（实得「$got」）⇒ 每批默认读数都要多问一句"; bad=1; }
  # (3) 反向：rev 写错必须**说出来**，不许悄悄回落成 HEAD（第 38 项立的形状，这里在启动档再钉一次）
  rm -f "$m/meta.json"
  REV=x DIRTY=0 MEASURE_REV="这个rev不存在" meta_write "$m" "page=探测"
  got=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1],encoding='utf-8')).get('measured_rev',''))" \
         "$m/meta.json" 2>/dev/null)
  case "$got" in 取不到*) ;; *) fail "写错的 rev 被写成「$got」⇒ 该出声的地方它没出声"; bad=1 ;; esac
  # (4) 没有 `die` 的进程里，不合格的一趟**必须非零退出**：`die` 住在宿主脚本，单独 source 本文件时不在场。
  #     实测（2026-09-23）：缺 die ⇒ "拒跑"分支以 rc=0 走完，闸门从拒翻成放。
  #     放行那一侧不在这里验——第 17 项的六维矩阵已经钉过"全合格 ⇒ 通过"。
  local rc=0
  bash -c 'source scripts/perf_preflight.sh >/dev/null 2>&1
           mkdir -p "$1"; MEASURE_REV="这个rev不存在" preflight_context "$1" "" launch' _ "$d/refuse" \
    >/dev/null 2>&1 || rc=$?
  [ "$rc" != "0" ] \
    || { fail "宿主 `die` 不在场时，不合格的一趟仍以 rc=0 收尾 ⇒ 一条会静默放行的闸门（最坏方向）"; bad=1; }
  [ -f "$d/refuse/REFUSED" ] \
    || { fail "拒了却没在目录上留 REFUSED ⇒ 后来的人会把空目录读成『量过了』"; bad=1; }
  [ "$bad" = "0" ] && ok "冷启动档：归属写给被测内容（含 rev 写错要出声），且缺 die 时仍然拒跑 + 落 REFUSED"
}

selfcheck_load_threshold_override() {  # 51) 公开的 LOAD_MAX 出口必须**真的改判**，且回显生效的那个数
  # 现场（2026-09-23 17:17）：注释写着"LOAD_MAX 可覆盖"，代码里阈值写死 `c*1.5`。
  # 我拿 LOAD_MAX=5 去要更严的心跳窗口，闸门照旧按 22.5 放行 ⇒ 一趟 load1=13.44/15 的样本被采下来，
  # 量出 24.8 ms（同一个二进制在 load 4.6 起的那趟是 1.59 ms）。**写在判据旁边的出口必须是出口**。
  local pf=scripts/perf_preflight.sh bad=0 out pass
  ask() {  # ask <LOAD_MAX> ⇒ 打印"hard=0/1 与闸门话术"
    bash -c "source $pf >/dev/null 2>&1
             load1=8; cores=15; hard=0
             LOAD_MAX=\"\${1:-}\" preflight_gates_load 2>&1 || true
             echo \"hard=\$hard\"" _ "${1:-}"
  }
  out=$(ask "")
  case "$out" in *"hard=0"*) ;; *) fail "默认阈值下 load1=8/15 核被判不合格 ⇒ 默认口径被改了（要改默认值得明说理由）"; bad=1 ;; esac
  out=$(ask 5)
  case "$out" in *"hard=1"*) ;; *) fail "LOAD_MAX=5 没让闸门变严 ⇒ 写在判据旁边的出口是空头的"; bad=1 ;; esac
  # 话术是两行（阈值那一行 + 下一行提示），先压成一行再判，免得"换行"把匹配拆开
  local flat; flat=$(printf '%s' "$out" | tr '\n' ' ')
  case "$flat" in *"阈值 5"*) ;; *) fail "拒了但没印出真正生效的那个数（印 22.5 判 5 = 屏幕上说的和判的不是一回事）"; bad=1 ;; esac
  case "$flat" in *"由 LOAD_MAX 显式覆盖"*) ;; *) fail "覆盖了阈值却不说明 ⇒ 报告里看不出这批不是默认条件"; bad=1 ;; esac
  [ "$bad" = "0" ] && ok "负载阈值：默认照旧、LOAD_MAX 能变严，且话术里印的就是生效的那个门槛"
}

inwindow_fixture() {  # inwindow_fixture <目录> <tsv 内容…> —— 摆一份窗口内采样夹具
  local d="$1"; shift; mkdir -p "$d"; printf '%b' "$*" > "$d/load-in-window.tsv"; rm -f "$d/meta.json"
}

inwindow_meta() {  # inwindow_meta <目录> [<LOAD_MAX>] —— 真跑一次判定，回显 meta 里那几格
  local bar="${2-}"
  LOAD_MAX="$bar" bash -c "source scripts/perf_preflight.sh >/dev/null 2>&1
    source scripts/perf_measure_io.sh >/dev/null 2>&1
    REV=x; DIRTY=0; cores=15; load_window_verdict \"\$1\"" _ "$1" >/dev/null 2>&1
  python3 -c "
import json,sys
try: m=json.load(open(sys.argv[1]+'/meta.json',encoding='utf-8'))
except Exception: m={}
print(m.get('load_bar_used'), m.get('contaminated_by_foreign_load'),
      m.get('load1_max_in_window'), m.get('heavy_max_in_window'), m.get('load_in_window'))" "$1" 2>/dev/null
}

selfcheck_inwindow_load_verdict() {  # 52) 窗口内负载采样必须能定合格/不合格（四种形状，含"没采到"）
  # 现场（§AP，09-23 17:17–17:44）：八趟里唯一落在 4.0 ms 红线内的那趟，收窗负载是 19.73——
  # 旧复核只看"起窗前"与"收窗时"两个点，放行了中段被编译挤满的窗口。
  local d="$out/inwindow" bad=0 got
  # (1) 整窗干净 ⇒ 峰值被记下、不判污染，阈值回显默认那一个
  inwindow_fixture "$d/clean" '1\t2.0\t0\n2\t3.0\t0\n3\t2.5\t0\n'
  got=$(inwindow_meta "$d/clean")
  [ "$got" = "22.5 None 3.0 0 None" ] || { fail "整窗干净那趟的形状不对：「$got」"; bad=1; }
  # (2) 中段峰值 9.9：默认阈值放行，但 LOAD_MAX=4 必须判污染 ⇒ 证明闸门与窗口内判据同一家
  inwindow_fixture "$d/mid" '1\t2.0\t0\n2\t9.9\t0\n3\t2.5\t0\n'
  got=$(inwindow_meta "$d/mid")
  [ "$got" = "22.5 None 9.9 0 None" ] || { fail "默认阈值下中段峰值没被如实记下：「$got」"; bad=1; }
  got=$(inwindow_meta "$d/mid" 4)
  [ "$got" = "4 1 9.9 0 None" ] || { fail "LOAD_MAX=4 没让窗口内判据变严（实得「$got」）⇒ 两处各一套阈值"; bad=1; }
  # (3) 中段出现过重活 ⇒ 负载再低也判污染：重活与负载是两件事，不许互相顶替
  inwindow_fixture "$d/jobs" '1\t2.0\t0\n2\t2.1\t1\n'
  got=$(inwindow_meta "$d/jobs")
  case "$got" in *"1 2.1 1 "*) ;; *) fail "窗口内出现过重活却没判污染（实得「$got」）⇒ 这条闸只看负载不看名字"; bad=1 ;; esac
  # (4) 一个样本都没采到 ⇒ 必须出声写「未采到」，不许把空目录读成"整窗干净"（假绿里最坏的那种）
  mkdir -p "$d/none"; rm -f "$d/none/meta.json"
  got=$(inwindow_meta "$d/none")
  case "$got" in *"未采到"*) ;; *) fail "缺样时 meta 写的是「$got」而不是「未采到」⇒ 空会被读成干净"; bad=1 ;; esac
  # (5) 窗口内的"重活"必须排掉**我们自己 spawn 的那个采集进程**：`xctrace` 在重活名单里
  #     （它确实是最重的争用），而录制窗口里必然有它一个 ⇒ 不排就是**每一批必判污染**。
  #     实证是 2026-09-23 22:03 那三趟：起窗时「并发重活=无」，窗口内 heavy 峰值却有 3/2/3。
  declare -f filter_out_pids >/dev/null \
    || { fail "source 链里没有 filter_out_pids ⇒ 这一维看不见东西，拒绝判定（恒放行比恒拒更危险）"; bad=1; }
  [ "$(filter_out_pids "111 222" "111")" = "222" ] \
    || { fail "外部那个 pid 被一起排掉了（拿到「$(filter_out_pids "111 222" "111")」）⇒ 按名字排会把别人的采集也放掉"; bad=1; }
  [ -z "$(filter_out_pids "111" "111")" ] \
    || { fail "只剩自己那一个时没排干净 ⇒ 自己的 xctrace 又会把整批判污染"; bad=1; }
  [ -z "$(filter_out_pids "" "111")" ] \
    || { fail "空名单被排出了东西"; bad=1; }
  # (6) **明细列必须与计数列共用同一份过滤结果**（09-24 #49）。旧写法用第二种过滤法
  #     （`grep -vF -x` 去比 `pid=<self>`，可明细行长成 `pid=<self> name=xctrace`，整行永不相等）
  #     ⇒ 第三列排掉了自己、第四列却把我的 xctrace 写成"在场的重活"。
  #     这不是排版问题：我照着 run4 那行 `pid=32337 name=xctrace` 立过一张"别人在录制"的错单。
  heavy_names_for_pids "pid=111 name=xctrace" "" >/dev/null \
    || { fail "source 链里没有 heavy_names_for_pids ⇒ 这一维看不见东西，拒绝判定"; bad=1; }
  [ -z "$(heavy_names_for_pids "pid=111 name=xctrace" "")" ] \
    || { fail "只剩自己那一个采集进程时明细列还在点名 ⇒ 读的人会去找一个不存在的干扰源"; bad=1; }
  [ "$(heavy_names_for_pids "pid=111 name=xctrace pid=222 name=swiftc" "222")" = "pid=222 name=swiftc" ] \
    || { fail "别人那个 swiftc 没被点出来（实得「$(heavy_names_for_pids "pid=111 name=xctrace pid=222 name=swiftc" "222")」）⇒ 明细列与计数列不同源"; bad=1; }
  [ "$bad" = "0" ] && ok "窗口内负载采样能定合格：干净放行 / 中段越阈判污 / 重活单独也判 / 没采到必须出声 / 自己那一个采集进程不算外部争用（计数与明细同一份过滤）"
}
