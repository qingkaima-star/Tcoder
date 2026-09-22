import Foundation

// MARK: - Shared risk vocabulary

enum RiskLevel: String, Codable, CaseIterable, Comparable, Sendable {
    case none = "无"
    case low = "低"
    case medium = "中"
    case high = "高"
    case critical = "严重"

    var rank: Int {
        switch self {
        case .none: return 0
        case .low: return 1
        case .medium: return 2
        case .high: return 3
        case .critical: return 4
        }
    }

    static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }

    var colorHex: String {
        switch self {
        case .none: return "8E8E93"
        case .low: return "30B94D"
        case .medium: return "E8A33D"
        case .high: return "E2593B"
        case .critical: return "B3261E"
        }
    }
}

enum HealthGrade: String, Codable, CaseIterable, Sendable {
    case a = "A"
    case b = "B"
    case c = "C"
    case d = "D"
    case e = "E"

    init(score: Int) {
        switch score {
        case 85...: self = .a
        case 70..<85: self = .b
        case 55..<70: self = .c
        case 40..<55: self = .d
        default: self = .e
        }
    }
}

// MARK: - Project identity

struct MonitoredProject: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var name: String
    var path: String
    var addedAt: Date
    var lastScanAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        addedAt: Date = Date(),
        lastScanAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
        self.lastScanAt = lastScanAt
    }

    var url: URL { URL(fileURLWithPath: path) }
    var directoryName: String { url.lastPathComponent }
}

// MARK: - Scan orchestration types

/// 扫描阶段。**只有这四档是真的存在的状态**。
///
/// 原来这里并列着 `code/git/logs/dependencies/health` 五档"正在做哪一路"，
/// 而 `scan` 是 `async let` **五路同时开跑**、全程只赋过 `.code` 与 `.finished`
/// 两个值（批次 P7-C 走查实测）。后果不是难看，是**说假话**：
/// 五路全失败时界面仍然显示"分析完成"，而并行扫描期间它一直说"正在扫描代码规模"。
/// 五档假进度要么去实现串行编排（没有理由），要么删掉（选了这条）。
/// 真实可报的进度只剩"几路回来了"，那个数走 `AppState.completedSectionCount`，
/// 不塞进这个枚举里冒充顺序。
enum AnalysisPhase: String, Codable, Sendable {
    case idle
    case scanning
    case finished
    case failed
}

struct ScanOptions: Codable, Equatable, Sendable {
    var maxFiles: Int = 60_000
    var maxFileBytes: Int = 2_000_000
    var skipDirectories: Set<String> = ScanOptions.defaultSkipDirectories
    var binaryExtensions: Set<String> = ScanOptions.defaultBinaryExtensions
    var includeHidden: Bool = false

    static let `default` = ScanOptions()

    static let defaultSkipDirectories: Set<String> = [
        ".git", ".svn", ".hg", ".build", ".swiftpm", "node_modules", "bower_components",
        "dist", "build", "out", "target", "bin", "obj", "DerivedData", ".gradle", ".mvn",
        "Pods", "Carthage", "venv", ".venv", "__pycache__", ".pytest_cache", ".mypy_cache",
        "vendor", "coverage", ".nyc_output", ".next", ".nuxt", ".turbo", ".parcel-cache",
        "Resources/raw", "unpackage", "logs", ".idea", ".vscode", "xcuserdata",
        "gradle-wrapper", ".dart_tool", "pub", "dart_plugin_registrant",
    ]

    static let defaultBinaryExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "ico", "icns", "pdf", "zip", "gz", "tar", "jar", "war",
        "class", "so", "dylib", "a", "o", "framework", "mp3", "mp4", "mov", "avi", "woff",
        "woff2", "ttf", "otf", "eot", "pyc", "dSYM", "pack", "dat", "db", "sqlite", "sqlite3",
        "keystore", "jks", "p12", "mob", "map", "webp", "heic", "ttc", "bundle", "nib", "storyboardc",
    ]
}

// MARK: - Aggregate report for one project

struct ProjectReport: Codable, Sendable {
    var project: MonitoredProject
    var code: CodeMetrics?
    var git: GitInsights?
    var logs: LogSummary?
    var dependencies: DependencyReport?
    var coverage: CoverageMetrics?
    var health: HealthScore?
    /// 这份报告是在哪个提交、用哪个版本的工具与判据产的。Optional：`d0e` 之前落盘的旧 JSON 没有这一栏，
    /// 必须照样解得开（见「落盘字段必须 Optional」那条规矩）。
    var provenance: ScanProvenance?
    var generatedAt: Date = Date()

    /// Set once a scan has been attempted, even if some analyzers failed. Without this
    /// a partially-failed report looks "never scanned" and the app either re-scans
    /// forever or never retries.
    var attemptedAt: Date?
    /// Chinese labels of analyzers that failed during the last attempt.
    var failedSections: [String] = []

    /// 每一路分析器的执行台账（四态 + 耗时 + 撞到的上限 + 失败原因原文）。
    /// 与 `failedSections` 的分工：那一格只说"哪几路挂了"，这一格说"每一路当时是什么状态"。
    /// **必须 Optional**：旧报告没有这一格 ⇒ 解码时整键缺席，不许补空数组（空数组会被读成"五路都没跑"）。
    var analyzerLedger: [AnalyzerRunRecord]? = nil

    var hasBeenScanned: Bool { attemptedAt != nil }

    init(project: MonitoredProject) {
        self.project = project
    }
}
