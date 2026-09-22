#!/bin/bash
# =============================================================================
# perf_selfcheck.sh —— selfcheck 档的**编排器**（拿合成夹具量尺子自己），由
# perf_harness.sh 在 `selfcheck` 那一档 **source** 进来。**不要单独执行**：它依赖
# 宿主的 $REV / $TRACE_REPORT / $PULSE_REPORT / $QUIESCE_SRC 与 quiescence_probe /
# quietest_seconds / human_input_in_window / die 这些同进程的量。
#
# 本文件现在只有 `cmd_selfcheck` + 三段 `items_*`（29 项 `item` 调用按主题分三段）；
# 29 项反例的**判据本体**按主题住在同目录三块文件里
# （`_ruler_shapes` 形状与三态话术 / `_gates` 前置与闸门 / `_eligibility` 样本资格），
# 由下面三行 source 进来。**为什么要拆**：`SelfScanDogfoodTests` 的 ≤800 行棘轮
# **分母含 `.sh`** 且 ceiling=0（`SourceLanguageCatalog` 认 Shell），2026-09-21 本文件
# 涨到 835 行，把并完 main 的那次门禁当场判红。
# **拆开它才是修复，拧阈值不是**（2026-09-20 就是 trace_report.py 长到 819 行把 main
# 判红过一次，那次没人提前发现，因为没人跑过 selfcheck 的这一项）。
# 三块文件都进了尺子热点棘轮的点名清单（"尺子文件名单"那条门，在 Tests 侧）——
# 搬出去不等于免检，"拆"一旦成为免检通道，这条棘轮就只剩装饰作用。
# （这里刻意不写点号形式的符号名：文档锚点门只核验 `Sources/**` 里的标识符，
#   指着 Tests 侧的符号会被判成失效引用——2026-09-21 实测踩过一次。）
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
  # 每一项都必须**出声**。`bad` 是好几项共用的全局：某项把它置 1 之后，后面所有以
  # `[ "${bad:-0}" = "0" ] && ok …` 收尾的项会**一声不吭地既不 ok 也不 fail**。
  # 2026-09-21 实测：第 23 项红一次就吞掉了第 24 项整条，31 项变 30 项，
  # 而汇总只说"坏了 1 项"——被吞的那一维没有任何人会看见，这正是最难查的那种失效。
  item() {  # item <项函数> <outdir>
    local spoke=$((checked + fails))
    local bad=0                       # 项与项之间不共享状态
    "$@"
    [ "$((checked + fails))" -gt "$spoke" ] \
      || fail "项 $1 一声不吭（既没 ok 也没 fail）——被跳过的判据比红的更危险"
  }

  items_ruler_shapes "$out"
  items_gates "$out"
  items_sample_eligibility "$out"

  echo "◇ selfcheck：$checked 项通过，$fails 项失败（产物 $out）"
  [ "$fails" -eq 0 ] || die "尺子坏了 $fails 项——修尺子，别改读数"
}

# -----------------------------------------------------------------------------
# 29 项 `item` 调用按主题分成三段。
#
# **为什么还要再拆一次**（2026-09-22）：这段以前是一串直白写在 `cmd_selfcheck` 里的
# `item …`，加到第 30 项之后函数体 53 行，被**尺子自己的**「函数 ≤50 行 / CC<16」棘轮判红。
# 而它此前一直没红，原因是量它的引擎变好了：main 在这批合并里动了
# `Services/Code/SourceFileClassifier.swift` 与 `FileSystemCodeAnalyzer.swift`，
# 于是 `.sh` 里这个函数的行数**第一次被数对**。
# ⇒ 这不是"守卫突然苛刻"，是**这把尺子以前瞎**。（正解仍是拆开它，不是抬 50 这条线。）
#
# 拆法刻意**保持调用顺序逐字不变**：这样"拆前后行为一致"可以用 selfcheck 自己的
# 输出逐字 diff 来证，而不是靠"应该没影响"。三段各自只用 `item` / `$out`，
# 而 `item` 是编排器里的嵌套函数、`out`/`checked`/`fails` 是它的 `local`
# —— bash 是**动态作用域**，被调函数照样看得见（这一条是本文件头就验过的老事实）。
# -----------------------------------------------------------------------------
items_ruler_shapes() {   # items_ruler_shapes <outdir> —— 1..13 形状、三态话术、分级与前台
  item selfcheck_ruler_files "$out"      # 1) 三层文件齐全 / 编译得过 / 没撞 ≤800 行棘轮
  item selfcheck_switch_fixture "$out"   # 2) switch 档逐页表的三态（读数 / 缺 meta / 缺 life-cycle）
  item selfcheck_empty_table "$out"      # 3) 空表要报"未采到"，而不是报"n=0 达标"
  item selfcheck_missing_file "$out"     # 4) 垃圾输入必须非零退出
  item selfcheck_cross_check "$out"      # 5) 反向元测试：复核尺抓得住不一致
  item selfcheck_framepulse "$out"       # 6) 交互期那把尺子的三个退出码
  item selfcheck_period_wording "$out"   # 7) 测量期间印在表头上 + 两档各说各的资格
  item selfcheck_migration "$out"        # 8) migration 的口径必须从守卫源码里读
  item selfcheck_quiescence "$out"       # 10) 人手静默探针（第五维）
  item selfcheck_weight_ruler "$out"     # 11) 收益分级：现读、缺料要喊、名单对不上要报⚠
  item selfcheck_front_name "$out"       # 12) 前台名判定：显示名/进程名都认，别家一律拒
  item selfcheck_render_regime "$out"    # 13) render 比率只在同一种出帧机制下互比
}

items_gates() {          # items_gates <outdir> —— 14..19 前置与开录闸门
  item selfcheck_binary_provenance "$out" # 14) 被量的二进制必须就是这份代码（rev 对齐）
  item selfcheck_baseline_text_is_derived "$out"  # 15) 对照列文字不许是字典的第二份手抄
  item selfcheck_heavy_jobs_probe "$out"  # 16) 并发重活：三个名字都要认，输出必须是 pid 清单
  item selfcheck_gate_matrix "$out"      # 17) 七维闸门合成矩阵：能放行，也会逐维拒
  item selfcheck_page_list_shape "$out"    # 18) 九页页名逐条完整（带空格的那条不许被拆）
  item selfcheck_launch_ready "$out"       # 19) 首帧要剔除运行期尾巴，不许拿求和冒充
  item selfcheck_launcher_inventory "$out"  # 31) 实例清单要分得清"真起 / 会收尾 / 只是讲"（三夹具双向）
  item selfcheck_synth_launch_pairing "$out"  # 32) 谁起实例/谁投滚动/什么时候投，三者必须配套
}

items_sample_eligibility() {  # items_sample_eligibility <outdir> —— 20..30 样本资格与留痕
  item selfcheck_probe_sentinel "$out"     # 20) 探针取不到的哨兵不许骗过"有人在动"那条判定
  item selfcheck_period_eligibility "$out" # 21) 档位声明与收尾复核互相矛盾的样本不许拿到 T1 资格
  item selfcheck_probe_self_sufficient "$out" # 22) 探针必须能被裸 `set -u` 消费者调用（不靠 harness）
  item selfcheck_perf_root_ignored "$out"    # 23) 样本根必须真的被 git 忽略，且不许有第二处写死 /tmp 默认值
  item selfcheck_disk_precondition "$out"    # 24) 前置必须**能失败**：判定要在、且全仓只有一份
  item selfcheck_display_regime "$out"       # 25) 120Hz 预算只对 120Hz 档成立：降频档里不许印"危急"
  item selfcheck_app_update_split "$out"         # 26) 一个 max 不许同时盖住"整体很快"和"有个孤例很慢"
  item selfcheck_phase_blame "$out"              # 27) 迟到帧要说清该怪主线程还是合成侧，三种形状各判一次
  item selfcheck_input_rate_qualification "$out"  # 28) meta 里的输入节奏必须有读者
  item selfcheck_launcher_hygiene "$out"       # 29) 起实例的脚本必须有 trap、不许按 bundle id 广播
  item selfcheck_md_tables_unbroken "$out"     # 30) markdown 表格不许有夹在行中间的裸续行
}

# 反例分块（每块一个文件，宿主只留编排）：这三行必须在 cmd_selfcheck 之前，
# 因为编排器一跑就要点到里面的函数名。
# shellcheck source=/dev/null
for _part in ruler_shapes gates eligibility; do
  source "scripts/perf_selfcheck_${_part}.sh"
done
unset _part
