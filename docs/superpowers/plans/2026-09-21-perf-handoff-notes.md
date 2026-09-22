# 性能侧 → UI 总工的交接备忘（从 2026-09-20-perf-followup-tickets.md 搬出来）

> 搬出原因：`SelfScanDogfoodTests` 的 ≤800 行棘轮**分母含 `.md`**、ceiling=0，
> 工单本体涨到 884 行把门禁判红过一次（2026-09-21）。**拆，不拧阈值。**
> 工单本体：[`2026-09-20-perf-followup-tickets.md`](./2026-09-20-perf-followup-tickets.md)
> 本节记的是**随包落地而更新**的现状（A~G 各条 + 存量复扫 + 性能侧欠账）。

## 给 UI 总工的性能侧交接（12:40 更新，随包 2/3 落地）

### A. 还欠着的迁移：一条都没动

`python3 scripts/trace_report.py migration` 现扫现报，此刻：
**粗粒度读点 16 处 / 上限 16 / 细粒度读点 0 处**，收益分级 **承重 10 / 顺手 6**。
也就是说 M0 交付的细粒度契约（`monitor.pulse.value` / `curve.value` /
`cpuRanking.value` / `ledger.value.*` …）**至今零消费**——基座的收益还没进任何一屏。

- 入口都在 `Views/**`（我不写，按 21:15 裁定归你派发）；
- 每处给什么符号，`migration` 报告逐行点名，不用再抄我手写的表；
- 已核对：粗读点与细格挂在**同一个** `MachSystemMonitor`（`state.monitor`）上，
  照抄路径能编译；
- 迁移时两条禁令（都已有 baseline-0 守卫在守）：
  ① 别在页面里对 `curve.value.suffix(...)` / `cpuRanking.value.sorted(...)` 再切一遍再排一遍
     （`reslicePattern`，基线 0）；
  ② 别把裸内存量直接渲染（`rawMemoryEvidencePattern`，基线 0）——
     `Text(monitor.memory.value.usedBytes)` 会在没数据时显示成 "0 B"，那是伪装成健康值的假读数。

### B. 渲染路径禁则：扫描面刚扩了一圈，基线跟着变

判据写的是"**body/Mark 内**"，而 `Design/**`（`GlassComponents` / `ChartTokens` /
`ReadoutKit` / `HealthAdviceCards` …）本身就是视图构造器，旧实现只扫 `Views/`。
撞见实证才修：i18n 台账把 `misses.sorted()` 放在 `Design/ReadoutKit.swift`，老扫描面数不到。

⇒ 现在 = **Views ∪ Design**，`dynamicNSColor` 基线 **56 → 64**：
**这是扩面、不是新增债**，多看见的 8 处全在 `Design/`，台账逐条带 `Design/` 前缀可复核
（`$TMPDIR/tcoder-perf-renderpath-debt.txt`，每条都是 `文件:行 + 原文`）。
从 64 起仍只许减不许增，终点 0。现量：`directFormatters 1/1 dynamicNSColor 64/64 fullSort 10/10 syncFileIO 2/2`。

### C. 一条会咬到 x6 的守卫 —— 已自己化解，留档说明它不是假警报

`.worktrees/x6-scale`（当时待并）把 `FramePulse` 拆成 411→367 行，
它的 `writeHeaderLocked()` 只写 **2 行**，而我这边是 **4 行**——含两条语义提醒：
"心跳最大间隔 = runloop 唤醒间隔，**不是**主线程占用时长"、
"要量占用请用 xctrace 的 `app-update` 相位；本文件的帧间隔 p95 才是 T1 的直接对象"。

⇒ **2026-09-21 复查：这条已经不复存在。** x6 已并入 main，拆分后的表头把两条提醒带着走了：
`FramePulse.swift` 368 行，两条 `writeLineLocked("# …")` 在 `:313` 与 `:315`。
合并后重跑的门禁：`Executed 909 tests, with 11 tests skipped and 0 failures`（含那条守卫）。
留这一条的意义：**守卫当时确实会在掉提醒的那一刻变红**，而红是对的——
提醒真差一点就掉了。搬动代码的人把它接住了，这就够了。

### D. 采样纪律（已进闸门，不靠自觉）

`TCODER_I18N_RUNTIME_LEDGER` 设了再量帧率，量的是台账自己的开销
（`record()` 在渲染路径上、按 200 次节流写盘）。⇒ `perf_preflight.sh` 现在直接**拒跑**，
并把它的状态写进 `measurement-context.txt`。日常使用不受影响（不设即零成本）。

**2026-09-21 追加**：交互档（T1）的开录时机换了，跑的人只需知道一件事——
**你只管持续滚，脚本检测到你正在滚才开录**，不用猜时机、不用等发话。
旧写法"先等 8 秒静默再倒计时"把前三轮全烧成了 `窗口内没人`。
另：静默探针从此只有一把（`perf_preflight.sh` 的 `quiescence_probe`），
排程器里再出现自己 `swiftc` 编探针会被 selfcheck 第 20 项当场抓住。

### E. 一条通用红线：**落一个证据标记，同一笔里就必须有读者**

今天抓到自己两次"记了但没人看"：
- `no_human_input_during_window=1` / `contaminated_by_human_input=1` 写进 meta，
  **全仓 grep 只有一个写点、零个读者** ⇒ "整窗没人滚"的样本照样打印「有资格答 T1」。
  我三轮作废样本是靠**自己读终端**判掉的，工具一次都没拦。
- `PROVENANCE_NOTE=…` 变量赋值出不了 `$(…)` 子 shell ⇒ "按 tree 放行必须留痕"这条
  我自己定的规矩，在实际路径上一句不印，闸门照样放行。

⇒ 凡是"把异常写进某个文件/变量以示诚实"的改动，落地那笔要顺手 `grep -c 键名`：
   **写点数 + 读点数 ≥ 2 且分布在不同文件**，否则那条记录只是让我安心。
   退出码比表头文字更可靠：脚本化的比较只看 rc，表头多一行 ⚠ 会被下一环当绿灯放过
   （`perf_trace_summary.py` 现在对"声明与复核互相矛盾"的样本 **rc=3**）。

### E′. 存量复扫（2026-09-21 22:04，用守卫自己的口径现扫现报）

```
扫描 45 个文件（Views + App），粗粒度读点 16 / 上限 16 / 目标 0，细粒度读点 0
收益分级：承重 10 / 顺手 6
渲染路径：directFormatters 1/1  dynamicNSColor 64/64  fullSort 9/10  syncFileIO 2/2
```

- `fullSort` 已经掉到 **9**，我这头把基线从 10 拧到 9（`96da24d`）——
  **棘轮只许变紧**：留着那一格隐形余量，下一个人在别处新加一处排序会显示成"10/10 没涨"。
- **`dynamicNSColor 64` 是扩面后的数，不是新增债**（Views ∪ Design，台账逐条带前缀可复核：
  `$TMPDIR/tcoder-perf-renderpath-debt.txt`，每条 = 文件:行 + 原文）。从 64 起只许减，终点 0。
- 16 处粗读点的**逐行入口**不用抄表：`python3 scripts/trace_report.py migration` 现扫现报，
  每处都给"换成哪个细格"；其中 3 处不是 1:1 换名（要把整份快照递给别的视图），
  **必须改接收方**，原地换写法等于没迁。

### A′. 第一份"有资格"的 T1 读数（缺陷 #47：交互期掉帧，且主线程有 168 ms 孤例）

样本 `.scratch/tcoder-perf-a9aed5c-interact-run1`（rev `f9d4a43`，`period=interaction`、
`input_source=synth`，上下文 `load1=5.90/15`、`并发重活=无`、`scrollWheel=0.02s`
—— 最后这条是"滚动确实落在被测窗口里"的证据，不是"投了个寂寞"）：

| 指标 | 这份读数 |
|---|---|
| 迟到帧 | **42 / 20 s = 2.10 每秒**（帧时长 8.33~41.67 ms） |
| HTR | 6.67 ms/s（Apple 口径"可察觉·需排查"） |
| 实测出帧 | **p50 53 / p95 93 每秒** ← 滚动时根本没跑到 120 Hz 档 |
| app-update | **p50 1.73 / p95 3.44 ms**，但 602 个里有 **13 个超预算，最长 168.3 ms** |
| render 超预算 | 8 / 1129 帧 = 0.71%（相位 p95 6.42 ms 仍算健康） |
| potential-hangs | **0 次** |

**怎么读这张表（三条都不是套话，每条都改变结论）**
1. **主线程整体不是瓶颈**：p95 3.44 ms。所以 42 个迟到帧里绝大多数**不是**"算不出来"，
   而是渲染/合成侧或节奏问题 —— 别去优化 `_updateViewGraph` 的常数。
2. **"超 20.2 倍"那种单数字会把两件事同时说反**，所以我把它拆了（`9f857e4`）：
   真正该查的是**那 13 个超预算 update 里最长的 168 ms**——一次 168 ms 就是肉眼可见的一次卡顿，
   而 `potential-hangs=0` 说明它短于 hang 阈值，**只有这条拆分口径能把它露出来**。
3. **出帧 p50 只有 53/s ⇒ 这份读数不在 120 Hz 档内**，所以 hitch/HTR 的档位词一律标
   「不判档，只记形状」（`8d335ef` 起）。**但"滚动时达不到 120 Hz"本身就是 T1 要治的症状**，
   两件事别混：档位词不判 ≠ 没问题。

**假设与可复验的因果实验（我不写 `Views/**`，这条按裁定归你派发）**
粗读点 16 处未迁（`monitor.latestSnapshot` / `monitor.history` 这类**无等值闸门**的整份发布），
心跳 1.5 s 一次 ⇒ 20 s 里约 13 次 tick。观测到的"超预算 update"**恰好 13 个**，
与 tick 数同量级 —— 这不能证明因果，但给出一个便宜的判决实验：

> **只迁 A 组里的 2 处承重项**（`LiveReadings.swift:25/26` → `monitor.pulse.value` /
> `monitor.curve.value`），然后原样重跑三趟 `MODE=interact INPUT=synth`。
> 判据：超预算 update 数从 13 显著下降（趋近 0）且出帧 p50 上移 ⇒ 因果成立，
> 剩下的按同一形状排；若纹丝不动 ⇒ 假设被证伪，转去查合成侧（我把这条记进"已排除"）。
> 复测命令见 G 段，两批的 `Sources` tree 要各自记 sha，别拿旧头部交新结论。


**第二趟到手后，先把"能定的"和"不能定的"分开（22:41）**

| 趟 | 迟到帧/20s | update p95（超预算次数/最长） | 出帧 p50/p95 | 上下文 |
|---|---|---|---|---|
| run1 | 42 | 3.44 ms（13 / 168.3 ms） | **53 / 93** | load1 5.90/15、无并发重活 |
| run2 | **5** | 3.24 ms（1 / 10.1 ms） | **41 / 57** | load1 4.29/15、无并发重活 |

- **现在就能定的**：两趟**都不在 120 Hz 档**（出帧 p50 41~53/s，`input_source=synth`、
  `scrollWheel=0.00~0.02s` 证明滚动确实落在被测窗口）。
  ⇒ 用户那句"达不到 120 帧"**第一次被量下来**：滚动期间合成就没进过 120 Hz 节奏。
  这一条不依赖迟到次数，所以可以先写。
- **现在不能定的**：迟到计数在两趟之间差 **8 倍**（42 vs 5）。
  ⇒ 任何"交互期 hitch = X"的单趟数字都不许引用；要么凑到 3 趟同量级，
  要么把差异本身当变量查（两趟的差别只有：run1 落在别的会话刚编译完的余温里、
  run1 出帧更高说明画面动得更多）。
- **主线程依旧不是瓶颈**：两趟 update p95 都在 3.2~3.4 ms，超预算 13/1 次都远低于迟到帧数。

**两个我自己提出、又被自己的测试否掉的假设（写明，免得别人再走一遍）**
1. ~~"13 个超预算 update ≈ 20s 里 13 次心跳 tick"~~ ⇒ **否**：按时间排序后相邻间隔是
   `58 / 167 / 166 / 142 / 93 / 78 / 946 / 1642 / 1721 / 2792 ms`（中位 876 ms），
   而且 11.2~12.6 s 之间**挤了 7 个** —— 不是 1.5 s 节律，是**随滚动来的爆发**。
   所以 A 组那 2 处迁移**不是这个症状的首要嫌疑**（实验仍值得做，但预期落空要认）。
2. ~~每个滚动事件 `cancel + 新建 Task` 的 `notePointerStreamActivity`~~ ⇒ **按预登记的判据划进"已排除"**：
   `notePointerStreamActivity / swift_task_create / task_cancel / withAnimation`
   在这份 interact 的 `time-profile.xml` + `threads.txt` 里**各出现 0 次**。
   **限定条件要写清**：这份 profile 只有 352 个主线程样本 / 42 s，
   对"每事件几十微秒"的开销不敏感 —— 这条是"未检出不等于不存在"，
   真要判死得换 `os_signpost` 或数 Task 创建次数，别拿这个 0 去宣布无罪。

**那么现在最像的解释**：迟到帧的 update 相位整体很快（p95 3.44 ms），
瓶颈在**渲染/合成侧**（出帧 p50 53/s、`UC::DriverCore::continueProcessing` 占 53.1%、
`CA::Transaction::commit` 链 34%），
而 13 个超预算 update 是**爆发式**的 —— 与"滚动时整片重算"同形。
下一步该做的是把 `render 超预算` 与 `update 超预算` 的**时间对齐**（同一批迟到帧里
谁是先超的），我这边把这条做成尺子；`Views/**` 侧的迁移实验按 A 组照常排。

### F. 反向复用同一把尺子之前，先问它的失败值落在数轴哪一端

idle 档判"够静默"是 `q >= 8`；我照同一把尺子做交互档"有人在动"，顺手写成 `q < 3` ——
但探针失败时打的是 `静默=-1.00s`，**-1 在数轴上最小**，
于是"量不到"精确地变成"最有人在动"，一条**恒真**的开录闸门。
现在有一道与数值无关的 `probe_usable()` 挡在前面，
元测试还**反向承认**哨兵确实骗得过原判定（哪天骗不过了，是守卫的理由消失了，连守卫一起改）。

### G. 你们每并一批 UI 改动之后，请自己重跑一次（10 分钟的事）

```bash
cd TcoderMonitor
./scripts/build_app.sh release                                   # 必须：新闸门要求产物 rev == 树头
./scripts/perf_wait_window.sh $(git rev-parse --short HEAD) 3    # T2 心跳期 ×3（只等窗口、不绕闸）
MODE=interact ./scripts/perf_wait_window.sh $(git rev-parse --short HEAD) 3   # T1 交互期：需要真人滚
./scripts/perf_harness.sh switch /tmp/tcoder-perf-$(git rev-parse --short HEAD)-switch  # T4 逐页冷启动
./scripts/perf_harness.sh report <上面任一目录>                   # 表头会写明期间与产物 rev
```

**为什么必须重跑**：`measurement-context.txt` 与 `meta.json` 现在都记**产物自己的**
`rev`（`dist/RELEASE_MANIFEST.env`），不匹配就直接拒采。
今天实测过一次误标：12:20 我拿 `9e60fec` 的二进制量到"T2 三趟一致"，
而当时的头已经并进了 10 个 i18n 提交（19 个 `Sources/` 文件）——
**那三趟不属于新代码**。这条闸门就是为这件事加的。

### F. 性能侧欠大家的（我在做，不用你动）

1. **T1 仍未举证**：交互期 hitch=0 / p95≤8.4ms 需要真人滚动，已排好命令，等用户配合。
2. **§1"改动前基线"仍未成立**：要按 §4.1 在旧 rev 的独立产物上受控重测，
   而尺子现在还量不了"别人的构建"（`TARGET_BINARY` 固定指本树 `dist/`，
   且新 provenance 闸门要求 rev 等于我的 HEAD）⇒ 需要先加
   `MEASURE_TARGET=<路径>` + `MEASURE_REV=<完整 sha>` 的成对入口（只给一个就拒）。
   在那之前，任何"从 X 降到 Y"的话都不许说（表头已经自己声明对照列未受控）。
3. **外部争用看不见**：同 rev、同实例、五维全同的三趟里 hitch 是 43/3/1，
   而 `app-update` 稳定 2.x ms ⇒ 差异在显示系统层面。已登记 spec §7 第 8 条；
   要收这一维得给 preflight 再加一维（例如整机出帧基线），本轮没做。

## H. 22:56 复扫：**"折进正在重写的批次"这条裁定的前提已经断了**（需要新的派单）

01:09 的裁定原文是"那 10 处承重粗读迁移折进**正在重写这些文件的批次**，由总工顺手做"。
并完 main（`e929a47`，58+25 个提交）之后按两边现量重算，**交集 = 0**：

| 两边总体 | 现量 |
|---|---|
| 16 处粗读点所在文件（守卫自己的正则现扫） | `LiveReadings.swift` ×2、`PerformanceView.swift` ×10、`DashboardReadouts.swift` ×3、`ProjectSidebar.swift` ×1 |
| 主树此刻在途的 11 个文件 | `CodeMetrics*`、`CodeRiskView`、`ContributorsView`、`FileSystemCodeAnalyzer`、`Localizable.strings`、`AGENTS.md` 等（**代码规模 / Git 贡献者两页 + 尺子**） |
| 交集 | **0 个文件** |

⇒ 含义很直白：**现在没有任何一个在途批次会碰到这四个文件**，
"折进去顺手做"已经不可能顺手——这一批要么单独派，要么继续欠着。
（上一轮"10 处排序债里有 5 处正被重写"是成立的，那批已落且**没有顺手清掉**，
所以这条裁定不能靠"再等下一批"自动兑现。）

同时报一条已经还上的：渲染路径台账现扫 `dynamicNSColor 62/64`，
台账自己点名两格隐形余量 ⇒ 棘轮已拧到 **62**（`directFormatters 1/1`、`fullSort 9/9`、
`syncFileIO 2/2` 本来就零余量）。**四条里留一条松，就是给下一次"没涨"留口子。**

## I. 【可直接派】16 处粗读点迁移单批工单（2026-09-22 02:22 现扫生成，rev `8fea49d`）

用户 2026-09-22 裁定：**性能侧单独起草一批、交 UI 总工执行**（我不写 `Views/**`）。
下面这条清单是 `python3 scripts/trace_report.py migration` 在 rev `8fea49d` 的**原样输出**
（口径直接读守卫自己的正则，不复制第二份），行号只是当下位置、**符号是稳定的**。

### 一、13 处是 1:1 换名（无判断，照抄即可）

| 文件 | 成员（类型.成员锚点） | 从 | 换成 |
|---|---|---|---|
| `Views/PerfLogs/LiveReadings.swift` | `LiveReadings.body` ×2 | `monitor.latestSnapshot` / `monitor.history` | `monitor.pulse.value` / `monitor.curve.value` |
| `Views/Shell/DashboardReadouts.swift` | 总览读数 ×3 | `latestSnapshot` ×1、`history` ×2 | `pulse.value`、`curve.value` |
| `Views/Shell/ProjectSidebar.swift` | 侧栏 footer ×1 | `monitor.latestSnapshot` | `monitor.pulse.value` |
| `Views/Performance/PerformanceView.swift` | 性能页 ×7 | `history` ×2、`latestSnapshot`、`lastSampleAt` | `curve.value` ×2、`pulse.value`、`pulse.value.sampleAt` |

### 二、6 处"顺手"（帧率上测不出差异，但棘轮要清零才能翻闸门）

同一文件 `Views/Performance/PerformanceView.swift`：
`trackedGroups → groupRanking.value`、`processMetricsTruncated → ledger.value.metricsTruncated`（两处）、
`measuredProcessCount → ledger.value.measuredCount`、`topProcesses → cpuRanking.value`、
`processesByMemory → memoryRanking.value`。
**为什么单独标出来**：这六个宿主属性早就走 `write(\.x,…)` 等值闸门（值不换就不发布），
所以"只迁这六处"在帧率上等于没做——分级不是我拍的，是守卫从 `publish()` 现读 28 行算出来的。

### 三、3 处不是换名，是"把整份快照递给了别人" ⇒ 要改**接收方**

`SampleContext.from(snapshot:)`、`DashboardLiveReadout.snapshot`（别名属性）、
`SidebarLiveFooter` 把快照递给 `LiveCPUBadge`。
**原地换写法等于没迁**：只要参数类型还是整份快照，接收方仍然在每次发布时重建。
这三处的正确做法是把入参换成它真正读的那几个格。

### 四、验收（不接受口头完成，命令必须报 0）

```bash
cd TcoderMonitor && python3 scripts/trace_report.py migration | sed -n 2p
# 期望：粗粒度读点 **0** 处 / 登记上限 16 处 / 细粒度读点 **> 0** 处
./scripts/locked_build.sh test --filter PerfInvalidationRatchetTests   # 消费闸门必须翻绿
./scripts/locked_build.sh test --filter PerfMainThreadBudgetTests       # 假迁移守卫（见下）
```

三条红线：① **细格结果上不许再 `Array(….suffix(n))` 或 `.sorted{}`**——那叫假迁移，
守卫 `testPreparedCellsAreNeverReslicedOrResorted` 会当场抓（已进 main）；
② 不许顺手改视觉语义（这一批只做数据接线）；
③ 迁移与视觉改动**分提交分门禁**（一人接两条线之后这条尤其重要，不能自己给自己的两套口径放行）。

### 五、迁完请顺手给我一个判决实验的窗口（3 分钟，不需要你操作）

今晚第一份"上下文全合格"的交互期读数里，**602 次 update 有 13 次超 8.333 ms 预算、最长 168 ms**，
而 13 与"心跳 1.5 s 在 20 s 里约 13 次 tick"同量级——**不足以下因果结论**。
所以这批迁完之后我按同一份尺子原样重跑三趟：超预算 update 趋近 0 ⇒ 因果成立；
纹丝不动 ⇒ 我这个假设证伪，转查渲染/合成侧并记进"已排除"表（缺陷 #47 的另一半）。
