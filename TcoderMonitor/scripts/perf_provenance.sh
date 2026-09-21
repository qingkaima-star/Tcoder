#!/bin/bash
# =============================================================================
# perf_provenance.sh —— "被量的产物到底是不是这份代码"的**唯一判定处**。
#
# 为什么单独一个文件（不是客套话）：2026-09-21 我为了补测量归因，在
# `perf_preflight.sh` 里写了个 `provenance_ok`，随后才发现 `verify_provenance.sh`
# 早就在做同一件事（manifest rev == HEAD、构建时工作树干净、空值一律判败）。
# 同一件事两把手抄尺子的历史结局本仓记过多次：**口径会分叉，而且分叉之后
# 错的那一份常常在喂结论**。所以把判定抽到这里，两边都 source 它。
#
# 分工（不是两份口径，是同一判定的两个深度）：
#   · 本文件：rev / clean 的判定——测量与交付都要问的那一句；
#   · `verify_provenance.sh`：在此之上再加"交付面"才需要的哈希、Info.plist、架构。
#
# 用法：`source scripts/perf_provenance.sh`（本文件不自行执行任何东西）。
# =============================================================================

provenance_manifest_value() {  # provenance_manifest_value <KEY> [manifest 路径]
  # manifest 是 `build_app.sh` 落的 `KEY="value"`；注释行以 # 开头，天然不匹配。
  # 不 eval：值里曾有空格（旧包名），去引号再 eval 会词分割成注入面。
  local key="$1" path="${2:-dist/RELEASE_MANIFEST.env}" line
  [ -f "$path" ] || { echo ""; return 1; }
  line=$(grep -m1 "^${key}=" "$path" 2>/dev/null)
  printf '%s' "${line#*=}" | tr -d '"'
}

provenance_ok() {  # provenance_ok <manifest 里的完整 sha> <当前 HEAD> <manifest 的 GIT_CLEAN>
  # → 0=被量的二进制就是这份代码；非 0 时把原因 echo 到 stdout（调用方拼自己的话术）。
  #
  # 三个失效方向都拒，第四个方向（放行）也必须能过——否则就养出另一条
  # "永远不可能通过的闸门"（本仓实测踩过：前台名比错那次，三趟全被拒，
  # 而它拒得很响，看起来比放行更像尽职）。
  local built="$1" head="$2" clean="$3"
  if [ -z "$built" ] || [ "$built" = "unknown" ]; then
    echo "读不到产物的构建 rev（不是本仓 build_app.sh 建出来的，或 manifest 被删了）"; return 1
  fi
  if [ "$clean" != "true" ]; then
    echo "那趟构建**当时工作树就是脏的**（构建时 clean=${clean:-未记录}），rev 本身不可信"; return 1
  fi
  if [ -z "$head" ]; then
    echo "取不到当前 HEAD，无法与产物比对"; return 1
  fi
  if [ "$built" = "$head" ]; then
    return 0
  fi
  echo "产物是 ${built:0:7} 建的，当前代码是 ${head:0:7} —— 不是同一份代码"
  return 1
}
