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
| render 相位（2340 帧） | p50 2.73 / p95 4.05 / p99 4.67 / max 25.12 ms | ≤8.33 | **健康**，超预算仅 5 帧=0.21% |
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

## 2. 能力边界（编译探针实测，`xcrun swiftc -typecheck -target arm64-apple-macos14.0`）

| 能力 | macOS 14 下限 | 结论 |
|---|---|---|
| `CVDisplayLinkCreateWithActiveCGDisplays` | 可用 | 帧节拍内建探针用它 |
| `CGDisplayCopyDisplayMode(...).refreshRate`、`CGDisplayCopyAllDisplayModes` | 可用 | 运行时取真实 Hz，**不硬编码 120** |
| `os_signpost`（`OSSignpostID` 老式 API） | 可用 | 打点；`OSSignposter` 新式 API 的 `emit`/`signpost` 成员在本 SDK **签名不同，用前先探针** |
| `TimelineView(.animation(minimumInterval:paused:))`、`Canvas` | 可用 | 重画曲线/矩阵的原语 |
| `EquatableView(content:)`、`View.drawingGroup(opaque:colorMode:)` | 可用 | 手工短路重算 |
| `CADisplayLink` | **不可用**（"unavailable in macOS"） | 照抄 iOS 帧率方案这条路是死的 |
| `MetricKit` 的 `MXAnimationDiagnostic` / `MXMemoryDiagnostic` / `MXCPUDiagnostic` | **macOS 上不存在**（只有 `MXMetricManager`、`MXAppLaunchMetric`） | 线上帧率回传方案不成立 |
| `GlassEffectContainer` / `.glassEffect` | 仅 macOS 26 | 闸门仍只准集中在 `Design/Glass.swift` |
| `.containerBackground(_, for: .window)` | 仅 macOS 15+ | 需 `#available` 兜底，同样只准集中在 Design 层 |
| 本机运行系统 | **macOS 26.5.2** | 真玻璃路径在本机生效，测出来的数就是 26 路径的数 |

## 3. 目标（T1~T9，全部可机器断言）

- **T1 交互期不掉帧**：切页 / 滚动 / 悬停 / 拖窗 / resize 期间 p95 帧间隔 ≤ **8.4 ms**、p99 ≤ 16.7 ms；
  **hitch 帧 = 0**；硬上限 <1/s 且 hitch ratio <0.1%。
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

## 6. 验收判据（改完必须交这些）

1. `perf_harness.sh after` 与 §1 表格**逐列对齐**的同形状结果：hitch 数 **7→0**、
   单次 app-update **24.8→≤8.33 ms**、`potential-hangs` **13→0**、主线程热点第一不再是 `_updateViewGraph`。
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
