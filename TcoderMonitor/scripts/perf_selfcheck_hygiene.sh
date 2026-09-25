#!/bin/bash
# perf_selfcheck_hygiene.sh —— selfcheck 档的一块反例，由 scripts/perf_selfcheck.sh **source** 进来。
#
# 反例 61：**判废趟的原始 trace 回收**（缺陷 #70）。这一族以前没有任何反例，
#   因为「收尾扫残骸」这条规矩只有 $TMPDIR 那一半被量过（第 22 项）—— 产物搬进
#   仓库 `.scratch/` 之后旧清理器扫的是个不再有人写字的目录，而 215 GiB 的真实
#   残骸不在任何判据的射程里：**守卫全绿，磁盘照涨**。所以这块的分工是：
#   第 22 项管「收尾有没有真的跑起来」，本项管「回收这一维判得对不对、
#   以及它有没有接到那个出口上」。
#
# 双向是硬要求（本仓口径：扫描型判据必须两个方向都红过一次）：
#   反例侧 1 —— 合格趟里放一个巨大的 trace ⇒ **不许**被点名（否则回收器会删掉
#                唯一能解释「这档正常多大」的样本，下一轮的中位数就没有底座）；
#   反例侧 2 —— 被拒但尺寸正常的趟 ⇒ **不许**被点名（那份 trace 还能回收重导）；
#   反例侧 3 —— 样本不足的档 ⇒ 明写不判，且**不许**在该档里点名；
#   反例侧 4 —— 一趟都没认出来的空样本根 ⇒ 必须明写"没有分母"，且**不许**印可回收计数
#                （新克隆的树、或者目录命名口径改了的树，读起来都该是"没查成"而不是"干净"）；
#   正例     —— 被拒 ∧ 超同档线 ⇒ 必须点名，默认只印不删，`TCODER_RECLAIM=1` 才删，
#                删的时候只动 `*.trace`，判定与上下文（REFUSED / meta.json）原样留着；
#                第一层与 `archive-*/` 第二层各放一处，两层都要认得到。
# 造尺寸用真写出来的字节：回收器量的是实际占盘块数，`truncate` 糊的稀疏文件
# 量不出大小 —— 那把尺子故意不认「看起来大但盘上不存在」的身材。
# =============================================================================

mk_reclaim_run() {  # mk_reclaim_run <样本根> <趟名> <trace KiB> <REFUSED 0|1>
  local d="$1" name="$2" kib="$3" refused="$4" run
  run="$d/$name"
  mkdir -p "$run/hitches.trace"
  dd if=/dev/zero of="$run/hitches.trace/data.bin" bs=1024 count="$kib" status=none
  printf '{"rev":"abc1234"}\n' > "$run/meta.json"
  if [ "$refused" = "1" ]; then
    printf 'REFUSED\n这一趟判废：合成夹具。\n' > "$run/REFUSED"
  fi
  return 0
}

reclaim_fixture() {  # reclaim_fixture <dir>：四个形状各占一处
  local d="$1"
  # idle 档 6 个样本：4 正常 + 1 被拒但正常尺寸 + 1 被拒且巨大（唯一该点名的）
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run1 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run2 8 1
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run3 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run4 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-idle-run5 240 1
  # interact 档 4 个样本：其中一个**巨大但没被拒** ⇒ 尺寸线不能单独定罪
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run1 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run2 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run3 8 0
  mk_reclaim_run "$d" tcoder-perf-fix-interact-run4 240 0
  # switch 档只有 1 个样本 ⇒ 分母太小，整档不判（哪怕那个 trace 又大又被拒）
  mk_reclaim_run "$d" tcoder-perf-fix-switch-run1 240 1
  # 第二层：判废之后被整批挪进 `archive-*/` 的那些趟也要在射程内
  # （真实树上就有这么一批，只扫一层等于把"先攒着、以后再说"排除在回收之外）
  mk_reclaim_run "$d/archive-fake" tcoder-perf-fix-idle-run6 240 1
}

selfcheck_refused_trace_reclaim() {  # 61) 判废趟的 GB 级 trace：该点名的点名、不该动的一个字不动
  local d="$out/reclaim" rc=0 txt="$out/reclaim-print.txt" hygiene listed key orphan=""
  # 顺带钉住一件事（本项自己就是这种失效的最新例子）：**新增一块反例文件必须真的
  # 被宿主的 `_part` 名单 source 到**。函数定义了却没人调用 ⇒ 一项反例静默消失，
  # 而 selfcheck 的项数照样在涨。取不到那一行时 `listed` 只剩空格 ⇒ 每块都算孤儿，
  # 方向是**往红失败**（名单形状变了要当场出声，不能读成"都挂上了"）。
  listed=" $(sed -n 's/^for _part in \(.*\); do$/\1/p' scripts/perf_selfcheck.sh) "
  for key in scripts/perf_selfcheck_*.sh; do
    key=${key##*perf_selfcheck_}; key=${key%.sh}
    case "$listed" in *" $key "*) ;; *) orphan="$orphan $key" ;; esac
  done
  if [ -n "$orphan" ]; then
    fail "反例块没被宿主 source：$orphan ⇒ 里面的项一个字都不会跑"
    rc=1
  fi
  rm -rf "$d"
  reclaim_fixture "$d"
  if ! python3 scripts/perf_reclaim.py "$d" > "$txt" 2>&1; then
    fail "回收尺子跑一趟就非零退出 ⇒ `set -e` 下它会中止整个收尾（第 22 项那个形状）"
    return
  fi
  # ---- 正例：被拒 ∧ 超同档中位线 ⇒ 点名，并把拒因带出来
  if ! grep -qF 'tcoder-perf-fix-idle-run5/hitches.trace' "$txt"; then
    fail "被拒且超同档线的那趟没被点名 ⇒ 回收这一维等于没上线（现读 $(tr '\n' '|' < "$txt")）"
    rc=1
  fi
  if ! grep -qF 'tcoder-perf-fix-idle-run6/hitches.trace' "$txt"; then
    fail "挪进 `archive-*/` 第二层的那趟没被认出来 ⇒ 回收器的射程还是只扫一层（真实树上就有一批判废趟在第二层）"
    rc=1
  fi
  if ! grep -qF '2 个 bundle 可回收' "$txt"; then
    fail "点名的个数不是 2（该点的是第一层与第二层各一处）⇒ 尺寸线或档位分母算错了"
    rc=1
  fi
  if ! grep -qF '合成夹具' "$txt"; then
    fail "点名了却没带拒因 ⇒ 报出来像脚本自己数了个数，不像在说这趟为什么能删"
  fi
  # ---- 反例侧 1：巨大但**没被拒** ⇒ 不许点名
  if grep -qF 'tcoder-perf-fix-interact-run4' "$txt"; then
    fail "没被拒的巨大 trace 被点名 ⇒ 会删掉唯一解释「这档正常多大」的样本，下一轮中位数失去底座"
    rc=1
  fi
  # ---- 反例侧 2：被拒但尺寸正常 ⇒ 不许点名（还能回收重导，那份 trace 值得留）
  if grep -qF 'tcoder-perf-fix-idle-run2/hitches.trace' "$txt"; then
    fail "被拒但尺寸正常的趟被点名 ⇒ 静默探针拒掉的那趟照样能重导，删它就是销毁可回收的读数"
    rc=1
  fi
  # ---- 反例侧 3：样本不足的档明写不判，且不判就得真的不判
  if ! grep -qF '档 switch 样本 1' "$txt"; then
    fail "只有 1 个样本的档没有明写「不判」⇒ 分母太小的散布会被当成判据（裁 A 同一族）"
    rc=1
  fi
  if grep -qF 'tcoder-perf-fix-switch-run1' "$txt"; then
    fail "样本不足的档仍然点了名 ⇒ 「不判」只是话术，判定照跑"
    rc=1
  fi
  # ---- 默认只印不删
  if [ ! -d "$d/tcoder-perf-fix-idle-run5/hitches.trace" ]; then
    fail "没给 TCODER_RECLAIM 就真删了 ⇒ 回收取证原件必须显式授权"
    rc=1
  fi
  # ---- 出口接线：尺子存在≠每轮都印，收尾那一串里要看得见这一维
  hygiene=$(bash -c 'set -euo pipefail
                     source scripts/perf_preflight.sh 2>/dev/null
                     post_run_disk_hygiene /nonexistent-tcoder-sweep "$1" 2>&1' _ "$d")
  case "$hygiene" in
    *"unbound variable"*)
      fail "回收这一维在裸 set -u 消费者下有未初始化量 ⇒ 收尾会中止、读数会丢：$hygiene"
      rc=1 ;;
  esac
  if ! printf '%s\n' "$hygiene" | grep -qF '2 个 bundle 可回收'; then
    fail "收尾出口没把回收这一维印出来 ⇒ 尺子住在 scripts 里却没人每轮读它"
    rc=1
  fi
  # ---- 空扫描不许冒充"查过、干净"：一趟都没认出来时必须明写没有分母
  mkdir -p "$out/reclaim-empty"
  python3 scripts/perf_reclaim.py "$out/reclaim-empty" > "$out/reclaim-empty.txt" 2>&1 \
    || { fail "空样本根就非零退出 ⇒ 新克隆的树会把收尾打断"; rc=1; }
  if ! grep -qF '没有分母' "$out/reclaim-empty.txt"; then
    fail "样本根里一个 trace 都没认出来，却没说「没有分母」 ⇒ 现读 $(tr '\n' '|' < "$out/reclaim-empty.txt")"
    rc=1
  fi
  if grep -qF '可回收' "$out/reclaim-empty.txt"; then
    fail "没有分母却仍然印了可回收计数 ⇒ 空扫描会被读成「查过了，干净」（计数读 0 就通过那一族）"
    rc=1
  fi
  # ---- 显式授权才删，而且只删 *.trace。删之前先把一个句柄**开在 bundle 里面**
  #      （用宿主自己的 fd 9，不另起进程 ⇒ 不会有漏下来的实例要退），
  #      那就是"录到一半"的形状：回收器必须看得见开在目录里面的文件，
  #      只看 `lsof -- <目录>` 的话它是 0 行 —— 那等于没有守卫。
  exec 9< "$d/archive-fake/tcoder-perf-fix-idle-run6/hitches.trace/data.bin"
  if ! TCODER_RECLAIM=1 python3 scripts/perf_reclaim.py "$d" > "$out/reclaim-delete.txt" 2>&1; then
    fail "TCODER_RECLAIM=1 那一趟非零退出"
    rc=1
  fi
  exec 9<&-
  if ! grep -qF '跳过（仍被进程打开）' "$out/reclaim-delete.txt"; then
    fail "开着句柄的那一趟没有被认成「在用」⇒ 打印的跳过行没出现（现读 $(tr '\n' '|' < "$out/reclaim-delete.txt")）"
    rc=1
  fi
  if [ ! -d "$d/archive-fake/tcoder-perf-fix-idle-run6/hitches.trace" ]; then
    fail "有一个句柄开在 bundle 里面却被连目录删了 ⇒ 守卫只认「目录本身被打开」，那正是录制中的形状"
    rc=1
  fi
  if [ -d "$d/tcoder-perf-fix-idle-run5/hitches.trace" ]; then
    fail "给了 TCODER_RECLAIM=1 却没删 ⇒ 那个开关是装饰品"
    rc=1
  fi
  if [ ! -f "$d/tcoder-perf-fix-idle-run5/REFUSED" ] || [ ! -f "$d/tcoder-perf-fix-idle-run5/meta.json" ]; then
    fail "删 trace 时把判定/上下文一起带走了 ⇒ 台账会读成「这趟不存在」而不是「这趟判废」"
    rc=1
  fi
  if [ ! -d "$d/tcoder-perf-fix-interact-run4/hitches.trace" ] \
     || [ ! -d "$d/tcoder-perf-fix-switch-run1/hitches.trace" ]; then
    fail "不该点名的那两趟被删了 ⇒ 回收动作超出了判定点名的范围"
    rc=1
  fi
  [ "$rc" = "0" ] && ok "判废趟的原始 trace 回收四面有牙：被拒∧超线才点名（两层都认得）、默认只印、显式授权才删且只动 *.trace、空扫描明写没有分母"
}

selfcheck_artifact_locator_fork_honest() {  # 68) 同名产物分在三处时要按形状说对话，不许替人挑一份（#89）
  # 09-25 22:27 现场：搬家把 `blame1-idle-run2` 拆成「原地有导表、rescue 有原始 trace」两份，
  # 而 reclaim/一致性尺/report 都只按自己那棵树的 .scratch 找 ⇒ 清树可能删掉唯一的那一半。
  # **分叉有两种，话术必须分开**，这一条是上一版本自己被实跑抓到的：
  # `cert7b-idle-run1` 两处导表**都齐全**、只差原始 trace（一份包住另一份），
  # 上一版却照印「两份内容不重叠」⇒ 那句会把人推向"删哪份都疼"的错结论。
  # 于是五格：只在原地（0）、**互补**分叉（2 且说「都不能单独删」）、
  # **包含**分叉（2 且说「名单更全」、且**不许**说「都不能单独删」）、同一根传两遍（0）、
  # 批名不存在（1，且必须明说"一处都没找到"而不是静默）。
  local fx a b c r1 r2 r3 r4 r5 out
  fx=$(mktemp -d 2>/dev/null || echo /tmp/locator-fx)
  a="$fx/rootA"; b="$fx/rootB"; c="$fx/rootC"
  mkdir -p "$a/tcoder-perf-fake-run1" "$b/tcoder-perf-fake-run1/fake.trace" \
           "$c/tcoder-perf-fake-run1/big.trace"
  : > "$a/tcoder-perf-fake-run1/meta.json"      # 只有导表
  : > "$c/tcoder-perf-fake-run1/meta.json"      # 导表 + 原始 trace ⇒ 名单包住 a
  python3 scripts/perf_artifact_locator.py tcoder-perf-fake-run1 --root "$a" >"$fx/solo.txt" 2>&1; r1=$?
  python3 scripts/perf_artifact_locator.py tcoder-perf-fake-run1 --root "$a" --root "$b" >"$fx/fork.txt" 2>&1; r2=$?
  python3 scripts/perf_artifact_locator.py tcoder-perf-fake-run1 --root "$a" --root "$c" >"$fx/cover.txt" 2>&1; r5=$?
  python3 scripts/perf_artifact_locator.py tcoder-perf-fake-run1 --root "$a" --root "$a" >"$fx/same.txt" 2>&1; r3=$?
  python3 scripts/perf_artifact_locator.py tcoder-perf-nope-run9 --root "$a" >"$fx/none.txt" 2>&1; r4=$?
  out="ok"
  [ "$r1" = "0" ] || out="$out 只在原地=$r1（要 0）"
  [ "$r2" = "2" ] || out="$out 互补分叉=$r2（要 2）"
  [ "$r5" = "2" ] || out="$out 包含分叉=$r5（要 2：inode 不同就是分叉，不许因为一份更全就放行）"
  [ "$r3" = "0" ] || out="$out 同一根两遍=$r3（要 0，不许误报分叉）"
  [ "$r4" = "1" ] || out="$out 名字不存在=$r4（要 1）"
  grep -q "都不能单独删" "$fx/fork.txt" || out="$out 互补那格没说出「各握有对方没有的东西」这件最要紧的事"
  grep -q "名单更全" "$fx/cover.txt" || out="$out 包含那格没认出「一份的名单被另一份包住」"
  # 反向格：写成 if 而不是 `grep … && out=…`，让「不许误报成互补」这条不依赖 set -e 的边角语义
  if grep -q "都不能单独删" "$fx/cover.txt"; then
    out="$out 包含那格被印成了互补（22:44 实跑 cert7b 就是这个错话）"
  fi
  grep -q "一处都没找到" "$fx/none.txt" || out="$out 没找到时没明说（静默零命中＝假绿）"
  rm -rf "$fx"
  [ "$out" = "ok" ] || { fail "产物定位尺不成立：$out"; return; }
  ok "产物定位尺五格有牙：一处⇒定权威、互补⇒「都不能单独删」、包含⇒只说「名单更全」（且不误报成互补）、" \
     "同一根两遍不误报、查无此名要明说"
}

selfcheck_artifact_locator_names_the_tree_copy() {  # 69) 分叉时必须点名「本树那一份是尺子唯一认得的」（#89）
  # 这一条单独一项：它是清树现场**最容易被忽略**的那一半——`report`／一致性尺只按自己那棵树的
  # `.scratch` 找产物，所以"别处还有更全的一份"**不构成**删本树这份的理由。
  # 夹具**不落在真仓库树里**（那里正在跑批次，写进去既脏又会被回收器当成产物）：
  # 改成拿 cwd 造一棵合成树——定位尺认「本树」只认 `cwd/.scratch` 与 `父目录/.scratch` 两个前缀。
  # 反向格：两处都在本树之外（同一棵合成树的**兄弟目录**）⇒ 不许冒出这句。
  local fx loc r1 r2 out
  fx=$(mktemp -d 2>/dev/null || echo /tmp/locator-tree-fx)
  loc="$PWD/scripts/perf_artifact_locator.py"
  mkdir -p "$fx/tree/.scratch/tcoder-perf-fake-run1" "$fx/else/.scratch/tcoder-perf-fake-run1/q.trace"
  : > "$fx/tree/.scratch/tcoder-perf-fake-run1/meta.json"
  out="ok"
  ( cd "$fx/tree" && python3 "$loc" tcoder-perf-fake-run1 \
      --root "$fx/tree/.scratch" --root "$fx/else/.scratch" ) >"$fx/in.txt" 2>&1; r1=$?
  ( cd "$fx" && python3 "$loc" tcoder-perf-fake-run1 \
      --root "$fx/tree/.scratch" --root "$fx/else/.scratch" ) >"$fx/out.txt" 2>&1; r2=$?
  [ "$r1" = "2" ] || out="$out 本树分叉=$r1（要 2）"
  [ "$r2" = "2" ] || out="$out 非本树分叉=$r2（要 2：认不认得本树不该改判定）"
  grep -q "唯一认得" "$fx/in.txt" || out="$out 分叉里没点名本树那一份（清树最容易只删它）"
  if grep -q "唯一认得" "$fx/out.txt"; then
    out="$out 站错了目录还硬说「唯一认得」⇒ 这句只在命中真在本树下面时才许出现"
  fi
  rm -rf "$fx"
  [ "$out" = "ok" ] || { fail "本树那一份的点名不成立：$out"; return; }
  ok "分叉必点本树那一份（它是 report／一致性尺唯一认得的），且换一棵合成树站错目录时不冒这句"
}

selfcheck_locator_census_counts_only_batches() {  # 70) 「数了几批」由尺答：夹具树里的合成 -runN 不进分母（#90）
  # 23:07 实跑抓到的：普查档第一版按"深度 ≤2 全走"数批次，把 `selfcheck-<rev>/reclaim/tcoder-perf-fix-idle-run1`
  # 这类**合成夹具**数了进去 ⇒ 554 个"批次"而真批次只有 222 个。形状完全一样，只有
  # 「住在夹具树里」能分开 ⇒ 这条口径必须钉住，且**逐名模式与普查档共用同一份枚举**（两处入口两个数=老账）。
  local fx a b r1 r2 out
  fx=$(mktemp -d 2>/dev/null || echo /tmp/locator-census-fx)
  a="$fx/rootA"; b="$fx/rootB"
  mkdir -p "$a/tcoder-perf-real-idle-run1" "$b/tcoder-perf-real-idle-run1" \
           "$a/container/tcoder-perf-moved-idle-run2" \
           "$a/tcoder-perf-selfcheck-abc/reclaim/tcoder-perf-fake-idle-run1"
  python3 scripts/perf_artifact_locator.py --census --root "$a" --root "$b" >"$fx/census.txt" 2>&1; r1=$?
  python3 scripts/perf_artifact_locator.py tcoder-perf-fake-idle-run1 --root "$a" >"$fx/fake.txt" 2>&1; r2=$?
  out="ok"
  [ "$r1" = "0" ] || out="$out 普查=$r1（要 0）"
  [ "$r2" = "1" ] || out="$out 逐名查夹具批名=$r2（要 1：它不算批次，不能被当成'一处/分叉'）"
  grep -qF "批次目录 2 个（批名 2 个）" "$fx/census.txt" \
    || out="$out A 根没数成 2（真批次 1 ＋ 容器里第二层 1，夹具树里那 1 个不算）：$(grep -F "$a " "$fx/census.txt" | head -1)"
  grep -qF "不是批次形状的 1 类" "$fx/census.txt" || out="$out 没把 selfcheck 目录单列成'非批次形状'"
  grep -qF "只在一处 1 个／两处以上 1 个" "$fx/census.txt" || out="$out 跨根分组不对（moved 只在一处、real 在两处）"
  grep -qF "tcoder-perf-moved-idle-run2" "$fx/census.txt" || out="$out 唯一份清单没点名容器里那一层 ⇒ rescue/archive 形状会被漏掉"
  python3 scripts/perf_artifact_locator.py --census --root "$fx/empty-root" >"$fx/none.txt" 2>&1
  [ "$?" = "1" ] || out="$out 空根也放行（分母为 0 必须是发现，不是通过）"
  grep -qF "一个批次目录都没数到" "$fx/none.txt" || out="$out 空根没明说"
  rm -rf "$fx"
  [ "$out" = "ok" ] || { fail "普查档的分母口径不成立：$out"; return; }
  ok "普查档三面有牙：夹具树里的合成 -runN 不进批次分母（逐名模式同样查不到它）、容器第二层算数并点名唯一份、空根要判错"
}
