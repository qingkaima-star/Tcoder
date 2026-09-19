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

- 仓库根：`/Users/one/Documents/Tcoder/TcoderMonitor`
- Swift 6.3.3 / Xcode 26.6 / macOS SDK 26.5 / 仅 arm64。目标系统 macOS 14+。
- SwiftPM 可执行 target + `@main`（没有 main.swift）。语言模式被显式降到 **Swift 5**
  （`Package.swift` 里 `.swiftLanguageMode(.v5)`），所以 Sendable 只会警告，不会报错。
  **不要改 `Package.swift`，不要把语言模式调回 6。**

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

同一工作流内的子代理之间也必须**按文件名切分**，任何人不得改别人的文件。

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

## 6. 完成标准（Definition of Done）

1. `./scripts/locked_build.sh build` 通过（贴输出）。
2. 至少一个真实验证：在你的分析器上跑过真实目录/真实仓库/真实日志（例如 `/Users/one/Documents/Tcoder`、
   任一本地 git 仓库、`~/Library/Logs`）。
3. 单元测试覆盖你实现的纯函数逻辑（放在你名下的 Tests 文件里）。
4. UI 有实际渲染内容（不能只有占位 EmptyState）。
5. Obsidian 笔记已更新，最终汇报包含：文件清单、验证数字、契约缺口、已知问题。
