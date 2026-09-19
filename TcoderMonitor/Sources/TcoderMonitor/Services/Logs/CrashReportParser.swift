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
        // Apple 的 .ips 有两种写法：`"frames": [...]` 直挂，或 `"backtrace": {"frames": [...]}` 包一层。
        // 只认前者的话，真实报告（后者）的整条崩溃栈会被丢掉，标题里就没有可读符号。
        let nestedFrames = dictionary(triggered?["backtrace"]).flatMap { array($0["frames"]) }
        let rawFrames = (array(triggered?["frames"])
            ?? array(triggered?["backtrace"])
            ?? nestedFrames)
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

        // rawLine 装全部机器字段（含 Exception Type / signal / subtype）供排查与签名，
        // displayMessage 走 `title(...)` 这条统一口径：人先看懂「什么异常、崩在哪个符号」。
        var rawParts: [String] = ["崩溃报告 \(path)", "proc=\(procName)"]
        if let exceptionType { rawParts.append("Exception Type: " + clip(normalize(exceptionType), 60)) }
        if let signal { rawParts.append("signal " + clip(normalize(signal), 40)) }
        if let subtype { rawParts.append("subtype " + clip(normalize(subtype), 120)) }
        if let bugType { rawParts.append("bug_type " + clip(bugType, 40)) }
        if let codes { rawParts.append("codes " + clip(codes, 120)) }
        if let terminationText { rawParts.append("Termination Reason: " + clip(normalize(terminationText), 160)) }
        if let terminationFlags { rawParts.append("flags " + clip(terminationFlags, 40)) }
        if let threadLabel { rawParts.append("thread " + clip(normalize(threadLabel), 80)) }
        rawParts.append(contentsOf: asiLines.prefix(4).map { clip($0, 160) })
        if let appVersion { rawParts.append("app_version=" + clip(normalize(appVersion), 60)) }
        if let appSession { rawParts.append("session=" + clip(normalize(appSession), 60)) }
        if let incidentID { rawParts.append("incident=" + clip(normalize(incidentID), 60)) }
        if let product { rawParts.append("product=" + clip(normalize(product), 60)) }
        if let osVersion { rawParts.append("os=" + clip(normalize(osVersion), 80)) }
        let rawLine = rawParts.joined(separator: " ")
        let message = title(haystack: rawLine, symbol: stackFrames.first, procName: procName)

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
