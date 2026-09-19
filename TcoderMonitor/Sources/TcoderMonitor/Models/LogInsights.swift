import Foundation

// MARK: - Log / crash analysis

struct LogSummary: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var windowStart: Date?
    var windowEnd: Date?
    var scannedFiles: [ScannedLogFile] = []
    /// 因读取失败而被排除在「已核对」之外的文件，各自带 `readFailure` 原因。
    ///
    /// **为什么不并进 `scannedFiles`**：`hasData` 认 `!scannedFiles.isEmpty`，
    /// 把读失败的文件塞回去，就等于让一次权限不足重新换来一张 all-clear——那正是
    /// `FileLogAnalyzer` 那道 filter 要挡住的（审计 P1 #11）。所以单独记一本账。
    ///
    /// 整个数组也是 Optional（而不是 `= []`），同理：非可选的新 key 在旧报告里不存在，
    /// 合成解码会抛 `keyNotFound`，`try?` 会把用户已存报告整份静默丢掉。
    /// 语义上 nil 与空数组等价，写入方只在非空时赋值。
    var readFailedFiles: [ScannedLogFile]? = nil

    var errorCount: Int = 0
    var exceptionCount: Int = 0
    var warningCount: Int = 0
    var crashCount: Int = 0
    var fatalCount: Int = 0
    var infoLineCount: Int = 0
    var totalLinesScanned: Int = 0

    var topErrors: [ErrorCluster] = []
    var trend: [LogBucket] = []
    var affectedFiles: [String: Int] = [:]

    var todayErrorCount: Int {
        trend.filter { Calendar.current.isDate($0.date, inSameDayAs: Date()) }
            .reduce(0) { $0 + $1.errors + $1.exceptions + $1.crashes }
    }
    var hasData: Bool { totalLinesScanned > 0 || !scannedFiles.isEmpty }
    var overallRisk: RiskLevel {
        let severity = errorCount + exceptionCount * 2 + crashCount * 5
        switch severity {
        case 0: return .none
        case 1..<20: return .low
        case 20..<120: return .medium
        case 120..<600: return .high
        default: return .critical
        }
    }
}

struct ScannedLogFile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var path: String
    var sizeBytes: Int64
    var lineCount: Int
    var modifiedAt: Date
    var role: LogFileRole
    /// 读取失败时面向用户的一句话原因（「权限不足」等）；读成功或老报告里没有 = nil。
    ///
    /// **必须是 Optional。** `ProjectStore` 全程 `try?` 解码，而 Swift 合成的 `Codable`
    /// 不会为缺失的 key 套用属性默认值——这里若写成 `var readFailure: String = ""`，
    /// 用户升级前存的每一份报告都会 `keyNotFound` → 被 `try?` 静默变成 nil →
    /// **整份历史报告消失，且不报任何错**。Optional 缺 key 才解得成 nil。
    var readFailure: String? = nil

    var id: String { path }
}

enum LogFileRole: String, Codable, Sendable {
    case application = "应用日志"
    case error = "错误日志"
    case crash = "崩溃报告"
    case system = "系统日志"
    case build = "构建日志"
}

struct ErrorCluster: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Normalized signature, e.g. the exception class plus a message skeleton.
    var signature: String
    var displayMessage: String
    var count: Int
    var firstSeen: Date?
    var lastSeen: Date?
    var sourceFile: String
    var severity: LogSeverity
    var sampleLines: [String]
    var stackTopFrames: [String]

    var id: String { signature }

    var firstSeenDescription: String { LogRecency.describe(firstSeen) }
    var lastSeenDescription: String { LogRecency.describe(lastSeen) }
}

enum LogSeverity: String, Codable, CaseIterable, Sendable {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
    case exception = "EXCEPTION"
    case fatal = "FATAL"
    case crash = "CRASH"

    var colorHex: String {
        switch self {
        case .trace, .debug: return "8E8E93"
        case .info: return "3B82C4"
        case .warning: return "E8A33D"
        case .error: return "E2593B"
        case .exception: return "C9372B"
        case .fatal, .crash: return "B3261E"
        }
    }
}

struct LogBucket: Codable, Equatable, Hashable, Identifiable, Sendable {
    var date: Date
    var errors: Int
    var warnings: Int
    var exceptions: Int
    var crashes: Int

    var id: Date { date }
    var total: Int { errors + warnings + exceptions + crashes }
}

enum LogRecency {
    static func describe(_ date: Date?) -> String {
        guard let date else { return "未知" }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 0 { return "即将" }
        if seconds < 60 { return "\(seconds) 秒前" }
        if seconds < 3600 { return "\(seconds / 60) 分钟前" }
        if seconds < 86_400 { return "\(seconds / 3600) 小时前" }
        let days = seconds / 86_400
        if days == 1 { return "昨天" }
        if days < 30 { return "\(days) 天前" }
        if days < 365 { return "\(days / 30) 个月前" }
        return "\(days / 365) 年前"
    }
}
