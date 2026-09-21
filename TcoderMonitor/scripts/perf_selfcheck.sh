#!/bin/bash
# =============================================================================
# perf_selfcheck.sh —— selfcheck 档的**编排器**（拿合成夹具量尺子自己），由
# perf_harness.sh 在 `selfcheck` 那一档 **source** 进来。**不要单独执行**：它依赖
# 宿主的 $REV / $TRACE_REPORT / $PULSE_REPORT / $QUIESCE_SRC 与 quiescence_probe /
# quietest_seconds / human_input_in_window / die 这些同进程的量。
#
# 现在只剩 `cmd_selfcheck` 一个函数：27 项反例按主题住在同目录三块文件里
# （`_ruler_shapes` 形状与三态话术 / `_gates` 前置与闸门 / `_eligibility` 样本资格），
# 由下面三行 source 进来。**为什么要拆**：`SelfScanDogfoodTests` 的 ≤800 行棘轮
# **分母含 `.sh`** 且 ceiling=0（`SourceLanguageCatalog` 认 Shell），2026-09-21 本文件
# 涨到 835 行，把并完 main 的那次门禁当场判红。
# **拆开它才是修复，拧阈值不是**（2026-09-20 就是 trace_report.py 长到 819 行把 main
# 判红过一次，那次没人提前发现，因为没人跑过 selfcheck 的这一项）。
# 三块文件都进了 `PerfRulerHotspotRatchetTests.rulerScripts` 的点名清单——
# 搬出去不等于免检，"拆"一旦成为免检通道，这条棘轮就只剩装饰作用。
#
# 每一项的判据、断言与 `ok` / `fail` 文案**逐字未动**；项与项之间只共享 `fails` /
# `checked` 两个计数器（bash 是动态作用域，编排器里的 `local` 在被调函数里照样可见，
# 这一条已单独验过）。拆前拆后的 31 项输出逐字 diff 过（差异只有探针秒数、
# 当时机器上有没有别人的重活、以及 bash 自己打在 stderr 的 Terminated 作业行）。
# 上一轮（167 行 cmd_selfcheck 那次）的对照记在 97 号笔记。
# =============================================================================

# =============================================================================
# selfcheck —— 不起 App、不碰 xctrace，拿合成夹具验这把尺子自己还活着
# =============================================================================
cmd_selfcheck() {
  local out="${1:-${SCRATCH:-/tmp}/tcoder-perf-selfcheck-$REV}"
  echo "==> selfcheck 档：验尺子（合成夹具，零采样，秒级）"
  rm -rf "$out"; mkdir -p "$out"
  local fails=0
  local checked=0
  fail() { echo "  ✗ $1"; fails=$((fails+1)); }
  ok()   { echo "  ✓ $1"; checked=$((checked+1)); }

  selfcheck_ruler_files "$out"      # 1) 三层文件齐全 / 编译得过 / 没撞 ≤800 行棘轮
  selfcheck_switch_fixture "$out"   # 2) switch 档逐页表的三态（读数 / 缺 meta / 缺 life-cycle）
  selfcheck_empty_table "$out"      # 3) 空表要报"未采到"，而不是报"n=0 达标"
  selfcheck_missing_file "$out"     # 4) 垃圾输入必须非零退出
  selfcheck_cross_check "$out"      # 5) 反向元测试：复核尺抓得住不一致
  selfcheck_framepulse "$out"       # 6) 交互期那把尺子的三个退出码
  selfcheck_period_wording "$out"   # 7) 测量期间印在表头上 + 两档各说各的资格
  selfcheck_migration "$out"        # 8) migration 的口径必须从守卫源码里读
  selfcheck_quiescence "$out"       # 10) 人手静默探针（第五维）
  selfcheck_weight_ruler "$out"     # 11) 收益分级：现读、缺料要喊、名单对不上要报⚠
  selfcheck_front_name "$out"       # 12) 前台名判定：显示名/进程名都认，别家一律拒
  selfcheck_render_regime "$out"    # 13) render 比率只在同一种出帧机制下互比
  selfcheck_binary_provenance "$out" # 14) 被量的二进制必须就是这份代码（rev 对齐）
  selfcheck_baseline_text_is_derived "$out"  # 15) 对照列文字不许是字典的第二份手抄
  selfcheck_heavy_jobs_probe "$out"  # 16) 并发重活：三个名字都要认，输出必须是 pid 清单
  selfcheck_gate_matrix "$out"      # 17) 七维闸门合成矩阵：能放行，也会逐维拒
  selfcheck_page_list_shape "$out"    # 18) 九页页名逐条完整（带空格的那条不许被拆）
  selfcheck_launch_ready "$out"       # 19) 首帧要剔除运行期尾巴，不许拿求和冒充
  selfcheck_probe_sentinel "$out"     # 20) 探针取不到的哨兵不许骗过"有人在动"那条判定
  selfcheck_period_eligibility "$out" # 21) 档位声明与收尾复核互相矛盾的样本不许拿到 T1 资格
  selfcheck_probe_self_sufficient "$out" # 22) 探针必须能被裸 `set -u` 消费者调用（不靠 harness）
  selfcheck_perf_root_ignored "$out"    # 23) 样本根必须真的被 git 忽略，且不许有第二处写死 /tmp 默认值
  selfcheck_disk_precondition "$out"    # 24) 前置必须**能失败**：判定要在、且全仓只有一份
  selfcheck_display_regime "$out"       # 25) 120Hz 预算只对 120Hz 档成立：降频档里不许印"危急"
  selfcheck_app_update_split "$out"         # 26) 一个 max 不许同时盖住"整体很快"和"有个孤例很慢"
  selfcheck_phase_blame "$out"              # 27) 迟到帧要说清该怪主线程还是合成侧，三种形状各判一次

  echo "◇ selfcheck：$checked 项通过，$fails 项失败（产物 $out）"
  [ "$fails" -eq 0 ] || die "尺子坏了 $fails 项——修尺子，别改读数"
}

# 反例分块（每块一个文件，宿主只留编排）：这三行必须在 cmd_selfcheck 之前，
# 因为编排器一跑就要点到里面的函数名。
# shellcheck source=/dev/null
for _part in ruler_shapes gates eligibility; do
  source "scripts/perf_selfcheck_${_part}.sh"
done
unset _part
