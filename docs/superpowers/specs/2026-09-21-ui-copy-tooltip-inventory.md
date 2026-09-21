# 九页「解释性小文案」盘点表（ⓘ 收纳工单的输入）

产出：2026-09-21 · 盘点者：只读盘点子代理 · 落档：总工（WS-CL）
用户判词原文：**"小文案实在是太多了，把这些小文案都隐藏到那些圆圈问号里面，鼠标放上去的时候再显示详细文案。"**

判定标签：`藏`｜`留短藏长`｜`删`；`●` = 承担诚实性告知（见 Z 节，**不得整条藏**）。

## 表头：口径与覆盖声明

- **基准树**：`.worktrees/cli`，分支 `ws/cli-headless`，HEAD `155b4a1`。
- **文件数**：`Sources/TcoderMonitor/Views/**` 实测 **42 个 .swift，42/42 全部通读**
  （Code 6 / CodeGit 2 / Dependencies 3 / Git 5 / Health 3 / Logs 5 / PerfLogs 3 / Performance 6 / Shell 6 / 顶层 3）。
  `Design/**` 15 个：12 个通读，`Glass.swift / ColorToken.swift / ChartTokens.swift / ThemeTokens.swift / ThemeMetrics.swift`
  **已扫描未通读**（仅 `\p{Han}` 字面量扫描，结论：无上屏文案，唯一字面量是
  `ThemeMetrics.Layout.languageProbeKey = "总览"`，属探语言用键）。
- **本地化事实**：`Resources/` 下只有 `en.lproj`（`Localizable.strings` 526 键 + `.stringsdict`）。
  `Design/LocalizedCopyKit.swift` 的 `localizedCopy/localizedFormat/localizedCount` **以简体中文原文作键**，
  所以"键名"与"中文值"是同一串，英文值在 en.lproj。下表原文即键。
- **计入判据**：常驻上屏、承担"这个数字怎么算的 / 什么时候不准 / 为什么是 `--` / 下一步做什么"的句。
  **不列入**：列头、按钮标题、≤12 字短态词、改进建议与风险结论正文、`accessibilityLabel`、已在 `.help(...)` 里的串。
- **计数单位**：一处文案 = **一个上屏文案槽位**（不是字符串键）。槽位内含互斥分支的在原文栏标"N 支"。
  **分支展开后的总键数未逐支穷举，标『未覆盖』。**

**五数**：总条数 **129** ｜ 藏 **19** ｜ 留短藏长 **94** ｜ 删 **16** ｜ 承担诚实性告知 **89**。

## A 总览（含外壳、侧栏、共用句式）— 9

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `DashboardView.coverageCaliberLine` | 「口径：仅生产码（已排除 Tests/、PackageTests、.build、*Tests.swift），含测试代码 %@（不用于评分） · 差 %@ 来自测试代码」／「…与含测试代码的口径一致」／「口径：报告只有汇总粒度，未区分测试代码 · 来源 %@」3 支（55/42/22） | 留短藏长 ● |
| `DashboardView.codeScaleGroup` | 「选择项目目录后自动统计。」11 | 删（同屏有引导卡 + 添加按钮） |
| `DashboardView.topErrorsCard`（hasData 支） | 「已扫描 %@ 个日志文件，没有命中错误行。」18 | 留短藏长 ● |
| `DashboardView.topErrorsCard`（无数据支） | 「在项目内放置 Logs/error.log 或 crash.log，或用「附加日志文件」手动选择。」38 | 藏（操作指引） |
| `HealthHeroCard.narrative` | 「点击右上角「重新分析」，扫描代码规模、Git 历史、日志与依赖之后这里会出现评分与结论。」42 | 留短藏长 |
| `ProjectDetailView.content` | 「在左侧「选择目录…」指一个本地仓库目录，九页读数全部由它真实算出来。」33 | 留短藏长 |
| `DashboardLiveReadout.livePerformanceGroup` | 「首个采样点到达后显示曲线。」12 | 藏 |
| `AddProjectGuideCard.hint` | 「把项目文件夹拖到这里，或选择本地目录」18 | 留短藏长 |
| `ShellCopy.notAnalyzed/scannedButFoundNone/cannotAnalyze` | 三组互斥句式共 15 键（9–20） | 留短藏长 ● |

## B 代码规模 — 17

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `CodeMetricsSummaryGrid.body`(GlassSection subtitle) | 「代码 / 注释 / 空行共同构成总行数」15 | 删（与 `CodeInvariantRow` 等式逐字同义） |
| `CodeScaleSection.body`(hero note) | 「总行数（= 空行 + 注释 + 代码）」14 | 留短藏长 ● |
| `CodeScaleSection.subtitle` | 「按有效代码行计，共 %1$@ 种语言，展示前 %2$@ 种」20 | 留短藏长 ● |
| `CodeScaleSection.languageBlock` | 「扫描到 %@ 个文件，但没有任何语言的有效代码行占比大于 0。」25 | 留短藏长 ● |
| `CodeMetricsView.mergedNote`(DataFootnote) | 「「其他」合并了占比最低的 N 种语言，合计 X 行 · Y%。」26 | 留短藏长 ● |
| `CodeInvariantRow.body`(不一致支) | 「分项之和 %@ 与总行数相差 %@ 行，以扫描器输出为准。」24 | 留短藏长 ● |
| `CodeInvariantRow.body`(降级支) | 「识别规则降级：%1$@ 条正则没能编译，函数数与圈复杂度会偏低。这一屏的 0 读作「我们的规则没跑起来」，不读作「这个仓库没有函数」。」62 | 留短藏长 ● |
| `CodeMarkersSection.body` | 「源码里留下的待办标记，只代表历史备注，不代表当前缺陷」25 | 留短藏长 ● |
| `CodeMarkersSection.markerNote`(零支) | 「已完成扫描：N 个文件里没有 TODO / FIXME 标记。」22 | 留短藏长 ● |
| `CodeMarkersSection.markerNote`(FIXME 支) | 「FIXME N 处通常表示已知缺陷，建议优先在对应文件里核对。」27 | 藏 |
| `CodeHotspotSection.subtitle`(空支) | 「行数是单文件总行数（含空行与注释）」17 | 留短藏长 ● |
| `CodeHotspotSection.subtitle`(非空支) | 「共 %1$@ 个 · 最大 %2$@ 行 · 点击条目在 Finder 中显示」22 | 删（后半是操作提示，行尾图标已带 help） |
| `CodeHotspotSection.truncationNote` | 「另有 N 个未展示 · 当前列出 X / Y 个。」20／「共 N 个，已全部展示。」12 | 留短藏长 ● |
| `CodeDuplicationSummarySection.body` | 「仅概览数字，明细见「复杂度风险」页」16 | 藏（导流句） |
| `CodeDuplicationSummarySection`(重复率 caption) | 「的代码行落在重复块内」10 | 留短藏长 ● |
| `CodeDuplicationSummarySection`(均长 caption) | 「仅统计 ≥2 行的函数」10 | 留短藏长 ● |
| `CodeDuplicationSummarySection`(DataFootnote) | 「重复块 N 个 · 复杂度上榜 M 个函数」18 | 删（两个数在上一行读数带已各占一格） |

## C 复杂度风险 — 10

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `CodeRiskOverviewSection.body`(hero note) | 「的代码行落在重复块内 —— 综合风险 X，明细见下方「重复代码率」」27 | 留短藏长 ● |
| `CodeRiskOverviewSection.body`(DataCaption) | 「口径：N 个文件 · M 行有效代码 · 主语言 X」20 | 留短藏长 ● |
| `CodeDuplicationSection.body`(subtitle) | 「分母是有效代码行数（不含空行与注释）· 分子是落在重复块内的代码行」30 | 留短藏长 ● |
| `CodeRiskAnalysis.duplicationCaption`(DataCaption) | 「约 X 行 / 有效代码 Y 行 · 重复块 Z 个」20 | 删（与上一行同屏同义，一屏两遍） |
| `CodeDuplicationSection.body`(空态) | 「扫描了 N 个文件 / M 行有效代码，重复率为 X%。」24 | 留短藏长 ● |
| `CodeDuplicationSection.truncationNote` | 2 支 21／14 | 留短藏长 ● |
| `CodeRiskAnalysis.complexitySubtitle` | 「按圈复杂度降序 · 上榜 N 个 · CC 区间 A~B · 颜色取自引擎给出的风险分档」30 | 留短藏长 ● |
| `CodeComplexitySection.body`(DataFootnote) | 「点击行在 Finder 中定位源文件，行尾图标用默认应用打开。」26 | 藏 |
| `CodeSuggestionSection.body`(subtitle) | 「逐条对应本次扫描的真实数字，无数字支撑的不写」21 | 藏（对我们工作方式的自述，不改变任何读法） |
| `CodeRiskAnalysis.noRiskNote`(DataNotice) | 「已完成扫描，本次未见结构性风险：重复代码率 X、超长函数 N 个、最大文件 M 行。保持现状即可。」42 | 留短藏长 ● |

## D Git 洞察 — 14

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `GitInsightsMetricGrid.body`(subtitle) | 「以下均为测得值，口径见上方口径条」16 | 藏 |
| `GitHistoryScope.headline`（经 `GitCommitScopeSection.message` 上屏） | 4 支：「共 N（含 M 次合并）· 作者与代码行统计基于 K 次非合并提交」30／「…历史中没有合并提交，…覆盖全部 K 次提交」33／「…只覆盖最近 K 次非合并提交，更早的历史未纳入」38／「…这份报告没有记录非合并提交数…重新分析后可拆分」42 | 留短藏长 ● |
| `GitCommitScopeSection.message`(截断追加句) | 「。趋势、时段分布与作者占比都只是这段窗口的分布，不代表全部历史。」28 | 留短藏长 ● |
| `GitHistoryScope.totalTileCaption` | 4 支（12–20，含「含合并 · 非合并窗口 N 次」「旧报告未记录窗口口径」） | 留短藏长 ● |
| `GitHistoryScope.authorTileCaption` | 3 支（15/17/22，含「近 N 次提交窗口内 · K 人」「%@ 人 · 分母口径未记录」） | 留短藏长 ● |
| `GitRepositorySourceSection.discoveryDetail` | 4 支（14–20）；`.selectedDirectory` 支与 `discoveryCaption`「所选目录即仓库」同义复述 | 藏（该支判删） |
| `GitRepositorySourceSection.body`(DataFieldRow value) | 「来源未记录（旧数据，重新分析后可见）」17 | 留短藏长 ● |
| `GitNestedCandidatesSection.body`(subtitle) | 「当前只分析了提交数最多的那一个；要单独分析其中某个，直接把它添加为项目」33 | 留短藏长 ● |
| `GitActivitySection.body`(subtitle) | 「数据源只有边际分布 · 单元格是小时与星期两档归一的近似强度」+ `windowSuffix` 27 | 留短藏长 ● |
| `GitActivityHeatmap.body`(.help) | 「提交活跃度按星期与小时近似分布；强度为两条边际归一边际的平均值，是近似值」40 | 删（与上一行同卡同义，且已是 hover 位） |
| `GitActivitySection.busiestCaption`(DataFootnote) | 「最活跃时段：H:00 · 按各作者本地时区合并，未做时区归一」／「小时分布为空，只有星期分布可用」24/15 | 留短藏长 ● |
| `GitCommitTrendSection.body`(subtitle) | 「按 %@ 分桶 · 共 N 桶 + 窗口后缀」18 | 留短藏长 ● |
| `GitCommitTrendSection.body`(空态) | 「Git 分析没有产出按时间分桶的提交数据，因此这里无法给出峰值或均值。」31 | 留短藏长 |
| `GitInsightsEmptyState.missingAnalysis` | 「选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示提交趋势、24×7 活跃分布与最近提交记录。」+ `attemptedLocationsText`（产自 Services）≈70 | 留短藏长 |
| `GitRecentCommitsSection.body`(空态) | 「历史里有提交，但提交记录本身没有带回任何一行（旧报告或分析中断都会这样）。\n趋势与作者统计仍按已解析的部分给出，这里只说明明细缺失。」62 | 留短藏长 ● |
| `GitDataAbsence.copy`（服务本页与贡献者页） | 4 组 message：「分析器在所选目录及其上下若干层里都没有找到仓库根。\n这是「不适用」，不是「没有提交」…」52／「0 次提交是这次测得的结果，不是没扫…」44／「本次解析到 N 次非合并提交，却没有一条带得出作者字段。\n这是作者数据缺失，不是「零贡献者」…」55／「通常是历史里全部为合并提交…这里不给任何结论。」46 | 留短藏长 ● |

## E 贡献者 — 9

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `ContributorsView.body`(空态) | 「选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示贡献者排行、代码变更量与活跃时段分布。」44 | 留短藏长 |
| `ContributorBusFactorSection.message` | 5 支（20–55），含「（分母 = %@ 次非合并提交）」「单点风险：…活跃作者仅 N 人。」「贡献分布健康：…」 | 留短藏长 ● |
| `ContributorsMetricGrid.body`(subtitle) | = `GitHistoryScope.headline`（与 D 组同键的第二落点，此处整页唯一落点） | 留短藏长 ● |
| `ContributorsMetricGrid`(hero note) | 「%@ · 一人完成 · %@ 次」+「（算不出）」18 | 留短藏长 ● |
| `ContributorsMetricGrid`(累计变更 caption) | 「%1$@ / %2$@ · 按非合并提交统计」18 | 留短藏长 ● |
| `ContributorRankingSection.body`(subtitle) | 「按提交数降序 · 展示 %1$@ / %2$@ 人」14 | 留短藏长 |
| `ContributorRankingSection.truncationNote` | 「共 N 位贡献者，已全部展示。」／「另有 N 位贡献者未展示。」14/12 | 留短藏长 ● |
| `ContributorConcentrationSection.body`(subtitle) | 「Bus Factor %1$@ · 前 3 名合计 %2$@ + 窗口后缀」25 | 留短藏长 ● |
| `ContributorConcentrationSection`(DataNotice 2 支) | 「全部提交仅来自 1 位贡献者，任何离队都会让项目停摆。」25／「其余 N 位作者合计不足 X%，缺少可接手的第二人。」24 | 留短藏长 ● |

## F 性能监控 — 25

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `PerformanceView.header`(Page.Header subtitle) | 「系统级实时读数只观测不干预。数值随采样刷新，取不到的一律显示 --，不会补成 0。」38 | 留短藏长 ● |
| `PerformanceView.statusBanners`(暂停) | 「采样已暂停：下方为最后一次采集结果，点「继续」恢复实时刷新。」28 | 留短藏长 ● |
| `PerformanceView.statusBanners`(内存) | 「内存读数不可信：%@。本页按 -- 显示，未把它画成占满。」26 | 留短藏长 ● |
| `PerformanceSystemTiles.sectionSubtitle` | 「%1$@ 个核心 · 口径与活动监视器一致」15 | 留短藏长 ● |
| `SystemReadings.memoryCaliber`(`PerformanceSystemTiles.body` NoteLine) | 「口径 = 总量 −（空闲 + 推测 + 可清除），与活动监视器一致；这是「在用」，不是「剩余可用」。」44 | 留短藏长 ● |
| `PerformanceSystemTiles.diskTile`/`networkTile` caption | 「首个差分帧到达前，不给速率」13（同串两落点） | 留短藏长 ● |
| `PerformanceSystemTiles.cpuCaption` | 「负载 L · 差分帧未到，占用率暂不给出」17 | 留短藏长 ● |
| `PerformanceLiveCharts.axisNotes`(轴口径) | 「横轴：距今秒数（窗口不足 60 秒，时钟读数没有区分度）／每 N 秒一格。纵轴：CPU …%、内存 …%。带下限的轴是为看清走势而收窄的，不是 0 起点。」≈70 | 留短藏长 ● |
| `PerformanceLiveCharts.axisNotes`(剔除计数) | 「内存曲线已剔除 N 个无证据读数（引擎给出压力档 unknown 或字节数为 0）。」33 | 留短藏长 ● |
| `PerformanceLiveCharts.cpuBasis` | 「分子/分母：正在使用的核数 / %@ 核，100%% = 全部核心跑满」26 | 留短藏长 ● |
| `PerformanceLiveCharts.memoryBasis` | 「分子/分母：已用 %1$@ / 总量 %2$@」14 | 留短藏长 ● |
| `PerformanceLiveCharts.memoryBlock`(NoteLine) | 「本窗口没有足够的可信内存读数可画曲线（%1$@/%2$@ 点可用）。」25 | 留短藏长 ● |
| `PerformanceLiveCharts.body`(空态) | 「至少 3 个点之后才有曲线可画。这里不预先给出估算形状。」25 | 留短藏长 |
| `PerformanceProcessGroupsCard.body`(subtitle) | 「按匹配模式在全系统进程里查找，与所选项目无关」21 | 留短藏长 ● |
| `PerformanceProcessGroupsCard.coverageFootnote` | 「命中数为 0 只说明「这一帧没有匹配的进程」，不说明服务出了问题。」+「本轮取线程 / 句柄的时间预算已用完，覆盖度见各卡里的 N/M。」30+26 | 留短藏长 ● |
| `PerformanceGroupCard.body` | 「匹配模式 %1$@ · 对进程名与命令行做包含匹配」20 | 留短藏长 ● |
| `PerformanceGroupCard.copy(for:)` | 3 态 ×（message + nextStep）共 6 键，最长「暂停期间不再查找进程，这里显示的是最后一次采集的结果：全系统 N 个进程里没有命中「X」。」≈55；每卡常驻 ≈85–95 字 | 留短藏长 ● |
| `PerformanceGroupCard.cpuCell` caption | 「差分帧未到，不给百分比」11 | 留短藏长 ● |
| `PerformanceGroupCard.threadsCell`/`openFilesCell` | 「全部成员进程的 task_info 都没返回线程数」「本轮取句柄的时间预算已用完，一个都没读到」「全部成员进程的句柄数都未取到」3 支 18–21 + 「N/M 个进程取到」 | 留短藏长 ● |
| `PerformanceProcessTableCard.coverageNote` | 「已取指标 A / 全系统 B 个进程 · 只读」+「 · 句柄列受时间预算限制」／兜底「只读展示，不提供任何进程操作」18+12/14 | 留短藏长 ● |
| `PerformanceProcessTableCard.honestyLegend` | 「线程 / 打开文件显示 -- 表示本轮未取到（内核任务或时间预算已截断），不表示数量为 0。」2 支 ≈40 | 留短藏长 ● |
| `PerformanceProcessTableCard.table`(NoteLine) | 「已按当前排序列出前 N 项，另有 M 个进程未列出。」22 | 留短藏长 ● |
| `PerformanceProcessTableCard.body`(空态) | 「完成一次采样后会列出占用最高的进程（PID、名称、CPU 核当量、内存、线程、打开文件）。」40 | 藏（预告，等于没说） |
| `PerformanceMatcherEditor.body`(NoteLine) | 「匹配模式对进程名与命令行做包含匹配，例如 java、nginx、mysqld。规则本身不改变任何进程。」42 | 留短藏长 ● |
| `PerformanceMatcherEditor.body`(subtitle) | 「新增分组规则（只读观测，不干预任何进程）」18 | 删（与上一行后半逐字同义） |

## G 错误日志 — 12

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `LogsView.banners`(无报告) | 「该项目还没有日志分析结果。选择项目目录后点「重新分析」，或手动附加本地日志文件。」38 | 留短藏长 |
| `LogsView.banners`(无可解析文件) | 「项目目录与 ~/Library/Logs 里都没有找到可解析的日志文件。用「附加日志」手动选择 error.log、crash.log 后重新分析。」55 | 留短藏长 ● |
| `LogsView.rescanForNewWindow`/`clearAttachedFiles` | 「改窗口后需重新分析。」／「清空附加文件后需重新分析。」2 支 10/13 | 藏 |
| `LogsMetricGrid.subtitle` | 3 支「尚未分析，下方数值一律 --」12／「没有可读的日志文件，下方数值一律 --」+ 跳过段／「扫描 N 行 · M 个文件」 | 留短藏长 ● |
| `LogsMetricGrid.skippedNote` | 「 · 已跳过 N 份读取失败（权限不足 ×2、文件已不存在 ×1）」25 | 留短藏长 ● |
| `LogsMetricGrid.body`(NoteLine) | 「今日错误按代码规模归一为每千行 X 次；分母来自同一次扫描的有效代码行。」33 | 留短藏长 ● |
| `LogsMetricGrid.todayCaption` | 「错误 + 异常 + 崩溃，按代码规模归一见下」18 | 删（与上一行同卡同义） |
| `LogsMetricGrid` caption「未发现日志文件」「尚未分析」 | 短态词 | 留短藏长 ● |
| `LogsErrorClustersCard.subtitle` | 「共 N 类签名 · 按出现次数排序」14 | 藏 |
| `LogsErrorClustersCard.emptyState` | 3 支 24/12/28 | 留短藏长 ● |
| `LogsTrendCard.footnote` | 「柱状为错误 / 异常 / 崩溃按天堆叠，折线为警告数（与柱状共用纵轴）。纵轴 0…N 条，按 {1,2,2.5,5}×10ⁿ 台阶取轴。」≈55 | 留短藏长 ● |
| `LogsTrendCard`(SectionEmptyNote 未分析支) | 「尚未分析，点「重新分析」后这里按天展示错误、异常与崩溃的分布。」29 | 删（页顶横幅已逐字说过） |
| `LogsTrendCard`(SectionEmptyNote 无时间戳支) | 「暂无趋势数据：日志行里没有可解析的时间戳时无法按天分桶，这里不画空柱。」34 | 留短藏长 ● |
| `LogsAffectedFilesCard.subtitle` | 「按错误出现次数取前 N 项 · 条形与百分比同为「占全部出现次数」的比重」30 | 留短藏长 ● |
| `LogsScannedFilesCard.table`(NoteLine) | 「另有 N 个文件未列出。」11 | 留短藏长 ● |

## H 依赖分析 — 15

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `DependenciesView.body`(无清单空态) | 「扫描完成，但没有找到 package.json、Package.swift、pom.xml、go.mod 等清单文件。\n如果依赖声明在自定义脚本里，这一页为空是真实结果。」68 | 留短藏长 ● |
| `DependenciesView.body`(未分析空态) | 「该项目还没有依赖分析结果。点击「重新分析」开始扫描。\n需要最新版本与漏洞库在线核对时，先打开上方的联网开关。」52 | 留短藏长 |
| `NetworkOptionsCard.body`(subtitle) | 「联网核对会显著变慢，离线时仍会用内置快照」19 | 留短藏长 ● |
| `NetworkOptionsCard.statusCaption` | 「开启后需要重新执行分析才会生效。」／「当前为离线模式，版本与漏洞结论来自内置快照。」2 支 16/21 | 留短藏长 ● |
| `DependencySummaryGrid.body`(hero note) | 「清单直接声明，不含锁文件解析出的传递依赖」20 | 留短藏长 ● |
| `DependencySummaryGrid`(生态 caption) | 「清单来源，名单在上方「风险总览」」15 | 藏 |
| `DependencySummaryGrid`(运行时/开发 caption) | 「开发依赖不随产物发布」10 | 留短藏长 ● |
| `DependencySummaryGrid.outdatedCaption` | 「已比对版本数据，未发现落后项」／「没有可判定的依赖」／「占依赖总数 X%」3 支 13/8/10 | 留短藏长 ● |
| `DependencySafetyVerdict.tileCaption` | 3 支「命中详情见下方「安全公告」」等 12–18 | 留短藏长 ● |
| `DependencySafetyVerdict.summaryCaption` | 4 支 25–75（`.unchecked` 拼三段：「未联网核对，仅内置快照（覆盖 npm / Maven / Python），%@ · %@ / %@ 项有版本数据 · 未覆盖生态：%@」） | 删（当前已在 `.help`，且 `DependencyVerdictRows` 注释声称的「风险总览口径条逐字写着」经核不实——上屏那份是 `deps.networkLookupNote`，见 H14） |
| `DependenciesView.riskSlot` .help ＋ `DependencyVerdictRows.SafetyVerdictBadge` .help | 「默认不联网时漏洞判定恒为 0 条，这是「没有查」，不是「没有病」」30 × 2 处逐字重复 | 删一处（收成一处常量） |
| `DependencyEcosystemSection.body`(锁文件 value) | 「（只说明可复现，未计入依赖数）」14 | 留短藏长 ● |
| `DependencyTable.body`(DataCaption) | 「该清单没有解析出可枚举的依赖项。」15 | 留短藏长 ● |
| `DependencyTable.countNote` | 「当前展示 X / Y 项 · 按名称排序。」／「共 N 项，已全部展示。」16/12 | 留短藏长 ● |
| `DependencyAdvisoriesSection.subtitle` | 「内置快照与安全公告均未命中」13／「共 N 条 · 影响 M 个依赖」13 | 留短藏长 ● |
| `DependencyAdvisoriesSection.emptyCaption` | 「本次未联网核对，0 条命中只是「没有查」，不是「没有病」。」26／「已完成核对，未发现已知漏洞。」14／「有命中，见上方列表。」11 | 留短藏长 ● |
| `DependencyOverviewSection.body`(DataNotice ← `deps.networkLookupNote`) | 长 40–110，**文案产自 `Services/Dependencies/ManifestDependencyAnalyzer.offlineCaveat` 与 `DependencyNetworkLookup`，不在 `Views/**`** | 留短藏长 ●（本轮实现碰不到，见 Y 节契约缺口） |

## I 健康评分 — 18

| 符号 | 原文（≈字） | 判 |
|---|---|---|
| `HeuristicClaimLine.claim` | 「启发式加权计算，未调用外部模型」15 | 留短藏长 ●（**现状即目标形态样板：短句上屏 + 长句进 `.help`**） |
| `HealthHero.body`(subtitle) | 「%1$@/%2$@ 个维度参与计分」12 | 留短藏长 ● |
| `HealthHero.narrativeColumn` | 「本次评分没有附带文字结论。」12 | 藏 |
| `HealthHero.narrativeColumn`(BannerRow) | 「上游把这条评分标记为外部模型产物，与本页口径不一致：Tcoder 只做本机启发式加权计算，不调用外部模型。请重新分析后再看。」55 | 留短藏长 ● |
| `HealthNotScoredCard.body`(空态) | 「选择项目目录后点「重新分析」，会综合代码规模、复杂度、重复代码率、Git 活跃度、运行日志与依赖状况给出 0~100 分。」52 | 留短藏长 |
| `HealthNoInputCard.body`(主句) | 「本次没有任何维度输入，因此不给综合分。」18 | 留短藏长 ● |
| `HealthNoInputCard.body`(解释句) | 「这里刻意不画一个 0 分红环：0 分会被读成「这个项目很差」，而事实是「没有可算的数据」。」43 | 藏（设计理由，环里已给 `--`） |
| `HealthCodeScopeReadout.membershipLine` | 「计入 %@（与综合分同一批分量）」20／「计入 %1$@；不含 %2$@」28 | 留短藏长 ● |
| `HealthCodeScopeReadout`(help ← `scope.note`) | 产自 `Services/Health/WeightedHealthScorer.codeScopeNote`，2 支 24/35 | 排除本轮（已在 tooltip，但**键在 Services**） |
| `HealthComponentTable.body`(subtitle) | 「综合分 = Σ（得分 × 归一化权重） · 按拖累程度排序，贡献最低者在前」30 | 留短藏长 ●（前半与 `HeuristicClaimLine` 的 help 重复） |
| `HealthComponentTable.rowView`(详情列 ← `row.component.detail`) | 产自 Services，常驻 2 行 | 标注：非 Views 文案 |
| `HealthBreakdown.normalizationSummary`(NoteLine) | 2 支 ≈45/70「缺失 N 个维度不参与计分、也不按 0 计入，其份额已按在场维度等比摊入。（…折算说明…）」「输入覆盖全部 N 个可计分维度，没有维度缺席；但内置权重表合计 110%…」+ 追加句「测试覆盖只在项目真的产出了覆盖率报告时参与计分。」22 | 留短藏长 ● |
| `HealthComponentTable.body`(NoteLine) | 「分量合计 X 与综合分 Y 有出入，通常是评分器的归一化或取整口径不同。」30 | 留短藏长 ● |
| `MissingDimensionReason.text` | 约 10 支 12–24（「该项目没有产出覆盖率报告，不参与计分。」「上次扫描「代码扫描」失败，本维度没有输入。」「尚未分析日志。」…） | 留短藏长 ● |
| `HealthAdviceGrid` 三卡 subtitle | 「本次评分里做得好的地方」／「拉低综合分的地方」／「由上面的数字按规则派生」3 支 11/9/11 | 删（前两支是把卡名「优点」「问题」换个说法再讲一遍；第三支可藏） |
| `HealthAdviceGrid` emptyNote | 3 支 13/13/18「已完成计算，未识别到突出项。」… | 留短藏长 ● |
| `HealthTrendCard.subtitle` | 「共 N 个历史点 · 全部来自本机落盘的评分记录」20 | 留短藏长 ● |
| `HealthTrendCard.body`(NoteLine) | 「纵轴固定 0…100 分，B 级参考线 70 分；折线只连已有历史点，不做任何外推。」35 | 留短藏长 ● |
| `HealthTrendCard.consistencyNote` | 「历史末点 X 与本次 Y 不一致：可能是旧记录，或本次评分尚未落盘。」30 | 留短藏长 ● |
| `HealthTrendCard.body`(空态) | 「至少完成两次分析后可以看到趋势。少于两个点时这里不画线。」27 | 留短藏长 |

## Z 承担诚实性告知、**不得整条藏**的条目（89 条，按类归并）

判据：**这条一旦只有 hover 才看得见，用户就会把一个"没查 / 算不出 / 窗口内 / 未核对"读成一个真实的 0 或一个结论。**

- **缺数据 ≠ 0**：`DataAbsence` 四态字面与 `help`（样板，别动）｜`LogsMetricGrid.subtitle`「下方数值一律 --」｜
  `LogsMetricGrid.skippedNote`（跳过原因分布）｜`PerformanceSystemTiles`「首个差分帧到达前，不给速率」｜
  `PerformanceGroupCard.cpuCell/coverageCaption`「差分帧未到，不给百分比」「全部成员进程的 task_info 都没返回线程数」｜
  `PerformanceProcessTableCard.honestyLegend`（-- 不等于 0）｜`LiveReadings.memoryGapReason` 三因｜
  `CodeMetricsSummaryGrid.shareOf` / `CodeScaleSection.averageFileLines`（算不出 vs 没扫）。
- **口径 / 分母必须讲**：`GitHistoryScope.headline`·`totalTileCaption`·`authorTileCaption`·`windowSuffix`
  （统计基于非合并提交、近 N 次窗口、旧报告未记录口径）｜`GitCommitScopeSection.message` 追加句｜
  `GitActivitySection.busiestCaption`（未做时区归一）｜`GitActivitySection.subtitle` + `GitActivityHeatmap`（近似强度）｜
  `DependencySummaryGrid.heroNote`（不含传递依赖）｜`DependencySafetyVerdict.tileCaption/summaryCaption` +
  `DependencyAdvisoriesSection.emptyCaption` + `riskSlot.help`（没查 ≠ 没病）｜`NetworkOptionsCard.statusCaption`
  （结论来自内置快照）｜`DashboardView.coverageCaliberLine` 三支（含测试代码不用于评分）｜
  `LogsMetricGrid` 归一 NoteLine + `LogsAffectedFilesCard.subtitle`｜`PerformanceLiveCharts.cpuBasis/memoryBasis`
  （分子/分母）｜`SystemReadings.memoryCaliber`（在用 ≠ 剩余可用）｜`PerformanceSystemTiles.sectionSubtitle`（与活动监视器同口径）。
- **分数必须讲得出依据**：`HeuristicClaimLine`（启发式、未调用外部模型）｜`HealthHero.narrativeColumn` BannerRow｜
  `HealthComponentTable` subtitle/`normalizationSummary`/`weightTooltip`/`weightColumnHelp`/合计对不上 NoteLine｜
  `MissingDimensionReason.text`（缺证据不计分的原因）｜`HealthNoInputCard` 主句｜
  `HealthTrendCard.subtitle`/轴 NoteLine/consistencyNote｜`HealthCodeScopeReadout.membershipLine`。
- **轴 / 窗口不能骗人**：`PerformanceLiveCharts.axisNotes` 两支（非 0 起点、剔除点数）。
- **规则降级要认账**：`CodeInvariantRow` 规则降级句 + 不变式差值句。
- **只读承诺**：`PerformanceView.header`、`PerformanceProcessTableCard.coverageNote`、`PerformanceMatcherEditor` NoteLine、
  `PerformanceProcessGroupsCard.subtitle`（与所选项目无关）。

## Y 承载方式与三个前置缺口

**已有的正确形态（照抄，不要另造）**：`HeuristicClaimLine`（短主句 + `.help(长句)`）、
`DataTableHeader` 经 `DataGridColumn.help` → `DataOptionalHelp` 挂 `.help`、`DataAbsence.help(denominator:)`、
`DependencyRowStatus.tooltip`、`HealthBreakdown.weightTooltip`。图标侧已有 `IconName.unverified = "questionmark.circle"`
（`Design/IconTokens.swift`）与 `ThemedIcon(_:role:label:)`，**但全站没有一处"帮助图标 + tooltip"的共用组件** ——
现在所有 tooltip 都匿名挂在数字/徽标上，鼠标必须猜哪里可 hover。

**建议新增组件**：`CopyHelpBadge(_ text: String, label: String? = nil)`，落 `Design/SharedComponents.swift`
（与 `MetricTile`/`EmptyStateView` 同宿主，受 400 行线约束，必要时新开 `Design/CopyHelp.swift`）。
形状：`ThemedIcon(.unverified, role: .badge)` + `.help(localizedCopy(text))` + `.accessibilityLabel`，
颜色只取 `Theme.Semantic.neutral.textColor`，字号走 `.typed(Theme.Typo.microLabel)`；
页面侧零 `#available`、零散写材质（AGENTS §3 横切约束 1）。

**实现前必须先修的三个缺口**：

1. **27 处上屏点不过本地化表**：`DataFootnote`、`DataCaption`（`Views/CodeGit/CodeGitDesignKit.swift`）
   与 `NoteLine`（`Views/PerfLogs/NumberText.swift`）都是 `Text(text)` 直出，**不调 `localizedCopy`**
   （`DataFootnote` 8 处 / `DataCaption` 4 处 / `NoteLine` 15 处）。往 `Localizable.strings` 塞这些键**不会有任何效果**
   （`LocalizedCopyKit` 顶部 §7.1 就是讲这件事）。→ 不先修这条，ⓘ 收纳会把 27 处中文永久钉死在英文态。
2. **最重的几条口径文案不在 `Views/**`**：`ManifestDependencyAnalyzer.offlineCaveat`、
   `WeightedHealthScorer.codeScopeNote`、`ShellGitPureHelpers.attemptedLocationsText`、`HealthScore.narrative` /
   `ScoreComponent.detail`。按 AGENTS §3 这三处属冻结/他人所有，页面流无权搬 → 需总工拍板谁来搬。
3. `MetricTile.caption` 被 `TileCaptionLayout.reserveLines = 2` 钉死两行、且注释明写"口径脚注不许截断" ——
   把长口径塞进 caption 槽会撑歪读数带（`GitInsightsMetricGrid` 已用 `captionLineLimit: 2` 处理过一次）。
   **这正是需要 `CopyHelpBadge` 而不是继续往 caption 里加字的原因。**
