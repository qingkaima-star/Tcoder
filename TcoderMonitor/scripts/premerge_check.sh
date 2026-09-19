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
# 开工瞬间就把 commit 钉死：后面回执文件名用它，merge_stream 再拿分支头来对。
GATED_SHA=$(git rev-parse "$BRANCH" 2>/dev/null)
if [ -z "$GATED_SHA" ]; then
  echo "==> ❌ 解析不到分支 $BRANCH 的 commit，拒绝体检"
  exit 2
fi
RUN_TAG="$(date +%s)-$$"
BUILD_LOG="/tmp/premerge-${SLUG}-build.log"
TEST_LOG="/tmp/premerge-${SLUG}-test.log"
# 先只编测试目标：最便宜地暴露"没写完的重构"，不用等整轮 test。
if ! ./scripts/locked_build.sh build --build-tests > "$BUILD_LOG" 2>&1; then
  echo "  ❌ 测试模块编译不过，禁止合并"
  grep -aE "error:" "$BUILD_LOG" | sed 's|.*/\(Tests\|Sources\)/|\1/|' | sort -u | head -10
  fail=1
fi

# 快速模式：PREMERGE_SKIP_TEST=1 只做"能不能编译"这一半。
# 用途：一批分支排队等合入时，先用它把"没写完的重构"筛掉（这正是弄坏 main 的那个故障模式），
# 合并后再由 main 上的一次全量 test 兜底。跳过时结论会明写"未跑测试"，不许冒充全绿。
SKIP=0
if [ "${PREMERGE_SKIP_TEST:-0}" = "1" ]; then
  SKIP=1
  echo "  ⚠ PREMERGE_SKIP_TEST=1：本轮**未跑测试**，结论仅限「测试模块能编译」。"
fi

if [ "$fail" = "0" ] && [ "$SKIP" = "0" ]; then
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
if [ "$fail" = "0" ] && [ "$SKIP" = "0" ]; then
  SUMMARY=$(grep -aE "Executed [0-9]+ tests?" "$TEST_LOG" | tail -1)
  if [ -z "$SUMMARY" ]; then
    echo "  ❌ 测试日志里没有汇总行，无法证明跑过测试（取不到数字＝没跑）"
    tail -5 "$TEST_LOG"
    fail=1
  else
    RAN=$(printf '%s' "$SUMMARY" | sed -nE 's/.*Executed ([0-9]+) tests.*/\1/p')
    # 失败数必须取**紧邻 failures 的那个数字**。xctest 有两种真实措辞：
    #   Executed 378 tests, with 6 tests skipped and 0 failures (0 unexpected)
    #   Executed 8 tests, with 0 failures (0 unexpected)
    # 上一版按 "with ([0-9]+) failures" 取，被中间的 "6 tests skipped and" 挡住，
    # 于是把两个本来全绿的分支判红（方向没错，但结论是假的、消息还误导人）。
    FAILED=$(printf '%s' "$SUMMARY" | sed -nE 's/.*[^0-9]([0-9]+) failures?.*/\1/p')
    UNEXPECTED=$(printf '%s' "$SUMMARY" | sed -nE 's/.*[^0-9]([0-9]+) unexpected.*/\1/p')
    echo "  汇总行：$SUMMARY"
  fi
  if [ "$fail" = "0" ]; then
    if [ -z "$RAN" ] || [ -z "$FAILED" ]; then
      echo "  ❌ 汇总行取不到用例数/失败数，按未验证处理"
      fail=1
    elif [ "$RAN" -le 0 ]; then
      echo "  ❌ 实际执行 0 例，禁止合并：没有任何测试被跑到"
      fail=1
    elif [ "$FAILED" != "0" ] || [ "${UNEXPECTED:-0}" != "0" ]; then
      echo "  ❌ ${FAILED} 例失败 / ${UNEXPECTED:-?} 例意外（共 ${RAN} 例），禁止合并"
      fail=1
    else
      echo "  ✅ 全绿：${RAN} 例执行、0 失败"
    fi
  fi
fi

if [ -n "$CREATED" ]; then
  git worktree remove --force "$CREATED" 2>/dev/null || rm -rf "$CREATED"
fi

if [ "$fail" = "0" ]; then
  # 回执必须**钉在开工那一刻取到的 commit 上**，而不是"分支当前指向"。
  # 2026-09-20 实测漏过一次：门禁跑在 ed58dd5 上，负责人期间又交了 dfa6be3，
  # 我随后 merge 的是**没被体检过**的那个头。回执按 sha 命名，
  # merge_stream.sh 只认与分支头完全同号的回执，漂移就拒。
  if [ "$SKIP" = "1" ]; then
    echo "==> ⚠ $BRANCH 编译体检通过（**未跑测试**），可合入；合入后必须由 main 的全量 test 兜底"
    : > "/tmp/premerge-pass-${SLUG}-${GATED_SHA}.buildonly.ok"
  else
    echo "==> ✅ $BRANCH 可以合入 main"
    printf '%s\n' "$SUMMARY" > "/tmp/premerge-pass-${SLUG}-${GATED_SHA}.ok"
  fi
else
  echo "==> ❌ $BRANCH 不可合入。请让负责人自己跑双绿后再来。"
fi
exit "$fail"
