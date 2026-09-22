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
2. **§1"改动前基线"这条我降级了，理由要说清**（2026-09-22 02:26 现查）：
   封存的对照组 `/tmp/tcoder-before.app`（rev `415f0f0`、sha `54005bc4…`）**已经不在了**
   ——`/tmp` 被清过一次（就是那次 103 GB 之后），所以"补测改动前"要先在 detached 树
   重打一份旧 rev 的 release 产物，那是**一次编译风暴 + 一个测量窗口**的代价。
   ⇒ 判定不依赖它：**"到不到 120Hz"用的是绝对预算（8.333 ms/帧、app-update ≤4.0 ms）**，
   对照列只影响"从 X 降到 Y"这种说法，而那种说法本来就被表头自己声明为"未受控、不判趋势"。
   所以包 5（`MEASURE_TARGET` + `MEASURE_REV` 成对入口）**继续挂账但不排窗口**，
   除非哪天要对外引用"优化前后对比"，那时再一起做。
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

### 一、16 处的正确拆法（三节不重叠，加起来正好 16）

**16 = 13 处换名 + 3 处改接收方**；而"顺手"是**换名那 13 处里的 6 处**，不是第四类。
（我上一版把"13 换名"与"6 顺手"并列成两类，读者会加出 19 处——dispatch 单里这种错最伤人。）

| 类别 | 数量 | 逐条（`类型.成员` 为锚，行号只是当下位置） | 从 → 到 |
|---|---|---|---|
| A. 换名·承重（每 tick 必然换值，收益真实） | **7** | `LiveReadings.body` 的 `history`；`DashboardReadouts` 两处 `history`；`PerformanceView` 两处 `history` + `latestSnapshot` + `lastSampleAt` | `history → monitor.curve.value`；`latestSnapshot → monitor.pulse.value`；`lastSampleAt → monitor.pulse.value.sampleAt` |
| B. 换名·顺手（宿主走等值闸门，单独迁它在帧率上测不出差异） | **6** | 全在 `PerformanceView`：`trackedGroups`、`processMetricsTruncated`×2、`measuredProcessCount`、`topProcesses`、`processesByMemory` | → `groupRanking.value` / `ledger.value.metricsTruncated` / `ledger.value.measuredCount` / `cpuRanking.value` / `memoryRanking.value` |
| C. 不是换名，是**把整份快照递给接收方** | **3** | ① `LiveReadings.body` 里 `SampleContext(snapshot: monitor.latestSnapshot, …)`；② `DashboardReadouts` 的别名属性 `private var snapshot: SystemSnapshot? { state.monitor.latestSnapshot … }`（下游按整份读）；③ `ProjectSidebar` 里 `LiveCPUBadge(snapshot: state.monitor.latestSnapshot …)`（子视图收整份快照） | 三处都在 `latestSnapshot` 的读点上；**原地换写法等于没迁**——只要参数类型还是整份快照，接收方仍每次发布重建。正确做法是把入参换成它真正读的那几个格 |

A + B = 13 处换名（守卫现扫里报的"承重 10 / 顺手 6"= A7+C3 = 10 承重，B6 顺手，总数 16）。

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

## J. 量不到帧率的时候，先跑这一条（2026-09-22 上午）

```bash
cd TcoderMonitor && ./scripts/perf_who_holds_the_slot.sh      # 只读，不 kill 任何进程
```

为什么要它：昨夜到今晨 T2/T1 采不满，闸门反复报"唯一那个实例不是本树起的"——
**这句话是对的，但不可行动**。这条命令把现场拆开报：每个实例的 pid、跑了多久、
是哪棵树开的、**那棵树还在不在**。今早实测到的三类：我自己、**主树的实例（有人在主树开工）**、
以及一个 **`verify-main` 工作树已被删、进程还活着 10 小时 51 分**的孤儿。
"在场即拒"的闸门就是会被这种停着的孤儿一路押死（同一形状昨天是一次 21h 的孤儿 xctrace）。

它同时钉死一件事：**读不到路径就说"不知道是谁的"，绝不允许报成"工作树已删除"**——
第一版就是这么错的（相对路径没解析 + BSD sed 的前导 `*` 不是通配），
而下一个人会照着那句诬告去 kill 别人正在用的进程。`--probe` 五种归属各判一次，双向。

## K. 【报给 WS-E / e2e 的主人】取证脚本漏下 6 个实例，把所有人的帧率测量押死了

02:50 现查（`./scripts/perf_who_holds_the_slot.sh`，只读）：

```
pid=9969  22:41  主树的实例      pid=20362  10:01  主树的实例
pid=12615 20:26  主树的实例      pid=21163   9:14  主树的实例
pid=19525 10:47  主树的实例      pid=21774   8:28  主树的实例
pid=67534 11:02:30  孤儿（工作树 .worktrees/verify-main 已删除）
```

**这 6 个的 `ppid` 全是 1（launchd）** ⇒ 起它们的那个脚本早就退出了，却没有收尾。
全仓审计（一条 grep，三个会起实例的脚本，2026-09-22 11:10）：

| 脚本 | trap 收尾 | 按 bundle id 广播退出 |
|---|---|---|
| `scripts/perf_wait_window.sh` | ✅ 有（今早刚修，见下） | 否 |
| `scripts/e2e_check.sh` | ❌ 0 | ✅ 2 处 |
| `scripts/verify_pages.sh` | ❌ 0 | ✅ 2 处 |

⇒ 不是"可能有泄漏"，是**只有排程器一家做对了**。性能侧顺手把这条立成守卫
（selfcheck 第 29 项：会起实例的 `perf_*` 脚本必须有 trap、不许按 bundle id 广播，
反向夹具也认得出坏形状），但**只扫自己名下目录**——并行多流时别家的红由别家自己修，
那才是 §K 这种报告存在的意义。

按 cwd 追到 `TcoderMonitor/`，能起实例的只有 `scripts/e2e_check.sh` 与
`scripts/verify_pages.sh`（AGENTS 名册里 `verify_pages.sh` 归 **WS-E 发布工程**，
所以我只报不改）。两家的收尾形状都是：

```bash
open "$APP"
…
osascript -e 'tell application id "com.tcoder.monitor" to quit' || true
```

两个问题叠在一起：
1. **没有 `trap`** —— 脚本被中断（超时、Ctrl-C、上游取消）就走到不了那行 quit；
   一次跑留一个，六次跑留六个。
2. **按 bundle id 广播退出**，一次最多退掉其中一个；而多车道同时开着实例时
   "退掉一个"根本不含"退掉我起的那个"。这也和 22:40 之后立的规矩相反
   （**只 TERM 自己起的那个 pid，绝不按 bundle id 广播**）。

后果是具体的：测量闸门"实例数恰为 1"从昨夜到现在没通过过一次，
**T2/T1 采不到不是因为尺子，是因为没人收尾**。

修法（10 行以内，两处同一形状）：`open` 之后立刻把**自己那个** pid 记下来
（`pgrep -fx "<该树绝对路径>/dist/Tcoder.app/Contents/MacOS/TcoderMonitor"`），
`trap '… 只 TERM 这个 pid …' EXIT INT TERM`。
`perf_wait_window.sh` 与 `perf_raise.swift` 已经是这个形状，可以直接照抄；
它跑了一夜，一次都没漏下实例。

## L. 第一份**进程内**帧脉冲读数，以及"两层失配互相掩护"的完整记录（09-22 11:35）

补了一条 `perf_harness.sh probe --start <秒>` 之后才拿到手的（此前**整条自动化里没有一处设过
`TCODER_PERF_PROBE=1`**，而 `open` 起的 App 又不继承调用方环境变量 ⇒ 这颗探针在无人值守链里
根本开不起来，只留一个读 `/tmp` 的入口在那里等一个永远不会出现的文件）。

rev `5742fa0`、release 产物、10 秒窗口：

| 字段 | 读数 |
|---|---|
| 刷新率 | **120.0 Hz**（`CGDisplayCopyDisplayMode(current)` 实读，不是硬编码） |
| 帧数 | 1029 |
| 帧间隔 | p50 **8.33** / p95 **9.91** / p99 10.24 / max 10.28 ms |
| hitch(>1.5×) | **0 次**（0.00/s），0/100 拍 |
| 尺子判定 | **未达标** —— T1 要的是 p95 ≤ 预算 8.41 ms，而这里 p95 = 9.91 ms |

### 这条读数真正值钱的地方是判据强度，不是数字本身

**`hitch(>1.5x)=0` 与 `p95 ≤ 8.4 ms` 是两条强度不同的判据。**
按 Apple 的 1.5× 定义这次"零卡顿"，但用户给的标准是 p95 ≤ 8.4 ms，这一条**没过**：
约 5% 的帧比 8.33 ms 的节律晚了 1.5 ms 以上——那正好是"卡卡的"这种体量的东西。
⇒ 规矩：**以后任何"零 hitch"都不许被写成"达到 120Hz 标准"**，两句话必须各自成立。
`perf_framepulse.py` 已经按严的那条判（它打印"未达标"而不是"0 hitch"）。

### 两层失配怎么互相掩护的（值得单独记，因为两条各自都不起眼）

1. 生产者写的行是 `hz=120.0(CGDisplayCopyDisplayMode(current))` —— **括号里套一层括号**；
   python 解析器的来源组写的是 `[^)]*`，撞上真产物就**整行解析失败**。
2. 本该抓住它的两处对账，各自都没抓住：
   · 自测第 6 项喂的是手搓的 `hz=120.0(合成)`（没有第二层括号）；
   · Swift 侧 `PerfFramePulseRulerTests` 用的是 `FramePulse.shared.summaryLine`，
     而那是个**没 startIfNeeded() 的单例**，来源字段是默认值「未测」——
     **它比的是生产者的另一条分支**，所以一路绿。
3. 而这一切长期不可见，是因为**没有第三条路真的产出过文件**（探针开不起来），
   "文件不存在"永远先挡住解析这一步。

⇒ 三条判据：**夹具必须抄真产物**（现在两处都改成逐字抄来的那一行，并加了反向证明：
旧图案对真产物命中数为 0，所以这条钉真的会红）；**"对账"要确认对的是同一条分支**；
**仪器要两端都验**——能起得来、且起出来的东西读得懂。

### 边界（别把这条读成 T1 结论）

idle 档、非交互；机器上同时有 8 个别人的实例在跑；实例是直接 exec 起来的（不是 LaunchServices）。
⇒ 它是**量级线索与仪器自检**，不是 T1 的验收数；验收数仍要在干净窗口下由
`interact` 档 + xctrace 的 hitches/updates 表出。

## M. `pulse` 档三趟一致：p50 正好 8.33 ms，但尾巴稳定地晚 ~0.8 ms（09-22 12:00）

新档 `perf_harness.sh pulse <秒>`：**边投合成滚动（8 ms/拍 ≈125 Hz）边读进程内帧间隔**。
为什么要单独一档 —— 用户的验收口径是"**p95 帧间隔 ≤ 8.4 ms**"，而 xctrace 的 `hitches` 表
只列**超预算**的那些帧，"全部帧的分位数"这一列它压根没有；逐帧记间隔的只有 FramePulse。

| 趟 | 帧数 | p50 | **p95** | p99 | max | hitch(>1.5×) |
|---|---|---|---|---|---|---|
| r1 | 1376 | 8.33 | **9.17** | 9.31 | 9.34 | 0 |
| r2 | 1680 | 8.33 | **9.04** | 9.25 | 9.33 | 0 |
| r3 | 1319 | 8.33 | **9.25** | 9.33 | 9.34 | 0 |

三趟跨度只有 0.21 ms ⇒ 这不是噪声，是一个**稳定的形状**：约一半帧正好落在 vsync 边界上（8.33），
另一批稳定地晚 0.7~1.0 ms；**没有任何一帧晚到 1.5×**（12.5 ms）—— 也就没有"丢帧"。

⇒ 两句话必须分开说，谁也不许替谁背书：
- **"交互期没有丢帧"**：支持（三趟 × 4 千余帧，0 次 >12.5 ms）。
- **"p95 ≤ 8.4 ms"**：**不满足**，差约 0.7 ms，且判据按用户给的那条算就是未达标。

**还没做的事（不能跳过）**：这一列只有**一把**仪器在量，而 CVDisplayLink 回调的送达时刻本身
是否等于"上屏时刻"我没有独立验证。⇒ 要用 xctrace 的 `displayed-surfaces-per-second`
在**同一份合成滚动**下做一次交叉核对（链条已挂在 `perf_harness.sh interact`，只差窗口）。
若两条仪器的 p95 相差 ~1 ms，那么这条判据应该改用哪一种必须重新拍；
在此之前，任何人（包括我）拿这组数字宣布"达到 120Hz"或者"没达到"都算越证。

条件如实记在每趟的 `pulse-context.txt`：`rev=f6bb3d7`、输入 `synth@8ms`、
**本机同时有 9 个 Tcoder 实例**（主树漏下的那些，见 §K）、实例是直接 exec 而非 LaunchServices。

### 顺带三处修好
1. `start_synth_scroller` 的第 2 个位置参数**不是秒数**（内部按 `<秒> <pid> <像素> <间隔>` 传），
   我按位置传 ⇒ 它照默认投了 95 s，而被测实例 15 s 就 TERM 了：那 80 秒里光标底下是谁都可能
   被我的合成滚动打到。已改成 `SYNTH_SECS=` 传秒，并给投事件器加 **liveness 收手**
   （目标进程不在了立刻 break，每 20 拍查一次）。
2. 防抢光标的静默闸原来要 30 s，而它**分不清"人在动"与"上一趟我在动"** ⇒ 连跑时自己挡自己
   （实测挡掉两趟）。改成 15 s 并把这条理由写进代码：它管的是"不打扰人"，不是测量有效性。
3. 合成输入器从 `perf_wait_window.sh` 搬进 `perf_probes.sh`（两个消费者共用一份实现：
   排程器的 interact 档与 pulse 档），目标 pid 改由调用方传 —— 不再是"只有排程器能用"。

## K-2. §K 那条缺陷**正在现场复发**（12:21，比历史泄漏更严重：它还在长）

```
pid=37793 已跑 05:11   主树的实例
pid=38452 已跑 04:25   主树的实例
pid=39252 已跑 03:38   主树的实例
pid=40149 已跑 02:52   主树的实例
```
四个实例、**相隔约 45 秒**依次起、没有一个收尾 ⇒ 这不是"上次跑完忘了关"，
是**有个循环正在反复起实例而不收尾**（`e2e_check.sh` / `verify_pages.sh` 那两个 `trap=0`
的形状，见 §K）。上午那次清完之后 12:10 我才能连采两趟 idle；现在它又涨到 4 个，
而 T1 的闸门要求"实例数恰为 1"——**只要这个循环还在跑，这台机器上所有人都量不到帧率**。

请起它的那一流现在就补两件事（§K 里有可直接照抄的形状）：
① `open` 之后记下**自己那个 pid**，`trap '… 只 TERM 这个 pid …' EXIT INT TERM`；
② 收尾不要用 `osascript … to quit`（按 bundle id 广播，多实例时"退掉一个"不含"退掉我起的那个"）。
在我这一侧：`perf_wait_window.sh` / `capture_pages_isolated.sh` / `perf_harness.sh pulse`
三处都已经是这个形状，跑了一夜加一个上午，**没留下过一个实例**。
