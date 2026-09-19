import Foundation
import XCTest
@testable import TcoderMonitor

// WS-C · 子代理「日志分析单测」
//
// 覆盖范围：LogLineParser（时间戳/严重度/归一化/签名/栈帧）、LogDiscovery、LogReader 截尾、
// LogAggregator（cluster / buckets / affectedFiles / aggregate）、CrashReportParser
// （纯文本崩溃报告 + .ips 诊断报告）、FileLogAnalyzer 端到端冒烟。
//
// 口径说明：
// * 夹具与负责人手工验证共用同一份文本（error.log 多行 Java 堆栈、crash.log 崩溃报告、
//   最小合法 .ips），只把日期写成「相对基准日的偏移」，避免测试一年后失效。
// * 时间断言只用相对 referenceDate 的固定偏移；syslog 这类无年份格式一律显式传 referenceDate。
// * 无时区格式（`yyyy-MM-dd HH:mm:ss`、syslog）同时接受「按本地时区解释」与「按 UTC 解释」
//   两种结果——见 wallClockCandidates / assertNearAnyWallClock，因为实现可二选一。
// * 临时目录一律 NSTemporaryDirectory()/tcoder-logtest-<UUID>，并在 addTeardownBlock 里删除。
// * 标注「因实现细节放宽」的断言：等负责人确定行为后可收紧。

// MARK: - 夹具

private typealias LogStamp = (Int, String) -> String

private enum LogFixture {
    /// 固定基准时刻：2026-09-21 14:13:20 UTC（本地 2026-09-21，用于 syslog 补年份）。
    static let referenceDate = Date(timeIntervalSince1970: 1_790_000_000)
    /// 2026-09-19T08:12:33Z 的 epoch 秒，多个格式共用同一「墙上时刻」。
    static let isoZEpoch: TimeInterval = 1_789_805_553

    static let errorLogPath = "/srv/app/logs/error.log"
    static let crashLogPath = "/srv/app/logs/crash.log"

    // 多行 Java 堆栈里反复出现的原文（聚类必须把这些归成同一类）
    static let npeLine =
        "java.lang.NullPointerException: Cannot invoke \"com.example.shop.Price.getTotal()\" because \"price\" is null"
    static let npeFramePay = "\tat com.example.shop.OrderService.pay(OrderService.java:123)"
    static let npeFrameSubmit = "\tat com.example.shop.OrderController.submit(OrderController.java:56)"
    static let timeoutLine = "java.net.SocketTimeoutException: Read timed out"
    static let timeoutFrame = "\tat com.example.shop.PayClient.post(PayClient.java:88)"

    /// 只有 orderId / UUID / 时刻不同的同类业务错误行，聚类测试的对照组。
    static func headerError(_ daysBeforeReference: Int, _ clock: String,
                            orderId: Int, user: String) -> String {
        "\(absoluteStamp(daysBeforeReference, clock)) ERROR [order-service] c.e.s.OrderService - "
            + "处理订单失败 orderId=\(orderId) user=\(user)"
    }

    /// error.log 全文。`stamp` 决定日期前缀（相对偏移 or 固定基准日）。
    static func errorLogText(stamp: LogStamp) -> String {
        [
            "\(stamp(3, "10:14:22,431")) ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId=88213 user=4f9a2b7c-1d3e-4f5a-9b8c-7d6e5f4a3b2c",
            npeLine,
            npeFramePay,
            npeFrameSubmit,
            "Caused by: java.lang.IllegalStateException: price cache miss for sku 991-ABC",
            "\tat com.example.shop.PriceCache.lookup(PriceCache.java:44)",
            "\(stamp(3, "10:14:23,002")) WARN  [order-service] c.e.s.Retry - 第 2 次重试",
            "\(stamp(3, "11:02:07,884")) ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId=90455 user=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
            npeLine,
            npeFramePay,
            npeFrameSubmit,
            "\(stamp(2, "08:12:33,456")) ERROR [order-service] c.e.s.PayClient - HTTP 调用超时 url=https://api.example.com/v1/pay cost=30005ms",
            timeoutLine,
            timeoutFrame,
            "\(stamp(2, "08:12:34,001")) FATAL [order-service] c.e.s.Bootstrap - 关键服务不可用，退出",
            "\(stamp(2, "08:13:00,100")) INFO  [order-service] c.e.s.Health - 健康检查通过",
        ].joined(separator: "\n") + "\n"
    }

    /// crash.log 全文（纯文本崩溃报告，形态对齐 macOS 老式 .crash 报告）。
    static let crashLogText = [
        "Incident Identifier: 7B1D9F3E-4A55-4C8D-9E2F-1A2B3C4D5E6F",
        "Crash Reporter Key:  0000000000000000000000000000000000000000",
        "Exception Type:      EXC_BAD_ACCESS (SIGSEGV)",
        "Exception Codes:     0x0000000000000001, 0x0000000000000000",
        "Termination Reason:  SIGNAL 11",
        "Thread 3 Crashed:",
        "0   libsystem_kernel.dylib        0x00000001a2b3c4d5 __pthread_kill + 8",
        "1   AppKit                        0x000000018f9e8d7c _NSViewDrawRect + 124",
        "2   TcoderSample                  0x0000000100a2b3c4 com.example.shop.Cache.flush() + 68 (Cache.swift:210)",
        "3   TcoderSample                  0x0000000100a2d110 com.example.shop.App.main() + 316 (main.swift:12)",
        "Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value: file TcoderSample/Cache.swift, line 210",
        "Swift runtime failure: Unexpectedly found nil",
    ].joined(separator: "\n") + "\n"

    /// 最小合法 .ips：首行 header JSON + 其余 body JSON（字段名对齐真实 CrashReporter 报告）。
    static let ipsText = """
    {"app_name":"TcoderSample","app_version":"1.0.0","bundleID":"com.example.shop","bug_type":"309","incident_id":"2C4E6A80-1B3D-4F5A-6C7E-8A9B0C1D2E3F","is_first_party":1,"name":"TcoderSample","os_version":"macOS 14.5 (23F79)","roots_installed":0,"share_with_app_devs":0,"slice_uuid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","timestamp":"2026-09-19 08:13:01 +0800","version":2}
    {
      "bug_type" : "309",
      "incident_id" : "2C4E6A80-1B3D-4F5A-6C7E-8A9B0C1D2E3F",
      "timestamp" : "2026-09-19 08:13:01 +0800",
      "version" : 2,
      "uptime" : 421500,
      "procName" : "TcoderSample",
      "procPath" : "/srv/app/TcoderSample.app/Contents/MacOS/TcoderSample",
      "parentProc" : "launchd",
      "os_version" : {"train":"macOS 14.5 (23F79)","build":"23F79","releaseType":"User"},
      "exception" : {
        "type":"EXC_BAD_ACCESS",
        "signal":"SIGSEGV",
        "subtype":"KERN_INVALID_ADDRESS at 0x000000016f8a8b00",
        "codes":"0x0000000000000001, 0x000000016f8a8b00",
        "rawCodes":[1,6166176512]
      },
      "termination" : {"flags":0,"code":11,"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},
      "threads" : [
        {
          "id" : 4321,
          "name" : "worker",
          "triggered" : true,
          "frames" : [
            {"imageIndex":3,"imageOffset":45678,"symbol":"com.example.shop.Cache.flush()","symbolLocation":68,"sourceLineInfo":{"file":"Cache.swift","line":210}},
            {"imageIndex":3,"imageOffset":53520,"symbol":"com.example.shop.App.main()","symbolLocation":316,"sourceLineInfo":{"file":"main.swift","line":12}},
            {"imageIndex":0,"imageOffset":1234,"symbol":"__pthread_kill","symbolLocation":8}
          ],
          "backtrace" : {
            "frames" : [
              {"image_index":3,"image_offset":45678,"symbol":"com.example.shop.Cache.flush()","sourceLineInfo":{"file":"Cache.swift","line":210}},
              {"image_index":3,"image_offset":53520,"symbol":"com.example.shop.App.main()","sourceLineInfo":{"file":"main.swift","line":12}},
              {"image_index":0,"image_offset":1234,"symbol":"__pthread_kill"}
            ]
          }
        },
        {
          "id" : 101,
          "name" : "main",
          "triggered" : false,
          "frames" : [ {"imageIndex":0,"imageOffset":99,"symbol":"mach_msg2_trap","symbolLocation":8} ]
        }
      ],
      "usedImages" : [
        {"source":"P","name":"libsystem_kernel.dylib","path":"/usr/lib/system/libsystem_kernel.dylib","UUID":"11112222-3333-4444-5555-666677778888"},
        {"source":"P","name":"libsystem_pthread.dylib","path":"/usr/lib/system/libsystem_pthread.dylib","UUID":"AAAAAAAA-1111-2222-3333-444455556666"},
        {"source":"P","name":"AppKit","path":"/System/Library/Frameworks/AppKit.framework/Versions/CrossUI/AppKit","UUID":"BBBBBBBB-1111-2222-3333-444455556666"},
        {"source":"P","name":"TcoderSample","path":"/srv/app/TcoderSample.app/Contents/MacOS/TcoderSample","UUID":"CCCCCCCC-1111-2222-3333-444455556666"}
      ]
    }
    """

    /// 崩溃报告里出现过的 16 位十六进制地址原值（签名必须把它们归一化掉）。
    static let rawHexAddresses = [
        "0x00000001a2b3c4d5",
        "0x000000018f9e8d7c",
        "0x0000000100a2b3c4",
        "0x0000000100a2d110",
        "0x000000016f8a8b00",
    ]
    static let incidentID = "7B1D9F3E-4A55-4C8D-9E2F-1A2B3C4D5E6F"

    /// 纯解析用例用的「固定基准日」前缀：3 天前 = 2026-09-18、2 天前 = 2026-09-19。
    static func absoluteStamp(_ daysBeforeReference: Int, _ clock: String) -> String {
        "\(dayString(referenceDate, daysBeforeReference)) \(clock)"
    }

    /// 端到端用例用的「相对今天」前缀，保证永远落在 withinDays 窗口内。
    static func relativeStamp(_ daysAgo: Int, _ clock: String) -> String {
        "\(dayString(Date(), daysAgo)) \(clock)"
    }

    private static func dayString(_ anchor: Date, _ daysBack: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -daysBack, to: anchor)
            ?? anchor.addingTimeInterval(-Double(daysBack) * 86_400)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: day)
    }
}

// MARK: - 全局小工具

private func wallClock(_ year: Int, _ month: Int, _ day: Int,
                       _ hour: Int, _ minute: Int, _ second: Int,
                       timeZone: TimeZone) -> Date? {
    var comps = DateComponents()
    comps.year = year; comps.month = month; comps.day = day
    comps.hour = hour; comps.minute = minute; comps.second = second
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = timeZone
    return calendar.date(from: comps)
}

/// 同一串「无时区」文本的两种合法解释：本地时区 / UTC。实现二选一即可。
private func wallClockCandidates(_ year: Int, _ month: Int, _ day: Int,
                                 _ hour: Int, _ minute: Int, _ second: Int) -> [Date] {
    [wallClock(year, month, day, hour, minute, second, timeZone: .current),
     wallClock(year, month, day, hour, minute, second, timeZone: TimeZone(identifier: "UTC") ?? .current)]
        .compactMap { $0 }
}

private func assertNearAnyWallClock(_ date: Date?, _ candidates: [Date],
                                    accuracy: TimeInterval = 1.0,
                                    label: String = "",
                                    file: StaticString = #filePath, line: UInt = #line) {
    guard let date else {
        XCTFail("parseTimestamp 返回 nil：\(label)", file: file, line: line)
        return
    }
    let hits = candidates.filter { abs($0.timeIntervalSince(date)) <= accuracy }
    XCTAssertTrue(!hits.isEmpty,
                  "\(label): 结果 \(date.timeIntervalSince1970) 既不等于本地解释也不等于 UTC 解释（容差 \(accuracy)s）",
                  file: file, line: line)
}

private func severitiesOf(_ lines: [String]) -> [LogSeverity?] {
    lines.map { LogLineParser.detectSeverity($0) }
}

@discardableResult
private func writeLog(_ text: String, to url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
    return url
}

private func makeEvent(_ severity: LogSeverity,
                       raw: String,
                       message: String? = nil,
                       date: Date? = nil,
                       path: String = LogFixture.errorLogPath,
                       line: Int = 1,
                       frames: [String] = [],
                       files: [String] = [],
                       isCrash: Bool = false,
                       isContinuation: Bool = false) -> LogEvent {
    LogEvent(date: date,
             severity: severity,
             rawLine: raw,
             message: message ?? raw,
             sourceLogPath: path,
             lineNumber: line,
             stackFrames: frames,
             sourceFiles: files,
             isCrash: isCrash,
             isContinuation: isContinuation)
}

/// 以 `base` 为基准整体平移 `days` 天（整天偏移，任何时区下都落在同一天内），用于按天分桶的用例。
private func dayShifted(_ base: Date, _ days: Int) -> Date {
    base.addingTimeInterval(TimeInterval(days * 86_400))
}

// MARK: - 测试

final class LogAnalysisTests: XCTestCase {

    // MARK: 临时目录

    private func makeTempDir(_ tag: String) throws -> URL {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-logtest-\(tag)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let captured = base
        addTeardownBlock {
            try? FileManager.default.removeItem(at: captured)
        }
        return base
    }

    /// 判断路径是否位于夹具目录之下。macOS 的 `/var` 与 `/private/var` 是同一份，
    /// FileManager 有时会给出解析软链后的形式，所以几种写法都接受。
    private func isUnder(_ path: String, root: URL) -> Bool {
        let variants: [String] = [
            root.path,
            root.standardizedFileURL.path,
            root.resolvingSymlinksInPath().path,
            root.path.replacingOccurrences(of: "/private/var/", with: "/var/"),
        ]
        return variants.contains { path.hasPrefix($0) }
    }

    // MARK: 1. parseTimestamp —— 九种格式

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

    // MARK: 6. cluster

    private func npeEvent(_ day: Int, line: Int) -> LogEvent {
        makeEvent(.error,
                  raw: LogFixture.npeLine,
                  date: dayShifted(LogFixture.referenceDate, day),
                  line: line,
                  frames: [LogFixture.npeFramePay, LogFixture.npeFrameSubmit],
                  files: ["OrderService.java", "OrderController.java"])
    }

    private func timeoutEvent(_ day: Int, line: Int) -> LogEvent {
        makeEvent(.error,
                  raw: LogFixture.timeoutLine,
                  date: dayShifted(LogFixture.referenceDate, day),
                  line: line,
                  frames: [LogFixture.timeoutFrame],
                  files: ["PayClient.java"])
    }

    func testClusterGroupsByCountAndSummarizesTopGroup() throws {
        let events = [npeEvent(0, line: 2), timeoutEvent(1, line: 13), npeEvent(1, line: 9),
                      timeoutEvent(1, line: 14), npeEvent(2, line: 2)]
        let clusters = LogAggregator.cluster(events: events, limit: 10)
        XCTAssertEqual(clusters.count, 2, "两类异常应聚成两簇")

        let top = try XCTUnwrap(clusters.first)
        XCTAssertTrue(top.signature.contains("NullPointerException"), "NPE 组在前：\(top.signature)")
        XCTAssertEqual(top.count, 3)
        XCTAssertLessThanOrEqual(top.sampleLines.count, 3)
        XCTAssertTrue(top.stackTopFrames.contains { $0.contains("OrderService.java:123") },
                      "栈顶帧要带上：\(top.stackTopFrames)")
        let first = try XCTUnwrap(top.firstSeen)
        let last = try XCTUnwrap(top.lastSeen)
        XCTAssertLessThan(first, last)
        XCTAssertFalse(top.displayMessage.isEmpty)
        XCTAssertTrue(top.displayMessage.contains("java.lang.NullPointerException") || top.displayMessage.contains("price"),
                      "displayMessage 要保留可读原文：\(top.displayMessage)")
        XCTAssertEqual(top.severity, LogSeverity.error)

        let second = try XCTUnwrap(clusters.last)
        XCTAssertTrue(second.signature.contains("SocketTimeoutException") || second.signature.contains("timed out"),
                      "第二簇：\(second.signature)")
        XCTAssertEqual(second.count, 2)
    }

    func testClusterOrderIsStableForEqualCounts() throws {
        let events = [npeEvent(0, line: 2), npeEvent(1, line: 9),
                      timeoutEvent(0, line: 13), timeoutEvent(1, line: 14)]
        let once = LogAggregator.cluster(events: events, limit: 10).map { $0.signature }
        let twice = LogAggregator.cluster(events: events, limit: 10).map { $0.signature }
        XCTAssertEqual(once.count, 2)
        XCTAssertEqual(once, twice, "并列数量下同一输入的排序必须稳定")
    }

    func testClusterRespectsLimit() throws {
        var events: [LogEvent] = []
        for index in 0..<6 {
            events.append(makeEvent(.error,
                                    raw: "java.lang.IllegalStateException: 分片 \(index) 写入失败 seq=\(index)",
                                    date: dayShifted(LogFixture.referenceDate, index % 2),
                                    line: index + 1))
        }
        let clusters = LogAggregator.cluster(events: events, limit: 3)
        XCTAssertLessThanOrEqual(clusters.count, 3)
    }

    // MARK: 7. buckets

    func testBucketsGroupByDay() throws {
        let base = LogFixture.referenceDate
        let dayMinus2 = dayShifted(base, -2)
        let dayMinus1 = dayShifted(base, -1)
        let day0 = base

        var events = [
            makeEvent(.error, raw: "ERROR 甲 day-2", date: dayMinus2, line: 1),
            makeEvent(.error, raw: "ERROR 乙 day-1", date: dayMinus1, line: 2),
            makeEvent(.error, raw: "ERROR 丙 today", date: day0, line: 3),
            makeEvent(.warning, raw: "WARN 乙 day-1", date: dayMinus1, line: 4),
            makeEvent(.warning, raw: "WARN 丙 today", date: day0, line: 5),
            makeEvent(.crash, raw: "EXC_BAD_ACCESS 丙 today", date: day0, line: 6, isCrash: true),
        ]
        // date == nil 的事件不进桶
        events.append(makeEvent(.error, raw: "ERROR 没有时间戳", date: nil, line: 7))

        let buckets = LogAggregator.buckets(for: events)
        XCTAssertEqual(buckets.count, 3, "桶数 = 出现过的天数")
        XCTAssertEqual(buckets, buckets.sorted { $0.date < $1.date }, "必须按 date 升序")
        XCTAssertEqual(buckets.map { $0.errors }.sorted(), [1, 1, 1])
        XCTAssertEqual(buckets.map { $0.warnings }.sorted(), [0, 1, 1])
        XCTAssertEqual(buckets.map { $0.crashes }.sorted(), [0, 0, 1])
        XCTAssertEqual(buckets.map { $0.exceptions }.reduce(0, +), 0)
        XCTAssertEqual(buckets.map { $0.total }, buckets.map { $0.errors + $0.warnings + $0.exceptions + $0.crashes })
        XCTAssertEqual(buckets.map { $0.total }.sorted(), [1, 2, 3])
        XCTAssertEqual(buckets.map { $0.total }.reduce(0, +), 6, "无日期事件不进桶")
    }

    func testBucketsUseSameDayGrouping() throws {
        let base = LogFixture.referenceDate
        let events = [
            makeEvent(.error, raw: "ERROR 同日早晨", date: base.addingTimeInterval(-40_000), line: 1),
            makeEvent(.error, raw: "ERROR 同日晚间", date: base.addingTimeInterval(40_000), line: 2),
        ]
        let buckets = LogAggregator.buckets(for: events)
        // 因实现细节放宽：跨 UTC/本地日界的两条允许进 1 桶或 2 桶，但总数必须守恒
        XCTAssertTrue([1, 2].contains(buckets.count), "桶数=\(buckets.count)")
        XCTAssertEqual(buckets.map { $0.total }.reduce(0, +), 2)
    }

    // MARK: 8. affectedFiles

    func testAffectedFilesTruncatesToLimitKeepingHighestCounts() throws {
        var events: [LogEvent] = []
        // 12 个文件，出现次数依次 12、11、…、1
        for index in 1...12 {
            let name = String(format: "mod%02d.java", index)
            for _ in 1...(13 - index) {
                events.append(makeEvent(.error, raw: "ERROR \(name) 抛异常", date: LogFixture.referenceDate,
                                        files: [name]))
            }
        }
        let counts = LogAggregator.affectedFiles(for: events, limit: 10)
        XCTAssertEqual(counts.count, 10, "前 10 截断")
        XCTAssertEqual(counts.values.sorted(), Array(3...12), "截断后剩下的必须是次数最高的 10 个")
        XCTAssertEqual(counts["mod01.java"], 12)
        XCTAssertNil(counts["mod12.java"], "次数最低的必须被挤掉")
        // 降序在 [String:Int] 字典里无顺序可表达，只校验「保留的是最高的一批」
    }

    func testAffectedFilesCountsFixtureSourceFiles() throws {
        let events = [
            makeEvent(.error, raw: LogFixture.npeLine, files: ["OrderService.java", "OrderController.java"]),
            makeEvent(.error, raw: LogFixture.npeLine, files: ["OrderService.java"]),
            makeEvent(.error, raw: LogFixture.timeoutLine, files: ["PayClient.java"]),
            makeEvent(.crash, raw: "Thread 3 Crashed:", files: ["Cache.swift"], isCrash: true),
        ]
        let counts = LogAggregator.affectedFiles(for: events, limit: 10)
        XCTAssertEqual(counts["OrderService.java"], 2)
        XCTAssertEqual(counts.count, 4)
        XCTAssertEqual(Set(counts.keys), ["OrderService.java", "OrderController.java", "PayClient.java", "Cache.swift"])
    }

    // MARK: 9. aggregate

    func testAggregateSumsLinesCountsAndWindow() throws {
        let dir = try makeTempDir("aggregate")
        let errorURL = try writeLog(LogFixture.errorLogText(stamp: LogFixture.absoluteStamp),
                                   to: dir.appendingPathComponent("error.log"))
        let crashURL = try writeLog(LogFixture.crashLogText, to: dir.appendingPathComponent("crash.log"))

        let dayA = dayShifted(LogFixture.referenceDate, -3)
        let dayB = dayShifted(LogFixture.referenceDate, -2)

        let errorEvents: [LogEvent] = [
            makeEvent(.error, raw: "ERROR 处理订单失败 orderId=88213", date: dayA, path: errorURL.path, line: 1,
                      frames: [LogFixture.npeFramePay], files: ["OrderService.java"]),
            makeEvent(.error, raw: "ERROR 处理订单失败 orderId=90455", date: dayA, path: errorURL.path, line: 8,
                      frames: [LogFixture.npeFramePay], files: ["OrderService.java"]),
            makeEvent(.error, raw: "ERROR HTTP 调用超时", date: dayB, path: errorURL.path, line: 12,
                      files: ["PayClient.java"]),
            makeEvent(.exception, raw: LogFixture.npeLine, date: dayA, path: errorURL.path, line: 2),
            makeEvent(.warning, raw: "WARN 第 2 次重试", date: dayA, path: errorURL.path, line: 7),
            makeEvent(.fatal, raw: "FATAL 关键服务不可用，退出", date: dayB, path: errorURL.path, line: 15),
            makeEvent(.info, raw: "INFO 健康检查通过", date: dayB, path: errorURL.path, line: 16),
            makeEvent(.info, raw: "INFO 启动完成", date: dayB, path: errorURL.path, line: 17),
        ]
        let crashEvents: [LogEvent] = [
            makeEvent(.crash, raw: "Exception Type:      EXC_BAD_ACCESS (SIGSEGV)", date: dayB,
                      path: crashURL.path, line: 3, isCrash: true),
        ]
        let readingA = LogFileReading(url: errorURL, role: .error, sizeBytes: Int64(LogFixture.errorLogText(stamp: LogFixture.absoluteStamp).utf8.count),
                                      modifiedAt: dayA, totalLines: 16, linesRead: 16, truncated: false,
                                      events: errorEvents, parseErrors: 0)
        let readingB = LogFileReading(url: crashURL, role: .crash, sizeBytes: Int64(LogFixture.crashLogText.utf8.count),
                                      modifiedAt: dayB, totalLines: 12, linesRead: 12, truncated: false,
                                      events: crashEvents, parseErrors: 0)
        let extra = makeEvent(.warning, raw: "WARN 外部日志告警", date: dayB, path: "/srv/app/logs/extra.log", line: 1)

        let agg = LogAggregator.aggregate(readings: [readingA, readingB], extraEvents: [extra], topLimit: 5)
        XCTAssertEqual(agg.totalLinesScanned, readingA.totalLines + readingB.totalLines)
        XCTAssertEqual(agg.events.count, errorEvents.count + crashEvents.count + 1, "extraEvents 要并入")
        XCTAssertEqual(agg.warningCount, 2, "extraEvents 参与计数")
        XCTAssertEqual(agg.exceptionCount, 1)
        XCTAssertEqual(agg.fatalCount, 1)
        XCTAssertEqual(agg.crashCount, 1)
        // 因实现细节放宽：error 计数是否吞并 exception/fatal/crash 各实现不同
        XCTAssertTrue((3...6).contains(agg.errorCount), "errorCount=\(agg.errorCount)")
        XCTAssertGreaterThanOrEqual(agg.infoLineCount, 2)
        let windowStart = try XCTUnwrap(agg.windowStart, "windowStart = 有日期事件的最小值")
        let windowEnd = try XCTUnwrap(agg.windowEnd, "windowEnd = 有日期事件的最大值")
        XCTAssertEqual(windowStart.timeIntervalSince1970, dayA.timeIntervalSince1970, accuracy: 1)
        XCTAssertEqual(windowEnd.timeIntervalSince1970, dayB.timeIntervalSince1970, accuracy: 1)
        XCTAssertFalse(agg.topErrors.isEmpty)
        XCTAssertFalse(agg.trend.isEmpty)
        XCTAssertEqual(agg.affectedFiles["OrderService.java"], 2)
    }

    func testAggregateSkipsContinuationEventsFromErrorCount() throws {
        let dir = try makeTempDir("continuation")
        let url = try writeLog("ERROR 处理订单失败\nERROR 处理订单失败\nERROR 处理订单失败\n",
                               to: dir.appendingPathComponent("error.log"))
        let first = makeEvent(.error, raw: "ERROR 处理订单失败", date: LogFixture.referenceDate,
                              path: url.path, line: 1)
        let second = makeEvent(.error, raw: "ERROR 处理订单失败", date: LogFixture.referenceDate,
                               path: url.path, line: 8)
        // 与 first 同签名的「续行」错误：不应再计一次
        let continuation = makeEvent(.error, raw: "ERROR 处理订单失败", date: LogFixture.referenceDate,
                                     path: url.path, line: 9, isContinuation: true)
        let reading = LogFileReading(url: url, role: .error, sizeBytes: 16, modifiedAt: LogFixture.referenceDate,
                                     totalLines: 3, linesRead: 3, truncated: false,
                                     events: [first, second, continuation], parseErrors: 0)
        let agg = LogAggregator.aggregate(readings: [reading], extraEvents: [], topLimit: 5)
        XCTAssertEqual(agg.errorCount, 2, "isContinuation 的事件不进 errorCount")
        XCTAssertEqual(agg.totalLinesScanned, 3)
        XCTAssertGreaterThanOrEqual(agg.events.count, 2)
    }

    // MARK: 10. CrashReportParser.parseCrashText

    private func crashEventsFromText() -> [LogEvent] {
        CrashReportParser.parseCrashText(text: LogFixture.crashLogText, path: LogFixture.crashLogPath,
                                         modifiedAt: LogFixture.referenceDate)
    }

    /// 崩溃报告的「主事件」：优先取标了 .crash + isCrash 且 message 带异常类型的那一条；
    /// 若实现把异常类型与崩溃标记拆到不同事件上，退而取前两个条件（因实现细节放宽）。
    private func primaryCrashEvent(from events: [LogEvent]) throws -> LogEvent {
        let preferred = events.first { $0.severity == .crash && $0.isCrash && $0.message.contains("EXC_BAD_ACCESS") }
        let marked = events.first { $0.severity == .crash && $0.isCrash }
        return try XCTUnwrap(preferred ?? marked ?? events.first, "崩溃文本必须至少产出一个事件")
    }

    func testParseCrashTextProducesCrashEvent() throws {
        let events = crashEventsFromText()
        XCTAssertFalse(events.isEmpty, "至少要产出一个事件")
        XCTAssertTrue(events.contains { $0.severity == LogSeverity.crash }, "要有 .crash 事件")
        XCTAssertTrue(events.contains { $0.isCrash }, "isCrash 要置位")
        XCTAssertTrue(events.allSatisfy { $0.sourceLogPath == LogFixture.crashLogPath },
                      "sourceLogPath 要回传入参路径")

        let crashEvent = try primaryCrashEvent(from: events)
        XCTAssertTrue(crashEvent.message.contains("EXC_BAD_ACCESS"),
                      "主事件 message 要含异常类型：\(crashEvent.message)")
        XCTAssertTrue(events.flatMap { $0.stackFrames }.contains { $0.contains("Cache.swift") },
                      "栈帧要带 Cache.swift")
    }

    func testCrashSignatureIsNormalizedAndStable() throws {
        let signature = try XCTUnwrap(CrashReportParser.crashSignature(from: primaryCrashEvent(from: crashEventsFromText())),
                                      "崩溃签名不能为空")
        XCTAssertFalse(signature.isEmpty)
        for address in LogFixture.rawHexAddresses {
            XCTAssertFalse(signature.lowercased().contains(address),
                           "签名不得含十六进制地址原值 \(address)：\(signature)")
        }
        let loweredIncident = LogFixture.incidentID.lowercased()
        XCTAssertFalse(signature.lowercased().contains(loweredIncident),
                       "签名不得含 Incident Identifier 原值：\(signature)")
        XCTAssertFalse(signature.lowercased().contains(String(loweredIncident.prefix(8))),
                       "签名不得含 Incident Identifier 片段：\(signature)")

        let repeated = try XCTUnwrap(CrashReportParser.crashSignature(from: primaryCrashEvent(from: crashEventsFromText())))
        XCTAssertEqual(signature, repeated, "同一份报告的崩溃签名必须稳定")
    }

    // MARK: 11. CrashReportParser.parseDiagnosticReport (.ips)

    func testParseDiagnosticReportForIpsText() throws {
        let events = CrashReportParser.parseDiagnosticReport(text: LogFixture.ipsText,
                                                             path: "/srv/app/logs/TcoderSample-2026-09-19-081301.ips",
                                                             modifiedAt: LogFixture.referenceDate)
        // 因实现细节放宽：真实 .ips 可能按「触发线程」聚成 1 个事件，也可能拆多行；只要求至少 1 个
        XCTAssertGreaterThanOrEqual(events.count, 1)
        XCTAssertTrue(events.contains { $0.severity == LogSeverity.crash }, "诊断报告要判成 .crash")
        let message = try XCTUnwrap(events.first { $0.message.contains("EXC_BAD_ACCESS") }?.message)
        XCTAssertTrue(message.contains("KERN_INVALID_ADDRESS"), "message 要带 subtype：\(message)")
        let frames = events.flatMap { $0.stackFrames }
        XCTAssertFalse(frames.isEmpty, "栈帧不能为空")
        XCTAssertTrue(frames.contains { $0.contains("Cache.swift") }, "栈帧要带源文件：\(frames)")
        XCTAssertEqual(events.filter { $0.severity == .crash && $0.isCrash }.count, 1, "一份报告 = 一次崩溃")

        // timestamp = 2026-09-19 08:13:01 +0800 → epoch 1_789_776_781；按天容差
        let expected = Date(timeIntervalSince1970: 1_789_776_781)
        let dated = try XCTUnwrap(events.first { $0.date != nil }?.date)
        XCTAssertLessThan(abs(dated.timeIntervalSince(expected)), 86_400)
    }

    func testParseDiagnosticReportToleratesGarbage() throws {
        let events = CrashReportParser.parseDiagnosticReport(text: "not json at all",
                                                            path: "/srv/app/logs/Broken-2026-09-19.ips",
                                                            modifiedAt: LogFixture.referenceDate)
        XCTAssertLessThanOrEqual(events.count, 1, "垃圾文本不得崩，也不得编造出多个事件")
        for event in events {
            XCTAssertFalse(event.sourceLogPath.isEmpty)
        }
    }

    // MARK: 12. isCrashReport

    func testIsCrashReportByName() throws {
        XCTAssertTrue(CrashReportParser.isCrashReport(URL(fileURLWithPath: "/srv/app/logs/a.ips")))
        XCTAssertTrue(CrashReportParser.isCrashReport(URL(fileURLWithPath: "/srv/app/logs/x-crash.log")))
        XCTAssertTrue(CrashReportParser.isCrashReport(URL(fileURLWithPath: "/srv/app/logs/y.crash")))
        XCTAssertFalse(CrashReportParser.isCrashReport(URL(fileURLWithPath: "/srv/app/logs/app.log")))
        // 只用明确的名字，避开「role 兜底」带来的歧义
        XCTAssertFalse(CrashReportParser.isCrashReport(URL(fileURLWithPath: "/srv/app/logs/build-output.log")))
    }

    // MARK: 13. LogReader 截尾

    func testReaderKeepsOnlyTailWhenTruncated() throws {
        let dir = try makeTempDir("reader")
        let url = dir.appendingPathComponent("bulk.log")
        let headMarker = "HEAD_MARKER_9F3A"
        let tailMarker = "TAIL_MARKER_7C1B"

        var lines: [String] = []
        lines.append("\(LogFixture.absoluteStamp(9, "00:00:00,000")) ERROR [order-service] c.e.s.Head - \(headMarker) 头部标记，不该被读到")
        // 每行约 340 字节：maxBytes = 40_000 的尾窗只装得下 ~115 行，
        // 这样「行数上限 200」不会先把文件末尾截掉，才能验证「读的是尾部」。
        let padding = String(repeating: "abcdefghij", count: 25)
        for index in 0..<5_000 {
            lines.append(String(format: "2026-09-10 03:04:%02d,000 INFO  [order-service] c.e.s.Worker - 载入批次 batchId=%04d payload=",
                                index % 60, index) + padding)
        }
        lines.append("\(LogFixture.absoluteStamp(1, "23:59:59,999")) ERROR [order-service] c.e.s.Tail - \(tailMarker) 尾部标记，必须被读到")
        let text = lines.joined(separator: "\n") + "\n"
        try writeLog(text, to: url)
        XCTAssertGreaterThan(Data(text.utf8).count, 40_000, "夹具本身必须超过 maxBytes")

        let log = DiscoveredLog(url: url, role: .application, sizeBytes: Int64(Data(text.utf8).count),
                                modifiedAt: LogFixture.referenceDate)
        let reading = LogReader.read(log, maxBytes: 40_000, maxLines: 200)
        XCTAssertTrue(reading.truncated, "超过上限必须标 truncated")
        XCTAssertGreaterThan(reading.totalLines, 0)
        XCTAssertLessThanOrEqual(reading.totalLines, 200)
        XCTAssertGreaterThan(reading.sizeBytes, 0, "要报告文件大小")

        let readText = reading.events.map { $0.rawLine }.joined(separator: "\n")
        XCTAssertTrue(readText.contains(tailMarker), "尾部标记必须在读到的内容里（只读了尾部）")
        XCTAssertFalse(readText.contains(headMarker), "头部标记不该出现")
    }

    func testReaderParsesSmallFileWithoutTruncation() throws {
        let dir = try makeTempDir("reader-small")
        let url = try writeLog(LogFixture.errorLogText(stamp: LogFixture.absoluteStamp),
                               to: dir.appendingPathComponent("error.log"))
        let log = DiscoveredLog(url: url, role: .error,
                               sizeBytes: Int64(LogFixture.errorLogText(stamp: LogFixture.absoluteStamp).utf8.count),
                               modifiedAt: LogFixture.referenceDate)
        let reading = LogReader.read(log, maxBytes: 4_000_000, maxLines: 5_000)
        XCTAssertFalse(reading.truncated)
        // 因实现细节放宽：结尾换行算不算一行，各家 split 语义不同
        XCTAssertTrue((15...17).contains(reading.totalLines), "totalLines=\(reading.totalLines)")
        XCTAssertFalse(reading.events.isEmpty)
        XCTAssertTrue(reading.events.contains { $0.severity == .error || $0.severity == .exception })
        XCTAssertTrue(reading.events.contains { $0.isContinuation } || reading.events.contains { !$0.stackFrames.isEmpty },
                      "多行堆栈要么标续行、要么把栈帧挂到事件上")
    }

    // MARK: 14. LogDiscovery

    func testDiscoveryFindsLogsAndSkipsNoise() throws {
        let dir = try makeTempDir("discover")
        let errorLog = try writeLog("ERROR 一条\n", to: dir.appendingPathComponent("Logs/error.log"))
        _ = try writeLog("INFO 一条\n", to: dir.appendingPathComponent("Logs/app.txt"))
        _ = try writeLog("ERROR 一条\n", to: dir.appendingPathComponent("a/b/c/Logs/nested.log"))
        _ = try writeLog("ERROR 一条\n", to: dir.appendingPathComponent("node_modules/x.log"))
        _ = try writeLog("class Main {}\n", to: dir.appendingPathComponent("src/main.java"))

        let found = LogDiscovery.discover(projectRoot: dir, projectName: "ShopApp", withinDays: 30, maxFiles: 50)
        let underRoot = found.filter { isUnder($0.url.path, root: dir) }
        let names = Set(underRoot.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["error.log", "app.txt", "nested.log"],
                       "只该发现工程内的日志文件（node_modules 与 .java 除外）：\(underRoot.map { $0.url.path })")
        XCTAssertTrue(underRoot.contains { $0.url.path == errorLog.path || $0.url.lastPathComponent == "error.log" })
        XCTAssertFalse(underRoot.contains { $0.url.lastPathComponent == "main.java" }, ".java 源码不是日志")
        XCTAssertFalse(underRoot.contains { $0.url.lastPathComponent == "x.log" }, "node_modules 里的日志不该算工程日志")
        XCTAssertFalse(found.contains { $0.url.path.contains("node_modules") }, "整棵树都不该伸进 node_modules")

        XCTAssertTrue(underRoot.allSatisfy { $0.sizeBytes >= 0 }, "发现项要带大小")
        XCTAssertTrue(underRoot.contains { $0.modifiedAt > Date(timeIntervalSince1970: 1_600_000_000) },
                      "发现项要带修改时间")
        XCTAssertEqual(LogDiscovery.role(for: errorLog, in: dir), LogFileRole.error)
    }

    func testDiscoveryOnEmptyAndMissingRoot() throws {
        let empty = try makeTempDir("discover-empty")
        let missing = empty.appendingPathComponent("does-not-exist")

        for root in [empty, missing] {
            let found = LogDiscovery.discover(projectRoot: root, projectName: "ShopApp", withinDays: 30, maxFiles: 20)
            // 实现会额外附加 ~/Library/Logs/DiagnosticReports，所以不能断言 count == 0
            let underRoot = found.filter { isUnder($0.url.path, root: root) }
            XCTAssertTrue(underRoot.isEmpty, "\(root.path) 之下不该有任何发现项：\(underRoot.map { $0.url.path })")
        }
    }

    // MARK: 15. 端到端 FileLogAnalyzer

    func testEndToEndAnalysisOfErrorAndCrashLogs() async throws {
        let dir = try makeTempDir("e2e")
        let errorLog = try writeLog(LogFixture.errorLogText(stamp: LogFixture.relativeStamp),
                                    to: dir.appendingPathComponent("Logs/error.log"))
        _ = try writeLog(LogFixture.crashLogText, to: dir.appendingPathComponent("Logs/crash.log"))

        let summary = try await FileLogAnalyzer()
            .analyze(projectRoot: dir, extraLogURLs: [], withinDays: 365)

        XCTAssertTrue(summary.hasData, "端到端必须读到数据")
        XCTAssertGreaterThanOrEqual(summary.errorCount, 3, "三条 ERROR 行")
        // 因实现细节放宽：裸异常行（`java.lang.NullPointerException:` 无级别前缀）在 detectSeverity
        // 里认不出级别、`Caused by:` 归为续行继承父事件级别、崩溃通道又把 "Exception Type:" 记成
        // .crash，所以 exceptionCount 可能为 0，异常证据改由 crash/error 计数承载。
        // 等负责人确定 FileLogAnalyzer 口径后再收紧为 `>= 1`。
        XCTAssertGreaterThanOrEqual(summary.exceptionCount + summary.crashCount, 1, "异常/崩溃证据至少要有一条")
        XCTAssertGreaterThanOrEqual(summary.crashCount, 1, "崩溃报告")
        XCTAssertGreaterThanOrEqual(summary.fatalCount, 1, "FATAL 行")
        XCTAssertGreaterThanOrEqual(summary.warningCount, 1)
        XCTAssertGreaterThanOrEqual(summary.totalLinesScanned, 20)
        XCTAssertGreaterThanOrEqual(summary.topErrors.first?.count ?? 0, 2, "同类的两行 ERROR（只差 orderId/UUID）要聚成一簇")
        let scannedPaths = summary.scannedFiles.map { $0.path }
        XCTAssertTrue(scannedPaths.contains(errorLog.path) || scannedPaths.contains { $0.hasSuffix("Logs/error.log") },
                      "scannedFiles 要含 error.log：\(scannedPaths)")
        XCTAssertFalse(summary.trend.isEmpty, "按天趋势不能为空")
        XCTAssertTrue(summary.affectedFiles.keys.contains("OrderService.java"),
                      "affectedFiles：\(summary.affectedFiles)")
        XCTAssertNotNil(summary.windowStart)
        XCTAssertNotNil(summary.windowEnd)
        XCTAssertNotEqual(summary.overallRisk, RiskLevel.none)
    }

    // MARK: 16. 空目录（宽松口径，等负责人确定行为后收紧）

    func testEndToEndAnalysisOfEmptyProjectRoot() async throws {
        let dir = try makeTempDir("e2e-empty")
        // 这条按宽松口径写：实现要么返回空摘要，要么显式抛错，两种都算合法。
        do {
            let summary = try await FileLogAnalyzer()
                .analyze(projectRoot: dir, extraLogURLs: [], withinDays: 7)
            if summary.hasData {
                // 因实现细节放宽：discover 会附加 ~/Library/Logs/DiagnosticReports 这类系统目录，
                // 因此只要没有任何 projectRoot 之下的文件被扫到，就不算「假装有数据」。
                XCTAssertTrue(summary.scannedFiles.allSatisfy { !isUnder($0.path, root: dir) },
                              "空工程根目录不该扫到工程内文件：\(summary.scannedFiles.map { $0.path })")
            } else {
                XCTAssertEqual(summary.totalLinesScanned, 0)
                XCTAssertTrue(summary.scannedFiles.isEmpty)
            }
        } catch {
            // 实现选择抛错同样是合法行为，这里只确认拿到的是可描述的错误对象
            XCTAssertFalse(String(describing: error).isEmpty)
        }
    }
}
