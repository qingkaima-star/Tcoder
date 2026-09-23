# Tcoder

Apple Silicon 原生 macOS App（Swift + SwiftUI），对本地开发项目做一站式工程指标监控。

- 模块名 `TcoderMonitor` · bundle id `com.tcoder.monitor` · 仅 arm64 · macOS 14+
- 架构：SwiftUI Views → `AppState`（MVVM 根）→ Service Layer → 系统能力
- 并行开发规约见 [`TcoderMonitor/AGENTS.md`](TcoderMonitor/AGENTS.md)

## 先分清两类内容

| 你是谁 | 该看哪里 |
|---|---|
| **想用它监控自己的项目**（不写代码、不编译） | [`docs/使用说明.md`](docs/使用说明.md) —— 怎么装、九个页面各在看什么；
  口径、隐私、常见问题在它的续篇 [`docs/口径与已知限制.md`](docs/口径与已知限制.md)（小节编号连续，"第 4.x 节"照旧指得准） |
| **要构建 / 改代码 / 出包取证** | 本文件下列各节（以开发与发布向为主）＋ `TcoderMonitor/AGENTS.md` |

本 README 侧重**开发与发布**；唯一两栖的是「数据口径」一节（两边都该读），
它的**使用者版完整解释**——含界面上原样出现的句子与逐页说明——在
[`docs/口径与已知限制.md`](docs/口径与已知限制.md) 第 4 节。

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
| 依赖分析 | `package.json` / `pom.xml` / `build.gradle(.kts)` / `settings.gradle(.kts)` / `Package.swift` / `requirements.txt`（含 `requirements-*.txt`、`dev-requirements.txt` 派生名）/ `pyproject.toml` / `setup.py` / `Pipfile` / `go.mod` / `Cargo.toml` / `Podfile` / `Gemfile` / `packages.config` —— 共 16 个精确文件名外加派生规则，以 `ManifestParsers.swift` 的
`ManifestFileName.table`（清单名 → 生态）与 `ManifestFileName.ecosystem(for:)`（派生名判定）为准；
版本过旧与已知漏洞，可选在线查 OSV.dev 与 npm registry |
| 健康评分 | 9 维加权评分与优点/问题/建议，另并列**工程质量（代码口径）**副读数。**启发式本地计算，未调用任何外部模型**，界面已如实标注 |

> 上表是开发向速览。逐页「给我看什么 / 数字怎么算的 / 什么时候会不准」见
> [`docs/使用说明.md`](docs/使用说明.md) 第 3 节；页面名称以侧栏为准
> （`SectionNav.DetailSection`）。
> 另注：「依赖分析」一行只举了常见清单名，代码实际识别 16 个清单文件名
> （还含 `settings.gradle(.kts)`、`setup.py`、`Pipfile`、`packages.config`，见 `ManifestFileName.table`）。

## 界面风格（简约无界）

九页共用一套视觉规则，且**每条都有机器守卫或像素读数兜着**，不靠"看着像"：

| 规则 | 落地 | 怎么被守住 |
|---|---|---|
| 地面是纯白/纯黑，内容卡**不画面** | `Theme.Palette.Surface.ground`（浅 `#FFFFFF` / 深 `#000000`）。**2026-09-21 更正**：上一版定成灰 `#F1F1F3`，实拍 87–95% 像素落在同一条灰带 = 用户判词「灰色底显脏」；且 `referenceSurface` 一直是白/`#1E1E1E`，灰地面等于让像素比 3:1 断言低 12% | 九页像素读数分带：白占比从 0–13% → **89–98%**（`scripts/pixel_audit.swift`） |
| 井是唯一允许的填充 | `Theme.Palette.Surface.well`（浅 `#F5F5F7`），只给表格/日志/代码块；**行底不铺色**，行与行之间只留发丝线 | 同文件的「全仓无材质」用例 + `test_noBoxedSegmentedPickersRemain` 同族的画法唯一性用例 |
| 投影只给浮层 | `View.surface` 的 `.floating` 分支，全仓 1 处 | 同文件的「投影全仓唯一且只落在浮层分支」用例 |
| 最重的墨给最大的数 | 主读数一律 `Theme.Palette.Surface.ink`（`.primary` 不够黑：`labelColor` 只有 85% 黑） | 九页像素读数最暗像素亮度 0.000–0.004 且落在最大数字所在带 |
| 结构去色、语义留色 | 颜色只承载状态（健康分档/风险/日志等级/增删）与交互；**序列色属于图与图例，不属于数字**，规则收在 `ChartSeries`。**2026-09-21 再收两步**：提示条从"整幅 15% 色底"改成**左侧 2pt 语义色竖标**（彩色面积降 99.9%）；占比条与作者份额条不再按名字/邮箱取序列色，一律纯墨 | 同文件的「取色规则只有一份」用例 + 数据涂倾向色实测 0 处 |
| 强调色钉死为绿，不跟随系统 | `Theme.Semantic.accent` 从"跟随用户系统强调色"改成定值（`graphic #15803D` 双向过线：画在白底 5.02:1、白字压在其上 5.02:1）。accent 从此进 `measurable`，八个角色全部参与对比度断言，无一豁免 | `testAccentGraphicClearsBothGraphicAndOnFillLines` + `testSemanticRegistryIsCompleteAndUniquelyNamed`（收紧成"一个都不能少"） |
| 一屏只有一个大标题 | 项目名降成 11pt 面包屑，节名升成唯一 H1；标题行收在基座 `Theme.Page.Header`，九页各声明一处 | `test_everyPageDeclaresExactlyOnePageHeader`（数调用点：缺一页或一页两份都红）+ 元测试 |
| 分组靠小标题 + 留白 | `Theme.Typo.groupLabel`（10pt medium + 0.6pt 字距），组间 `Theme.Spacing.group`(32) / 页级段落 `Theme.Spacing.section`(40) / 页边距 `Theme.Spacing.pageMargin`(24) | 同文件的「呼吸档必须有人引用」用例 |
| 一套骨架、一套取色 | `Theme.Page.Scaffold` 与 `ChartSeries` 全仓各只有一份，都在 `Design/` | 同文件的「页骨架只许一份」用例 + 上一条 |

排版令牌**唯一消费入口是 `View.typed`** —— `Font` 没有任何字距 API，
写 `.font(Theme.Typo.groupLabel.font)` 会静默丢掉字距，所以有守卫专门抓这种写法。

已解决（2026-09-21）：深色 `warning` 从纯黄 `#FFD60A` 降到 `#FF9F0A`。
旧值相对亮度 0.694，比 `danger` 的 0.258 **亮 2.7 倍** —— 一个 61 分的中间档
在深色下成了整块色板里最响的东西；新值 0.461 回到色带内。

设计规格与实施计划见 `docs/superpowers/specs/2026-09-20-borderless-minimal-ui-redesign-design.md`
与 `docs/superpowers/plans/2026-09-20-borderless-minimal-ui-redesign.md`；
逐页像素读数与机械反查结果见 `docs/九页实拍读数.md` §2.5。

> 上面那两份是**第三轮「简约无界」**的规格，其中"去卡片面、纯墨主线"的取值
> 已被 2026-09-21 的裁定取代。现在的权威口径是这两份：
- **界面中英双语**：键 = 简体中文原文，缺一条译文的表现是退回中文而不是漏机器键；
  覆盖范围、现量读数与三条诚实边界见 [`docs/使用说明.md`](docs/使用说明.md) §2.5。
> [`docs/界面语言-对齐AiX.md`](docs/界面语言-对齐AiX.md)（灰画布 + 白卡 + azure 蓝，
> 含 §6.2 起每批取证与修后的复拍记录），
> 以及 [`docs/界面-乱的清单.md`](docs/界面-乱的清单.md)
> ——「乱」按**重叠 / 溢出 / 对齐 / 层级 / 密度**五类逐条列，每条给落点与判据
> （哪把守卫，或哪张图的哪个读数），并列出还开着的四条。

## 构建与运行

> 以下是**开发/发布向**。普通使用者不用构建：拿到 `dist/Tcoder.app` 双击即可，
> 首次启动、添加项目、重新分析的手动流程见 [`docs/使用说明.md`](docs/使用说明.md) 第 2 节。

```bash
cd TcoderMonitor

# 开发期编译（多智能体并行时必须走这把锁，SwiftPM 的 .build 不支持并发）
./scripts/locked_build.sh build
./scripts/locked_build.sh test

# 产出可双击的 .app 到 dist/
./scripts/build_app.sh release
open "dist/Tcoder.app"
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

# 同一件事的**隔离版**：自带 /tmp 沙箱支持目录（走 TCODER_SUPPORT_DIR），
# 所以不要求"本机零实例"，也不会与正在运行的实例互相回写项目列表。
# 它同样先做"dist 二进制 == 当前源码"的来源证明，拍完还会核对九张图不许字节相同。
./scripts/capture_pages_isolated.sh /tmp/tcoder-pages

# 真实仓库取证（默认跳过，因为要对数十万行做全量分析）：
# 断言的是诚实性——提交总数不得是截断采样值、不在仓库根也要认出父仓库、
# 无覆盖率报告时 hasData 必须为 false 而不是 0%。
TCODER_REAL_REPO=1 ./scripts/locked_build.sh test --filter RealRepositoryEvidenceTests

# 证明 dist 里的 .app 确实来自某一次提交（六项机械比对，空值一律判失败）
./scripts/build_app.sh release && ./scripts/verify_provenance.sh

# 无头 CLI：不启动 App 就把一个仓库的工程指标读到终端 / 管道里。
# 同一个二进制的 argv 分派（词表见 CLIRouter.headlessWords），GUI 启动路径零影响。
./.build/debug/TcoderMonitor score /path/to/repo        # 只出读数：失败路在前，缺席维度带原因
./dist/Tcoder.app/Contents/MacOS/TcoderMonitor scan . --compact | jq .health.overall
./dist/Tcoder.app/Contents/MacOS/TcoderMonitor doctor   # 我在用哪个二进制、debug 还是 release
./scripts/self_score.sh                                 # 扫本仓库自己（改造前要起 App 轮询落盘，上限 300 秒）

# 为什么要这个入口：AI 与子代理此前各自拿 find|wc、git shortlog 数同一件事，
# 那些就是第二把尺子。退出码 0 / 2 / 3 / 4 / 64 里**没有"静默成功"这一档**：
# 非 0 时先读 failedSections 再谈结论；缺席的那一路在 JSON 里整键缺席，而不是被填成 0。
```

打包会把 `git rev-parse HEAD`、分支、**工作树是否干净**、构建时间与
**签名后**的二进制 SHA-256 写进 `Info.plist` 与 `dist/RELEASE_MANIFEST.env`。
`verify_provenance.sh` 逐项比对，其中「构建时工作树干净」这一项专门用来
拒绝认证混入了未提交在途改动的产物。
注：ad-hoc 签名不产出可字节复现的二进制，所以同源码两次构建哈希不同——
这里保证的是**可追溯到提交**，不是可复现构建。

## 数据与隐私

> 使用者版（逐条带界面原文与超时/重试的实际数字）见 [`docs/口径与已知限制.md`](docs/口径与已知限制.md) 第 5 节。

- 所有分析**在本机完成**，不上传任何源码内容。
- 依赖在线查询**默认关闭**，需在「依赖分析」页手动开启。
  单个请求 5 秒硬超时（实测黑洞地址下 OSV=5.006s、npm=5.006s 各自被掐断）；
  但 npm 与 OSV 是**串行**发起的，所以整个在线阶段实测约 10 秒，不是 5 秒。
  超时或失败只降级为内置离线快照，并在页面上写明未核对。
- 项目列表与报告存在 `~/Library/Application Support/TcoderMonitor/`，删除该目录即清空。
- 进程监控**只读展示**，不向任何进程发送信号。`ProcessInspector.swift` 用到的查询接口
  **共五类**（不是早先写的四类）：`sysctl(KERN_PROC_ALL)` 数进程总数（`ProcessInspector.processCount`）、
  `proc_listallpids`（`ProcessInspector.listAllPids` / `visibleProcessCount`）、
  `proc_pidinfo` 的三种 flavor `PROC_PIDTBSDINFO` / `PROC_PIDTASKINFO` / `PROC_PIDLISTFDS`
  （`bsdInfo` / `taskInfo` / `openFileCount`）、**`proc_pidpath`**（`executablePath`，早先这行漏了它）、
  `proc_pid_rusage`（`rusageInfo` 经 `callRusage`）。全是取值用的，没有任何写操作。
- 在线查询只连 npm registry 与 OSV.dev，两个域名写死在 `DependencyNetworkLookup.osvHost` 与
  `DependencyNetworkLookup.npmRegistryHost`。
  **注意 OSV 批量接口是 POST**（`OsvClient.swift` 的 `DependencyNetworkLookup.osvQueryBatch`，
  逐包回退 `osvQuerySingle` 同样是 POST）：语义上只读、请求体只含包名与版本，
  但不是"只发 GET"，写文档时别这么概括。

## 数据口径（看到数字前先读这节）

- **「0 个漏洞」有三种含义**，界面会分开说：全部已比对 / 部分已比对 / 均无版本数据可比对。
  内置离线快照只覆盖 npm、Maven、Python 三个生态，其余生态（RubyGems、CocoaPods、Go、
  Cargo、NuGet、SwiftPM…）在未联网时是**未判定**，不是"安全"。
- **提交总数与作者榜求和可能不相等**：作者与代码行统计一贯采用 `--no-merges` 口径，
  而提交总数含合并提交，差值即 merge 数。页面会分别标注。
- **大仓库的历史是按窗口分析的**：**非合并提交**打满 20,000 条窗口上限时界面才标"近 N 次提交窗口内"，
  判据是派生属性 `GitHistoryScope.isWindowTruncated`（**不是**契约字段 `GitInsights.historyTruncated`，
  理由见本节脚注②与 `docs/使用说明.md` 第 4.3 节），此时作者数、增删行都是窗口内结果而非全量。
- **健康评分是启发式本地计算，未调用任何外部模型**，界面已如实标注。
  缺少证据的维度**不参与计分也不得分**，其权重按比例摊到场维度，
  页面底部会列出缺失维度与重归一化明细。
- **本仓库自己被自己扫的读数是公开的**：`./scripts/self_score.sh` 出综合分与
  「工程质量（代码口径）」两个数，逐维依据见 `docs/口径与已知限制.md` §4.4.2。
  两个数必须一起读：代码口径只统计"靠改代码抬得起来"的维度，
  综合分里那 21% 权重（提交活跃度 + 协作分布）量的是 Git 历史的既成事实，
  新仓库与署名口径都会压低它，与代码好坏无关。
- 覆盖率只读取仓库已生成的报告，不会代为执行测试；**没有报告时整块不画**（连分隔线都不出现），
  既不是空态卡也不是 0%——实现是 `DashboardView.coverageStrip` 外面那层 `coverage.hasData` 判断，
  与 `docs/使用说明.md` 第 4.6 节同一条口径。

> 使用者版含界面上**原样出现**的句子与判定字段，见 `docs/使用说明.md` 第 4 节。
> 两处措辞在此校正（不改上面的结论，只补精确出处）：
> ① 第三种漏洞状态在界面上写的是「未联网核对，仅内置快照（覆盖 npm / Maven / Python）· 无依赖可核对」
>   或「已联网核对，但无可比对版本数据的依赖」
>   （`DependencyVerdictRows.DependencySafetyVerdict.summaryCaption`），
>   不是「均无版本数据可比对」这句话；
> ② 界面判断「历史是否被窗口截断」用的是派生判据 `isWindowTruncated`
>   （`GitHistoryScope.isWindowTruncated`，判据是非合并窗口是否打满），
>   **不是**契约字段 `GitInsights.historyTruncated`——后者在 `ShellGitAnalyzer.makeInsights` 里按
>   `commitsAnalyzed < totalCommits` 赋值，仓库只要有一个合并提交它就为真：本仓 2026-09-20 实测
>   `git rev-list --count HEAD` = 291（含 127 次合并、非合并 164），距 20,000 的窗口上限差两个数量级，
>   该字段依然是真。所以描述界面行为时按 `isWindowTruncated` 写，别按字段名写。

## 已知限制

- **内置示例项目已于批次 P7-A 退役**（用户口径：「所有功能都要正常使用，不能有假数据」）。
  首启不再种示例、侧栏与菜单不再有「加载示例项目」、`MonitoredProject.isDemo` 字段删除。
  现在界面上出现的每个数字，都必须来自你选择的那个真实仓库。
  退役前它有一条已知缺陷：六个页面的样例数字**不带任何「示例」标记**
  （当时只有侧栏行、性能、日志、评分四处带标）—— 全过程与接替守卫记在
  `docs/功能真实性清单.md` 的 S1 条，机器断言是 `FunctionalHonestyGuardTests` 的
  `test_noFabricatedProjectDataAnywhereInSources`。
- `git log` 撞上 60 秒硬超时（`ShellGitAnalyzer.swift` 的 `ShellGitAnalyzer.init` 参数 `logTimeout`
  默认值）时本轮 Git 结果整块置空，
  **上一轮成功的 Git 数据不会被保留**（`AppState.scan` 每次新建报告），
  页面退回「尚未分析 Git 历史」。
- 内置离线漏洞规则共 10 条，只覆盖 npm / Maven / Python
  （`VulnerabilitySource.swift` 的 `VulnerabilitySource.bundled`，逐条编号看每条的
  `KnownVulnerability.cveIdentifiers`）；
  SwiftPM 与 CocoaPods 连在线核对也不支持
  （`DependencyNetworkLookup.swift` 的 `OsvPackageQuery.osvEcosystem` 对它们返回 nil）。
- 无 root 时逐进程指标只覆盖当前用户可见的进程；进程总数走 `sysctl(KERN_PROC_ALL)`，与 `top`/`ps -A` 同源。
- 内存口径为 `total - (free + speculative + purgeable)`，与活动监视器一致。
- 首次扫描 `~/Documents`、`~/Desktop` 下的目录时 macOS 可能弹一次文件访问授权。
- 覆盖率只读取仓库已生成的报告（lcov / istanbul / JaCoCo / coverage.py / clover），不会代为执行测试。

### 这些数字是跟谁对齐的

> 一个功能指标如果讲不出"跟哪个系统工具比过、差多少、差在哪"，它就不该被拿去打分。

- **代码规模**：常见做法是拿 `cloc` 当基准，但**本机没有 `cloc`**（`tokei`、`scc` 同样未安装），
  所以这里改用一套与分析器零共享代码的独立口径核对：`git ls-files` 排除 `vendor/` 后 `wc -l`。
  主导语言在测量当天逐位吻合，对上的读数是 **1756 文件 / 239,668 行**（2026-09-19 实测）。
  **`/opt/homebrew` 是活的第三方仓库，这两个数不是恒定量**：2026-09-20 同口径复测已漂到
  **1757 文件 / 240,128 行**（当时其 HEAD 为 `72ba737379`）。复现命令（全部只读）：
  ```bash
  git -C /opt/homebrew ls-files '*.rb' | grep -v vendor | wc -l
  git -C /opt/homebrew ls-files -z '*.rb' | grep -zv vendor \
      | (cd /opt/homebrew && xargs -0 wc -l) | tail -1
  ```
  所以本条只能读作「当日实测 X，隔天会漂」；要复核的是**命令与口径**，不是那两个数本身。
  文件总数上的差值来自分析器**比窄后缀白名单更包含**（`.rake`、`.gemspec`、`.podspec`
  以及 `Gemfile`、`bin/brew` 这类无后缀可执行脚本），不是漏算或多算。
- **Git 指标**：提交总数与 `git rev-list --count HEAD` 逐位一致；增删行数与同窗口
  `git log --no-merges --numstat` 的聚合**一字不差**（`+1672258/-1347981`）。
  作者数**已解释，不是误差**：分析器按 `normalizeEmail` 归一后的邮箱去重
  （`GitLogParser.swift`：去尖括号、去空白、转小写，且对 `gmail.com` / `googlemail.com`
  剥掉 `+alias` 后缀）。Homebrew 窗口内 618 个原始邮箱里有且仅有一对
  `tomhu1096+gpg@gmail.com` 与 `tomhu1096@gmail.com` 被归并为同一人，因此工具给 **617**；
  复现命令：
  `git log --no-merges -n 20000 --format=%aE | sort -u | wc -l` → 618，套上上述归一 → 617。
  两个必须一起读的口径提醒：作者数只在 **`-n 20000` 采样窗口**内统计（全历史非合并
  为 35,907 次提交、1,331 个姓名），且**按姓名去重只有 587**——所以任何"作者数对不对"的
  讨论都要先说清是姓名口径还是邮箱口径、窗口口径还是全历史口径。
- **运行时指标**：与活动监视器 / `top` / `ps` 的可比性由 `PerformanceLiveSampleTests`
  三条用例钉住（采样可与活动监视器比、进程组与真实进程匹配、磁盘吞吐是差值而非累计量）。
- **覆盖率**：以 `llvm-cov` 为基准。2026-09-20 在 `1e6319d` 上重测：
  ```
  swift test --enable-code-coverage
  xcrun llvm-cov export -format=lcov -instr-profile <...>/codecov/default.profdata \
      <...>/TcoderMonitorPackageTests.xctest/Contents/MacOS/TcoderMonitorPackageTests
  ```
  汇总本次 lcov 的全部 `LF/LH`（163 条记录）得到**全口径 27047/42137 = 64.19%**，
  但分母里有 **18486 行（43.87%）来自项目自己的测试代码与构建派生物**，
  所以真正进分数的读数是**生产码口径 11080/23651 = 46.85%**：
  ```
  Sources/TcoderMonitor/**（生产码，进评分）   11080 / 23651  = 46.85%
  Tests/TcoderMonitorTests/**（测试码，不评分） 15953 / 18469  = 86.38%   占分母 43.83%
  ```
  分析器与独立汇总**逐位一致**，由 `SelfScanCoverageAgreementTests` 守着
  （真产物那条需 `TCODER_SELF_LCOV=<lcov 路径>` 显式开启）。

  **为什么评分不看全口径（#37）**：测试代码天然接近满覆盖，把它算进分母等于
  给分数一个"不必改善生产码也能涨"的增长项。这不是推演——同一套统计在 `ee8e7b9` 是
  全口径 64.00%，期间**一行生产码都没改**、只往 `Tests/` 加了 140 行测试，就涨到 64.19%。
  现在 `CoverageMetrics.overallLinePercent` 只算 `CoverageScope.isProductionSource` 为真的记录，
  全量数字降级为次要读数 `allSourcesLinePercent`，界面上标"含测试代码 xx%（不用于评分）"，
  并把口径本身写在读数旁边。守门用例是 `CoverageProductionScopeTests`，实测打印：
  ```
  【#37 增长项】生产码 40.0% → 40.0%（加测试码不变）；全口径 40.00% → 69.50%（自己涨）
  ```
  即"**只加测试码不得改变报出的生产码覆盖率**"这条性质现在是被钉住的。
  对本仓库自己的端到端实测（同一份真 lcov，只换口径）：
  ```
  改前 全口径 64.19%  → 测试覆盖分量 78 分 · 总分 73
  改后 生产码 46.85%  → 测试覆盖分量 62 分 · 总分 72
  ```
  也就是说把测试代码从分母里摘出去，**这个项目的自评降了 1 分**——
  分数变低是这次修改预期的、正确的结果，不是回归。
  另外，覆盖率产物是仓库自己生成的本地文件（`TcoderMonitor/coverage/` 被 gitignore、
  没有 git 历史），所以读数旁边会写**报告年龄**：
  多份报告按**最旧那份**说新鲜度，取不到时间的报告单独计数，
  整批都没有时间时显示「报告为未知生成时间（不按新鲜数据计）」而不是干脆不显示（#38）。
