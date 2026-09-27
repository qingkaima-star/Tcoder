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
  #
  # `PROVENANCE_MANIFEST` 是**取数出处**的唯一覆盖点（不给 `provenance_binary_matches` 单独开一枚）：
  # 判据本体只从这一个读点进，覆盖点也只有一个，才不会"rev 读夹具、内容读宿主"两半各说各话。
  # 它存在的理由很具体（#110，2026-09-27 实测）：selfcheck 被 harness source 进同一进程，
  # 于是 `PERF_BIN` 的默认值 `$PWD/dist/…` 会让**没建过 release 产物的树**里第 17 项假红。
  # 真实测量一律不设这个变量 ⇒ 行为一字不变。
  local key="$1" path="${2:-${PROVENANCE_MANIFEST:-dist/RELEASE_MANIFEST.env}}" line
  [ -f "$path" ] || { echo ""; return 1; }
  line=$(grep -m1 "^${key}=" "$path" 2>/dev/null)
  printf '%s' "${line#*=}" | tr -d '"'
}

provenance_binary_matches() {  # provenance_binary_matches <被量的二进制> [manifest 路径]
  # → 0＝眼前这个二进制**就是** manifest 记的那一份；非 0 时把原因 echo 到 stdout
  #   （调用方一律写成 `WHY=$(…)`，所以话术必须走 stdout，不走 stderr——同 `provenance_ok` 那条老账）。
  #
  # 为什么要它（2026-09-27 工单 #107，实测撞出来的）：闸门原先只比 **manifest 的 rev** 与 HEAD，
  # 而 manifest 每棵树只有一份（`dist/RELEASE_MANIFEST.env`），`PERF_BIN` 却可以指向任何 bundle
  # ⇒ "装着 A 的 manifest 去量 B"一路绿灯，读数被归到**不是它的那份代码**头上。
  # manifest 里 `TCODER_BINARY_SHA256` 早就有，只是一直没有读者（第 23 类：只有写点、零读者）。
  #
  # 按设计不参与的一格由**调用方**决定：debug 产物的哈希不在 release manifest 里
  # （那格是 codesign 之后对 `dist/…` 那个文件算的），所以调用方对 debug 要**明着跳过并说出来**，
  # 不许静默放行——这里只回答"内容对不对得上"，不替调用方判"该不该问这个问题"。
  #
  # 第二枚参数**缺省时不在这里填默认值**：出处只有 `provenance_manifest_value` 那一处（同一件事两把
  # 尺子的老账）。这里传空过去，读点自己按 `PROVENANCE_MANIFEST` → `dist/RELEASE_MANIFEST.env` 落。
  local bin="$1" path="${2:-}" want got
  if [ -z "$bin" ]; then
    echo "取不到被量的二进制路径（TARGET_BINARY 为空）⇒ 这一格没法对账"
    return 1
  fi
  [ -f "$bin" ] || { echo "被量的二进制不在场：$bin"; return 1; }
  want=$(provenance_manifest_value TCODER_BINARY_SHA256 "$path")
  if [ -z "$want" ]; then
    echo "manifest 里没有 TCODER_BINARY_SHA256（看 ${path:-PROVENANCE_MANIFEST 未设，即默认的 dist/RELEASE_MANIFEST.env}）⇒ 无从对账，别当通过"
    return 1
  fi
  got=$(shasum -a 256 "$bin" 2>/dev/null | cut -d' ' -f1)
  if [ -z "$got" ]; then
    echo "算不出被量二进制的 sha256：$bin"
    return 1
  fi
  if [ "$want" != "$got" ]; then
    echo "manifest 记的产物是 ${want:0:12}…，而真正要量的这个算出 ${got:0:12}…（$bin）⇒ 这批读数不归给这份代码"
    return 1
  fi
  return 0
}

provenance_product_tree() {  # provenance_product_tree [rev] → 该提交"产物码"的 tree 指纹
  # 为什么比 tree 而不是 commit sha：落地/merge 加的**容器提交**会换 sha，
  # 而 `Sources/` + `Resources/` 两棵子树逐字节没变。只比 sha 就会把
  # "刚落的交付内容"判成"另一份代码"——2026-09-21 14:08 实测：
  # 落地后同步出来的头与建物的头，Sources 树 hash 完全相同（e3f8980…），
  # 闸门却因为 sha 不同，把一整轮交互期测量拒掉了（**假拒**）。
  # 拿不到两棵子树就返回空：调用方按 fail-closed 处理，绝不"看不见就当通过"。
  local rev="${1:-HEAD}" a b
  a=$(git rev-parse "$rev:TcoderMonitor/Sources" 2>/dev/null) || a=""
  b=$(git rev-parse "$rev:TcoderMonitor/Resources" 2>/dev/null) || b=""
  [ -n "$a" ] && [ -n "$b" ] || { echo ""; return 1; }
  printf '%s%s' "$a" "$b" | shasum -a 256 | cut -d' ' -f1
}

provenance_target_rev() {  # → 归属比的是**谁**：默认 HEAD；`MEASURE_REV` 显式给了就比它
  # 派生只住这一处（preflight 的两个函数都要用，抄两遍就会分叉——
  # 2026-09-23 实测：第一版把它写在"收集上下文"那个函数里，而闸门那个函数被自测**单独调用**
  # 时拿到空值，于是"六维全合格却被拒"，等于我自己养出一条永远不可能通过的闸门）。
  # `--verify --quiet` + `^{commit}`：取不到就**回空**，不许把没解析动的字符串原样吐回来。
  # （`git rev-parse 没有这个rev` 会打印入参本身并非零退出 ⇒ 闸门拿到一个"看着像 sha"的
  #   非空值，拒是拒了，但话术成了「当前代码是 没有这个rev」——那是把取不到说成一个提交。）
  git rev-parse --verify --quiet "${MEASURE_REV:-HEAD}^{commit}" 2>/dev/null
}

provenance_ok() {  # provenance_ok <产物 rev> <当前 HEAD> <构建时 clean> [产物 tree] [当前 tree]
  # → 0=被量的二进制就是这份代码；非 0 时把原因 echo 到 stdout（调用方拼自己的话术）。
  # 第 4/5 参是"产物码 tree 指纹"：给了就认——rev 不同但 tree 相同 ⇒ 放行，
  # 并把放行理由写进 `PROVENANCE_NOTE`，调用方**必须**把它印进上下文（不许悄悄放行）。
  # 没给（老 manifest 里没这个字段）⇒ 退回严格比 sha，宁拒不错。
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
  local btree="${4:-}" htree="${5:-}"
  if [ -n "$btree" ] && [ -n "$htree" ] && [ "$btree" = "$htree" ]; then
    # 必须走 stdout：调用方普遍写成 `WHY=$(provenance_ok …)`，那里面对变量的赋值
    # 发生在**子 shell** 里，父进程永远读不到——实测 2026-09-21 15:31，
    # 于是"按 tree 放行必须留痕"变成了一句没有效果的注释（悄悄放行，正是我禁止的那种）。
    echo "rev 不同（产物 ${built:0:7} / 当前 ${head:0:7}）但产物码 tree 相同 ${btree:0:7}"\
" —— 差的只是 docs/scripts/测试，可归属"
    return 0
  fi
  echo "产物是 ${built:0:7} 建的，当前代码是 ${head:0:7} —— 不是同一份代码"\
"${btree:+（产物码 tree 也不同：${btree:0:7} vs ${htree:-?}）}"
  return 1
}

provenance_main_drift() {  # provenance_main_drift [rev] → 该 rev 落后 main 几笔**碰产品码的**提交；取不到打「未取到」
  # 【为什么要有这一格】`measured_rev` 只回答"这枚二进制是谁"，不回答"它落后多少"。
  # 于是"内部完全一致、对外已经过期"这一类判废在 harness 里**从来没有读数**——
  # `is-ancestor` 只活在合流侧 `merge_stream.sh`，测量侧一处都没有（09-25 另一条流按名字复核时
  # 就把它标成未闭合）。这一格把那句话变成读数，只加字段、不加闸门：
  # **要不要因为落后而拒测，是调度约定（#62）的事，不由这把尺替需求方决定。**
  #
  # 【口径，写死在这里】只数改了 `TcoderMonitor/Sources` 或 `TcoderMonitor/Resources` 的提交。
  # 08:00 在真历史标定过：从出货那一笔 `ab22870` 到 main，按产品码口径 = **3 笔**，
  # 按"全部提交"口径 = **57 笔**，差 19 倍。用 57 那种数当警报，这一格天天响，
  # 于是没人再看它——**报警过密的读数等于没有读数**。
  #
  # 【pathspec 必须带 `:/`】本文件常被从包根（`TcoderMonitor/`）source，而 pathspec 是
  # **相对 cwd** 解析的：08:08 实测在包根跑
  #   `git rev-list --count ab22870..main -- TcoderMonitor/Sources` → **0**（假的"没落后"）
  #   同一句加 `:/` → **3**（真值）。
  # 少了这两个字符，这把尺会**永远报最新**，是它能坏掉的最坏形状。
  #
  # 【"没查到"不许渲染成"没落后"】rev 解析不了、不在仓库里、git 报错 ⇒ 一律 `未取到`。
  # 08:03 我就把一个 sha 打错一位，`git rev-list --count` 回的是**空串、不是 0**；
  # 所以下面**不写 `|| echo 0`**，并且只认"纯数字"这一种输出。
  local rev="${1:-}" out
  [ -n "$rev" ] || rev=$(git rev-parse HEAD 2>/dev/null) || { echo "未取到"; return 0; }
  out=$(git rev-list --count "$rev..main" \
          -- :/TcoderMonitor/Sources :/TcoderMonitor/Resources 2>/dev/null)
  case "$out" in
    ''|*[!0-9]*) echo "未取到" ;;
    *)           echo "$out" ;;
  esac
}

provenance_product_identity() {  # provenance_product_identity [manifest 路径]
  # → 一行**人看**的话：被测的那枚二进制到底是哪份内容、它落后 main 几笔产品码。
  # 【为什么搬进库文件】排程器本体不可 source（一 source 就开始等窗、起 GUI），
  # 反例点不到它里面的函数——同一族形状已经搬过两次（`perf_chain_guard.sh`、`perf_blame_caliber.py`）。
  # 搬进来之后第 65 项才能拿一棵临时仓库去逐格判它。
  # 【口径】rev 只从 manifest 取（`provenance_manifest_value`），落后几笔只从
  # `provenance_main_drift` 取：本文件外面不许再解析一遍 manifest、再数一遍提交。
  local manifest="${1:-dist/RELEASE_MANIFEST.env}" rev tree drift
  rev=$(provenance_manifest_value TCODER_GIT_REVISION "$manifest")
  if [ -z "$rev" ] || [ "$rev" = "unknown" ]; then
    # 取不到就明说取不到。回落成 HEAD 会把「不知道被测的是谁」印成「被测的就是最新」，方向正好相反。
    echo "⚠ manifest 里没有可用的 TCODER_GIT_REVISION ⇒ 说不出被测产品码，这一批只能当线索"
    return 1
  fi
  tree=$(git rev-parse --short=12 "${rev}:TcoderMonitor/Sources" 2>/dev/null) || tree=""
  drift=$(provenance_main_drift "$rev")
  echo "被测产品码 Sources tree=${tree:-取不到}（rev=${rev:0:7}，落后 main ${drift} 笔产品码）"
}
