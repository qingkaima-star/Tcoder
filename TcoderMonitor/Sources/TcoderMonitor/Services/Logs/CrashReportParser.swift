// MARK: - 崩溃报告解析（WS-C 日志工作流）
//
// 本文件只负责「崩溃类」文件：.ips / .crash / .panic / .diag / .spin / .csncrashed /
// .diagnostics，以及文件名含 crash / diag 的日志、role == .crash 的日志。
// 普通应用日志由 LogLineParser + FileLogAnalyzer 处理，这里不抢活：
// 非崩溃文件一律直接返回空数组。
//
// 设计纪律：
// 1. 纯函数式 enum，天然 nonisolated，可在 `Task.detached` 里调用；
//    不触碰 AppState / ProjectStore / 任何 @MainActor，也不做目录枚举
//    （只读 FileLogAnalyzer 交给我的那一个 URL）。
// 2. 任何一步解析失败只返回空数组：绝不 force-unwrap、绝不 `try!`、绝不 `as!`，
//    JSONSerialization 的结果全部用 `as?` 安全取值。
//    兜底事件只在 `events(for:)` 里合成，最多 1 条。
// 3. 宁少不假：一份崩溃报告只产 1 条主事件；堆栈帧只进 stackFrames、不单独成事件；
//    纯文本通道为了 sourceFiles/affectedFiles 统计才额外产 isContinuation 事件
//    （上层按 isContinuation 排除计数）。
// 4. 进签名的内容一律先过 `LogLineParser.normalizeMessage`
//    （incident_id / uuid / 地址 / 绝对路径 必须归一化，否则每次崩溃都是新签名，聚不起来）。

import Foundation

enum CrashReportParser {
    // MARK: - 公开签名（FileLogAnalyzer 调用，一个字都不能改）

    /// `.ips` / `.crash` / `.panic` / `.diag`，或文件名含 crash 的日志。
    static func isCrashReport(_ url: URL) -> Bool {
        isCrashReport(url, role: .application)
    }

    /// 同上，额外接受 `role == .crash` 这条判据（公开签名里没有 role，所以给一个重载）。
    static func isCrashReport(_ url: URL, role: LogFileRole) -> Bool {
        if crashExtensions.contains(url.pathExtension.lowercased()) { return true }
        let name = url.lastPathComponent.lowercased()
        if name.contains("crash") || name.contains("diag") { return true }
        return role == .crash
    }

    /// 整份 reading 走崩溃通道：先试 .ips（JSON），否则按纯文本崩溃日志处理。
    static func events(for reading: LogFileReading) -> [LogEvent] {
        guard isCrashReport(reading.url, role: reading.role) else { return [] }
        let path = reading.url.path
        let modifiedAt = reading.modifiedAt
        guard let text = readText(reading.url), !text.isEmpty else {
            return [synthesizedEvent(path: path, modifiedAt: modifiedAt)]
        }
        // parseDiagnosticReport 内部要求文本以 `{` 开头，不是一行头 JSON 就返回 []。
        let diagnostic = parseDiagnosticReport(text: text, path: path, modifiedAt: modifiedAt)
        if !diagnostic.isEmpty { return diagnostic }
        let plain = parseCrashText(text: text, path: path, modifiedAt: modifiedAt)
        if !plain.isEmpty { return plain }
        return [synthesizedEvent(path: path, modifiedAt: modifiedAt)]
    }

    /// Apple DiagnosticReports 的 .ips：第一行是 header JSON，其余是 body JSON。
    static func parseDiagnosticReport(text: String, path: String, modifiedAt: Date) -> [LogEvent] {
        guard startsWithBrace(text) else { return [] }
        // header 独占一行；body 是剩下的全部（可能 pretty-print 成很多行）。
        let pieces = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headerText = pieces.first.map(String.init) ?? ""
        let bodyText = pieces.count > 1 ? String(pieces[1]) : ""
        let header = jsonDictionary(headerText) ?? [:]
        // 少数 .ips 是单行 JSON：body 解不开时整体再试一次，再不行退化成 header。
        let body = jsonDictionary(bodyText) ?? jsonDictionary(text) ?? header
        guard !body.isEmpty || !header.isEmpty else { return [] }

        let exception = dictionary(body["exception"]) ?? dictionary(header["exception"])
        let termination = dictionary(body["termination"]) ?? dictionary(header["termination"])

        let exceptionType = firstNonEmpty([string(exception?["type"]), string(body["exceptionType"])])
        let signal = string(exception?["signal"])
        let codes = firstNonEmpty([
            stringOrJoined(exception?["codes"]),
            stringOrJoined(exception?["codes_if_signaled"]),
        ]).map { normalize($0) }
        // subtype 里的地址（KERN_INVALID_ADDRESS at 0x…）必须归一化后才进签名。
        let subtype = firstNonEmpty([
            stringOrJoined(exception?["subtype"]),
            stringOrJoined(body["exceptionStrings"]),
        ]).map { normalize($0) }
        let terminationText = firstNonEmpty([
            string(termination?["reason"]),
            string(termination?["indicator"]),
            stringOrJoined(termination?["notificationName"]),
        ])
        let terminationFlags = string(termination?["flags"])
        let bugType = firstNonEmpty([string(body["bug_type"]), string(header["bug_type"])])

        let procName = firstNonEmpty([
            string(body["procName"]),
            string(body["proc_name"]),
            string(header["app_name"]),
        ]) ?? (path as NSString).lastPathComponent
        let appVersion = firstNonEmpty([string(body["app_version"]), string(header["app_version"])])
        let appSession = firstNonEmpty([string(body["app_session"]), string(header["app_session"])])
        let incidentID = firstNonEmpty([
            string(body["incident_id"]),
            string(body["incident_identifier"]),
            string(header["incident_id"]),
            string(header["incident_identifier"]),
        ])
        let osVersion = firstNonEmpty([string(body["os_version"]), string(header["os_version"])])
        let product = firstNonEmpty([string(body["product"]), string(header["product"])])

        // 线程：找 triggered / crashed 的那一个，只取前 8 帧
        let threads = arrayOfDictionaries(body["threads"])
        let imageNames = usedImageNames(body["usedImages"])
        let triggered = threads.first { boolValue($0["triggered"]) || boolValue($0["crashed"]) }
            ?? indexed(threads, int(body["crashedThread"]))
            ?? threads.first
        let rawFrames = (array(triggered?["backtrace"]) ?? array(triggered?["frames"]))
            ?? array(body["lastExceptionBacktrace"])
            ?? []
        var stackFrames: [String] = []
        var sourceFiles: [String] = []
        for (offset, raw) in rawFrames.prefix(ipsMaxFrames).enumerated() {
            guard let built = ipsFrame(raw, index: offset, imageNames: imageNames) else { continue }
            stackFrames.append(built.frame)
            if let file = built.file, !sourceFiles.contains(file) { sourceFiles.append(file) }
        }
        let asiLines = flattenASI(dictionary(body["asi"]))
        let threadLabel = firstNonEmpty([
            string(triggered?["name"]),
            string(triggered?["queue"]),
            string(triggered?["threadName"]),
        ])

        // 一个崩溃事实都没读到就返回 []，由 events(for:) 决定要不要合成兜底事件。
        let hasEvidence = exceptionType != nil || signal != nil || subtype != nil || codes != nil
            || terminationText != nil || bugType != nil || !stackFrames.isEmpty || !asiLines.isEmpty
        guard hasEvidence else { return [] }

        var messageParts: [String] = ["崩溃 \(procName)"]
        if let bugType { messageParts.append("bug_type " + clip(bugType, 40)) }
        if let exceptionType { messageParts.append(clip(normalize(exceptionType), 80)) }
        if let subtype { messageParts.append(clip(subtype, 160)) }
        if let signal { messageParts.append(clip(normalize(signal), 40)) }
        if let codes { messageParts.append("codes " + clip(codes, 120)) }
        if let terminationText { messageParts.append("终止原因 " + clip(normalize(terminationText), 160)) }
        if let terminationFlags { messageParts.append("flags " + clip(terminationFlags, 40)) }
        if let threadLabel { messageParts.append("线程 " + clip(normalize(threadLabel), 80)) }
        messageParts.append(contentsOf: asiLines.map { clip($0, 160) })
        let message = normalize(messageParts.filter { !$0.isEmpty }.joined(separator: " · "))

        // incident_id / app_session 先归一化再写进 rawLine（crashSignature 会复用 rawLine 文本）。
        var rawParts: [String] = ["崩溃报告 \(path)", "proc=\(procName)"]
        if let appVersion { rawParts.append("app_version=" + clip(normalize(appVersion), 60)) }
        if let appSession { rawParts.append("session=" + clip(normalize(appSession), 60)) }
        if let incidentID { rawParts.append("incident=" + clip(normalize(incidentID), 60)) }
        if let product { rawParts.append("product=" + clip(normalize(product), 60)) }
        if let osVersion { rawParts.append("os=" + clip(normalize(osVersion), 80)) }
        let rawLine = rawParts.joined(separator: " ")

        let event = LogEvent(
            date: ipsDate(body: body, header: header, path: path, modifiedAt: modifiedAt),
            severity: .crash,
            rawLine: rawLine,
            message: message,
            sourceLogPath: path,
            lineNumber: 1,
            stackFrames: stackFrames,
            sourceFiles: sourceFiles,
            isCrash: true,
            isContinuation: false
        )
        return [event]
    }

    /// 纯文本崩溃日志（crash.log / .crash / 含堆栈的 abort 输出）。
    static func parseCrashText(text: String, path: String, modifiedAt: Date) -> [LogEvent] {
        // omittingEmptySubsequences: false —— 行号必须和原文件对得上。
        let rows = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        guard !rows.isEmpty else { return [] }
        let limited = rows.count > maxTextLines ? Array(rows.prefix(maxTextLines)) : Array(rows)
        let lines = limited.map { clip(trimmed(String($0)), 400) }

        // 段切分：出现一次 `Incident Identifier:` 就是一份新的崩溃报告。
        var starts: [Int] = []
        for (index, line) in lines.enumerated() where line.lowercased().contains("incident identifier") {
            starts.append(index)
        }
        var boundaries: [Int] = []
        if let first = starts.first, first > 0 { boundaries.append(0) }
        boundaries.append(contentsOf: starts)
        if boundaries.isEmpty { boundaries = [0] }
        boundaries = Array(Set(boundaries)).sorted()

        var events: [LogEvent] = []
        for (position, start) in boundaries.enumerated() {
            let end = position + 1 < boundaries.count ? boundaries[position + 1] : lines.count
            guard start < end else { continue }
            let segment = Array(lines[start..<end])
            let blob = segment.joined(separator: "\n").lowercased()
            // 看着像一份完整报告（有 Incident Identifier，或 Exception Type + 线程表）
            // 就只算一次崩溃；否则视为累积型 crash.log，段内每个锚点特征词各算一次。
            let singleReport = blob.contains("incident identifier")
                || (blob.contains("exception type") && blob.contains("thread "))
            events.append(contentsOf: parseTextSegment(
                lines: segment,
                lineNumberOffset: start,
                path: path,
                modifiedAt: modifiedAt,
                singleReport: singleReport
            ))
            if events.count >= maxTextEvents { break }
        }
        return Array(events.prefix(maxTextEvents))
    }

    /// 供聚类用的稳定签名，如 "EXC_BAD_ACCESS / KERN_INVALID_ADDRESS"、"SIGABRT"、"Fatal error"。
    static func crashSignature(from event: LogEvent) -> String? {
        let haystack = [event.message, event.rawLine].filter { !$0.isEmpty }.joined(separator: " · ")
        guard !haystack.isEmpty else { return nil }

        // 1) EXC_* 配上 KERN_* / BUS_* / SEGV_* 之类的机器码（地址已被 normalizeMessage 换掉）
        let exceptionToken = exceptionTypePattern.firstMatch(in: haystack)
        let machineToken = machineCodePattern.firstMatch(in: haystack)
        if let exceptionToken {
            var result = exceptionToken
            if let machineToken, machineToken != exceptionToken {
                result += " / " + machineToken
            } else if machineToken == nil, let signal = signalPattern.firstMatch(in: haystack) {
                // EXC_CRASH 这类笼统的异常码，靠信号区分（EXC_CRASH / SIGABRT）
                result += " / " + signal
            }
            return emptyToNil(normalize(result))
        }
        if let machineToken { return emptyToNil(normalize(machineToken)) }
        // 2) 信号
        if let signal = signalPattern.firstMatch(in: haystack) {
            return emptyToNil(normalize(signal))
        }
        // 3) 语言级 fatal 短语（Fatal error / precondition failure / …）
        for phrase in fatalPhrases where phrase.pattern.matches(haystack) {
            return emptyToNil(normalize(phrase.label))
        }
        // 4) `Exception Type: <值>` / `Termination Reason: <值>`
        for pattern in [exceptionTypeValuePattern, terminationValuePattern] {
            if let value = pattern.firstGroup(in: haystack, 1) {
                let cleaned = emptyToNil(normalize(clip(value, 120)))
                if let cleaned { return cleaned }
            }
        }
        return nil
    }
}

// MARK: - 内部：正则包装与判定表（全部是不可变 static let，线程安全）

extension CrashReportParser {
    /// NSRegularExpression 的安全包装：编译失败就是 nil，所有查询按「不匹配」处理。
    struct Pattern {
        private let regex: NSRegularExpression?

        init(_ expression: String) {
            regex = try? NSRegularExpression(pattern: expression, options: [])
        }

        func matches(_ text: String) -> Bool {
            guard let regex, !text.isEmpty else { return false }
            let ns = text as NSString
            return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil
        }

        /// group 0 是整条匹配，未命中的分组为 nil；整体不匹配返回 nil。
        func groups(in text: String) -> [String?]? {
            guard let regex, !text.isEmpty else { return nil }
            let ns = text as NSString
            guard let result = regex.firstMatch(
                in: text,
                options: [],
                range: NSRange(location: 0, length: ns.length)
            ) else { return nil }
            var values: [String?] = []
            for index in 0..<result.numberOfRanges {
                let range = result.range(at: index)
                values.append(range.location == NSNotFound ? nil : ns.substring(with: range))
            }
            return values
        }

        func firstMatch(in text: String) -> String? {
            guard let groups = groups(in: text), groups.count > 0, let whole = groups[0] else { return nil }
            let cleaned = CrashReportParser.trimmed(whole)
            return cleaned.isEmpty ? nil : cleaned
        }

        func firstGroup(in text: String, _ index: Int) -> String? {
            guard let groups = groups(in: text), index < groups.count, let value = groups[index] else { return nil }
            let cleaned = CrashReportParser.trimmed(value)
            return cleaned.isEmpty ? nil : cleaned
        }

        /// 一行里可能有多个文件名（例如 `at Foo.swift:12 (Bar.swift:9)`）。
        func allMatches(in text: String, group: Int = 0) -> [String] {
            guard let regex, !text.isEmpty, group >= 0 else { return [] }
            let ns = text as NSString
            var found: [String] = []
            regex.enumerateMatches(in: text, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
                guard let result, group < result.numberOfRanges else { return }
                let range = result.range(at: group)
                guard range.location != NSNotFound, range.length > 0, range.length < 200 else { return }
                found.append(ns.substring(with: range))
            }
            return found
        }
    }

    /// 崩溃报告扩展名（Apple DiagnosticReports 的常见后缀）。
    static let crashExtensions: Set<String> = [
        "ips", "crash", "panic", "diag", "spin", "csncrashed", "diagnostics",
    ]

    static let ipsMaxFrames = 8
    static let textMaxFrames = 12
    static let maxReadBytes = 4_000_000
    static let maxTextLines = 20_000
    static let maxTextEvents = 2_000

    static let exceptionTypePattern = Pattern("\\bEXC_[A-Z][A-Z0-9_]{2,}\\b")
    static let machineCodePattern = Pattern("\\b(?:KERN_[A-Z][A-Z_]{2,}|BUS_[A-Z][A-Z_]{2,}|ILL_[A-Z][A-Z_]{2,}|SEGV_[A-Z][A-Z_]{2,}|FPE_[A-Z][A-Z_]{2,})\\b")
    static let signalPattern = Pattern("\\bSIG(?:SEGV|ABRT|BUS|ILL|TRAP|KILL|SYS|EMT|XCPU|XFSZ|PIPE|TERM|INT|QUIT|STOP|USR1|USR2)\\b")
    static let exceptionTypeValuePattern = Pattern("\\bException Type\\s*:\\s*([^\\n·]+)")
    static let terminationValuePattern = Pattern("\\bTermination Reason\\s*:\\s*([^\\n·]+)")
    static let crashedThreadPattern = Pattern("^\\s*Thread\\s+\\d+\\s+(?:Crashed|crashed)\\b")
    static let anyThreadPattern = Pattern("^\\s*Thread\\s+\\d+\\b")
    static let sectionStopPattern = Pattern("^\\s*(?:Binary Images|Extra Information|Application Specific Information|Last Exception Backtrace|VM Regions|Used Images|Thread State)\\b")
    static let dateLabelPattern = Pattern("^\\s*(?:Date/Time|Timestamp|Incident Date)\\s*:\\s*(.+)$")
    static let fileNameDatePattern = Pattern("(\\d{4})-(\\d{2})-(\\d{2})[-_](\\d{2})(\\d{2})?(\\d{2})?")
    static let sourceFilePattern = Pattern("(?:[A-Za-z0-9_$.\\-]+[/\\\\])+([A-Za-z0-9_$.\\-]+)\\.(?:swift|mm|c|cc|cpp|cxx|m|py|js|jsx|ts|tsx|kt|java|go|rs)\\b|[A-Za-z0-9_$.\\-]+\\.(?:swift|mm|c|cc|cpp|cxx|m|py|js|jsx|ts|tsx|kt|java|go|rs)\\b")

    /// 堆栈帧行的几种写法（Apple 文本 / lldb / 带源码行）。
    static let framePatterns: [Pattern] = [
        Pattern("^[ \\t]*\\d{1,3}[ \\t]+\\S+[ \\t]+0x[0-9a-fA-F]{6,}[ \\t]+\\S[^\\n]*[+-][ \\t]*\\d+[ \\t]*$"),
        Pattern("^[ \\t]*(?:frame[ \\t]+)?#[ \\t]*\\d+[ \\t]*:?[ \\t]+0x[0-9a-fA-F]{6,}[ \\t]+\\S[^\\n]*$"),
        Pattern("^[ \\t]*(?:frame[ \\t]+)?#[ \\t]*\\d+[ \\t]*:?[ \\t]+in[ \\t]+\\S[^\\n]*\\.(?:swift|mm|cc|cpp|c|py|js|ts|kt|java|go)\\b[^\\n]*$"),
        Pattern("^[ \\t]*\\d{1,3}[ \\t]+\\S+[ \\t]+[^\\t\\n ]+[^\\n]*\\([^\\n)]*\\.(?:swift|mm|cc|cpp|c|py|js|ts):\\d+\\)[ \\t]*$"),
    ]

    /// 特征词表。`startsReport` = 它足以单独算「一次崩溃」；
    /// false = 同一份报告里的补充信息，只并进主事件（避免一次崩溃被数成 5 次）。
    struct Cue {
        let label: String
        let startsReport: Bool
        let pattern: Pattern
    }

    static let cues: [Cue] = [
        Cue(label: "Fatal error", startsReport: true, pattern: Pattern("\\bFatal error\\b")),
        Cue(label: "Fatal Python error", startsReport: true, pattern: Pattern("\\bFatal Python error\\b")),
        Cue(label: "precondition failure", startsReport: true, pattern: Pattern("\\bprecondition failure\\b")),
        Cue(label: "assertion failure", startsReport: true, pattern: Pattern("\\bassertion failure\\b")),
        Cue(label: "pure virtual method called", startsReport: true, pattern: Pattern("\\bpure virtual method called\\b")),
        Cue(label: "terminate called after throwing", startsReport: true, pattern: Pattern("\\bterminate called after throwing\\b")),
        Cue(label: "kernel panic", startsReport: true, pattern: Pattern("\\bkernel panic\\b")),
        Cue(label: "uncaught exception", startsReport: true, pattern: Pattern("\\buncaught exception\\b")),
        Cue(label: "Incident Identifier", startsReport: true, pattern: Pattern("\\bIncident Identifier\\s*:")),
        Cue(label: "Exception Type", startsReport: true, pattern: Pattern("\\bException Type\\s*:")),
        Cue(label: "EXC_BAD_ACCESS", startsReport: false, pattern: Pattern("\\bEXC_BAD_ACCESS\\b")),
        Cue(label: "EXC_BAD_INSTRUCTION", startsReport: false, pattern: Pattern("\\bEXC_BAD_INSTRUCTION\\b")),
        Cue(label: "EXC_CRASH", startsReport: false, pattern: Pattern("\\bEXC_CRASH\\b")),
        Cue(label: "EXC_BREAKPOINT", startsReport: false, pattern: Pattern("\\bEXC_BREAKPOINT\\b")),
        Cue(label: "EXC_GUARD", startsReport: false, pattern: Pattern("\\bEXC_GUARD\\b")),
        Cue(label: "EXC_RESOURCE", startsReport: false, pattern: Pattern("\\bEXC_RESOURCE\\b")),
        Cue(label: "EXC", startsReport: false, pattern: Pattern("\\bEXC_[A-Z][A-Z0-9_]{2,}\\b")),
        Cue(label: "signal", startsReport: false, pattern: Pattern("\\bSIG(?:SEGV|ABRT|BUS|ILL|TRAP|KILL|SYS|EMT|XCPU|XFSZ|PIPE|TERM|INT|QUIT|STOP|USR1|USR2)\\b")),
        Cue(label: "Thread Crashed", startsReport: false, pattern: Pattern("\\bThread\\s+\\d+\\s+(?:Crashed|crashed)\\b")),
        Cue(label: "Termination Reason", startsReport: false, pattern: Pattern("\\bTermination Reason\\s*:")),
        Cue(label: "Exception Codes", startsReport: false, pattern: Pattern("\\bException (?:Codes|Subtype|Signal)\\s*:")),
        Cue(label: "Triggered by Thread", startsReport: false, pattern: Pattern("\\bTriggered by Thread\\s*:")),
        Cue(label: "Segmentation fault", startsReport: false, pattern: Pattern("\\bSegmentation fault\\b")),
        Cue(label: "Abort trap", startsReport: false, pattern: Pattern("\\bAbort trap\\b")),
    ]

    /// fatal 短语 -> 稳定签名标签（按声明顺序优先；"Segmentation fault" 归一成 SIGSEGV）。
    struct FatalPhrase {
        let label: String
        let pattern: Pattern
    }

    static let fatalPhrases: [FatalPhrase] = [
        FatalPhrase(label: "Fatal error", pattern: Pattern("\\bFatal error\\b")),
        FatalPhrase(label: "Fatal Python error", pattern: Pattern("\\bFatal Python error\\b")),
        FatalPhrase(label: "precondition failure", pattern: Pattern("\\bprecondition failure\\b")),
        FatalPhrase(label: "assertion failure", pattern: Pattern("\\bassertion failure\\b")),
        FatalPhrase(label: "terminate called after throwing", pattern: Pattern("\\bterminate called after throwing\\b")),
        FatalPhrase(label: "pure virtual method called", pattern: Pattern("\\bpure virtual method called\\b")),
        FatalPhrase(label: "kernel panic", pattern: Pattern("\\bkernel panic\\b")),
        FatalPhrase(label: "uncaught exception", pattern: Pattern("\\buncaught exception\\b")),
        FatalPhrase(label: "SIGSEGV", pattern: Pattern("\\bSegmentation fault\\b")),
        FatalPhrase(label: "SIGABRT", pattern: Pattern("\\bAbort trap\\b")),
    ]
}

// MARK: - 内部：纯文本段解析

extension CrashReportParser {
    /// 段内规则：
    /// - 首个特征词（不论类别）一定成为主事件；
    /// - 之后的锚点特征词：单报告段里只并进主事件，累积型段里各自成为新主事件；
    /// - 非锚点特征词（Exception Codes / Termination Reason / Thread N Crashed …）
    ///   永远并进当前主事件，最多并 4 条；
    /// - 堆栈帧行追加到「上一条主事件」的 stackFrames（最多 12 帧），
    ///   同时产一条 isContinuation = true 的事件（上层不计数，只贡献 sourceFiles）。
    static func parseTextSegment(lines: [String],
                                 lineNumberOffset: Int,
                                 path: String,
                                 modifiedAt: Date,
                                 singleReport: Bool) -> [LogEvent] {
        var events: [LogEvent] = []
        var primaryIndexes: [Int] = []
        var currentPrimary: Int?
        var details: [String] = []
        var sawCrashedThread = false
        var inCrashedBlock = false
        var segmentDate: Date?

        func flushDetails() {
            defer { details = [] }
            guard let index = currentPrimary, index < events.count, !details.isEmpty else { return }
            let merged = ([events[index].message] + details).joined(separator: " · ")
            events[index].message = normalize(merged)
        }

        for (offset, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let number = lineNumberOffset + offset + 1

            // 崩溃线程块跟踪：帧只在 Crashed 块里收（整段没出现过线程表就一律收）。
            if crashedThreadPattern.matches(line) {
                sawCrashedThread = true
                inCrashedBlock = true
            } else if anyThreadPattern.matches(line) {
                inCrashedBlock = false
            }
            if sectionStopPattern.matches(line) { inCrashedBlock = false }

            if let label = dateLabelPattern.firstGroup(in: line, 1),
               let parsed = date(from: label, referenceDate: modifiedAt) {
                segmentDate = parsed
            }

            // 1) 堆栈帧行：追加到上一条主事件 + 产一条 isContinuation 事件
            if isStackFrame(line), inCrashedBlock || !sawCrashedThread, let anchor = currentPrimary {
                let frame = frameText(line)
                if events[anchor].stackFrames.count < textMaxFrames {
                    events[anchor].stackFrames.append(frame)
                }
                events.append(LogEvent(
                    date: events[anchor].date,
                    severity: .crash,
                    rawLine: line,
                    message: normalize(frame),
                    sourceLogPath: path,
                    lineNumber: number,
                    stackFrames: [frame],
                    sourceFiles: sourceFiles(in: line),
                    isCrash: true,
                    isContinuation: true
                ))
                if events.count >= maxTextEvents { break }
                continue
            }

            // 2) 崩溃特征词
            guard let cue = matchedCue(in: line) else { continue }
            if currentPrimary == nil || (!singleReport && cue.startsReport) {
                flushDetails()
                let parsed = LogLineParser.parseLine(line, number: number, sourcePath: path, referenceDate: modifiedAt)
                events.append(LogEvent(
                    date: parsed.date ?? segmentDate ?? modifiedAt,
                    severity: .crash,
                    rawLine: line,
                    message: baseMessage(for: parsed),
                    sourceLogPath: path,
                    lineNumber: number,
                    stackFrames: [],
                    sourceFiles: sourceFiles(in: line),
                    isCrash: true,
                    isContinuation: false
                ))
                let anchor = events.count - 1
                currentPrimary = anchor
                primaryIndexes.append(anchor)
            } else if details.count < 4 {
                details.append(clip(line, 160))
            }

            if events.count >= maxTextEvents { break }
        }
        flushDetails()

        // 单报告段：段里那次崩溃的时间以 `Date/Time:` 为准（比文件 mtime 可信）。
        if singleReport, let segmentDate {
            for index in events.indices { events[index].date = segmentDate }
        }
        // 主事件的 sourceFiles 补上它自己帧里出现过的文件。
        for index in primaryIndexes where index < events.count {
            var files = events[index].sourceFiles
            for frame in events[index].stackFrames {
                for file in sourceFiles(in: frame) where !files.contains(file) { files.append(file) }
            }
            events[index].sourceFiles = Array(files.prefix(8))
        }
        return events
    }

    /// 与文本日志保持一致的归一化：优先 signature(for:)，退回 message，再退回整行。
    static func baseMessage(for parsed: ParsedLogLine) -> String {
        var base = parsed.message
        if let signature = LogLineParser.signature(for: parsed), !signature.isEmpty { base = signature }
        if base.isEmpty { base = parsed.raw }
        return normalize(base)
    }

    static func matchedCue(in line: String) -> Cue? {
        for cue in cues where cue.pattern.matches(line) { return cue }
        return nil
    }

    static func isStackFrame(_ line: String) -> Bool {
        framePatterns.contains { $0.matches(line) }
    }

    static func frameText(_ line: String) -> String {
        if let extracted = LogLineParser.stackFrame(in: line), !extracted.isEmpty {
            return clip(trimmed(extracted), 300)
        }
        return clip(trimmed(line), 300)
    }

    /// 只留文件名（不带绝对路径），供 affectedFiles / sourceFiles 统计。
    static func sourceFiles(in line: String) -> [String] {
        var files: [String] = []
        func add(_ raw: String) {
            let name = trimmed((raw as NSString).lastPathComponent)
            guard name.count >= 3, name.count <= 160, name.contains("."), !name.lowercased().contains("http") else { return }
            if !files.contains(name) { files.append(name) }
        }
        if let detected = LogLineParser.sourceFile(in: line) { add(detected) }
        for match in sourceFilePattern.allMatches(in: line) { add(match) }
        return Array(files.prefix(4))
    }

    static func synthesizedEvent(path: String, modifiedAt: Date) -> LogEvent {
        let name = (path as NSString).lastPathComponent
        return LogEvent(
            date: modifiedAt,
            severity: .crash,
            rawLine: "崩溃报告 \(path)（未能解析出细节）",
            message: normalize("崩溃报告 \(name)（未能解析出细节）"),
            sourceLogPath: path,
            lineNumber: 1,
            stackFrames: [],
            sourceFiles: [],
            isCrash: true,
            isContinuation: false
        )
    }
}

// MARK: - 内部：安全取值工具

extension CrashReportParser {
    static func readText(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else { return nil }
        let bytes = data.count > maxReadBytes ? Data(data.prefix(maxReadBytes)) : data
        if let text = String(data: bytes, encoding: .utf8) { return text }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func trimmed(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func clip(_ text: String, _ limit: Int) -> String {
        text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    static func emptyToNil(_ text: String) -> String? {
        text.isEmpty ? nil : text
    }

    /// 与文本日志同一条归一化通道（去 uuid / 地址 / 绝对路径 / 数字噪声）。
    static func normalize(_ text: String) -> String {
        let cleaned = LogLineParser.normalizeMessage(text)
        return clip(trimmed(cleaned.replacingOccurrences(of: "\u{0000}", with: " ")), 900)
    }

    static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values.compactMap({ $0 }) where !trimmed(value).isEmpty { return value }
        return nil
    }

    static func indexed(_ values: [[String: Any]], _ index: Int?) -> [String: Any]? {
        guard let index, index >= 0, index < values.count else { return nil }
        return dictionary(values[index])
    }

    static func startsWithBrace(_ text: String) -> Bool {
        for character in text where !character.isNewline && character != " " && character != "\t" && character != "\u{FEFF}" {
            return character == "{"
        }
        return false
    }

    static func jsonDictionary(_ text: String) -> [String: Any]? {
        let body = trimmed(text)
        guard body.hasPrefix("{"), body.count > 2 else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: Data(body.utf8), options: []),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        // 尾部可能有杂散内容：退到最后一个 `}` 再试一次。
        if let opening = body.firstIndex(of: "{"), let closing = body.lastIndex(of: "}"), opening < closing {
            let slice = String(body[opening...closing])
            if let object = try? JSONSerialization.jsonObject(with: Data(slice.utf8), options: []),
               let dictionary = object as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }

    static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]] {
        guard let list = value as? [Any] else { return [] }
        return list.compactMap { dictionary($0) }
    }

    /// 字符串 / NSNumber 都能读成字符串，读不到返回 nil。
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(trimmed(text)) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let lower = trimmed(text).lowercased()
            return lower == "true" || lower == "yes" || lower == "1"
        }
        return false
    }

    /// codes 可能是字符串、数字数组，也可能是小字典。
    static func stringOrJoined(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [Any] {
            let parts = list.compactMap { element -> String? in
                if let text = element as? String { return text.isEmpty ? nil : text }
                if let number = element as? NSNumber { return number.stringValue }
                if let nested = element as? [Any] {
                    let flat = nested.compactMap { string($0) }
                    return flat.isEmpty ? nil : flat.joined(separator: ", ")
                }
                if let table = element as? [String: Any] { return stringOrJoined(table) }
                return nil
            }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let table = value as? [String: Any] {
            let parts = table.keys.sorted().prefix(8).compactMap { key -> String? in
                guard let value = stringOrJoined(table[key]), !value.isEmpty else { return nil }
                return "\(key)=\(value)"
            }
            return parts.isEmpty ? nil : Array(parts).joined(separator: ", ")
        }
        return nil
    }

    /// `asi` 的每个 section 形如 `[[key, [values]], …]`，平摊成 `key = v1, v2`。
    static func flattenASI(_ asi: [String: Any]?) -> [String] {
        guard let asi, !asi.isEmpty else { return [] }
        let preferred = ["Backtrace", "Diagnose"]
        let ordered = preferred.filter { asi[$0] != nil } + asi.keys.filter { !preferred.contains($0) }.sorted()
        var result: [String] = []
        for section in ordered {
            guard let entries = array(asi[section]) else { continue }
            for entry in entries {
                if result.count >= 6 { break }
                if let pair = array(entry), let key = string(pair.first), pair.count >= 2 {
                    let values = array(pair[1])?.compactMap { string($0) } ?? []
                    let joined = values.isEmpty ? (stringOrJoined(pair[1]) ?? "") : values.joined(separator: ", ")
                    guard !joined.isEmpty else { continue }
                    result.append(normalize("\(key) = \(joined)"))
                } else if let table = dictionary(entry) {
                    for key in table.keys.sorted() {
                        guard result.count < 6, let value = stringOrJoined(table[key]), !value.isEmpty else { continue }
                        result.append(normalize("\(key) = \(value)"))
                    }
                }
            }
            if result.count >= 6 { break }
        }
        return Array(result.prefix(6))
    }

    /// usedImages 顺序表：frame 只带 imageIndex 时用它补镜像名。
    static func usedImageNames(_ value: Any?) -> [String] {
        arrayOfDictionaries(value).map { image in
            firstNonEmpty([
                string(image["name"]),
                string(image["path"]).map { ($0 as NSString).lastPathComponent },
            ]) ?? ""
        }
    }

    /// 一帧 .ips frame -> `symbol (File.swift:123)`；无 symbol 时 `frame <idx> in <imageName>`。
    static func ipsFrame(_ raw: Any?, index: Int, imageNames: [String]) -> (frame: String, file: String?)? {
        if let text = string(raw) {
            let plain = clip(trimmed(text), 300)
            return plain.isEmpty ? nil : (plain, nil)
        }
        guard let frame = dictionary(raw) else { return nil }
        let symbol = firstNonEmpty([string(frame["symbol"]), string(frame["symbolLocation"])])
        let source = dictionary(frame["sourceLineInfo"])
        let filePath = firstNonEmpty([string(source?["file"]), string(source?["filePath"])])
        let lineNumber = int(source?["line"]) ?? int(source?["lineNumber"])
        let imageIndex = int(frame["imageIndex"]) ?? int(frame["image_index"])
        let imageName = firstNonEmpty([
            string(frame["binary_name"]),
            string(frame["imageName"]),
            imageIndex.flatMap { position in position >= 0 && position < imageNames.count ? imageNames[position] : nil },
        ])
        let offset = int(frame["image_offset"]) ?? int(frame["imageOffset"])

        let file = filePath.map { trimmed(($0 as NSString).lastPathComponent) }
        let fileName = (file?.isEmpty == false) ? file : nil

        var text: String
        if let symbol {
            text = clip(symbol, 160)
            if let fileName {
                text += lineNumber.map { " (\(fileName):\($0))" } ?? " (\(fileName))"
            } else if let imageName {
                text += " in \(imageName)"
            }
        } else {
            text = "frame \(index)"
            if let imageName { text += " in \(imageName)" }
            if let offset { text += " + 0x" + String(max(0, offset), radix: 16) }
        }
        let built = clip(trimmed(text), 300)
        guard !built.isEmpty else { return nil }
        return (built, fileName)
    }

    /// date 优先 body 的 timestamp，回落到 header 的 timestamp/reporting_time，再回落 modifiedAt。
    static func ipsDate(body: [String: Any], header: [String: Any], path: String, modifiedAt: Date) -> Date {
        let candidates = [
            string(body["timestamp"]),
            string(body["incident_timestamp"]),
            string(header["timestamp"]),
            string(header["reporting_time"]),
            string(header["utc_time"]),
            string(header["incident_identifier"]),
        ]
        for candidate in candidates.compactMap({ $0 }) {
            if let parsed = date(from: candidate, referenceDate: modifiedAt) { return parsed }
        }
        if let fromName = dateFromFileName(path) { return fromName }
        return modifiedAt
    }

    static func date(from text: String, referenceDate: Date) -> Date? {
        let value = trimmed(text)
        guard value.count >= 8 else { return nil }
        guard value.contains("-") || value.contains("/") else {
            return LogLineParser.parseTimestamp(value, referenceDate: referenceDate)
        }
        if let iso = iso8601(value) { return iso }
        for format in [
            "yyyy-MM-dd HH:mm:ss.SS ZZZZ",
            "yyyy-MM-dd HH:mm:ss ZZZZ",
            "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd HH:mm:ss.SS",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
        ] {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.isLenient = true
            formatter.dateFormat = format
            if let parsed = formatter.date(from: value) { return parsed }
        }
        return LogLineParser.parseTimestamp(value, referenceDate: referenceDate)
    }

    static func iso8601(_ text: String) -> Date? {
        let withFractions = ISO8601DateFormatter()
        withFractions.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let parsed = withFractions.date(from: text) { return parsed }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }

    /// `TcoderMonitor-2026-09-18-132231.ips` 这类文件名里带的时间（报告头缺失时用）。
    static func dateFromFileName(_ path: String) -> Date? {
        guard let groups = fileNameDatePattern.groups(in: (path as NSString).lastPathComponent),
              groups.count >= 5,
              let year = Int(groups[1] ?? ""),
              let month = Int(groups[2] ?? ""),
              let day = Int(groups[3] ?? ""),
              let hour = Int(groups[4] ?? ""),
              year > 1970, (1...12).contains(month), (1...31).contains(day), (0...23).contains(hour)
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = groups.count > 5 ? (Int(groups[5] ?? "") ?? 0) : 0
        components.second = groups.count > 6 ? (Int(groups[6] ?? "") ?? 0) : 0
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)
    }
}
