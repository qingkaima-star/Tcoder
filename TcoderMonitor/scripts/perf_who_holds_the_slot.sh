#!/bin/bash
# perf_who_holds_the_slot.sh —— 只读回答一句话：**现在谁占着测量窗口**。
#
# 为什么要有它（2026-09-22 实测）：整夜 T2/T1 采不满，闸门反复报
# "唯一那个实例不是本树起的（attach 它会量到别人的构建）"——**这句话是对的，但不可行动**。
# 人要知道的是：那个实例是谁的、从那棵树上开的、那棵树还在不在、跑了多久、
# 我有没有资格动它。今天最后卡住我的就是一个 **工作树已被删、进程还活着 10.5 小时**的孤儿，
# 而"在场即拒"的闸门会被这种停着的孤儿一路押死（同一形状今天已经踩过一次：21h 的孤儿 xctrace）。
#
# 红线：这个脚本**只读**。不 kill、不发信号、不 `osascript quit`、不按 bundle id 广播。
# 它只把"该找谁、跑哪条命令"打出来，动作交给人（或树的主人）做。
#
# 用法：./scripts/perf_who_holds_the_slot.sh        # 加 --json 便于别的脚本吃
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

MY_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "?")
AS_JSON=0
[ "${1:-}" = "--json" ] && AS_JSON=1

# 每个实例：pid / 已跑多久 / 可执行文件全路径
# 全路径要自己拼准：`ps -o comm=` 给的是**当初怎么起的**（可能是相对路径，
# 例如从别人的工作树里 `open dist/Tcoder.app` 只剩 `dist/Tcoder.app/…`），
# 相对路径必须用该进程的 cwd 补成绝对路径，否则下面会把"读不到"误判成"树被删了"。
instance_rows() {
  local pid path cwd
  for pid in $(pgrep -x TcoderMonitor 2>/dev/null); do
    path=$(lsof -a -p "$pid" -d txt -Fn 2>/dev/null | sed -n 's|^n||p' | grep 'TcoderMonitor$' | head -1)
    case "$path" in
      /*) : ;;
      ?*) cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's|^n||p' | head -1)
          path="${cwd%/}/${path}" ;;
      *)  path='?' ;;          # 两条都读不到：如实标"不知道"，**绝不猜**
    esac
    printf '%s\t%s\t%s\n' "$pid" "$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')" "$path"
  done
}

# 归属：我自己 / 主树（别人在主树上开工）/ 某棵工作树（还在不在）/ 读不到。
# 主树也算"别人"——它随时带着在途改动，attach 上去一样是把别人的构建当我的读数。
# 主树路径只能问 `git worktree list` 的第一条：在 linked worktree 里
# `--git-common-dir` 给的是主树的 .git 目录，再拿它去 --show-toplevel 会算错（实测错过一次）。
REPO_ROOT=$(git worktree list --porcelain 2>/dev/null | sed -n '1s|^worktree ||p')

# 【唯一一处按路径判归属】下面两件事都从这里取，不许各写一遍 `case`：
#   · `owner_of` 印的那句话；
#   · 结尾那列「← 我的」标记。
# 第一版这两处是**两条独立的前缀匹配**，于是"印的是 A、比的是 B"——本仓为这类错记过
# "印与比共用同一个变量是判据的一部分"。
kind_of() {  # kind_of <可执行路径> → unknown | revtree | mine | worktree | orphan | main | outside
  local p="$1" t
  case "$p" in
    '?') printf 'unknown' ;;
    # 【形状缺口，09-25 09:25 现场抓到】补测产物树（包 5 `perf_measure_rev.sh` 造的
    # `.scratch/rev-trees/<rev>/…`）长在仓库根**下面**，所以它会被 `"$MY_ROOT"/*` 先吃进去，
    # 印成「我自己（本树 …）」并打上「← 我的」——而收尾的 trap 按**全路径** `pgrep -fx` 认，
    # 根本不收它。这一句必须排在"本树/主树"之前，否则每一批补测产物都会被读成"我这一批起的"。
    */.scratch/rev-trees/*) printf 'revtree' ;;
    # 【第二格同一个错，09-25 11:44 现场抓到】"工作树"这一维必须排在**本树**之前，不只是排在主树之前：
    # 站在主树问的时候 `MY_ROOT == REPO_ROOT`，而 `.worktrees/` 就长在主树下面，
    # 于是别人工作树里的实例（实测 pid=23242，住在 `.worktrees/perf-base/…`）
    # 被 `"$MY_ROOT"/*` 先吃成「我自己（本树 /Users/one/Documents/Tcoder） ← 我的」——
    # 下一句话就是"那我可以 kill 它"，而它不是我的。自己的 `--probe` 抓不到，
    # 因为夹具里 `MY_ROOT=$fx/treeA` 不是 `REPO_ROOT` 的父目录：**夹具比现场少一种形状**。
    */.worktrees/*) t=$(printf '%s' "$p" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')
                    # 只认"那一棵就是我站着的那一棵"。这里**不能再加一条前缀匹配**：
                    # 站在主树时 `MY_ROOT == REPO_ROOT` 是所有工作树的父目录，
                    # 前缀一比就把别人那棵判回「我自己」——本格修的正是这个（探针第三格反向钉着）。
                    if [ -z "$t" ] || [ ! -d "$t" ]; then printf 'orphan'
                    elif [ "$t" = "$MY_ROOT" ]; then printf 'mine'
                    else printf 'worktree'; fi ;;
    "$MY_ROOT"/*) printf 'mine' ;;
    "$REPO_ROOT"/*) printf 'main' ;;
    *) printf 'outside' ;;
  esac
}

# 是谁**起**的：只看落过盘的归属记录，按 pid + 全路径两格同时命中才算数
# （pid 会被回收再发，只比 pid 会把新进程认成旧批次）。记录由 `perf_run_batch.sh` 的
# `warm_and_hold` 写在各自树的 `.scratch/INSTANCE-OWNER`（三列制表符：pid、批名、二进制）。
# 读不到就如实说读不到——**不许**再写"找起它的那一批"：本仓从来没有"那一批"可查，
# 这句话把 4 小时 43 分的阻塞推给了空气（§145）。
owner_record_of() {  # owner_record_of <pid> <可执行路径> → 批名 | 空（读不到）
  local pid="$1" p="$2" f
  [ -n "$pid" ] && [ "$pid" != "?" ] || return 1
  for f in "${TCODER_OWNER_RECORD:-}" \
           "$REPO_ROOT/.scratch/INSTANCE-OWNER" \
           "$REPO_ROOT"/.worktrees/*/.scratch/INSTANCE-OWNER; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if awk -F'\t' -v pid="$pid" -v p="$p" '$1==pid && $3==p {print $2; found=1} END{exit !found}' "$f"; then
      return 0
    fi
  done
  return 1
}

owner_named() {  # owner_named <pid> <可执行路径> <没有记录时的人话> —— 有记录点名，没记录说"不知道"
  local pid="$1" p="$2" fallback="$3" rec
  if rec=$(owner_record_of "$pid" "$p"); then
    printf '是批次「%s」起的（盘上有归属记录）' "$rec"
  else
    printf '%s' "$fallback"
  fi
}

owner_of() {  # owner_of <可执行路径> [pid] —— 只把 `kind_of` 的判定翻成一句人话，自己不再判归属
  local p="$1" pid="${2:-?}" t
  case "$(kind_of "$p")" in
    unknown)  printf '读不到路径 ⇒ 不知道是谁的（**不许当成"已删除"，也不许当成"可以动"**）' ;;
    revtree)  t=$(printf '%s' "$p" | sed -n 's|\(.*\.scratch/rev-trees/[^/]*\)/.*|\1|p')
              if [ -n "$t" ] && [ -d "$t" ]; then
                printf '补测产物树 %s —— 不是这一批起的：%s' "$t" \
                  "$(owner_named "$pid" "$p" '盘上没有归属记录 ⇒ 说不出是谁起的，不猜')"
              else
                printf '补测产物树 %s 已删除（进程还活着）⇒ 由需求方或那一批的主人关它' "${t:-?}"
              fi ;;
    mine)     printf '我自己（本树 %s）' "$MY_ROOT" ;;
    worktree) printf '别人的工作树 %s —— %s' \
                "$(printf '%s' "$p" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')" \
                "$(owner_named "$pid" "$p" '盘上没有归属记录 ⇒ 说不出是哪一批起的，不猜')" ;;
    orphan)   t=$(printf '%s' "$p" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')
              printf '孤儿：工作树 %s 已删除（进程还活着）' "${t:-?}" ;;
    main)     printf '主树的实例 %s —— 有人在主树上开工；%s' "$REPO_ROOT" \
                "$(owner_named "$pid" "$p" '说不出是谁起的（盘上没有归属记录）')" ;;
    *)        printf '仓库外（%s）' "$p" ;;
  esac
}

# 自测：这条分类**判错过一次**（把"读不到路径"报成"工作树已删除"= 诬告树被删，
# 而下一个人会照着这句话去 kill），所以每种形状各钉一次，含反向。
# ⚠ 这个 `--probe` 以前**没有读者**（只有人会去跑它），第 66 项就是给它补的那个读者。
# ⚠ 探针必须**与跑它的那棵树无关**：所有格子只用合成根。
#    第一版里有三格写死了真实绝对路径（`/Users/one/Documents/Tcoder/…`），
#    于是"主树的实例""孤儿""在途工作树"三格在**主树里跑**会全部判成「我自己」
#    ——因为 `kind_of` 的第一条命中就是 `"$MY_ROOT"/*`，而在主树里 MY_ROOT 正是那个前缀。
#    09-25 10:02 现场抓到（`--probe` rc=1，四格红）。补了读者之后，这种"随 checkout 变色"
#    不再只是探针自己红，而是**别人家的门禁红**——所以这一版把根换成合成的。
if [ "${1:-}" = "--probe" ]; then
  bad=0
  check() {  # check <期望含> <实际> <形状名>
    case "$2" in *"$1"*) : ;; *) echo "  ✗ $3 分类不对：拿到「$2」"; bad=$((bad + 1)) ;; esac
  }
  fx=$(mktemp -d 2>/dev/null || echo /tmp/slot-fx)
  mkdir -p "$fx/treeA" "$fx/repo/.worktrees/chief" \
           "$fx/repo/.scratch/rev-trees/deadbeef" 2>/dev/null
  # 换根：后面所有格子只在 `$fx` 下面构造路径，真实仓库路径一概不用。
  MY_ROOT="$fx/treeA"
  REPO_ROOT="$fx/repo"
  check "读不到路径" "$(owner_of '?')" "读不到（必须说「不知道」，不许猜成已删除）"
  check "我自己" "$(owner_of "$MY_ROOT/x/y")" "本树"
  check "主树的实例" "$(owner_of "$REPO_ROOT/TcoderMonitor/dist/a")" "主树"
  check "别人的工作树" "$(owner_of "$REPO_ROOT/.worktrees/chief/dist/a")" "在途工作树（树还在）"
  check "已删除" "$(owner_of "$REPO_ROOT/.worktrees/no-such-tree-xyz/dist/a")" "工作树孤儿"
  # 补测产物树两格：目录**必须现造**，"树在不在"才是被真的判过一次，
  # 而不是拿真历史里的某枚 rev 目录赌它还活着（那会随回收器一变而今天对、明天错）。
  check "不是这一批起的" "$(owner_of "$REPO_ROOT/.scratch/rev-trees/deadbeef/TcoderMonitor/dist/a")" \
    "补测产物树·树还在（要给判后动作：不代收、不代 kill）"
  check "已删除（进程还活着）" "$(owner_of "$REPO_ROOT/.scratch/rev-trees/gonecafe/TcoderMonitor/dist/a")" \
    "补测产物树·树已删（不许被读成「可以动」，也不许冒充普通工作树的孤儿）"
  # 反向之一（两枚根**还分开**的时候）：新形状不许吃掉普通工作树的判定。
  [ "$(kind_of "$REPO_ROOT/.worktrees/chief/dist/a")" = "worktree" ] \
    || { echo "  ✗ 反向失守：在途工作树被改判成 $(kind_of "$REPO_ROOT/.worktrees/chief/dist/a")"; bad=$((bad + 1)); }
  # 反向之二：主树自己跑的时候（MY_ROOT == REPO_ROOT）本树的产物**必须**判成"我自己"，
  # 不能被"主树的实例"那一格抢走——这正是第一版在主树里把三格读成"我自己"的**同一处优先级**，
  # 只不过那一版把它用在了错误的方向上。（顺序有意义：这一格必须在换根之后。）
  MY_ROOT="$REPO_ROOT"
  check "我自己" "$(owner_of "$REPO_ROOT/TcoderMonitor/dist/a")" "主树里跑：本树产物仍算我自己"
  # 反向之三（09-25 11:44 现场抓到那一格）：**站在主树**看别人工作树里的实例，
  # 必须判成「别人的工作树」，不许被 `"$MY_ROOT"/*` 吃成「我自己 ← 我的」——
  # 上面那格只测了"两枚根分开"的情形，而真实布局里主树正是所有工作树的父目录，
  # 所以这一形状从没被测过（夹具比现场少一种形状）。
  check "别人的工作树" "$(owner_of "$REPO_ROOT/.worktrees/chief/dist/a" 4242)" \
    "站在主树看别人的工作树（曾印成「我自己」，会怂恿人 kill 别人的实例）"
  # 归属记录两格（§145 的正面修法）：盘上有记录就**点名是哪一批**，
  # 没记录只许说"说不出"——旧话术「找起它的那一批」不可执行，盘上从来没有可找的东西。
  printf '4242\tsome-batch\t%s\n' "$REPO_ROOT/.worktrees/chief/dist/a" > "$fx/OWNER"
  TCODER_OWNER_RECORD="$fx/OWNER"
  check "some-batch" "$(owner_of "$REPO_ROOT/.worktrees/chief/dist/a" 4242)" "有归属记录 ⇒ 点名批次"
  TCODER_OWNER_RECORD=""
  norec=$(owner_of "$REPO_ROOT/.worktrees/chief/dist/a" 9999)
  case "$norec" in
    *"找起它的那一批"*) echo "  ✗ 没记录时又写出「找那一批」这句执行不了的话"; bad=$((bad + 1)) ;;
    *"说不出"*) : ;;
    *) echo "  ✗ 没记录时既没点名也没说「说不出」：拿到「$norec」"; bad=$((bad + 1)) ;;
  esac
  rm -rf "$fx" 2>/dev/null
  [ "$bad" = "0" ] \
    && echo "  ✓ 归属各判对一次（六态＋三格反向＋归属记录两格，全部只用合成根 ⇒ 换一棵树跑结果不变）" \
    || exit 1
  exit 0
fi

rows=$(instance_rows)
if [ "$AS_JSON" = "1" ]; then
  printf '['; first=1
  while IFS=$'\t' read -r pid up path; do
    [ -n "$pid" ] || continue
    [ "$first" = "1" ] || printf ','
    first=0
    printf '{"pid":"%s","uptime":"%s","bin":"%s","owner":"%s"}' "$pid" "$up" "$path" "$(owner_of "$path" "$pid")"
  done <<< "$rows"
  printf ']\n'; exit 0
fi

n=$(printf '%s\n' "$rows" | grep -c '^[0-9]' || true)
echo "==> 本机 TcoderMonitor 实例：$n 个（测量闸门要求恰好 1 个，且必须是本树起的）"
echo "    本树 = $MY_ROOT"
if [ "$n" = "0" ]; then
  echo "    现在没有实例 ⇒ 采样器会自己起一个（LAUNCH_APP=1），窗口不被别人占"
  exit 0
fi
mine=0
while IFS=$'\t' read -r pid up path; do
  [ -n "$pid" ] || continue
  own=$(owner_of "$path" "$pid")
  kind=$(kind_of "$path")
  # 「← 我的」这一列与下面那句"窗口干净"的计数**都从同一把判定里取**（以前这里另写了一遍
  # `"$MY_ROOT"/*` 前缀匹配，于是补测产物树既被印成「我自己」、又被计进 `$mine`——
  # 结果是"场上只有一个人的补测产物实例"会被判成**窗口干净**并催我直接开录，
  # 而 attach 的那枚二进制根本不是本树建的）。
  if [ "$kind" = "mine" ]; then tag='← 我的'; mine=$((mine + 1)); else tag=''; fi
  printf '    pid=%-7s 已跑 %-10s %s %s\n' "$pid" "$up" "$own" "$tag"
done <<< "$rows"

echo "==> 判后动作（只读脚本不代你做）："
if [ "$n" = "1" ] && [ "$mine" = "1" ]; then
  echo "    窗口是干净的：直接 ./scripts/perf_wait_window.sh \$(git rev-parse --short HEAD) 3"
else
  echo "    · 是**别人正在用的实例** ⇒ 去问那棵树的主人，或等它自己退；我不 kill 别人的进程（AGENTS -1.3）。"
  echo "    · 是**孤儿**（上面写着「工作树 … 已删除」）⇒ 由需求方或树的主人关它：kill -TERM <pid>（只这一个 pid，"
  echo "      绝不按 bundle id 广播）。关完再跑 wait_window，它每 5 秒重查一次条件。"
  echo "    · 想让测量不被人抢 ⇒ 需求方给一个独占窗口，比让闸门放宽有效：放宽出来的读数本来就不要。"
fi
