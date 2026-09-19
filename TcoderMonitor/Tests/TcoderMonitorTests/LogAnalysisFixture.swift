import Foundation
import XCTest
@testable import TcoderMonitor

// WS-C · 子代理「日志分析单测」——共用夹具与全局小工具。
// WS-V 机械拆分自 LogAnalysisTests.swift（967 行越过 800 闸门），正文逐行原样搬运，
// 只把 `private` 降级为文件内可见所需的 internal，供下面四个测试类共用：
//   LogParsingTests / LogAggregationTests / LogCrashReportTests（+ 基类 LogAnalysisTestCase）。
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

typealias LogStamp = (Int, String) -> String

enum LogFixture {
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

func wallClock(_ year: Int, _ month: Int, _ day: Int,
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
func wallClockCandidates(_ year: Int, _ month: Int, _ day: Int,
                                 _ hour: Int, _ minute: Int, _ second: Int) -> [Date] {
    [wallClock(year, month, day, hour, minute, second, timeZone: .current),
     wallClock(year, month, day, hour, minute, second, timeZone: TimeZone(identifier: "UTC") ?? .current)]
        .compactMap { $0 }
}

func assertNearAnyWallClock(_ date: Date?, _ candidates: [Date],
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

func severitiesOf(_ lines: [String]) -> [LogSeverity?] {
    lines.map { LogLineParser.detectSeverity($0) }
}

@discardableResult
func writeLog(_ text: String, to url: URL) throws -> URL {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url, options: .atomic)
    return url
}

func makeEvent(_ severity: LogSeverity,
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
func dayShifted(_ base: Date, _ days: Int) -> Date {
    base.addingTimeInterval(TimeInterval(days * 86_400))
}
