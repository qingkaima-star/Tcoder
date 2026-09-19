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

**补充（20:34 实测教训）：`Tests/TcoderMonitorTests/**` 是同一个编译单元。**
你写的测试文件哪怕生产代码全对，只要它编译不过，
**全仓所有工作流就都跑不了 `test`**——别人会以为是自己的代码坏了。
所以提交前额外跑一次这条（它比整轮 test 快得多，专门用来验证测试模块可编译）：

```bash
./scripts/locked_build.sh build --build-tests   # 必须零 error 才算可以停笔
```

新开的取证/集成测试文件记得带 `@testable import TcoderMonitor`（缺了会报
"cannot find 'XxxAnalyzer' in scope"，看着像别人的代码坏了，其实是你自己的文件）。

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
- 统一用设计系统组件：`SectionCard`、`MetricTile`、`RiskBadge`、`SeverityBadge`、
  `MiniBarGauge`、`EmptyStateView`、`BannerRow`/`BannerStyle`、`StatLine`、`Theme.*`。
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
