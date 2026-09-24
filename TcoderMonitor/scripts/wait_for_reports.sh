#!/bin/bash
# 「等第一轮分析落盘」这一件事的**唯一实现**。
#
# 为什么要单独一份：`ax_tooltip_report.sh` 里那条判据是"reports/ 的文件数与体积
# **连续两轮不变**才算落盘"，而 `ax_truncation_sweep.sh` 当年只写了一句 `sleep 20`。
# 对本仓（约 10 秒扫完）两者等价；**换一个更大的仓库就不等价了**——固定 sleep 会在
# 界面还空着的时候去读树，于是"主门 0 处"读出来的是"还没画出来"，不是"界面干净"。
# 一把尺子的**前置条件**不该有两份写法，所以搬到这里，两边 source 它。
#
# 用法：`source scripts/wait_for_reports.sh`，然后 `wait_for_reports <pid>`。
# 依赖两个调用方各自定义的全局量：`SANDBOX`（支持目录）与 `WAIT_BUDGET`（秒，默认 420）。
# 返回 0 = 等到落盘（或超预算，按现状读并**出声**）；返回 1 = 实例中途退出，读数作废。

wait_for_reports() {  # 等到 reports/ 的文件数与体积连续两轮不变（不是拍脑袋 sleep）
  local pid="$1" waited=0 prev="" cur bytes sig
  local budget="${WAIT_BUDGET:-420}"
  while [ "$waited" -lt "$budget" ]; do
    cur=$(ls -1 "$SANDBOX/reports" 2>/dev/null | wc -l | tr -d ' ')
    bytes=$(du -sk "$SANDBOX/reports" 2>/dev/null | cut -f1)
    sig="$cur:$bytes"
    if [ "$cur" != "0" ] && [ "$sig" = "$prev" ]; then
      echo "   报告已落盘：$cur 份 / ${bytes} KiB（等了 ${waited}s）"; return 0
    fi
    prev="$sig"
    ps -p "$pid" > /dev/null 2>&1 || { echo "   !! 实例 $pid 已退出，不等了"; return 1; }
    sleep 5; waited=$((waited + 5))
  done
  echo "   ⚠ 超出 ${budget}s，按现状读（可能还在跑长段落）"; return 0
}
