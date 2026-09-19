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
    var totalLinesScanned: Int = 0
    var topErrors: [ErrorCluster] = []
    var trend: [LogBucket] = []
    var affectedFiles: [String: Int] = [:]
    var windowStart: Date?
    var windowEnd: Date?
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

        /// 读取中途的错误。打开成功但读不出内容时，原因和「文件本来就是空的」必须分开——
        /// 前者是没核对，后者才是核对过零命中。
        var readError: Error?

        func readChunk() -> Data? {
            do {
                return try handle.read(upToCount: chunkLength)
            } catch {
                if readError == nil { readError = error }
                return nil
            }
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
        // 文件声明有内容、却一行都没读出来：这不是「空的」，这是没读进来。
        // 不标成读取失败，就会被当成「核对过、零命中」参与后续结论。
        if let readError {
            reading.readFailed = true
            reading.readFailure = readFailureReason(for: readError)
        } else if reading.totalLines == 0 && reading.sizeBytes > 0 {
            reading.readFailed = true
            reading.readFailure = "文件有 \(reading.sizeBytes) 字节，却一行都没有读到"
        }
        return reading
    }

    /// 把「打不开 / 读不动」的错误翻成给用户看的一句话。
    ///
    /// 只把能确定成因的几类翻成短句；其余原样带上系统描述而不是兜一个「读取失败」——
    /// 「已跳过 3 份」这种话如果每份原因都一样，用户就分不出哪些是自己能修的（权限、
    /// 文件被移走）哪些是真故障。
    static func readFailureReason(for error: Error) -> String {
        let cocoa = error as NSError
        if cocoa.domain == NSCocoaErrorDomain {
            if cocoa.code == CocoaError.fileReadNoSuchFile.rawValue
                || cocoa.code == CocoaError.fileNoSuchFile.rawValue {
                return "文件已不存在"
            }
            if cocoa.code == CocoaError.fileReadNoPermission.rawValue {
                return "权限不足"
            }
        }
        if cocoa.domain == NSPOSIXErrorDomain, cocoa.code == Int(EACCES) || cocoa.code == Int(EPERM) {
            return "权限不足"
        }
        return "无法读取（\(cocoa.localizedDescription)）"
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
                             sourceLogPath: sourcePath, lineNumber: number, isCrash: isCrash)
        if let frame = line.stackFrame { event.stackFrames = [frame] }
        if let file = line.sourceFile { event.sourceFiles = [file] }
        events.append(event)
        parentIndex = events.count - 1
    }
}
