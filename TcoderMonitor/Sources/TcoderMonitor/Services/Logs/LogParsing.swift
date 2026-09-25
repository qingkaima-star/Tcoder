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
    /// 折叠进来的堆栈头里出现的异常类名。异常类常在级别行的下一行，
    /// 签名要靠它才能落在 `java.lang.NullPointerException` 而不是前缀文案上。
    var exceptionToken: String? = nil
    /// `date` 是哪来的。**必须有这一格**，否则「事件时间」与「文件修改时间」在下游无法区分：
    /// 整改前崩溃通道会拿 mtime 兜底填 `date`，于是一份没有时间戳的旧报告
    /// 被算成"刚发生的崩溃"并进入窗口计数（RD-22）。
    var eventTimeSource: CrashEventTimeSource = .unavailable
    /// 报告自报的应用与构建身份（RD-23）。只有崩溃通道的事件会有。
    var appIdentity: AppBuildIdentity? = nil
    /// Apple 报告里的 incident id / 崩溃事件唯一号 —— 去重的第一优先键。
    var incidentID: String? = nil
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
    /// 一次都没读成功（打不开，或声明有内容却一行都没读到）。
    /// **必须与 `totalLines == 0` 的「读到尽头确实没有行」区分开**：
    /// 前者是「没核对」，后者是「核对过、零命中」；把前者混进 scannedFiles 会让
    /// 一次权限不足换来一张 all-clear（`LogSummary.hasData` 认 scannedFiles 非空）。
    var readFailed: Bool = false
    /// 为什么没读到（「权限不足」/「文件已不存在」/…）。与 `readFailed` 同时置位，
    /// 供 `ScannedLogFile.readFailure` 呈现给 UI——只有一个布尔的话，UI 说得出"跳过了"
    /// 却说不出为什么，用户无从判断这份日志是不是真的不需要看。
    var readFailure: String? = nil
}

struct LogAggregate: Sendable {
    var events: [LogEvent] = []
    var errorCount: Int = 0
    var exceptionCount: Int = 0
    var warningCount: Int = 0
    var crashCount: Int = 0
    var fatalCount: Int = 0
    var infoLineCount: Int = 0
    /// 密度分母：**真日志文件**读到的行数。`role == .crash` 的那些一律不在里面（RD-46b）。
    var totalLinesScanned: Int = 0
    /// 被移出分母的那些行去了哪儿：崩溃报告（读成功的那些）贡献的**正文行数**。
    /// 开这两格是为了"移出分母"不等于"消失"——行数仍然要能点名，否则只是把一次灌大
    /// 换成一次静默丢弃。落盘字段由总工统一开（`crashReportLineCount: Int?`），
    /// 现在的落盘侧替代读者是 `LogSummary.scannedFiles` 里 role == .crash 的那几份各自行数。
    var crashReportLineCount: Int = 0
    /// 崩溃报告的**份数**（读成功的）。它与 `crashCount`（**确认崩溃次数**）不是一回事：
    /// 一份报告可以含多次崩溃事件，也可以一份都没确认（疑似 / 解析失败 / 无事件时间）。
    /// 总工预备落的字段名：`crashReportCount: Int?`。
    var crashReportFileCount: Int = 0
    var topErrors: [ErrorCluster] = []
    var trend: [LogBucket] = []
    var affectedFiles: [String: Int] = [:]
    var windowStart: Date?
    var windowEnd: Date?
    /// 有真实事件时间、落在窗口内的事件才参与上面的各种计数。
    /// 下面两本是**被排除的部分**，它们不是 0，是"没算进来"（X3 的那条老红线）。
    var undatedEventCount: Int = 0
    var outOfWindowEventCount: Int = 0
    // RD-60 删掉了一格 `crashEvidence: CrashEvidenceLedger?`：它从 R4 起就**既无写者也无读者**
    // （`LogAggregate` 不出 `FileLogAnalyzer`，台账由 `analyzeWithEvidence` 那个口子直接交回），
    // 留着它正是 RD-34「有写无读」的胚胎。它没有被搬到别处 —— 台账本体在
    // `CrashEvidenceLedger`，上屏装配在 `CrashEvidenceReadout`，落盘载体是报给总工的契约缺口。
    // 删之前查过：按**裸名字** grep 全仓零引用（不只定义式）、`git stash list` 无在途实现、
    // 无第二处同名实现、也没有任何用例断言过它。
}

// MARK: - 尾部读取

enum LogReader {

    static func read(_ log: DiscoveredLog, maxBytes: Int, maxLines: Int) -> LogFileReading {
        var reading = LogFileReading(url: log.url, role: log.role, sizeBytes: log.sizeBytes,
                                     modifiedAt: log.modifiedAt)
        guard maxBytes > 0, maxLines > 0 else { return reading }
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: log.url)
        } catch {
            reading.readFailed = true
            reading.readFailure = readFailureReason(for: error)
            return reading
        }
        defer { try? handle.close() }

        let size = resolvedByteSize(of: log)
        reading.sizeBytes = size
        let startOffset = tailStartOffset(size: size, maxBytes: maxBytes)
        if startOffset > 0 {
            handle.seek(toFileOffset: startOffset)
        }
        var stream = LogStream(reading: reading, maxBytes: maxBytes, maxLines: maxLines,
                               size: size, startOffset: startOffset)
        let chunkLength = max(4_096, min(262_144, maxBytes))

        while !stream.stoppedByLineCap {
            guard let chunk = stream.nextChunk(from: handle, length: chunkLength) else { break }
            stream.ingest(chunk)
            if stream.exceededTailBudget() { break }
        }

        stream.flushTrailingBuffer()
        stream.finishEmptyFileDisclosure()
        return stream.reading
    }

    /// `log.sizeBytes` 声明为 0 时向文件系统再问一次。
    /// 这条回退是原 `read` 里的一段，判定（`size <= 0` 且拿得到 `.size`）逐字未改。
    static func resolvedByteSize(of log: DiscoveredLog) -> Int64 {
        guard log.sizeBytes <= 0 else { return log.sizeBytes }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: log.url.path),
              let number = attrs[.size] as? NSNumber else { return log.sizeBytes }
        return number.int64Value
    }

    /// 只读尾段：大文件整读进内存会直接把 App 压挂。返回尾段的起始偏移。
    /// 「`size > maxBytes` 就截尾并置 truncated」这条判定与拆分前一致。
    static func tailStartOffset(size: Int64, maxBytes: Int) -> UInt64 {
        guard size > Int64(maxBytes) else { return 0 }
        return UInt64(size - Int64(maxBytes))
    }

    /// 逐块读取到行末的全部可变状态。原先这些是 `read` 里的局部变量与四个嵌套闭包，
    /// 收进结构体只是为了让每个判定各自成一个短函数，**初值、置位时机、读取顺序一字未改**。
    fileprivate struct LogStream {
        var reading: LogFileReading
        let maxBytes: Int
        let maxLines: Int
        let size: Int64
        var builder: LogEventBuilder
        var buffer = Data()
        var droppingLeadingPartialLine: Bool
        var bytesFromDisk: UInt64
        var stoppedByLineCap = false
        /// 读取中途的错误。打开成功但读不出内容时，原因和「文件本来就是空的」必须分开——
        /// 前者是没核对，后者才是核对过零命中。
        var readError: Error?

        static let newline = UInt8(0x0A)
        static let carriageReturn = UInt8(0x0D)

        init(reading: LogFileReading, maxBytes: Int, maxLines: Int, size: Int64, startOffset: UInt64) {
            self.reading = reading
            self.maxBytes = maxBytes
            self.maxLines = maxLines
            self.size = size
            self.builder = LogEventBuilder(sourcePath: reading.url.path,
                                           referenceDate: reading.modifiedAt,
                                           role: reading.role)
            self.droppingLeadingPartialLine = startOffset > 0
            self.bytesFromDisk = startOffset
            // 时间戳缺年份时以文件修改时间为基准而不是「现在」，否则老日志会被推到未来
            if startOffset > 0 { self.reading.truncated = true }
        }

        /// 读一块；读到空（文件到底）与读失败都返回 nil，但**只有读失败才记 readError**。
        mutating func nextChunk(from handle: FileHandle, length: Int) -> Data? {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: length)
            } catch {
                if readError == nil { readError = error }
                return nil
            }
            guard let chunk, !chunk.isEmpty else { return nil }
            return chunk
        }

        /// 把一块字节按换行切成行喂给 builder，并处理「截断处的第一个半行」与行数上限。
        mutating func ingest(_ chunk: Data) {
            buffer.append(chunk)
            bytesFromDisk += UInt64(chunk.count)
            while let index = buffer.firstIndex(of: Self.newline) {
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
        }

        /// `size <= 0` 时（拿不到声明大小）只能用已读字节数当硬闸。
        mutating func exceededTailBudget() -> Bool {
            guard size <= 0, bytesFromDisk >= UInt64(maxBytes) else { return false }
            reading.truncated = true
            return true
        }

        /// 读到尽头剩下的最后一段：仍在「准备丢半行」的状态就不收尾，与拆分前一致。
        mutating func flushTrailingBuffer() {
            guard !stoppedByLineCap, !buffer.isEmpty, !droppingLeadingPartialLine else { return }
            consume(buffer)
        }

        mutating func consume(_ data: Data) {
            var lineData = data
            if lineData.last == Self.carriageReturn { lineData.removeLast() }
            builder.append(decode(lineData))
        }

        mutating func decode(_ data: Data) -> String {
            if data.isEmpty { return "" }
            if let text = String(data: data, encoding: .utf8) { return text }
            reading.parseErrors += 1
            return String(decoding: data, as: UTF8.self)
        }

        /// 收尾：行计数、事件、以及「声明有内容却一行都没读出来」这条诚实性披露。
        mutating func finishEmptyFileDisclosure() {
            reading.totalLines = builder.lineCount
            reading.linesRead = builder.lineCount
            reading.events = builder.events
            // 文件声明有内容、却一行都没读出来：这不是「空的」，这是没读进来。
            // 不标成读取失败，就会被当成「核对过、零命中」参与后续结论。
            if let readError {
                reading.readFailed = true
                reading.readFailure = LogReader.readFailureReason(for: readError)
            } else if reading.totalLines == 0 && reading.sizeBytes > 0 {
                reading.readFailed = true
                reading.readFailure = "文件有 \(reading.sizeBytes) 字节，却一行都没有读到"
            }
        }
    }

    /// 把「打不开 / 读不动」的错误翻成给用户看的一句话。
    ///
    /// 只把能确定成因的几类翻成短句；其余原样带上系统描述而不是兜一个「读取失败」——
    /// 「已跳过 3 份」这种话如果每份原因都一样，用户就分不出哪些是自己能修的（权限、
    /// 文件被移走）哪些是真故障。
    static func readFailureReason(for error: Error) -> String {
        for candidate in errorChain(error) {
            if candidate.domain == NSPOSIXErrorDomain,
               candidate.code == Int(EACCES) || candidate.code == Int(EPERM) {
                return "权限不足"
            }
            if candidate.domain == NSCocoaErrorDomain {
                if candidate.code == CocoaError.fileNoSuchFile.rawValue
                    || candidate.code == CocoaError.fileReadNoSuchFile.rawValue {
                    return "文件已不存在"
                }
                if candidate.code == CocoaError.fileReadNoPermission.rawValue {
                    return "权限不足"
                }
            }
        }
        return "无法读取（\((error as NSError).localizedDescription)）"
    }

    /// 错误本身，以及它一层层包着的 `NSUnderlyingError`。
    ///
    /// **必须往下走一层**：`FileHandle(forReadingFrom:)` 撞权限时外层是
    /// `NSCocoaErrorDomain` code **513**（不是 257 `fileReadNoPermission`，也不在 POSIX 域），
    /// 真正的 `EACCES` 只在 underlying 的 `NSPOSIXErrorDomain` 13 里。只看外层就会把
    /// 一份「权限不足」误报成一句长长的系统描述——本机编译产物探针实测：
    /// `outer=NSCocoaErrorDomain/513, underlying=NSPOSIXErrorDomain/13`。
    private static func errorChain(_ error: Error, depthLimit: Int = 5) -> [NSError] {
        var result: [NSError] = []
        var cursor: NSError? = error as NSError
        while let current = cursor, result.count < depthLimit {
            result.append(current)
            cursor = current.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return result
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
                                 isCrash: parentIsCrash, isContinuation: true,
                                 eventTimeSource: line.date == nil ? .unavailable : .logLineTimestamp)
            if let frame = line.stackFrame {
                event.stackFrames = [frame]
                events[parentIndex].stackFrames.append(frame)
            }
            if let file = line.sourceFile {
                event.sourceFiles = [file]
                events[parentIndex].sourceFiles.append(file)
            }
            if events[parentIndex].exceptionToken == nil, let token = LogLineParser.mainToken(in: line.raw) {
                events[parentIndex].exceptionToken = token
            }
            events.append(event)
            return
        }

        guard let severity = line.severity else {
            // 没有级别前缀、但带异常类名的裸行（`java.lang.NullPointerException: ...`）不是新事件：
            // 它是上一条错误的堆栈头。把类名挂到父事件上，签名才是「异常类名 + 消息」而不是前缀文案。
            if let parentIndex, LogLineParser.isErrorFamily(events[parentIndex].severity),
               events[parentIndex].exceptionToken == nil,
               let token = LogLineParser.mainToken(in: line.raw) {
                events[parentIndex].exceptionToken = token
            }
            return
        }
        let isCrash = severity == .crash || (role == .crash && LogLineParser.looksLikeCrash(line.raw))
        var event = LogEvent(date: line.date, severity: severity, rawLine: line.raw, message: line.message,
                             sourceLogPath: sourcePath, lineNumber: number, isCrash: isCrash,
                             eventTimeSource: line.date == nil ? .unavailable : .logLineTimestamp)
        if let frame = line.stackFrame { event.stackFrames = [frame] }
        if let file = line.sourceFile { event.sourceFiles = [file] }
        events.append(event)
        parentIndex = events.count - 1
    }
}
