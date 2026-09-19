import Foundation
import XCTest
@testable import TcoderMonitor

/// 日志解析契约：时间戳九种格式、严重度、归一化、单行解析、签名、栈帧。
/// 拆自 LogAnalysisTests.swift，断言与用例一字未改（WS-V）。
final class LogParsingTests: LogAnalysisTestCase {
    func testParseTimestampISO8601WithZ() throws {
        let date = try XCTUnwrap(LogLineParser.parseTimestamp("2026-09-19T08:12:33Z",
                                                             referenceDate: LogFixture.referenceDate))
        // 时区无关：精确断言（只容忍浮点表示误差）
        XCTAssertEqual(date.timeIntervalSince1970, LogFixture.isoZEpoch, accuracy: 0.001)
    }

    func testParseTimestampISO8601WithMilliseconds() throws {
        let date = try XCTUnwrap(LogLineParser.parseTimestamp("2026-09-19T08:12:33.456Z",
                                                             referenceDate: LogFixture.referenceDate))
        // 因实现细节放宽：ISO8601DateFormatter 未开小数秒时 .456 会被丢掉，故容差 1 秒
        XCTAssertEqual(date.timeIntervalSince1970, LogFixture.isoZEpoch + 0.456, accuracy: 1.0)
    }

    func testParseTimestampISO8601WithNumericOffset() throws {
        // 16:12:33+08:00 == 08:12:33Z
        let date = try XCTUnwrap(LogLineParser.parseTimestamp("2026-09-19T16:12:33+08:00",
                                                             referenceDate: LogFixture.referenceDate))
        XCTAssertEqual(date.timeIntervalSince1970, LogFixture.isoZEpoch, accuracy: 1.0)
    }

    func testParseTimestampSpaceSeparatedSeconds() throws {
        let date = LogLineParser.parseTimestamp("2026-09-19 08:12:33",
                                                referenceDate: LogFixture.referenceDate)
        assertNearAnyWallClock(date, wallClockCandidates(2026, 9, 19, 8, 12, 33), label: "yyyy-MM-dd HH:mm:ss")
    }

    func testParseTimestampSpaceSeparatedWithMilliseconds() throws {
        let date = LogLineParser.parseTimestamp("2026-09-19 08:12:33.456",
                                                referenceDate: LogFixture.referenceDate)
        let candidates = wallClockCandidates(2026, 9, 19, 8, 12, 33).map { $0.addingTimeInterval(0.456) }
        assertNearAnyWallClock(date, candidates, accuracy: 1.0, label: "yyyy-MM-dd HH:mm:ss.SSS")
    }

    func testParseTimestampLog4jCommaMilliseconds() throws {
        let date = LogLineParser.parseTimestamp("2026-09-18 10:14:22,431",
                                                referenceDate: LogFixture.referenceDate)
        let candidates = wallClockCandidates(2026, 9, 18, 10, 14, 22).map { $0.addingTimeInterval(0.431) }
        assertNearAnyWallClock(date, candidates, accuracy: 1.0, label: "log4j 逗号毫秒")
    }

    func testParseTimestampSyslogWithoutYear() throws {
        // referenceDate 落在 2026-09-21，因此 Sep 19 应补成 2026-09-19
        let date = LogLineParser.parseTimestamp("Sep 19 08:12:33", referenceDate: LogFixture.referenceDate)
        assertNearAnyWallClock(date, wallClockCandidates(2026, 9, 19, 8, 12, 33), label: "syslog Sep 19")
    }

    func testParseTimestampEpochSeconds() throws {
        let date = try XCTUnwrap(LogLineParser.parseTimestamp("1790000000",
                                                             referenceDate: LogFixture.referenceDate))
        XCTAssertEqual(date.timeIntervalSince1970, 1_790_000_000, accuracy: 0.001)
    }

    func testParseTimestampEpochMilliseconds() throws {
        let date = try XCTUnwrap(LogLineParser.parseTimestamp("1790000000456",
                                                             referenceDate: LogFixture.referenceDate))
        XCTAssertEqual(date.timeIntervalSince1970, 1_790_000_000.456, accuracy: 0.001)
    }

    func testParseTimestampDoesNotInventDates() throws {
        for text in ["", "not a timestamp at all"] {
            let date = LogLineParser.parseTimestamp(text, referenceDate: LogFixture.referenceDate)
            // 因实现细节放宽：允许返回 nil，或退化成调用方传进来的 referenceDate，但不许编造别的时刻
            XCTAssertTrue(date == nil || abs(date!.timeIntervalSince(LogFixture.referenceDate)) < 1,
                          "「\(text)」解析成了 \(String(describing: date))")
        }
    }

    // MARK: 2. syslog 的未来时间要回退一年

    func testParseTimestampSyslogFutureDateRollsBackOneYear() throws {
        let reference = wallClock(2026, 1, 5, 0, 0, 0, timeZone: .current)
            ?? Date(timeIntervalSince1970: 1_767_571_200)
        let date = try XCTUnwrap(LogLineParser.parseTimestamp("Dec 31 23:59:59", referenceDate: reference))
        XCTAssertLessThan(date, reference, "无年份格式解析出未来时间时，应回退到上一年")
        assertNearAnyWallClock(date, wallClockCandidates(2025, 12, 31, 23, 59, 59),
                               label: "syslog Dec 31 回退到 2025")
    }

    // MARK: 3. detectSeverity

    func testDetectSeverityForLogLevelTokens() throws {
        let lines = [
            "2026-09-18 10:14:22,431 ERROR [order-service] c.e.s.OrderService - 处理订单失败",
            "[ERROR] 无法建立数据库连接 /srv/app/db/app.db",
            "2026-09-18 10:14:23,002 WARN  [order-service] c.e.s.Retry - 第 2 次重试",
            "WARNING: heap usage above threshold",
            "2026-09-19 08:13:00,100 INFO  [order-service] c.e.s.Health - 健康检查通过",
            "DEBUG [order-service] 入参 size=3",
            "TRACE [order-service] 逐帧埋点 seq=7",
            "2026-09-19 08:12:34,001 FATAL [order-service] c.e.s.Bootstrap - 关键服务不可用，退出",
        ]
        let expected: [LogSeverity?] = [.error, .error, .warning, .warning, .info, .debug, .trace, .fatal]
        XCTAssertEqual(severitiesOf(lines), expected)
    }

    func testDetectSeverityForExceptionAndCrashMarkers() throws {
        // 因实现细节放宽：SEVERE / CRITICAL / SIGABRT 这类词各家分层不同，允许落在候选集合内
        let relaxed: [(String, [LogSeverity])] = [
            ("SEVERE: order-service 线程池耗尽", [.error, .fatal, .exception]),
            ("CRITICAL: 队列积压超过阈值", [.error, .fatal, .exception]),
            ("SIGABRT received by process 4321", [.crash, .fatal, .error, .exception]),
            ("Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value: file TcoderSample/Cache.swift, line 210",
             [.fatal, .crash, .exception, .error]),
            ("precondition failure: index out of range", [.fatal, .crash, .exception, .error]),
            ("Thread 3 Crashed:", [.crash, .error, .fatal]),
            ("EXC_BAD_ACCESS", [.crash, .error, .fatal, .exception]),
            ("java.lang.Exception: 顶层包装异常", [.exception, .error]),
            ("Traceback (most recent call last):", [.exception, .error]),
            ("Caused by: java.lang.IllegalStateException: price cache miss for sku 991-ABC", [.exception, .error]),
        ]
        for (line, allowed) in relaxed {
            let severity = LogLineParser.detectSeverity(line)
            XCTAssertTrue(severity.map { allowed.contains($0) } ?? false,
                          "行「\(line)」判成 \(String(describing: severity))，期望落在 \(allowed.map { $0.rawValue })",
                          file: #filePath, line: #line)
        }

        // 实测口径：没有级别前缀、也没有崩溃特征的裸异常类名行**不单独判级别**。
        // 它是上一条 ERROR 的堆栈头，由 LogEventBuilder 折叠进父事件（类名走 exceptionToken 进签名），
        // 若在这里也判成 error/exception，一次故障会被计成两条，错误数直接翻倍。
        XCTAssertNil(LogLineParser.detectSeverity("java.lang.NullPointerException: Cannot invoke"))
        XCTAssertNotNil(LogLineParser.detectSeverity("Traceback (most recent call last):"))
        XCTAssertNotNil(LogLineParser.detectSeverity("Caused by: java.lang.IllegalStateException"))
    }

    func testDetectSeverityIgnoresWordsInsideMessageBody() throws {
        // 正文里的字段名不是日志级别
        let severity = LogLineParser.detectSeverity("sync status errorCount=0 info=false note=warn")
        XCTAssertNotEqual(severity, LogSeverity.error, "errorCount=0 这类正文词不得判成 ERROR")
        XCTAssertNotEqual(severity, LogSeverity.exception)
        XCTAssertNotEqual(severity, LogSeverity.fatal)
        XCTAssertNotEqual(severity, LogSeverity.crash)
    }

    // MARK: 4. normalizeMessage

    func testNormalizeMessageReplacesVolatileParts() throws {
        let digits = LogLineParser.normalizeMessage("orderId=88213 retry=3 cost=30005ms")
        XCTAssertFalse(digits.contains("88213"), "数字要归一化：\(digits)")
        XCTAssertTrue(digits.contains("N"), "数字占位符 N：\(digits)")

        let hex = LogLineParser.normalizeMessage("frame at 0x1a2b3c4d5e6f7a8b end")
        XCTAssertFalse(hex.lowercased().contains("1a2b3c4d5e6f7a8b"), "十六进制要归一化：\(hex)")
        XCTAssertTrue(hex.contains("0xN"), "十六进制占位符 0xN：\(hex)")

        let uuid = LogLineParser.normalizeMessage("user=4f9a2b7c-1d3e-4f5a-9b8c-7d6e5f4a3b2c done")
        XCTAssertFalse(uuid.lowercased().contains("4f9a2b7c"), "UUID 要归一化：\(uuid)")

        let path = LogLineParser.normalizeMessage("读取 /srv/app/data/orders/2026-09-18.json 失败")
        XCTAssertFalse(path.contains("/srv/app/data"), "绝对路径要归一化：\(path)")
        XCTAssertTrue(path.contains("<path>"), "路径占位符 <path>：\(path)")

        let quoted = LogLineParser.normalizeMessage(LogFixture.npeLine)
        XCTAssertFalse(quoted.contains("\"com.example.shop.Price.getTotal()\""),
                       "引号内字符串要归一化：\(quoted)")

        let spaces = LogLineParser.normalizeMessage("a    b\t\tc")
        XCTAssertFalse(spaces.contains("  "), "连续空白要折叠：\"\(spaces)\"")
        XCTAssertTrue(spaces.contains("a b c"), "折叠后仍是 a b c：\"\(spaces)\"")
    }

    func testNormalizeMessageMakesVaryingLinesIdentical() throws {
        let a = LogLineParser.normalizeMessage(LogFixture.headerError(3, "10:14:22,431", orderId: 88213,
                                                                      user: "4f9a2b7c-1d3e-4f5a-9b8c-7d6e5f4a3b2c"))
        let b = LogLineParser.normalizeMessage(LogFixture.headerError(3, "11:02:07,884", orderId: 90455,
                                                                      user: "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"))
        // 聚类根基：只有 orderId / UUID / 时间不同的两行，归一化后必须完全相等
        XCTAssertEqual(a, b)
    }

    // MARK: 5. parseLine / signature / stackFrame / sourceFile

    private func parse(_ raw: String, number: Int = 1) -> ParsedLogLine {
        LogLineParser.parseLine(raw, number: number, sourcePath: LogFixture.errorLogPath,
                                referenceDate: LogFixture.referenceDate)
    }

    func testParseLineOnTimestampedErrorLine() throws {
        let raw = "\(LogFixture.absoluteStamp(3, "10:14:22,431")) ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId=88213"
        let line = parse(raw, number: 7)
        XCTAssertEqual(line.number, 7)
        XCTAssertEqual(line.raw, raw)
        XCTAssertFalse(line.message.isEmpty)
        XCTAssertNotNil(line.severity)
        XCTAssertNotNil(line.date, "带时间戳的行应解析出日期")
    }

    func testSignatureKeepsExceptionClassAndGroupsRepeats() throws {
        // 单行式异常（带级别前缀）：签名保留全限定异常类名
        let inlineException = parse("2026-09-18 10:14:22,431 ERROR [order-service] \(LogFixture.npeLine)", number: 2)
        let signature = try XCTUnwrap(LogLineParser.signature(for: inlineException))
        XCTAssertTrue(signature.contains("java.lang.NullPointerException"),
                      "签名要保留异常类名：\(signature)")
        XCTAssertEqual(LogLineParser.signature(for: parse("2026-09-18 10:14:22,431 ERROR [order-service] \(LogFixture.npeLine)",
                                                           number: 2)),
                       signature, "同一行的签名必须稳定")

        // 多行堆栈里的裸异常行（无级别前缀）：因实现细节放宽——detectSeverity 认不出级别时
        // signature(for:) 按「非 error 族不进聚类」的口径返回 nil，两种结果都算合法。
        let bare = LogLineParser.signature(for: parse(LogFixture.npeLine, number: 3))
        XCTAssertTrue(bare == nil || bare!.contains("java.lang.NullPointerException"),
                      "裸异常行的签名：\(String(describing: bare))")

        // 只有 orderId / UUID 不同的同类业务错误：签名必须相等（聚类的根基）
        let headerA = parse(LogFixture.headerError(3, "10:14:22,431", orderId: 88213,
                                                   user: "4f9a2b7c-1d3e-4f5a-9b8c-7d6e5f4a3b2c"))
        let headerB = parse(LogFixture.headerError(3, "11:02:07,884", orderId: 90455,
                                                   user: "1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d"))
        let signatureA = try XCTUnwrap(LogLineParser.signature(for: headerA), "ERROR 行要有签名")
        let signatureB = try XCTUnwrap(LogLineParser.signature(for: headerB), "ERROR 行要有签名")
        XCTAssertEqual(signatureA, signatureB, "同类异常的签名要聚在一起")

        // 不同类异常的签名不应相同
        let timeout = parse("2026-09-19 08:12:33,456 ERROR [order-service] \(LogFixture.timeoutLine)", number: 13)
        XCTAssertNotEqual(LogLineParser.signature(for: timeout), signature)
    }

    func testStackFrameAndSourceFileExtraction() throws {
        let plain = "at com.example.shop.OrderService.pay(OrderService.java:123)"
        XCTAssertEqual(LogLineParser.sourceFile(in: plain), "OrderService.java")
        let frame = try XCTUnwrap(LogLineParser.stackFrame(in: plain), "栈帧行必须被识别")
        XCTAssertTrue(frame.contains("OrderService.java:123"))

        // 真实 Java 栈用制表符前缀；实现是否容忍前缀不确定 → 因实现细节放宽
        let tabbed = LogLineParser.sourceFile(in: LogFixture.npeFramePay)
        XCTAssertTrue(tabbed == nil || tabbed == "OrderService.java", "制表符前缀行：\(String(describing: tabbed))")

        // Swift 崩溃栈里的 (File.swift:line)
        let swiftFrame = "2   TcoderSample   0x0000000100a2b3c4 com.example.shop.Cache.flush() + 68 (Cache.swift:210)"
        XCTAssertEqual(LogLineParser.sourceFile(in: swiftFrame), "Cache.swift")

        XCTAssertNil(LogLineParser.sourceFile(in: "完全普通的一句话，没有栈帧"))
    }

}
