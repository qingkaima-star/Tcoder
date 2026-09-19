#!/bin/bash
# 合并前的强制体检：先把待合并的分支在**独立工作树**里编过、测过，再允许 merge。
# 用法: scripts/premerge_check.sh <分支名> [工作树路径]
#
# 为什么要有这把脚本：我犯过一次具体错误——看到某分支"领先 main 1 个提交"就直接 merge，
# 结果那是一个没写完的重构（164 个编译错，`static methods may only be declared on a type`、
# `extraneous '}' at top level`），把 main 弄坏了，只能 revert 补救。
# "分支有提交"不等于"分支能编译"。这条判断必须由脚本替我做，不能靠我记得。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1

BRANCH="${1:-}"
WT="${2:-}"
if [ -z "$BRANCH" ]; then
  echo "用法: $0 <分支名> [工作树路径]"; exit 2
fi

# 分支若已有工作树就用它（独立 .build，不抢主树锁）；没有就临时建一个。
CREATED=""
if [ -z "$WT" ]; then
  WT=$(git worktree list --porcelain | awk -v b="refs/heads/$BRANCH" '
        /^worktree /{w=$2} /^branch /{if($2==b) print w}')
fi
if [ -z "$WT" ]; then
  WT="/tmp/tcoder-premerge-$(basename "$BRANCH")"
  git worktree add "$WT" "$BRANCH" >/dev/null 2>&1 || { echo "!! 建不了工作树 $WT"; exit 1; }
  CREATED="$WT"
fi

cd "$WT/TcoderMonitor" || { echo "!! $WT 下没有 TcoderMonitor"; exit 1; }
echo "==> 体检分支 $BRANCH（工作树 $WT）"

fail=0
# 先只编测试目标：最便宜地暴露"没写完的重构"，不用等整轮 test。
if ! ./scripts/locked_build.sh build --build-tests > /tmp/premerge-build.log 2>&1; then
  echo "  ❌ 测试模块编译不过，禁止合并"
  grep -E "error:" /tmp/premerge-build.log | sed 's|.*/\(Tests\|Sources\)/|\1/|' | sort -u | head -10
  fail=1
fi

if [ "$fail" = "0" ]; then
  if ! ./scripts/locked_build.sh test > /tmp/premerge-test.log 2>&1; then
    echo "  ❌ 测试未通过，禁止合并"
    grep -E "Executed [0-9]+ tests" /tmp/premerge-test.log | tail -1
    grep -E "\.swift:[0-9]+: error:" /tmp/premerge-test.log | sed 's|.*/Tests/TcoderMonitorTests/||' | sort -u | head -10
    fail=1
  else
    grep -E "Executed [0-9]+ tests" /tmp/premerge-test.log | tail -1
  fi
fi

if [ -n "$CREATED" ]; then
  git worktree remove --force "$CREATED" 2>/dev/null || rm -rf "$CREATED"
fi

if [ "$fail" = "0" ]; then
  echo "==> ✅ $BRANCH 可以合入 main"
else
  echo "==> ❌ $BRANCH 不可合入。请让负责人自己跑双绿后再来。"
fi
exit "$fail"
