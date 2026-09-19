// MARK: - 崩溃报告解析（WS-C 日志工作流）
//
// 本文件只负责「崩溃类」文件：.ips / .crash / .panic / .diag / .spin / .csncrashed /
// .diagnostics，以及文件名含 crash / diag 的日志、role == .crash 的日志。
// 普通应用日志由 LogLineParser + FileLogAnalyzer 处理，这里不抢活：
// 非崩溃文件一律直接返回空数组。
//
// 设计纪律：
// 1. 纯函数式 enum，天然 nonisolated，可在 `Task.detached` 里调用；
//    不触碰 AppState / ProjectStore / 任何 @MainActor，也不做任何目录枚举
//    （只读 FileLogAnalyzer 交给我的那一个 URL）。
// 2. 任何一步解析失败只返回空数组：绝不 force-unwrap、绝不 `try!`、绝不 `as!`，
//    JSONSerialization 的结果全部用 `as?` 安全取。
//    兜底事件只在 `events(for:)` 里合成，最多 1 条。
// 3. 宁少不假：一份崩溃报告只产 1 条主事件；堆栈帧只进 stackFrames 不单独成事件；
//    纯文本通道为了 affectedFiles/sourceFiles 统计才额外产 isContinuation 事件
//    （上层按 isContinuation 排除计数）。
// 4. 进签名的东西一律先过 `LogLineParser.normalizeMessage`
//    （incident_id / uuid / 地址 / 绝对路径 必须先归一化，否则每次崩溃都是新签名）。

import Foundation

enum CrashReportParser {
    // MARK: - 公开签名（FileLogAnalyzer 调用，一个字都不能改）

    /// `.ips` / `.crash` / `.panic` / `.diag`，或文件名含 crash 的日志。
    static func isCrashReport(_ url: URL) -> Bool {
        isCrashReport(url, role: .application)
    }

    /// 同上，额外接受 `role == .crash` 的判定（签名里没有 role，所以这里给重载）。
    static func isCrashReport(_ url: URL, role: LogFileRole) -> Bool {
        if crashExtensions.contains(url.pathExtension.lowercased()) { return true }
        let name = url.lastPathComponent.lowercased()
        if name.contains("crash") || name.contains("diag") { return true }
        return role == .crash
    }

    /// 整份 reading 走崩溃通道：先看是不是 .ips（JSON），否则按纯文本崩溃日志处理。
    static func events(for reading: LogFileReading) -> [LogEvent] {
        guard isCrashReport(reading.url, role: reading.role) else { return [] }
        let path = reading.url.path
        let modifiedAt = reading.modifiedAt
        guard let text = readText(reading.url), !text.isEmpty else {
            return [synthesizedEvent(path: path, modifiedAt: modifiedAt)]
        }
        // .ips 以第一行 `{` 开头；不满足或解不出对象时内部直接返回 []。
        let diagnostic = parseDiagnosticReport(text: text, path: path, modifiedAt: modifiedAt)
        if !diagnostic.isEmpty { return diagnostic }
        let plain = parseCrashText(text: text, path: path, modifiedAt: modifiedAt)
        if !plain.isEmpty { return plain }
        return [synthesizedEvent(path: path, modifiedAt: modifiedAt)]
    }

    /// Apple DiagnosticReports 的 .ips：第一行是 header JSON，其余是 body JSON。
    static func parseDiagnosticReport(text: String, path: String, modifiedAt: Date) -> [LogEvent] {
        guard startsWithBrace(text) else { return [] }
        // header 占一行，body 是剩下的全部（可能 pretty-print 成很多行）。
        let pieces = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headerText = pieces.first.map(String.init) ?? ""
        let bodyText = pieces.count > 1 ? String(pieces[1]) : ""
        let header = jsonDictionary(headerText) ?? [:]
        // 极少数 .ips 是单行 JSON；body 解不开时整体再试一次。
        let body = jsonDictionary(bodyText) ?? jsonDictionary(text) ?? header
        guard !body.isEmpty || !header.isEmpty else { return [] }

        let exception = dictionary(body["exception"]) ?? dictionary(header["exception"])
        let termination = dictionary(body["termination"]) ?? dictionary(header["termination"])

        let exceptionType = firstNonEmpty([
            string(exception?["type"]),
            string(body["exceptionType"]),
        ])
        let signal = string(exception?["signal"])
        let codes = firstNonEmpty([
            stringOrJoined(exception?["codes"]),
            stringOrJoined(exception?["codes_if_signaled"]),
        ])
        let subtype = firstNonEmpty([
            string(exception?["subtype"]),
            string(body["exceptionStrings"]) == nil ? nil : stringOrJoined(body["exceptionStrings"]),
        ]).map { normalize($0) }

        let terminationText = firstNonEmpty([
            string(termination?["reason"]),
            string(termination?["indicator"]),
            stringOrJoined(termination?["notificationName"]),
        ])
        let terminationFlags = firstNonEmpty([string(termination?["flags"])])
        let bugType = firstNonEmpty([string(body["bug_type"]), string(header["bug_type"])])

        let procName = firstNonEmpty([
            string(body["procName"]),
            string(body["proc_name"]),
            string(header["app_name"]),
            string(header["appName"]),
        ]) ?? (path as NSString).lastPathComponent

        let appVersion = firstNonEmpty([
            string(body["app_version"]),
            string(header["app_version"]),
            string(body["versionNumber"]),
        ])
        let appSession = firstNonEmpty([string(body["app_session"]), string(header["app_session"])])
        let incidentID = firstNonEmpty([
            string(body["incident_id"]),
            string(body["incident_identifier"]),
            string(header["incident_id"]),
            string(header["incident_identifier"]),
        ])
        let osVersion = firstNonEmpty([string(body["os_version"]), string(header["os_version"])])
        let product = firstNonEmpty([string(body["product"]), string(header["product"])])

        // 线程：找 triggered / crashed 的那一个，取前 8 帧
        let threads = arrayOfDictionaries(body["threads"])
        let imageNames = usedImageNames(body["usedImages"])
        let triggered = threads.first { boolValue($0["triggered"]) || boolValue($0["crashed"]) }
            ?? (int(body["crashedThread"]).flatMap { index in index >= 0 && index < threads.count ? threads[index] : nil })
            ?? threads.first
        let rawFrames = (array(triggered?["backtrace"]) ?? array(triggered?["frames"]))
            ?? array(body["lastExceptionBacktrace"])
            ?? []
        var stackFrames: [String] = []
        var sourceFiles: [String] = []
        for (offset, frame) in rawFrames.prefix(ipsMaxFrames).enumerated() {
            guard let built = ipsFrame(frame, index: offset, imageNames: imageNames) else { continue }
            stackFrames.append(built.frame)
            if let file = built.file, !sourceFiles.contains(file) { sourceFiles.append(file) }
        }

        let threadLabel = firstNonEmpty([
            string(triggered?["name"]),
            string(triggered?["queue"]),
            string(triggered?["threadName"]),
        ])

        var messageParts: [String] = []
        messageParts.append("崩溃 \(procName)")
        if let bugType, !bugType.isEmpty { messageParts.append("bug_type \(clip(bugType, 40))") }
        if let exceptionType { messageParts.append(clip(exceptionType, 80)) }
        if let subtype, !subtype.isEmpty { messageParts.append(clip(subtype, 160)) }
        if let signal { messageParts.append(clip(signal, 40)) }
        if let codes, !codes.isEmpty { messageParts.append("codes " + clip(normalize(codes), 120)) }
        if let terminationText { messageParts.append("终止原因 " + clip(normalize(terminationText), 160)) }
        if let terminationFlags { messageParts.append("flags " + clip(terminationFlags, 40)) }
        if let threadLabel { messageParts.append("线程 " + clip(normalize(threadLabel), 80)) }
        for item in flattenASI(dictionary(body["asi"])) { messageParts.append(clip(item, 160)) }
        let message = normalize(messageParts.filter { !$0.isEmpty }.joined(separator: " · "))

        var rawParts: [String] = ["崩溃报告 \(path)"]
        rawParts.append("proc=\(procName)")
        if let appVersion { rawParts.append("app_version=" + clip(normalize(appVersion), 60)) }
        if let appSession { rawParts.append("session=" + clip(normalize(appSession), 60)) }
        if let incidentID { rawParts.append("incident=" + clip(normalize(incidentID), 60)) }
        if let product { rawParts.append("product=" + clip(normalize(product), 60)) }
        if let osVersion { rawParts.append("os=" + clip(normalize(osVersion), 80)) }
        let rawLine = rawParts.joined(separator: " ")

        guard message != "崩溃 \(procName)" || !stackFrames.isEmpty || exceptionType != nil else {
            // 一个崩溃字段都没读到：交给 events(for:) 走纯文本 / 兜底，不猜。
            return []
        }

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
        for (index, line) in lines.enumerated() where containsLabel(line, "incident identifier") {
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
            let lowercased = segment.joined(separator: "\n").lowercased()
            // 一份完整的报告头（有 Incident Identifier，或 Exception Type + 线程表）
            // 只算一次崩溃；否则段内每个锚点特征词各算一次（累积型 crash.log）。
            let singleReport = lowercased.contains("incident identifier")
                || (lowercased.contains("exception type") && lowercased.contains("thread "))
            let produced = parseTextSegment(
                lines: segment,
                lineNumberOffset: start,
                path: path,
                modifiedAt: modifiedAt,
                singleReport: singleReport
            )
            events.append(contentsOf: produced)
            if events.count >= maxTextEvents { break }
        }
        return Array(events.prefix(maxTextEvents))
    }

    /// 供聚类用的稳定签名，如 "EXC_BAD_ACCESS / KERN_INVALID_ADDRESS"、"SIGABRT"、"Fatal error"。
    static func crashSignature(from event: LogEvent) -> String? {
        let haystack = [event.message, event.rawLine].filter { !$0.isEmpty }.joined(separator: " · ")
        guard !haystack.isEmpty else { return nil }

        // 1) EXC_* 配合 KERN_* / BUS_* / SEGV_* 等机器码
        let exceptionToken = firstMatch(in: haystack, pattern: Self.exceptionTokenPattern)
        let machineToken = firstMatch(in: haystack, pattern: Self.machineCodePattern)
        if let exceptionToken {
            var result = exceptionToken
            if let machineToken, machineToken != exceptionToken { result += " / " + machineToken }
            let cleaned = normalize(result)
            return cleaned.isEmpty ? nil : cleaned
        }
        if let machineToken {
            let cleaned = normalize(machineToken)
            return cleaned.isEmpty ? nil : cleaned
        }
        // 2) 信号
        if let signal = firstMatch(in: haystack, pattern: Self.signalPattern) {
            let cleaned = normalize(signal)
            return cleaned.isEmpty ? nil : cleaned
        }
        // 3) 语言级 fatal 短语
        for phrase in fatalPhrases where firstMatch(in: haystack, pattern: phrase.pattern) != nil {
            let cleaned = normalize(phrase.label)
            return cleaned.isEmpty ? nil : cleaned
        }
        // 4) `Exception Type: <值>` / `Termination Reason: <值>`
        for pattern in [Self.exceptionTypeValuePattern, Self.terminationValuePattern] {
            if let value = firstGroup(in: haystack, pattern: pattern, group: 1), !value.isEmpty {
                let cleaned = normalize(clip(value, 120))
                if !cleaned.isEmpty { return cleaned }
            }
        }
        return nil
    }
}

// MARK: - 内部：判定表

extension CrashReportParser {
    /// 崩溃报告扩展名（Apple DiagnosticReports 常见后缀）。
    static let crashExtensions: Set<String> = [
        "ips", "crash", "panic", "diag", "spin", "csncrashed", "diagnostics",
    ]

    /// .ips 主事件带的帧数 / 纯文本单事件带的帧数。
    static let ipsMaxFrames = 8
    static let textMaxFrames = 12

    /// 防御性上限：单个崩溃文件最多读这么多字节、切这么多行、产这么多事件。
    static let maxReadBytes = 4_000_000
    static let maxTextLines = 20_000
    static let maxTextEvents = 2_000

    /// 特征词：`startsReport` 表示它足以单独算「一次崩溃」，
    /// false 表示它是同一份报告里的补充信息（只并进主事件）。
    struct Cue {
        let label: String
        let pattern: String
        let startsReport: Bool
        var regex: NSRegularExpression? { CrashReportParser.compiled(pattern) }
    }

    static let cues: [Cue] = [
        Cue("Fatal error", "\\bFatal error\\b", startsReport: true),
        Cue("Fatal Python error", "\\bFatal Python error\\b", startsReport: true),
        Cue("precondition failure", "\\bprecondition failure\\b", startsReport: true),
        Cue("assertion failure", "\\bassertion failure\\b", startsReport: true),
        Cue("pure virtual method called", "\\bpure virtual method called\\b", startsReport: true),
        Cue("terminate called after throwing", "\\bterminate called after throwing\\b", startsReport: true),
        Cue("kernel panic", "\\bkernel panic\\b", startsReport: true),
        Cue("uncaught exception", "\\buncaught exception\\b", startsReport: true),
        Cue("Incident Identifier", "\\bIncident Identifier\\s*:", startsReport: true),
        Cue("Exception Type", "\\bException Type\\s*:", startsReport: true),
        Cue("EXC_BAD_ACCESS", "\\bEXC_BAD_ACCESS\\b", startsReport: false),
        Cue("EXC_BAD_INSTRUCTION", "\\bEXC_BAD_INSTRUCTION\\b", startsReport: false),
        Cue("EXC_CRASH", "\\bEXC_CRASH\\b", startsReport: false),
        Cue("EXC_BREAKPOINT", "\\bEXC_BREAKPOINT\\b", startsReport: false),
        Cue("EXC_GUARD", "\\bEXC_GUARD\\b", startsReport: false),
        Cue("EXC_RESOURCE", "\\bEXC_RESOURCE\\b", startsReport: false),
        Cue("EXC", "\\bEXC_[A-Z][A-Z0-9_]{2,}\\b", startsReport: false),
        Cue("SIGSEGV", "\\bSIG(SEGV|ABRT|BUS|ILL|TRAP|KILL|SYS|EMT|XCPU|XFSZ|PIPE|TERM|INT|QUIT|STOP|USR1|USR2)\\b", startsReport: false),
        Cue("Thread Crashed", "\\bThread\\s+\\d+\\s+(?:Crashed|crashed)\\b", startsReport: false),
        Cue("Termination Reason", "\\bTermination Reason\\s*:", startsReport: false),
        Cue("Exception Codes", "\\bException (?:Codes|Subtype|Signal)\\s*:", startsReport: false),
        Cue("Triggered by Thread", "\\bTriggered by Thread\\s*:", startsReport: false),
        Cue("Segmentation fault", "\\bSegmentation fault\\b", startsReport: false),
        Cue("Abort trap", "\\bAbort trap\\b", startsReport: false),
    ]

    /// fatal 短语 -> 稳定签名标签（按声明顺序优先）。
    struct FatalPhrase {
        let label: String
        let pattern: String
        var regex: NSRegularExpression? { CrashReportParser.compiled(pattern) }
    }

    static let fatalPhrases: [FatalPhrase] = [
        FatalPhrase(label: "Fatal error", pattern: "\\bFatal error\\b"),
        FatalPhrase(label: "Fatal Python error", pattern: "\\bFatal Python error\\b"),
        FatalPhrase(label: "precondition failure", pattern: "\\bprecondition failure\\b"),
        FatalPhrase(label: "assertion failure", pattern: "\\bassertion failure\\b"),
        FatalPhrase(label: "terminate called after throwing", pattern: "\\bterminate called after throwing\\b"),
        FatalPhrase(label: "pure virtual method called", pattern: "\\bpure virtual method called\\b"),
        FatalPhrase(label: "kernel panic", pattern: "\\bkernel panic\\b"),
        FatalPhrase(label: "uncaught exception", pattern: "\\buncaught exception\\b"),
        FatalPhrase(label: "SIGSEGV", pattern: "\\bSegmentation fault\\b"),
        FatalPhrase(label: "SIGABRT", pattern: "\\bAbort trap\\b"),
    ]

    static let exceptionTokenPattern = "\\bEXC_[A-Z][A-Z0-9_]{2,}\\b"
    static let machineCodePattern = "\\b(?:KERN_[A-Z][A-Z_]{2,}|BUS_[A-Z][A-Z_]{2,}|ILL_[A-Z][A-Z_]{2,}|SEGV_[A-Z][A-Z_]{2,}|FPE_[A-Z][A-Z_]{2,})\\b"
    static let signalPattern = "\\bSIG(?:SEGV|ABRT|BUS|ILL|TRAP|KILL|SYS|EMT|XCPU|XFSZ|PIPE|TERM|INT|QUIT|STOP|USR1|USR2)\\b"
    static let exceptionTypeValuePattern = "\\bException Type\\s*:\\s*([^\\n·]+)"
    static let terminationValuePattern = "\\bTermination Reason\\s*:\\s*([^\\n·]+)"
    static let crashedThreadPattern = "^\\s*Thread\\s+\\d+\\s+(?:Crashed|crashed)\\b"
    static let anyThreadPattern = "^\\s*Thread\\s+\\d+\\b"
    static let sectionStopPattern = "^\\s*(?:Binary Images|Extra Information|Application Specific Information|Thread \\d+ crashed|Last Exception Backtrace|VM Regions|Used Images)\\b"
    static let dateLabelPattern = "^\\s*(?:Date/Time|Timestamp|Incident Date)\\s*:\\s*(.+)$"
    static let fileNameDatePattern = "(\\d{4})-(\\d{2})-(\\d{2})[-_](\\d{2})(\\d{2})?(\\d{2})?"

    /// 堆栈帧行：Apple 文本 `N  image  0xADDR  sym + 12`、lldb `frame #0: 0xADDR …`、`#N in file.ext:12`。
    static let framePatterns: [String] = [
        "^[ \\t]*\\d{1,3}[ \\t]+\\S+[ \\t]+0x[0-9a-fA-F]{6,}[ \\t]+\\S[^\\n]*[+-][ \\t]*\\d+[ \\t]*$",
        "^[ \\t]*(?:frame[ \\t]+)?#[ \\t]*\\d+[ \\t]*:?[ \\t]+0x[0-9a-fA-F]{6,}[ \\t]+\\S[^\\n]*$",
        "^[ \\t]*(?:frame[ \\t]+)?#[ \\t]*\\d+[ \\t]*:?[ \\t]+in[ \\t]+\\S[^\\n]*\\.(?:swift|m|mm|cc|cpp|c|py|js|ts|kt|java|go)\\b[^\\n]*$",
        "^[ \\t]*\\d{1,3}[ \\t]+\\S+[ \\t]+[^\\t\\n ]+[^\\n]*\\([^\\n)]*\\.(?:swift|m|mm|cc|cpp|c|py|js|ts):\\d+\\)[ \\t]*$",
    ]

    /// 源文件名（用于 sourceFiles / affectedFiles）。
    static let sourceFileNamePattern = "([A-Za-z0-9_+$.\\-/ ]*[/\\\\])?([A-Za-z0-9_+$.\\-]{1,120})\\.(swift|mm|m|cc|cpp|c|cxx|py|js|jsx|ts|tsx|kt|java|go|rs)\\b"

    private static var regexCache: [String: NSRegularExpression?] = [:]
    private static let cacheLock = NSLock()

    /// 正则编译一次就缓存；编译失败记 nil，调用方按「不匹配」处理，绝不抛异常。
    static func compiled(_ pattern: String) -> NSRegularExpression? {
        cacheLock.lock()
        let cached = regexCache[pattern]
        cacheLock.unlock()
        if let cached { return cached }
        let compiled = try? NSRegularExpression(pattern: pattern, options: [])
        cacheLock.lock()
        regexCache[pattern] = compiled
        cacheLock.unlock()
        return compiled
    }
}

// MARK: - 内部：纯文本段解析

extension CrashReportParser {
    private struct SegmentOutput {
        var events: [LogEvent] = []
        var primaryIndexes: [Int] = []
    }

    /// 段内规则：
    /// - 首个特征词（不论类别）一定成为主事件；
    /// - 之后的「锚点特征词」在单报告段里只并进主事件，在累积型段里各自成为新主事件；
    /// - 堆栈帧行追加到「上一条主事件」的 stackFrames（最多 12 帧），
    ///   同时产一条 isContinuation = true 的事件（上层不计数，只贡献 sourceFiles）。
    static func parseTextSegment(lines: [String],
                                 lineNumberOffset: Int,
                                 path: String,
                                 modifiedAt: Date,
                                 singleReport: Bool) -> [LogEvent] {
        var output = SegmentOutput()
        var currentPrimary: Int?
        var details: [String] = []
        var sawCrashedThread = false
        var inCrashedBlock = false
        var segmentDate: Date?

        func attachDetails() {
            guard let index = currentPrimary, !details.isEmpty else { details = []; return }
            let merged = ([output.events[index].message] + details).joined(separator: " · ")
            output.events[index].message = normalize(merged)
            details = []
        }

        for (offset, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let number = lineNumberOffset + offset + 1

            if matches(line, pattern: Self.crashedThreadPattern) {
                sawCrashedThread = true
                inCrashedBlock = true
            } else if matches(line, pattern: Self.anyThreadPattern) {
                inCrashedBlock = false
            }
            if matches(line, pattern: Self.sectionStopPattern) { inCrashedBlock = false }

            if let label = firstGroup(in: line, pattern: Self.dateLabelPattern, group: 1),
               let parsed = date(from: label, referenceDate: modifiedAt) {
                segmentDate = parsed
            }

            // 1) 堆栈帧行
            if isStackFrameLine(line), inCrashedBlock || !sawCrashedThread, let anchor = currentPrimary {
                let frame = frameText(line)
                if output.events[anchor].stackFrames.count < textMaxFrames {
                    output.events[anchor].stackFrames.append(frame)
                }
                output.events.append(LogEvent(
                    date: output.events[anchor].date,
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
                continue
            }

            // 2) 崩溃特征词
            guard let cue = matchedCue(in: line) else { continue }
            let startsNew = currentPrimary == nil || (!singleReport && cue.startsReport)
            if startsNew {
                attachDetails()
                let parsed = LogLineParser.parseLine(line, number: number, sourcePath: path, referenceDate: modifiedAt)
                let event = LogEvent(
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
                )
                output.events.append(event)
                currentPrimary = output.events.count - 1
                output.primaryIndexes.append(currentPrimary ?? -1)
            } else if details.count < 4 {
                details.append(clip(line, 160))
            }

            if output.events.count >= maxTextEvents { break }
        }
        attachDetails()

        // 单报告段：段里唯一那次崩溃的时间以 `Date/Time:` 为准。
        if singleReport, let segmentDate {
            for index in output.events.indices { output.events[index].date = segmentDate }
        }
        // 主事件的 sourceFiles 补上自己帧里出现过的文件。
        for index in output.primaryIndexes where index < output.events.count {
            var files = output.events[index].sourceFiles
            for frame in output.events[index].stackFrames {
                for file in sourceFiles(in: frame) where !files.contains(file) { files.append(file) }
            }
            output.events[index].sourceFiles = Array(files.prefix(8))
        }
        return output.events
    }

    private static func baseMessage(for parsed: ParsedLogLine) -> String {
        var base = parsed.message
        if let signature = LogLineParser.signature(for: parsed), !signature.isEmpty { base = signature }
        if base.isEmpty { base = parsed.raw }
        return normalize(base)
    }

    /// 与文本日志一致的归一化 + 长度裁剪。
    static func normalize(_ text: String) -> String {
        let cleaned = LogLineParser.normalizeMessage(text)
            .replacingOccurrences(of: "\u{0000}", with: " ")
        return clip(trimmed(cleaned), 900)
    }

    static func frameText(_ line: String) -> String {
        if let extracted = LogLineParser.stackFrame(in: line), !extracted.isEmpty {
            return clip(trimmed(extracted), 300)
        }
        return clip(trimmed(line), 300)
    }

    static func sourceFiles(in line: String) -> [String] {
        var files: [String] = []
        if let detected = LogLineParser.sourceFile(in: line) {
            let name = trimmed(detected)
            if !name.isEmpty { files.append(name) }
        }
        guard let regex = compiled(sourceFileNamePattern) else { return Array(files.prefix(4)) }
        let ns = line as NSString
        regex.enumerateMatches(in: line, options: [], range: NSRange(location: 0, length: ns.length)) { result, _, _ in
            guard let result else { return }
            let range = result.range(at: result.numberOfRanges > 2 ? 2 : 0)
            guard range.location != NSNotFound else { return }
            let raw = ns.substring(with: range)
            guard raw.count >= 3, raw.count <= 160 else { return }
            if raw.lowercased().contains("http") { return }
            let name = trimmed(raw)
            if !name.isEmpty, !files.contains(name) { files.append(name) }
        }
        return Array(files.prefix(4))
    }

    static func isStackFrameLine(_ line: String) -> Bool {
        framePatterns.contains { matches(line, pattern: $0) }
    }

    static func matchedCue(in line: String) -> Cue? {
        for cue in cues where matches(line, pattern: cue.pattern) { return cue }
        return nil
    }

    static func synthesizedEvent(path: String, modifiedAt: Date) -> LogEvent {
        let name = (path as NSString).lastPathComponent
        let message = normalize("崩溃报告 \(name)（未能解析出细节）")
        return LogEvent(
            date: modifiedAt,
            severity: .crash,
            rawLine: "崩溃报告 \(path)（未能解析出细节）",
            message: message,
            sourceLogPath: path,
            lineNumber: 1,
            stackFrames: [],
            sourceFiles: [],
            isCrash: true,
            isContinuation: false
        )
    }
}

// MARK: - 内部：.ips 取值工具（全部安全取，缺字段就跳过）

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

    static func firstNonEmpty(_ values: [String?]) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func containsLabel(_ line: String, _ label: String) -> Bool {
        line.lowercased().contains(label)
    }

    static func startsWithBrace(_ text: String) -> Bool {
        for character in text where !character.isNewline && character != " " && character != "\u{FEFF}" {
            return character == "{"
        }
        return false
    }

    static func jsonDictionary(_ text: String) -> [String: Any]? {
        let body = trimmed(text)
        guard body.hasPrefix("{"), let data = body.data(using: .utf8) else { return nil }
        if let object = try? JSONSerialization.jsonObject(with: data, options: []),
           let dictionary = object as? [String: Any] {
            return dictionary
        }
        // 尾部可能还有杂散内容：退到最后一个 `}` 再试一次。
        if let opening = body.firstIndex(of: "{"), let closing = body.lastIndex(of: "}"), opening < closing {
            let slice = String(body[opening...closing])
            if let data = slice.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data, options: []),
               let dictionary = object as? [String: Any] {
                return dictionary
            }
        }
        return nil
    }

    static func dictionary(_ value: Any?) -> [String: Any]? { value as? [String: Any] }
    static func array(_ value: Any?) -> [Any]? { value as? [Any] }

    static func arrayOfDictionaries(_ value: Any?) -> [[String: Any]] {
        (value as? [Any])?.compactMap { dictionary($0) } ?? []
    }

    /// 字符串 / NSNumber 都能读成字符串，读不到返回 nil。
    static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let text = value as? String { return Int(text.trimmingCharacters(in: .whitespaces)) }
        return nil
    }

    static func boolValue(_ value: Any?) -> Bool {
        if let flag = value as? Bool { return flag }
        if let number = value as? NSNumber { return number.boolValue }
        if let text = value as? String {
            let lower = text.lowercased()
            return lower == "true" || lower == "yes" || lower == "1"
        }
        return false
    }

    /// codes 既可能是字符串，也可能是数字数组，也可能是小字典。
    static func stringOrJoined(_ value: Any?) -> String? {
        if let text = value as? String { return text.isEmpty ? nil : text }
        if let number = value as? NSNumber { return number.stringValue }
        if let list = value as? [Any] {
            let parts = list.compactMap { element -> String? in
                if let text = element as? String { return text }
                if let number = element as? NSNumber { return number.stringValue }
                if let nested = element as? [Any] { return nested.compactMap({ string($0) }).joined(separator: ", ") }
                return nil
            }.filter { !$0.isEmpty }
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        }
        if let table = value as? [String: Any] {
            let parts = table.keys.sorted().prefix(8).compactMap { key -> String? in
                let value = stringOrJoined(table[key]) ?? ""
                return value.isEmpty ? nil : "\(key)=\(value)"
            }
            return parts.isEmpty ? nil : Array(parts).joined(separator: ", ")
        }
        return nil
    }

    /// `asi` 的每个 section 是 `[[key, [values]], …]`，平摊成 `key = v1, v2`。
    static func flattenASI(_ asi: [String: Any]?) -> [String] {
        guard let asi, !asi.isEmpty else { return [] }
        let preferred = ["Backtrace", "Diagnose"]
        let ordered = preferred.filter { asi[$0] != nil } + asi.keys.filter { !preferred.contains($0) }.sorted()
        var result: [String] = []
        for section in ordered {
            guard let entries = array(asi[section]) else { continue }
            for entry in entries {
                if let pair = array(entry), let key = string(pair.first), pair.count >= 2 {
                    let values = array(pair[1])?.compactMap { string($0) } ?? []
                    let joined = values.isEmpty ? (stringOrJoined(pair[1]) ?? "") : values.joined(separator: ", ")
                    if joined.isEmpty { continue }
                    result.append(normalize("\(key) = \(joined)"))
                } else if let table = dictionary(entry) {
                    for key in table.keys.sorted() {
                        guard let value = stringOrJoined(table[key]), !value.isEmpty else { continue }
                        result.append(normalize("\(key) = \(value)"))
                    }
                }
            }
            if result.count >= 6 { break }
        }
        return Array(result.prefix(6))
    }

    /// usedImages 顺序表：frame 只有 imageIndex 时用它补镜像名。
    static func usedImageNames(_ value: Any?) -> [String] {
        arrayOfDictionaries(value).map { dictionary in
            firstNonEmpty([string(dictionary["name"]), string(dictionary["bundleVersion"])]) ?? ""
        }
    }

    static func ipsFrame(_ raw: Any?, index: Int, imageNames: [String]) -> (frame: String, file: String?)? {
        guard let frame = dictionary(raw) else {
            if let text = string(raw) { return (clip(text, 300), nil) }
            return nil
        }
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

        var text = ""
        if let symbol, !symbol.isEmpty {
            text = clip(symbol, 160)
            if let filePath {
                let name = (filePath as NSString).lastPathComponent
                text += lineNumber.map { " (\(name):\($0))" } ?? " (\(name))"
            } else if let imageName {
                text += " in \(imageName)"
            }
        } else {
            text = "frame \(index)"
            if let imageName { text += " in \(imageName)" }
            if let offset { text += String(format: " + 0x%llx", offset) }
        }
        guard !text.isEmpty else { return nil }
        let file = filePath.map { ($0 as NSString).lastPathComponent }
        return (clip(text, 300), file?.isEmpty == false ? file : nil)
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
        for candidate in candidates {
            guard let candidate else { continue }
            if let parsed = date(from: candidate, referenceDate: modifiedAt) { return parsed }
        }
        if let fromName = dateFromFileName(path) { return fromName }
        return modifiedAt
    }

    static func date(from text: String, referenceDate: Date) -> Date? {
        let value = trimmed(text)
        guard value.count >= 8 else { return nil }
        if value.contains("-") || value.contains("/") {
            if let iso = iso8601(value) { return iso }
            let formats = [
                "yyyy-MM-dd HH:mm:ss.SS ZZZZ",
                "yyyy-MM-dd HH:mm:ss ZZZZ",
                "yyyy-MM-dd HH:mm:ss.SSSXXXXX",
                "yyyy-MM-dd HH:mm:ss.SS",
                "yyyy-MM-dd HH:mm:ss",
                "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
                "yyyy-MM-dd'T'HH:mm:ss",
                "yyyy-MM-dd HH:mm",
                "yyyy-MM-dd",
            ]
            for format in formats {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.isLenient = true
                formatter.dateFormat = format
                if let parsed = formatter.date(from: value) { return parsed }
            }
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

    /// `TcoderMonitor-2026-09-18-132231.ips` 这种文件名里带的时间。
    static func dateFromFileName(_ path: String) -> Date? {
        guard let groups = groups(in: (path as NSString).lastPathComponent, pattern: fileNameDatePattern),
              groups.count >= 4,
              let year = Int(groups[1] ?? ""), let month = Int(groups[2] ?? ""), let day = Int(groups[3] ?? "") {
            return nil
        }
        var components = DateComponents()
        components.year = Int(groups[1] ?? "")
        components.month = Int(groups[2] ?? "")
        components.day = Int(groups[3] ?? "")
        components.hour = Int(groups[4] ?? "")
        components.minute = groups.count > 5 ? Int(groups[5] ?? "") : nil
        components.second = groups.count > 6 ? Int(groups[6] ?? "") : nil
        components.timeZone = TimeZone.current
        return Calendar.current.date(from: components)
    }
}

// MARK: - 内部：正则匹配小工具

extension CrashReportParser {
    static func matches(_ text: String, pattern: String) -> Bool {
        guard let regex = compiled(pattern) else { return false }
        let ns = text as NSString
        return regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = compiled(pattern) else { return nil }
        let ns = text as NSString
        guard let result = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)),
              result.range(at: 0).location != NSNotFound else { return nil }
        return ns.substring(with: result.range(at: 0))
    }

    /// 返回 group 0...n 的数组（未命中的分组为 nil）。
    static func groups(in text: String, pattern: String) -> [String?]? {
        guard let regex = compiled(pattern) else { return nil }
        let ns = text as NSString
        guard let result = regex.firstMatch(in: text, options: [], range: NSRange(location: 0, length: ns.length)) else { return nil }
        var values: [String?] = []
        for index in 0..<result.numberOfRanges {
            let range = result.range(at: index)
            values.append(range.location == NSNotFound ? nil : ns.substring(with: range))
        }
        return values
    }

    static func firstGroup(in text: String, pattern: String, group: Int) -> String? {
        guard let values = groups(in: text, pattern: pattern) else { return nil }
        guard group < values.count, let value = values[group] else { return nil }
        let cleaned = trimmed(value)
        return cleaned.isEmpty ? nil : cleaned
    }
}
