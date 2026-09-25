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
    "$MY_ROOT"/*) printf 'mine' ;;
    # 顺序有意：工作树的路径也长在仓库根下面，`*/.worktrees/*` 必须排在主树那条之前，
    # 否则每棵工作树都会被读成"主树的实例"（第一版就是这么错的）。
    */.worktrees/*) t=$(printf '%s' "$p" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')
                    if [ -n "$t" ] && [ -d "$t" ]; then printf 'worktree'
                    else printf 'orphan'; fi ;;
    "$REPO_ROOT"/*) printf 'main' ;;
    *) printf 'outside' ;;
  esac
}

owner_of() {  # owner_of <可执行路径> —— 只把 `kind_of` 的判定翻成一句人话，自己不再判
  local p="$1" t
  case "$(kind_of "$p")" in
    unknown)  printf '读不到路径 ⇒ 不知道是谁的（**不许当成"已删除"，也不许当成"可以动"**）' ;;
    revtree)  t=$(printf '%s' "$p" | sed -n 's|\(.*\.scratch/rev-trees/[^/]*\)/.*|\1|p')
              if [ -n "$t" ] && [ -d "$t" ]; then
                printf '补测产物树 %s —— 不是这一批起的：不代收、不代 kill，找起它的那一批或需求方' "$t"
              else
                printf '补测产物树 %s 已删除（进程还活着）⇒ 由需求方或那一批的主人关它' "${t:-?}"
              fi ;;
    mine)     printf '我自己（本树 %s）' "$MY_ROOT" ;;
    worktree) printf '别人的工作树 %s' \
                "$(printf '%s' "$p" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')" ;;
    orphan)   t=$(printf '%s' "$p" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')
              printf '孤儿：工作树 %s 已删除（进程还活着）' "${t:-?}" ;;
    main)     printf '主树的实例 %s —— 有人在主树上开工' "$REPO_ROOT" ;;
    *)        printf '仓库外（%s）' "$p" ;;
  esac
}

# 自测：这条分类**判错过一次**（把"读不到路径"报成"工作树已删除"= 诬告树被删，
# 而下一个人会照着这句话去 kill），所以每种形状各钉一次，含反向。
# ⚠ 这个 `--probe` 以前**没有读者**（只有人会去跑它），第 66 项就是给它补的那个读者。
if [ "${1:-}" = "--probe" ]; then
  bad=0
  check() {  # check <期望含> <实际> <形状名>
    case "$2" in *"$1"*) : ;; *) echo "  ✗ $3 分类不对：拿到「$2」"; bad=$((bad + 1)) ;; esac
  }
  check "读不到路径" "$(owner_of '?')" "读不到（必须说'不知道'，不许猜成已删除）"
  check "我自己" "$(owner_of "$MY_ROOT/x/y")" "本树"
  check "主树的实例" "$(owner_of "/Users/one/Documents/Tcoder/TcoderMonitor/dist/a")" "主树"
  check "已删除" "$(owner_of "/Users/one/Documents/Tcoder/.worktrees/no-such-tree-xyz/dist/a")" "孤儿"
  check "别人的工作树" "$(owner_of "$REPO_ROOT/.worktrees/chief/dist/a")" "在途工作树（树还在）"
  # 补测产物树这一态有**两格**，而且"树在不在"必须是现造的目录，不能拿真历史里的路径当夹具
  # （那会随 checkout 变色：今天 5a5d55c 还在，明天回收器一跑就没了，于是这条断言今天对明天错）。
  fx=$(mktemp -d 2>/dev/null || echo /tmp/slot-fx)
  mkdir -p "$fx/.scratch/rev-trees/deadbeef" "$fx/.scratch/rev-trees/gonecafe" 2>/dev/null
  rmdir "$fx/.scratch/rev-trees/gonecafe" 2>/dev/null
  check "不是这一批起的" "$(owner_of "$fx/.scratch/rev-trees/deadbeef/TcoderMonitor/dist/a")" \
    "补测产物树·树还在（要给判后动作：不代收、不代 kill）"
  check "已删除（进程还活着）" "$(owner_of "$fx/.scratch/rev-trees/gonecafe/TcoderMonitor/dist/a")" \
    "补测产物树·树已删（不许被读成「可以动」，也不许冒充普通工作树的孤儿）"
  rm -rf "$fx" 2>/dev/null
  # 反向那一格不许被新形状吃掉：主树自己的 dist 仍然必须判成"主树的实例"。
  [ "$(kind_of "$REPO_ROOT/TcoderMonitor/dist/a")" = "main" ] \
    || { echo "  ✗ 反向失守：主树 dist 被新判据改判成 $(kind_of "$REPO_ROOT/TcoderMonitor/dist/a")"; bad=$((bad + 1)); }
  [ "$bad" = "0" ] \
    && echo "  ✓ 归属各判对一次（含补测产物树的「树还在／已删除」两态，与「读不到」「已删除」不许互相冒充、主树 dist 不被新形状吃掉）" \
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
    printf '{"pid":"%s","uptime":"%s","bin":"%s","owner":"%s"}' "$pid" "$up" "$path" "$(owner_of "$path")"
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
  own=$(owner_of "$path")
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
