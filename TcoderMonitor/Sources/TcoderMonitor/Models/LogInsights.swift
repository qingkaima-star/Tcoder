import Foundation

// MARK: - Log / crash analysis

struct LogSummary: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var windowStart: Date?
    var windowEnd: Date?
    var scannedFiles: [ScannedLogFile] = []

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
