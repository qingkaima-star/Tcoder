#!/bin/bash
# =============================================================================
# perf_measure_rev.sh —— 让"改动前那份内容"**还能被重测**（工单包 5）
#
# 为什么需要它：§Q 那 14 处还掉之后，交付要说的是"从 X 降到 Y"。
# 而现在的尺子只能量"我这棵树当前内容"——`perf_provenance.sh` 比的是产物 vs HEAD。
# 于是"改动前的 X"要么是旧日志里抄来的数（**不受控**，spec §1.3 明令不许当 X），
# 要么根本没法补测。这一支脚本把"另一个 rev 的产物"变成一条命令就能备好的东西：
#
#     eval "$(scripts/perf_measure_rev.sh env d73bea4)"   # 备好产物 + 设好 PERF_BIN / MEASURE_REV
#     MODE=idle ./scripts/perf_wait_window.sh d73bea4 3 900
#     scripts/perf_measure_rev.sh clean d73bea4           # 量完收回（不留第二份树占盘）
#
# 三条边界：
# 1) **不 checkout**：这棵树正被测量链与别家用着，切头等于把别人的窗口砸了。
#    所以走 `git worktree add --detach`，落在**仓库内被 git 忽略**的 `.scratch/rev-trees/`
#    （落盘纪律第 1 条：产物不进 `$TMPDIR`）。
# 2) 建产物会占构建锁约一分钟，而且**编译负载本身会让闸门拒录** ⇒
#    只在两档之间跑，或者干脆等场上没测量在跑；别边量边建。
# 3) 它只改"归属比的是谁"（`MEASURE_REV`），**不放宽任何判定**：
#    产物 rev 与 `MEASURE_REV` 对不上、或产物码 tree 对不上，一样拒。
#    （`MEASURE_REV` 的语义钉在 selfcheck 第 38 项：写错 rev ⇒ 取不到 ⇒ 判败，不是跳过。）
# =============================================================================
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel 2>/dev/null) \
  || { printf '!! 认不出仓库根（%s）\n' "$HERE" >&2; exit 2; }
PKG="$ROOT/TcoderMonitor"
SCRATCH="$ROOT/.scratch/rev-trees"
FREE_MIN_GIB=20

die() { printf '!! %s\n' "$*" >&2; exit 1; }
say() { printf '%s\n' "$*"; }

# 【`die` 在 `$( … )` 里是**杀不死父进程**的】第一版就是这么写的，实测：
#   rev 取不到 ⇒ 报错照印，可 `cmd_env` 继续往下跑，最后**印出一行空值 env 并以 rc=0 收工**
#   （`.scratch/rev-trees//TcoderMonitor/…` 这种路径看着就像真有一个树）。
# 所以这里只 `return 1`，由**调用方**决定退不退 —— 与第 10/23 条同族：先确认死的是谁。
resolve() {  # resolve <rev> ⇒ 完整 commit sha 到 stdout；取不到 ⇒ 出声并回 1
  local sha
  sha=$(git -C "$ROOT" rev-parse --verify --quiet "$1^{commit}") || sha=''
  if [ -z "$sha" ]; then
    printf '!! rev「%s」在这个仓库里取不到 commit ⇒ 不往下走（空串会拼出一个"看起来存在"的产物路径）\n' "$1" >&2
    return 1
  fi
  printf '%s' "$sha"
}

tree_dir() { printf '%s' "$SCRATCH/${1:0:7}"; }

guard_disk() {
  local free
  free=$(df -k /System/Volumes/Data | awk 'NR==2{print int($4/1024/1024)}')
  [ "${free:-0}" -ge "$FREE_MIN_GIB" ] \
    || die "磁盘可用 ${free:-取不到} GiB < ${FREE_MIN_GIB} GiB ⇒ 不建第二份产物（判据同闸门第 4 条）"
  say "磁盘可用 ${free} GiB（≥${FREE_MIN_GIB}）"
}

cmd_prepare() {  # cmd_prepare <rev>
  local sha dir
  [ $# -ge 1 ] || die "用法: $0 prepare <rev>"
  sha=$(resolve "$1") || exit 1
  dir=$(tree_dir "$sha")
  if [ -x "$dir/TcoderMonitor/dist/Tcoder.app/Contents/MacOS/TcoderMonitor" ]; then
    say "已有该 rev 的产物，直接用：$dir"
    return 0
  fi
  guard_disk
  mkdir -p "$SCRATCH" || die "造不出 $SCRATCH"
  if [ ! -d "$dir" ]; then
    say "git worktree add --detach $dir ${sha:0:7}"
    git -C "$ROOT" worktree add --detach "$dir" "$sha" >/dev/null 2>&1 \
      || die "建工作树失败（$dir）—— 手工看 `git worktree list`，别在残局上重试"
  fi
  say "在该树里打 release 产物（占构建锁约 1 分钟；期间别开测量）"
  ( cd "$dir/TcoderMonitor" && ./scripts/build_app.sh release ) || die "build_app.sh release 失败"
  [ -x "$dir/TcoderMonitor/dist/Tcoder.app/Contents/MacOS/TcoderMonitor" ] \
    || die "打完产物却找不到二进制 —— 布局变了，这条不许当成'成功'"
  say "备好：${sha:0:7} → $dir"
}

cmd_env() {  # cmd_env <rev> ⇒ 给 shell eval 的一行（路径都取绝对，省得依赖 cwd）
  local sha dir
  [ $# -ge 1 ] || die "用法: $0 env <rev>"
  sha=$(resolve "$1") || exit 1
  dir=$(tree_dir "$sha")
  printf 'export PERF_BIN=%q MEASURE_REV=%q\n' \
         "$dir/TcoderMonitor/dist/Tcoder.app/Contents/MacOS/TcoderMonitor" "$sha"
}

cmd_clean() {  # cmd_clean <rev> ⇒ 收回那棵树。**不用 --force**：脏了就交给人看
  local sha dir
  [ $# -ge 1 ] || die "用法: $0 clean <rev>"
  sha=$(resolve "$1") || exit 1
  dir=$(tree_dir "$sha")
  [ -d "$dir" ] || { say "没有 $dir 可收（本来就没建）"; return 0; }
  git -C "$ROOT" worktree remove "$dir" 2>/dev/null \
    || die "git 不肯收 $dir（里面有未提交改动）—— 先自己看一眼，别加 --force"
  say "已收回 $dir"
}

cmd_list() {
  say "当前挂着的 rev 树（$SCRATCH）："
  git -C "$ROOT" worktree list | grep "$SCRATCH" || say "  （无）"
}

case "${1:-}" in
  prepare) shift; cmd_prepare "$@" ;;
  env)     shift; cmd_env "$@" ;;
  clean)   shift; cmd_clean "$@" ;;
  list)    cmd_list ;;
  *)       printf '用法: %s prepare|env|clean <rev> | list\n' "$0"; exit 2 ;;
esac
