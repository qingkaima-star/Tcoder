import Foundation

// MARK: - Code size & quality hotspots

struct CodeMetrics: Codable, Equatable, Sendable {
    var scannedAt: Date = Date()
    var durationMs: Int = 0

    var totalFiles: Int = 0
    var totalLines: Int = 0
    var blankLines: Int = 0
    var commentLines: Int = 0
    var codeLines: Int = 0

    var languages: [LanguageShare] = []
    var todoCount: Int = 0
    var fixmeCount: Int = 0

    var hugeFiles: [FileHotspot] = []
    /// 越过「巨大文件」行数线的**真个数**。`hugeFiles` 是封顶榜单（只留最大的 20 个），
    /// 拿它的 `count` 当占比分子会在大仓库上把问题**报小**——本 App 扫自己实测：
    /// 榜内 20 个 / 实际 38 个，占比被报成 10.5% 而真值是 20%。
    ///
    /// Optional 是落盘兼容要求（旧报告没这个字段）。缺它时评分器退回榜内计数，
    /// 那是**偏松**的口径，所以 detail 必须写明用的是哪一个（`WeightedHealthScorer.codeQualityOutcome`）。
    var hugeFileCount: Int? = nil
    /// 占比分子的唯一取法，两处消费方（评分器与界面）都走它，免得各写一份口径。
    var reportedHugeFileCount: Int { hugeFileCount ?? hugeFiles.count }
    var topComplexFunctions: [FunctionHotspot] = []
    /// **全体**函数里判档达到"高"或更高的个数。
    ///
    /// ⚠️ 为什么没有一并加一枚"热点总数"：读实现才确认 `FileSystemCodeAnalyzer.hotspots(…)`
    /// **根本不做筛选** —— 它把每一个被识别的函数都映射成 `FunctionHotspot`，
    /// 所以它的 `count` 等于函数总数（本仓 3358），拿它当"热点总数"上屏就是一句谎话。
    /// 榜就是榜：`topComplexFunctions` 的读数以"复杂度**上榜**"命名是诚实的，
    /// 需要"多少个函数真的偏复杂"这一格时，用下面这个按判档算出来的个数。
    var highRiskHotspotCount: Int? = nil
    /// 取法只留一处：消费方不许各自再写一遍 `?? 榜内 filter`（那会得到第二个口径）。
    /// 旧报告没有这一格时才退回榜内算法，那是**偏小**的口径（榜只留 20）。
    var reportedHighRiskHotspotCount: Int {
        highRiskHotspotCount ?? topComplexFunctions.filter { $0.risk.rank >= RiskLevel.high.rank }.count
    }
    var longFunctions: Int = 0
    var averageFunctionLength: Int = 0

    /// Repo-wide mean cyclomatic complexity over **every** function the analyzer
    /// recognized, not the mean of the hotspot list. `topComplexFunctions` is a
    /// capped ranking, so averaging it inflates the score non-monotonically with
    /// repo size; consumers that need a repo average must not substitute it.
    ///
    /// Optional because `ProjectStore` decodes persisted reports with `try?` —
    /// a missing key on a non-optional field would silently discard the user's
    /// previously saved reports instead of failing loudly.
    var averageCyclomaticComplexity: Double?
    /// Denominator behind `averageCyclomaticComplexity`. Zero means the analyzer
    /// recognized no functions at all, which is "unknown", not "simple".
    var analyzedFunctionCount: Int = 0
    /// 没能编译的识别规则（批次 P7-B 2-6/2-7）。`nil` = 所有规则都跑起来了。
    ///
    /// 存在理由：正则坏掉时函数数会算成 0，而 0 在界面上读起来就是"这个仓库没有函数"。
    /// 这条台账把"我们的规则没跑起来"与"这个仓库真的没有"分开。
    /// **Optional 是落盘兼容要求**：非 Optional 带默认值会让旧报告整份解码失败。
    var analyzerRuleFailures: [String]? = nil
    /// 本次扫描**生效过的边界与上限**（批次 P7-C 3-2），一行一条，全部带真实数字。
    /// `nil` = 一条都没生效，这份数字是全量；非空 = 部分测量，界面不得把它画成"扫完了"。
    ///
    /// 存在理由：`CodeScanCoverage` 早就算出了"被哪条上限切掉多少"，但契约里没有承接字段，
    /// 于是 `analyze` 只取 `metrics`，那四个字段连同中文说明一起被丢掉 —— 一份只读了
    /// 前 3 个文件的报告在屏上与全量报告长得一模一样。
    /// **Optional 是落盘兼容要求**：非 Optional 带默认值会让旧报告整份解码失败。
    var scanLimitations: [String]? = nil

    /// 0...1 — share of code lines that fall inside a duplicated block.
    var duplicationRatio: Double = 0
    var duplicatedBlocks: [DuplicatedBlock] = []

    // MARK: 重复明细榜的"榜外那一半"（RD-48 · 台账卷二 §27 之续）
    //
    // 存在理由：`DuplicationEngine` 早就算清了"被上限切掉多少"（下面这几枚全是它的字段直传），
    // 但契约里没有承接格 ⇒ 那四个数**只活在 `scanLimitations` 那句中文里**。
    // 后果有两层：① 消费方要"榜外还有几块"只能去解析句子（等于造第二把尺子）；
    // ② 界面页尾那句"明细榜上限 20 块"是**数**，却来自一条按句式认领的字符串
    // （`CodeBoardTruth.outsideBoardNote`），改文案不改认领标记就会静默失去披露。
    // ⚠️ **故意不给"重复块总数"**：`rankedBlocks` 在撞 id 时还会削掉若干块而无处计数
    // （R6b 交回时点名），所以"榜内 + 榜外 == 总数"这个等式天然不平，
    // 造一枚看似精确的总数就是把不平藏起来。
    /// 明细榜的封顶长度（引擎那份 `maxBlocks` 的直传，不是界面自己抄的 20）。
    /// `nil` = 本次没跑到重复分析（旧报告与"依赖/日志缺席"同一种处理）。
    var duplicatedBlockLimit: Int? = nil
    /// 按行数降序截断到上限时**被丢掉的克隆块数**（它们参与了 ratio，只是没进明细）。
    var duplicatedBlocksDroppedByCap: Int? = nil
    /// 上面那些被丢掉的块覆盖的代码行数。
    var duplicatedLinesOutsideReportedBlocks: Int? = nil
    /// 因每指纹片段的展开预算而**没展开成片段**的拷贝窗口数（ratio 已含它们）。
    var duplicateFragmentsNotExpandedCount: Int? = nil
    /// 归一化行数触到窗口上限、后半段克隆不参与检测的文件数。
    var duplicateFilesHittingLineCap: Int? = nil

    /// 榜外（被明细榜单的 20 块上限切掉、但**参与重复率分子**）那些块的**可点名坐标**（RD-52）。
    ///
    /// 存在理由：这些坐标原先只活在 `scanLimitations` 的中文句子里，而且**同一串在一份报告里
    /// 印两遍**（口径句一遍、扫描边界句一遍），单条实测长达 2,407 个字符。
    /// 读 JSON 的人（含 AI 调用方）要定位"到底是哪几块"仍然得解析散文 ——
    /// 这正是 RD-48 刚消灭过的形状，在坐标这一格复活了。
    /// 现在引擎那份**原样**落在这里（原始测量，不做加工），句子只点名前几条并指回本字段。
    /// `nil` = 这份报告没有这一读数（旧报告 / 这一路没跑）；**空数组 = 榜外确实没有剩余块** ——
    /// 两件事不许混，后者是"量过了、为零"。
    /// **Optional 是落盘兼容要求**：非 Optional 带默认值会让旧报告整份解码失败。
    var duplicateBlockCoordinatesOutsideBoard: [String]? = nil

    // MARK: 混合语言文件的分区归位读数（RD-42 · 台账卷二 §23「有写无读」那一条）
    //
    // 存在理由：`ComplexityEngine.LexIntegrity.nonCodeRegionLineCount` 从 R2 起就在算
    // （`sanitize(_:profiles:)` 里逐行累加、`merged` 里跨区累加），全仓却**一个读者都没有**：
    // 它不在 `hasAnomaly`、也不在 `limitations`，于是"分区认出来了、于是 N 行按非代码归位"
    // 这件事一件没说。而"分区**没**认出来"是另一条在出声的（`vueRegionFallbackFileCount`）。
    //
    // ⚠️ **这一格是口径，不是"未量准"**：template / style 那些行是**已经量到了**、
    // 只是分类不同（不进代码统计）。所以它**不进** `scanLimitations` —— 那条在 CLI 会被
    // 打成「未量准 N 条」（`CLIScoreText.precisionCaveat`），塞进来就是把那个数灌虚高。
    // 读者走扫描边界那一族：`MixedLanguageRegionCaliber.note(_:)`（界面与 CLI 同一把尺子）。
    //
    /// 混合语言文件（`.vue` 的 template / style 与 SFC 标签行）里按分区归位为**非代码**、
    /// 因而没有进入代码统计的行数。**直传**词法台账那一份，任何消费方都不许再数第二遍。
    /// `nil` = **这份报告没有这个读数**（旧报告 / 这一路没跑）—— 不许写成 0；
    /// `0` = 跑过了，这个语料里没有需要分区的区域（纯 Swift/Java 仓库）。
    /// **Optional 是落盘兼容要求**：非 Optional 带默认值会让旧报告整份解码失败。
    var nonCodeRegionLineCount: Int? = nil

    /// 本次扫描的**范围台账**（RD-15 · 申请单 R6 §3）。`nil` = 这份报告没有范围台账
    /// （旧报告 / 这一路没跑）—— 这时「排除了 0 个」这句话**不成立**，屏上只能报缺席。
    ///
    /// 存在理由：`SourceScanScopeReadout` 与 `SourceTreeFollowingLedger` 早就把
    /// 「排除了几个条目、被排除的那些有多少行、行数到底是数过还是没数」算清楚了，
    /// 但那几个数只活在 `scanLimitations` 的中文句子与单测里 ——
    /// 读 JSON 的人拿不到数，只能解析散文（与 RD-48 那一批同形）。
    /// **必须 Optional**：非 Optional 带默认值会让旧报告整份解码失败。
    /// 上屏那一句的唯一装配口是 `CodeScanSurfaceReadout.accountingLine(_:)`
    /// （住 `SourceScanScopeReadout.swift`，界面与 CLI 共用同一把尺子）。
    var scanSurface: CodeScanScope? = nil

    var largestFileLineCount: Int = 0

    var overallRisk: RiskLevel = .none

    var primaryLanguage: String { languages.first?.language ?? "未知" }
    var commentRatio: Double { totalLines == 0 ? 0 : Double(commentLines) / Double(totalLines) }
}

struct LanguageShare: Codable, Equatable, Hashable, Identifiable, Sendable {
    var language: String
    var fileCount: Int
    var lineCount: Int

    var id: String { language }
    var share: Double

    init(language: String, fileCount: Int, lineCount: Int, share: Double = 0) {
        self.language = language
        self.fileCount = fileCount
        self.lineCount = lineCount
        self.share = share
    }
}

struct FileHotspot: Codable, Equatable, Hashable, Identifiable, Sendable {
    var path: String
    var lineCount: Int
    var risk: RiskLevel
    var suggestion: String

    var id: String { "\(path):\(lineCount)" }
}

struct FunctionHotspot: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var filePath: String
    var startLine: Int
    var lineCount: Int
    var cyclomaticComplexity: Int
    var parameterCount: Int
    var risk: RiskLevel

    var id: String { "\(filePath):\(startLine):\(name)" }
}

struct DuplicatedBlock: Codable, Equatable, Hashable, Identifiable, Sendable {
    var occurrences: [DuplicatedFragment]
    var lineCount: Int
    var similarity: Double

    var id: String { occurrences.map(\.path).sorted().joined(separator: "|") + ":\(lineCount)" }
}

struct DuplicatedFragment: Codable, Equatable, Hashable, Sendable {
    var path: String
    var startLine: Int
}

// MARK: - 扫描范围（RD-15 · 申请单 R6 §3 的形状，字段名一字未改）

/// 一次扫描的**范围读数**。三件事必须是三个不同的读数，所以**每一格都是 Optional**：
/// ① 整枚 `CodeMetrics.scanSurface` 缺席 = 这份报告没有范围台账；
/// ② 某一格缺席 = 那一项没量；③ 某一格是 `0` = 量过了、真的是 0。
///
/// 数值全部**直传**内部台账（`SourceScanScopeReadout` + `SourceTreeFollowingLedger`），
/// 这里不做任何加减；唯一允许的算术是 `reportedExcludedEntryCount` 那一处取法
/// （§5 那一族的形状：可选真总数 + 取法只留一处的计算属性，消费方不再各写一份相加）。
///
/// ⚠️ 上屏那一句的唯一装配口是 `CodeScanSurfaceReadout.accountingLine(_:)`
/// （住 `Services/Code/SourceScanScopeReadout.swift`，界面与 CLI 共用同一把尺子）。
struct CodeScanScope: Codable, Equatable, Sendable {
    /// 遍历看到的条目数（纳入 + 剔除；目录、软链接、隐藏项这些"条目"也在内）。
    /// `nil` = 这一份没有范围台账 —— 申请单点名的那一态：屏上只能报"没有台账"。
    var totalCount: Int?
    /// 逐条留了路径样本的**被排除条目**数（每个原因桶最多 `SourceSkipLedger.sampleLimit` 条）。
    var displayedCount: Int?
    /// 被排除但**没有**留下路径样本的条目数。
    var undisplayedCount: Int?
    /// 没量到的范围，一行一条（带计数）。
    /// ⚠️ **空数组与 `nil` 是两件事**：空 = 真的没有未量到的范围（看完了）；
    /// `nil` = 这一格没记。拿空数组冒充"看完了"是本字段的第一号反例。
    var unmeasuredScope: [String]?
    /// 被排除条目的**行数**。`nil` = 没读内容所以没数；`0` = 读过了、真的是 0 行。
    /// `linesCounted == false` 时这一格**必须**为 `nil`（产品默认路径 `auditLineBudget == 0`
    /// 就是这种组合；把 0 填进去等于把"没数"写成"没有"）。
    var excludedLineCount: Int?
    /// 上一格到底数没数过（审计模式才为 true）。
    var linesCounted: Bool?
    /// 根之下又出现的版本库标记数。口径：它们的工作树**已并入**本次统计，不按子仓库另算。
    var nestedRepositoryCount: Int?
    /// 其中 `.git` 是文件形状的（submodule 标记）。
    var submoduleMarkerCount: Int?
    /// 文件软链接数（刻意不跟随 ⇒ 不重复计数）。
    var symbolicLinkFileCount: Int?
    /// 目录软链接数（刻意不进入 ⇒ 其内部文件数未统计）。
    var symbolicLinkDirectoryCount: Int?
    /// 名单外、被系统 bundle 判定剪掉的目录数（`*.xcarchive` 这类）。修前恒为"不知道"。
    var unlistedPrunedDirectoryCount: Int?
    /// 本次读不动的目录数。**`0` 与 `nil` 是两个读数**：0 = 每个目录都读到了，
    /// `nil` = 这一格没记。申请单接手那一段点名要它 —— 少了它，界面上就只有
    /// 「这一份是没看完」那句中文、拿不到数。
    var unreadableDirectoryCount: Int?

    /// 「按规则排除了多少个条目」的**唯一取法**：点名的那半 + 没点名的那半。
    /// 两半任缺其一就返回 `nil` —— 缺读数时补 0 就是把"没数"当成"没有"。
    /// ⚠️ 它与 `totalCount` **不是同一个分母**（后者含被纳入的条目），两者相加不相等，
    /// 所以任何地方都不许写死 `totalCount == displayed + undisplayed`。
    var reportedExcludedEntryCount: Int? {
        guard let displayed = displayedCount, let undisplayed = undisplayedCount else { return nil }
        return displayed + undisplayed
    }
}
