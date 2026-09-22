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

    /// 本项目名下**读到几份崩溃报告**（RD-46b）。它与 `crashCount`（**确认崩溃次数**）不是一回事：
    /// 一份报告可以含多次事件，也可以一份都没确认（读不动 / 内容损坏 / 无事件时间）。
    ///
    /// 为什么必须落这一格：RD-46b 把崩溃正文从密度分母里摘出去之后，"分母是 0"这件事
    /// 有两种完全不同的来路——一种是真的没有日志，一种是**读到了几份崩溃报告、只是它们不该进分母**。
    /// 没有这一格，界面就只能把后一种也说成前一种（那就是 RD-49）。
    /// `0` = 看了崩溃通道、一份都没有；`nil` = 这一路根本没跑（旧报告 / 该路失败）。
    /// **Optional 是落盘兼容要求**：非 Optional 带默认值会让旧报告整份解码失败。
    var crashReportCount: Int? = nil
    /// 被移出分母的那些行去了哪儿：崩溃报告（读成功的那几份）贡献的**正文行数**（RD-46b）。
    ///
    /// 存在理由：`totalLinesScanned` 只数真日志行之后，那些行必须仍然数得出来，
    /// 否则这次修正就是把一次"灌大分母"换成一次静默丢弃。对账等式由
    /// `totalLinesScanned + crashReportLineCount ==` 本次实际读到的总行数，
    /// 由 `LogDenominatorAccountingTests` 钉住。
    var crashReportLineCount: Int? = nil

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
        // 每条都是**整句键**（方案 §7.3）：「5 秒前」在英文里是 "5 seconds ago"，
        // 词序反过来、还要分单复数，碎片拼接做不到。
        // 中文侧一字不变：`String(format: "%lld 秒前", 5)` 就是「5 秒前」。
        guard let date else { return localizedCopy("未知") }
        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 0 { return localizedCopy("即将") }
        if seconds < 60 { return localizedCount("%lld 秒前", seconds) }
        if seconds < 3600 { return localizedCount("%lld 分钟前", seconds / 60) }
        if seconds < 86_400 { return localizedCount("%lld 小时前", seconds / 3600) }
        let days = seconds / 86_400
        if days == 1 { return localizedCopy("昨天") }
        if days < 30 { return localizedCount("%lld 天前", days) }
        if days < 365 { return localizedCount("%lld 个月前", days / 30) }
        return localizedCount("%lld 年前", days / 365)
    }

    /// 把 `describe` 的整句结果拆成「数字 + 单位」两段，供有 `unit` 槽的读数组件用。
    ///
    /// 为什么不新加 `"秒前"` 这种碎片键：双语方案的硬规矩是**整句键**（§7.3）——
    /// 英文要反过来作词序（"5 seconds ago"）还分单复数，碎片各自翻译一定错。
    /// 所以拆的是**已经本地化完的那一句**，两种语言都只按"前导数字 / 其余文字"切：
    /// 中文 `49 秒前` → `49` + `秒前`；英文 `49 seconds ago` → `49` + `seconds ago`。
    ///
    /// 为什么非要拆：整句塞进 `MetricTile.value` 会让单位词一起吃到 `metricNumber`
    /// 大数档。实拍 Git 洞察（批次 P5）：「49 秒前」三个字是全页最重的墨，
    /// 比本页真正的最大数 558 还抢眼 —— "最重的墨给最大的数" 被单位词破坏了。
    /// 无前导数字的三态（`昨天` / `未知` / `即将`）整体留在 value，不硬造单位。
    static func split(_ text: String) -> (value: String, unit: String?) {
        func isLead(_ character: Character) -> Bool {
            character.isNumber || character == "." || character == "," || character.isWhitespace
        }
        var index = text.startIndex
        while index < text.endIndex, isLead(text[index]) { index = text.index(after: index) }
        let head = String(text[text.startIndex..<index]).trimmingCharacters(in: .whitespaces)
        let tail = String(text[index...]).trimmingCharacters(in: .whitespaces)
        guard head.contains(where: \.isNumber), !tail.isEmpty else { return (text, nil) }
        return (head, tail)
    }

    /// `describe(date)` 再拆两段，省掉调用点的两步写法。
    static func split(_ date: Date?) -> (value: String, unit: String?) {
        split(describe(date))
    }
}
