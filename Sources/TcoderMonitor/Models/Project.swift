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
    var isDemo: Bool

    init(
        id: UUID = UUID(),
        name: String,
        path: String,
        addedAt: Date = Date(),
        lastScanAt: Date? = nil,
        isDemo: Bool = false
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.addedAt = addedAt
        self.lastScanAt = lastScanAt
        self.isDemo = isDemo
    }

    var url: URL { URL(fileURLWithPath: path) }
    var directoryName: String { url.lastPathComponent }
}

// MARK: - Scan orchestration types

enum AnalysisPhase: String, Codable, Sendable {
    case idle
    case code
    case git
    case logs
    case dependencies
    case health
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
    var health: HealthScore?
    var generatedAt: Date = Date()

    init(project: MonitoredProject) {
        self.project = project
    }
}
