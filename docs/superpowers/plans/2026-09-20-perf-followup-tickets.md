# 性能追加工单（第四轮 120Hz → 现由接管的总工一人执行，见 §0.4）

- 发件：第四轮「120Hz 性能」总工（`ws/perf-base`）
- 收件：~~第三轮「简约无界」UI 总工~~ → **22:40 起两条线合成一个人**（`AGENTS.md`「单人接管」）：
  下面所有工单直接由那一个人执行，不必再走「派给哪家」的形状；**执行清单见 §0.4**。
- 依据裁定：用户 2026-09-20 16:57（`AGENTS.md`「双总工协作裁定」）——页面树归 UI 总工派发与收回，
  性能侧只出工单、**不另起会话写 `Views/**`**。本文件就是那份工单，性能轮不动手写这些文件。
  **22:40 更新**：两条线的执行者已合成同一个人，所以"不碰 `Views/**`"这条对**性能侧的会话**仍然成立
  （我依然不写页面），但它不再是这批工单的前置障碍——工单与执行现在同属一人。
- 度量口径：本文件的**调用点计数一律以守卫自己的正则为准**
  （`PerfHitchGuardTests` / `PerfInvalidationRatchetTests`）。
  头一版写在 `main = 96761b7` 上、用顺手 `git grep | wc -l` 量的数已作废——**行数不是调用点**
  （同一次误判让我差点把绿的 main 报成红的，见 spec §1.4 之后的那段更正）。

## 0.0 先说一件拦路的事：main 那条红是我欠的，已经修好了

`165faa7` 的提交说明点名：main 上唯一那条红是性能轮随 `d5bb239` 带进来的
`scripts/trace_report.py` 涨到 **810 行**，撞本仓 ≤800 行棘轮（`SelfScanDogfoodTests`，
ceiling=0，扫描分母含 `.py/.sh/.md`）。你**没有改阈值**，只把它交回给我——处理如下（`f84a8f4`）：

- 按层拆成 `perf_trace_xml.py` / `perf_trace_metrics.py` / `trace_report.py`，**入口形状一字未动**，
  `perf_harness.sh` 零改动；拆前拆后对同一批真 trace 跑 6 种子命令，stdout 逐字相同、JSON 逐字节相同。
- 顺带兜出一个真缺陷：`cmd_switches` 引用不存在的 `cur` ⇒ **switch 档只要有真数据就崩**
  （空目录时提前返回，所以一直没暴露）。
- 新增 `scripts/perf_harness.sh selfcheck`（六项、合成夹具、零采样）。

**对三家的影响**：这条红卡的是**所有人的 `premerge_check`**（你们树上那 810 行是同一个文件）。
我这包一合，main 回全绿，你们的回执才谈得上重跑；我合入会让 main 前进一笔，
**请在合入之后再 merge main 并重取回执**。我这边只有这一包要落，之后到 M2 前不再动 main。

**测帧率的规矩（M1 交回时请照这个来，不照做的话数字我不收）**：

1. 测量前先 `scripts/perf_harness.sh selfcheck`，六项全绿才算"这把尺子可用"；它红了所有读数作废。
2. 交互期那一档（T1）**不做合成滚动输入**：本机 System Events 权限被拒，`CGEvent` 会被静默丢弃，
   只会量产"交互期 0 hitch"的假绿。两条正规路，各管一件事：

   ```bash
   # 路 A：xctrace 外部尺子（改前/改后**都能用**，所以前后对比只能走这条）
   ./scripts/perf_harness.sh interact          # 录制那 20 s 里请持续滚动被测窗口
   ./scripts/perf_harness.sh report <该目录>    # 表头会写「测量期间：interaction — 有资格答 T1」

   # 路 B：App 内常驻探针（只有装了 FramePulse 的改后产物有，改前对照物没有 ⇒ 只能单向看趋势）
   TCODER_PERF_PROBE=1 dist/Tcoder.app/Contents/MacOS/TcoderMonitor &
   # ……真实滚动 10 秒……
   ./scripts/perf_harness.sh probe --interaction   # 0 达标 / 1 未达标 / 2 没确认交互（只算 idle）
   ```

   **前后对比必须同路同档**：改前那棵封存产物 `/tmp/tcoder-before.app`（rev `415f0f0`）
   里根本没有 `FramePulse`，拿路 B 量改后、拿路 A 量改前 = 两把不同的尺子比同一个数，不作数。
   不带 `--interaction` / 不写 `period=interaction` 的读数一律只算 idle——**别拿它当 T1 达标**。
3. 禁则棘轮现在每次跑都打「现量/上限」，并落一份 `$TMPDIR/tcoder-perf-renderpath-debt.txt` 台账。`dynamicNSColor` 已从 107 → 86（图表取色上提）→ **59**（`c60abbd` 颜色面积收敛又还掉 27 处）
   （两笔都是靠这条打印才现形的：`165faa7` 还掉 21 处、`c60abbd` 还掉 27 处，之前都藏在余量里没人看见）。
   四条现在**零余量**：`1/1 59/59 10/10 2/2`——再新增一处当场红。

## 0.0.1 给马上要跑九页取证的那位：`capture_pages_isolated.sh` 收尾改了

按 bundle id 广播的 `osascript … to quit` **已从两处删除**（`61cc6a5`）。它就是 WS-W 那轮
"我的实例活不过 10 秒、九页拍到 0 张"的元凶——它不分工作树、不分沙箱，命中全机所有实例，
也会顺手杀掉**正在跑帧测量**的那个（拍图锁挡不住，因为被杀的一方没在锁里）。

- 默认**不动任何进程**，只打印 pid 等人工 Cmd+Q；
- 想让脚本自己收尾：`CAPTURE_TERM=1 scripts/capture_pages_isolated.sh …`——
  它只对本脚本起的、且 `ps -o comm=` 核对到同一棵树的二进制的那个 pid 发 SIGTERM，核对不一致会拒绝；
- **拍图锁保留**（外观是全机状态、屏幕会互相遮挡，这两条互斥仍然成立），别绕过它。
- 另注：`SWITCH_MODE=single` 那一路仍在写用户真实的 `defaults` 域（`com.tcoder.monitor`），
  与"沙箱隔离"不同层——要完全不碰用户状态请用 `SWITCH_MODE=argv`。这条我没动（改形会碰你们的取证口径）。

## 0.1 【最高优先】细粒度契约目前消费数为 **0**

按守卫自己的正则复算 `main = a99f38b` 的 `Views/**` + `App/**`：

- **粗粒度读点 16 处 = 棘轮上限 16（零余量，再加第 17 处即判红）**
- **细粒度读点（`monitor.<格>.value`）0 处**

含义说白：**M0 服务侧把一次 tick 的写入面收窄了，但页面一格都没接**，
所以 1.5 秒一次的整棵重算**依旧在发生**，用户端目前**不会感到任何帧率改善**。
T1/T2 在这 16 处迁完之前不可能达标——**这不是"优化项"，是其余性能工单的前置**。

16 处逐条（迁完后由总工把上限往下拧，最终 0）。
**下面这张表是快照，行号会漂**——反复核对请用命令，它的正则与上限**直接从守卫源码里读**，
不存在第二套口径：

```bash
python3 scripts/trace_report.py migration              # 剩哪几处 + 该换成哪个格 + 按文件汇总
python3 scripts/trace_report.py migration --strict     # 还有剩余就非零退出（可挂自家门禁）
python3 scripts/trace_report.py migration --module-root ../<你的树>/TcoderMonitor
```

按文件汇总（2026-09-20 20:56 实测，`main = ee3dbdd`）——**归属照第三轮的页面分工**：

| 谁 | 文件 | 剩几处 |
|---|---|---|
| WS-O | `Views/DashboardView.swift` ×3、`Views/Shell/ProjectSidebar.swift` ×1 | **4** |
| WS-W | `Views/Performance/PerformanceView.swift` ×10、`Views/PerfLogs/LiveReadings.swift` ×2 | **12** |
| WS-P | 代码/Git/依赖三组页 | **0**（本项无工，其余 W/P/O 工单照旧） |

| 文件 | 行 | 现在这么读 | 该换成 |
|---|---|---|---|
| `Views/DashboardView.swift` | 332 | `state.monitor.latestSnapshot` | `monitor.pulse.value`（+ 需要的格单独读） |
|  | 443 | `state.monitor.history.count > 2` | `monitor.pulse.value.historyCount` |
|  | 444 | `Array(state.monitor.history.suffix(90))` | **`monitor.curve.value`**（已切好窗口，别再 `suffix`） |
| `Views/PerfLogs/LiveReadings.swift` | 25–26 | `monitor.latestSnapshot` / `monitor.history.count` | 入参改成 `PerfPulse`，或读 `pulse.value` / `curve.value` |
| `Views/Performance/PerformanceView.swift` | 45 | `monitor.trackedGroups` | `monitor.groupRanking.value` |
|  | 47 / 55 | `monitor.processMetricsTruncated` ×2 | `monitor.ledger.value.metricsTruncated` |
|  | 53 | `monitor.measuredProcessCount` | `monitor.ledger.value.measuredCount` |
|  | 54 | `monitor.latestSnapshot?.processCount` | `monitor.ledger.value`（系统/被测计数） |
|  | 63 | `Array(monitor.history.suffix(chartPointLimit))` | `monitor.curve.value` |
|  | 68 | `monitor.topProcesses` | `monitor.cpuRanking.value` |
|  | 69 | `monitor.processesByMemory` | `monitor.memoryRanking.value` |
|  | 104 | `monitor.lastSampleAt` | `monitor.pulse.value.sampleAt` |
|  | 105 | `monitor.history.count` | `monitor.pulse.value.historyCount` |
| `Views/Shell/ProjectSidebar.swift` | 411 | `state.monitor.latestSnapshot`（喂 `LiveCPUBadge`） | **经 `SystemReadings` 读 `cpu.value.usage` + `memory.value`**（徽章要两格；直接渲染 `memory.value.usedBytes` 会把 `--` 变成 `0 B`，见 §0.6 末尾那条更正） |

> 顺带：`isCollectingForDisplay` 也是 **0 读取**（见 W-6）。
> 这两个 0 是同一件事的两面——**新契约没接，旧入口没撤**。

**「完成」现在有机器定义了**：`PerfInvalidationRatchetTests.consumptionGateOpen`（当前 `false`）。
闸门是四态判定，除「粗读点 0 / 上限 0 / 细读点 > 0」这一种之外，没有任何状态能静默绿：
债还在 → 每次跑测试都打印「这轮的收益还没在页面上落地」；债清完却没人翻闸门 → 判红（防长期挂着）；
**提前翻闸门 → 判红**。所以「16 处迁完 + 上限拧成 0」是这套工单里唯一一条**能改变 T1/T2 可否判定**的项。
16 处迁完后请回报，由我把上限拧成 0 并翻闸门，然后才做帧率复测。

## 0.2 【派工单】三家合完之后，这 16 处仍无人做——请按流重派（用户 21:15 裁定：仍归 UI 总工派发）

现状不是"差不多做完了"，而是**这项目前一行未动**。三个独立来源数到同一个数：

| 量法 | 粗粒度读点 | 细粒度读点 |
|---|---|---|
| Swift 守卫 `PerfInvalidationRatchetTests`（跑全量时） | 16 | 0 |
| 我另写的 python 复算（`git show <ref>` 逐 ref） | 16（main / p / o / w 四个 ref 全同） | 0 |
| `trace_report.py migration`（正则与上限直接读守卫源码） | 16 | 0 |

⇒ **`165faa7`～`5f996d4` 三家的无界化合完，性能契约在页面侧的消费量仍是 0**。
M0 把一次 tick 的写入面收窄了，页面继续读粗表面，所以用户端的流畅度**不会因为这一轮变好**——
把这句话写在这里，是为了让"三家已合入"不被误读成"性能轮已交付"。

### 请这样派（每家一条自验命令，不用回来问我）

```bash
git merge main                                   # 先取我这包：migration 命令与守卫都在里面
python3 scripts/trace_report.py migration        # 我还剩哪几处、该换成哪个格
python3 scripts/trace_report.py migration --strict   # 挂进自家收尾检查：还有剩余就非零退出
```

| 派给 | 文件与处数 | 换成 |
|---|---|---|
| **WS-O** | `DashboardView.swift` 3 处（`latestSnapshot` ×1、`history` ×2）、`ProjectSidebar.swift` 1 处（`latestSnapshot`） | `pulse.value` / `curve.value`（已切窗口）/ `cpu.value`（badge 只要 CPU） |
| **WS-W** | `PerformanceView.swift` 10 处、`LiveReadings.swift` 2 处 | 见 §0.1 表；`ledger.value` / `cpuRanking.value` / `memoryRanking.value` / `groupRanking.value` / `pulse.value.sampleAt` |
| **WS-P** | 0 处 | 本项无工（其余 P 工单照旧） |

三条红线（都会被当场拦，别试）：
1. **不要新增第 17 处**——棘轮零余量（`1/1 59/59 10/10 2/2`），多一处立即红；
2. **不要用 `AnyView` / `id: \.offset` 绕失效面**——那只是把重建换个名字，守卫与本工单都不认；
   （新加一条同族守卫 `testPreparedCellsAreNeverReslicedOrResorted`：**读到细格之后又再切一次窗口、
   再排一次榜单**也算假迁移——编译通过、画面也对，收益却留在原地，粗 API 棘轮抓不到它，
   所以基线从写作起就是 **0**，元测试双向验过）；
3. **不要对 `curve.value` 再 `suffix`、对 `cpuRanking.value` 再 `sorted`**——排序与切窗已在采集侧做一次。

### 交回标准（我不接受口头完成）

- `migration` 报 **0 处粗读**（这是唯一读数，命令自己会写"请总工把上限拧成 0"）；
- 我随后把 `coarseCallSiteCeiling` 拧成 0 并翻 `consumptionGateOpen = true`——
  这个闸门是四态的，**没迁完就翻会当场判红**，所以它翻得动本身就是证据；
- `W-1 / W-2 / W-3 / W-6` 逐项附自己的验证命令输出。

### 交回之后我需要的一个窗口（M2 终测）

一次 **约 5 分钟**的安静窗口：本机只有被测的那**一个**实例、它在前台、无并发编译
（`perf_harness.sh` 的 `preflight_context` 会自己判，不合格它直接拒跑，不会给我假数）。
里面跑：`idle` ×3（心跳期，对 T2）与 `interact` ×3（交互期，对 T1，需要有人持续滚动）。
**改前对照组**已封存 `/tmp/tcoder-before.app`（rev `415f0f0`，sha `54005bc4…`）——
它里面没有 `FramePulse`，所以前后对比只能走 xctrace 那两档，不能拿 `probe` 比。

## 0.4 【取代 §0.2/§0.3 的派工形状】单人接管后的执行清单——按值排序，每条自带验收命令

用户 22:40 裁定：**性能总工停手，两条线合成一个人**（`AGENTS.md`「22:40 单人接管」）。
所以 §0.1/§0.2/§0.3 里"派给 WS-O / 派给 WS-W / 各建新树"那套**派发形状作废**（内容仍有效），
下面这份是替它：一个人、按顺序、每条都有机器验收。**红线一条不撤**——它们约束的是做法不是人。

### 第 1 步（收益最大）：把 16 处粗读点迁成细粒度格

```bash
python3 scripts/trace_report.py migration            # 还剩哪几处 + 该换成哪个格
python3 scripts/trace_report.py migration --strict   # 迁干净前它会非零退出
```
- 位置（02:13 按 x7 拆分后重锚）：`PerformanceView` 10、`Shell/DashboardReadouts.swift` 3
  （原 `DashboardView`，被 WS-X7 拆出来的）、`PerfLogs/LiveReadings.swift` 2、`Shell/ProjectSidebar.swift` 1；
- 换成什么：`docs/superpowers/specs/2026-09-20-performance-120hz-design.md` §5.3 的实名契约
  （`monitor.cpu.value` / `.memory.value` / `.rates.value` / `.ledger.value` / `.pulse.value` /
  `.cpuRanking.value` / `.memoryRanking.value` / `.groupRanking.value` / `.curve.value`）；
- 三条不要做：不要新增第 17 处（棘轮零余量当场红）、不要用 `AnyView` / `id: \.offset` 绕失效面、
  不要对 `curve.value` 再 `suffix` 或对 ranking 再 `sorted`（采集侧各做一次）；
- **验收不看谁说了什么，看这三样**：`migration` 报 0 处 → 总工把 `coarseCallSiteCeiling` 拧成 0
  → 再把 `consumptionGateOpen` 翻成 `true`。**没迁完就翻会当场判红**，所以"它翻得动"就是证据。
- 顺带把 W-6 一起收：`isCollectingForDisplay` 目前仍 0 读取（"重新采样"点了最长 1.5 s 没反馈）。

#### 但请按这张表加权，别对 16 处平均使力（09-21 01:2x 读 `publish()` 实测，含对我自己上一条的更正）

> **这张表现在有机器出处**，不是一份会腐烂的手抄名单：
> **先看清这件事的前置**：下面点名的守卫（`classifyCoarseWrites` / `publishBody` /
> `testCoarseReadoutSitesSplitIntoLoadBearingAndIncidental`）与台账
> `tcoder-perf-migration-weighting.txt` **现在只在 `ws/perf-base` 上，还没进 main**
> （本文件这段是先落 main 的，包本身在 §0.5 第 0 步排队）。
> 所以在 main 上你要的是**结论**（10 承重 / 6 顺手、以及哪几处），不是那条打印——
> 现在想在 main 上复现分级，只能照本节末尾那四条替换关系手点，或等守卫进 main 之后自动打。
> `PerfHitchGuardTests` 那份**逐条点名**的渲染路径台账同理：明细已在 main 的守卫里，
> 但"落文件"这件事跟着 `966f896` 排队。
>
> 守卫落地后每次跑都会打印
> `承重 N / 顺手 M / 合计 K` 并落台账 `$TMPDIR/tcoder-perf-migration-weighting.txt`，
> 分类由 `classifyCoarseWrites(declarations:tickBody:symbols:)` **从 `publish()` 源码现读**
> （符号名单从 `coarsePattern` 的交替组取，只有一处真相）。
> 谁改了闸门写法而没回来改口径，那两条测试会红——它已经在第一次跑的时候抓到我一处口径错
> （`refreshGroups()` 里的一次性裸写被算成了每 tick 成本），所以下面的数字是过了这一关的。

机制只有一条：`publish()` 里**只有两处是无闸门写**，而它们的值每 tick 必然变——

| 粗属性 | 写法（`MachSystemMonitor.publish` 内） | 每 tick 真的换值吗 | 读它的代价 |
|---|---|---|---|
| `latestSnapshot`（`:535`）、`history`（`:544`） | `latestSnapshot = batch.snapshot` / `history = frames` **无闸门** | 是（`timestamp` 每帧新、数组每帧追加） | **每次心跳都重算读它的那棵 body** |
| `topProcesses` / `processesByMemory` / `trackedGroups` / `measuredProcessCount` / `processMetricsTruncated` | 走 `write(\…, &stats)` **等值闸门** | 不一定（榜单/计数常整帧不变，闸门会 skip） | 只在值真变时重算 |

所以 16 处**不是 16 份等价收益**：

- **承重的 10 处**（读上面那两个无闸门属性）：`DashboardLiveReadout.snapshot` 别名 ＋
  `DashboardLiveReadout.livePerformanceGroup` 两处 `history.suffix(90)`、
  `LiveReadings` 25 / 26、`ProjectSidebar` 443、`PerformanceView` 54 / 63 / 94 / 95。
  `PerformanceView:94` 的 `monitor.lastSampleAt` 其实是 `latestSnapshot?.timestamp`（`:280`），也算这一类。
- **顺手的 6 处**（读已闸门属性）：`PerformanceView` 45 / 47 / 53 / 55 / 68 / 69。
  它们和 `:54` 在**同一个 body**里，所以单独迁它们**测不出差异**——那一屏仍被 `latestSnapshot` 拽着重算。
  既然人到现场了，一并改掉是对的（棘轮要的是 0，不是"有效的 0"），但**别把收益记在它们头上**。
- 10 处承重里，**7 处是 1:1 换名**（`curve.value` 直接顶 `Array(history.suffix(90))`、
  `pulse.value.historyCount` 顶 `history.count`、`pulse.value.sampleAt` 顶 `lastSampleAt`、
  `ledger.value.systemWideCount` 顶 `latestSnapshot?.processCount`；四 + 一 + 一 + 一 正好七处），
  剩下 **3 处是"把整份快照递给别人"**，性质和 `SampleContext` 一样，要改的是**接收方的入参**：
  1. `LiveReadings.swift:25` `SampleContext(snapshot:)` —— 喂着 `PerformanceView` 里五个子视图；
  2. `DashboardLiveReadout.snapshot`（现居 `Views/Shell/DashboardReadouts.swift`）
     `private var snapshot: SystemSnapshot? { monitor.latestSnapshot }`
     —— 页内 10 处读点共用这个别名，实际只碰 `disk*/network*` 四个速率字段（都在 `rates.value`）；
  3. `ProjectSidebar.swift:443` `LiveCPUBadge(snapshot: monitor.latestSnapshot)` —— 子视图收整份快照，
     它要的只是 `cpu.value.usage`（＋ `coreCount`）。
  这三处**不要**原地换成 `monitor.latestSnapshot` 的另一种写法：那还是同一棵 body 每 tick 重算。
- 顺序建议：**先做那 7 处 1:1 的**（零判断、当场能让 `migration` 掉 7 个），
  再按 `SidebarLiveFooter` → `DashboardLiveReadout` → `PerformanceView`+`SampleContext` 做那 3 处（由小到大，
  `LiveCPUBadge` 只有一枚徽章、`SampleContext` 要动五个子视图的入参，放最后）。

`SampleContext`（`LiveReadings.swift:15`）是唯一需要决策的一处，其余都是 1:1 换名。
它是"整份 `SystemSnapshot` 塞进一个值"，喂着 `PerformanceView`/`SystemTiles`/`ProcessTable`/
`LiveCharts`/`ProcessGroups` 五处的 `let context: SampleContext`——**只要它还在，那一屏就还整棵重算**。
它的 20 个纯读数函数不需要新契约：把视图里经 `ctx.snapshot` 读到的字段逐个对过去，
**14 个不同字段全部已在九格里**（`cpuUsage/cpuCoreCount/thermalState/uptimeSeconds`→`cpu`，
`memoryUsedBytes/memoryTotalBytes/memoryPressure`→`memory`，`disk*/network*` 四个→`rates`，
`processCount`→`ledger.systemWideCount`＋`countIsSystemWide` 管"全系统 vs 本用户子集"三态，
`historyCount/lastSampleAt`→`pulse`，榜单→`cpuRanking/memoryRanking`）。
也就是说**契约侧没有缺口**，缺口只在"改签名"：把 `ctx.snapshot?.x` 换成读对应的格。
一个提醒：`PerfCPULead.usage` 等是 `Double?`，比 `SystemSnapshot` 的裸 `Double` **更能表达"没取到"**，
所以换过去之后 `cpuFraction/memoryGapReason` 那几条的三态判据要**逐条重看**，不要机械替换后沿用旧的
"snapshot 为 nil 才算缺"——那是把更强的诚实性降级掉（同 §0.0 的红线：诚实性语义一条不降）。

还有一条**留给 `trace_report.py` 的下一个人**（我这轮故意不动它：`ws/x2-runtimesvc` 正在二次拆这个文件，
我改就是撞车）：`migration` 现在只报"还剩 16 处"，应该把上面的 `承重/顺手` 分级一起打出来，
让派单的人一眼看见"先做哪 10 处"。分级逻辑已经有了（守卫里的 `classifyCoarseWrites`），
照它读 `coarsePattern` 的写法再读一遍 `tickBody` 就行——**别手抄第二份名单**，那正是 #44 的形状。

> **一条待办（02:41 想到，但故意现在不做）**：`REFUSED` 有个残留缺陷——
> 如果同一个输出目录被复用（`/tmp/tcoder-perf-<rev>-run1` 先被拒、后来真采到了），
> 旧的 `REFUSED` 会**留在**那个已经有数据的目录上，于是 `report` 会拒绝一份**合法**读数。
> 修法是一行：`cmd_idle` 在 preflight 通过、准备录制之前 `rm -f "$out/REFUSED"`
> （语义 = "REFUSED"只描述最近一次尝试，不是目录的永久属性）。
> **为什么不当场改**：`perf_wait_window.sh` 正在后台等窗口，它随后会 exec
> `perf_harness.sh` / `perf_preflight.sh`——bash 是按字节偏移增量读脚本的，
> **改一个正在运行的脚本可能让对方执行到错位的内容**。所以先记账，等 watcher 收工再改。
> 同理，这一轮我已经把 run1~3 目录里那三个 `REFUSED` 手工清掉了：
> 不清的话，watcher 复用同名目录采到真数据时会被那个过期标记误判成"被拒的一趟"。
> **这两件事是同一个坑**：标记必须是"最近一次尝试"的状态，不能变成残留物。

### 第 1.5 步（与第 1 步同批、但收益不同期）：渲染路径剩下的 12 处**全在页面侧**


> **02:45 一条时效性很强的补充**：接管者**此刻在途的这批**（主树 32 个未提交文件）正好覆盖
> 10 处排序债里的 **5 处**，包括其中**最贵的那一处**：
> `Dependencies/DependenciesView.swift`（`dependencies.sorted`，n 可到上千）、
> `Git/ContributorRows.swift` ×2、`Git/ContributorsView.swift`、`Health/HealthComponentTable.swift`。
> 判据和第 1 步一样：**这些文件正在被重写，换排序位置是同一次编辑**；
> 这批过了再单开一趟，就要在同样的行上第二次合并。
> 未被这批覆盖的 5 处（`Logs/*` 四处 + `Code/CodeMetricsView`）留到 Logs 批次顺手做。
> **注意别和视觉改动混判**：这批若顺手清了排序，`fullSort` 会从 10 掉下来，
> 那是**收益**，但复测时不能把帧率变化记给"视觉批次"——所以清哪几处要留在 commit message 里。

01:49 用守卫自己的规则复算了全部命中并落进台账明细（`tcoder-perf-renderpath-debt.txt` 现在带
`文件:行 + 原文`，不再只报一个数）：`fullSort 10` + `syncFileIO 2` **一处都不在 `Services/`、`Design/`、`App/` 里**
⇒ 性能侧**没有可以自救的份**，这 12 处只能由写页面的人做。清单：

| 处 | 位置 | 被排集合规模 n | 与哪条验收有关 |
|---|---|---|---|
| 1 | `Dependencies/DependenciesView.swift:278` `dependencies.sorted { name, version }` | **可到上千**（全仓依赖） | **T1 交互期**（依赖页滚动/切页时重算） |
| 1 | `Logs/LogsFileTables.swift:104` `scannedFiles.sorted` | **数百～上千**（扫到的日志文件） | **T1 交互期** |
| 1 | `Logs/LogsFileTables.swift:65` `affectedFiles.sorted` | 数十～数百 | T1，量级次之 |
| 1 | `Code/CodeMetricsView.swift:56` `languages.sorted` | 个位数～几十 | 清了口径，**别提帧率收益** |
| 2 | `Git/ContributorRows.swift:11 / :62`、`Git/ContributorsView.swift:22` | 作者数十 | 同上 |
| 1 | `Health/HealthComponentTable.swift:47` | 组件数固定 | 同上 |
| 1 | `Logs/LogsMetricGrid.swift:92` `grouped.keys.sorted()` | 几个 key 拼文案 | 同上 |
| 1 | `Logs/LogsTrendCard.swift:33` `trend.sorted { date }` | 按天分桶，≤90 | 同上（且生产侧本就可以有序） |
| 2 | `Logs/LogsView.swift:176 / :209` `fileExists` / `attributesOfItem` | **同步 stat()** | **T1**：日志页滚动期做磁盘 I/O |

**为什么这 12 处不牵 T2（心跳 4 ms）**：这五页**一处都不读监控格**——01:50 逐个文件数过
`grep -c 'monitor\.'`：`DependenciesView`/`LogsView`/`LogsFileTables`/`LogsTrendCard`/
`LogsMetricGrid`/`CodeMetricsView`/`ContributorRows`/`ContributorsView`/`HealthComponentTable`
**九个文件全是 0**（粗读点名册里也只有 `DashboardReadouts`/`LiveReadings`/`ProjectSidebar`/`PerformanceView`）。
所以它们的 body 不随心跳失效，里面的排序/I-O 不会每 tick 跑。⇒ **它们是"切页与滚动期"的成本，归 T1 管，不归 T2 管**。
派单时别把它们和那 10 处承重粗读点混成一句"清完渲染路径"，两批的验收证据不是同一个窗口。

正解形状与 `cpuRanking` 同一种：**排一次、放进产出，页面读现成的**
（`PerfLeads.derive` 就是在采集侧一次性排好、页面零排序）。依赖表/日志文件表那两处大集合
适合挪到分析侧产出有序结果，页面只读——**采集侧改动归我，页面那一行删除归你**。
要的话我先在服务端把有序版本准备好（不碰 `Views/**`），你那边只剩删调用。

### 第 2 步：帧率复测（分两小步，因为其中一步需要人手）
> **12:08 复测现状**：rev `082f403` 上第 1 趟可用（`app-update` 0.6~1.3 ms、hitch 0、
> render 超预算 0.43%/n=1644），第 2、3 趟**在录制中途**被闸门拒（有人起了 `swiftc`，
> load 从 4.80 升到 8.53）⇒ **T2 仍差 2 趟一致样本**。
> 排程器这一维已补：它现在会**先等"本仓无重活"**再开始，而不是连烧三次尝试。
> 另有一处口径待总工裁定，见 spec §1.5c（`pct < 0.1%` 与基线自身 0.42% 互相矛盾）。
>
> **包 2 落地（11:38）后新增的两条工具能力**：
> ① `MODE=interact ./scripts/perf_wait_window.sh <tag> 3` —— T1 也能"机器等窗口"了：
>    它会先等人手静默再起 App（不抢正在被人用的焦点），起完之后**要求这 20 秒里有人滚**，
>    没人滚就被 `human_input_in_window` 拒。产物目录带档名（`-idle-run*` / `-interact-run*`），
>    两批数不会互相覆盖。
> ② "被量的二进制是不是这份代码"现在有闸门了（`scripts/perf_provenance.sh` 是唯一判定处，
>    `verify_provenance.sh` 与测量档都走它）。**后果**：现在 `dist/` 里那个 09:49 建的包
>    会被两条流水线同时拒——复测与九页取证之前**必须先** `./scripts/build_app.sh release`。
>

> **进度（09-21 11:07 更新，接上面那条排程约束）**：闸门修好后**第一趟受控 idle 已经出数**
> ——`app-update` 0.6~1.0 ms（T2 红线 ≤4.0）、hitch 0 次、HTR 0.00、`potential-hangs` 0 次，
> 上下文与拒因都落在 `/tmp/tcoder-perf-ab26811-run{1,2,3}/measurement-context.txt`。
> 但**它只是 N=1**：同一轮第 2、3 趟被闸门拒（前台被 `AiX` 抢走，其余四条闸全合格）⇒
> 按 §1.3"连测 ≥3 次且取值一致"的规矩，**T2 还不能申报达标**，还差 2 趟。
> 同批还修了尺子三处口径（跨机制裸比比率 / 未受控对照列冒充 X / 绕开 harness 必崩表），
> 见 spec §1.6 与 `fd5d06e`。下面那条"顺手 6 处的 skip 率"**仍未量**，别把它当已结案。
>
> **一条现在正生效的排程约束（02:29 写下，免得下一位自己把自己挡掉）**：
> `perf_wait_window.sh` 挂后台等窗口时，**这台机器上不要跑 `swift build` / `swift test`**——
> `idle` 档的闸门之一正是"`pgrep -x swiftc` 为空"，我自己的编译会让 watcher 一直拒跑。
> 同理门禁（`premerge_check`）要么等 watcher 结束（默认最长 25 分钟 / `LAUNCH_APP=0` 时更短），
> 要么先 `kill` 掉 watcher（只有它自己起的那个 pid，它退出时自己 TERM）。
> **别为了让门禁过而把 watcher 的闸门调松**——那五维就是它存在的理由。

> **顺带要量的一个新数（01:59 立，别让它停在推理上）**：我这轮把 6 处读点判成"顺手"，
> 依据是它们的宿主属性走 `write(\.x,…)` 等值闸门。但**"有闸门"不等于"闸门真的经常关"**——
> `measuredProcessCount` 在一台真机器上每 tick 都在变的话，skip 率接近 0，那这 6 处就仍然每 tick 抖。
> 好消息是不管 skip 率多少，排序不变（无闸门那两处**必然**每 tick 换值，闸门写最多和它一样频繁），
> 所以派单顺序不依赖这个数；但这个数会决定"顺手"是"零收益"还是"小收益"，
> 而且**它已经可测**：`lastPublishStats` 就在产品里（`@ObservationIgnored`，不进观察图），
> `ticks`/`writes`/`skips` 三个数，跑 `idle` 档时顺手读一次台账即可。
> 量法：`writes + skips` 应等于 `ticks × 12`（7 个细格 + 5 个闸门粗属性），
> 不等就是记账漏了一格——那才是这条读数的第一用途。
> **口径提醒**：这条量的是"闸门有没有在关"，不是"页面有没有重算"，两件事分别由
> `idle` 档的 xctrace app-update 与这里的 stats 管，别拿一个数交两条验收。

```bash
./scripts/perf_harness.sh selfcheck          # 14 项（02:00 加了收益分级三项后），红了所有读数作废
./scripts/perf_harness.sh idle   /tmp/tcoder-perf-after-<rev>     # 2a：不需要人**操作**，但需要人**离开**
#   （02:51 实测更正：原先写"不需要人"是错的。三趟全被拒：
#    ① 前台是「微信」——不在前的窗口被 macOS 节流绘制，同一二进制后台 app-update 只有 1.9~3.0 ms，
#       前台 10.8~24.8 ms，拿后台数交 T2 就是**假性好看**；
#    ② 人手 0.05~0.19 秒前还在动（要求静默 ≥5 s）。
#   ⇒ 闸门拒得对：它替我挡下一批会骗人的 T2 读数。T2 的窗口条件是
#      "Tcoder 停在最前面 + 这 5 分钟没人碰这台 Mac"，不是"无人参与"。）
./scripts/perf_harness.sh interact /tmp/tcoder-perf-interact-<rev> # 2b：**这 20 s 要有人持续滚动**
./scripts/perf_harness.sh report <目录>       # 表头会写测量期间，idle 那批明说不得交 T1
```
- 五维闸门：实例数=1、前台是被测 App、有在屏窗口、load1 ≤ 核数×1.5 且无并发 swiftc、**人手静默 ≥5 s**；
  任一不合格脚本直接拒跑（那不是脚本坏，是它在拦第三次"未受控基线"）。
- **改前对照**只能走 xctrace：`/tmp/tcoder-before.app`（rev `415f0f0`、sha `54005bc4…`）里
  没有 `FramePulse`。`probe` 档只对改后产物有意义，不许左右互比。
- **测"哪一颗头"必须写在读数旁边。** 我这颗头（`ws/perf-base`）相对 main 的**非文档差异只有
  3 个测试文件 + `FramePulse` 里两行产物头注释**——都不参与运行时视图行为。
  所以**用它 build 出来的 release 产物量到的 T2，就是 main 当前行为的 T2**，
  不必为了"等合完再测"再排一次队；但读数落盘时要照实写"被测头 = ws/perf-base@<sha>，
  与 main 的行为差异：无"，别让下一位以为量的是迁移之后的状态。
- 一条已核过的前提：`idle` 档 **attach 已存在的实例**且要求"实例数恰为 1"，
  所以顺序是 `build_app.sh release` → 启动那一个实例 → `idle`×3 → `report`；
  跑完**只打印 pid**（按 bundle id 广播退出的老写法已作废，见 §0.0.1）。
- 合格判据：HTR <5 ms/s（目标 0）、app-update ≤8.33 ms、`potential-hangs` 归 0、
  热点第一名不再是 `_updateViewGraph`。**每次都要 3 个样本，单样本不进结论。**

### 第 3 步：M2 收尾

- 九页 × 深浅取证：`SWITCH_MODE=argv` + 自己的 `CAPTURE_SANDBOX` + 目录名带短 HEAD，
  **按 `CAPTURE_LOCK` 排队别绕锁**；深色用 `osascript … set dark mode`（`defaults write` 无效），
  翻完立刻翻回；每趟逐张量平均亮度（浅 0.95–0.98 / 深 0.15–0.16），被污染的页重拍。
  收尾退出现在只处理自己那个 pid（`CAPTURE_TERM=1`），**不会再按 bundle id 全机杀实例**。
- 文档：《九页实拍读数》《README》《口径与已知限制》三处按新读数更正，未覆盖项**明写未覆盖**。
- 清树：三家已清；剩 `ws/perf-base` 由性能侧在第 1、2 步交回后清（`git worktree remove` + `git branch -d`）。
  `/Users/one/WorkBuddy/…` 那棵树在仓库目录外，**按禁区规则不去动**。

### 已经量化掉、不要再重开的两件事（§5.4 结案）

| 项 | 我量 | UI 总工独立复跑 | 判定 |
|---|---|---|---|
| 一次 `upsertReport`（主线程） | 中位 0.5 ms | 中位 **0.58 ms** | **不动**：占 T2 预算约 1/8，且不在 1.5 s 节拍下触发 |
| 启动 `load()` 解码 4 份真报告 | 中位 1.3 ms | 中位 **1.25 ms** | **不动**：占 T4 冷启动 0.13% |

两个操作者、同一台机器、同一档量级 ⇒ 这条结案可以认为是稳的。
它的价值是**把候选排除了**：持久化不占主线程预算，所以剩下的怀疑对象只有视图图更新，
也就是第 1 步那 **10 处承重读点**（不是 16 处——见上面的加权表）。

### 第 4 个候选：已定位、**尚未排除**（02:40 读 `AppState` 时发现，记在这里免得重复找）

`AppState.notePointerStreamActivity()` 是**每个滚动事件都跑一次**的入口，形状是：

```swift
monitor.beginInteractionPause(.pointerStream)   // 走等值闸门，第二次起 skip
pointerSettleTask?.cancel()                     // 每事件取消上一个
pointerSettleTask = Task { @MainActor in … }    // 每事件新建一个非结构化 Task
```

⇒ 120 Hz 滚动下约是**每秒 120 次 Task 分配 + 120 次取消**，全在主 actor 上。
**我没有据此改代码**：单次 Task 只有微秒量级，"推测它贵"和"推测它不贵"同样没有证据，
而这里唯一相关的证据是交互期 profile 里它到底占多少。
**判据写成一条可查的动作**：跑完 `interact` 档后在 `time-profile` 表里搜
`notePointerStreamActivity` / `swift_task_create`——
**进热点前 20 名就回来改**（改成记 `lastEventAt` ＋ 复用同一个沉降 Task），
不出现就把这条划进上面那张"已排除"表。**不许在没量的情况下先动它，
也不许因为"看起来像问题"就永远挂着不结。**

顺带钉一条反向的：**这里不许"顺手"改成每事件都 publish 一次。**
暂停/恢复的写入必须继续走等值闸门，否则 T3 会把"交互期不刷新"变成"交互期疯狂失效"，
那是比 Task churn 大两个数量级的成本。

## 0.5 交接状态（09-21 00:31）——写给"一个人接两条线"的那位，免考古

**已进 main 的性能侧东西**（`main = f9841ae` 之前的 `3a3381c`）：
细粒度九格契约 + 交互期引用计数暂停（`Services/Performance/MachSystemMonitor.swift`、`App/AppState.swift`）、
Design 令牌缓存、尺子六档 + `selfcheck`（14 项）、`migration` 命令（含收益分级）、
五维 preflight（含**人手静默**）、四条禁则零余量 `1/1 59/59 10/10 2/2`、
§5.4 与 **T2 两半归因**（主线程九格写入 0.01 ms / 900 进程派生 9.3 ms 在后台）。

**已提交、只差合的两包**（09-21 01:2x 更正：**不再是"主树一干净就落"**，见下面第 0 条）：
```bash
ls /tmp/premerge-pass-ws_perf-base-*.ok | tail -2          # 看回执对应的头
cd TcoderMonitor && ./scripts/merge_stream.sh ws/perf-base "merge ws/perf-base: 台账 + 假迁移守卫"
```
内容 = `dynamicNSColor` 拧到 59、两条棘轮各落一份 `$TMPDIR` 台账、
新守卫 `testPreparedCellsAreNeverReslicedOrResorted`（防"迁了个假的"）。

**合入顺序现在多了一条前置条件（09-21 01:2x 实查 `ws/x3-testsplit`）**：
WS-X3 把这两条守卫的**宿主文件按行数拆成了 extension**——
`PerfInvalidationRatchetTests.swift`(190) + `+CoarseRatchet.swift`(104) + `+InvalidationBehavior.swift`(209)、
`PerfHitchGuardTests.swift`(252) + `+FramePulse.swift`(111)，而我这两包的 hunk 正落在宿主文件里。
所以：
0. **等 X3/X0 那批先进 main，我再把自己的两包"重新落位"到拆后的布局上**（把 `reslicePattern` 那两条测试
   放进 `+CoarseRatchet.swift`、`knownBaseline` 的改动留在主文件），跑一遍门再合。
   ~~落位时必须顺手把 §3.6「收益分级」整段搬进一个新的 extension 文件~~ —— **01:54 已经做掉了**：
   那段现在在 `PerfInvalidationRatchetTests+CoarseWeighting.swift`(252 行)，主文件回到 **541 行**
   （原来 781 行、离 800 上限只剩 19 行，再写一条测试就会把 main 弄红；**拆文件才是修复，改阈值不是**）。
   搬动方式**不是复制一份尺子**：`coarsePattern`/`scanHits`/`codeLines`/`Doc`/`Line`/`moduleRoot`/
   `scannedConsumerDocs` 从 `private` 放开成 `internal`，两段代码共用同一把尺子。
   搬完 23 条测试的数量与全部读数**一字不差**（承重 10 / 顺手 6 / 合计 16、`publish()` 抽到 33 行、
   `1/1 59/59 10/10 2/2`）。X3 拆的是主文件、他们树上没有 `+CoarseWeighting.swift`
   ⇒ 我的净增行数已经从宿主文件里挪走，将来的冲突面比 01:31 写这条时小。
   顺序反过来会变成"我先进、他们拆的时候撞我的 hunk"，冲突由不懂这套口径的人解更容易出事。
   **好消息已经核过**：X3 把口径常量（`coarsePattern` / `finePattern` / `coarseCallSiteCeiling` /
   `consumerDirectories` / `knownBaseline`）**留在主文件里没搬**，所以 `trace_report.py migration`
   那把"从守卫里现读尺子"的机器在 X3 树上照样跑得出 `16/16/0`——**拆文件没有把尺子的取数口拆断**。
   若后续谁把这些常量搬进 extension，`migration` 会**报错而不是用一份手抄的旧尺子**，那是设计行为。
   **01:57 又实测了一遍落位兼容性，结论比 01:31 乐观**：X3 把 `moduleRoot` / `Line` / `Doc` /
   `codeLines` / `scanHits` / `documents` / `scannedConsumerDocs` **留在宿主文件里、而且已经全部
   放开成 `internal`**（逐条 `grep` 核过 `.worktrees/x3-testsplit`）——与我 01:54 为了跨文件共用
   做的六处放开**是同一批成员、同一个可见性**。
   ⇒ 我的 `+CoarseWeighting.swift` 对着他们的布局**不需要任何改动就能编译**，
   重新落位缩成两小步：`reslicePattern` 那两条测试挪进 `+CoarseRatchet.swift`、
   `knownBaseline` 与台账明细的改动留在 `PerfHitchGuardTests.swift` 主文件。
0′. **还有一棵树正在搬我另一包的家**：`ws/x6-scale` 在拆 `Services/Performance/FramePulse.swift`
   （`1f2696a` 411→367 行），而我那笔"把语义边界写进产物文件头"的改动
   （`5f21eee`，给 `writeHeaderLocked()` 加两行 `#` 注释）**正是加在这个文件里**。
   它一旦进 main，我那两行要么撞冲突、要么**在搬函数时静默丢掉**——而丢掉是看不见的：
   产物文件照样生成，只是少了两行"这是唤醒间隔、不是主线程占用"的提醒，
   下一个人就会继续把 `心跳最大间隔` 读成 T2 的占用时长（这笔债本来就是为此才写的）。
   ⇒ 落位时**先核 `writeHeaderLocked` 搬去了哪个分片、那两行还在不在**，
   用 `grep -c '唤醒间隔' <新文件>` 之类的存在性检查判，不要靠 diff 印象。
   同理 `perf_harness.sh`（`21fab71` 643→356 行、selfcheck 外迁 `perf_selfcheck.sh`）
   与我那批尺子改动是同一个文件的两次手术，合之前先跑一次 `selfcheck` 确认没被拆漏。
1. **§0.4 第 1 步**：**10 处承重**粗读点迁完（`python3 scripts/trace_report.py migration` 报 0）
   → 我再把 `coarseCallSiteCeiling` 拧 0、翻 `consumptionGateOpen`；
2. **§0.4 第 2 步**：约 5 分钟安静窗口（`idle`×3 不需要人；`interact`×3 需要你持续滚 20 秒）。
   被挡过两次的真实原因都写在 `measurement-context.txt` 里，脚本会自己拒，不用你判断。

**这一轮还查到两件与派单有关的事实**（都影响"下一步做什么"）：- **`ws/x0-chief`、`x1`、`x2`、`x3` 四棵树里 16 处读点一处没动**（01:2x 逐树跑 `migration` 全是 `16/16/0`）。
  这批是**体量/圈复杂度拆分轮**，不是 120Hz 轮；`x2` 那位还在二次拆我的 `trace_report.py`、
  把 `selfcheck` 搬进 `perf_selfcheck.sh`（读数我核过没变）。⇒ **交互期 hitch 的收益仍然完全押在第 1 步上**，
  它一旦再排到下一批，这一轮的 T1 就没法结。
- `ws/chief`（`f5c0449`，13:30）**已全部在 main 里、树是干净的**，是上一轮留下的空树。
  不是我建的、也不归我清，报给接管者处置：`git worktree remove .worktrees/chief && git branch -d ws/chief`。

**别做这三件事**（都是这一轮踩过或量过的）：
不要为了"零动态色"删取色引用（终点不是 0，见规范 T5）；
不要把任何阈值调松来变绿（`ceiling = 0` 与 ≤800 行那条一样，"改这里的数字不是修复"）；
不要拿 `probe` 去和改前对照物比（`/tmp/tcoder-before.app` 里没有 `FramePulse`，只能同走 xctrace）。

## 0.6 【02:02 提，02:13 按 x7 拆分后的现状重锚】那 10 处该**折进正在重写这些文件的批次**做

**先记一件刚发生的事**：这段 02:02 落 main 时写的是 `DashboardView.swift:458/459`，
几分钟后 **WS-X7 的规模拆分进了 main**，同两处读点搬进 `Views/Shell/DashboardReadouts.swift`
（行号变 335/336），`ProjectSidebar` 那处从 333 漂到 339。
⇒ 本节坐标**一律改成「类型.成员」**（本仓既有约定：Views 层钉符号不钉行号）。
`migration` 仍按当下位置报行号，**别拿它当稳定坐标**。
读数没变：**还是 16 处**——拆分把债搬走了，既没清掉也没长回来（这条值得一提：
**大规模搬文件的改动如果顺手"优化"了读法，16 会掉；没掉说明真没人动**）。

| 稳定坐标（类型.成员） | 现在在哪个文件 | 最近被谁重写 |
|---|---|---|
| `PerformanceView.body` 那 10 处 | `Views/Performance/PerformanceView.swift` | 批次 E、批次 ABC |
| `DashboardLiveReadout.snapshot`（整份快照别名） | `Views/Shell/DashboardReadouts.swift` | **WS-X7 拆分 02:10** |
| `DashboardLiveReadout.livePerformanceGroup`（两处 `history.suffix(90)`） | 同上 | **WS-X7 拆分**（557→376 那一路） |
| `SidebarLiveFooter.body`（`LiveCPUBadge(snapshot:)`） | `Views/Shell/ProjectSidebar.swift` | **WS-X7 拆分**（486→384） |
| `SampleContext.from(_:)`（整份快照造上下文） | `Views/PerfLogs/LiveReadings.swift` | 近期没有观感批次碰 |

⇒ **迁移文件 == 别人此刻正在重写的文件**。另起一趟"性能迁移派单"必然和下一批撞在同一批行上：
**两拨人改同一个 body 的同几行**，这就是 21:15 那条"性能侧不许写 `Views/**`"裁定要防的事，
它到现在仍然是对的——而 x7 刚把这三个文件切开，**趁热把读法一起换是眼下最省的一次机会**。
更省的道理很简单：那几行本来就要重写，换 `monitor.curve.value` 与"把 557 行拆成 376 行"是同一次编辑，
**不多花一次合并、不多花一遍门禁、也不多占一次实机测量窗口**。

给接管者的可执行版本（都是 1:1、零判断，坐标写成员名不写行号）：
`Array(monitor.history.suffix(90))` → `monitor.curve.value`
（三处：`DashboardLiveReadout.livePerformanceGroup`×2、`PerformanceView.chartWindow`；
 `PerformanceView.sampleStats` 里那处是 `monitor.history.count`，归下一条）；
`monitor.history.count` → `monitor.pulse.value.historyCount`（`SampleContext.from`、`PerformanceView.sampleStats`）；
`monitor.lastSampleAt` → `monitor.pulse.value.sampleAt`（`PerformanceView.sampleStats`）；
`monitor.latestSnapshot?.processCount` → `monitor.ledger.value.systemWideCount`（`PerformanceView.body`）。
剩下 3 处要改**接收方**，不是换名：`SampleContext.from`（喂五个子视图）、
`DashboardLiveReadout.snapshot`（页内 10 处共用的别名）、`SidebarLiveFooter` 递给
`LiveCPUBadge(snapshot:)` 的那个入参。
这三处适合作为**单独一小批**，和纯视觉改动混在一起会看不清是谁的效果。

> **02:07 更正我上面这条建议里的一处危险简化（照我原话说会造出假零）。**
> 我写"徽章只要 `cpu.value.usage`"，但徽章其实吃**两格**：`cpuUsage` 与 `memoryUsedBytes`，
> 现在靠 `DataAbsence.optional(snapshot.map { … })` 表达"还没采到" ⇒ 显示 `--`。
> 而 `PerfMemoryLead.usedBytes` / `.totalBytes` 是**非 Optional 的 `UInt64`**，
> `.empty` 就是 `0 / 0`（`Services/Performance/PerfReadoutCells.swift:83`）——
> **照直渲染就是"0 B"**，把"没测到"说成"测到 0"，正是本仓 ④⑤ 两类事故的形状。
>
> ⇒ 正确路线**不是让页面去读原始格**，而是继续走 `SystemReadings`：
> 它是三态判定的唯一归属（四条 guard：`snapshot == nil`、`memoryTotalBytes > 0`、
> `pressure != .unknown`、`usedBytes > 0` 才算有证据），迁移只该改"**上下文怎么来**"，
> 不该把判据搬进页面、也不该为此改格类型的字段。
> 所以那 3 处的做法是：**把 `SampleContext.from(_:)` 改成从细粒度格拼**（一个文件、一处），
> 五个子视图与徽章继续吃 `SystemReadings`，判据一字不改。
>
> 顺带一句：`migration` 的提示语对这三处偏简单——**那句是给 7 处 1:1 用的**，
> 这 3 处请按本节办。
**验收仍然不认口头**：`python3 scripts/trace_report.py migration` 报 0 → 我把
`coarseCallSiteCeiling` 拧 0 → 再翻 `consumptionGateOpen`。**这批折进哪一轮做都行，
但只要它没做，T1（交互期 hitch = 0）就没有可交的证据**，而这是目标里排第一的那条。

## 0. 消费什么（都已进 main，不用等）

`state.monitor` 上的 9 个独立观察格与派生入口，签名与语义见
`docs/superpowers/specs/2026-09-20-performance-120hz-design.md` §5.3。要点：

- 读某一格只会因**那一格**变化而失效；同值写入不产生第二次唤醒。
- `curve.value` **已经切好窗口**，视图里不要再 `suffix`。
- `cpuRanking/memoryRanking/groupRanking` **已经排好序**，视图里不要再 `sorted`。
- 节奏文案一律 `sampleIntervalText` / `windowSeconds(pointCount:)`，不要再写 `1.5`。
- 滚动与拖窗引起的实时暂停**已由 `AppState` 统一接管**，页面只在"切页动画"这类自己知道的时机
  用 `beginInteractionPause(.pageTransition)` / `endInteractionPause(.pageTransition)`，**不要接第二条**。

## 0.3 重派前请先各建一棵新树——三家的工作树与分支已随 M2 清掉了

2026-09-20 22:24 实查：`git worktree list` 只剩主树、`ws/chief`、`ws/perf-base` 与 WorkBuddy 的树，
`git branch --list 'ws/*borderless*'` **一条不剩**，`git stash list` 为空。
也就是说 §0.2 那 16 处目前**既没有工作树也没有分支**可以承接——重派必须先建树：

```bash
cd /Users/one/Documents/Tcoder
git worktree add .worktrees/o-perf-migration -b ws/o-perf-migration main
cd .worktrees/o-perf-migration/TcoderMonitor
./scripts/locked_build.sh build && ./scripts/locked_build.sh test   # 本机第一道：双绿
```

改完之后按既有两道门走（**不要直接合 main**）：

```bash
git add <你改过的文件> && git commit -m "WS-O(§0.2): 4 处粗读点上收细粒度格"
./scripts/premerge_check.sh ws/o-perf-migration      # 回执按头 SHA 命名
cd /Users/one/Documents/Tcoder && git worktree remove .worktrees/<树名>   # 由总工或自己清，别留
```

三条现场约束（都是今天真咬过的）：
- **锁按树独立**：`locked_build.sh` 的锁在各树自己的 `.build/agents.lock`，
  所以"一家只跑一个编译"是**约定**不是机制——请自觉，别和别的流同时抢 CPU（读数会被污染）。
- **不要动 `Design/**` 与 `App/Theme.swift` 的取值**（归 UI 总工），这单只改读法；
- **不要为了少改而新增第 17 处粗读**：棘轮零余量（`1/1 59/59 10/10 2/2` 与粗读 `16/16`），加一处当场红。

### 为什么这 16 处现在更是唯一有收益的路

同一轮把 §5.4 那两笔欠账也量掉了（`PerfMainThreadBudgetTests`，夹具是取证沙箱里的**真报告** 42,663 字节）：

- 一次 `upsertReport`（encode + 写报告 + 写注册表，全在主线程）**中位 0.5 ms**、p95 1.0 ms；
- 启动同步解码 4 份真报告 **中位 1.3 ms**（占 T4 冷启动预算 0.13%）。

⇒ **持久化不占主线程预算**，两笔都结案为"不动"。
于是 §1 那 10.8~24.8 ms 的 app-update 只剩一个怀疑对象：**视图图更新**，
也就是你们这边那 16 处粗读点。这条读数不出自推测，出自把候选逐个排除。

### M2 终测要预约窗口（先到先得，别同时上）

```bash
pgrep -x TcoderMonitor | wc -l        # 必须是 1（被采的那一个）
lsappinfo info -only name $(lsappinfo front)   # 前台必须是 Tcoder
pgrep -f 'swift-frontend|swift-build' | wc -l  # 必须是 0
ls -d /tmp/tcoder-capture.lock 2>/dev/null     # 取证锁必须空闲
```

四条都满足才跑 `./scripts/perf_harness.sh idle <目录>`（或 `interact`，需要真人持续滚动）。
不满足时脚本自己的 `preflight_context` 会**直接拒跑**并写明缺哪一条——那不是脚本坏，
是它在拦第三次"未受控基线"（spec §1.3 已经作废过两批这样的数）。
一次完整前后对比约 **5 分钟**（`idle`×3 + `interact`×3，各含导出与解析）。

## 1. WS-W（性能·日志·健康三页）—— 已随 `96761b7` 交回，**现在就能排**

| # | 工 | main 上实测现状 | 交回时要拿出的东西 |
|---|---|---|---|
| W-1 | `body` 内同步文件 I/O 归零 | `LogsView.attachedItems` 仍是**计算属性**，一次 body 被读 **4 次**（`body` 的 `if !attachedItems.isEmpty`、清空按钮的 `isEnabled:`、"已附加 N 个文件"文案、`ForEach`），每次对每个附加文件走一趟 `FileManager.attributesOfItem`（`LogsView.fileSize(of:)`） | 改成 `@State` + `.task` 载入，或让它成为真正缓存的存储值；给出**每 body 的 syscall 次数改前/改后**。`fileExists` 在 `chooseLogFiles()` 按钮动作里，**不算渲染路径、不用改** |
| W-2 | 曲线降本 | `PerformanceLiveCharts.trustedMemory` 仍是计算属性，一 tick 被跑 **4 遍**（`memoryAxis` 内 2 次 + 曲线 1 次 + `rejectedMemoryPoints` 为拿一个计数把整数组重过滤一遍再丢弃）= **360 个 `SampleContext`/tick** | 每 tick **≤ 1 遍**：`trustedMemory` 改存储值或直接消费 `monitor.curve.value`；**计数不许靠重过滤整数组来求**。停在性能页跑 `perf_harness.sh idle`，给出 app-update 相位 |
| W-3 | 轴标签 formatter | `Views/PerfLogs/ChartChrome.swift` 里仍有 1 处 `DateFormatter()` 现造（在轴标签循环内） | 提 `static let`；`PerfHitchGuardTests` 的 `directFormatters` 该文件命中 0 |
| W-4 | 进程榜 | 榜的行数与内容口径**不许变**；排序必须消费 `memoryRanking/cpuRanking`，视图内不得再 `sorted` | 交改前/改后"视图里 `sorted` 次数" |
| W-5 | 迁移到细粒度格 | 三页仍在读粗表面：`latestSnapshot` 4、`monitor.history` 5、`topProcesses` 1、`trackedGroups` 1（全 Views 口径） | `PerfInvalidationRatchetTests` 的粗表面基线**按流下降到 0**；不许新增粗表面读 |
| **W-6（性能轮自己引进的，优先做）** | 「重新采样 / 立即采样」**点击后没有任何"已受理"反馈** | `sampleNow()` 现在只 `scheduleCollection()` 并立即返回最近一帧（冷启动第一帧除外）；服务侧 `isCollectingForDisplay` 在 `MachSystemMonitor` 被写 **4 次**，但 **`Views/**` 里零读取**——两个入口是 `PerformanceView.controls` 的「重新采样」与 `DashboardLiveReadout.livePerformanceGroup` 的「立即采样」 | **性质要说准：这不是伪造读数**——屏上那些值本来就是 ≤1.5 s 前的真实一帧，与常态节拍同旧。缺的是 T7 的交互反馈：点击 → 视觉响应 ≤100 ms。做法：按钮消费 `monitor.isCollectingForDisplay`（进行中态 / 防重复点击），或把"已排队采下一帧"写成一行状态文字。<br>这条由性能轮引入：改前 `sampleNow` 同步扫全量（占主线程，正是 T7 要消掉的东西）但按钮"看起来立刻变了"；改后不卡了，反馈却归零。**两头都要，不是二选一。** |


已完成的一条（不必重做）：**节拍字面量 5 → 1**，`sampleIntervalText` 已接上真值。

## 2. WS-P（代码 / 复杂度 / Git / 贡献者 / 依赖五页）—— 待你收流后排上

| # | 工 | 实测现状（同一口径） | 交回时要拿出的东西 |
|---|---|---|---|
| P-1 | 密集矩阵降本 | `ContributorHourRow`：30 行 × 24 柱 = **720 个 `RoundedRectangle` + 720 个 `.help(String(format:))`**，`peak` 每柱重算；`GitActivityHeatmap`：168 格 + 168 tooltip，`intensity` 内两次 `.max()` | 改 `Canvas` 或懒加载；交**渲染期视图实例数**改前/改后，并写清算法（调用点计数 ≠ 渲染实例） |
| P-2 | 长列表懒加载 | **`LazyVStack` 全仓仍为 0**（`LazyVGrid` 已有 11 处，那些是 tile 网格，**别动**）；`DependenciesView` 用 `ScrollView{VStack}` 一次实例化 N 生态 × 40 行 | 名下长列表改 lazy；列头只能**调用** `Design/DataTable.swift`（红线 1），要加列能力报契约缺口 |
| P-3 | body 内派生集合缓存 | `DependencySafetyVerdict` body 内构造 4 次（每次 `flatMap`+`filter` 全量依赖）；`CodeRiskAnalysis.suggestions` ≈10 次 filter/map/max/reduce；`CodeDuplicationBlockRow.hint` 对全部 occurrence 做 `pathTail`；Views 内 `.sorted` 命中 2 | 命中数进 `PerfHitchGuardTests` 的 `fullSort` 棘轮（基线 10），**只减不增** |
| P-5 | 稳定 identity | `id: \.offset` **4 处**、`id: \.self` **8 处**（另有 `\.element` 6 / `\.key` 1 / `\.raw` 1 属可接受形状） | 名下页 `\.offset` 归零；`\.self` 只留在真正不可变且唯一的字符串键上，逐条给理由 |
| P-4 | 扫描离开主线程 | 实测扫描耗时 **Git 11.4 s / 8.0 s、代码 1830 ms**；5 分析器 `async let` + 16 路 `classifyConcurrently` | 扫描运行中点击响应 ≤ 100 ms（T7），交 `perf_harness.sh` 扫描期读数；**扫描结果数值必须逐位不变**（不许为提速改口径） |

## 3. WS-O（侧栏 / 外壳 / 总览）—— 待你收流后排上

| # | 工 | 实测现状 | 交回时要拿出的东西 |
|---|---|---|---|
| O-1 | 侧栏脱离心跳失效面 | `ProjectSidebar` 仍读 `state.monitor.latestSnapshot`（实测在 `Views` 的 4 处里），其失效域含整个 `List` 内容 | 停在总览页跑 `idle`，`potential-hangs` 与主线程热点前列应显著改善；交同形状对照表 |
| O-2 | 总览脱离整页重算 | 同上：总览 body 直读粗表面 + 历史切片 | 主线程热点第一名不再是 `_updateViewGraph`；总览 app-update ≤ 8.33 ms |
| O-3 | `AnyView` 归零 | 全 Views **13 处**（含 `GlassSection.trailing: AnyView?` 声明 1 处） | 改 `@ViewBuilder` / 泛型 `Trailing`；`AnyView` 计数 0 |
| O-4 | 切页首帧 | `switch` 档读数尚未建立（尺子刚修好首帧口径，见下） | 交改前/改后同形状读数；**测不到就明写"未覆盖"** |

## 4. 三条共同约束（不遵守会导致整批退回）

1. **不许为了让守卫绿而放宽阈值或调低基线**（`PerfHitchGuardTests` / `PerfInvalidationRatchetTests` /
   `PerfCadenceSingleSourceTests` 的 `knownBaseline` 只能由改动方在提交信息里写清理由后**下调**，不许上调蒙混）。
2. **诚实性语义一条不降级**：两帧才出速率、缺数据 `--`、不可信点剔除并计数、轴台阶 ∈{1,2,2.5,5}×10ⁿ
   且只抬不降 ≤2 倍。`PerformanceDisplayTests` / `PerformanceMemoryHonestyTests` 是硬门。
3. 报告里没有与 §1~§3 对应口径的**改前/改后数字**，按未完成处理。

## 5. 性能侧欠大家的两件事（我这边排，不用你动）

1. **受控的改动前/改动后帧率对比还没跑**——尺子的 `switch` 档首帧口径刚修正（此前 `first_frame_ms`
   恒等于录制时长），且按 16:57 之后的冻结约定，我在你收完三家之前不合 main。
2. `ProjectStore` 主线程编码/启动同步解码两项**待量化**才决定动不动（规范 §5.4）。
   持久化不做投机手术：它异步化会引入"退出前未 flush 就丢报告"的新风险，而 `e2e_check.sh`
   正靠读回这些 JSON 判定。

## 6. 取证协作（已按你的锁走）

- 我这边拍帧/录 trace 一律先 `git merge main`（含你的 `0578a7c` 拍图互斥锁），
  用 `TCODER_STREAM_NAME=perf`，**不绕过锁**；900 s 上限目前够用，若我要跑整轮九页 × 深浅再找你改可续租。
- 深色外观固定用 `osascript ... set dark mode to true`，拍完恢复（`defaults write -g AppleInterfaceStyle`
  在本机不生效，这条我已记进记忆）。

> **12:19 落地被别人的文件挡住（事实与处置）**
> `./scripts/premerge_check.sh ws/perf-base` 在 `99097e1` 上 897 例 **1 failure**，
> 唯一失败是 `X3TestSizeAuditTests`：`LocalizationGuardTests.swift 408 行`（>400 线）。
> 归属：`dd523ed`(P5-d) 给该文件 +30 行推过线，`ad081dd`(P5-d2) 未回收；
> **main 自身同样红**（我已独立 `wc -l` 复核 main 与我树都是 408）。
> 处置：三条禁令——不改那个文件、不改阈值、不自家豁免；等拆完我对现头重跑一次门禁再落。
> 复用价值：这是**第二次**同一文件撞同一条线（上次 507→371，`64b9c15`）。
> 若还想省事，正解不是提高 400，而是把"给守卫测试加用例"的默认落点改成分片文件
> （`LocalizationGuardTests+XXX.swift`），并在提交前跑一次 `wc -l Tests/**/*.swift | awk '$1>380'` 自查。

---

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
