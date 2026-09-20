//
// 归一化、签名、堆栈帧识别与错误聚类
//
// 从 LogParsing.swift 拆出：只为控制单文件长度，语义与拆分前完全一致。
//
import Foundation

extension LogLineParser {
    // MARK: 归一化与签名

    // 归一化用的正则全部 static：这些函数按行调用，逐行编译正则会把整个分析拖慢一个数量级。
    static let collapseWhitespace = RX(#"\s+"#)
    static let uuidPattern = RX(#"\b[0-9a-fA-F]{8}-(?:[0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}\b"#)
    static let hexPattern = RX(#"\b0[xX][0-9a-fA-F]+\b"#)
    /// 十六进制先落成不含数字的占位，避免随后「数字 -> N」把 `0xN` 里的 0 再吃掉一次
    static let hexPlaceholder = "<hex>"
    static let windowsPathPattern = RX(#"[A-Za-z]:[\\/][^\s"'`]*"#)
    static let unixPathPattern = RX(#"(?:/[A-Za-z0-9._$@~+-]+){2,}/?"#)
    static let singleQuotedPattern = RX(#"'[^'\n]*'"#)
    static let doubleQuotedPattern = RX(#""[^"\n]*""#)
    static let backtickQuotedPattern = RX(#"`[^`\n]*`"#)
    static let dottedNumberPattern = RX(#"\b\d+(?:[._-]\d+)+\b"#)
    static let digitsPattern = RX(#"\d+"#)
    static let repeatedPathPattern = RX(#"<path>(?:[ /]+<path>)+"#)
    static let repeatedStringPattern = RX(#"(?:<str>[ ,]*<str>)+"#)

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

    static let exceptionClass = RX(#"[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)+(?:Exception|Error|Throwable)\b"#)
    static let fatalErrorMessage = RX(#"\bFatal error\b"#)
    static let excBadAccess = RX(#"\bEXC_BAD_ACCESS\b"#)
    static let excCrashToken = RX(#"\bEXC_CRASH\b"#)
    static let tracebackLabel = RX(#"\bTraceback \(most recent call last\)"#)
    static let threadCrashed = RX(#"\bThread[ \t]+\d+[ \t]+Crashed\b"#)
    static let leadingSeparators = RX(#"^[\s:,;>\-|]+"#)

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

    static func lastPathComponent(of token: String) -> String? {
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
        // 崩溃报告有两种提取路径：逐行解析器会把 .ips 的 JSON 行当成日志（产出裸 JSON 的
        // 「错误」），CrashReportParser 才是权威解读。同一份文件只允许后者的事件入场，
        // 否则一次崩溃会被拆成两条 cluster、次数也翻倍。
        let crashHandledPaths = Set(extraEvents.map(\.sourceLogPath))
        for reading in readings {
            if crashHandledPaths.contains(reading.url.path) { continue }
            events.append(contentsOf: reading.events)
        }
        events.append(contentsOf: extraEvents)
        events = deduplicated(events)
        result.events = events

        countEventSeverities(events, into: &result)

        let dated = events.compactMap { $0.date }
        result.windowStart = dated.min()
        result.windowEnd = dated.max()

        let signalEvents = events.filter { $0.isContinuation == false && signature(for: $0) != nil }
        result.topErrors = cluster(events: signalEvents, limit: topLimit)
        result.trend = buckets(for: events)
        result.affectedFiles = affectedFiles(for: events, limit: 10)
        return result
    }

    /// 级别计数。`switch` 的八个分支与那句「`severity == .crash` **或** `isCrash` 都算一次崩溃」
    /// 逐字照抄拆分前，包括 `.trace / .debug / .crash` 三个只 break 不计数分支。
    static func countEventSeverities(_ events: [LogEvent], into result: inout LogAggregate) {
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
    }

    /// cluster 的排序判据（全序，输出因此确定）。
    static func clusterOrder(_ lhs: ErrorCluster, _ rhs: ErrorCluster) -> Bool {
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        let left = lhs.lastSeen ?? Date.distantPast
        let right = rhs.lastSeen ?? Date.distantPast
        if left != right { return left > right }
        return lhs.signature < rhs.signature
    }

    /// 只保留带签名的非 continuation 事件（调用方也可能直接扔全量事件过来）。
    static func keyedSignatureEvents(_ events: [LogEvent]) -> [(signature: String, event: LogEvent)] {
        var keyed: [(signature: String, event: LogEvent)] = []
        for event in events where event.isContinuation == false {
            guard let sig = signature(for: event) else { continue }
            keyed.append((sig, event))
        }
        return keyed
    }

    /// 先按 (signature, path, lineNumber) 做一次全序，组内「第一条事件」的选取才与字典遍历顺序无关
    static func keyedEventOrder(_ lhs: (signature: String, event: LogEvent),
                                _ rhs: (signature: String, event: LogEvent)) -> Bool {
        if lhs.signature != rhs.signature { return lhs.signature < rhs.signature }
        if lhs.event.sourceLogPath != rhs.event.sourceLogPath {
            return lhs.event.sourceLogPath < rhs.event.sourceLogPath
        }
        return lhs.event.lineNumber < rhs.event.lineNumber
    }

    /// 按签名分组，`keys` 记录首次出现顺序（输出稳定靠的就是这一条）。
    static func groupKeyedEvents(_ keyed: [(signature: String, event: LogEvent)])
        -> (keys: [String], groups: [String: [LogEvent]]) {
        var keys: [String] = []
        var groups: [String: [LogEvent]] = [:]
        for pair in keyed {
            if groups[pair.signature] == nil { keys.append(pair.signature) }
            groups[pair.signature, default: []].append(pair.event)
        }
        return (keys, groups)
    }

    /// 组 -> cluster，`makeCluster` 判定为 nil 的组整组丢掉（与拆分前一致）。
    static func buildClusters(keys: [String], groups: [String: [LogEvent]]) -> [ErrorCluster] {
        var clusters: [ErrorCluster] = []
        for key in keys {
            guard let group = groups[key], let item = makeCluster(signature: key, events: group) else { continue }
            clusters.append(item)
        }
        return clusters
    }

    static func cluster(events: [LogEvent], limit: Int) -> [ErrorCluster] {
        guard limit > 0 else { return [] }
        let keyed = keyedSignatureEvents(events)
        guard keyed.isEmpty == false else { return [] }
        let sorted = keyed.sorted(by: keyedEventOrder)
        let grouped = groupKeyedEvents(sorted)
        // count 降序 -> lastSeen 新到旧 -> signature 升序，构成全序，输出因此确定；
        // 最后按 limit 截断（截断这一步与拆分前同样是「先全序再 prefix」）。
        return buildClusters(keys: grouped.keys, groups: grouped.groups)
            .sorted(by: clusterOrder)
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

    static func deduplicated(_ events: [LogEvent]) -> [LogEvent] {
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

    static func eventOrder(_ lhs: LogEvent, _ rhs: LogEvent) -> Bool {
        if lhs.sourceLogPath != rhs.sourceLogPath { return lhs.sourceLogPath < rhs.sourceLogPath }
        return lhs.lineNumber < rhs.lineNumber
    }

    static func makeCluster(signature: String, events: [LogEvent]) -> ErrorCluster? {
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

    static func rank(_ severity: LogSeverity) -> Int { LogLineParser.rank(severity) }

    static func mostFrequent(_ counts: [String: Int]) -> String? {
        guard counts.isEmpty == false else { return nil }
        let sorted = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        return sorted.first?.key
    }

    static func oneLine(_ text: String, limit: Int) -> String {
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
        // 异常类名在堆栈头里时优先用它做主 token（用户口径：签名 = 异常类名 + 归一化消息）。
        if let token = event.exceptionToken {
            let normalized = LogLineParser.normalizeMessage(event.message.isEmpty ? event.rawLine : event.message)
            return normalized.isEmpty ? token : "\(token): \(normalized)"
        }
        return LogLineParser.signature(for: line)
    }
}
