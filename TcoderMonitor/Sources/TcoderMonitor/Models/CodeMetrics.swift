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
