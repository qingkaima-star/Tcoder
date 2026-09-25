#!/bin/bash
# =============================================================================
# perf_selfcheck.sh —— selfcheck 档的**编排器**（拿合成夹具量尺子自己），由
# perf_harness.sh 在 `selfcheck` 那一档 **source** 进来。**不要单独执行**：它依赖
# 宿主的 $REV / $TRACE_REPORT / $PULSE_REPORT / $QUIESCE_SRC 与 quiescence_probe /
# quietest_seconds / human_input_in_window / die 这些同进程的量。
#
# 本文件现在只有 `cmd_selfcheck` 与几段 `items_*`（`item` 调用按主题分块，块数不抄在这里）；
# 【两个分母别混】末行印的「N 项通过」数的是 `ok` 调用次数（一项可以印两行 ✓），
# 与「`item` 调用的处数」不是同一个数（那把尺现量：`grep -cE '^[[:space:]]+item selfcheck_' scripts/perf_selfcheck.sh`）。
# 以前这里写死过"32 处"，加一项就烂一次 —— 手写分母要么每次跟着改，要么换成能跑的命令；
# 09-22 加第 32、33 项时就把两个数混过一回，别再留第三个腐烂的数字在这里。
# 反例的**判据本体**按主题住在同目录的若干块文件里（`_ruler_shapes` 形状与三态话术 /
# `_gates` 前置与闸门 / `_eligibility` 样本资格 / `_launchers` 起实例与收尾 / `_tables` 文档表 /
# `_chain` 链的归属与同树链闸 / `_trap` trap 的时效性（长 sleep 会把收尾拖过一整窗）。
# **块清单只有一个来源：下面那个 `for` 的那一行**，
# 这里刻意不再抄一个数字（第 12 行那句"别再留腐烂的数字"说的就是这类抄件）。
# 由那个 for source 进来。**为什么要拆**：`SelfScanDogfoodTests` 的 ≤800 行棘轮
# **分母含 `.sh`** 且 ceiling=0（`SourceLanguageCatalog` 认 Shell），2026-09-21 本文件
# 涨到 835 行，把并完 main 的那次门禁当场判红。
# **拆开它才是修复，拧阈值不是**（2026-09-20 就是 trace_report.py 长到 819 行把 main
# 判红过一次，那次没人提前发现，因为没人跑过 selfcheck 的这一项）。
# 每一块文件都进了尺子热点棘轮的点名清单（`rulerScripts` 那条门，在 Tests 侧）——
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
# `item` 调用按主题分成若干块（块清单在下面那个 for，只有那一处是权威）。
#
# **为什么还要再拆一次**（2026-09-22）：这段以前是一串直白写在 `cmd_selfcheck` 里的
# `item …`，加到第 30 项之后函数体 53 行，被**尺子自己的**「函数 ≤50 行 / CC<16」棘轮判红。
# 而它此前一直没红，原因是量它的引擎变好了：main 在这批合并里动了
# `Services/Code/SourceFileClassifier.swift` 与 `FileSystemCodeAnalyzer.swift`，
# 于是 `.sh` 里这个函数的行数**第一次被数对**。
# ⇒ 这不是"守卫突然苛刻"，是**这把尺子以前瞎**。（正解仍是拆开它，不是抬 50 这条线。）
#
# 拆法刻意**保持调用顺序逐字不变**：这样"拆前后行为一致"可以用 selfcheck 自己的
# 输出逐字 diff 来证，而不是靠"应该没影响"。各段都只用 `item` / `$out`，
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
  item selfcheck_py_rulers_compile "$out"       # 36) 每支 .py 尺子都要能被 compile() 读懂（ASCII 引号第 6 次）
  item selfcheck_section_wiring "$out"      # 40) MEASURE_SECTION 必须进到启动那一行（定义了没用＝假接线）
  item selfcheck_measure_rev_attribution "$out"  # 38) 补测改动前基线：归属照样判，只是判另一个 rev
  item selfcheck_load_threshold_override "$out"  # 51) LOAD_MAX 这个出口必须真的改判并回显生效阈值
  item selfcheck_inwindow_load_verdict "$out"  # 52) 窗口内负载峰值要能定合格（四形状，含"没采到要出声"）
  item selfcheck_switch_page_names "$out"        # 48) 冷启动档的页名：含空格的要过、名册外的要当场红
  item selfcheck_switch_attribution_and_refusal "$out"  # 49) 归属写给被测内容；宿主 die 不在场时也要拒跑
  item selfcheck_cleanup_opt_in_state "$out"   # 37) 收尾形状三分：无条件 kill / 躲在开关后面 / 没有（三夹具双向）
}

items_sample_eligibility() {  # items_sample_eligibility <outdir> —— 20..30 样本资格与留痕
  item selfcheck_probe_sentinel "$out"     # 20) 探针取不到的哨兵不许骗过"有人在动"那条判定
  item selfcheck_period_eligibility "$out" # 21) 档位声明与收尾复核互相矛盾的样本不许拿到 T1 资格
  item selfcheck_probe_self_sufficient "$out" # 22) 探针必须能被裸 `set -u` 消费者调用（不靠 harness）
  item selfcheck_perf_root_ignored "$out"    # 23) 样本根必须真的被 git 忽略，且不许有第二处写死 /tmp 默认值
  item selfcheck_disk_precondition "$out"    # 24) 前置必须**能失败**：判定要在、且全仓只有一份
  item selfcheck_display_regime "$out"       # 25) 120Hz 预算只对 120Hz 档成立：降频档里不许印"危急"
  item selfcheck_app_update_split "$out"         # 26) 一个 max 不许同时盖住"整体很快"和"有个孤例很慢"
  item selfcheck_phase_blame "$out"              # 27) 迟到帧该怪谁：八种形状各判一次（含"有 hangs 不许归给合成侧"与它的反向）
  item selfcheck_input_rate_qualification "$out"  # 28) meta 里的输入节奏必须有读者
  item selfcheck_launcher_hygiene "$out"       # 29) 起实例的脚本必须有 trap、不许按 bundle id 广播
  item selfcheck_p95_crosscheck_shapes "$out"  # 33) p95 那半句由两把尺子合判，七种形状各判一次
  item selfcheck_update_table_caveat "$out"    # 34) update 表窄分布形状不许被当成主线程忙时
  item selfcheck_frame_table_budgets "$out"  # 42) 逐帧三张表各配自己的预算（寿命不判单帧，防「100% 超预算」）
  item selfcheck_pulse_window_scope "$out"   # 41) FramePulse 的总数是生命期累计：不许冒充本窗口（§M 因此降级未定）
  item selfcheck_trio_agreement "$out"       # 39) ≥3 趟那半句「且取值一致」：十种形状各判一次（idle 档极值不当判据的正反一对在内）
  item selfcheck_cadence_two_budgets "$out"    # 35) p95 判据必须两把预算并排印、且真会分歧
  item selfcheck_md_tables_unbroken "$out"     # 30) markdown 表格不许有夹在行中间的裸续行
  item selfcheck_record_bounded "$out"          # 43) 录制要有墙钟兜底：被测进程一消失就当场判废，别永等
  item selfcheck_covered_evidence "$out"        # 44) 三张关键表都没行数的一趟，不许被印成「✓ 第 i 趟完成」
  item selfcheck_warmup_dimension "$out"        # 53) 第七维·预热：etime 解析要对、未预热要拒、启动档不参与（列在最后：新维度不与既有项抢顺序）
  item selfcheck_update_caliber_one_rule "$out"  # 54) app-update 只有一个口径：sidecar 与表同 n、少计方向要拒、回落不再截 40
  item selfcheck_refused_not_pooled "$out"  # 55) 被当场拒收（有 REFUSED）的那一趟混不进散布；没 REFUSED 的必须还能读成可用
  item selfcheck_chain_guard_one_per_tree "$out"  # 56) 同树只许一条链：无链要放行／同树假链要点名拒跑／跨闸要出声（列在最后：新项不与既有项抢顺序）
  item selfcheck_path_display_keeps_the_tail "$out"  # 57) 归属行两头有牙：长路径保住文件名、短路径一字不改
  item selfcheck_chain_message_names_the_compared_tree "$out"  # 58) 拒人行印的就是比对那棵树（印与比同形）+ is_ours 双向
  item selfcheck_long_sleep_defers_the_trap "$out"  # 59) trap 的时效性：长 sleep 确实拖住（反例）／分片睡 8 秒内收尾（正例）
  item selfcheck_trapped_scripts_have_no_long_sleep "$out"  # 60) 带 trap 的 perf_ 脚本里不许留长 sleep（要长等就走 nap）
  item selfcheck_refused_trace_reclaim "$out"  # 61) 判废趟的 GB 级原始 trace：被拒∧超同档线才点名、默认只印、显式授权才删（#70）
  item selfcheck_hang_retry_policy "$out"  # 62) 只有录制挂死值得同窗补一次：按批封顶、挂死计数抹不掉、meta 键双向（#55）
  item selfcheck_update_stack_attribution "$out"  # 63) 长 update → 调用栈归因：同窗才 join，四种"不许算"各判一次（#43/#73）
  item selfcheck_blame_wiring "$out"  # 63b) 归因档的接线：附加仪器作为一个参数进 xctrace、导出改名不盖认证档
  item selfcheck_main_drift_reading "$out"  # 64) 基线新鲜度：落后 main 几笔**产品码**（只数产品码、乱 rev 报未取到、换 cwd 仍是 1）（#76）
  item selfcheck_batch_product_identity "$out"  # 65) 排程器那行「被测产品码」抄的是 manifest 那枚二进制，不是 HEAD（#80）
  item selfcheck_slot_owner_states "$out"  # 66) 实例归属分类各态各判对（补上「补测产物树」这一态）＋给那个没人读过的 --probe 补读者（#81）
  item selfcheck_switch_cleanup_names_no_target "$out"  # 67) switch 收尾提示：没有 pid 就不许叫人去退（实跑六页全印了空 pid 的那格）
  item selfcheck_artifact_locator_fork_honest "$out"  # 68) 同名产物分在三处时按形状说对话（互补／包含），不许替人挑一份（#89，清树的前置）
  item selfcheck_artifact_locator_names_the_tree_copy "$out"  # 69) 分叉里点名本树那一份：它是 report／一致性尺唯一认得的（换树不冒这句）
  item selfcheck_locator_census_counts_only_batches "$out"  # 70) 「数了几批」由尺答：夹具树里的合成 -runN 不进批次分母、容器第二层算数、空根要判错（#90）
}

# 反例分块（每块一个文件，宿主只留编排）：那个 for 必须在 cmd_selfcheck 之前，
# 因为编排器一跑就要点到里面的函数名。
# shellcheck source=/dev/null
for _part in ruler_shapes gates eligibility launchers tables chain trap windows hygiene context attribution; do
  source "scripts/perf_selfcheck_${_part}.sh"
done
unset _part

# 单独执行本文件 = 把函数定义一遍就退出，**一项都不测**。
# 09-25 12:00 现场：我拿 `perf_selfcheck.sh context attribution` 当命令跑，
# 拿到「零行输出 + rc=0」，那形状与"这两块全过"一模一样——空结果伪装成通过（同族又一次）。
# ⇒ 库就是库：被直接执行时要出声、要判错，不许留一个看起来像通过的退出码。
if [ "${BASH_SOURCE[0]:-}" = "$0" ]; then
  echo "!! perf_selfcheck.sh 是被 source 的库，单独跑**一项都不测**——别把'一行都没印'读成通过。" >&2
  echo "   要跑全部项：./scripts/perf_harness.sh selfcheck" >&2
  exit 2
fi

