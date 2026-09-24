#!/bin/bash
# =============================================================================
# perf_warmup.sh —— 测量协议第七维「预热」：被测实例到底已经跑了多久
#
# 为什么单独一个文件：`perf_preflight.sh` 加完这一维是 410 行，撞产品侧同一口径的 400 行线
# （`.sh` 也算实现文件 —— 这条规矩 09-22 就为它拆过六个脚本）。
# **但拆文件不能切断依赖链**：selfcheck 里有一项是「单独 source preflight」来验缺省阈值的，
# 所以这一维由 `perf_preflight.sh` **自己** source 进来（不是调用方拼），
# 否则那条路会拿到一个不完整的函数集 —— 两个入口各拿一半函数是这条链上写死不许发生的形状。
#
# 这一维是怎么来的（2026-09-24 04:1x 实测，同一个实例、间隔约 5 分钟、机器全程零重活）：
#   run1  potential-hangs 5 枚 / 合计 2725 ms / 最长 887.24 ms；app-update max 598.70 ms；hitch 49
#   run2  2 枚 / 574 ms                                              max 1.24 ms；    hitch 15
#   run3  0 枚 / 0                                                   max 1.52 ms；    hitch 0
# ⇒ 第一窗量到的是**启动后的首扫尾巴**，不是 1.5 s 心跳的稳态。
#   在那之前尺子没有这一维，所以"心跳期占用 598 ms"这句话既真实又**指错了对象**，
#   一致性质检因此判出 481.9× 的极差比（它抓到的是"两个阶段"，不是"一次抖动"）。
# 判据落点：读不到时长 ⇒ 出声但**不拒**（不能让 `ps` 失败变成永久拒跑）；
#   读得到且低于预热线 ⇒ **拒**，因为那种窗口的数与稳态根本不可比。
# 启动档（`PREFLIGHT_TIER=launch`）不参与：那一刻实例本来就是刚起来的，
#   拿预热线去判它等于造一条永远不可能通过的闸（同"启动档跳过窗口两维"那条教训）。
# =============================================================================
# **这里不写 `set -euo pipefail`**：本文件是被 `perf_preflight.sh` source 进去的库，
# shell 选项会**留在调用方**——`set -u` 一生效，preflight 里任何一个未绑定的变量都会让
# 非交互 shell **当场退出**（连一行输出都没有），表现成"闸门静默消失"。
# 实测过一次：加了这行之后 `preflight_context` 的拒跑分支不再落 REFUSED、外层 rc=127。
# 同族的兄弟：`perf_preflight.sh` / `perf_measure_io.sh` / `perf_probes.sh` 都不设选项，只有可执行脚本才设。

instance_uptime_seconds() {  # <pid> ⇒ 已运行秒数；读不到印「取不到」并回 1（**不许回落成 0**）
  local raw
  raw=$(ps -o etime= -p "${1:-}" 2>/dev/null | tr -d ' ')
  [ -n "$raw" ] || { printf '取不到\n'; return 1; }
  printf '%s\n' "$raw" | awk '{
    d = 0; rest = $0
    if (index(rest, "-") > 0) { split(rest, a, "-"); d = a[1] + 0; rest = a[2] }
    n = split(rest, t, ":")
    if (n == 3)      print d * 86400 + t[1] * 3600 + t[2] * 60 + t[3]
    else if (n == 2) print d * 86400 + t[1] * 60 + t[2]
    else             print "取不到"
  }'
}

preflight_gates_warmup() {  # 读上面那几个动态作用域的 local：uptime_secs / PREFLIGHT_TIER / hard
  [ "${PREFLIGHT_TIER:-measure}" = "launch" ] && return 0
  case "${uptime_secs:-}" in
    ''|*[!0-9]*)
      echo "    ⚠ 读不到被测实例的运行时长 ⇒ 不拒跑，但这批读数的『稳态心跳』身份未证" >&2
      return 0 ;;
  esac
  if [ "$uptime_secs" -lt "${WARMUP_MIN_SECONDS:-120}" ]; then
    echo "    ✗ 被测实例只跑了 ${uptime_secs}s（预热线 ${WARMUP_MIN_SECONDS:-120}s）" \
         "——首扫尾巴会伪装成心跳，这一窗的数与稳态不可比" >&2
    hard=1
  else
    echo "    ✓ 被测实例已跑 ${uptime_secs}s ≥ 预热线 ${WARMUP_MIN_SECONDS:-120}s"
  fi
}
