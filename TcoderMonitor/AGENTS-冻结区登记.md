# 冻结区 additive／删除登记表（从 `AGENTS.md` §3 整块搬出）

> **为什么单独一份**：`AGENTS.md` 是并行开发的权威规约，它逼近全仓 800 行上限
> （`SelfScanDogfoodTests` 的巨型文件棘轮，ceiling = 0 个新增超限文件）。
> 这张表是**只追加的历史**，每一轮冻结区改动都要多一行 —— 它和"规矩"住在一起就会先把规约文件撑爆。
> 2026-09-25 由总工搬出：规矩留在 `AGENTS.md` §3，历史搬到这里，**内容一字未改、整块搬走**。
> 本文件**不在**判活尺子 `DocReferenceRatchetTests` 那 11 份扫描面里（`AGENTS.md` 本身也不在），
> 所以表里的符号要靠**写的时候当场核**（AGENTS §8 第 5 条：工单点名的符号必须 `Read` 到并贴原文）。

> **用法**：新登记一行就照下面这张表的四列写（冻结文件 / 加了什么 / 为什么不能在别的文件里 / 自带守卫）；
> 删成员同样要留名并说清"为什么它不是被搬走了"。
> **没在这张表里的冻结区改动一律视为越界** —— 这句判据留在 `AGENTS.md`，这里只是账。

### 冻结区 additive 变更登记（第三轮 · P6-Q / P7-D，总工本人）

22:40 单人接管后，「冻结区缺口由总工处理」这句的执行者就是本流自己。为避免它变成
"总工想改就改"，这里逐条登记本轮动过的冻结文件，并给自己立两条判据：**只加不改**
（不改动任何既有取义与既有成员）、**新增的东西必须自带守卫**（否则下一轮长回去没人知道）。

| 冻结文件 | 加了什么 | 为什么不能在别的文件里 | 自带守卫 |
|---|---|---|---|
| `Utilities/SharedUtilities.swift` | `DateFormat.day`（日期档格式化器，`full` 一字未动） | `PerfHitchGuardTests` 的 `directFormatters` 现量 1 / 上限 1，把 `DateFormatter()` 挪进 `Views/**` 当场红；格式化器必须住在扫描面之外的共用层 | `DesignAbsenceStateTests` 钉「读数格走 day 且正好 10 字符」 |
| `Models/CodeMetrics.swift` | `scanLimitations: [String]?`（一个字段，其余一字未动） | WS-A 在 `FileSystemCodeAnalyzer` 里把"哪些上限真的生效过"算好了却无处安放，注释点名"交给总工决定接入点"——这就是那个接入点的另一半。**必须是 Optional**：非 Optional 带默认值会让旧报告整份解码失败 | `FunctionalHonestyGuardTests` G9（写/读两头都在）+ `CodeAnalyzerPrecisionTests` 行为两向（截断→非空、未截断→nil）|
| `Models/CoverageMetrics.swift` | `unreadableDirectoryCount: Int?`（其余一字未动） | 目录枚举失败被 `try?` 吞掉时，"没看到"会在界面上长成"该项目没有产出覆盖率报告"。这一格要把"扫描面不完整"随报告一起落盘，只能住在契约里 | `CoverageAnalyzerTests` 两向（挡住一个目录→计数 ≥1 且结论补一句"没看完"；一个都没挡住→必须写 0，不许留 nil） |
| `Design/SharedComponents.swift` | `MetricTile` 的自定义 `init` 补一个 `captionHelp: String? = nil` 形参（插在 `caption:` 之后，带默认值） | 属性与渲染 main 早就开好了，**只有 init 不收这个参数 ⇒ 调用点传不进去**；「留短藏长」的格子没有别的挂载点，而 42 处现有调用点靠默认值一字不改 | `TooltipMigrationGuardTests+HelpSlots`（新标签必须进 A/B 两本账）+ S7 的 `ShellReadoutTooltipTests`（三格 captionHelp 只指既有真值生产者，不许重抄中文） |
| `Models/ScanProvenance.swift`（**新文件**） | 报告溯源块：`schemaVersion` / `toolVersion` / `rulesVersion` / `producedBy` / `scannedRoot` / `resolvedGitRoot` / `sourceCommit` / `sourceBranch` / `workingTreeDirty` / `dirtyEntryCount` / `dirtyProbeNote`，**11 个字段全 Optional** | "这份报告是哪个提交、哪一版工具、哪一版判据产的"必须随报告一起落盘；放别处就没有第二份产物能带着它走 | `ScanProvenanceTests` 17 例（含 4 条反例：没量到不得渲染成干净、缺席值打「未记录」、仓库根相等时不许造假提示、非零退出要带原因）+ 真子进程三情形对独立真值 + sabotage 3 红 |
| `Models/Project.swift` | `ProjectReport` 加 `var provenance: ScanProvenance? = nil`（其余一字未动） | 溯源块必须挂在唯一那份 schema 上（§5.9 第 2 条：不存在第二个 DTO）；**必须 Optional**，否则旧 JSON 整份解码失败 | `testReportWithoutProvenanceKeyStillDecodes`（把键删掉再解）+ `testProvenanceRoundTripKeepsEveryField` |
| `Models/GitInsights.swift` | 加 `workingTreeDirty: Bool?` / `dirtyEntryCount: Int?` / `dirtyProbeNote: String`（既有成员一字未动） | 工作区状态只有 Git 那一路量得到：`ShellGitAnalyzer` 已经在同一次分析里起进程，**再开第二个 git 进程就是第二把尺子**（一处看仓库根、一处看用户选的子目录，今天真踩过） | `ShellGitAnalyzer.workingTree(from:)` 三态 + `testStatusProbeDistinguishesCleanDirtyAndUnmeasured` 四分支 |
| `App/AppState.swift` | 扫描收尾处加 **1 行**：`merged.provenance = ScanProvenance(…producedBy: "gui")` | 装配点只有两个（GUI 与 CLI），少一个就产出一半"无溯源"的报告，而 `producedBy` 正是 CLI↔GUI 对表要用的那格 | `testProvenanceHasBothWritersAndReaders`（**两个写者点名相等**，且必须有读者） |
| `Services/CLI/CLIOutput.swift` | `buildConfiguration` / `bundleIdentity` 改成**转发**到 `ScanProvenance`，输出逐字未变 | 同一件事不许有两把尺子：`--version` 与报告溯源必须给同一个串 | `testCLIIdentityAndProvenanceShareOneRuler` |
| `Models/HealthScore.swift` | `HealthDimension` 加 **1 个静态成员** `repositoryScoped`（既有成员一字未动） | "哪几维的输入是按仓库/项目身份定位的"这件事，两个生产者（`ShellGitAnalyzer` 向上找 `.git`、`LogProjectIdentity.resolve` 取锚点）各算各的，只有契约里放得下这份汇总；放文案里就是手写第二份名单，加第四个成员时句子会静默漏报 | `test_repositoryScopedMatchesTheInputsThatFeedIt`（钉**生产者**：单独喂 Git/日志/代码/依赖四路，落进与落不出必须各自成立；已在真源码上破坏验证——把 `dependencies` 塞进名单判两条红）+ `test_relocationNoticeNamesExactlyRepositoryScopedDimensions` |
| `Models/ScanProvenance.swift` | 加 `CommitIdentity`（缩短宽度 12 + `abbreviated`），既有成员一字未动 | 提交号原先有**两把尺子**：Git 那一路 `rev-parse --short=7` 存 7 位、覆盖率那一路自己 `prefix(12)`，同一份报告三格说两样话。缩短只能发生在唯一装配口 `ShellGitPureHelpers.makeInsights` | `CommitIdentityRulerTests`（尺子 2 例 + 「只有两个调用点」+ `--short` 不许回来）+ 对表用例 `testCoverageFingerprintAndProvenanceCommitShareOneRuler`；sabotage 摘掉装配口缩短 ⇒ 5 红 |
| `Models/AnalyzerLedger.swift`（**新文件**） | 四态台账 `AnalyzerRunState` / `AnalyzerRunRecord` / `AnalyzerAttempt` + 唯一装配助手 `timed` / `records` + 五路路名唯一一份 `sectionLabels` | 用户 §十一：每路的状态·耗时·上限·失败原因要问得出来；`notRun` / `failed` / `partial` / `ok` 是四件不同的事，原先报告里只有「挂掉的路名」一种表达 | `AnalyzerLedgerTests` 8 例（含真跑一次无头装配填满五代、四态各不混淆）+ 两处写者点名各 1 次；sabotage（partial 判成 ok + 摘掉 GUI 写者）⇒ 8 例里 4 红 |
| `Models/Project.swift` | `ProjectReport` 加 `var analyzerLedger: [AnalyzerRunRecord]? = nil`（其余一字未动） | 台账必须挂在唯一那份 schema 上；**必须 Optional**，否则旧报告整份解码失败，而空数组会被读成「五路都没跑」 | `testReportWithoutLedgerKeyStillDecodesAsNil`（断言键真的缺席）+ `testLedgerRoundTripKeepsEveryField` |
| `App/AppState.swift` | 五路改走 `AnalyzerLedger.timed`、收尾加 1 行台账；**删掉**自己那份 `attempt<T>` 助手（有删，理由写在这里） | 那份助手与 `CLIScan.attempt` 是「同一件事两个入口」（RD-38 同族），且它手打的路名与 `sectionFailures` 那五行不一致——同一次失败在界面叫「日志分析」、在报告里叫「错误日志」 | `SectionLabelGuardTests` 两条（AppState 一个路名字面量都不许有 + 命名位不许传字面量）各配元测试；`AnalyzerLedgerTests.testBothAssemblyPointsWriteTheLedger` |
| `Models/CodeMetrics.swift` | 加 5 枚 Optional：`duplicatedBlockLimit` / `duplicatedBlocksDroppedByCap` / `duplicatedLinesOutsideReportedBlocks` / `duplicateFragmentsNotExpandedCount` / `duplicateFilesHittingLineCap`（既有成员一字未动；**故意不给「总块数」**） | 引擎早就算好这四个数，但契约里没有承接格 ⇒ 它们只活在 `scanLimitations` 那句中文里，界面按句式认领句子、读 JSON 的人只能解析散文。不给总数是因为 `rankedBlocks` 撞 id 削掉的块无读数，「榜内 + 榜外 == 总数」天然不平 | `DuplicateBoardAccountingTests` 6 例（真扫本仓对账「字段 == 台账句里的数」：榜内 20 · 榜外 85 块 / 584 行 · 未展开 225 处；含「不许把两者相加当总数」的结构守卫）；sabotage 摘两枚字段 ⇒ 2 红 |
| `Models/LogInsights.swift` | 加 2 枚 Optional：`crashReportCount`（读到几份崩溃报告）/ `crashReportLineCount`（被移出密度分母的正文行数），既有成员一字未动 | RD-46b 把崩溃正文从 `totalLinesScanned` 摘出去之后，那些行只活在内部类型 `LogAggregate` 里；不落成字段，"移出分母"就和"消失"在盘上无法区分，而 RD-49 的输入（有崩溃证据、零真日志行）在报告里也就数不出来。**故意没开**两格：`crashReportDirectoryReadable`（要把"目录读不动"与"目录里没有"分开，得先给 `LogDiscovery` 加枚举失败读数 = 新能力，同形边界已写在 `LogDenominatorStatesTests` 文件头）、`unattributedCrashReportCount`（数的是**别人项目**的报告，属整机面不是项目面；"自己的报告没产出可用事件"那件事由 `stabilityEvidenceGaps` 已经在说） | `LogDenominatorAccountingTests` 5 例（真值取自盘上 `0x0A` 计数、含对账等式 `分母 + 崩溃正文 == 盘上读到的总行数`、旧 JSON 缺键 ⇒ `nil`、写者集合恰好是 `FileLogAnalyzer.swift` 一条 + 其元测试）；R11 侧另有 `LogDenominatorTests` 9 例与 sabotage（摘掉 role 分流 ⇒ 6 红） |
| `Views/DashboardView.swift` | hero 那条最近提交标题 `Text(commit.subject)` 补 **1 个修饰符** `.help(commit.subject)`（既有布局、字号、取义一字未动） | 被裁的是**这一格自己的**文本，去处必须挂在同一个元素上 —— `ax_frames` 第 9 列量的就是"这一格挂没挂 help"，挂到邻居身上等于给尺子造假信号。Git 页提交榜（`Views/Git/**`，非冻结）同批补上，画法与侧栏项目名一致 | `scripts/ax_truncation_sweep.sh` 的主门（装不下**且无 help** 才 exit 1）+ 夹具那一格的**分档自证**（它必须落在"有 help"档，落进主门即第 9 列没读到 ⇒ 当场判不成立） |
| `Views/DashboardView.swift` | **第二处，同上形状**：`ErrorClusterRow` 里那条崩溃标题也补 `.help(cluster.displayMessage)`（窄态 1080 实测格宽 557pt / 单行需 624pt） | 同一把尺子在窄态那一档量出来的同类缺陷：错误日志页的同类格子早就挂了 help，总览榜上这条没有 ⇒ 被裁掉的半个崩溃标题在全站任何地方都读不到 | 同上，走 `ax_truncation_sweep.sh` 窄态那趟的主门 |
| `Models/CodeMetrics.swift` | 再加 **1 枚** Optional：`nonCodeRegionLineCount`（混合语言文件里按分区归位为非代码、未进代码统计的行数），既有成员一字未动 | RD-42「有写无读」：`ComplexitySanitizer` 从 R2 起就在算这枚数（逐行累加 + `merged` 跨区累加），全仓零读者 ⇒ "分区认出来了、N 行归位"一件没说，而"分区**没**认出来"倒另有一格在出声（`vueRegionFallbackFileCount`）。**这一格是口径不是"未量准"**，所以故意**不进** `scanLimitations`（那条在 CLI 被打成「未量准 N 条」，塞进来等于把那个数灌虚高） | `NonCodeRegionReadoutTests` 10 例：正例真值取自测试自己手写的 `.vue` 夹具（template 12 + style 8 + SFC 标签 6 ⇒ 26，先自证数对了再断言）、反例钉「这句不许进限制账」+ 对账等式、未知态（认不出分区的文件一行都不算已归位）、缺席（纯 Swift 语料整句不出声 + 旧 JSON 缺键 ⇒ `nil`）、写者恰一处与读者两出口的扫描守卫各配元测试；sabotage 一次 ⇒ 9 红 |
| `Models/CodeMetrics.swift` | 再加 **1 枚** Optional：`duplicateBlockCoordinatesOutsideBoard`（榜外块的可点名坐标样本，直传引擎那份），既有成员一字未动 | RD-52：这些 id 原先只在 `scanLimitations` 的中文句里，而且**同一串在一份报告里印两遍**（口径句 + 扫描边界句），单条实测 2,407 字符；读 JSON 的人要定位「到底是哪几块」仍得解析散文 —— RD-48 刚消灭过的形状在坐标这格复活。⚠️ 我最初记成「全量坐标被静默截断」，复核后不对：引擎本来就只点 `outsideBoardSampleLimit` 条、未点名块数在 `droppedByCap` 里，所以修法是**散文点 3 条 + 指回字段与计数、字段给引擎那 6 条一条不减** | `OutsideBoardCoordinatesTests` 4 例（真扫本仓对账「字段在、样本数不超过引擎那把尺子、同一串只出现一次、最长限制说明 <1,200 字符」+ 装配口正例/余数反例 + 缺键 ⇒ `nil` + 抄回边界句的 sabotage ⇒ 2 红）
| `Models/CodeMetrics.swift` | 再加**一族**：`CodeFileRoleShare` / `CodeFileRoles` 两个类型 + `var fileRoles: CodeFileRoles? = nil`（既有成员一字未动；八档**全量列出含 0**，缺档 = 没量到，`weakEvidenceFiles` 只挂 `production` 档、其余档给 `nil` 而不是 0） | RD-14/RD-20 后半第一步：角色分档此前**只是文本**（判据 `SourceFileRoleRule.decide` 与累计 `SourceRoleTally` 早就有，但没有落盘承接格）⇒ 读 JSON 的人拿不到"生产码有多少行"、评分侧也没有按角色收窄的分母。只有挂在 `CodeMetrics` 上才与 `totalLines`/`codeLines` 同属一次快照（放 `CodeScanCoverage` 就停在内存里）。写者一处：`FileSystemCodeAnalyzer` 里 `SourceRoleTally` **算一次**同喂契约字段与覆盖度台账（避免同一判据两个入口） | `CodeFileRoleContractTests` 12 例 + `CodeFileRoleRealScanTests` 1 例（共 13 例；真值取自测试自己手写的 10 文件语料逐行数出来的，含"同名 `Widget` 落进四个不同档"证明不是按 basename 猜的；两条反例 + 写者/读者扫描守卫各配元测试）；sabotage 摘掉写字段那一行 ⇒ 13 例里 8 红；旧 JSON 缺键 ⇒ `nil` |
| `Models/CodeMetrics.swift` | 再加 **1 枚** Optional：`scanSurface: CodeScanScope?`（带一族新类型，逐格 Optional） | R17 算清的"排除了几个条目、被排除的那些有多少行、行数到底是数过还是没数"原先只活在 `scanLimitations` 的中文句里 ⇒ 读 JSON 的人要解析散文（与 RD-48 同形）。**"没数过"与"真的是 0"必须是两格**：`linesCounted == false` 时 `excludedLineCount` 必须 `nil`，填 0 等于把"没数"写成"没有"。上屏那一句的唯一装配口是 `CodeScanSurfaceReadout.accountingLine(_:)`（界面与 CLI 共用一把尺子） | `CodeScanSurfaceContractTests` + `CodeScanSurfaceProductPathTests`（本流 13:17 实跑合并树：8 例 0 失败）；旧 JSON 缺键 ⇒ `nil`；真产品路径用例钉"屏上那句与字段同源于同一次扫描" |
| `Models/CodeMetrics.swift` | 加 **1 个计算属性** `reportedDuplicatedBlockTotalCount`（既有成员一字未动；**取法只此一处**） | R18：评分详情那句"共 N 处重复块"吃的是 `duplicatedBlocks.count` = **榜长**（被 `maxBlocks`=20 截过的明细榜），本仓实扫榜内 20 · 榜外 96 ⇒ 少报 96 处。修法是**唯一装配口做加法**，消费方（评分解释文本 / 界面 / CLI）一律走它，谁再写一遍 `count + dropped` 就是第二把尺子。⚠️ 这一格**只许配「去重后口径」这句限定语上屏**：撞同一个 `DuplicatedBlock.id` 被削掉的块没有读数，"榜内+榜外"天然不平，不许被读成"这个仓库一共有多少处克隆" | `DuplicationTotalInScoreDetailTests`（三态各一句，第三态**断言不含「共」字**）+ `DuplicateBoardAccountingTests`（真扫对账、加法只一个家）+ `BoardLengthReadoutRatchetTests`（棘轮 1→0、全仓上限 7→6，6 = 本次实跑现量）；独立真值由测试自己走 `SourceTreeScanner → DuplicationEngine.analyze` 相加，不经装配层 |
| `Models/LogInsights.swift` | 加 **1 枚** Optional：`crashEvidence: CrashEvidenceSnapshot?`（新类型九格**全 Optional**，既有成员一字未动） | RD-60：`CrashEvidenceLedger` 把八种原因分开算好了，但 `LogAnalysisProviding.analyze` 签名冻结只回 `LogSummary` ⇒ 台账在生产路径**算完即丢**，屏上只能读那把从趋势桶倒推的粗尺（同一事实两把尺子、分母还不同）。快照必须与 `crashCount` **同源同刻**：挂 `ProjectReport` 顶层会造出第二个「崩溃数」入口（RD-38 同族），留在 Services 的内存对象送不到视图（就是修前的样子） | `CrashEvidenceContractTests` 4 例（删整键仍解得开且读成 `nil` / 九格逐字段往返 / 缺席格不许变 0 / 编码时整键缺席不写 `null`）+ `CrashEvidenceWiringTests`（含"接回来的那一格"直接断言，不许只断言拼出的句子——R24 sabotage S2 就是这么漏的）；`CrashEvidenceReadout.readingFromFields` 任一格缺席即整枚 `nil`，一个数都不重算 |

| `Views/DashboardView.swift` | 覆盖率卡片两格 `value:` 改走唯一装配口 `CoverageCategoryReadout.text(for:in:)`（该口开在 `Services/Coverage/CoverageDisplayShape.swift`，`CLIScoreText.coverageCategoryLines(_:)` 复用同一函数）；两文件**净增 0 行**，既有取义一字未动 | 「这一类到底是被标注过还是没有这一类」只有 `CoverageReportIdentity`/`kind` 那一层知道，卡片自己判就要重抄一遍分类尺子（RD-51 刚把覆盖率披露口径收成一个家，此处同形）。更狠的是原先**四处各写各的**：GUI 两格 + CLI 两句，「没标注」在屏上长成「无报告」，而那张卡只在 `coverage.hasData` 时才渲染 ⇒ 这句话在每次真实上屏里都是假的 | `CoverageCategoryAbsenceReadoutTests` 8 例：三态各一句（未标注 / 有该类报告 / 没产出该类报告）+「未标注」那句绝不出现「无报告」+ 空树仍说没有 + 真值取自测试自建 `coverage.json` 夹具 + 扫描守卫三条（只有装配口写这些句子 / 两格必须走装配口 / 注入第二份副本当场红）；R33 侧另有 4 处 sabotage 复跑；门 `1753 例 / 0 失败`、`PREMERGE-RC=0`，合流 `d467cc1` |
| `Models/ScanProvenance.swift` | 加 **2 枚** Optional：`sourceDriftDuringScan`（三态：`nil` 没量到 / `false` 两枚指纹一致 / `true` 期间变了）+ `driftNote`（量不到的原因或变更摘要），既有字段一字未动；同文件另起一族 `SourceTreeFingerprint`（条数 + 字节和 + **升序路径**的 FNV-1a 摘要，`Probe` 两态）与三个唯一装配口 `driftReading` / `driftNotice` / `recordDrift` | RD-31：一份报告要五路并行跑几十秒，期间有人 `git checkout` 或编辑器保存，落进报告的就是**来自不同时刻**的一批读数，而报告里没有任何一格这么说。它与 `workingTreeDirty` **不是一回事**（那格答"开工当时脏不脏"）。指纹只能住契约：它是 `sourceDriftDuringScan` 那格的值域，放 Services 就会被抄第二份口径；另起文件还会踩普查分母（§3 第 7 条）。**故意不读文件内容**（等长改写判不出来 ⇒ `false` 那句只说「两枚指纹一致」，绝不说「源码没变」），也**故意不起第二个 git 进程** | `ScanSourceDriftTests` 18 例（三态各一句 + 两侧任一枚没量到就整枚判未量到 + 枚举器报出错不许交出"看起来完整"的指纹 + 摘要与枚举顺序无关（RD-39 家族病）+ 措辞越界四个词逐个钉 + 旧 JSON 缺键 ⇒ `nil` + 三个出口同一句 + 两条装配点扫描守卫各配元测试）；双语 6 枚整句键（英文值只用 ASCII 标点）；`plutil -lint` OK，合流 `f367c73` |
| `App/AppState.swift` | 扫描收尾处 **+10 / −1 行（4 行是注释）**：`Task.detached` 内开工/收工各采一枚 `SourceTreeFingerprint.probe`、溯源块改成本地变量后 `recordDrift` 再挂上（`producedBy: "gui"` 那行取义未变） | 装配点只有两个（GUI 与 CLI），少一个就产出一半"无溯源"的报告（这条规矩 §3 早写过一次）。两枚指纹**必须采在 detached 里**：采在 `scan(project:)` 头部就是把一次目录遍历挪回主线程 | `ScanSourceDriftTests.testBothAssemblyPointsRecordDrift`（点名 Sources 两个写者）+ `test_meta_assemblyRulerBitesBothWays`；⚠️ 另外**测试侧还有第三个形状** `Tests/TcoderMonitorTests/GuiSideReportReplay.swift`（两条 GUI↔CLI 对表共用的重演入口），由 `GuiSideReplayEntryPointTests` 3 例钉"入口名单必须等于这一个文件且采两枚" —— 点名"两个装配点"时别把它忘掉 |

| `Models/DependencyReport.swift` | 补登记（RD-10 的两枚字段，**当时漏记 3 天**，09-24 完成度审计抓到）：`resolvedVersion: String?` + `resolvedVersionSource: String?`（§8.1 已把这一族 `DependencyVersion` 的改动放行给 R3；两枚都是 Optional） | "实际装了什么版本"只有锁文件解析那一路知道，而它必须与声明范围同挂在同一条依赖记录上，否则界面显示的仍是声明范围（用户点的"版本范围当 0"就是这一族的另一面）。写者：`ManifestDependencyAnalyzerVersionEvidence` 的锁回填；读者两处：`DependencyVerdictRows` 的「实际解析 X（来自 Y）」与 `DependencyEvidence` 的「安装版本由已解析产物给出」 | `DependencyLockResolutionTests`（8 例逐锁格式）+ `DependencyParentManagementTests` + `DependencyEvidenceTests` + `DependencyCoordinateGuardTests`；出口层由 R36 的 `DependencyExitParityTests.testLowerBoundFallbackIsDisclosedAtBothExits` 钉"降级要在两处都出声" |
| `Models/ScanRulesVersion.swift`（**新文件**）+ `Models/ScanProvenance.swift`（只删掉一行手写字面量、留指针注释） | 规则版本台账 `RulesVersion` / `rulesChangeLedger`（两格：r2 点名 RD-79 那两笔、r1 是立块基线） + 装配口 `rulesVersionStamp`（改成从台账第一格取，**不再手写**）+ 纯函数判据 `rulesLedgerDefects` 与 `rulesStampRevision`；同时抬戳 `2026.09-r1` → `2026.09-r2` | 戳号与它的含义必须是同一格数据：留在 `ScanProvenance.swift` 里就是「一行字符串 + 一段说明」两处手写，正是 RD-81 病根本体（自 `9932a19` 起从没动过，整轮 RD-01…RD-79 换判据它都还在说 r1）；另起文件是因为那文件 349 行、离 400 闸门只剩几十行 | `ScanRulesVersionLedgerTests` 9 例（分母自证＋装配口唯一＋**六条反例**各判一条原因＋解析器双向＋一条产品读者钉 `doctor` 两行）；读者两处不在测试里：报告溯源栏与 `CLI doctor`（新印「该版收进的判据」与「规则台账自检」）。射程边界写在代码注释里：挡得住「挪戳不记账／记账不挪戳」，**挡不住「改判据什么都不动」**——那一格按文件摘要上闸会在纯注释改动上误报（第 24 类：会误报的粗尺不上闸），靠评审与对表 |
| `Models/ScanRulesVersion.swift`（RD-80 抬戳） | `rulesChangeLedger` 顶部加一格 `2026.09-r3`；`rulesLedgerDefects` 加一条「最新一格点名的 RD 号要比任何旧格都新」；本文件底部新增 `extension String { func rdNumbers() }`（只认 `RD-` 前缀） | 台账与校验必须同源：判据住在 Models 这一格，别处再抄一份就会分叉；`rdNumbers` 是给校验用的私有形状，放别的文件会让台账自检跨两个文件读 | `ScanRulesVersionLedgerTests.testDefectRequiresTheHeadToNameNewerLedgerItemsThanHistory`（三格双向：抄旧条目红／正常抬格不红／没点名只报一条） |
| `Models/CodeMetrics.swift`（RD-85） | 只加一枚 `duplicatedBlocksDroppedByIdCollision: Int? = nil`（紧跟同族的 `duplicatedBlocksDroppedByCap`）；**另外改了三处注释**：原先写着「故意不给总数，因为撞 id 削掉的块没有读数」，那句话的前提被这一格消掉了，留着就是文档与代码各说一套（§3 横切约束 3.1） | 这一格是 `DuplicationScan.rankedBlocks` 第五项读数的**唯一承接位**，落在别的文件就等于「引擎算清了、契约里没有」——RD-48 那一整批的同一条病；申请单 `docs/R6-契约字段清单.md` §7 第 2 条点名要的形状就是它（Optional、只加不改） | `DuplicateIdCollisionConservationTests`（6 例：两块等长克隆⇒1、五条不同 id⇒0、榜满与撞 id 同时开火仍守恒、旧报告整键缺席、页尾只在有数时出声、榜外全零时**单靠这一格**顶起页尾）＋ `DuplicateBoardAccountingTests.testRealScanFillsTheCollisionFieldAndTheLedgerAgrees`（真扫本仓填得上，读数落 `.scratch/tcoder-idcollision.txt` 再读回比对）。**sabotage 一次有牙**：抽掉 `FileSystemCodeAnalyzer` 那行直传 ⇒ 该例单独红 `14 tests, with 1 failure`、`rc=1`（探针未提交） |

不在这张表里的冻结区改动一律视为越界。历史批次（P7-A 退役示例数据动过
`Models/Project.swift`、`Models/HealthScore.swift`、`App/AppState.swift`、
`Services/ProjectStore.swift`）是同一性质的 additive/删除，**当时没有登记**，
补记在此只是为了让下一轮看得见，不是为了追认流程无瑕疵。

**同一把尺子也管"删"**：从冻结文件删成员，同样要留名 + 说清为什么它不是被搬走了。
P7-C 收尾这一批删了两处有写无读：`ProjectStore` 的 `sortedProjects`（侧栏按插入序读，
接上去会让行在光标底下跳——**不接是判断**）、`AppState` 的 `hasProjects`
（与 `store.projects.isEmpty` 重复且零调用），外加一个空的 `Views/Shared/` 目录。
删之前查过 `git stash list` 为空、全仓无第二处同名实现，随 `sortedProjects`
一起删的是它的契约测试（判据对象已不存在）。
**还有一处删错了又恢复**：`ProjectStore` 的 `rename` —— 我按定义式 grep
（`func rename`）判它零调用，漏掉了测试里的**调用点**，而它恰恰是
「注册表与报告里的 project 必须同步」这条不变式唯一的 exerciser。已恢复并就地写明理由。
⇒ 判死代码的规矩补一条：**要 grep 名字本身，不能只 grep 定义式**；
删掉一条绿用例之前，先问它断言的不变式还有别人测吗。
（这几处刻意写成"类型 的 成员"而不是点号形式：点号会被符号锚点棘轮当成活符号去判活。）

**09-24 删了第二枚（RD-78），同一把尺子**：`Models/DependencyReport.swift` 里的
`hasVulnerabilityCoverage`。判据不是"看着没人用"，是四条自助读数：① RD-70 之后 `Sources/**` 只剩两处
**注释**在讲它的历史；② 它的本体是 `networkLookupPerformed || !advisories.isEmpty` —— 字面写着
*coverage*、实际回答"发起过没有"，**这正是 RD-11 记过的病根形状**；③ 它想说的两件事各有唯一正主
（`networkLookupPerformed` 与 `advisories`），合成一枚布尔只会再次被当覆盖度消费；
④ 退役前把它的全部引用点逐条读过（含 `FunctionalHonestyGuardTests` 与 R41 那族守卫里的**前提自证**，
两处都改成同时钉那两件分开的事实，判据强度不降）。**没删掉的**是 `DependencyEcosystemCoverageTests+ScanGuards`
里那两枚字符串标记 —— 守卫扫的是名字，属性没了、"别再把它接上屏"这条约束反而更需要留着。
顺带一条流程教训：我先用 `git grep -c … | head -5` 量引用面，被自己的截断骗过（实际还有三处），
**判"零读者"之前不许对完整性 grep 加 `head`**。

**09-24 又删了一枚，理由照同一把尺子留名**：`Models/CoverageMetrics.swift` 里逐份报告的
`CoverageReport.branchPercent`。判据不是"看着没人用"，是**四条自助读数**：`Sources`/`Tests` 全文
零命中、46 个本地分支 `git grep` 零命中、`git stash list` 只有两条与本件无关的账、屏上那句
「分支覆盖 …」读的是聚合格 `overallBranchPercent`（它先把各份的分子分母**各自相加再除**，
不是取平均）。留着它有害：那是一把从没对过表的百分比，而它算出来的东西恰恰**不该**被拿去平均——
下一个人若拿它做聚合，就造出第二个「分支覆盖率」口径。删除的那笔同时把这句理由钉在
`overallBranchPercent` 的注释上（**要新增逐份那一栏时，必须与聚合同源**，别在视图里现算第二遍）。
回归读数：`--filter Coverage` 144 例 / 3 skip / **0 失败**、`rc=0`，含 `report_parity.py rc=0` 那趟对表。
