// MARK: - 日志发现 / 行解析 / 错误聚类（WS-C 纯逻辑层）
//
// 本文件被 Task.detached 调用，因此全部类型都是 nonisolated 纯逻辑：
// 不引用 AppState / ProjectStore / 任何 @MainActor 对象，只依赖 Foundation。
// 所有文件 I/O 都走「可失败降级」：读不到就跳过并计数，绝不整读大文件、绝不 force-unwrap。

import Foundation

// MARK: - 中间结果类型

struct DiscoveredLog: Sendable, Equatable {
    var url: URL
    var role: LogFileRole
    var sizeBytes: Int64
    var modifiedAt: Date
}

struct ParsedLogLine: Sendable {
    var number: Int
    var raw: String
    var date: Date?
    var severity: LogSeverity?
    /// 去掉时间戳 / 级别前缀后的正文
    var message: String
    /// "at com.foo.Bar.baz(Bar.java:123)" 或 Swift 符号帧
    var stackFrame: String?
    /// 堆栈里出现的源文件 key，如 "Bar.java" / "OrderService.swift"
    var sourceFile: String?
}

struct LogEvent: Sendable {
    var date: Date?
    var severity: LogSeverity
    var rawLine: String
    var message: String
    var sourceLogPath: String
    var lineNumber: Int
    var stackFrames: [String] = []
    var sourceFiles: [String] = []
    var isCrash: Bool = false
    /// true = 属于上一条事件的多行堆栈 / `Caused by:`，不单独计数
    var isContinuation: Bool = false
}

struct LogFileReading: Sendable {
    var url: URL
    var role: LogFileRole
    var sizeBytes: Int64
    var modifiedAt: Date
    /// 文件里实际读到的行数
    var totalLines: Int = 0
    /// 与 totalLines 同义，保留以便视图显示「读取 N 行（已截尾）」
    var linesRead: Int = 0
    var truncated: Bool = false
    var events: [LogEvent] = []
    var parseErrors: Int = 0
}

struct LogAggregate: Sendable {
    var events: [LogEvent] = []
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
    var windowStart: Date?
    var windowEnd: Date?
}

// MARK: - 正则缓存

/// NSRegularExpression 只编译一次：日志按行解析是热路径，逐行编译会慢一个数量级。
fileprivate final class RX {
    let regex: NSRegularExpression?

    init(_ pattern: String, options: NSRegularExpression.Options = []) {
        regex = try? NSRegularExpression(pattern: pattern, options: options)
    }

    func first(in text: String, from location: Int = 0) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        let ns = text as NSString
        let start = max(0, min(location, ns.length))
        guard start < ns.length else { return nil }
        return regex.firstMatch(in: text, options: [], range: NSRange(location: start, length: ns.length - start))
    }

    func replaces(_ text: String, with template: String) -> String {
        guard let regex else { return text }
        let ns = text as NSString
        guard ns.length > 0 else { return text }
        return regex.stringByReplacingMatches(in: text, options: [],
                                              range: NSRange(location: 0, length: ns.length),
                                              withTemplate: template)
    }
}

fileprivate func rxGroup(_ result: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
    guard index < result.numberOfRanges else { return nil }
    let range = result.range(at: index)
    guard range.location != NSNotFound else { return nil }
    let ns = text as NSString
    guard NSMaxRange(range) <= ns.length else { return nil }
    let value = ns.substring(with: range)
    return value.isEmpty ? nil : value
}

/// 时间戳解析用的格式器全部 static 缓存；主路径走分组组装 DateComponents，格式化器只做兜底。
fileprivate enum LogDateFormat {
    static let isoWithZone = makeISO(options: [.withInternetDateTime])
    static let isoWithZoneAndFraction = makeISO(options: [.withInternetDateTime, .withFractionalSeconds])

    static let dateOnly: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    static func isoDate(_ text: String) -> Date? {
        if let date = isoWithZoneAndFraction.date(from: text) { return date }
        if let date = isoWithZone.date(from: text) { return date }
        return nil
    }

    private static func makeISO(options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        return formatter
    }
}

// MARK: - 日志发现

enum LogDiscovery {

    /// 项目内发现 + ~/Library/Logs/<项目名>/ + ~/Library/Logs/DiagnosticReports/*.ips
    static func discover(projectRoot: URL, projectName: String, withinDays: Int, maxFiles: Int) -> [DiscoveredLog] {
        guard maxFiles > 0 else { return [] }
        var unique: [String: DiscoveredLog] = [:]

        func register(_ url: URL) {
            let key = canonicalPath(of: url)
            guard unique[key] == nil else { return }
            let values = attributes(of: url)
            guard values.isFile else { return }
            let modified = values.modifiedAt ?? Date.distantPast
            unique[key] = DiscoveredLog(url: URL(fileURLWithPath: key),
                                        role: role(for: url, in: projectRoot),
                                        sizeBytes: values.sizeBytes,
                                        modifiedAt: modified)
        }

        for url in projectLogCandidates(root: projectRoot) { register(url) }
        for url in libraryLogCandidates(projectName: projectName) { register(url) }
        for url in diagnosticReportCandidates(withinDays: withinDays) { register(url) }

        return unique.values
            .sorted { lhs, rhs in
                if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt > rhs.modifiedAt }
                return lhs.url.path < rhs.url.path
            }
            .prefix(maxFiles)
            .map { $0 }
    }

    static func role(for url: URL, in projectRoot: URL?) -> LogFileRole {
        let name = url.lastPathComponent.lowercased()
        let haystack: String
        if let projectRoot {
            let relative = relativePath(of: url, root: projectRoot)
            haystack = relative == url.path ? url.path.lowercased() : relative.lowercased()
        } else {
            haystack = url.path.lowercased()
        }

        // 崩溃特征优先于 error 字样：DiagnosticReports 的 .ips 名字常同时含两者，归错类会让崩溃整类证据消失
        if url.pathExtension.lowercased() == "ips" || haystack.contains("diagnosticreports") { return .crash }
        if name.contains("crash") { return .crash }
        if name.contains("error") || name.contains("exception") { return .error }
        if name.contains("audit") || name.contains("systemlog") || name.contains("system.log") { return .system }
        if name.contains("build") || name.contains("gradle-worker") || name.contains("npm-debug") { return .build }
        return .application
    }

    static func diagnosticReportsDirectory() -> URL {
        libraryLogsDirectory().appendingPathComponent("DiagnosticReports", isDirectory: true)
    }

    static func projectLibraryLogDirectory(projectName: String) -> URL {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Tcoder" : trimmed
        return libraryLogsDirectory().appendingPathComponent(name, isDirectory: true)
    }

    // MARK: 发现细节

    static let maxDepth = 6
    static let directoryBudget = 4_000
    static let entryBudget = 60_000

    static let skippedDirectoryNames: Set<String> = [
        "node_modules", "build", ".build", ".git", ".svn", "dist", "out", "target", "bin", "obj",
        "DerivedData", "Pods", "Carthage", "venv", ".venv", "__pycache__", "vendor", ".next",
        ".gradle", "xcuserdata",
    ]

    /// 含斜杠的相对路径黑名单（整棵子树跳过）
    static let skippedRelativePaths: [String] = ["Resources/raw"]

    static let logExtensions: Set<String> = ["log", "out"]
    static let crashExtensions: Set<String> = ["ips"]

    /// 名字像日志但实际是二进制 / 压缩产物，别交给行解析器
    static let rejectedExtensions: Set<String> = [
        "zip", "gz", "tgz", "bz2", "xz", "zst", "7z", "dmg", "pkg", "app", "framework", "dylib", "so",
        "a", "o", "class", "jar", "war", "png", "jpg", "jpeg", "gif", "pdf", "icns", "ttf", "otf",
        "woff", "woff2", "mp4", "mov", "db", "db-wal", "db-shm", "sqlite", "sqlite3", "pack", "idx",
        "pyc", "map",
    ]

    private static func projectLogCandidates(root: URL) -> [URL] {
        var result: [URL] = []
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return result }

        struct Frame { var url: URL; var depth: Int }
        var stack: [Frame] = [Frame(url: root, depth: 0)]
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .nameKey]
        var directoriesLeft = directoryBudget
        var entriesLeft = entryBudget

        while let frame = stack.popLast() {
            guard directoriesLeft > 0, entriesLeft > 0 else { break }
            directoriesLeft -= 1
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: frame.url, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                entriesLeft -= 1
                if entriesLeft <= 0 { break }
                let values = try? entry.resourceValues(forKeys: Set(keys))
                // 符号链接既不跟随也不读取：不会成环，也不会顺链接逃到仓库外的资产目录
                if values?.isSymbolicLink == true { continue }

                if values?.isDirectory == true {
                    if frame.depth >= maxDepth { continue }
                    if isSkippedDirectory(entry, root: root) { continue }
                    stack.append(Frame(url: entry, depth: frame.depth + 1))
                    continue
                }
                if values?.isRegularFile == false { continue }
                if isLogFile(entry) { result.append(entry) }
            }
        }
        return result
    }

    private static func libraryLogCandidates(projectName: String) -> [URL] {
        let directory = projectLibraryLogDirectory(projectName: projectName)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .nameKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "log" else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            return values?.isSymbolicLink != true && values?.isRegularFile != false
        }
    }

    private static func diagnosticReportCandidates(withinDays: Int) -> [URL] {
        let directory = diagnosticReportsDirectory()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .nameKey,
                                      .contentModificationDateKey]
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }
        let cutoff: Date? = withinDays > 0 ? Date().addingTimeInterval(-Double(withinDays) * 86_400) : nil
        return entries.filter { url in
            guard url.pathExtension.lowercased() == "ips" else { return false }
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isSymbolicLink != true, values?.isRegularFile != false else { return false }
            guard let cutoff else { return true }
            guard let modified = values?.contentModificationDate else { return false }
            return modified >= cutoff
        }
    }

    private static func isLogFile(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        if rejectedExtensions.contains(ext) { return false }
        if logExtensions.contains(ext) { return true }
        if crashExtensions.contains(ext) { return true }
        let parent = url.deletingLastPathComponent().lastPathComponent.lowercased()
        guard parent == "logs" else { return false }
        // 只有在 Logs/ 目录里 txt 才算日志，避免把满树的 README.txt 吞进来
        if ext == "txt" || ext == "err" || ext == "trace" || ext == "logrotate" { return true }
        return ext.isEmpty
    }

    private static func isSkippedDirectory(_ url: URL, root: URL) -> Bool {
        if skippedDirectoryNames.contains(url.lastPathComponent) { return true }
        let relative = relativePath(of: url, root: root)
        for skipped in skippedRelativePaths where relative == skipped || relative.hasPrefix(skipped + "/") {
            return true
        }
        return false
    }

    private static func relativePath(of url: URL, root: URL) -> String {
        let path = url.path
        let base = root.path
        guard path.hasPrefix(base) else { return path }
        let trimmed = path.dropFirst(base.count)
        return trimmed.hasPrefix("/") ? String(trimmed.dropFirst()) : String(trimmed)
    }

    private static func canonicalPath(of url: URL) -> String {
        // resolvingSymlinksInPath 顺带把 /private/var 这类系统别名归一，去重因此更准
        return url.resolvingSymlinksInPath().path
    }

    private static func libraryLogsDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs", isDirectory: true)
    }

    private struct FileAttributes {
        var sizeBytes: Int64 = 0
        var modifiedAt: Date?
        var isFile: Bool = true
    }

    private static func attributes(of url: URL) -> FileAttributes {
        var result = FileAttributes()
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            result.isFile = false
            return result
        }
        if let number = attrs[.size] as? NSNumber { result.sizeBytes = number.int64Value }
        result.modifiedAt = attrs[.modificationDate] as? Date
        if let type = attrs[.type] as? FileAttributeType, type != .typeRegular { result.isFile = false }
        return result
    }
}

// MARK: - 尾部读取

enum LogReader {

    static func read(_ log: DiscoveredLog, maxBytes: Int, maxLines: Int) -> LogFileReading {
        var reading = LogFileReading(url: log.url, role: log.role, sizeBytes: log.sizeBytes,
                                     modifiedAt: log.modifiedAt)
        guard maxBytes > 0, maxLines > 0 else { return reading }
        guard let handle = try? FileHandle(forReadingFrom: log.url) else { return reading }
        defer { try? handle.close() }

        var size = log.sizeBytes
        if size <= 0, let attrs = try? FileManager.default.attributesOfItem(atPath: log.url.path),
           let number = attrs[.size] as? NSNumber {
            size = number.int64Value
        }
        reading.sizeBytes = size

        // 只读尾段：大文件整读进内存会直接把 App 压挂
        var startOffset: UInt64 = 0
        if size > Int64(maxBytes) {
            startOffset = UInt64(size - Int64(maxBytes))
            reading.truncated = true
        }
        if startOffset > 0 {
            handle.seek(toFileOffset: startOffset)
        }

        // 时间戳缺年份时以文件修改时间为基准而不是「现在」，否则老日志会被推到未来
        var builder = LogEventBuilder(sourcePath: log.url.path, referenceDate: log.modifiedAt, role: log.role)
        var buffer = Data()
        var droppingLeadingPartialLine = startOffset > 0
        var bytesFromDisk = startOffset
        let chunkLength = max(4_096, min(262_144, maxBytes))
        let newline = UInt8(0x0A)
        let carriageReturn = UInt8(0x0D)

        func decode(_ data: Data) -> String {
            if data.isEmpty { return "" }
            if let text = String(data: data, encoding: .utf8) { return text }
            reading.parseErrors += 1
            return String(decoding: data, as: UTF8.self)
        }

        func consume(_ data: Data) {
            var lineData = data
            if lineData.last == carriageReturn { lineData.removeLast() }
            builder.append(decode(lineData))
        }

        func readChunk() -> Data? {
            guard let data = try? handle.read(upToCount: chunkLength) else { return nil }
            return data
        }

        var stoppedByLineCap = false
        while !stoppedByLineCap {
            guard let chunk = readChunk(), !chunk.isEmpty else { break }
            buffer.append(chunk)
            bytesFromDisk += UInt64(chunk.count)

            while let index = buffer.firstIndex(of: newline) {
                let lineData = buffer.subdata(in: buffer.startIndex..<index)
                buffer.removeSubrange(buffer.startIndex...index)
                if droppingLeadingPartialLine {
                    // 截断处的首行是半行，丢掉，不污染签名
                    droppingLeadingPartialLine = false
                    continue
                }
                consume(lineData)
                if builder.lineCount >= maxLines {
                    reading.truncated = true
                    stoppedByLineCap = true
                    break
                }
            }

            if stoppedByLineCap { break }
            if size <= 0, bytesFromDisk >= UInt64(maxBytes) {
                reading.truncated = true
                break
            }
        }

        if !stoppedByLineCap, buffer.isEmpty == false, droppingLeadingPartialLine == false {
            consume(buffer)
        }

        reading.totalLines = builder.lineCount
        reading.linesRead = builder.lineCount
        reading.events = builder.events
        return reading
    }
}

/// 逐行累积事件，负责「多行堆栈归属上一条事件」。
fileprivate struct LogEventBuilder {
    let sourcePath: String
    let referenceDate: Date
    let role: LogFileRole
    var events: [LogEvent] = []
    var lineCount = 0
    var parentIndex: Int? = nil

    mutating func append(_ raw: String) {
        lineCount += 1
        let number = lineCount
        let line = LogLineParser.parseLine(raw, number: number, sourcePath: sourcePath,
                                           referenceDate: referenceDate)

        if let parentIndex,
           LogLineParser.isErrorFamily(events[parentIndex].severity),
           LogLineParser.isStackLine(line.raw) {
            let parentSeverity = events[parentIndex].severity
            let parentIsCrash = events[parentIndex].isCrash
            var event = LogEvent(date: line.date, severity: parentSeverity, rawLine: line.raw,
                                 message: line.message, sourceLogPath: sourcePath, lineNumber: number,
                                 isCrash: parentIsCrash, isContinuation: true)
            if let frame = line.stackFrame {
                event.stackFrames = [frame]
                events[parentIndex].stackFrames.append(frame)
            }
            if let file = line.sourceFile {
                event.sourceFiles = [file]
                events[parentIndex].sourceFiles.append(file)
            }
            events.append(event)
            return
        }

        guard let severity = line.severity else { return }
        let isCrash = severity == .crash || (role == .crash && LogLineParser.looksLikeCrash(line.raw))
        var event = LogEvent(date: line.date, severity: severity, rawLine: line.raw, message: line.message,
                             sourceLogPath: sourcePath, lineNumber: number, isCrash: isCrash)
        if let frame = line.stackFrame { event.stackFrames = [frame] }
        if let file = line.sourceFile { event.sourceFiles = [file] }
        events.append(event)
        parentIndex = events.count - 1
    }
}

// MARK: - 行解析

enum LogLineParser {

    // 时间戳族：ISO / 空格分隔 / log4j 逗号毫秒 / syslog / epoch。捕获组编号见下方常量注释。
    // groups: 1年 2月 3日 4时 5分 6秒 7小数秒 8时区
    private static let stamp = RX(#"(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(?:[.,](\d{1,9}))?(Z|[+-]\d{1,2}(?::?\d{2})?)?"#)
    // groups: 1月名 2日 3时 4分 5秒 6小数秒
    private static let syslogStamp = RX(#"([A-Z][a-z]{2})\s{1,2}(\d{1,2})\s+(\d{1,2}):(\d{2}):(\d{2})(?:[.,](\d{1,3}))?"#)
    private static let epochStamp = RX(#"(?<![\d.])(\d{10,13})(?![\d.])"#)
    private static let dateOnlyStamp = RX(#"\b\d{4}-\d{2}-\d{2}\b"#)
    private static let bracketPrefix = RX(#"^[\s\[(<]{0,2}[\[(<](?!(?:ERROR|WARN|WARNING|INFO|DEBUG|TRACE|FATAL|SEVERE|CRITICAL|EXCEPTION|NOTICE)\b)[^\]\)>]{1,40}[\]\)>][ \t]*[:\-|>?]{0,2}[ \t]*"#, options: .caseInsensitive)

    // 级别
    private static let crashMarker = RX(#"\b(?:SIGSEGV|SIGABRT|SIGBUS|SIGILL|SIGTRAP|EXC_BAD_ACCESS|EXC_CRASH)\b|\bFatal error:|\bprecondition failure\b|\bFatal Python error\b|\bThread[ \t]+\d+[ \t]+Crashed\b"#)
    private static let anchoredLevel = RX(#"^[\s\[<(]{0,4}(ERROR|FATAL|SEVERE|CRITICAL|EXCEPTION|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)\b"#, options: .caseInsensitive)
    private static let anchoredShortLevel = RX(#"^[\s\[<(]{0,3}([EWIDTFVS])/[\w.\-\[]"#, options: .caseInsensitive)
    private static let levelKeyValue = RX(#"\blevel[ \t]*[=:][ \t]*"?(trace|debug|info|notice|warn|warning|error|fatal|critical|exception)"?(?![\w-])"#, options: .caseInsensitive)
    private static let levelWordAnywhere = RX(#"\b(FATAL|CRITICAL|EXCEPTION|SEVERE|ERROR|WARNING|WARN|NOTICE|INFO|DEBUG|TRACE)\b(?![\w-])"#, options: .caseInsensitive)
    private static let tracebackMarker = RX(#"\bTraceback\b"#)
    private static let causedByMarker = RX(#"\bCaused by:"#)
    private static let crashedThreadHeader = RX(#"^\s*Crashed[ \t]+Thread:[ \t]*\d+\s*$"#, options: .caseInsensitive)

    // 堆栈帧
    private static let javaFrame = RX(#"\bat\s+[A-Za-z_$][\w$<>$.]*\.[\w$<>$.]+\([\w$.]*\.(?:java|kt|kts|scala|groovy)(?![\w-])(?::\d+)?\)"#)
    private static let genericAtFrame = RX(#"(?:^|[\t ])at\s+[\w$<>.$,()\[\]]+\([\w$.]*\.[A-Za-z]{2,5}(?::\d+)?\)"#)
    private static let nativeFrame = RX(#"#\d+[ \t]+0x[0-9a-fA-F_]+[ \t]+in[ \t]+\S+"#)
    private static let pythonFrame = RX(#"File[ \t]*"[^"]+",[ \t]*line[ \t]+\d+(?:,[ \t]*in[ \t]+\S+)?"#)
    private static let hexFrame = RX(#"\b0x[0-9a-fA-F]{6,}\b"#)
    private static let swiftSymbolFrame = RX("([A-Za-z_$][\\w$]*\\.){2,}[\\w$]+\\s*:\\s*[\\w$()\\[\\],.&' \u{2039}\u{203a}]+")
    private static let fileLineFrame = RX(#"[\w$./\-]+\.(?:java|kt|kts|swift|py|go|ts|tsx|js|jsx|vue|scala|rb|rs)(?![\w-])(?::\d+)?"#)
    private static let sourceFileFromFrame = RX(#"\(([\w$.\-/]+\.(?:java|kt|kts|swift|py|go|ts|tsx|js|jsx|vue|scala|rb|rs))(?![\w-])(?::(\d+))?\)"#)
    private static let quotedPath = RX(#""([^"\n]+)""#)

    /// 归属判定用：这些形态的行挂在上一条 error 级事件上
    private static let stackLinePatterns: [RX] = [
        RX(#"^(?:[\t ]|\\t)+at[ \t]+[\w$<>.$]"#),                        // "\tat com.foo.Bar.baz(...)"
        RX(#"^(?:[\t ]|\\t)*at[ \t]+[A-Za-z_$][\w$<>$.]*\("#),           // "at com.foo.Bar.baz(...)"
        RX(#"^(?:[\t ]|\\t)*\.\.\.[ \t]+\d+[ \t]+more"#, options: .caseInsensitive),  // "... 12 more"
        RX(#"^\s*Caused by:[ \t]+"#),                                     // Java 异常链
        RX(#"^\s*Suppressed:[ \t]+"#),
        RX(#"^\s*#\d+[ \t]+0x[0-9a-fA-F_]+"#),                             // lldb / crash 帧 "#0 0x..."
        RX(#"^\s*(?:\(\?\?\)\s*)?0x[0-9a-fA-F]{6,}\b"#),                  // 裸地址帧
        RX(#"^\s*File[ \t]*"[^"]+",[ \t]*line[ \t]+\d+"#),                // Python 帧
        RX(#"^\s*[\w$./\-]+\.(?:java|kt|kts|swift|py|go|ts|tsx|js|jsx|vue|scala|rb|rs|m|mm|c|cpp)(?![\w-]):\d+"#),
        RX(#"^\s*[\w$./\-(\)\[\]<>,]+\s*\+\s*0x[0-9a-fA-F]{2,}"#),         // Go / C 符号偏移帧 "pkg.fn(0x1) + 0x20"
        RX(#"^\s+[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*){2,}\s*:"#),        // 缩进 + Swift demangled 符号
    ]

    private static let monthNumbers: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    // MARK: 单行

    static func parseLine(_ raw: String, number: Int, sourcePath: String, referenceDate: Date) -> ParsedLogLine {
        let cleaned = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let stripped = droppingTimestampPrefix(from: cleaned)
        let detected = detectSeverity(cleaned)
        // .ips 里 "Crashed Thread: 5" 这类无级别行只有结合文件角色才认得出来
        let severity = detected ?? (isCrashReportPath(sourcePath) ? plainCrashSeverity(in: cleaned) : nil)

        return ParsedLogLine(number: number,
                             raw: cleaned,
                             date: parseTimestamp(cleaned, referenceDate: referenceDate),
                             severity: severity,
                             message: composeMessage(from: stripped),
                             stackFrame: stackFrame(in: cleaned),
                             sourceFile: sourceFile(in: cleaned))
    }

    // MARK: 时间戳

    /// 先在行首 80 字符内试固定格式（前缀优先），再退回全串扫描。
    static func parseTimestamp(_ text: String, referenceDate: Date) -> Date? {
        let nsLength = (text as NSString).length
        let prefixLimit = min(nsLength, 80)
        if let date = timestamp(in: text, prefixLimit: prefixLimit, referenceDate: referenceDate) { return date }
        if let date = timestamp(in: text, prefixLimit: nil, referenceDate: referenceDate) { return date }
        return formatterFallback(in: text, prefixLimit: prefixLimit)
    }

    private static func timestamp(in text: String, prefixLimit: Int?, referenceDate: Date) -> Date? {
        if let date = isoStyleDate(in: text, prefixLimit: prefixLimit) { return date }
        if let date = syslogDate(in: text, prefixLimit: prefixLimit, referenceDate: referenceDate) { return date }
        if let date = epochDate(in: text, prefixLimit: prefixLimit) { return date }
        return plainDateOnly(in: text, prefixLimit: prefixLimit)
    }

    /// groups: 1年 2月 3日 4时 5分 6秒 7小数秒 8时区
    private static func isoStyleDate(in text: String, prefixLimit: Int?) -> Date? {
        guard let result = stamp.first(in: text), withinPrefix(result.range.location, prefixLimit) else { return nil }
        guard
            let year = Int(rxGroup(result, 1, in: text) ?? ""),
            let month = Int(rxGroup(result, 2, in: text) ?? ""),
            let day = Int(rxGroup(result, 3, in: text) ?? ""),
            let hour = Int(rxGroup(result, 4, in: text) ?? ""),
            let minute = Int(rxGroup(result, 5, in: text) ?? ""),
            let second = Int(rxGroup(result, 6, in: text) ?? "")
        else { return nil }

        let nanosecond = nanoseconds(from: rxGroup(result, 7, in: text))
        let zone: TimeZone?
        if let token = rxGroup(result, 8, in: text) {
            zone = timeZone(for: token)
        } else {
            zone = TimeZone.current
        }
        return date(year: year, month: month, day: day, hour: hour, minute: minute,
                    second: second, nanosecond: nanosecond, timeZone: zone)
    }

    /// groups: 1月名 2日 3时 4分 5秒 6小数秒
    /// syslog `Sep 19 08:12:33` 无年份：按 referenceDate 的年份组装，落在未来就整年退一格。
    private static func syslogDate(in text: String, prefixLimit: Int?, referenceDate: Date) -> Date? {
        guard let result = syslogStamp.first(in: text), withinPrefix(result.range.location, prefixLimit) else { return nil }
        guard
            let monthToken = rxGroup(result, 1, in: text),
            let month = monthNumbers[monthToken],
            let day = Int(rxGroup(result, 2, in: text) ?? ""),
            let hour = Int(rxGroup(result, 3, in: text) ?? ""),
            let minute = Int(rxGroup(result, 4, in: text) ?? ""),
            let second = Int(rxGroup(result, 5, in: text) ?? "")
        else { return nil }

        let nanosecond = nanoseconds(from: rxGroup(result, 6, in: text))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let year = calendar.component(.year, from: referenceDate)
        guard let candidate = date(year: year, month: month, day: day, hour: hour, minute: minute,
                                   second: second, nanosecond: nanosecond, timeZone: .current) else { return nil }
        guard candidate > referenceDate else { return candidate }
        return date(year: year - 1, month: month, day: day, hour: hour, minute: minute,
                    second: second, nanosecond: nanosecond, timeZone: .current)
    }

    /// epoch 只认行首 24 字符内的独立 token：正文里的 10 位订单号不该被当成时间。
    private static func epochDate(in text: String, prefixLimit: Int?) -> Date? {
        guard let limit = prefixLimit else { return nil }
        guard let result = epochStamp.first(in: text), withinPrefix(result.range.location, min(limit, 2)) else { return nil }
        guard let token = rxGroup(result, 1, in: text), let value = Double(token) else { return nil }
        let seconds: Double
        switch token.count {
        case 10: seconds = value
        case 13: seconds = value / 1_000
        default: return nil
        }
        // 10 位数字也可能是订单号 / 构建号，用 2000-2100 的合理性窗口挡掉
        guard seconds >= 946_684_800, seconds <= 4_102_444_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func plainDateOnly(in text: String, prefixLimit: Int?) -> Date? {
        guard let result = dateOnlyStamp.first(in: text), withinPrefix(result.range.location, prefixLimit) else { return nil }
        let token = (text as NSString).substring(with: result.range)
        return LogDateFormat.dateOnly.date(from: token)
    }

    /// 最后一道兜底：把行首可能的时间戳片段交给缓存好的 ISO8601 格式化器。
    private static func formatterFallback(in text: String, prefixLimit: Int) -> Date? {
        let ns = text as NSString
        guard ns.length > 8 else { return nil }
        let head = ns.substring(to: min(ns.length, prefixLimit)).trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = [head, head.trimmingCharacters(in: CharacterSet(charactersIn: "[]()<>"))]
        for candidate in candidates {
            if candidate.count >= 10, candidate.contains("-"), candidate.contains(":") {
                if let date = LogDateFormat.isoDate(candidate) { return date }
            }
        }
        return nil
    }

    private static func nanoseconds(from fraction: String?) -> Int {
        guard let fraction, fraction.isEmpty == false else { return 0 }
        let digits = String(fraction.prefix(9))
        guard let value = Int(digits) else { return 0 }
        return value * Int(pow(10.0, Double(9 - digits.count)))
    }

    private static func timeZone(for token: String) -> TimeZone? {
        if token.uppercased() == "Z" { return TimeZone(secondsFromGMT: 0) }
        let sign: Int = token.hasPrefix("-") ? -1 : 1
        let digits = token.drop(while: { $0 == "+" || $0 == "-" }).filter { $0.isNumber }
        guard digits.isEmpty == false else { return nil }
        var hours = 0
        var minutes = 0
        if digits.count >= 4 {
            hours = Int(digits.prefix(2)) ?? 0
            minutes = Int(digits.dropFirst(2).prefix(2)) ?? 0
        } else {
            hours = Int(String(digits.prefix(min(2, digits.count)))) ?? 0
            if digits.count > 2 { minutes = Int(digits.dropFirst(2)) ?? 0 }
        }
        return TimeZone(secondsFromGMT: sign * (hours * 3_600 + minutes * 60))
    }

    private static func date(year: Int, month: Int, day: Int, hour: Int, minute: Int, second: Int,
                             nanosecond: Int, timeZone: TimeZone?) -> Date? {
        guard year >= 1_970, year <= 2_999, (1...12).contains(month), (1...31).contains(day),
              hour <= 23, minute <= 59, second <= 60 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        if let timeZone { calendar.timeZone = timeZone }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        components.nanosecond = nanosecond
        return calendar.date(from: components)
    }

    private static func withinPrefix(_ location: Int, _ limit: Int?) -> Bool {
        guard let limit else { return true }
        return location <= limit
    }

    // MARK: 级别

    /// 匹配前先剥时间戳前缀，并且只在行首 240 字符内按单词边界匹配：
    /// 既躲开 `errorCount=0` 这类误判，也让「行首显式级别前缀」优先于正文里出现的崩溃词。
    static func detectSeverity(_ raw: String) -> LogSeverity? {
        let cleaned = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        let stripped = droppingTimestampPrefix(from: cleaned)
        let window = String(stripped.prefix(240))
        guard window.isEmpty == false else { return nil }

        let prefixHit = anchoredLevelHit(in: window)
        if let crashLocation = crashMarker.first(in: window)?.range.location {
            if let hit = prefixHit, hit.location < crashLocation { return hit.severity }
            return .crash
        }
        if let hit = prefixHit { return hit.severity }
        if let hit = levelKeyValue.first(in: window),
           let token = rxGroup(hit, 1, in: window),
           let severity = severity(forLevelWord: token) {
            return severity
        }
        return bodyKeywordSeverity(in: window)
    }

    private static func anchoredLevelHit(in text: String) -> (location: Int, severity: LogSeverity)? {
        if let result = anchoredLevel.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forLevelWord: token) {
            return (result.range.location, severity)
        }
        if let result = anchoredShortLevel.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forShortCode: token) {
            return (result.range.location, severity)
        }
        if let result = levelKeyValue.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forLevelWord: token) {
            return (result.range.location, severity)
        }
        return nil
    }

    private static func bodyKeywordSeverity(in text: String) -> LogSeverity? {
        var best: (location: Int, severity: LogSeverity)?

        func consider(_ location: Int?, _ severity: LogSeverity) {
            guard let location else { return }
            guard let current = best else {
                best = (location, severity)
                return
            }
            if location < current.location || (location == current.location && rank(severity) > rank(current.severity)) {
                best = (location, severity)
            }
        }

        if let result = levelWordAnywhere.first(in: text),
           let token = rxGroup(result, 1, in: text),
           let severity = severity(forLevelWord: token) {
            consider(result.range.location, severity)
        }
        consider(tracebackMarker.first(in: text)?.range.location, .exception)
        // `Caused by:` 按原始大小写匹配，避免误吞正文里的 "caused by" 散文
        consider(causedByMarker.first(in: text)?.range.location, .exception)
        return best?.severity
    }

    static func severity(forLevelWord word: String) -> LogSeverity? {
        switch word.uppercased() {
        case "ERROR", "SEVERE", "CRITICAL": return .error
        case "FATAL": return .fatal
        case "EXCEPTION": return .exception
        case "WARNING", "WARN": return .warning
        case "NOTICE", "INFO": return .info
        case "DEBUG", "VERBOSE": return .debug
        case "TRACE": return .trace
        default: return nil
        }
    }

    private static func severity(forShortCode code: String) -> LogSeverity? {
        switch code.uppercased() {
        case "E": return .error
        case "W": return .warning
        case "I": return .info
        case "D", "V": return .debug
        case "T": return .trace
        case "F", "C": return .fatal
        default: return nil
        }
    }

    static func rank(_ severity: LogSeverity) -> Int {
        switch severity {
        case .trace: return 0
        case .debug: return 1
        case .info: return 2
        case .warning: return 3
        case .error: return 4
        case .exception: return 5
        case .fatal: return 6
        case .crash: return 7
        }
    }

    static func isErrorFamily(_ severity: LogSeverity) -> Bool {
        rank(severity) >= rank(.error)
    }

    static func looksLikeCrash(_ raw: String) -> Bool {
        crashMarker.first(in: raw) != nil
    }

    private static func plainCrashSeverity(in text: String) -> LogSeverity? {
        crashedThreadHeader.first(in: text) != nil ? .crash : nil
    }

    private static func isCrashReportPath(_ path: String) -> Bool {
        let lower = path.lowercased()
        return lower.hasSuffix(".ips") || lower.contains("diagnosticreports")
    }

    // MARK: 前缀剥离

    /// 剥掉行首的时间戳以及紧随其后的 `[main]` / `<Info>` 之类的线程/模块标签。
    static func droppingTimestampPrefix(from text: String) -> String {
        guard let result = leadingStampMatch(in: text) else { return text }
        let ns = text as NSString
        var cut = NSMaxRange(result.range)
        guard cut <= ns.length else { return text }
        cut = skipSeparators(ns, from: cut, limit: 6)
        var rest = ns.substring(from: cut)
        for _ in 0..<2 {
            guard let tag = bracketPrefix.first(in: rest) else { break }
            let restNs = rest as NSString
            let end = skipSeparators(restNs, from: NSMaxRange(tag.range), limit: 4)
            guard end <= restNs.length else { break }
            rest = restNs.substring(from: end)
        }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func skipSeparators(_ ns: NSString, from location: Int, limit: Int) -> Int {
        var cursor = location
        var skipped = 0
        while cursor < ns.length, skipped < limit {
            let character = ns.substring(with: NSRange(location: cursor, length: 1))
            if "])>-:|, \t".contains(character) {
                cursor += 1
                skipped += 1
            } else {
                break
            }
        }
        return cursor
    }

    /// 只认真正位于行首的时间戳（起始位置 <= 4），否则会把正文吃掉。
    private static func leadingStampMatch(in text: String) -> NSTextCheckingResult? {
        var best: NSTextCheckingResult?
        for pattern in [stamp, syslogStamp, epochStamp, dateOnlyStamp] {
            guard let result = pattern.first(in: text), result.range.location <= 4 else { continue }
            if let current = best {
                if result.range.location < current.range.location { best = result }
            } else {
                best = result
            }
        }
        return best
    }

    private static func composeMessage(from stripped: String) -> String {
        var text = stripped
        if let result = anchoredLevel.first(in: text) {
            let ns = text as NSString
            let cut = skipSeparators(ns, from: NSMaxRange(result.range), limit: 4)
            if cut <= ns.length { text = ns.substring(from: cut) }
        } else if let result = anchoredShortLevel.first(in: text) {
            let ns = text as NSString
            let cut = min(NSMaxRange(result.range), ns.length)
            text = ns.substring(from: cut)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty == false { return trimmed }
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: 归一化与签名

    // 归一化用的正则全部 static：这些函数按行调用，逐行编译正则会把整个分析拖慢一个数量级。
    private static let collapseWhitespace = RX(#"\s+"#)
    private static let uuidPattern = RX(#"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b"#)
    private static let hexPattern = RX(#"\b0[xX][0-9a-fA-F]+\b"#)
    /// 十六进制先落成不含数字的占位，避免随后「数字 -> N」把 `0xN` 里的 0 再吃掉一次
    private static let hexPlaceholder = "<hex>"
    private static let windowsPathPattern = RX(#"[A-Za-z]:[\\/][^\s"'`]*"#)
    private static let unixPathPattern = RX(#"(?:/[A-Za-z0-9._$@~+-]+){2,}/?"#)
    private static let singleQuotedPattern = RX(#"'[^'\n]*'"#)
    private static let doubleQuotedPattern = RX(#""[^"\n]*""#)
    private static let backtickQuotedPattern = RX(#"`[^`\n]*`"#)
    private static let dottedNumberPattern = RX(#"\b\d+(?:[._-]\d+)+\b"#)
    private static let digitsPattern = RX(#"\d+"#)
    private static let repeatedPathPattern = RX(#"<path>(?:[ /]+<path>)+"#)
    private static let repeatedStringPattern = RX(#"(?:<str>[ ,]*<str>)+"#)

    /// 顺序：折叠空白 -> uuid -> 十六进制 -> 路径 -> 引号串 -> 数字 -> 合并重复占位 -> 截断 240。
    /// 数字放在十六进制 / UUID 之后，否则 `0x1F4A` 会被拆成碎片而不是稳定的 `0xN`。
    static func normalizeMessage(_ message: String) -> String {
        var text = collapseWhitespace.replaces(message, with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.isEmpty == false else { return "" }

        text = uuidPattern.replaces(text, with: "<uuid>")
        text = hexPattern.replaces(text, with: hexPlaceholder)
        text = windowsPathPattern.replaces(text, with: "<path>")
        text = unixPathPattern.replaces(text, with: "<path>")
        text = singleQuotedPattern.replaces(text, with: "<str>")
        text = doubleQuotedPattern.replaces(text, with: "<str>")
        text = backtickQuotedPattern.replaces(text, with: "<str>")
        text = dottedNumberPattern.replaces(text, with: "N")
        text = digitsPattern.replaces(text, with: "N")
        text = repeatedPathPattern.replaces(text, with: "<path>")
        text = repeatedStringPattern.replaces(text, with: "<str>")
        text = text.replacingOccurrences(of: hexPlaceholder, with: "0xN")
        text = collapseWhitespace.replaces(text, with: " ")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if text.count > 240 { text = String(text.prefix(240)) }
        return text
    }

    private static let exceptionClass = RX(#"[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+(?:Exception|Error|Throwable)\b"#)
    private static let fatalErrorMessage = RX(#"\bFatal error\b"#)
    private static let excBadAccess = RX(#"\bEXC_BAD_ACCESS\b"#)
    private static let excCrashToken = RX(#"\bEXC_CRASH\b"#)
    private static let tracebackLabel = RX(#"\bTraceback \(most recent call last\)"#)
    private static let threadCrashed = RX(#"\bThread[ \t]+\d+[ \t]+Crashed\b"#)
    private static let leadingSeparators = RX(#"^[\s:,;>\-|]+"#)

    /// 非 error 级返回 nil（不进聚类）。签名 = 「主 token + 归一化消息」。
    static func signature(for line: ParsedLogLine) -> String? {
        guard let severity = line.severity, isErrorFamily(severity) else { return nil }
        let haystack = line.message.isEmpty ? line.raw : line.message
        let token = mainToken(in: haystack) ?? mainToken(in: line.raw) ?? severity.rawValue

        // 把 token 本身从消息里挖掉再归一化，否则签名会把它重复两遍
        var remainder = haystack
        if let range = remainder.range(of: token) { remainder.removeSubrange(range) }
        remainder = leadingSeparators.replaces(remainder, with: "")
        let normalized = normalizeMessage(remainder)
        if normalized.isEmpty { return token }
        return "\(token): \(normalized)"
    }

    /// 主 token 依次取：Java 全限定异常类名 -> Traceback -> Thread N Crashed -> Fatal error -> EXC_*
    static func mainToken(in text: String) -> String? {
        if let result = exceptionClass.first(in: text), let token = rxGroup(result, 0, in: text) { return token }
        if let result = tracebackLabel.first(in: text), let token = rxGroup(result, 0, in: text) { return token }
        if let result = threadCrashed.first(in: text), let token = rxGroup(result, 0, in: text) {
            return collapseWhitespace.replaces(token, with: " ")
        }
        if fatalErrorMessage.first(in: text) != nil { return "Fatal error" }
        if excBadAccess.first(in: text) != nil { return "EXC_BAD_ACCESS" }
        if excCrashToken.first(in: text) != nil { return "EXC_CRASH" }
        return nil
    }

    // MARK: 堆栈

    static func stackFrame(in raw: String) -> String? {
        let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        var best: (location: Int, value: String)?
        for candidate in [javaFrame, nativeFrame, pythonFrame, genericAtFrame] {
            guard let result = candidate.first(in: text), let value = rxGroup(result, 0, in: text) else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.isEmpty == false else { continue }
            if let current = best {
                if result.range.location < current.location { best = (result.range.location, trimmed) }
            } else {
                best = (result.range.location, trimmed)
            }
        }
        if let best { return best.value }

        // demangled 符号帧要求缩进：否则 `pkg.Class: message` 这类 Java 正文会被误认成帧
        if text.hasPrefix(" ") || text.hasPrefix("\t") || text.hasPrefix("\\t"),
           let result = swiftSymbolFrame.first(in: text), let value = rxGroup(result, 0, in: text) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty == false { return String(trimmed.prefix(200)) }
        }
        // macOS 符号化帧形如 `func() in binary (0x1..)`：只有同时含地址与 ` in ` 才认
        if hexFrame.first(in: text) != nil, text.contains(" in ") {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return String(trimmed.prefix(200))
        }
        return nil
    }

    /// 只取 basename：绝对路径会把用户目录结构泄漏进摘要与 UI。
    static func sourceFile(in raw: String) -> String? {
        let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        if let result = sourceFileFromFrame.first(in: text), let token = rxGroup(result, 1, in: text) {
            return lastPathComponent(of: token)
        }
        if let result = pythonFrame.first(in: text) {
            let ns = text as NSString
            let frame = ns.substring(with: result.range)
            if let quoted = quotedPath.first(in: frame), let path = rxGroup(quoted, 1, in: frame) {
                return lastPathComponent(of: path)
            }
        }
        if let result = fileLineFrame.first(in: text), let token = rxGroup(result, 0, in: text) {
            return lastPathComponent(of: token)
        }
        return nil
    }

    private static func lastPathComponent(of token: String) -> String? {
        var value = token
        // 连续剥掉尾部的 `:123` `:42` 行列号，只留文件名
        while let range = value.range(of: ":", options: .backwards),
              value[range.upperBound...].isEmpty == false,
              value[range.upperBound...].allSatisfy({ $0.isNumber }) {
            value = String(value[..<range.lowerBound])
        }
        let name = value.split(separator: "/").last.map(String.init) ?? value
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleaned.isEmpty == false, cleaned.contains(".") else { return nil }
        return cleaned
    }

    /// 多行堆栈归属：紧跟 error / exception / fatal / crash 事件之后的连续帧行。
    static func isStackLine(_ raw: String) -> Bool {
        let text = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return false }
        for pattern in stackLinePatterns where pattern.first(in: text) != nil { return true }
        return false
    }
}

// MARK: - 聚合与聚类

enum LogAggregator {

    static func aggregate(readings: [LogFileReading], extraEvents: [LogEvent], topLimit: Int) -> LogAggregate {
        var result = LogAggregate()
        // 真实读到的行数，不是估算值
        result.totalLinesScanned = readings.reduce(0) { $0 + $1.totalLines }

        var events: [LogEvent] = []
        for reading in readings { events.append(contentsOf: reading.events) }
        events.append(contentsOf: extraEvents)
        events = deduplicated(events)
        result.events = events

        for event in events where event.isContinuation == false {
            switch event.severity {
            case .error: result.errorCount += 1
            case .exception: result.exceptionCount += 1
            case .warning: result.warningCount += 1
            case .fatal: result.fatalCount += 1
            case .info: result.infoLineCount += 1
            case .trace, .debug: break
            case .crash: break
            }
            if event.severity == .crash || event.isCrash { result.crashCount += 1 }
        }

        let dated = events.compactMap { $0.date }
        result.windowStart = dated.min()
        result.windowEnd = dated.max()

        let signalEvents = events.filter { $0.isContinuation == false && signature(for: $0) != nil }
        result.topErrors = cluster(events: signalEvents, limit: topLimit)
        result.trend = buckets(for: events)
        result.affectedFiles = affectedFiles(for: events, limit: 10)
        return result
    }

    static func cluster(events: [LogEvent], limit: Int) -> [ErrorCluster] {
        guard limit > 0 else { return [] }
        // 只保留带签名的非 continuation 事件（调用方也可能直接扔全量事件过来）
        var keyed: [(signature: String, event: LogEvent)] = []
        for event in events where event.isContinuation == false {
            guard let sig = signature(for: event) else { continue }
            keyed.append((sig, event))
        }
        guard keyed.isEmpty == false else { return [] }

        // 先按 (signature, path, lineNumber) 做一次全序，组内「第一条事件」的选取才与字典遍历顺序无关
        keyed.sort { lhs, rhs in
            if lhs.signature != rhs.signature { return lhs.signature < rhs.signature }
            if lhs.event.sourceLogPath != rhs.event.sourceLogPath {
                return lhs.event.sourceLogPath < rhs.event.sourceLogPath
            }
            return lhs.event.lineNumber < rhs.event.lineNumber
        }

        var keys: [String] = []
        var groups: [String: [LogEvent]] = [:]
        for pair in keyed {
            if groups[pair.signature] == nil { keys.append(pair.signature) }
            groups[pair.signature, default: []].append(pair.event)
        }

        var clusters: [ErrorCluster] = []
        for key in keys {
            guard let group = groups[key], let item = makeCluster(signature: key, events: group) else { continue }
            clusters.append(item)
        }

        // count 降序 -> lastSeen 新到旧 -> signature 升序，构成全序，输出因此确定
        return clusters
            .sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                let left = lhs.lastSeen ?? Date.distantPast
                let right = rhs.lastSeen ?? Date.distantPast
                if left != right { return left > right }
                return lhs.signature < rhs.signature
            }
            .prefix(limit)
            .map { $0 }
    }

    static func buckets(for events: [LogEvent]) -> [LogBucket] {
        struct DayCount {
            var errors = 0
            var warnings = 0
            var exceptions = 0
            var crashes = 0
        }
        var table: [Date: DayCount] = [:]

        for event in events {
            guard event.isContinuation == false, let date = event.date else { continue }
            let day = Calendar.current.startOfDay(for: date)
            var value = table[day] ?? DayCount()
            switch event.severity {
            case .error: value.errors += 1
            case .warning: value.warnings += 1
            case .exception: value.exceptions += 1
            case .crash, .fatal: value.crashes += 1
            case .trace, .debug, .info: continue
            }
            table[day] = value
        }

        return table.keys.sorted().map { day in
            let value = table[day] ?? DayCount()
            return LogBucket(date: day,
                             errors: value.errors,
                             warnings: value.warnings,
                             exceptions: value.exceptions,
                             crashes: value.crashes)
        }
    }

    static func affectedFiles(for events: [LogEvent], limit: Int) -> [String: Int] {
        guard limit > 0 else { return [:] }
        var counts: [String: Int] = [:]
        // continuation 事件的帧已经并进父事件了，所以只看非 continuation 就够，不会重复计数
        for event in events where event.isContinuation == false {
            for file in event.sourceFiles where file.isEmpty == false {
                counts[file, default: 0] += 1
            }
        }
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        var result: [String: Int] = [:]
        for pair in sorted.prefix(limit) { result[pair.key] = pair.value }
        return result
    }

    // MARK: 细节

    private static func deduplicated(_ events: [LogEvent]) -> [LogEvent] {
        var seen = Set<String>()
        var result: [LogEvent] = []
        for event in events.sorted(by: { eventOrder($0, $1) }) {
            // lineNumber == 0 是外部子代理合成的事件，没有可靠行号可比，原样保留
            guard event.lineNumber > 0 else {
                result.append(event)
                continue
            }
            let key = "\(event.sourceLogPath)#\(event.lineNumber)"
            if seen.contains(key) { continue }
            seen.insert(key)
            result.append(event)
        }
        return result
    }

    private static func eventOrder(_ lhs: LogEvent, _ rhs: LogEvent) -> Bool {
        if lhs.sourceLogPath != rhs.sourceLogPath { return lhs.sourceLogPath < rhs.sourceLogPath }
        return lhs.lineNumber < rhs.lineNumber
    }

    private static func makeCluster(signature: String, events: [LogEvent]) -> ErrorCluster? {
        guard let first = events.first else { return nil }

        var severity = first.severity
        var dates: [Date] = []
        var fileCounts: [String: Int] = [:]
        var samples: [String] = []
        var frames: [String] = []

        for (index, event) in events.enumerated() {
            if rank(event.severity) > rank(severity) { severity = event.severity }
            if let date = event.date { dates.append(date) }
            for file in event.sourceFiles where file.isEmpty == false {
                fileCounts[file, default: 0] += 1
            }
            if samples.count < 3 { samples.append(oneLine(event.rawLine, limit: 300)) }
            // 前两条事件各自的前 3 个帧
            if index < 2 { frames.append(contentsOf: event.stackFrames.prefix(3)) }
        }

        let sourceFile: String
        if let leading = mostFrequent(fileCounts) {
            sourceFile = leading
        } else if let token = LogLineParser.mainToken(in: signature) {
            sourceFile = token
        } else {
            sourceFile = "未知"
        }

        return ErrorCluster(signature: signature,
                            displayMessage: oneLine(first.message.isEmpty ? first.rawLine : first.message, limit: 200),
                            count: events.count,
                            firstSeen: dates.min(),
                            lastSeen: dates.max(),
                            sourceFile: sourceFile,
                            severity: severity,
                            sampleLines: samples,
                            stackTopFrames: Array(frames.prefix(6)))
    }

    private static func rank(_ severity: LogSeverity) -> Int { LogLineParser.rank(severity) }

    private static func mostFrequent(_ counts: [String: Int]) -> String? {
        guard counts.isEmpty == false else { return nil }
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        return sorted.first?.key
    }

    private static func oneLine(_ text: String, limit: Int) -> String {
        let value = text.replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if value.count <= limit { return value }
        return String(value.prefix(limit))
    }

    /// 由事件反构造解析行，复用同一套签名规则（崩溃报告子代理也走这条路）。
    static func signature(for event: LogEvent) -> String? {
        var line = ParsedLogLine(number: event.lineNumber, raw: event.rawLine, date: event.date,
                                 severity: event.severity, message: event.message,
                                 stackFrame: event.stackFrames.first, sourceFile: event.sourceFiles.first)
        if line.message.isEmpty { line.message = oneLine(line.raw, limit: 300) }
        return LogLineParser.signature(for: line)
    }
}
