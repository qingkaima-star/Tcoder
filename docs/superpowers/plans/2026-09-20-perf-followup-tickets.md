# 性能追加工单（发给 UI 总工的三条页面流）

- 发件：第四轮「120Hz 性能」总工（`ws/perf-base`）
- 收件：第三轮「简约无界」UI 总工 —— 由你排进对应流的**追加**批次
- 依据裁定：用户 2026-09-20 16:57（`AGENTS.md`「双总工协作裁定」）——页面树归 UI 总工派发与收回，
  性能侧只出工单、**不另起会话写 `Views/**`**。本文件就是那份工单，性能轮不动手写这些文件。
- 度量口径：本文件所有数字都是在 **`main = 96761b7`** 上用宽松口径实扫得到的
  （`git grep -h -E <模式> refs/heads/main -- 'TcoderMonitor/Sources/TcoderMonitor/Views'`）。
  严谨口径以守卫自己的计数为准（`PerfHitchGuardTests` / `PerfInvalidationRatchetTests`）。

## 0.1 【最高优先】细粒度契约目前消费数为 **0**

按守卫自己的正则复算 `main = a99f38b` 的 `Views/**` + `App/**`：

- **粗粒度读点 16 处 = 棘轮上限 16（零余量，再加第 17 处即判红）**
- **细粒度读点（`monitor.<格>.value`）0 处**

含义说白：**M0 服务侧把一次 tick 的写入面收窄了，但页面一格都没接**，
所以 1.5 秒一次的整棵重算**依旧在发生**，用户端目前**不会感到任何帧率改善**。
T1/T2 在这 16 处迁完之前不可能达标——**这不是"优化项"，是其余性能工单的前置**。

16 处逐条（迁完后由总工把上限往下拧，最终 0）：

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

## 0. 消费什么（都已进 main，不用等）


`state.monitor` 上的 9 个独立观察格与派生入口，签名与语义见
`docs/superpowers/specs/2026-09-20-performance-120hz-design.md` §5.3。要点：

- 读某一格只会因**那一格**变化而失效；同值写入不产生第二次唤醒。
- `curve.value` **已经切好窗口**，视图里不要再 `suffix`。
- `cpuRanking/memoryRanking/groupRanking` **已经排好序**，视图里不要再 `sorted`。
- 节奏文案一律 `sampleIntervalText` / `windowSeconds(pointCount:)`，不要再写 `1.5`。
- 滚动与拖窗引起的实时暂停**已由 `AppState` 统一接管**，页面只在"切页动画"这类自己知道的时机
  用 `beginInteractionPause(.pageTransition)` / `endInteractionPause(.pageTransition)`，**不要接第二条**。

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
