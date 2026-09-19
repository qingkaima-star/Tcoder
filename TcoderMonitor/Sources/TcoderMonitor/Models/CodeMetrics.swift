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
