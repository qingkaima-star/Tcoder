# Tcoder 性能规范 v1 · 120Hz 流畅（含"简约无界"合并轮）

- 状态：已批准执行（用户 2026-09-20 15:0x「给自己定个目标 开始吧」）
- 负责人：总工程师（性能 + 设计总监双身份）
- 基线提交：`2981ae5`（行为等价于产物 `465f5a6`，见下）
- 合并范围：本轮与 `2026-09-20-borderless-minimal-ui-redesign-design.md` **同一批文件、同一次交付**，
  不再分两轮付两遍钱。视觉契约看那份，性能契约看这份；**冲突时以本文件的"不掉帧"为硬约束，
  以那份的"观感"为软目标**——凡两者冲突处必须在交付报告里点名，不许静默取舍。

---

## 0. 一句话病因（实测，非推断）

**空闲不动的时候，这个 App 每 1.5 秒把自己钉住 5~7 帧。**

## 1. 改动前基线（xctrace 只读采样，pid 96992 = `dist/Tcoder.app`，release，`GIT_CLEAN=true`，rev `465f5a6`）

工具：`xcrun xctrace record --template "Animation Hitches" / "Time Profiler" --attach <pid>`，
沙箱无需（未写 `defaults`、未启动第二实例）。解析器 `scripts/perf_harness.sh` 内嵌的
`trace_report.py`（本文件写作时的原始数据在 `/tmp/tcoder-perf-baseline/`，**是产物，不入库**）。

| 指标 | 实测值 | 预算 | 判定 |
|---|---|---|---|
| 内建屏 3024×1964 最大刷新率 | **120 Hz**（`device-display-info`，主显=Yes） | — | 8.33ms/帧预算成立 |
| 外接 4K 最大刷新率 | 120 Hz | — | 同上 |
| render 相位（2394 帧） | p50 2.73 / p95 4.06 / p99 4.77 / max 25.12 ms | ≤8.33 | **健康**，超预算 **10 帧 = 0.42%** |
| app-update 相位（7 个 hitch） | **10.8 / 11.1 / 13.2 / 15.0 / 16.0 / 18.6 / 24.8 ms** | ≤8.33 | **全线超预算 1.3~3.0 倍** |
| hitch 次数 / 速率 | 7 次 / 20 s = **0.35 /s** | 0（硬上限 <1/s） | 超 |
| hitch 帧时长 | 33.33 ~ **58.33 ms**（=4~7 帧） | 0 | 超 |
| `potential-hangs`（Potential Interaction Delay） | **13 次 / 25 s**，中位 **42.6 ms**、最大 59.8 ms、累计 **573 ms** | 单次 ≤8.33 ms | 严重超 |
| 主线程 CPU | 684 / 807 样本（**占全进程 84.8%**），25 s 内 ≈ 684 ms | 空闲 ≤2% 且零突发 | 达标但**全挤在 13 次突发里** |
| 主线程热点 | **64.3% 在 `ViewGraphRootValueUpdater._updateViewGraph` / `AG::Graph::UpdateStack::update()`**；另有 `_platform_memmove` 16、`iokit_user_client_trap ← IOGPUCommandQueueSubmitCommandBuffers` 17、`icu::UnicodeString::setToUTF8` 4 | — | 病因=视图图更新面，不是算不动 |

**两次心跳的间隔实测为 1.50 / 1.51 / 1.50 / 1.65 s** —— 与 `AppState.init` 里
`monitor.start(intervalMilliseconds: 1_500)` 同相位。**约每两次 tick 就有一次 hitch（13 tick / 7 hitch）。**

### 1.1 这次测量推翻了我自己的排序（备案）

勘查阶段我把"每屏 88 层材质+投影"列为头号嫌疑（`Glass.materialLayer` 一处 `.shadow` 被 88 个入口继承）。
实测 **render p95 = 4.05 ms、p99 = 4.67 ms**：在 M5 Pro 上合成根本不缺时间。
所以：

1. **`Design/Glass.swift` 表面换血继续做，但理由改成"观感（明暗关系反了、投影滥用）+ 顺带省 GPU"，
   不得再宣称它是性能主因。** 谁在报告里写"去材质所以不卡了"就是错证据。
2. 头号工是 **收窄一次 publish 引起的视图图更新面**（§3 T2/T5）。

### 1.2 勘查数字勘误（总工独立计数复核，15:37）

三名勘查子代理的结论方向正确，但**四个数字是错的**，其中一个会造出假零守卫。
以本表为准（计数命令附后，口径 = `grep -rhoE <正则> <目录> --include='*.swift' | wc -l`，在 `m0-borderless-base` 之后的 `ws/perf-base` 上跑）：

| 项 | 勘查报的 | **实测** | 影响 |
|---|---|---|---|
| Views 内动态色成员（`.textColor/.graphicColor/.badgeFill/.onFillColor`） | 115 | **116** | 差 1，无实质影响 |
| `id: \.offset` / `id: \.self` | 8 / 7 | **4 / 8**（另有 `\.element` 6、`\.key` 1、`\.raw` 1） | **两个数写反了**，工单 P-5 按实测派 |
| "全仓 0 个 Lazy" | 0 个 LazyVStack | `LazyVStack` 确实 **0**，但 **`LazyVGrid` 已有 11 处**（总览/健康/代码/依赖/日志/性能/Git/贡献者的 tile 网格） | 工单 P-2 必须收窄成**只改长列表**，误改已是 Lazy 的网格属于白烧 |
| "`LogsView.attachedItems` 在 body 里做 `stat()`，每次 body 3~4 轮 syscall" | 3~4 轮 | **两个半边各对一半**：符号不是 `stat(` 而是 `FileManager.attributesOfItem`（定义处 1 个：`LogsView.fileSize(of:)`）；但 `attachedItems` 在**一次 body 里被求值 3 次**（`LogsView.body` 的 `if !attachedItems.isEmpty`、"已附加 N 个文件" 文案、`ForEach(attachedItems)`），每次求值对**每个附加文件**一趟同步 syscall ⇒ "3~4 轮"说的是求值次数，没错。另：`fileExists` 在 `chooseLogFiles()` 按钮动作里，**不属渲染路径、不用改** | 工单 W-1 已按实测改写；② **T5-③ 守卫若只正则匹配 `stat(` 会永远得 0 = 假零守卫** |
| Views 内 `.font(` | 183（含 Design） | **Views 内 148**，Views+Design 合计 183 | 口径分两个数写，别当同一个 |
| `trustedMemoryPoints` 每 tick 跑几遍 | 3 遍 / 270 个 `SampleContext` | **4 遍 / 360 个**：`PerformanceLiveCharts.memoryAxis` 一次 body 内访问 `trustedMemory` **两次**（`.map` 求 peak + `isEmpty` 判空）、曲线再取一次、`SystemReadings.rejectedMemoryPoints` 又跑一遍——**而它只是为了拿一个计数，把整数组重过滤一遍就把结果丢掉** | 工单 W-2 已按实测改写；这第四遍是最容易改也最没人想到要改的 |
| 全仓 `#available` | 4 处全在 `Design/Glass.swift` | 9 处，分布在 `Design/Glass.swift` + `Design/GlassComponents.swift` | 两份都在 `Design/**`，**"页面不散写"红线未被违反**，不改工单 |
| `Sources/**` 实现文件数 / 超 800 行文件数 | 110 / — | **110 / 0** | 与 `SourceFileReachabilityTests.censusBaseline = 110` 一致；M0 每加一个新文件该基线 +1，**只由总工改** |

> **给 R 的硬要求（写在这里防止守卫长成假零）**：T5-③「渲染路径同步 I/O」的正则**必须至少覆盖**
> `fileExists`、`attributesOfItem`、`contentsOfDirectory`、`Data(contentsOf:`、`String(contentsOf:`、
> `stat(`、`lstat(`、`FileManager`；且元测试要用 **`attributesOfItem`** 这种真实形状造坏样例，
> 而不是用最显眼的 `stat(`——否则扫描器只会抓一种写法却对外宣称抓全部。



### 1.3 **基线状态：未成立**（15:20 自我收回，别拿下表当"改动前"）

下表（run1）是**单一采样、条件未受控**。同一份 release 二进制（`465f5a6`）后来又采了两次，
三者互相矛盾，而代码一行没变：

| 样本 | 时刻/时长 | hitch | app-update 相位 | 交互延迟 | 当时的机器条件 |
|---|---|---|---|---|---|
| run1 | 15:03 / 20s | 7 次 = 0.35/s | **10.8 ~ 24.8 ms** | 13 次，中位 42.6ms | **我正在并发跑几十个 `swiftc -typecheck` 探针**（抢满 15 核）→ 抬高 |
| run2 | 16:03 / 25s | 2 次 = 0.08/s | — | 1 次 3243.8 ms | 刚 SIGTERM 掉 6 个残留实例；那个 3243ms 像被挂起 |
| run2b | 16:12 / 20s | 2 次 = 0.10/s | **1.9 ~ 3.0 ms** | **0 次** | `vm.loadavg = {82.38 …}`、**前台是别的 App** → 后台窗口被节流，假性地好看 |

**所以**：既不能说"改动前 7 hitch / 24.8ms"，也不能说"其实只要 1.9ms 早就达标了"。
两把读数都没被条件约束住。**处置**：`perf_harness.sh` 已加 `preflight_context()`
（并发编译器 / `load1 ≤ 核数×1.5` / 被测窗口必须前台 / 非 hidden，全部连同读数落
`measurement-context.txt`），按该协议**连测 ≥3 次且取值一致**的那一组，才是本规范"改动前基线"一栏该填的数。
在此之前，§3 的 T1/T2 目标值仍按 Apple 口径推导（120Hz ⇒ 8.33ms/帧），**不依赖**这张表；
但 §6 验收里"7 → 0"这一项在基线重定之前**不得申报达成**。

### 1.4 一次"两把尺子对不上"的结案：错的是我，不是工具

`perf_harness.sh report` 重打 run1 时，`render 超预算帧` 给 **10 帧 (0.42%)**，
我此前手算给 **5 帧 (0.21%)**。我一度判工具坏了（理由看起来很像样：那 10 个值恰好是 5 个值各出现两次，
而两边行数都是 2394）。**结论反了**：

- 我的复核脚本写的是 `val.get(int(m.group(2)))`，而 id 字典的键是**字符串** ⇒
  **所有 `<duration ref="N"/>` 形式的时长被静默当成 0**。
  2394 行里约 54 行走 ref，正好就是"消失的那 5 帧"。
- p50/p95 只差在小数点后第二位，所以这个 bug **不会**在分位数上露馅，只在"超阈值计数"上露馅——
  而阈值计数恰好是验收要看的那一列。
- 这是 xctrace XML 的 id/ref 内部引用**第 3 次**咬人（前两次：线程 `fmt` 只出现在首次出现的行、
  窗口号 `fmt`）。**同一族坑第 3 次，说明"我记得这个坑"不等于"我的每条新代码都不踩它"。**

**处置（已落到尺子里）**：`trace_report.py` 新增 `cross_check_durations()` ——
汇总表里 render 一列**必须用两条独立解析（`Doc` 的 id/ref 解引用 vs 逐行正则）比对**，
不一致就把这一列标成"未报（两把解析不一致）"并打印差异，**绝不允许挑一个好看的数用**。
§1 的 render 行已按工具口径改正：**p50 2.73 / p95 4.06 / p99 4.77 / max 25.12，超预算 10 帧 = 0.42%**。
（结论不变：render 相位健康，不是本轮瓶颈；改的是数，不是判断。）


## 2. 能力边界（编译探针实测，`xcrun swiftc -typecheck -target arm64-apple-macos14.0`）

| 能力 | macOS 14 下限 | 结论 |
|---|---|---|
| `CVDisplayLinkCreateWithActiveCGDisplays` | 可用 | 帧节拍内建探针的**兜底**时间源（主时间源见 §2.1） |
| `CGDisplayCopyDisplayMode(...).refreshRate`、`CGDisplayCopyAllDisplayModes` | 可用 | 运行时取真实 Hz，**不硬编码 120** |
| `os_signpost`（`OSSignpostID` 老式 API） | 可用 | 打点；`OSSignposter` 新式 API 的 `emit`/`signpost` 成员在本 SDK **签名不同，用前先探针** |
| `TimelineView(.animation(minimumInterval:paused:))`、`Canvas` | 可用 | 重画曲线/矩阵的原语 |
| `EquatableView(content:)`、`View.drawingGroup(opaque:colorMode:)` | 可用 | 手工短路重算 |
| `CADisplayLink` | **可用——但只能经 `NSView.displayLink(target:selector:)` 拿到**（见 §2.1） | 直接构造子 `CADisplayLink(target:selector:)` 在 macOS **不可用**；成员 `preferredFramesPerSecond` / `frameInterval` / `preferredFrameDuration` 也不可用 |
| MetricKit 的 `MXAnimationDiagnostic` / `MXMemoryDiagnostic` / `MXCPUDiagnostic` | **macOS 上不存在**（只有 `MXMetricManager`、`MXAppLaunchMetric`） | 线上帧率回传方案不成立 |
| `GlassEffectContainer` / `.glassEffect` | 仅 macOS 26 | 闸门仍只准集中在 `Design/Glass.swift` |
| `.containerBackground(_, for: .window)` | 仅 macOS 15+ | 需 `#available` 兜底，同样只准集中在 Design 层 |
| `onScrollPhaseChange` / `onScrollGeometryChange(for:of:action:)` | **仅 macOS 15+**（14 下限报 "only available in macOS 15.0 or newer"） | T3 不能用它们（页面禁散写 `#available`） |
| `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .leftMouseDragged, .rightMouseDragged])`、`NSScrollView.didLiveScrollNotification` | **macOS 14 可用** | **T3 交互期暂停就走这条**（见 §4.1） |
| 本机运行系统 | **macOS 26.5.2** | 真玻璃路径在本机生效，测出来的数就是 26 路径的数 |

### 2.1 纠正一处我自己写错的结论（15:33 复核，编译探针）

本文件初稿在 §2 写过「`CADisplayLink` 不可用 → 照抄 iOS 帧率方案这条路是死的」。**那是错的**，
错因就是我刚在别处提醒过别人的那个坑：**半截探针会得出反向结论**。我探的是
`CADisplayLink(target:selector:)` 直接构造子（确实 "unavailable in macOS"），
但**没有探 `NSView.displayLink(target:selector:)`** —— 它返回的正是 `CADisplayLink`，
且整套在 macOS 14 下限可用：

```swift
let dl = someView.displayLink(target: handler, selector: #selector(H.tick(_:)))  // -> CADisplayLink
dl.add(to: RunLoop.main, forMode: .common)     // 注意：add(_:) 单参版不存在，必须 to:forMode:
dl.isPaused = true                             // 不是 .paused
dl.remove(from: RunLoop.main, forMode: .common); dl.invalidate()
// 回调参数可用成员：timestamp / duration / targetTimestamp
// 不可用成员：preferredFrameDuration / preferredFramesPerSecond / frameInterval
```

**结论改动**：`FramePulse` 的主时间源从 `CVDisplayLink` 升级为 **`NSView.displayLink` 拿到的
`CADisplayLink`**（它是"这个视图所在显示器真正呈现的节拍"，比 `CVDisplayLink` 的"显示器名义节拍"
更贴近用户看到的卡顿）；`CVDisplayLink` 与 `CGDisplayMode.refreshRate` 降为**无窗口时的兜底与名义 Hz 来源**。
两把尺子仍然互相校验，但**不得共享同一盲区**：`displayLink` 挂在具体 `NSView` 上，
测不到"窗口不可见时"的行为，这部分留给 xctrace 外部尺子。

## 3. 目标（T1~T9，全部可机器断言）

### 3.0 口径出处（Apple 原文，不是我自己推的）

来源：Apple Developer Tech Talk **《Explore UI animation hitches and the render loop》**
（`developer.apple.com/videos/play/tech-talks/10855/`），以及其推荐的配套会话
《Eliminate animation hitches with XCTest》（WWDC20 `wwdc2020/10077`）、
《Find and fix hitches in the commit phase》《Demystify and eliminate hitches in the render phase》。

| Apple 原文口径 | 本规范怎么用 |
|---|---|
| hitch =「**any time a frame appears on screen later than expected**」 | 判据定义，不自造 |
| 帧预算：60 Hz 每 **16.67 ms** 出一帧；ProMotion 120 Hz 每 **8.33 ms** 一帧 | T1/T2 的预算值来源（本机 `device-display-info` 实测 120Hz ⇒ 8.33ms） |
| 正式指标是 **Hitch Time Ratio**（一段时间内 hitch 总时长 ÷ 该段时间，单位 **hitch-ms/秒**） | **主指标改用它**；我原先写的"hitch ratio < 0.1%"是自造口径，**撤销** |
| 档位：**<5 无感**；**5–10 用户可察觉、需排查**；**>10 严重影响体验、需立刻处理**；**理想 = 0** | T1 验收线 = **<5，目标 0**；run1 实测 **11.67 ms/s** 属"危急"档 |
| hitch 分 **commit hitch**（本进程错过 VSYNC：布局/绘制/事件处理慢）与 **render hitch**（render server 侧） | 归因分层：本轮打的全是 commit 侧（`_updateViewGraph`），render 侧实测健康 |

**本仓库的算法**：`HTR = Σ max(0, 帧时长 − 预算) / 录制秒数`，数据源是
`Animation Hitches` 模板的 `hitches` 表（帧时长）。这是 Apple 定义的**保守上界**
（它按"晚了多少"算，我们按整帧时长减预算算，不会低估）。已实现进 `trace_report.py`。

- **T1 交互期不掉帧**：切页 / 滚动 / 悬停 / 拖窗 / resize 期间 **Hitch Time Ratio < 5 ms/s，目标 0**；
  p95 帧间隔 ≤ **8.4 ms**、p99 ≤ 16.7 ms。改动前基线（未受控，见 §1.3）**= 11.67 ms/s（`perf_harness.sh report` 实算，非口算）= Apple 的"危急"档**。

- **T2 心跳不越一帧**：1.5 s 一次 publish 引起的 **app-update 相位 ≤ 8.33 ms**（冲刺目标 4.0 ms）。
  起点 10.8~24.8 ms ⇒ 需要 **2~6 倍**收窄，只靠"少画几个点"不可能达到，必须收失效面。
- **T3 交互优先**：滚动 / 拖窗期间冻结实时写入，交互停止 150 ms 后恢复（用户已批准）。
  **不新增"未刷新"占位态**（`DesignAbsenceStateTests` 的 `bypassCeiling = 1` 只减不增），
  暂停期显示的仍是真实末值。若任何一次暂停实测 >500 ms，本条判失败并回退。
- **T4 冷启动**：到可交互 ≤ 1.0 s（`App Launch` 模板），首帧 ≤ 3 个显示节拍。
- **T5 主线程禁则**（静态守卫钉死，见 §4）：`body` 与图表 Mark 闭包内 **0 次** new
  `NSColor` / `DateFormatter` / `NumberFormatter` / `Font`；**0 次**全量 `sorted`/`filter`/`reduce`；
  **0 次**同步文件 I/O（`stat`/`Data(contentsOf:)`/JSON 解码）。
- **T6 合成层预算**：内容层 0 填充、投影只给 `.floating`、每屏材质/backdrop 层 ≤ 2。
  理由记在观感账上（§1.1），不记在帧率账上。
- **T7 扫描期仍可交互**：扫描（实测 Git 11.4 s / 代码 1830 ms）运行中点击响应 ≤ 100 ms，
  分析器不得占住 `@MainActor`；`sampleNow` 这类全量 sweep（260~920 进程）一律离开主线程。
- **T8 诚实性不降级**：两帧才出速率、缺数据 `--`、轴台阶 ∈{1,2,2.5,5}×10ⁿ 且只抬不降 ≤2 倍、
  不可信点从曲线剔除并在卡面计数、`historyTruncated` 窗口标注、零证据不得给满分——
  **一条都不许为了帧率改语义**。`PerformanceDisplayTests` / `PerformanceMemoryHonestyTests` /
  `HealthScore*Tests` 全绿是硬门禁。
- **T9 只减不增**：hitch 数、单次 update 时长、主线程样本占比、T5 三类禁则命中数，
  全部进回归门禁；任何回退判红。**阈值不许为了变绿而放宽。**

## 4. 尺子（M0 先落，先量后改）

1. `scripts/perf_harness.sh`（新）：`before|after` 两个子命令，封装 attach 录制 Animation Hitches +
   Time Profiler → `xctrace export --xpath` 逐表导出 → 内嵌 `trace_report.py` 出一张固定形状的结果表
   （hitch 数、hitch/s、帧时长分布、app-update 分布、`potential-hangs`、主线程热点 Top20、
   按线程样本数）。输出目录**必须带短 HEAD 后缀**（`/tmp/tcoder-perf-<rev>/`），否则后一批覆盖前一批。
   采样路径分三档：`idle`（不碰它，量心跳）、`switch`（`-selectedDetailSection <页>` 逐页重启，
   量切页与冷构建）、`scroll`（若驱动得起；起不动就如实写"未覆盖"，不许拿 idle 的数冒充交互数）。
2. `FramePulse`（新，`Services/Performance/`）：`CVDisplayLink` 时间戳 + 主线程 runloop 心跳看门狗
   + `os_signpost`，**仅 `TCODER_PERF_PROBE=1` 时启动**（常驻开销不可接受），
   读数落 `$TCODER_PERF_OUT` 或 `/tmp` 文件——**取证 print 必须落文件**，`swift test` 会丢子进程 stdout 后半段。
   它是常驻门禁的尺子，与 xctrace 这把外部尺子**互相校验**（两把尺子不得共享同一盲区）。
3. T5 三条静态禁则守卫 + **每条配元测试**（故意造违规样本确认它会红）。理由见记忆
   「扫描型测试要配元测试」：本仓上一轮的病因正是"令牌定义了但零引用"，旧守卫查不出来。

## 4.1 T3「交互期暂停」的实现位置（由探针决定，不由偏好决定）

候选 API 探测结果：`onScrollPhaseChange` / `onScrollGeometryChange` 是 **macOS 15+**，
而红线禁止页面散写 `#available`（AGENTS.md §3 横切约束 1、无界红线 7）→ **不能用**。
可用的是 **macOS 14 就有**的 `NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel,
.leftMouseDragged, .rightMouseDragged])` 与 `NSScrollView.didLiveScrollNotification`。

因此机制定死为：**`AppState` 装一个本地事件监视器记 `lastInteractionAt`**，心跳 tick 到来时
若 `now - lastInteractionAt < 150ms` 就**跳过发布**；页面**零改动**、Design 层零 `#available`。
两条硬要求：
1. **暂停不许丢数据**：跳过的帧仍要进环形缓冲，恢复时一次性补齐；**严禁把暂停期画成 0 或空白**
   （那等于制造假读数，违反 T8 与 `PerformanceMemoryHonestyTests` 的精神）。
2. **暂停不许变成"永远暂停"**：监视器必须成对释放；单次连续暂停实测 **>500ms 即本条判失败并回退**。
   实测方式：`perf_harness.sh` 的 `scroll` 档（驱动得起就用它），驱动不起来就交 `FramePulse` 内建读数，
   两者都拿不到就**明写"未覆盖"**，不许拿 idle 档的数冒充。

## 5. 分工（零文件重叠，按"谁消费谁负责"）

### M0 总工串行（不占三家名额，`ws/perf-base` 一棵树，我 merge）

**实况修订（2026-09-20 15:16，边写边被并行会话抢先落地）**：下表 S/T 两包**已由并行会话的无界基座落进 main**
（`6ca0578` 令牌、`6d7b35e` 表面换血、`04453f6` DataTable 上提，tag `m0-borderless-base`）。
本文件 §1 的基线数字取自 `465f5a6` 产物，即**无界基座之前**的读数——复测时必须注明这一点，
否则会把"表面换血"的收益错记到性能工头上。M0 实际剩余独占有三件：

| 包 | 内容 | 路径 | 归属 |
|---|---|---|---|
| R 尺子 | `perf_harness.sh`、`trace_report.py`、`FramePulse`、T5 守卫 + 元测试 | `scripts/**`、`Services/Performance/FramePulse.swift`、`Tests/TcoderMonitorTests/Perf*Tests.swift` | 总工独占（新建文件，零重叠） |
| P 心跳链路 | `publish` 拆细粒度读模型、派生榜单（`processesByMemory`、`history.suffix(90)`）在 publish 里算一次并缓存、`sampleNow` 移出主线程、T3 交互期暂停 | `Services/Performance/**`(除 FramePulse)、`App/AppState.swift`（本轮解冻，`SystemSnapshot` 契约不动） | **无界三家按 spec 不得碰 `Services/**`，此包总工独占** |
| C 令牌缓存 | `ColorToken.swift` 每次访问 new `NSColor(name:nil){}` → 缓存；`ThemeTokens` 的 `var font: Font {` 计算属性 → `static let`；`ChartTokens.areaGradient` 每调用现造 `LinearGradient` → 按 (index,intensity) 缓存 | `Design/**` | **与无界轮 `Design/**` 归属冲突，待用户裁定后才能动**（见 §7.7） |

`SourceFileReachabilityTests` 的 `censusBaseline`、800 行棘轮、`DesignTokenTests`/`DesignKitTests`
里钉当前值的断言，**只由总工在 M0 串行更新**，三家一律不许自己翻基线。

### M1 三家并行（各一棵工作树、各 ≤3 子代理、一家同时只跑 1 个编译）

| 流 | 页面 | 独占 Services | 性能包（除无界化重排外） | Obsidian |
|---|---|---|---|---|
| **WS-O** 外壳与总览 | `Views/RootView.swift`、`Views/ProjectDetailView.swift`、`Views/DashboardView.swift`、`Views/Shell/**` | — | 侧栏与总览**脱离心跳失效面**（`ProjectSidebar.sidebarFooter`、`DashboardView.snapshot`、`CPUHistoryChart`）、`AnyView` 归零、`ReadoutStrip`、T3 暂停接线到滚动 | `80 WS-O 外壳与总览无界化.md` |
| **WS-P** 代码与 Git 五页 | `Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**`、`Views/CodeGit/**` | `Services/Code`、`Services/Git`、`Services/Dependencies` | 720 柱 + 168 格矩阵改 `Canvas`/lazy、稳定 identity（去 `id: \.offset`）、body 内派生集合缓存、扫描 11.4 s / 1830 ms 离开主线程且不重入 | `82 WS-P 代码与Git五页无界化.md` |
| **WS-W** 性能·日志·评分 | `Views/Performance/**`、`Views/PerfLogs/**`、`Views/Health/**`、`Views/Logs/**` | `Services/Logs`、`Services/Health` | `LogsView.attachedItems` 的 `body` 内 `stat()` 移出、图表渐变与 `suffix(90)` 缓存、`DateFormatter` 提 `static let`、进程榜 20 行的 `.help` 拼串降本 | `84 WS-W 性能日志评分无界化.md` |

三家共同红线（沿用 AGENTS.md §3 与无界化 spec §5.2）：
不得改 `Design/**`、`App/Theme.swift`、`Models/**`、`Package.swift`、`Services/Performance/**`（M0 后归总工）；
视图签名 `XxxView(report: ProjectReport?)` 冻结；新文件 ≤800 行；
拍图必须 `SWITCH_MODE=argv` + 各自 `CAPTURE_SANDBOX` + 带短 HEAD 的输出目录；
交回前先 `git merge main`，再 `locked_build.sh build --build-tests` + `test` 双绿 + `premerge_check.sh`；
**每组先过门再 commit**（子代理有 150 轮上限，截断时未提交的只剩磁盘）。

### M2 总工收口
逐家过门合入 → 终测（同一把尺子复测，前后逐列对齐）→ `capture_pages_isolated.sh` 九页×深浅取证 →
更新 `docs/九页实拍读数.md`、`README.md`、`docs/口径与已知限制.md`、Obsidian `90` →
确认 `ahead=0 && dirty=0` 后 `git worktree remove` + `git branch -d` 清树。

## 5.1 跨流共同禁则：采样节拍与窗口只许一个来源（15:50 实拆）

`docs/口径与已知限制.md` 记的是"三处独立字面量"，**实测是六处，而且节拍本身也有两处来源**：

| 形状 | 位置 | 风险 |
|---|---|---|
| 节拍代码来源 × **2** | `AppState` 的 `monitor.start(intervalMilliseconds: 1_500)`、`MachSystemMonitor` 内部默认路径的 `start(intervalMilliseconds: 1_500)` | 两处各写一份，改一处另一处照旧跳 1.5s |
| 显示字面量 × **4** | `DashboardView` 副标题"每 1.5 秒采样"、`PerformanceLiveCharts` 副标题"每 1.5 秒"、`PerformanceProcessGroups` 提示"约 1.5 秒后"、`PerformanceView.sampleIntervalText` | 节拍一改，界面就**说谎** |
| 节拍进算术 × **1** | `PerformanceView.windowSeconds`（`Double(chartPointLimit) * 1.5`） | 窗口秒数静默失配，而它同时是曲线轴的依据 |

**规矩（M0 由 P 落，M1 由三家消费）**：

1. `MachSystemMonitor` 暴露**唯一**节拍真值（毫秒数 + 由它派生的展示文案 + 由它派生的窗口秒数），
   `AppState` 只在启动处传一次，不许再出现第二个 `1_500`。
2. 上述 4 处显示点与 1 处算术点**一律改为读该真值**；页面里**不许再出现 `1.5` 这个字面量**
   （`ChartChrome` 的 1.5pt 线宽、`HealthComponentTable` 的 ±1.5 容差、`barRadius 1.5`、
   侧栏宽度注释里的 1.5 GB 与节拍无关，**不在禁列**，守卫的锚点必须按语义区分，不许整词 grep `1.5` 判红）。
3. 守卫：`Views/**` 里"采样节拍语义"的 `1.5` 字面量计数**只减不增**，基线 = 本表 5（4 显示 + 1 算术），
   目标 0 由 WS-O（1 处）+ WS-W（4 处）在 M1 清零。**元测试要用真形状**
   （`"每 1.5 秒"` 这种字符串），并且必须证明它不会把 `barRadius: CGFloat = 1.5` 误判成违规——
   两个方向都要测，否则这把尺子量的是个模糊集。
4. T3 交互期暂停让"上一次刷新距今"可以大于节拍值，**副标题不许继续显示"每 1.5 秒"当现状**：
   读数本身仍是真的（末值有效），但节奏文案要么随暂停态调整、要么由 P 提供"最近一次发布时间"入口，
   由 WS-W 在 M1 决定画法并交《预期视觉变化清单》。**这条不许 silently 选一个**。

## 5.2 M1 性能工单（与无界工单**同一次交付**，两家合并执行）

每条都带"改动前实测"与"交回时要拿出的数"。**没有数的报告按未完成处理。**

### WS-O 外壳与总览 —— 性能包

| 工 | 改动前实测病因 | 交回判据 |
|---|---|---|
| O-1 侧栏脱离心跳失效面 | `ProjectSidebar.sidebarFooter` 读 `monitor.latestSnapshot`，其失效域含整个 `List` 内容闭包 → **每 1.5s 重建全部项目行**（`ProjectSidebar.projectsSection`、`ProjectRow.body`） | 停在总览页跑 `perf_harness.sh idle`，`potential-hangs` 从 **13 次/25s → 0**；`ProjectRow` 路径上不再出现每秒级重建 |
| O-2 总览脱离整页重算 | `DashboardView.snapshot` + `livePerformanceCard` + `CPUHistoryChart.body`：一次 publish 让 4 枚 tile + 3 张静态卡 + 90 点×2 mark 全量重算；主线程 **64.3%** 样本在 `AG::Graph::UpdateStack::update()` | 主线程热点第一名**不再是** `_updateViewGraph`；总览页 app-update 相位 ≤ 8.33ms |
| O-3 `AnyView` 归零 | `GlassSection.trailing: AnyView?` 声明 1 处，Views 内 `AnyView` 13 处 | 全仓 `AnyView` 计数 **0**，且写进守卫（元测试自证抓得住坏样例） |
| O-4 切页首帧 | 无实测（待 `switch` 档基线） | 交 `switch` 档改前/改后同形状读数；**测不到就明写"未覆盖"** |

### WS-P 代码与 Git 五页 —— 性能包

| 工 | 改动前实测病因 | 交回判据 |
|---|---|---|
| P-1 密集矩阵降本 | `ContributorHourRow.bar(for:)`：30 行 × 24 柱 = **720 个 `RoundedRectangle` + 720 个 `.help(String(format:))`**，且 `peak` 每柱重算；`GitActivityHeatmap.body` 非懒 **168 格 + 168 tooltip**，`intensity` 内两次 `.max()` | 改 `Canvas` 或懒加载；交回给出**视图实例数改前/改后**（同一计数口径：`grep -c` 的调用点数 + 渲染期实例数算法要写清） |
| P-2 长列表懒加载 | **`LazyVStack` 实测仍为 0、`Table(` 为 0**（但 tile 网格已有 **11 处 `LazyVGrid`，那些别动**）；`DependenciesView.body` 用 `ScrollView{VStack}` 一次实例化 N 生态 × 40 行 | 名下五页**长列表**改 lazy；列头仍只能用 `Design/DataTable.swift`（红线 1，只许调用不许改） |
| P-3 body 内派生集合缓存 | `DependencySafetyVerdict` 在 body 里被构 4 次（每次 `flatMap`+`filter` 全量依赖）；`CodeRiskAnalysis.suggestions` ≈10 次 filter/map/max/reduce；`CodeDuplicationBlockRow.hint` 对**全部** occurrence 做 `pathTail`；`HealthView.historyPoints` 每 body 重排 | 命中数进 R 的 T5 棘轮基线并**只减不增**；名下页目标 0 |
| P-4 扫描离开主线程 | 实测扫描耗时 **Git 11.4s / 8.0s、代码 1830ms**；5 分析器 `async let` 并发 + 16 路 `classifyConcurrently`，扫描期 CPU 抢占为"高" | 扫描运行中点击响应 ≤ 100ms（T7），并给出 `perf_harness.sh` 扫描期读数；**扫描结果数值必须逐位不变**（不许为提速改口径） |
| P-5 稳定 identity | 实测 `id: \.self` **8 处**、`id: \.offset` **4 处**（勘查曾把两个数写反，见 §1.2；另有 `\.element` 6、`\.key` 1、`\.raw` 1 属可接受形状） | 名下页 `\.offset` 归零、`\.self` 只允许留在真正不可变且唯一的字符串键上，逐条给理由 |

### WS-W 性能·日志·评分 —— 性能包

| 工 | 改动前实测病因 | 交回判据 |
|---|---|---|
| W-1 `body` 内同步 I/O 归零 | `LogsView.attachedItems` 在**一次 body 里被求值 3 次**，每次对每个附加文件走一趟 `FileManager.attributesOfItem`（`LogsView.fileSize(of:)`） | 求值挪进 `@State` + `.task`，或把 `attachedItems` 改存储属性；R 的 T5-③ 守卫该流命中数**只减不增**（`fileExists` 在按钮动作里，不计入、不改） |
| W-2 图表降本 | `LiveSeriesChart.body` 每点 AreaMark+LineMark，**每 mark 现场构造 `LinearGradient` + 动态 `NSColor`**（C 包已把构造变成缓存，但重算面还在）；`trustedMemoryPoints` 每 tick 被跑 **4 遍 = 360 个 `SampleContext`**（`memoryAxis` 内访问 `trustedMemory` 两次 + 曲线一次 + `rejectedMemoryPoints` 为拿计数再一遍） | 停在该页跑 `idle`，app-update ≤ 8.33ms；`trustedMemoryPoints` 每 tick **≤ 1 遍**（`trustedMemory` 改存储属性或由 P 的缓存供给；计数不许靠重过滤整数组来求） |
| W-3 轴标签 formatter | **实测唯一定义点：`Views/PerfLogs/ChartChrome.swift` 的 `DateFormatter()`**（总工工单初稿误写成 `LiveSeriesChart.xLabel`，已改）；它在轴标签循环里逐次现造 | 提 `static let`；R 的 T5-① 守卫该文件命中 0 |
| W-4 进程榜 | `PerformanceProcessTable.row`：20 行 × 6 个 `LiveNumber` 格式化 + 每行 2 处 `.help` 拼串；`PerformanceView.rankedProcesses` → `MachSystemMonitor.processesByMemory` 每次访问全量 `sorted`（本机 `ps ax` = 920） | 排序消费 P 缓存的榜单（**不再自算**）；榜长与内容逐位不变 |
| W-5 消费 P 的细粒度契约 | 现状：性能页整页 body 读每秒变化的值 | 改读 P 在 M0 交付的细粒度入口 + P 的《必须迁移清单》，粗 API 棘轮该流命中数 → 0 |

**三家共同**：`AnyView` 归零（各自名下）、T5 三条守卫全绿且元测试自证、
**§5.1 的节拍唯一来源迁移**（WS-O 名下 1 处：`DashboardView` 副标题；WS-W 名下 4 处：
`PerformanceLiveCharts` 副标题、`PerformanceProcessGroups` 提示语、`PerformanceView.sampleIntervalText`
与 `windowSeconds` 的算术；WS-P 名下 0 处）、
`git merge main` 后 `build --build-tests` + `test` 双绿 + `premerge_check.sh` 回执、
**每组先过门再 commit**（子代理有 150 轮上限）、Obsidian 名下笔记贴真实输出。

## 5.3 M0 交付的细粒度契约（三家直接消费，别自己造第二套）

`MachSystemMonitor` 现在把每次 tick 的读数装进 **9 个独立观察格**
（`@Observable final class PerfCell<Value: Equatable>`，挂在 `let` 上——`let` 不进观察图，
所以**写 A 格不会唤醒只读 B 格的视图**；`apply()` 同值直接返回 `false`，不产生第二次唤醒）：

| 读法（`state.monitor.…`） | 里面是什么 | 该用它的地方 |
|---|---|---|
| `cpu.value` → `PerfCPULead` | `usage: Double?`（**无上一帧即 nil，不是 0**）、`coreCount`、`load1/5/15`、`thermal`、`uptimeSeconds` | `LiveCPUBadge`、CPU tile、侧栏底栏 |
| `memory.value` → `PerfMemoryLead` | `usedBytes`、`totalBytes`、`pressure` | 内存 tile / 内存卡 |
| `rates.value` → `PerfRateLead` | 读写盘与网络四个 `UInt64?`（**全可选**，两帧才出数） | 磁盘/网络 tile |
| `ledger.value` → `PerfProcessLedger` | `systemWideCount`、`countIsSystemWide`、`measuredCount`、`metricsTruncated` | 进程榜副标题、"被测 N / 共 M"口径 |
| `pulse.value` → `PerfPulse` | `sampleAt: Date?`、`historyCount` | 一切"最近 N 点 · 每 X 秒 · 窗口约 Y 秒"类副标题 |
| `curve.value` → `[SystemSnapshot]` | **已经切好窗口**（`curveWindowPoints`），视图里**不要再 `suffix`** | 实时曲线、总览历史曲线 |
| `cpuRanking.value` / `memoryRanking.value` | 排好序的前 N 个 `ProcessSnapshot` | 进程榜两张表——**视图内一律不再 `sorted`** |
| `groupRanking.value` | `[ProcessGroupSnapshot]` | 分组卡 |

**节拍与窗口**：`sampleIntervalMilliseconds` / `sampleIntervalText`（例「1.5 秒」）/
`windowSeconds(pointCount:)`；数值真值只有 `defaultSampleIntervalMilliseconds` 一处（§5.1）。

**交互暂停**（页面只在**切页动画**这类自己知道的时机用；滚动与拖窗已由 `AppState` 的
`NSEvent` 监视器统一接管，页面**不要**再接第二条）：
`beginInteractionPause(.pageTransition)` / `endInteractionPause(.pageTransition)`，
状态读 `isInteractionPaused`；源枚举 `LivePauseSource = .pointerStream | .windowDrag | .pageTransition`。

**旧的粗表面**（`latestSnapshot` / `history` / `topProcesses` / `allProcesses` / `trackedGroups`）
**暂时保留是为了让三家不必同批改完就能编译**，但它们仍会带动整棵 body：
`PerfInvalidationRatchetTests` 数着"还在读粗表面"的调用点，**只减不增、终点 0**。
迁完一处就少一处；**不许新增对粗表面的读**，也不许把新页面架在它上面。

## 5.4 待量化后才决定做不做的（登记，不预先动手）

| 项 | 证据 | 为什么现在不改 |
|---|---|---|
| `ProjectStore` 的主线程编码+落盘 | `@MainActor` 下 `encoder.encode(...)` 用 `.prettyPrinted + .sortedKeys`，随后 `data.write(..., .atomic)`；`save(report:)` / `persist()` / `persistHistory()` 三个口都在主线程，扫描完成回投时触发（单报告实测 29–43 KB） | ① **没有毫秒数**——它到底贡献多少主线程占用未测；② 挪到后台要引入串行队列与"退出前未 flush 就丢报告"的新风险，而 `e2e_check.sh` / `verify_pages.sh` 正是靠读回这些 JSON 判定的。持久化投机手术失败一次的成本，比它可能省下的几毫秒大得多。**等受控测量给出它的占比再决定。** |
| `ProjectStore.load()` 启动同步解码 4 份报告 | 勘查标"中" | 同上，缺绝对值；先量冷启动（T4）再判断值不值得异步化。 |

## 6. 验收判据（改完必须交这些）

1. `perf_harness.sh after` 与**§1.3 重定后的受控基线**逐列同形状对齐（**不是** run1 那张未受控的表）：
   hitch 数 → **0**、单次 app-update → **≤8.33 ms**、`potential-hangs` → **0**、
   主线程热点第一名不再是 `_updateViewGraph`。两次读数必须来自**同一测量协议**
   （`measurement-context.txt` 两栏并列贴出：前台 App、`load1`、并发编译器、实例数），
   上下文不一致的对比等于没对比。
2. T5 三条守卫 + 元测试全绿，且元测试能证明守卫抓得住坏样例。
3. `locked_build.sh test` 全绿（当前 645 例基线，只许增不许减）。
4. 九页×深浅截图 + 《预期视觉变化清单》（无界化 spec §6.3）。
5. 每家 Obsidian 笔记：真实命令输出数字、契约缺口、已知问题。
6. **未覆盖项必须明写"未覆盖"**（例如 `scroll` 档若驱动不起来），不许拿相邻档的数冒充。

## 7. 风险与备案

1. **M0 落地后、三家交回前 main 是过渡态界面**（无界化 spec 已备案），本轮叠加"心跳语义变了但页面还没改完"的窗口。
2. **既有测试会大面积变红**（它们钉的是当前值）。M0 由总工统一更新；**页面级断言归各流**，
   谁为了让它绿而删断言，视为返工。
3. **release 产物符号可读、但未优化内联更激进**：绝对值以 release 为准，火焰图归因以 debug 为准，
   两把尺子分开写，**不混**（`465f5a6` 是 release，本基线就是 release 口径）。
4. **T3 暂停实测 >500 ms 即回退**（§3）。
5. **xctrace 需要独占实例**：用户自己的实例（曾为 pid 96992）在采样期间不得同时开第二个写 `defaults` 的实例。
6. **120Hz 不是恒定出帧**：静止界面无所谓帧率。凡有人拿"我这里有 120 帧读数"当交付证据，
   先问"这段时间有没有东西在动"。
7. **两个"总工"同时在推同一棵树**（实测：本文件写作期间，并行会话连推 `5ce35ce`→`a709813` 五个提交、
   建好 `o-borderless`/`p-borderless`/`w-borderless` 三棵树待派）。`Design/**` 与 `Views/**` 的归属
   因此是**真冲突**而不是假想风险：谁在未经裁定的情况下改对方名下的文件，就是 AGENTS.md 记过的那次
   "未提交重构把 main 弄坏"的重演。§5 的 C 包与 M1 三家在裁定前一律不动。
