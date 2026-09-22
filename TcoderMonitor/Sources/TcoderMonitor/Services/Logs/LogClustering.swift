//
// 聚合与聚类：`LogAggregator`（事件去重、签名分组、cluster / buckets / affectedFiles）
//
// 从 LogParsing.swift 拆出，本文件的归一化与签名段在 WS-X5 又整体搬进 `LogLineParser.swift`：
// 两次搬运都只为控制单文件长度，判据、阈值、断言语义与搬运前完全一致。
//
import Foundation

// MARK: - 聚合与聚类

enum LogAggregator {

    /// 聚合一批 reading 与崩溃事件。
    ///
    /// `windowCutoff` 是**按事件时间**的裁剪线（RD-22）：整改前它不存在，
    /// 「最近 7 天」只裁文件 mtime（`LogDiscovery` 那一层），于是
    /// 一个 90 天没写过、内含 90 天错误的文件会整批算进"最近 7 天"。
    /// 现在：计数只算「有真实事件时间且时间 ≥ cutoff」的事件；
    /// 无事件时间与窗口外的事件各自计数，**不静默丢弃**。
    /// 传 `nil` = 不裁剪（老报告与单测的直接调用路径保持原行为）。
    static func aggregate(readings: [LogFileReading], extraEvents: [LogEvent], topLimit: Int,
                          windowCutoff: Date? = nil,
                          crashHandledPaths explicitCrashPaths: Set<String>? = nil,
                          windowExemptPaths: Set<String>? = nil) -> LogAggregate {
        var result = LogAggregate()
        // 真实读到的行数，不是估算值
        result.totalLinesScanned = readings.reduce(0) { $0 + $1.totalLines }

        var events: [LogEvent] = []
        // 崩溃报告有两种提取路径：逐行解析器会把 .ips 的 JSON 行当成日志（产出裸 JSON 的
        // 「错误」），CrashReportParser 才是权威解读。同一份文件只允许后者的事件入场，
        // 否则一次崩溃会被拆成两条 cluster、次数也翻倍。
        //
        // ⚠️ 这份名单**不能**从 `extraEvents` 反推：调用方交给聚合器的只是"够格进计数"的那部分
        // 崩溃事件（窗口内、有事件时间、非旧构建）。一份无事件时间的报告同样已经被崩溃通道解析过，
        // 若因为它不在 `extraEvents` 里就放行解析进来，`Exception Type: EXC_CRASH (SIGABRT)`
        // 这一行会被 `crashMarker` 第二次算成崩溃 —— 一次崩溃两个通道各数一遍。
        // 所以由 `FileLogAnalyzer` 显式交回"崩溃通道真出过事件的路径"。
        let crashHandledPaths = explicitCrashPaths ?? Set(extraEvents.map(\.sourceLogPath))
        for reading in readings {
            if crashHandledPaths.contains(reading.url.path) { continue }
            events.append(contentsOf: reading.events)
        }
        events.append(contentsOf: extraEvents)
        events = deduplicated(events)
        result.events = events

        let split = LogEventWindowSplit.split(events, cutoff: windowCutoff,
                                              exemptPaths: windowExemptPaths ?? [])
        result.undatedEventCount = split.undated.count
        result.outOfWindowEventCount = split.outOfWindow.count
        countEventSeverities(split.inWindow, into: &result)

        let dated = events.compactMap { $0.date }
        result.windowStart = dated.min()
        result.windowEnd = dated.max()

        let signalEvents = split.inWindow.filter { $0.isContinuation == false && signature(for: $0) != nil }
        result.topErrors = cluster(events: signalEvents, limit: topLimit)
        // 趋势按天分桶看的是**全部有事件时间的事件**（含窗口外的历史），
        // 它正是"历史报告与当前观察窗口分开展示"的那个载体；
        // 无事件时间的事件进不了任何一天，只能由台账单列。
        result.trend = buckets(for: events)
        result.affectedFiles = affectedFiles(for: split.inWindow, limit: 10)
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
