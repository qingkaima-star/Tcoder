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
# 日志必须**按分支隔离**。我曾把两边都写成固定路径 "$TEST_LOG"，
# 于是并发的两次体检互相覆盖：c-runtime 与 ws/n-npmreg 的结论里打出了
# 一字不差、连耗时都相同（`in 160.225 (201.499) seconds`）的汇总行——
# 两个真实测试运行不可能耗时到小数点后三位一致，那说明它们读的是同一份被别人写过的日志。
# 更糟的是并发交错把文件写成了二进制，grep 直接报 `Binary file matches`，
# 那一次的 ✅ 等于没有任何依据。
SLUG=$(printf '%s' "$BRANCH" | tr -c 'A-Za-z0-9._-' '_')
RUN_TAG="$(date +%s)-$$"
BUILD_LOG="/tmp/premerge-${SLUG}-build.log"
TEST_LOG="/tmp/premerge-${SLUG}-test.log"
# 先只编测试目标：最便宜地暴露"没写完的重构"，不用等整轮 test。
if ! ./scripts/locked_build.sh build --build-tests > "$BUILD_LOG" 2>&1; then
  echo "  ❌ 测试模块编译不过，禁止合并"
  grep -aE "error:" "$BUILD_LOG" | sed 's|.*/\(Tests\|Sources\)/|\1/|' | sort -u | head -10
  fail=1
fi

if [ "$fail" = "0" ]; then
  # 日志自带本次运行的身份。只有标记**恰好出现一次**，才能证明下面读到的数字
  # 是这一次跑出来的，而不是别的分支留在同一个文件里的。
  { echo "PREMERGE-MARK branch=$BRANCH run=$RUN_TAG"
    ./scripts/locked_build.sh test
    echo "PREMERGE-RC=$?"; } > "$TEST_LOG" 2>&1
  MARKS=$(grep -ac "^PREMERGE-MARK branch=$BRANCH run=$RUN_TAG\$" "$TEST_LOG")
  RC=$(grep -a '^PREMERGE-RC=' "$TEST_LOG" | tail -1 | cut -d= -f2)
  if [ "$MARKS" != "1" ]; then
    echo "  ❌ 运行标记出现 ${MARKS} 次（应为 1）：日志被并发覆盖，本次结论不作数"
    fail=1
  elif [ "$RC" != "0" ]; then
    echo "  ❌ 测试未通过（退出码 ${RC:-未取到}），禁止合并"
    grep -aE "Executed [0-9]+ tests" "$TEST_LOG" | tail -1
    grep -aE "\.swift:[0-9]+: error:" "$TEST_LOG" | sed 's|.*/Tests/TcoderMonitorTests/||' | sort -u | head -10
    fail=1
  fi
fi

# 退出码 0 并不等于"真的跑过测试"。我差点用一版只看退出码的门禁放行了自己写的
# `--filter`（名字写错时 xctest 输出 `Executed 0 tests, with 0 failures`，是永真绿）。
# 所以这里必须**正向断言**跑掉了多少例、失败了多少例，取不到汇总行就判失败。
if [ "$fail" = "0" ]; then
  SUMMARY=$(grep -aE "Executed [0-9]+ tests?" "$TEST_LOG" | tail -1)
  RAN=$(printf '%s' "$SUMMARY" | sed -nE 's/.*Executed ([0-9]+) tests?.*/\1/p')
  FAILED=$(printf '%s' "$SUMMARY" | sed -nE 's/.*with ([0-9]+) failures?.*/\1/p')
  if [ -z "$RAN" ] || [ -z "$FAILED" ]; then
    echo "  ❌ 测试日志里没有汇总行，无法证明跑过测试（取不到数字＝没跑）"
    tail -5 "$TEST_LOG"
    fail=1
  elif [ "$RAN" -le 0 ]; then
    echo "  ❌ 实际执行 0 例，禁止合并：没有任何测试被跑到"
    fail=1
  elif [ "$FAILED" != "0" ]; then
    echo "  ❌ ${FAILED} 例失败（共 ${RAN} 例），禁止合并"
    fail=1
  else
    echo "  ✅ 全绿：${RAN} 例执行、0 失败"
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
