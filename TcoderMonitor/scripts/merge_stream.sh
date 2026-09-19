#!/bin/bash
# 把一条分支合进 main，并且**不允许把 main 留在冲突中间态**。
# 用法: scripts/merge_stream.sh ws/<分支> ["提交说明"]
#
# 为什么要这把脚本：我犯过两次同类错误。
#  ① 看到"分支领先 main 1 个提交"就直接 merge，结果那是没写完的重构（164 个编译错）。
#  ② 今天用一串 `git merge ... >/dev/null 2>&1 && echo ✅` 批量合入，
#     **没有 else 分支**，于是撞冲突时一声不响，main 被留在 MERGE_HEAD 存在、
#     3 个 unmerged 文件的状态，紧接着的 test 因为编不出《Executed N tests》而 EXIT=1，
#     我却差点把"EXIT=1 但没有失败用例行"当成别人的代码坏了。
# 这两次的共同点：判断"能不能合、合坏了没有"被我记在脑子里，而不是写在脚本里。
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 1

BRANCH="${1:-}"
MSG="${2:-merge $BRANCH}"
if [ -z "$BRANCH" ]; then echo "用法: $0 ws/<分支> [提交说明]"; exit 2; fi
if [ "$(git rev-parse --abbrev-ref HEAD)" != "main" ]; then
  echo "!! 当前不在 main 上（在 $(git rev-parse --abbrev-ref HEAD)），本脚本只做 main 集成"
  exit 1
fi
if [ ! -f "TcoderMonitor/Package.swift" ] && [ ! -f "Package.swift" ]; then
  echo "!! 看起来不是本仓库根，拒绝执行"
  exit 1
fi

die_clean() {           # 万一真进了冲突态，先撤销再报错，绝不把 main 留脏
  if git rev-parse -q --verify MERGE_HEAD >/dev/null; then
    git merge --abort && echo "   （已自动 merge --abort，main 回到 $(git rev-parse --short HEAD)）"
  fi
  echo "==> ❌ $1"
  exit 1
}

# 1) 合并前 main 必须是干净的
DIRTY=$(git status --porcelain | wc -l | tr -d ' ')
if [ "$DIRTY" != "0" ]; then
  die_clean "main 有 $DIRTY 个未提交改动。主树只作集成用，先弄清是谁留的。"
fi

# 2) 先做无副作用的冲突预检（不碰工作树）
if ! git merge-tree --write-tree --name-only main "$BRANCH" >/tmp/merge-tree-out.txt 2>&1; then
  echo "==> ❌ $BRANCH 与 main 有文本冲突，不在 main 上解。"
  grep -aE "^(CONFLICT|Auto-merging)" /tmp/merge-tree-out.txt | head -8
  echo "    请让负责人在自己树里 `git merge main` 解完再合。"
  exit 1
fi

# 3) 真合并
if ! git merge --no-ff "$BRANCH" -m "$MSG" >/tmp/merge-run.txt 2>&1; then
  echo "---- merge 输出 ----"; tail -8 /tmp/merge-run.txt
  die_clean "$BRANCH 合并失败（预检说没冲突，说明是 rename/delete 这类预检看不出来的冲突）"
fi

# 4) 合并后必须仍然干净 —— 这条是今天这次事故的直接补丁
AFTER=$(git status --porcelain | wc -l | tr -d ' ')
if [ "$AFTER" != "0" ]; then
  echo "---- 脏文件 ----"; git status --porcelain | head -6
  die_clean "合并后 main 仍有 $AFTER 个未提交/unmerged 文件"
fi

echo "==> ✅ $BRANCH 已合入 main（$(git rev-parse --short HEAD)），主树干净"
