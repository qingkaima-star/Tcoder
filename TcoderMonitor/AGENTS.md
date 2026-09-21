# Tcoder 项目监控 — 并行开发规约（所有会话与子代理必读）

## -1. 命名与禁区（最高优先级，违反即返工）

本项目叫 **Tcoder**，与任何其他项目无关。

1. 代码、UI 文案、示例与测试数据、注释、标识符、笔记里**一律不得出现** "Mona" / "MONA" / "mona"。
   品牌词只用 `Tcoder`。
2. **禁止读取、扫描、分析、写入任何不属于 `/Users/one/Documents/Tcoder` 的他人项目资产**，
   尤其是本机其他项目的仓库、`.env`、密钥目录、证书目录、数据库、Redis、生产机。
   需要真实数据做验证时，只用：本仓库自己的目录树、`/tmp` 下你自己创建并事后删除的临时夹具、
   `/opt/homebrew` 下的公共开源源码、`~/Library/Logs` 里属于本 App 的日志。
3. 进程监控**只读展示**：不得向任何进程发送信号、kill、重启、附加调试器。
4. 不得修改本机系统配置、防火墙、代理、启动项、其他服务的任何文件。

本仓库由 1 位总工程师 + 3 个并行对话窗口（WS-A / WS-B / WS-C）共同开发，
每个窗口内再并发多个子代理。**违反本文件的写入会造成互相覆盖，务必遵守。**

## 0. 你的目标（每次动手前先复述一遍）

交付一款 Apple Silicon 原生 macOS App：对项目做工程指标监控
（代码规模、Git 贡献、复杂度/重复风险、CPU/内存/磁盘/网络、错误日志、依赖与 CVE、健康评分）。
你只负责自己被指派的那一片，做完要能编译、能有真实数据、UI 用中文。

## 1. 环境事实

- **git 仓库根是 `/Users/one/Documents/Tcoder`**（不是子目录）。App 源码在 `TcoderMonitor/` 下，
  所以从任何子目录跑 `git` 都可用，但 `git status` 的路径会带 `TcoderMonitor/` 前缀。
- 仓库根：`/Users/one/Documents/Tcoder/TcoderMonitor`
- Swift 6.3.3 / Xcode 26.6 / macOS SDK 26.5 / 仅 arm64。目标系统 macOS 14+。
- SwiftPM 可执行 target + `@main`（没有 main.swift）。语言模式被显式降到 **Swift 5**
  （`Package.swift` 里 `.swiftLanguageMode(.v5)`），所以 Sendable 只会警告，不会报错。
  **不要改 `Package.swift`，不要把语言模式调回 6。**

## 1.5 停笔纪律（并行开发最容易出事的地方）

**不允许把半成品留在工作区。** 停笔前必须自己跑到双绿：

```bash
cd /Users/one/Documents/Tcoder/TcoderMonitor
./scripts/locked_build.sh build && ./scripts/locked_build.sh test
```

改完就 `git add <你的文件> && git commit`，不要留未提交的编译错——别人会以为仓库是坏的。
若要暂存未完成工作，用带说明的 `git stash push -m "..."` 并**同时**存一份
`git diff > .inflight/<名字>.patch`，别只靠队列里的消息通知总工。

**禁止用 `git reset --hard` / `git checkout -- <文件>` 清理在途改动（2026-09-20 实测丢过一整份工）。**
WS-C 的 #26（`ScannedLogFile` 读取失败原因字段）两个在途文件就是这么没的：
`reflog` 里留着 `reset: moving to HEAD`，而字段在 `Models/LogInsights.swift` 里已不存在，
既没提交也没留档，等于白做一轮。
要把工作树恢复干净，**只有两条合法路**：

```bash
git stash push -u -m "<流名>-<时间>-<内容>"      # 可取回
git diff > .inflight/<流名>.patch                # 同时留一份可读档
```

**每做完一小步就 commit**——攒着的在途改动就是最容易整份丢掉的东西。

**补充（20:34 实测教训）：`Tests/TcoderMonitorTests/**` 是同一个编译单元。**
你写的测试文件哪怕生产代码全对，只要它编译不过，
**全仓所有工作流就都跑不了 `test`**——别人会以为是自己的代码坏了。
所以提交前额外跑一次这条（它比整轮 test 快得多，专门用来验证测试模块可编译）：

```bash
./scripts/locked_build.sh build --build-tests   # 必须零 error 才算可以停笔
```

新开的取证/集成测试文件记得带 `@testable import TcoderMonitor`（缺了会报
"cannot find 'XxxAnalyzer' in scope"，看着像别人的代码坏了，其实是你自己的文件）。

**总工的合并门禁（2026-09-19 21:25 起强制执行）**
我曾犯过一次具体错误：看到某分支"领先 main 1 个提交"就直接 merge，
结果那是一个没写完的重构（164 个编译错），把 main 弄坏，只能 `revert` 补救。
**"分支有提交"不等于"分支能编译"。** 现在任何分支合入前，总工必须先跑：

```bash
./scripts/premerge_check.sh ws/<工作流名>     # 独立工作树里 build --build-tests + test
```

任一失败即拒绝合入。**负责人不要等总工拦你**——提交前自己先把这两条跑过。
重构类工作建议拆成两步提交：①"新增文件且仍编译" ②"删旧文件且仍编译"。
把"能编译的修复"和"没写完的重构"混进同一个提交，会连坐被整体撤销。

## 2. 构建纪律（最重要）

`swift build` 的 `.build` 目录**不支持并发**。多个会话同时编译会互相打坏。

- 禁止直接执行 `swift build` / `swift test` / `xcodebuild`。
- 一律走串行锁：
  ```bash
  cd /Users/one/Documents/Tcoder/TcoderMonitor
  ./scripts/locked_build.sh build
  ./scripts/locked_build.sh test
  ```
  锁会排队（最多 20 分钟，超时自动接管并回收死锁）。
- **不要**为了"快点"绕过锁。排队时先去写代码或记笔记。

## 3. 文件所有权（只能改自己名下的路径）

### 冻结区（任何工作流都不得修改）
```
Package.swift
Sources/TcoderMonitor/Models/**            # 数据契约
Sources/TcoderMonitor/App/AppState.swift   # 编排器
Sources/TcoderMonitor/App/TcoderMonitorApp.swift
Sources/TcoderMonitor/App/Theme.swift      # 设计系统 + 共享组件
Sources/TcoderMonitor/Services/ProjectStore.swift
Sources/TcoderMonitor/Services/ServiceContracts.swift
Sources/TcoderMonitor/Services/Demo/DemoData.swift
Sources/TcoderMonitor/Utilities/SharedUtilities.swift
Sources/TcoderMonitor/Views/RootView.swift
Sources/TcoderMonitor/Views/ProjectDetailView.swift
Sources/TcoderMonitor/Views/DashboardView.swift
```
契约不够用时：**不要改它**，在你自己的文件里加扩展（`extension CodeMetrics { ... }`）
或用派生类型；把缺口写进你的 Obsidian 笔记 + 在最终汇报里列为「契约缺口」，由总工处理。

### WS-A 静态代码分析
```
Sources/TcoderMonitor/Services/Code/**
Sources/TcoderMonitor/Views/Code/**
Tests/TcoderMonitorTests/Code*Tests.swift
```
入口类型：`FileSystemCodeAnalyzer`（已存在，改写它）。

### WS-B Git 与依赖
```
Sources/TcoderMonitor/Services/Git/**
Sources/TcoderMonitor/Services/Dependencies/**
Sources/TcoderMonitor/Views/Git/**
Sources/TcoderMonitor/Views/Dependencies/**
Tests/TcoderMonitorTests/Git*Tests.swift
Tests/TcoderMonitorTests/Dependency*Tests.swift
```
入口类型：`ShellGitAnalyzer`、`ManifestDependencyAnalyzer`、
视图：`GitInsightsView`、`ContributorsView`、`DependenciesView`。

### WS-C 运行时 / 日志 / 评分
```
Sources/TcoderMonitor/Services/Performance/**
Sources/TcoderMonitor/Services/Logs/**
Sources/TcoderMonitor/Services/Health/**
Sources/TcoderMonitor/Views/Performance/**
Sources/TcoderMonitor/Views/Logs/**
Sources/TcoderMonitor/Views/Health/**
Tests/TcoderMonitorTests/Performance*Tests.swift
Tests/TcoderMonitorTests/Log*Tests.swift
Tests/TcoderMonitorTests/Health*Tests.swift
```
入口类型：`MachSystemMonitor`、`FileLogAnalyzer`、`WeightedHealthScorer`、
视图：`PerformanceView`、`LogsView`、`HealthView`。

**18:33 所有权变更**：`Services/Health/WeightedHealthScorer.swift` 由总工交还给 WS-C
（要接 `ScoreCurves.swift`）。前提：`HealthScoreTests` 36 例保持全绿，尤其两条硬契约
① 分量 `weight` 自身归一化到 1.0；② `overall == sum(score*weight)`（±1）。
接不进去就删掉 `ScoreCurves.swift`，**不许留无调用方的实现文件**。

同一工作流内的子代理之间也必须**按文件名切分**，任何人不得改别人的文件。

### 20:38 工作树制扩充流（见 §7）

| 流 | 负责域 | 可写路径 |
|---|---|---|
| WS-D 诚实性审计 | 只读找虚报/假数据/暗示调用 AI | **仅** Obsidian `20 WS-D 诚实性审计.md`；不得改任何代码 |
| WS-E 发布工程 | 打包、二进制==HEAD 证明、九页取证 | `scripts/build_app.sh`、`scripts/verify_pages.sh`、Obsidian `30`；**不得改 `Sources/**`** |
| WS-F 夹具实验室 | 多清单/多格式覆盖率真值验证 | 新建 `Tests/TcoderMonitorTests/ManifestLabFixtureTests.swift`；**不得改 `Sources/**`** |
| **WS-G 设计系统基座** | 令牌、玻璃组件库、排版与语义色 | **`App/Theme.swift`（原总工冻结区，现移交 WS-G）**、新建 `Design/**`、`Tests/.../DesignTokenTests.swift`；**不得改 `Views/**` 页面、`Services/**`、`Models/**`、`Package.swift`** |
| WS-H 设计规范 | 栅格/字号/色板/SF Symbols/中文文案规范 | **仅** Obsidian `40 WS-H 设计语言规范.md`；不写码 |
| WS-I 设计债审计 | 硬编码值/魔法数/不统一写法清单 | **仅** Obsidian `45 WS-I 设计债清单.md`；不写码、**不启动 App** |
| WS-J 自食其果 | 用 Tcoder 扫 Tcoder，按自报结论修真问题 | 报告点名的 `Services/**`；**碰别人目录先停下报总工**；不得改 `Models/**`、`Package.swift`、阈值定义 |


### 第三轮（2026-09-20 07:08）：全站 UI「简约无界」重构

设计规格 `docs/superpowers/specs/2026-09-20-borderless-minimal-ui-redesign-design.md`，
实施计划 `docs/superpowers/plans/2026-09-20-borderless-minimal-ui-redesign.md`。
基座（M0）已由总工落在 `04453f6` 并打 tag **`m0-borderless-base`**，三家从该 tag 切树。

| 流 | 负责 | 可写路径 | Obsidian |
|---|---|---|---|
| WS-O 外壳与总览 | 侧栏 source list / 删 chip 条 / 总览重排 | `Views/RootView.swift`、`Views/ProjectDetailView.swift`、`Views/DashboardView.swift`、`Views/Shell/**`、新建 `Tests/TcoderMonitorTests/ShellBorderlessTests.swift` | 新建 `80 WS-O 外壳与总览无界化.md` |
| WS-P 代码与 Git 五页 | 代码规模/复杂度/Git/贡献者/依赖 | `Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**`、`Views/CodeGit/**`、新建 `Tests/TcoderMonitorTests/CodeGitBorderlessTests.swift` | 新建 `82 WS-P 代码与Git五页无界化.md` |
| WS-W 性能·日志·评分 | 杀手功能三页 | `Views/Performance/**`、`Views/Logs/**`、`Views/Health/**`、`Views/PerfLogs/**`、新建 `Tests/TcoderMonitorTests/PerfLogsBorderlessTests.swift` | 新建 `84 WS-W 性能日志评分无界化.md` |

**M0 之后新增的红线（覆盖 §3 旧表的相关条目）**：

1. **`Design/DataTable.swift` 由总工拥有**（自 `Views/CodeGit/CodeGitTable.swift` 上提，
   它被 6 个目录 10 个文件共用）。三家只许**调用**，不得改；要加列能力报契约缺口。
2. **`Design/**` 与 `App/Theme.swift` 仍归总工**（M0 起）。三家不得改。
3. **`View.typed(_:)` 是排版令牌唯一消费入口**（`Design/SharedComponents.swift`）。
   `Font` 没有任何字距 API，所以 `.font(Theme.Typo.groupLabel.font)` 会**静默丢掉字距**，
   `BorderlessSurfaceGuardTests` 钉着这条。分区标题一律写 `.typed(Theme.Typo.groupLabel)`。
4. **`GlassSection` 不再画面板**（`.content` 层现在返回 `self`），`padding` 默认值已是 **0**。
   页面要"嵌进去"的观感只能靠 `.contentInset`（实心井，限表格/日志/代码块）。
5. **主读数一律 `Theme.Palette.Surface.ink`**，`.primary` 不够黑（`labelColor` 只有 85% 黑）。
   数据色禁止用 `info`/`accent`；颜色只承载语义（健康分档/风险/日志等级/增删）。
6. **投影不得新增**。全仓 `.shadow(` 只允许 1 处且在 `.floating` 分支内，
   `BorderlessSurfaceGuardTests.test_shadowIsExactlyOneOccurrenceAndSitsInFloating` 会拦。
7. **页面不得散写 `#available` / `glassEffect`**（沿用 §3 横切约束 1）。
8. `BorderlessSurfaceGuardTests` 里 `m2WiringComplete = false` 是**总工的闸门**，
   三家不得自行翻成 true；M2 由总工在接线完成后撤除。
9. **并行拍图必须 `SWITCH_MODE=argv` + 各自 `CAPTURE_SANDBOX` + 各自输出目录**。
   `single` 模式会 `defaults write com.tcoder.monitor`，那是全机共享域，三家会互相改页。

### 第四轮（2026-09-20 15:40）：性能轮 120Hz —— 本包归属与新增红线

性能规格 `docs/superpowers/specs/2026-09-20-performance-120hz-design.md`（含**改动前实测基线**）。

**裁定沿革**：用户 15:2x 曾把三棵页面树判给本会话派发，**该条已被下方「双总工协作裁定
（16:57）」作废**——`ws/o-borderless` / `ws/p-borderless` / `ws/w-borderless` 归 **UI 总工**派发与收回。
本轮仍与无界化**合并成同一次交付**（不分两轮付两遍钱），但性能工单是**追加到该流已交回的产物上**，
性能轮不另起会话写同一批文件。性能轮的实际持有区见下一节。

**M0 剩余三包归属（全在 `ws/perf-base` 一棵树，总工串行 merge）**：

| 包 | 路径 | 内容 |
|---|---|---|
| R 尺子 | `scripts/perf_harness.sh`、`scripts/trace_report.py` + `scripts/perf_trace_xml.py` + `scripts/perf_trace_metrics.py` + `scripts/perf_framepulse.py`、`Sources/TcoderMonitor/Services/Performance/FramePulse.swift`、`scripts/perf_selfcheck.sh`、`scripts/perf_trace_summary.py`、`scripts/perf_trace_threads.py`、`Tests/TcoderMonitorTests/Perf*Tests.swift` | xctrace 封装（六档：`idle`/`interact`/`switch`/`report`/`probe`/`selfcheck`）+ App 内帧探针 + T5 主线程禁则守卫（每条配元测试）。尺子自己也被 `selfcheck` 十四项反例守着（含 `migration` 收益分级三项：正例算得对、缺料要喊、两侧分叉要报 ⚠）|
| P 心跳链路 | `Services/Performance/**`（除 `FramePulse.swift`）、`App/AppState.swift`（**本轮解冻，仅限这两处**；`SystemSnapshot` 契约不动） | 一次 publish 的失效面收窄、派生榜单缓存、`sampleNow` 离开主线程、T3 交互期暂停 |
| C 令牌缓存 | `Design/**`（`ColorToken`/`ThemeTokens`/`ChartTokens`） | 把"每次访问现造 `NSColor`/`Font`/`LinearGradient`"改成缓存，**公开 API 名字与调用形状一字不动** |

**本轮新增红线（覆盖第三轮相关条目）**：

1. **帧率结论只认 `perf_harness.sh` 的读数**。报告里没有与基线**逐列同形状**的数字，按未完成处理。
2. **口径必须标出来**：`release` 还是 `debug`（绝对值不可混比，火焰图归因用 debug、交付数用 release）、
   `idle` / `switch` / `scroll` 哪一档。**测不到就明写"未覆盖"**，不许拿相邻档冒充。
3. **`render` 相位实测健康（p95 4.05ms）**，所以"去材质/去投影"**不得再被当作性能主因**申报；
   它的收益记在观感账上。头号靶子是 `AG::Graph::UpdateStack::update()`（主线程 64.3% 样本）。
4. **交互期暂停只在 `AppState` 实现**（`NSEvent` 本地监视器，macOS 14 可用）。
   页面**零改动**、`Design/**` **零新增 `#available`**——`onScrollPhaseChange` 是 macOS 15+，禁止使用。
   暂停期跳过的帧仍要进环形缓冲，**严禁把暂停期画成 0 或空白**。
5. **诚实性语义与阈值一律不许为了帧率改**：两帧才出速率、缺数据 `--`、轴台阶 ∈{1,2,2.5,5}×10ⁿ
   且只抬不降 ≤2 倍、不可信点剔除并计数、`historyCapacity`、pressure 70/85、`.unknown` 只能由
   `available:false` 产出。**谁为了让守卫绿而放宽阈值，等于把工具废掉。**
6. **T5 三条主线程禁则的守卫一律写成"只减不增棘轮 + 元测试 + 分母 > 0"**。
   特别是渲染路径 I/O 那条：正则必须覆盖 `fileExists`/`attributesOfItem`/`contentsOfDirectory`/
   `Data(contentsOf:`/`String(contentsOf:`/`stat(`/`lstat(`/`FileManager`，
   元测试要用 **`attributesOfItem`** 这种仓库里真实存在的形状造坏样例——只匹配 `stat(` 会得到永真绿守卫。
7. **`SourceFileReachabilityTests.censusBaseline`（现 110）与本文件的新章节，只由总工改**；
   每加一个 `Sources/**` 文件必须在该常量注释里写清"谁加的、凭什么被引用"。
   注意该守卫**剥注释与字符串**、且**只认 `Sources/**` 里的调用点**——单测引用不算证据。
8. `FramePulse` 必须接线进产品代码后才允许合入（零调用的实现文件会被第 7 条拦下），
   且**默认关闭**：只有 `TCODER_PERF_PROBE=1` 时才允许创建 `displayLink`，关闭时开销必须为零。
### 双总工协作裁定（2026-09-20 16:57，由用户裁定）

本仓库此刻有**两位总工在飞**：第三轮「简约无界」UI 重构（设计总监口径）与
第四轮「120Hz 性能」（性能口径）。两者在 `Design/**` 上重叠，故按**关注点**切分，
不按文件树切分：

| 关注点 | 归属 | 范围 |
|---|---|---|
| **观感与 UI 语义** | 第三轮（UI 总工） | `Views/**` 全部；`Design/**` 的**取值与画法**（字号链、地面色、纯墨、投影规则、组件渲染） |
| **性能** | 第四轮（性能总工） | `Services/**`、`App/AppState.swift`、`scripts/perf_*`；`Design/**` 的**内部缓存化**——不得改任何数值、语义或公开 API 形状 |

**三棵页面树 `ws/o-borderless` / `ws/p-borderless` / `ws/w-borderless` 由 UI 总工派发与收回。**
性能轮若要给页面下工单（`LazyVStack`、`AnyView` 收敛、节拍字面量等），**等该流无界化交回后
追加到同一条流**，不要另起会话写同一批文件——一次交付，不分两轮付两遍钱。

**`AGENTS.md` 的合并规则**：每个工作流在**自己那一轮的小节**里追加，**两份小节合并保留，
不得互相覆盖**。第四轮「120Hz」那一节（含其 M0 三包归属与新增红线）在合入 main 时
必须原样保留，本裁定不取消它的任何一条。

**两条已被双方共同确认的事实**（写下来免得再争）：
1. 「去材质 / 去投影」**不是**本轮的性能收益来源。`render` 相位实测健康，收益只记在观感账上。
2. 诚实性语义与阈值不得为了任何指标（帧率或守卫绿）放宽——两帧才出速率、缺数据 `--`、
   轴台阶 ∈{1,2,2.5,5}×10ⁿ 且只抬不降 ≤2 倍、零证据不给满分。谁放宽谁把工具废掉。
### 22:40 单人接管：性能轮并入 UI 轮（用户裁定）

用户 2026-09-20 夜告知 **workbuddy（性能总工）停止作业**，其关注点转由 UI 总工一人持有。
上面「双总工协作裁定」的**两格归属表照旧读**，只是执行者合成一个人。三条后果写在这里：

1. **第四轮「120Hz」那一节的全部红线一条不撤**。它们约束的是做法不是人——尤其
   「帧率结论只认 `perf_harness.sh` 读数」「T5 守卫只减不增 + 元测试 + 分母 > 0」
   「诚实性语义与阈值不得为任何指标放宽」。
2. **一个人不能给自己的两套口径同时放行**。性能工单合入前照旧走
   `premerge_check.sh` 的机器断言，不因为"UI 和性能都是我写的"而免检。
   观感改动（`Design/**` 取值）与性能改动（`Services/**`）**分提交、分门禁**，
   否则一次回归无法归因。
3. **在途产物的处置**：`ws/perf-base` 上 `PerfMainThreadBudgetTests`（160 行，
   只出读数、**不设阈值**）+ 规范 §5.4 两笔量化结案，已于 22:21 由该分支自己合入 main，
   UI 总工独立复跑核过读数（`upsert 中位 0.58 ms / 启动 4 份 中位 1.25 ms`，
   与报的 0.5 / 1.3 同档）。该分支尾部还剩一个纯文档提交未合。

`/Users/one/WorkBuddy/Worktrees/Tcoder/main-3128694f` 那棵树**不在本仓库目录内**，
按禁区规则不去动它（它已全合并进 main，留着无害）。要清它由用户处置。

### 23:05 第二轮观感返工：灰底与强调色（用户判词驱动）

用户对着 22:31 的实拍提了两条：**「不要用灰色底，显脏」**、**「跟参考图有差距，
按钮这些都不一样，强调色我看参考是亮绿色，你认真分析颜色」**。

本轮归属仍在 UI 总工（`Views/**` + `Design/**` 取值与画法），但**加两条约束**：

1. **改取值必须先有参考图与实拍的同尺子读数**，不许凭印象调色。工具是
   `scripts/pixel_audit.swift`（报告器，不是闸门）与临时取样器；
   参考图与实拍必须走同一个量化分档，否则"灰底"这种判断无法证伪。
2. **`Design/**` 的对比度断言与地面取值必须同源于同一个白/黑底**。
   `DesignAppearance.referenceSurface` 一直是 `#FFFFFF / #1E1E1E`，
   而地面上一版定成 `#F1F1F3` —— 这等于**所有 3:1 图形色断言在替一个不存在的底背书**。
   新增的 `testAccentGraphicClearsBothGraphicAndOnFillLines` 是这类"一个值要同时撑住
   画出来和被压在其上的字"双向线的样板。

### 三条横切约束（设计与 dogfooding 流尤其注意）

1. **部署下限 macOS 14 不变**。Liquid Glass API 是 macOS 26 才有的，
   一律集中在设计系统里走 `if #available(macOS 26.0, *)` + 材质兜底，
   **页面里禁止散写可用性判断**，也禁止为此把 `Package.swift` 抬到 26。
   实测哪些 API 可用见 Obsidian `35 已验证设计能力基线.md`（用编译探针验的，
   静态 grep SDK 桩文件会得出错误结论）。
2. **同一时刻只允许一个人启动 App**。`Application Support` 与 `defaults` 域全机唯一，
   不随工作树隔离。跑 UI 取证前先 `pgrep -x TcoderMonitor` 确认为 0。
   所以 WS-H/WS-I/WS-J 一律**不启动 App**，用测试驱动分析器取数。
3. **阈值不许为了刷分而动**。巨大文件行数、复杂度榜长度这类定义属冻结区；
   把阈值放宽让自己变好看，等于把工具废掉。
4. **实现文件越过 400 行会让全仓测试变红**（`SourcesSizeAuditTests`，2026-09-21 补）。
   这条口径（`FileSystemCodeAnalyzer.mediumFileLines`）本来只出现在自扫报告里、没有断言守着，
   于是收官轮打到 0 之后又悄悄长回 4 个超限文件。红了的正确反应是**按类型整块搬去新文件**
   （逐字节搬动、多重集对冲自证），不是往 `hugeFileWorkList` 里塞条目；
   确实要挂账（例如归别的流的尺子），必须在清单里写清归属与拆法并向总工说明。
   同一条 400 行在 `Tests/**` 侧由 `X3TestSizeAuditTests` 守，两侧口径同源。

### 21:05 第二轮：页面重样流（承接 WS-G 基座）

WS-G 的 `Design/**` 已合入 main，九页重样解锁。三条流按**页面目录**切分，互不重叠：

| 流 | 负责页面 | 可写路径 |
|---|---|---|
| WS-K 外壳与导航 | 侧栏 / 页面切换 / 顶栏 / 总览 | `Views/RootView.swift`、`Views/ProjectDetailView.swift`、`Views/DashboardView.swift`（自总工冻结区**移交**）、新建 `Views/Shell/**` |
| WS-L 代码与 Git 类 | 代码规模 / 复杂度风险 / Git 洞察 / 贡献者 / 依赖 | `Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**`、新建 `Views/CodeGit/**` |
| WS-M 性能与评分 | **杀手功能**性能监控 / 错误日志 / 健康评分 | `Views/Performance/**`、`Views/Logs/**`、`Views/Health/**`、新建 `Views/PerfLogs/**` |

三家共同的红线：
- **不得改 `Design/**` 与 `App/Theme.swift`**（那是 WS-G 的），不得改 `Services/**`、`Models/**`；
- 视图签名 `XxxView(report: ProjectReport?)` 冻结；
- **不得新增超 800 行文件**（`SelfScanDogfoodTests.swift:154` 全仓棘轮，`ceiling = 9` 不许放宽，
  当前实测 8 个，**只剩 1 个余量**）；
- **不得启动 App**（UI 取证格同一时刻只有一人，由总工排期），改为交《预期视觉变化清单》供最终目视核对。

WS-L 另背一条**功能性诚实修正**（不是美化）：界面显示"提交总数 62"而作者表求和 48，
差值恰为 14 个 merge 提交，分析器一贯用 `--no-merges` 统计作者——用户自己会发现对不上而我们从不解释。
须在 Git 页写明"共 62 次提交（含 14 次合并）· 作者与代码行统计基于 48 次非合并提交"，
并在 `historyTruncated` 时标出"近 N 次提交窗口内"。

## 4. 视图约定

- 视图 struct 名与初始化签名已冻结：`XxxView(report: ProjectReport?)`。内部自己取子字段。
- 读实时性能：`@Environment(AppState.self) private var state` → `state.monitor.history` /
  `state.monitor.latestSnapshot` / `state.monitor.topProcesses`。
- `SystemSnapshot` 已是 `Identifiable`（`id = timestamp` 的 TimeInterval），可直接喂 Swift Charts。
- 统一用设计系统组件：`GlassSection`（分区卡的事实标准：46 处调用 / 22 个文件）、`MetricTile`、`RiskBadge`、
  `SeverityBadge`、`MiniBarGauge`、`EmptyStateView`、`BannerRow`/`BannerStyle`、`StatLine`、`Theme.*`。
  `SectionCard` 与 `Design/TableKit.swift` 整文件已因零引用删除（2026-09-20，WS-G #28），**别再往回加**；
  表格列头自 `d6345e5`（WS-Q #34）起**只剩 WS-L 那套 `DataTableHeader` + 列数组**（`Views/CodeGit/CodeGitTable.swift`），
  `TableHeaderCell` 与 `Grid`/`GridRow` 排布已删除，`TableHeaderConvergenceTests` 钉住不许回来；
  列系统仍住在 WS-L 目录下（归属错位，上提进 `Design/` 需总工拍板）。
  需要新组件写在你自己的目录里，不要往 `Theme.swift` 里加。
- 文案一律简体中文；数字用 `NumberFormat.grouped/compact/percent`、`ByteFormat.string/rate/bitRate`、
  `DateFormat.sinceDescription`。
- 数据缺失时显示 `EmptyStateView`，**不要**显示为 0 假装是真实结果。

## 4.5 已踩到的致命坑（总工实测）

`.commands { }` / `WindowGroup` 之外的 Scene 内容**不继承** `.environment(state)`。
在 commands 里放一个用 `@Environment(AppState.self)` 的子视图会在启动时直接 trap：
`Fatal error: No Observable object of type AppState found`。
→ 任何菜单/命令内容都要直接捕获总工传下来的 `state`，不要在子视图里读 environment。

同理：`AppState`、`ProjectStore`、`MachSystemMonitor` 都是 `@MainActor @Observable`，
`FileSystemCodeAnalyzer` 等分析器在 `Task.detached` 里跑，**不要**在分析器内部触碰
`ProjectStore` 或任何 `@MainActor` 对象——把结果返回给 AppState 由它落盘。



## 4.6 文档里的代码引用怎么写（2026-09-20 由 #29 定，机器校验）

**只写符号，不写行号。** `README.md` 与 `docs/使用说明.md` 里指向代码的锚点，允许两种形状：

- `类型.成员` —— 例 `HealthRing.readout`
- `文件名.类型.成员` —— 首段是 `Sources/**` 里的**文件名去后缀**，用来消歧同名类型，
  例 `ContributorRows.ContributorRow.body`（Views 层 `body` 遍地都是，光写 `ContributorRow.body` 不够定位）

`Foo.swift:123` 这种**行号引用一律不要新增**：Views 层一天改三轮，行号必腐烂，
而且腐烂是静默的（读到的人照着错行去找，找不到也不报错）。
确需指到某一行的约束（例如冻结区的阈值定义），写成
`` `File.swift` 的 `SomeType.someMember` ``（符号在反引号里，行号不要出现）。

两种形状都由 `Tests/TcoderMonitorTests/DocReferenceRatchetTests.swift` 机器校验，它会：
断言两份文档都真被读到、符号与行号两类分母各自 > 0、并按恒等式
`符号锚点数 == 文件作用域活 + 普通活 + 死` 要求**每一条引用都有归属**（不许"没分类"）。

**省略写法 `:NNN` 的规矩（#41，由 `DocBareLineReferenceTests` 校验）**：
裸行号**必须能回指**——在**同一段落内**（向上直到空行或 `#` 标题为止）
最近的那个 `.swift` 文件名，且行号不超过该文件实际行数。回指不到或越界一律判失效。
所以：省可以，但只能在同一小节里省；隔了一个空行或换了标题，就必须把文件名重新写出来。

**基线 `knownDeadAnchors` 当前被断言必须为空**——也就是说现在没有豁免额度。
新增死锚点会让测试直接变红，唯一正确的反应是**改文档或改代码**，不是往基线里塞。
（它是 `[锚点: 为什么死]` 的形状，是为了万一真要留豁免时，原因必须和条目一起写下来；
`#29` 第一次交回时曾把 33 条**活锚点**当"已知失效"塞进基线，于是校验器对它们永远不红——
这段历史就是"不许拿基线当遮羞布"的理由。）


## 5. 工作日志（Obsidian，边做边写）

库：`/Users/one/Documents/Obsidian Vault/Tcoder 项目监控/`
只写你自己的那一份，禁止改别人的或 `00 总览` / `90 集成与交付日志`：

- WS-A → `10 WS-A 静态代码分析.md`
- WS-B → `11 WS-B Git与依赖.md`
- WS-C → `12 WS-C 运行时与日志.md`

格式：追加二级小节 `## HH:MM <子代理名/职责>`，写清：做了什么、验证到哪一步
（贴真实命令输出数字）、契约缺口、下一步。**空话不写。**

## 7. 工作树规约（20:38 由用户定调，最高优先级，覆盖本文件其他并行约定）

**每人一棵工作树，改完各自合入主线，然后清掉自己的工作树。**
主工作树 `/Users/one/Documents/Tcoder` 从此**只作集成用**，任何负责人不得直接在主树里编辑。

### 为什么必须这样

1. **构建锁自然解除**。`swift build` 的 `.build` 不支持并发，此前所有人抢一把串行锁排队。
   每个 worktree 有独立 `.build`，锁文件路径也独立
   （`locked_build.sh` 用 `$PWD/.build/agents.lock`），于是**真并行编译**成为可能。
2. **不再互相覆盖**。历史上发生过：旧 WS-A 会话未真正停止，与新会话抢写
   `Services/Code/**`，导致总行数不升反降、`DuplicationEngine` 回到半成品状态。
3. **取证才可信**。在主树里构建，拿到的二进制混着别人未提交的在途改动，
   "交付二进制与 HEAD 一致"这句话就是假的。

### 目录与命名

```
/Users/one/Documents/Tcoder/.worktrees/<工作流名>     # 已 gitignore
分支 ws/<工作流名>，一律从 main 的某个明确 hash 切出
```

现有工作流：`a-code`、`b-git-deps`、`c-runtime`、`d-audit`、`e-release`、`f-manifest`。

### 每人必须做的

1. 进自己的 worktree 干活，**路径以外的一律不碰**（尤其不要 cd 回主树构建）。
2. 在自己的分支上小步提交，commit message 前缀写自己的工作流名。
3. 合入前自检：`./scripts/locked_build.sh build && ./scripts/locked_build.sh test` 双绿。
4. **合入主线由总工执行**（别人不要自己 merge/push main），完成后
   `git worktree remove` 清掉自己的工作树与分支。

### 署名口径（2026-09-21 由用户裁定「按流署名」）

每棵工作树用**自己这条流**的身份提交，只写 worktree 级配置——
不改仓库级 `user.name`（那是共享的，主树要留 `Tcoder Team` 给集成用），**也不重写历史**：

```bash
git config --worktree user.name  "WS-X1 CodeServices"
git config --worktree user.email "x1.codesvc@tcoder.local"
```

Why：健康评分的「协作分布」读的就是 git 作者分布。收官前全仓 273/334 笔非合并提交都署在
`Tcoder Team <dev@tcoder.local>` 一个身份下，那一维算出 83% 单人占比、6 分。
这个数**混了两件事**：真实存在的单点风险，以及"多条并行流共用同一个身份"造成的记录假象。
按流署名把后者摘出去，顺便让"这块代码归哪条流"能从 `git log` 直接读出来。

⚠️ **诚实边界**（写进 `docs/口径与已知限制.md` §4.4.2，读分的人必须看到）：
署名改的是**归因口径**，不是团队规模。8 个署名背后是 8 条工作流加一位总工，
不是 8 个人；历史里那 273 笔仍挂在共用身份下，没有回头改写。
所以「协作分布」这一维今后读的是"哪条流握着这块代码"，
**不许被说成"多人协作已经很分散"**。

### 并行度上限（2026-09-19 23:50 由用户定调，与"嫌慢就加并行"并存）

**同时活跃的对话 ≤ 3 个；每个对话内的子代理 ≤ 3 个；一家之内同一时刻只跑 1 个编译。**
总工自己不计入这 3 个名额。

Why：我把 12 个冷会话一次性全部唤醒，本机内存扛不住，连着闪退两次。
用户要的是**排队推进**，不是**同时推进**。

操作要求：
1. 唤醒前先排序：**未提交风险最高 / 最卡主线的三家**先上，其余一律发**待命令**。
2. 待命令只要求一件事——把手上这一小步 `commit`，或 `git stash push -u -m "<名字-时间-半成品>"`
   并 `git diff > .inflight/<名字>.patch` 留档，然后停止开子代理、停止起编译。
   待命期间仍可用**不跑命令的一句话**向总工回收结论。
3. **已提交、只等总工合入的分支不占活跃名额**——总工用 `premerge_check.sh` 替它们跑，
   别让负责人空跑一轮编译白占内存。
4. 腾出名额后按顺序唤醒下一家，一次一家，不要一次放一排。

### 仍然共享的状态（worktree 解决不了，必须靠约定）

- **`~/Library/Application Support/TcoderMonitor` 与 `defaults` 域 `com.tcoder.monitor`
  是全机唯一的**：多个 worktree 的 App 实例同时跑，会共用项目列表与报告，
  退出时还会互相回写覆盖。→ **同一时刻只允许一个人启动 App 做验证**，
  跑 UI 取证前先 `pgrep -x TcoderMonitor` 确认为 0。
- 真实仓库（`/opt/homebrew` 等）与 `~/Library/Logs` 是只读共享，没问题。

### 迁移期（现在）

WS-A/WS-B/WS-C 此刻在**主树里有未提交在途改动**。不允许直接切 worktree 把他们的工作丢了。
过渡办法（总工执行）：先让三人各自在主树把当前成果 commit（双绿为前提），
总工随后从该 main 切出各自 worktree，**下一轮起所有人只能在 worktree 里干活**。

## 6. 完成标准（Definition of Done）

1. `./scripts/locked_build.sh build` 通过（贴输出）。
2. 至少一个真实验证：在你的分析器上跑过真实目录/真实仓库/真实日志（例如 `/Users/one/Documents/Tcoder`、
   任一本地 git 仓库、`~/Library/Logs`）。
3. 单元测试覆盖你实现的纯函数逻辑（放在你名下的 Tests 文件里）。
4. UI 有实际渲染内容（不能只有占位 EmptyState）。
5. Obsidian 笔记已更新，最终汇报包含：文件清单、验证数字、契约缺口、已知问题。
