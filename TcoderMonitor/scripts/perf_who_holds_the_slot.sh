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
owner_of() {
  case "$1" in
    '?') printf '读不到路径 ⇒ 不知道是谁的（**不许当成"已删除"，也不许当成"可以动"**）' ;;
    "$MY_ROOT"/*) printf '我自己（本树 %s）' "$MY_ROOT" ;;
    # 顺序有意：工作树的路径也长在仓库根下面，`*/.worktrees/*` 必须排在主树那条之前，
    # 否则每棵工作树都会被读成"主树的实例"（第一版就是这么错的）。
    */.worktrees/*) local t; t=$(printf '%s' "$1" | sed -n 's|\(.*\.worktrees/[^/]*\)/.*|\1|p')
                    if [ -n "$t" ] && [ -d "$t" ]; then printf '别人的工作树 %s' "$t"
                    else printf '孤儿：工作树 %s 已删除（进程还活着）' "${t:-?}"; fi ;;
    "$REPO_ROOT"/*) printf '主树的实例 %s —— 有人在主树上开工' "$REPO_ROOT" ;;
    *) printf '仓库外（%s）' "$1" ;;
  esac
}

# 自测：这条分类**判错过一次**（把"读不到路径"报成"工作树已删除"= 诬告树被删，
# 而下一个人会照着这句话去 kill），所以四种形状各钉一次，含两个反向。
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
  [ "$bad" = "0" ] && echo "  ✓ 五种归属各判对一次（含「读不到」与「已删除」不许互相冒充）" || exit 1
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
  case "$path" in "$MY_ROOT"/*) mine=$((mine + 1)); tag='← 我的' ;; *) tag='' ;; esac
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
