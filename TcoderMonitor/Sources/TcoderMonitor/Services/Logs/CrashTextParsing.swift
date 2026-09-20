//
// 崩溃报告的纯文本通道：按 `Incident Identifier` 切段、段内找主事件、把堆栈帧挂回上一条，
// 以及统一的标题口径 `title(haystack:symbol:procName:)`（机器字段只进 rawLine）。
// 从 CrashReportParser.swift 拆出，语义不变。
//
import Foundation

// MARK: - 内部：纯文本段解析

extension CrashReportParser {
    /// 段内可变状态。原先这些是 `parseTextSegment` 里的七个局部变量，
    /// 收进一个结构体只为把逐行判定拆成小函数，**初值与含义一字未改**。
    struct CrashSegmentState {
        var events: [LogEvent] = []
        var primaryIndexes: [Int] = []
        var currentPrimary: Int?
        var details: [String] = []
        var sawCrashedThread = false
        var inCrashedBlock = false
        var segmentDate: Date?
    }

    /// 段内规则（与拆分前逐字一致）：
    /// - 首个特征词（不论类别）一定成为主事件；
    /// - 之后的锚点特征词：单报告段里只并进主事件，累积型段里各自成为新主事件；
    /// - 非锚点特征词（Exception Codes / Termination Reason / Thread N Crashed …）
    ///   永远并进当前主事件，最多并 4 条；
    /// - 堆栈帧行追加到「上一条主事件」的 stackFrames（最多 12 帧），
    ///   同时产一条 isContinuation = true 的事件（上层不计数，只贡献 sourceFiles）。
    /// 本函数只保留逐行驱动与两处 `maxTextEvents` 上限判断。
    static func parseTextSegment(lines: [String],
                                 lineNumberOffset: Int,
                                 path: String,
                                 modifiedAt: Date,
                                 singleReport: Bool) -> [LogEvent] {
        var state = CrashSegmentState()
        for (offset, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            let number = lineNumberOffset + offset + 1
            observeCrashedThreadBlock(line, in: &state)
            noteSegmentDate(line, modifiedAt: modifiedAt, in: &state)

            if consumeCrashFrameLine(line, number: number, path: path, in: &state) {
                if state.events.count >= maxTextEvents { break }
                continue
            }
            consumeCrashCueLine(line, number: number, path: path, modifiedAt: modifiedAt,
                                singleReport: singleReport, in: &state)
            if state.events.count >= maxTextEvents { break }
        }
        flushCrashDetails(in: &state)
        applySegmentDate(singleReport: singleReport, in: &state)
        backfillPrimarySourceFiles(in: &state)
        return state.events
    }

    /// 崩溃线程块跟踪：帧只在 Crashed 块里收（整段没出现过线程表就一律收）。
    static func observeCrashedThreadBlock(_ line: String, in state: inout CrashSegmentState) {
        if crashedThreadPattern.matches(line) {
            state.sawCrashedThread = true
            state.inCrashedBlock = true
        } else if anyThreadPattern.matches(line) {
            state.inCrashedBlock = false
        }
        if sectionStopPattern.matches(line) { state.inCrashedBlock = false }
    }

    static func noteSegmentDate(_ line: String, modifiedAt: Date, in state: inout CrashSegmentState) {
        guard let label = dateLabelPattern.firstGroup(in: line, 1),
              let parsed = date(from: label, referenceDate: modifiedAt) else { return }
        state.segmentDate = parsed
    }

    /// 1) 堆栈帧行：追加到上一条主事件 + 产一条 isContinuation 事件。
    /// 返回 true 表示这一行确实是帧行且已被消费（调用方据此 `continue`），
    /// 判定式 `isStackFrame && (inCrashedBlock || !sawCrashedThread) && currentPrimary != nil`
    /// 与拆分前的三元条件逐个操作数相同。
    static func consumeCrashFrameLine(_ line: String, number: Int, path: String,
                                      in state: inout CrashSegmentState) -> Bool {
        guard isStackFrame(line), state.inCrashedBlock || !state.sawCrashedThread,
              let anchor = state.currentPrimary else { return false }
        let frame = frameText(line)
        if state.events[anchor].stackFrames.count < textMaxFrames {
            state.events[anchor].stackFrames.append(frame)
        }
        state.events.append(LogEvent(
            date: state.events[anchor].date,
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
        return true
    }

    /// 2) 崩溃特征词：够格就另起主事件，否则并进当前主事件的机器字段（最多 4 条）。
    static func consumeCrashCueLine(_ line: String, number: Int, path: String,
                                    modifiedAt: Date, singleReport: Bool,
                                    in state: inout CrashSegmentState) {
        guard let cue = matchedCue(in: line) else { return }
        if state.currentPrimary == nil || (!singleReport && cue.startsReport) {
            flushCrashDetails(in: &state)
            let parsed = LogLineParser.parseLine(line, number: number, sourcePath: path, referenceDate: modifiedAt)
            state.events.append(LogEvent(
                date: parsed.date ?? state.segmentDate ?? modifiedAt,
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
            let anchor = state.events.count - 1
            state.currentPrimary = anchor
            state.primaryIndexes.append(anchor)
        } else if state.details.count < 4 {
            state.details.append(clip(line, 160))
        }
    }

    /// 把攒下的机器字段并进当前主事件：rawLine 拼接后按统一口径重排标题。
    static func flushCrashDetails(in state: inout CrashSegmentState) {
        defer { state.details = [] }
        guard let index = state.currentPrimary, index < state.events.count,
              !state.details.isEmpty else { return }
        // 机器字段（Exception Codes / Termination Reason / Thread N Crashed …）并进 rawLine 供排查，
        // 标题按统一口径重排，不再用「 · 」把整段拼起来当标题。
        let haystack = ([state.events[index].rawLine] + state.details).joined(separator: " ")
        state.events[index].rawLine = haystack
        state.events[index].message = CrashReportParser.title(haystack: haystack,
                                                              symbol: state.events[index].stackFrames.first,
                                                              procName: nil)
    }

    /// 单报告段：段里那次崩溃的时间以 `Date/Time:` 为准（比文件 mtime 可信）。
    static func applySegmentDate(singleReport: Bool, in state: inout CrashSegmentState) {
        guard singleReport, let segmentDate = state.segmentDate else { return }
        for index in state.events.indices { state.events[index].date = segmentDate }
    }

    /// 主事件的 sourceFiles 补上它自己帧里出现过的文件（每事件最多 8 个）。
    static func backfillPrimarySourceFiles(in state: inout CrashSegmentState) {
        for index in state.primaryIndexes where index < state.events.count {
            var files = state.events[index].sourceFiles
            for frame in state.events[index].stackFrames {
                for file in sourceFiles(in: frame) where !files.contains(file) { files.append(file) }
            }
            state.events[index].sourceFiles = Array(files.prefix(8))
        }
    }

    /// 与文本日志保持一致的归一化：优先 signature(for:)，退回 message，再退回整行。
    static func baseMessage(for parsed: ParsedLogLine) -> String {
        title(haystack: parsed.raw.isEmpty ? parsed.message : parsed.raw, symbol: nil, procName: nil)
    }

    /// 崩溃标题的唯一口径（用户实测反馈：不能把裸 JSON / 机器字段当标题）。
    /// 顺序：Exception Type（带信号）→ 崩溃于哪个符号 → KERN_/BUS_ 等机器码 → 终止原因；
    /// 一个都取不到才退回原文。`bug_type` / `codes` / `flags` / `Incident Identifier` 一律不进标题。
    static func title(haystack: String, symbol: String?, procName: String?) -> String {
        var parts: [String] = []
        let exception = clip(normalize(firstClause(exceptionTypeValuePattern.firstGroup(in: haystack, 1)
                                                  ?? exceptionTypePattern.firstGroup(in: haystack, 0))), 60)
        let signal = clip(normalize(signalPattern.firstGroup(in: haystack, 0) ?? ""), 24)
        if !exception.isEmpty {
            // `Exception Type: EXC_BAD_ACCESS (SIGSEGV)` 本身常带信号，别再拼第二遍。
            parts.append(signal.isEmpty || exception.contains(signal) ? exception : "\(exception) (\(signal))")
        } else if !signal.isEmpty {
            parts.append(signal)
        }
        if let symbol, !symbol.isEmpty { parts.append("崩溃于 " + clip(humanize(symbol), 90)) }
        if let machine = machineCodePattern.firstGroup(in: haystack, 0) { parts.append(machine) }
        if parts.isEmpty, let termination = terminationValuePattern.firstGroup(in: haystack, 1) {
            parts.append("终止原因 " + clip(normalize(firstClause(termination)), 120))
        }
        if let procName, !procName.isEmpty { parts.append("进程 \(procName)") }
        if parts.isEmpty { parts.append(clip(normalize(haystack), 120)) }
        return normalize(parts.joined(separator: " · "))
    }

    /// 值捕获用的截断：`Exception Type:` 这类正则会一路吃到行尾，把后面的
    /// `Exception Codes` / `Thread N` / `subtype` 等机器字段也吞进标题。
    /// 这里在第一个已知机器键处切一刀，只留人要看的那一段。
    static let machineKeyStops: [String] = [
        "Exception Codes", "Exception Subtype", "Termination Reason", "Incident Identifier",
        "Crash Reporter", "Thread ", "signal ", "subtype ", "flags ", "bug_type ", "codes ",
        "session=", "incident=", "app_version=", "product=", "os=", "proc=",
    ]

    static func firstClause(_ text: String?) -> String {
        guard let text, !text.isEmpty else { return "" }
        var cut = text.endIndex
        for key in machineKeyStops {
            guard let found = text.range(of: key) else { continue }
            if found.lowerBound < cut { cut = found.lowerBound }
        }
        return String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
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
