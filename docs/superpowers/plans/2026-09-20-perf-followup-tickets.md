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
| `Views/Shell/ProjectSidebar.swift` | 411 | `state.monitor.latestSnapshot`（喂 `LiveCPUBadge`） | `monitor.cpu.value`（badge 只需 CPU） |

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
- 位置：`PerformanceView` 10、`DashboardView` 3、`LiveReadings` 2、`ProjectSidebar` 1；
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
> `testCoarseReadoutSitesSplitIntoLoadBearingAndIncidental` 每次跑都打印
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

- **承重的 10 处**（读上面那两个无闸门属性）：`DashboardView` 333 / 458 / 459、
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
  2. `DashboardView.swift:333` `private var snapshot: SystemSnapshot? { monitor.latestSnapshot }`
     —— 页内 10 处读点共用这个别名，实际只碰 `disk*/network*` 四个速率字段（都在 `rates.value`）；
  3. `ProjectSidebar.swift:443` `LiveCPUBadge(snapshot: monitor.latestSnapshot)` —— 子视图收整份快照，
     它要的只是 `cpu.value.usage`（＋ `coreCount`）。
  这三处**不要**原地换成 `monitor.latestSnapshot` 的另一种写法：那还是同一棵 body 每 tick 重算。
- 顺序建议：**先做那 7 处 1:1 的**（零判断、当场能让 `migration` 掉 7 个），
  再按 `ProjectSidebar` → `DashboardView` → `PerformanceView`+`LiveReadings` 做那 3 处（由小到大，
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

### 第 1.5 步（与第 1 步同批、但收益不同期）：渲染路径剩下的 12 处**全在页面侧**

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
**九个文件全是 0**（粗读点名册里也只有 `DashboardView`/`LiveReadings`/`ProjectSidebar`/`PerformanceView`）。
所以它们的 body 不随心跳失效，里面的排序/I-O 不会每 tick 跑。⇒ **它们是"切页与滚动期"的成本，归 T1 管，不归 T2 管**。
派单时别把它们和那 10 处承重粗读点混成一句"清完渲染路径"，两批的验收证据不是同一个窗口。

正解形状与 `cpuRanking` 同一种：**排一次、放进产出，页面读现成的**
（`PerfLeads.derive` 就是在采集侧一次性排好、页面零排序）。依赖表/日志文件表那两处大集合
适合挪到分析侧产出有序结果，页面只读——**采集侧改动归我，页面那一行删除归你**。
要的话我先在服务端把有序版本准备好（不碰 `Views/**`），你那边只剩删调用。

### 第 2 步：帧率复测（分两小步，因为其中一步需要人手）

```bash
./scripts/perf_harness.sh selfcheck          # 11 项，红了所有读数作废——先量尺子再量代码
./scripts/perf_harness.sh idle   /tmp/tcoder-perf-after-<rev>     # 2a：不需要人，只要机器安静
./scripts/perf_harness.sh interact /tmp/tcoder-perf-interact-<rev> # 2b：**这 20 s 要有人持续滚动**
./scripts/perf_harness.sh report <目录>       # 表头会写测量期间，idle 那批明说不得交 T1
```
- 五维闸门：实例数=1、前台是被测 App、有在屏窗口、load1 ≤ 核数×1.5 且无并发 swiftc、**人手静默 ≥5 s**；
  任一不合格脚本直接拒跑（那不是脚本坏，是它在拦第三次"未受控基线"）。
- **改前对照**只能走 xctrace：`/tmp/tcoder-before.app`（rev `415f0f0`、sha `54005bc4…`）里
  没有 `FramePulse`。`probe` 档只对改后产物有意义，不许左右互比。
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

## 0.5 交接状态（09-21 00:31）——写给"一个人接两条线"的那位，免考古

**已进 main 的性能侧东西**（`main = f9841ae` 之前的 `3a3381c`）：
细粒度九格契约 + 交互期引用计数暂停（`Services/Performance/MachSystemMonitor.swift`、`App/AppState.swift`）、
Design 令牌缓存、尺子五档 + `probe` + `selfcheck`（11 项）、`migration` 命令、
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
   **落位时必须顺手把 §3.6「收益分级」整段搬进一个新的 `PerfInvalidationRatchetTests+CoarseWeighting.swift`**：
   加完那段之后主文件已经 **781 行**，离 800 上限只剩 19 行——再写一条测试就会把 main 弄红，
   而"拆文件"才是修复（改阈值不是，这条已被反复钉过）。现在不搬是因为搬动要把
   `coarsePattern` / `scanHits` / `codeLines` 从 `private` 放开成 `internal` 才能跨文件共用，
   而我**不接受复制一份尺子**（两套口径必然漂，#44 就是这个形状）。
   顺序反过来会变成"我先进、他们拆的时候撞我的 hunk"，冲突由不懂这套口径的人解更容易出事。
   **好消息已经核过**：X3 把口径常量（`coarsePattern` / `finePattern` / `coarseCallSiteCeiling` /
   `consumerDirectories` / `knownBaseline`）**留在主文件里没搬**，所以 `trace_report.py migration`
   那把"从守卫里现读尺子"的机器在 X3 树上照样跑得出 `16/16/0`——**拆文件没有把尺子的取数口拆断**。
   若后续谁把这些常量搬进 extension，`migration` 会**报错而不是用一份手抄的旧尺子**，那是设计行为。
1. **§0.4 第 1 步**：**10 处承重**粗读点迁完（`python3 scripts/trace_report.py migration` 报 0）
   → 我再把 `coarseCallSiteCeiling` 拧 0、翻 `consumptionGateOpen`；
2. **§0.4 第 2 步**：约 5 分钟安静窗口（`idle`×3 不需要人；`interact`×3 需要你持续滚 20 秒）。
   被挡过两次的真实原因都写在 `measurement-context.txt` 里，脚本会自己拒，不用你判断。

**这一轮还查到两件与派单有关的事实**（都影响"下一步做什么"）：
- **`ws/x0-chief`、`x1`、`x2`、`x3` 四棵树里 16 处读点一处没动**（01:2x 逐树跑 `migration` 全是 `16/16/0`）。
  这批是**体量/圈复杂度拆分轮**，不是 120Hz 轮；`x2` 那位还在二次拆我的 `trace_report.py`、
  把 `selfcheck` 搬进 `perf_selfcheck.sh`（读数我核过没变）。⇒ **交互期 hitch 的收益仍然完全押在第 1 步上**，
  它一旦再排到下一批，这一轮的 T1 就没法结。
- `ws/chief`（`f5c0449`，13:30）**已全部在 main 里、树是干净的**，是上一轮留下的空树。
  不是我建的、也不归我清，报给接管者处置：`git worktree remove .worktrees/chief && git branch -d ws/chief`。

**别做这三件事**（都是这一轮踩过或量过的）：
不要为了"零动态色"删取色引用（终点不是 0，见规范 T5）；
不要把任何阈值调松来变绿（`ceiling = 0` 与 ≤800 行那条一样，"改这里的数字不是修复"）；
不要拿 `probe` 去和改前对照物比（`/tmp/tcoder-before.app` 里没有 `FramePulse`，只能同走 xctrace）。

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
| **W-6（性能轮自己引进的，优先做）** | 「重新采样 / 立即采样」**点击后没有任何"已受理"反馈** | `sampleNow()` 现在只 `scheduleCollection()` 并立即返回最近一帧（冷启动第一帧除外）；服务侧 `isCollectingForDisplay` 在 `MachSystemMonitor` 被写 **4 次**，但 **`Views/**` 里零读取**——两个入口是 `PerformanceView.controls` 的「重新采样」与 `DashboardView.livePerformanceCard` 的「立即采样」 | **性质要说准：这不是伪造读数**——屏上那些值本来就是 ≤1.5 s 前的真实一帧，与常态节拍同旧。缺的是 T7 的交互反馈：点击 → 视觉响应 ≤100 ms。做法：按钮消费 `monitor.isCollectingForDisplay`（进行中态 / 防重复点击），或把"已排队采下一帧"写成一行状态文字。<br>这条由性能轮引入：改前 `sampleNow` 同步扫全量（占主线程，正是 T7 要消掉的东西）但按钮"看起来立刻变了"；改后不卡了，反馈却归零。**两头都要，不是二选一。** |


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
