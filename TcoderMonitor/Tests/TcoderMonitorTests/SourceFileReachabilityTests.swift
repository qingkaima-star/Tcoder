import XCTest

/// OWNER: WS-U 可达性守卫（缺陷 #45）——**"实现文件必须被引用"的机器守卫**。
///
/// 要补的洞：往 `Sources/TcoderMonitor/**` 扔一个零调用的 `.swift`，`Package.swift` 里只有
/// 一个 `executableTarget(path: "Sources/TcoderMonitor")`，它照样参与编译，全仓 58 个测试文件
/// 一声不响全绿。现有守卫都不管：`DocReferenceRatchetTests` 判「文档锚点的符号存不存在」（新增
/// 死文件反而让它更绿）、`SelfScanDogfoodTests` 只数超 800 行的文件、覆盖率类只看得见有可执行行的文件。
///
/// **判据（怎么写才算被引用）**：先用等长脱敏器剥掉注释与字符串字面量（插值 `\(...)` 里的
/// 表达式按代码保留，因为 `Text("\(Theme.Layout.x)")` 是真引用），再按**花括号深度**把声明分成
/// 「类型声明（深度 ≤ 1）」与「类型作用域成员（深度恰为 1，即 `struct`/`extension` 一级花括号内的
/// `func`/`var`/`let`/`case`/`typealias`）」。函数体里的局部量一律不当候选证据——普查时
/// 「局部变量 `arguments`/`limit`/`modifiers` 在别的文件里也叫这个名」就是这样把死文件洗活的。
/// 四条判据任一命中即算在用：
/// 1. **唯一类型名**：本文件声明的类型名全仓只有本文件声明，且在另一个实现文件里整词出现；
/// 2. **限定引用**：`Owner.member` 逐字出现在另一个实现文件里；
/// 3. **同作用域派发**：`(Owner, member)` 全仓只由本文件声明，且另一文件自己也拥有 `Owner`
///    作用域（声明或扩展了它）并整词提到该成员名——`ManifestParsers.swift` 分派到各解析分片、
///    `DependencyNetworkLookup.swift` 调 `NpmClient.swift` 里的 `performNpmLookup` 都是这形状；
/// 4. **static 简写**：`static` 成员（同样要求 `(Owner, member)` 全仓唯一声明）以 `.member` 形式
///    被使用。缺这条会把 `Notification.Name.requestAddProject`（消费方写 `for: .requestAddProject`）
///    判成死码，也就是误杀 `@main` 那个文件。
///
/// **搜索面**只有 `Sources/TcoderMonitor/**` 的其他实现文件：只有单测在用的实现文件，正是
/// AGENTS.md 明令禁止的「无调用方的实现文件」。**唯一性**在 Sources + Tests 全集上算——别人在
/// 测试里声明了同名符号时，朴素 grep 会把它当调用证据，那正是坑 3 的对称面。
final class SourceFileReachabilityTests: XCTestCase {

    // MARK: - 仓库根与扫描面

    /// 仓库根走 `#filePath` 回溯（与 `SelfScanHarness.repoRoot`、`DocReferenceRatchetTests` 同一套
    /// 写法）：本文件 → TcoderMonitorTests → Tests → TcoderMonitor（包根）。测试进程的 CWD 不是
    /// 包根，按相对路径扫会「静默扫不到东西、然后判通过」。
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let sourceDirName = "Sources/TcoderMonitor"
    static let testDirName = "Tests/TcoderMonitorTests"

    /// 普查基线：`Sources/TcoderMonitor/**` 的文件数。钉住它是为了堵死
    /// 「目录解析失效 → 分母掉到个位数 → 零死文件通过」这条永真绿路径。
    ///
    /// 108 → 109（WS-T #43 新增 Services/Health/GitCadenceEvidence.swift，
    /// 调用点 WeightedHealthScorer 的 .activity 分支）。棘轮的摩擦是有意的：
    /// 加文件必须有人先确认它凭什么被引用。
    /// 109 → 110（WS-Y #47 新增 Design/DataAbsence.swift，13 处页面调用点，未用清单未点名它）；110 → 111（性能轮 R 包新增 Services/Performance/FramePulse.swift，调用点 `AppState.init` 的 `FramePulse.shared.startIfNeeded()`，仅 `TCODER_PERF_PROBE=1` 时真正建探针）。
    /// 111 → 114（收官轮 WS-X0 新增 `Services/Health/` 三个 `extension WeightedHealthScorer` 分片：
    /// `HealthCodeDimensions` / `HealthTeamDimensions` / `HealthRuntimeDimensions`，调用点都是
    /// `WeightedHealthScorer.evaluate` 的九个 case。拆的理由是机械的：
    /// `evaluate` 单函数 CC 60、220 行，被本 App 自扫点名成全仓第一高）。
    /// 114 → 115（WS-X0 新增 Views/Code/CodeRiskAdvice.swift：`extension CodeRiskAnalysis`，
    /// 三个建议构建器被同类型的 `suggestions(for:)` 调用；拆的理由是该函数 138 行、CC 17）。
    /// 120 → 125（并入 ws/x2-runtimesvc：WS-X2/WS-X5 在 Logs / Git / Dependencies 三域
    /// 按自扫名册拆出的实现分片；引用证据见该分支 5 笔提交与本流 00:24 的合并说明）。
    /// 125 → 130（并入 ws/x6-scale：WS-X6 按自扫名册拆出的实现分片——
    /// `HealthCurveShapes`/`PerfReadoutCells`/`MachSystemMonitor+Groups` 等；
    /// 引用证据见该分支 4 笔提交，全部是既有类型的 extension 分片或被既有类型持有的类型）。
    /// 130 → 135（并入 ws/x7-views：WS-X7 拆 Design/ 与 Views/ 最后五枚 >400 行文件，
    /// 新增 `Design/ThemePalette`/`Design/ThemeMetrics`/`Design/DataRows`/
    /// `Views/Shell/SidebarRows`/`Views/Code/CodeMetricsSections`；
    /// 守卫实报「在用 134 · 未用 0 · 零调用清单：无」）。
    /// 135 → 137（WS-X8 实现文件规模闸门落地：`Design/SharedComponents.swift` 426 行、
    /// `Design/ReadoutKit.swift` 424 行各自越线，按类型整块搬出成
    /// `Design/ReadoutStripKit.swift`（`ReadoutStrip`/`DataBandSeparator`/`RiskBadge`/
    /// `SeverityBadge`/`MiniBarGauge`/`SectionEmptyNote`）与
    /// `Design/LocalizedCopyKit.swift`（`localizedCopy`/`localizedFormat`/`localizedCount`）；
    /// 守卫实报「实现文件 137 · 在用 136 · 未用 0 · 零调用清单：无」。
    /// 135 → 134（批次 P7-A：**删除** `Services/Demo/DemoData.swift`。
    /// 用户口径「不能有假数据」，那份内置示例九页数字整条退役，实现文件因此少一枚。
    /// 这是本守卫建立以来第一次分母变小 —— 方向是健康的：它只可能因为"删掉一份没人调用的实现"
    /// 或"删掉一份假数据"而下降，两者都是净收益。判据本体一条没动。）
    /// 合流两侧：135 + 2（WS-X8 两枚分片）− 1（P7-A 删掉 DemoData）= 136，
    /// 且这 136 是守卫**实报**的数（`testDenominatorMatchesCensusBaseline` 跑出来填的，不是算出来的）。
    /// 136 → 137（紧随其后还掉本门挂的那笔新账：`DependenciesView.swift` 401 行越线，
    /// 把只被它自己使用的 `NetworkOptionsCard` 搬成同目录分片 `Dependencies/NetworkOptionsCard.swift`；
    /// 守卫实报「实现文件 137 · 零调用清单：无」，`hugeFileWorkList` 里那条已删）。
    /// 137 → 141（WS-CL 无头 CLI，四枚全在 `Services/CLI/`，**2026-09-21 由总工按守卫实报填**：
    /// `CLIRouter.swift`（argv 词表 + 参数 + 退出码）由 `App/TcoderMonitorApp.init()` 直接调用 ——
    /// 命中子命令词才走它，GUI 路径一字不动；
    /// `CLIScan.swift`（五路扇出，复用 GUI 那五个分析器）由 `CLIRouter.runReport` 调用；
    /// `CLIScoreText.swift`（`score` 文本读数）与 `CLIOutput.swift`（`CLIConfig` 口径自检 +
    /// stdout/stderr 分流）各由 `CLIRouter` 调用。四枚都是"入口"而不是"第二把尺子"：
    /// 评分与 schema 一律沿用 `Models/ProjectReport.swift` 本体。守卫实报「实现文件 141 ·
    /// 零调用清单：无」（`unused.isEmpty` 通过 = 四枚都有产品侧引用，不是被单测喂活的）。
    /// 141 → 142（同一条流紧随其后的一笔：`Services/Health/HealthBreakdown.swift` ——
    /// 把 `ScoreRow` / `HealthBreakdown` / `WeightShiftCause` / `DimensionDisplay` /
    /// `MissingDimensionReason` 从 `Views/Health/HealthComponentTable.swift` **整块下移**，
    /// 让无头 CLI 与界面共用同一份"哪些维度缺席、为什么缺席"。引用点：
    /// `Views/Health/HealthComponentTable.swift`（原调用方，一字未改）、
    /// `Design/DataTable.swift`（此前一直在反向引用 `HealthBreakdown.weightColumnHelp`，
    /// 这次连方向一起摆正）、`Services/CLI/CLIScoreText.swift`（新增的第二位读者）。
    /// 142 → 143（WS-X8 ⓘ 前置：新增 `Design/CopyHelp.swift`，声明 `CopyHelpBadge`。
    /// **凭什么被引用**：`Views/PerfLogs/NumberText.swift` 的 `NoteLine(_:role:icon:help:)`
    /// 在 `help != nil` 那一支渲染它 —— 那是「留短藏长」类槽位（盘点表 129 槽里 94 槽判这一类）
    /// 在性能 / 日志 / 健康三页的挂载点，ⓘ 的画法全站只许这一份
    ///（新增的 `CopyHelpBadgeTests` 三条判据 + 注入坏样例的元测试钉住）。
    /// 守卫实报「实现文件 143 · 在用 142 · 未用 0 · 零调用清单：无」）。
    /// 143 → 144（WS-CL 第二轮·入口重排，**2026-09-22 由总工按守卫实报填**：
    /// 新增 `App/TcoderEntry.swift` 持有 `@main`。**凭什么被引用**：它就是进程入口，
    /// 由链接器/`@main` 展开的 `main()` 调用（与 `App/TcoderMonitorApp.swift` 同一类证据，
    /// 区别只是那个类型不再隐式调度）；它自己调用 `CLIRouter.main` 与 `TcoderMonitorApp.main()`
    /// 两路，所以**两边都不成孤儿**。动它的理由不是审美：真二进制实测
    /// `score <不存在的路径>` 在 `App.init()` 里 `exit()` 会撞上 AppKit 的窗口状态恢复，
    /// 挂死 16 分钟不出声，而 in-process 的 20 条 CLI 单测全绿（盲区由
    /// 新增的 `CLIProcessTests` 真子进程一把堵上）。
    /// 同时 `frameworkWhitelist` 从 `TcoderMonitorApp.swift` 换成 `TcoderEntry.swift`
    /// —— 白名单只留"真正写着 `@main` 的那一个"，`TcoderMonitorApp` 改由 `TcoderEntry` 点名调用。
    /// 144 → 147（2026-09-22 检测正确性整改轮 · R4 日志与崩溃证据链，三枚全在 `Services/Logs/`；
    /// **2026-09-22 09:36 由总工按守卫实报填**（守卫跑出 147，不是算出来的）：
    /// `CrashEvidence.swift`（四态类型 `CrashEvidenceState` / `CrashEvidenceRecord` / `CrashEvidenceLedger`
    ///   + `AppBuildIdentity` / `CrashEventTimeSource` / `LogEventWindowSplit`）—— 被
    ///   `FileLogAnalyzer`、`LogParsing`、`CrashTextParsing`、`CrashIpsValueReading`、`CrashReportParser`、
    ///   `CrashEvidenceClassification`、`LogClustering` 共同引用；
    /// `CrashEvidenceClassification.swift`（把"文件名像崩溃报告"与"真的拿到事件证据"分开的那一步）——
    ///   被 `CrashTextParsing` 与 `FileLogAnalyzer` 引用；
    /// `LogProjectIdentity.swift`（应用归属不再靠目录名猜）—— 被 `FileLogAnalyzer` 与 `LogDiscovery` 引用。
    /// 三枚都不是死文件：同一次守卫跑出「零调用清单：空」（`testZeroCallListIsEmpty` 未红）。
    /// 147 → 150（R2 Vue/TS 识别流三枚，2026-09-22 09:46 由总工按**集成分支上守卫实报**填）：
    /// `ComplexityLexMachine.swift`（模板串/插值的帧栈状态机，被 `ComplexitySanitizer` 与
    ///   `ComplexityEngine` 引用）；`VueSourceRegions.swift`（SFC 三分区归位，被 `SourceFileClassifier`
    ///   与 `FunctionRecognition.computeScriptMask` 那条路引用）；
    /// `FunctionScanning.swift`（为回到 400 行口径从 `ComplexityEngine.swift` 整块搬出的扫描端，
    ///   被 `ComplexityEngine` 调用 —— 同批把 `ComplexityEngine.swift` 从 475 行降到闸门内）。
    /// 150 → 151（集成分支修复人把 `CodeScanCoverage` 整块搬出 `FileSystemCodeAnalyzer.swift`
    ///   以守 400 行闸门，新增 `FileSystemCodeAnalyzerLimits.swift` 一枚）。
    /// 151 → 152（RD-30/31 溯源块新增 `Models/ScanProvenance.swift`，四处在引用它）。
    /// 152 → 164：依赖链一条流带来 12 枚新实现文件（枚数与引用证据逐条见台账卷二 §27，
    ///   全部由守卫 `testEveryImplementationFileHasExternalCallEvidence` 实跑判过在用）。
    /// 164 → 173（R5/R5b 覆盖率链整块拆出的九枚，全在 `Services/Coverage/`：
    ///   `CoverageDisplayShape` / `CoverageLineLedger` / `CoverageMergeConfidence` / `CoverageMergeLedger` /
    ///   `CoverageMergePlanner` / `CoverageReportDiscovery` / `CoverageReportIdentity` /
    ///   `CoverageRunIdentity` / `CoverageSourceBinding`。
    ///   引用证据是同一次守卫跑出的「零调用清单：空」（`testZeroCallListIsEmpty` 未红），
    ///   九枚都是 `CoverageAnalyzer` 那条链为守 400 行闸门按类型整块搬出去的，不是空壳。）
    /// 173 → 174（R10 台账一枚 `Models/AnalyzerLedger.swift`：CLI 与 GUI 两个装配点各调一次
    ///   `AnalyzerLedger.records(from:)`，五路路名也只住这一份）。
    /// ✅ 174 已由守卫在同一棵合流树上实跑核对过：打印「实现文件 174 个（普查基线 174）」，
    ///   且零调用清单为空。拼接值不自证，跑过才算数（这条旋钮的历史就是"算的数"与"跑的数"分叉）。
    /// 174 → 181（**两批新增都在同一棵树里了**，说明逐条并排留着）：
    /// - main 侧 R6 流 174 → 178，四枚在 `Services/Code/`：`SourceFileRoleRules`（角色判据）/ `SourceFileRoleSignals`（信号采集）/`SourceRoleTally`（逐条计数）/ `SourceScanScopeReadout`（范围读数与「跟不跟」句子的装配）。同一次守卫跑出「零调用清单：空」⇒ 四枚都有 `Sources/**` 内的调用点，不是空壳。
    /// - 本流 R10b 174 → 177，三枚全在新目录 `Services/Trace/`：`AnalyzerLedgerText`（把四态台账打成 CLI 文本，装在「未量准」之后、分数之前）、`MeasurementLedger`（甲栏量出来的 / 乙栏算出来的分栏，乙栏每行带「← 由…算来」，并用 `danglingSources` + `upstreamInputs` 把「只从既有类型算、不许重扫源码」做成机器判据）、`EvidenceCoordinates`（文件 ⇑ 符号 ⇑ 判据名的稳定坐标，key 不含行号、路径按 scannedRoot 相对化）。
    /// ⚠️ 181 = 178 + 3 是**推的**，不是守卫实报的：合完 main 之后必须重跑一次，以它打印的现量为准（这条常量只由总工拧，且只按实报拧）。
    /// 181 → 182（**总工本人 2026-09-23 22:36，按守卫实报拧**）：R17 落 RD-15 契约时新增一枚
    ///   `Services/Code/CodeScanSurfaceReadout.swift` —— 把申请单 §3 那族"范围台账"
    ///   （`totalCount` / 被剔除条目的行数 / `linesCounted` 三态 / 读不动的目录）从内部类型
    ///   `SourceScanScopeReadout` + `SourceTreeFollowingLedger` 接进 `CodeMetrics.scanSurface`。
    ///   同一次全量跑出的是：分母 **182**、`unused` **为空** ⇒ 它在 `Sources/**` 内真有调用点
    ///   （`FileSystemCodeAnalyzer` 写字段那一路），不是空壳；除这一条外 1588 例全绿。
    ///   ⚠️ 上面那句"181 是推的"仍然算账：这一轮重跑同时把 181 与实扫现量对上了，
    ///   没有第二枚未登记的净增减。
    ///   2026-09-24 **182 → 183**（RD-60 那支合流时由总工按实报拧，同一行只换数字）：
    ///   顶上来的是 `Services/Logs/CrashEvidenceReadout.swift`（`a1d577c` 新增，
    ///   真读者是 `FileLogAnalyzer` 那条上屏链与 CLI/GUI 两个出口，不是只被自己的单测引用）。
    static let censusBaseline = 183

    /// 不再自己抄一份：仓库遍历剪枝只有 `SelfScanHarnessCase.skipDirectoryNames` 一个来源。
    static let prunedDirectories: Set<String> = SelfScanHarnessCase.skipDirectoryNames

    /// 框架隐式调度的入口白名单。**只有 `@main` 一处**，且下面的门要求每个条目正文里真写着
    /// `@main`、并且它本身也拿得出证据——白名单不许变遮羞布。
    static let frameworkWhitelist: Set<String> = ["App/TcoderEntry.swift"]

    /// 普查点名的三个扩展分片（坑 1）：自己不声明顶层类型，只写 `extension SomeType`。
    /// 分片全集由扫描动态得出，这里钉三个具体名字，防止「发现逻辑哪天退化成空集」。
    static let namedShardFiles = ["Services/Dependencies/ManifestParsersApple.swift",
                                          "Services/Code/ComplexityCounting.swift",
                                          "Services/Logs/CrashTextParsing.swift"]

    // MARK: - 数据模型

    // MARK: - 可见性说明（2026-09-20 拆分所致，**不要改回 private**）
    //
    // `RDoc` / `Rule` / `Evidence` / `ScanOutcome` / `Gate` / `leadingDotRE` / `buildOutcome` /
    // `gate` / `synth` 原先是 `private`。本轮补元测试后本文件涨到 880 行、撞上 800 行闸门，
    // 按「闸门不降、把文件拆开才是修复」拆出了 `SourceFileReachabilityMetaTests.swift`；
    // `private` 在同类型的跨文件 extension 里不可见，所以这几个声明放成了 `internal`。
    // **改回 `private` 会让那个文件编不过。**

    struct RDoc { var relativePath: String; var raw: String; var isProduction: Bool }

    struct OwnerMember: Hashable, Comparable {
        var owner: String; var member: String
        static func < (l: OwnerMember, r: OwnerMember) -> Bool { (l.owner, l.member) < (r.owner, r.member) }
    }

    struct RAnalysis {
        var types = Set<String>()
        /// 深度 0 声明的类型：只写 `extension` 的分片文件这里必为空。
        var topLevelTypes = Set<String>()
        var extensions = Set<String>()
        /// 深度恰为 1 的成员声明（类型作用域成员，不含函数体里的局部量）。
        var members = Set<OwnerMember>()
        var staticMembers = Set<OwnerMember>()
        /// 本文件「拥有作用域」的类型名：自己声明的类型 + 扩展目标 + 成员所属类型。
        var owners = Set<String>()
    }

    enum Rule: String, CaseIterable {
        case uniqueType = "①唯一类型名", qualified = "②限定引用"
        case dispatcher = "③同作用域派发", staticShorthand = "④static 简写"
    }

    struct Evidence: Hashable { var rule: Rule; var symbol: String; var witness: String }

    struct ScanOutcome {
        var productionFiles: [String] = []
        var testFileCount = 0
        var inUse: [String] = []
        var unused: [String] = []
        var whitelisted: [String] = []
        var evidence: [String: [Evidence]] = [:]
        var ruleTally: [Rule: Int] = [:]
        var candidateCount = 0
        var strippedFileCount = 0
    }

    struct Gate { var reasons: [String]; var pass: Bool { reasons.isEmpty } }

    /// 整词 / 限定 / 前导点简写三张倒排索引（键 → 出现过的实现文件集合）。
    /// 用索引而不是逐条跑正则：候选符号上千个，逐条正则会跑到分钟级。
    struct TokenIndex {
        var word: [String: Set<String>] = [:]
        var qualified: [String: Set<String>] = [:]
        var dot: [String: Set<String>] = [:]
    }

    // MARK: - 脱敏器（剥注释与字符串，等长替换）

    // MARK: - 声明解析与倒排索引

    static let declRE = try! NSRegularExpression(
        pattern: #"\b(struct|class|enum|protocol|actor|extension)\s+([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)"#)
    static let memberRE = try! NSRegularExpression(
        pattern: #"\b(func|var|let|case|typealias)\s+([A-Za-z_]\w*)"#)
    static let staticRE = try! NSRegularExpression(pattern: #"\bstatic\b|\bclass[ \t]+func\b"#)
    static let wordRE = try! NSRegularExpression(pattern: #"[A-Za-z_]\w*"#)
    static let dottedRE = try! NSRegularExpression(pattern: #"\b([A-Za-z_]\w*)\.([A-Za-z_]\w*)\b"#)
    /// 前导点简写索引。`(?<![\w.])` 是**必须的**：少了它 `NSWorkspace.shared` 也会被收进来，
    /// 于是任何声明了 `static ... shared` 的类型都被别的类型白送证据（2026-09-20 真漏过一次）。
    static let leadingDotRE = try! NSRegularExpression(pattern: #"(?<![\w.])\.([A-Za-z_]\w*)"#)
    /// 元测试 5 的独立复核口径：行首 ≤ 4 空白 + 修饰词 + 类型关键字 + 名字。故意**不借用**引擎的
    /// 花括号深度逻辑——两把尺子不许共享同一个盲区。
    static let independentTypeSiteRE = try! NSRegularExpression(
        pattern: #"^[ \t]{0,4}(?:[A-Za-z_]\w* +)*(?:struct|class|enum|protocol|actor) +([A-Za-z_]\w*)"#)

    // MARK: - 可达性判定（纯函数：喂合成文档就能验，不碰磁盘）

    /// 一趟普查的装配线：脱敏 → 解析 → 建索引 → 逐文件取证 → 三分类。
    /// 四条取证规则各自抽在 `SourceFileReachabilityTests+EvidenceRules.swift`
    /// （WS-X3 拆分：本函数原判 CC 29 / 73 行，超本仓 16 的热点线）。
    static func buildOutcome(_ docs: [RDoc], whitelist: Set<String>) -> ScanOutcome {
        var code: [String: String] = [:]
        var analyses: [String: RAnalysis] = [:]
        var out = ScanOutcome()
        for doc in docs {
            let stripped = strippingNoise(doc.raw)
            code[doc.relativePath] = stripped
            analyses[doc.relativePath] = analyzeOne(stripped)
            if doc.isProduction, stripped != doc.raw { out.strippedFileCount += 1 }
        }
        // 唯一性在 Sources + Tests 全集上算
        let declarers = declarerIndex(docs, analyses: analyses)
        let production = docs.filter { $0.isProduction }.sorted { $0.relativePath < $1.relativePath }
        out.productionFiles = production.map(\.relativePath)
        out.testFileCount = docs.count - production.count
        let index = buildIndex(docs, code: code)

        var candidates = 0
        for doc in production {
            guard let a = analyses[doc.relativePath] else { continue }
            out.evidence[doc.relativePath] = evidence(for: doc.relativePath, analysis: a,
                                                      index: index, declarers: declarers,
                                                      analyses: analyses, candidates: &candidates)
        }
        out.candidateCount = candidates
        classifyFiles(&out, whitelist: whitelist)
        return out
    }

    /// 判定门口：真跑那一轮与合成夹具走的是**同一份**代码。
    /// 分母为 0 一律判失败——「没扫到东西」绝不能等于「交付干净」。
    static func gate(_ out: ScanOutcome, whitelist: Set<String>) -> Gate {
        var reasons: [String] = []
        if out.productionFiles.isEmpty {
            reasons.append("分母为 0：一个实现文件都没扫到。这是扫描器坏了，不是代码干净。")
        } else if out.productionFiles.count < 100 {
            reasons.append("分母 \(out.productionFiles.count) 远低于普查基线 \(censusBaseline)：路径解析静默失效。")
        }
        if !out.unused.isEmpty {
            reasons.append("零调用实现文件 \(out.unused.count) 个：\n"
                + out.unused.map { "  \($0)" }.joined(separator: "\n"))
        }
        let stale = whitelist.subtracting(out.productionFiles)
        if !stale.isEmpty { reasons.append("白名单条目已不在扫描面上，必须删掉：\(stale.sorted())") }
        let identity = out.inUse.count + out.unused.count + out.whitelisted.count
        if identity != out.productionFiles.count {
            reasons.append("守恒破了：在用 \(out.inUse.count) + 未用 \(out.unused.count)"
                + " + 白名单 \(out.whitelisted.count) = \(identity) ≠ 分母 \(out.productionFiles.count)")
        }
        return Gate(reasons: reasons)
    }

    // MARK: - 取数：真实仓库 / 合成夹具

    // MARK: - 主门：每个实现文件逐个要有外部调用证据（分母见 censusBaseline）

    func testEveryImplementationFileHasExternalCallEvidence() throws {
        let (docs, out) = try realOutcome()
        let g = Self.gate(out, whitelist: Self.frameworkWhitelist)
        XCTAssertTrue(g.pass, g.reasons.joined(separator: "\n"))
        XCTAssertEqual(out.productionFiles.count, docs.filter { $0.isProduction }.count, "分母与扫描面不一致")
        XCTAssertGreaterThan(out.productionFiles.count, 100, "分母必须 > 100（普查基线见 censusBaseline）")
        XCTAssertGreaterThan(out.testFileCount, 50, "测试面也没扫到 → 目录解析八成是坏的")
        XCTAssertEqual(out.inUse.count + out.unused.count + out.whitelisted.count, out.productionFiles.count,
                       "在用 + 未用 + 白名单 必须等于分母，不许有没归类的文件")
        XCTAssertGreaterThan(out.strippedFileCount, out.productionFiles.count * 3 / 4,
                             "多数文件脱敏后文本没变化 → 脱敏器可能空转")
        var report: [String] = []
        report.append("【WS-U 可达性守卫】实现文件 \(out.productionFiles.count) 个"
            + "（普查基线 \(Self.censusBaseline)）；测试文件 \(out.testFileCount) 个参与唯一性计算")
        report.append("  在用 \(out.inUse.count) · 未用 \(out.unused.count)"
            + " · 白名单 \(out.whitelisted.count)（\(Self.frameworkWhitelist.sorted().joined(separator: ", "))）")
        report.append("  全仓唯一声明的候选符号 \(out.candidateCount) 个；证据条数按判据："
            + Self.ruleTallyText(out.ruleTally))
        report.append("  剥掉注释与字符串后文本发生变化的实现文件："
            + "\(out.strippedFileCount)/\(out.productionFiles.count)")
        report.append("  白名单自身证据：" + out.whitelisted
            .map { "\($0) → \(self.firstEvidence(out, $0))" }.joined(separator: " ; "))
        report.append("  零调用清单：" + (out.unused.isEmpty ? "无" : out.unused.joined(separator: ", ")))
        print(report.joined(separator: "\n"))
    }

    // MARK: - 元测试 1：合成死文件必须被抓出来（守卫抓得住坏例）

    // MARK: - 元测试 2：扩展分片不得被误杀（守卫不放倒好例）

    // MARK: - 元测试 4：脱敏真的起作用

    // MARK: - 元测试 5：名字碰撞不能把死文件洗活

    // MARK: - 元测试 6：白名单必须自己站得住（且不许环境门控）

    // MARK: - 元测试 7：靠弱判据活着的文件必须被点名（守卫不许悄悄变松）

    // MARK: - 元测试 8：分母与普查基线对齐（也防 filter 名字写错的永真绿）

    func testDenominatorMatchesCensusBaseline() throws {
        let (_, out) = try realOutcome()
        XCTAssertEqual(out.productionFiles.count, Self.censusBaseline,
                       "分母从 \(Self.censusBaseline) 变了：先分清是新增实现文件（那就该有引用）还是扫描面坏了")
        XCTAssertTrue(out.unused.isEmpty, "未用文件：\(out.unused)")
    }
}
