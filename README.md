# Tcoder 项目监控

Apple Silicon 原生 macOS App（Swift + SwiftUI），对本地开发项目做一站式工程指标监控。

- 模块名 `TcoderMonitor` · bundle id `com.tcoder.monitor` · 仅 arm64 · macOS 14+
- 架构：SwiftUI Views → `AppState`（MVVM 根）→ Service Layer → 系统能力
- 并行开发规约见 [`TcoderMonitor/AGENTS.md`](TcoderMonitor/AGENTS.md)

## 先分清两类内容

| 你是谁 | 该看哪里 |
|---|---|
| **想用它监控自己的项目**（不写代码、不编译） | [`docs/使用说明.md`](docs/使用说明.md) —— 怎么装、九个页面各在看什么、每个数字怎么算、什么时候会不准、隐私边界、常见问题 |
| **要构建 / 改代码 / 出包取证** | 本文件下列各节（以开发与发布向为主）＋ `TcoderMonitor/AGENTS.md` |

本 README 侧重**开发与发布**；唯一两栖的是「数据口径」一节（两边都该读），
它的**使用者版完整解释**——含界面上原样出现的句子与逐页说明——在
[`docs/使用说明.md`](docs/使用说明.md) 第 4 节。

## 功能

| 页面 | 产出 |
|---|---|
| 总览 Dashboard | 健康评分环、CPU/内存/今日错误/最近提交、代码规模与语言占比、实时性能曲线、最近提交、高频错误、测试覆盖率 |
| 代码规模 | 文件数、总行/空行/注释行/有效代码行、语言占比、TODO·FIXME、最大文件 |
| 复杂度风险 | 巨大文件与中文拆分建议、圈复杂度最高的函数、重复代码率与重复块明细 |
| Git 洞察 | 提交数、项目年龄、提交趋势、24×7 活跃热力（按作者自己的时区）、分支与 HEAD |
| 贡献者 | 提交/增删/占比排行、每人活跃时段、Bus Factor 风险 |
| 性能监控 | 本机 CPU/内存/磁盘/网络实时曲线 + 进程占用排行 + **进程分组**（按匹配模式汇总某服务的 CPU/RAM/Threads/Open Files；旧称「工程进程组」，卡标题已随《40 WS-H》§1.3 收口） |
| 错误日志 | 解析 `Logs/error.log`、`crash.log`、macOS `.ips`；今日错误/崩溃/异常/警告、高频错误聚类（次数、首次、最近；旧称 Top Errors） |
| 依赖分析 | `package.json` / `pom.xml` / `build.gradle(.kts)` / `settings.gradle(.kts)` / `Package.swift` / `requirements.txt`（含 `requirements-*.txt`、`dev-requirements.txt` 派生名）/ `pyproject.toml` / `setup.py` / `Pipfile` / `go.mod` / `Cargo.toml` / `Podfile` / `Gemfile` / `packages.config` —— 共 16 个精确文件名外加派生规则，以 `ManifestFileName.table` 与 `ecosystem(for:)` 的派生名规则为准（`Sources/TcoderMonitor/Services/Dependencies/ManifestParsers.swift:34-62`，
其中 `enum ManifestFileName` 在 `:34`、`table` 在 `:36-53`、派生判定在 `ecosystem(for:)` `:55-62`）；版本过旧与已知漏洞，可选在线查 OSV.dev 与 npm registry |
| 健康评分 | 9 维加权评分与优点/问题/建议。**启发式本地计算，未调用任何外部模型**，界面已如实标注 |

> 上表是开发向速览。逐页「给我看什么 / 数字怎么算的 / 什么时候会不准」见
> [`docs/使用说明.md`](docs/使用说明.md) 第 3 节；页面名称以侧栏为准
> （`Views/Shell/SectionNav.swift:15-23`）。
> 另注：「依赖分析」一行只举了常见清单名，代码实际识别 16 个清单文件名
> （还含 `settings.gradle(.kts)`、`setup.py`、`Pipfile`、`packages.config`，
> `Services/Dependencies/ManifestParsers.swift:36-53`）。

## 构建与运行

> 以下是**开发/发布向**。普通使用者不用构建：拿到 `dist/Tcoder Monitor.app` 双击即可，
> 首次启动、添加项目、重新分析的手动流程见 [`docs/使用说明.md`](docs/使用说明.md) 第 2 节。

```bash
cd TcoderMonitor

# 开发期编译（多智能体并行时必须走这把锁，SwiftPM 的 .build 不支持并发）
./scripts/locked_build.sh build
./scripts/locked_build.sh test

# 产出可双击的 .app 到 dist/
./scripts/build_app.sh release
open "dist/Tcoder Monitor.app"
```

## 验收脚手架

> 纯开发/发布向，使用者可跳过本节与下一段。

```bash
# 端到端：预置一个真实目录让 App 自动扫描，再把落盘的测量结果读回来逐项核对
# （会先备份并自动还原你现有的项目列表；有其他实例在跑时会拒绝执行以免污染结果）
./scripts/e2e_check.sh /path/to/repo

# 九个页面逐页截图取证。开头硬门禁：从当前源码重建 + 测试必须跑绿，
# 否则 exit 1 —— 避免拿旧 dist 二进制截出九张"看着可信"的废图。
./scripts/verify_pages.sh

# 真实仓库取证（默认跳过，因为要对数十万行做全量分析）：
# 断言的是诚实性——提交总数不得是截断采样值、不在仓库根也要认出父仓库、
# 无覆盖率报告时 hasData 必须为 false 而不是 0%。
TCODER_REAL_REPO=1 ./scripts/locked_build.sh test --filter RealRepositoryEvidenceTests

# 证明 dist 里的 .app 确实来自某一次提交（六项机械比对，空值一律判失败）
./scripts/build_app.sh release && ./scripts/verify_provenance.sh
```

打包会把 `git rev-parse HEAD`、分支、**工作树是否干净**、构建时间与
**签名后**的二进制 SHA-256 写进 `Info.plist` 与 `dist/RELEASE_MANIFEST.env`。
`verify_provenance.sh` 逐项比对，其中「构建时工作树干净」这一项专门用来
拒绝认证混入了未提交在途改动的产物。
注：ad-hoc 签名不产出可字节复现的二进制，所以同源码两次构建哈希不同——
这里保证的是**可追溯到提交**，不是可复现构建。

## 数据与隐私

> 使用者版（逐条带界面原文与超时/重试的实际数字）见 [`docs/使用说明.md`](docs/使用说明.md) 第 5 节。

- 所有分析**在本机完成**，不上传任何源码内容。
- 依赖在线查询**默认关闭**，需在「依赖分析」页手动开启。
  单个请求 5 秒硬超时（实测黑洞地址下 OSV=5.006s、npm=5.006s 各自被掐断）；
  但 npm 与 OSV 是**串行**发起的，所以整个在线阶段实测约 10 秒，不是 5 秒。
  超时或失败只降级为内置离线快照，并在页面上写明未核对。
- 项目列表与报告存在 `~/Library/Application Support/TcoderMonitor/`，删除该目录即清空。
- 进程监控**只读展示**，不向任何进程发送信号。
  用到的系统调用仅 `proc_listallpids` / `proc_pidinfo` / `proc_pid_rusage` / `sysctl`
  （`Sources/TcoderMonitor/Services/Performance/ProcessInspector.swift:54,61,72,206`）。
- 在线查询只连 npm registry 与 OSV.dev（域名写死 `DependencyNetworkLookup.swift:128-129`）。
  **注意 OSV 批量接口是 POST**（`OsvClient.swift:129,197`）：语义上只读、请求体只含包名与版本，
  但不是"只发 GET"，写文档时别这么概括。

## 数据口径（看到数字前先读这节）

- **「0 个漏洞」有三种含义**，界面会分开说：全部已比对 / 部分已比对 / 均无版本数据可比对。
  内置离线快照只覆盖 npm、Maven、Python 三个生态，其余生态（RubyGems、CocoaPods、Go、
  Cargo、NuGet、SwiftPM…）在未联网时是**未判定**，不是"安全"。
- **提交总数与作者榜求和可能不相等**：作者与代码行统计一贯采用 `--no-merges` 口径，
  而提交总数含合并提交，差值即 merge 数。页面会分别标注。
- **大仓库的历史是按窗口分析的**：超过上限时 `historyTruncated` 为真，
  页面标"近 N 次提交窗口内"，此时作者数、增删行都是窗口内结果而非全量。
- **健康评分是启发式本地计算，未调用任何外部模型**，界面已如实标注。
  缺少证据的维度**不参与计分也不得分**，其权重按比例摊到场维度，
  页面底部会列出缺失维度与重归一化明细。
- 覆盖率只读取仓库已生成的报告，不会代为执行测试；无报告时显示空态而不是 0%。

> 使用者版含界面上**原样出现**的句子与判定字段，见 `docs/使用说明.md` 第 4 节。
> 两处措辞在此校正（不改上面的结论，只补精确出处）：
> ① 第三种漏洞状态在界面上写的是「未联网核对，仅内置快照（覆盖 npm / Maven / Python）· 无依赖可核对」
>   或「已联网核对，但无可比对版本数据的依赖」
>   （`Sources/TcoderMonitor/Views/Dependencies/DependencyVerdictRows.swift:140-154`），
>   不是「均无版本数据可比对」这句话；
> ② 界面判断「历史是否被窗口截断」用的是派生判据 `isWindowTruncated`
>   （`Sources/TcoderMonitor/Views/CodeGit/GitHistoryScope.swift:65-67`），
>   **不是**契约字段 `GitInsights.historyTruncated`——后者被合并提交污染，两者不等价
>   （赋值处 `Services/Git/ShellGitAnalyzer.swift:245-247`）。

## 已知限制

- **内置示例项目的样例数字在六个页面不带任何「示例」标记**：
  只有侧栏徽标（`Views/Shell/ProjectSidebar.swift:97-100`）与性能页标签
  （`Views/Performance/PerformanceView.swift:50`）会说明它是示例，
  总览 / 代码规模 / 复杂度风险 / Git 洞察 / 贡献者 / 健康评分 六页 `isDemo` 零引用。
  数值全来自 `Services/Demo/DemoData.swift` 的写死样例。
- `git log` 撞上 60 秒硬超时（`Services/Git/ShellGitAnalyzer.swift:53`）时本轮 Git 结果整块置空，
  **上一轮成功的 Git 数据不会被保留**（`App/AppState.swift:148-150` 每次新建报告），
  页面退回「尚未分析 Git 历史」。
- 内置离线漏洞规则共 10 条，只覆盖 npm / Maven / Python
  （`Services/Dependencies/VulnerabilitySource.swift:69-222`）；
  SwiftPM 与 CocoaPods 连在线核对也不支持（`DependencyNetworkLookup.swift:39`）。

- 无 root 时逐进程指标只覆盖当前用户可见的进程；进程总数走 `sysctl(KERN_PROC_ALL)`，与 `top`/`ps -A` 同源。
- 内存口径为 `total - (free + speculative + purgeable)`，与活动监视器一致。
- 首次扫描 `~/Documents`、`~/Desktop` 下的目录时 macOS 可能弹一次文件访问授权。
- 覆盖率只读取仓库已生成的报告（lcov / istanbul / JaCoCo / coverage.py / clover），不会代为执行测试。
