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
//    **取不出证据就交回空数组** —— 由 `crashChannel(reading:)` 判成
//    「解析失败 / 疑似报告」，绝不合成一条崩溃事件冒充证据（RD-21 的根因就在这儿）。
// 3. 宁少不假：一份崩溃报告只产 1 条主事件；堆栈帧只进 stackFrames、不单独成事件；
//    纯文本通道为了 sourceFiles/affectedFiles 统计才额外产 isContinuation 事件
//    （上层按 isContinuation 排除计数）。
// 4. 进签名的内容一律先过 `LogLineParser.normalizeMessage`
//    （incident_id / uuid / 地址 / 绝对路径 必须归一化，否则每次崩溃都是新签名，聚不起来）。
// 5. 事件时间只认报告字段与报告文件名两种来源；**文件 mtime 不是事件时间**。

import Foundation

enum CrashReportParser {
    /// `.ips` / `.crash` / `.panic` / `.diag` / `.spin` / `.csncrashed` / `.diagnostics`
    /// 这些**内容格式**后缀，或被 `LogDiscovery` 按目录/名字归到 `.crash` 角色的文件，
    /// 才是崩溃通道的候选。
    ///
    /// 整改前这里还写着 `if name.contains("crash") || name.contains("diag") { return true }`
    /// —— 一个文件名就把普通日志推进了崩溃通道，**双向出错**：
    /// 一方面通道内取不出证据时合成一条假崩溃（9 次 vs 真值 2 次），
    /// 另一方面该文件被 `crashHandledPaths` 挡掉正常行解析，它真实的 3 条错误全丢
    /// （台账 §9.4 那次读数里 `errorCount = 0` 的来由）。
    /// 现在「候选」只决定**多看一眼**，不决定**下结论**。
    static func isCrashCandidate(_ url: URL, role: LogFileRole) -> Bool {
        crashExtensions.contains(url.pathExtension.lowercased()) || role == .crash
    }

    /// Apple DiagnosticReports 的 .ips：第一行是 header JSON，其余是 body JSON。
    ///
    /// 本函数只留「取两段 JSON → 取事实 → 取栈 → 有没有证据 → 拼 rawLine → 出事件」这条主线；
    /// 四段取值分别抽在下面四个函数里，**每个键的候选顺序、`?? ` 回退链、裁剪长度、
    /// 「宁少不假」的 hasEvidence 判据、以及 rawParts 的拼接顺序全部逐字照抄**。
    static func parseDiagnosticReport(text: String, path: String, modifiedAt: Date) -> [LogEvent] {
        guard startsWithBrace(text) else { return [] }
        let sections = ipsJSONSections(text)
        guard !sections.body.isEmpty || !sections.header.isEmpty else { return [] }

        let facts = ipsDiagnosticFacts(body: sections.body, header: sections.header, path: path)
        let stack = ipsDiagnosticStack(body: sections.body)
        guard ipsHasEvidence(facts: facts, stack: stack) else { return [] }

        // rawLine 装全部机器字段（含 Exception Type / signal / subtype）供排查与签名，
        // displayMessage 走 `title(...)` 这条统一口径：人先看懂「什么异常、崩在哪个符号」。
        let rawLine = ipsRawLine(path: path, facts: facts,
                                 threadLabel: stack.threadLabel, asiLines: stack.asiLines)
        let message = title(haystack: rawLine, symbol: stack.frames.first, procName: facts.procName)
        let timing = ipsEventDate(body: sections.body, header: sections.header,
                                  path: path, yearReference: modifiedAt)

        let event = LogEvent(
            date: timing.date,
            severity: .crash,
            rawLine: rawLine,
            message: message,
            sourceLogPath: path,
            lineNumber: 1,
            stackFrames: stack.frames,
            sourceFiles: stack.sourceFiles,
            isCrash: true,
            isContinuation: false,
            eventTimeSource: timing.source,
            appIdentity: ipsIdentity(from: facts),
            incidentID: facts.incidentID
        )
        return [event]
    }

    /// 报告自报的身份（RD-23 的五个维度：bundle id / 构建版本 / 发生时间 / 终止原因 / 采集环境）。
    static func ipsIdentity(from facts: IPSDiagnosticFacts) -> AppBuildIdentity {
        AppBuildIdentity(processName: emptyToNil(facts.procName),
                         bundleID: facts.bundleID,
                         appVersion: facts.appVersion,
                         buildVersion: facts.appVersion.flatMap(buildNumber(of:)),
                         osVersion: facts.osVersion,
                         product: facts.product,
                         terminationReason: facts.terminationText ?? facts.terminationFlags)
    }

    /// `"2.0 (9)"` 的括号内段；没有括号就用整串。
    static func buildNumber(of appVersion: String) -> String? {
        guard let open = appVersion.firstIndex(of: "("), let close = appVersion.lastIndex(of: ")"),
              open < close else {
            return trimmed(appVersion).isEmpty ? nil : trimmed(appVersion)
        }
        let value = trimmed(String(appVersion[appVersion.index(after: open)..<close]))
        return value.isEmpty ? nil : value
    }

    /// header 独占一行；body 是剩下的全部（可能 pretty-print 成很多行）。
    static func ipsJSONSections(_ text: String) -> (header: [String: Any], body: [String: Any]) {
        let pieces = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let headerText = pieces.first.map(String.init) ?? ""
        let bodyText = pieces.count > 1 ? String(pieces[1]) : ""
        let header = jsonDictionary(headerText) ?? [:]
        // 少数 .ips 是单行 JSON：body 解不开时整体再试一次，再不行退化成 header。
        let body = jsonDictionary(bodyText) ?? jsonDictionary(text) ?? header
        return (header, body)
    }

    /// 一份 .ips 的机器事实。每条 `firstNonEmpty([...])` 的候选顺序与拆分前一字不差。
    struct IPSDiagnosticFacts {
        var exceptionType: String?
        var signal: String?
        var codes: String?
        var subtype: String?
        var terminationText: String?
        var terminationFlags: String?
        var bugType: String?
        var procName: String
        var appVersion: String?
        var appSession: String?
        var incidentID: String?
        var osVersion: String?
        var product: String?
        /// 报告自报的 bundle id。只有部分 bug_type（309/409）会带；缺它是**归属维度不完整**，
        /// 不许改用目录名或文件名去补（RD-23）。
        var bundleID: String?
    }

    static func ipsDiagnosticFacts(body: [String: Any], header: [String: Any],
                                   path: String) -> IPSDiagnosticFacts {
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
        let bundleID = firstNonEmpty([
            string(body["bundleID"]),
            string(body["bundle_id"]),
            string(header["bundle_id"]),
            string(header["bundleID"]),
        ])

        return IPSDiagnosticFacts(exceptionType: exceptionType, signal: signal, codes: codes,
                                  subtype: subtype, terminationText: terminationText,
                                  terminationFlags: terminationFlags, bugType: bugType,
                                  procName: procName, appVersion: appVersion, appSession: appSession,
                                  incidentID: incidentID, osVersion: osVersion, product: product,
                                  bundleID: bundleID)
    }

    /// 线程与堆栈：找 triggered / crashed 的那一个，只取前 `ipsMaxFrames` 帧。
    struct IPSDiagnosticStack {
        var frames: [String]
        var sourceFiles: [String]
        var asiLines: [String]
        var threadLabel: String?
    }

    static func ipsDiagnosticStack(body: [String: Any]) -> IPSDiagnosticStack {
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
        let threadLabel = firstNonEmpty([
            string(triggered?["name"]),
            string(triggered?["queue"]),
            string(triggered?["threadName"]),
        ])
        return IPSDiagnosticStack(frames: stackFrames, sourceFiles: sourceFiles,
                                  asiLines: flattenASI(dictionary(body["asi"])), threadLabel: threadLabel)
    }

    /// 一个崩溃事实都没读到就返回 false，由 events(for:) 决定要不要合成兜底事件。
    /// 八条判据与它们的或运算顺序，逐字照抄拆分前那一句。
    static func ipsHasEvidence(facts: IPSDiagnosticFacts, stack: IPSDiagnosticStack) -> Bool {
        facts.exceptionType != nil || facts.signal != nil || facts.subtype != nil || facts.codes != nil
            || facts.terminationText != nil || facts.bugType != nil
            || !stack.frames.isEmpty || !stack.asiLines.isEmpty
    }

    /// rawLine 的拼装顺序就是拆分前那 15 个 append 的顺序：
    /// 崩溃报告路径 → proc → 异常四件套与终止原因 → 线程 → asi 前 4 条 → 身份五件套。
    /// 每段的裁剪长度（60/40/120/160/80）一字未改。
    static func ipsRawLine(path: String, facts: IPSDiagnosticFacts,
                           threadLabel: String?, asiLines: [String]) -> String {
        var rawParts: [String] = ["崩溃报告 \(path)", "proc=\(facts.procName)"]
        rawParts.append(contentsOf: ipsCrashFactParts(facts, threadLabel: threadLabel, asiLines: asiLines))
        rawParts.append(contentsOf: ipsIdentityFactParts(facts))
        return rawParts.joined(separator: " ")
    }

    static func ipsCrashFactParts(_ facts: IPSDiagnosticFacts,
                                  threadLabel: String?, asiLines: [String]) -> [String] {
        var parts: [String] = []
        if let exceptionType = facts.exceptionType { parts.append("Exception Type: " + clip(normalize(exceptionType), 60)) }
        if let signal = facts.signal { parts.append("signal " + clip(normalize(signal), 40)) }
        if let subtype = facts.subtype { parts.append("subtype " + clip(normalize(subtype), 120)) }
        if let bugType = facts.bugType { parts.append("bug_type " + clip(bugType, 40)) }
        if let codes = facts.codes { parts.append("codes " + clip(codes, 120)) }
        if let terminationText = facts.terminationText { parts.append("Termination Reason: " + clip(normalize(terminationText), 160)) }
        if let terminationFlags = facts.terminationFlags { parts.append("flags " + clip(terminationFlags, 40)) }
        if let threadLabel { parts.append("thread " + clip(normalize(threadLabel), 80)) }
        parts.append(contentsOf: asiLines.prefix(4).map { clip($0, 160) })
        return parts
    }

    static func ipsIdentityFactParts(_ facts: IPSDiagnosticFacts) -> [String] {
        var parts: [String] = []
        if let appVersion = facts.appVersion { parts.append("app_version=" + clip(normalize(appVersion), 60)) }
        if let appSession = facts.appSession { parts.append("session=" + clip(normalize(appSession), 60)) }
        if let incidentID = facts.incidentID { parts.append("incident=" + clip(normalize(incidentID), 60)) }
        if let product = facts.product { parts.append("product=" + clip(normalize(product), 60)) }
        if let osVersion = facts.osVersion { parts.append("os=" + clip(normalize(osVersion), 80)) }
        return parts
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
