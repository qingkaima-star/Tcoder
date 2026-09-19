import Foundation
import XCTest
@testable import TcoderMonitor

/// 真实日志聚类现场校验：用 /tmp 下自建的多行 Java 堆栈 + EXC_BAD_ACCESS 崩溃日志跑一遍
/// FileLogAnalyzer，把签名与次数打印出来供人工核对（Obsidian 笔记里的数字来自这里）。
/// 夹具只在本测试内部于 NSTemporaryDirectory() 下创建，teardown 删除。
final class LogFixtureClusterTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-fixture-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Logs", isDirectory: true),
                                                withIntermediateDirectories: true)
        root = base
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root) }
        super.tearDown()
    }

    private func stamp(_ raw: String, daysAgo: Int) -> String {
        // 夹具日期相对「今天」生成，避免测试随时间失效，同时保证落在 withinDays 窗口内。
        let day = Calendar.current.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return raw.replacingOccurrences(of: "@DAY@", with: formatter.string(from: day))
    }

    private func write(_ name: String, _ text: String, daysAgo: Int = 0) throws {
        let url = root.appendingPathComponent("Logs").appendingPathComponent(name)
        try stamp(text, daysAgo: daysAgo).write(to: url, atomically: true, encoding: .utf8)
    }

    func testClusterRealJavaStackAndCrashLog() async throws {
        let errorLog = """
        @DAY@ 10:14:22,431 ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId=88213 user=4f9a2b7c-1d3e-4f5a-9b8c-7d6e5f4a3b2c
        java.lang.NullPointerException: Cannot invoke "com.example.shop.Price.getTotal()" because "price" is null
        \tat com.example.shop.OrderService.pay(OrderService.java:123)
        \tat com.example.shop.OrderController.submit(OrderController.java:56)
        Caused by: java.lang.IllegalStateException: price cache miss for sku 991-ABC
        \tat com.example.shop.PriceCache.lookup(PriceCache.java:44)
        @DAY@ 10:14:23,002 WARN  [order-service] c.e.s.Retry - 第 2 次重试
        @DAY@ 11:02:07,884 ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId=90455 user=1a2b3c4d-5e6f-7a8b-9c0d-1e2f3a4b5c6d
        java.lang.NullPointerException: Cannot invoke "com.example.shop.Price.getTotal()" because "price" is null
        \tat com.example.shop.OrderService.pay(OrderService.java:123)
        \tat com.example.shop.OrderController.submit(OrderController.java:56)
        @DAY@ 08:12:33,456 ERROR [order-service] c.e.s.PayClient - HTTP 调用超时 url=https://api.example.com/v1/pay cost=30005ms
        java.net.SocketTimeoutException: Read timed out
        \tat com.example.shop.PayClient.post(PayClient.java:88)
        @DAY@ 08:12:34,001 FATAL [order-service] c.e.s.Bootstrap - 关键服务不可用，退出
        @DAY@ 08:13:00,100 INFO  [order-service] c.e.s.Health - 健康检查通过
        """

        let crashLog = """
        Incident Identifier: 7B1D9F3E-4A55-4C8D-9E2F-1A2B3C4D5E6F
        Exception Type:      EXC_BAD_ACCESS (SIGSEGV)
        Exception Codes:     0x0000000000000001, 0x0000000000000000
        Termination Reason:  SIGNAL 11
        Thread 3 Crashed:
        0   libsystem_kernel.dylib   0x00000001a2b3c4d5 __pthread_kill + 8
        1   AppKit                   0x000000018f9e8d7c _NSViewDrawRect + 124
        2   TcoderSample             0x0000000100a2b3c4 com.example.shop.Cache.flush() + 68 (Cache.swift:210)
        3   TcoderSample             0x0000000100a2d110 com.example.shop.App.main() + 316 (main.swift:12)
        Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value: file TcoderSample/Cache.swift, line 210
        """

        try write("error.log", errorLog, daysAgo: 1)
        try write("crash.log", crashLog, daysAgo: 1)

        let summary = try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)

        print("=== WS-C 日志夹具实测 ===")
        print("扫描文件数 = \(summary.scannedFiles.count)")
        for file in summary.scannedFiles {
            print("  \(file.role.rawValue) \(file.path.split(separator: "/").suffix(2).joined(separator: "/"))"
                + "  \(file.sizeBytes) 字节 / \(file.lineCount) 行")
        }
        print("总行数 = \(summary.totalLinesScanned)  ERROR = \(summary.errorCount)"
            + "  EXCEPTION = \(summary.exceptionCount)  FATAL = \(summary.fatalCount)"
            + "  CRASH = \(summary.crashCount)  WARN = \(summary.warningCount)  INFO = \(summary.infoLineCount)")
        print("窗口 = \(LogRecency.describe(summary.windowStart)) → \(LogRecency.describe(summary.windowEnd))")
        print("趋势分桶数 = \(summary.trend.count)")
        print("--- Top Errors（签名 / 次数 / 严重度 / 源文件）---")
        for cluster in summary.topErrors {
            print("[\(cluster.severity.rawValue)] ×\(cluster.count)  \(cluster.signature)")
            print("    首次 \(cluster.firstSeenDescription) · 最近 \(cluster.lastSeenDescription)"
                + " · 源文件 \(cluster.sourceFile) · 样例 \(cluster.sampleLines.count) 行"
                + " · 栈顶 \(cluster.stackTopFrames.prefix(3).joined(separator: " ← "))")
        }
        print("--- 受影响源文件 ---")
        for (file, count) in summary.affectedFiles.sorted(by: { $0.value > $1.value }) {
            print("  \(file) ×\(count)")
        }

        XCTAssertTrue(summary.hasData, "夹具里有两个日志文件，必须扫到内容")
        XCTAssertGreaterThanOrEqual(summary.totalLinesScanned, 25,
                                    "两份夹具合计 25 行，读取行数必须覆盖到")
        // 本 App 自己的 ~/Library/Logs/DiagnosticReports/*.ips 也会被一并扫到，所以只断言夹具在里面。
        let paths = Set(summary.scannedFiles.map(\.path))
        XCTAssertTrue(paths.contains(where: { $0.hasSuffix("Logs/error.log") }), "夹具 error.log 必须被扫到")
        XCTAssertTrue(paths.contains(where: { $0.hasSuffix("Logs/crash.log") }), "夹具 crash.log 必须被扫到")

        // 聚类的核心要求：同一种异常不管 orderId / UUID / 时间戳怎么变，都必须合成一个签名，
        // 并且签名要落在异常类名上（用户口径），而不是落在前缀文案上。
        let npe = summary.topErrors.filter { $0.signature.contains("NullPointerException") }
        XCTAssertFalse(npe.isEmpty, "必须出现以 java.lang.NullPointerException 为主 token 的签名，实得：\(summary.topErrors.map(\.signature))")
        let merged = npe.reduce(0) { $0 + $1.count }
        XCTAssertGreaterThanOrEqual(merged, 2, "两次同类 NPE 必须合并计数，实得 \(merged)")
        XCTAssertEqual(npe.count, 1, "两次 NPE 只能聚成一条签名，实得 \(npe.map(\.signature))")
        if let cluster = npe.first {
            XCTAssertFalse(cluster.stackTopFrames.isEmpty, "NPE 签名要带上堆栈顶帧")
            XCTAssertTrue(cluster.stackTopFrames.contains(where: { $0.contains("OrderService.java:123") }),
                          "栈顶要含夹具里的抛出点，实得 \(cluster.stackTopFrames)")
            XCTAssertFalse(cluster.displayMessage.isEmpty)
            XCTAssertNotNil(cluster.firstSeen)
            XCTAssertNotNil(cluster.lastSeen)
        }
        XCTAssertTrue(summary.topErrors.contains(where: { $0.signature.contains("SocketTimeoutException") }),
                      "超时那一条要单独成签名")
        XCTAssertTrue(summary.affectedFiles.keys.contains("OrderService.java"),
                      "堆栈里的源文件必须被统计到，实得 \(summary.affectedFiles)")
        XCTAssertTrue(summary.affectedFiles.keys.contains("PayClient.java"))
        XCTAssertGreaterThan(summary.warningCount, 0, "WARN 行必须计入警告")
        XCTAssertGreaterThan(summary.fatalCount + summary.errorCount, 0)
        XCTAssertTrue(summary.trend.count >= 1, "按天分桶必须至少一个桶")
    }

    /// 崩溃报告的证据不能丢：EXC_BAD_ACCESS 必须单独成一条 crash 级签名。
    func testCrashReportProducesCrashCluster() async throws {
        let crash = """
        Incident Identifier: AAAAAAAA-1111-2222-3333-444444444444
        Exception Type:      EXC_BAD_ACCESS (SIGSEGV)
        Exception Codes:     0x000000000000000d, 0x0000000000000000
        Thread 5 Crashed:
        0   TcoderSample   0x0000000100004a40 com.example.shop.Store.write(_:) + 128 (Store.swift:77)
        1   TcoderSample   0x0000000100004b80 com.example.shop.Store.flush() + 64 (Store.swift:90)
        Fatal error: Unexpectedly found nil while implicitly unwrapping an Optional value: file TcoderSample/Store.swift, line 77
        """
        try write("crash.log", crash, daysAgo: 0)

        let summary = try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
        print("--- 崩溃报告单独跑 ---")
        print("CRASH = \(summary.crashCount)  FATAL = \(summary.fatalCount)")
        for cluster in summary.topErrors {
            print("[\(cluster.severity.rawValue)] ×\(cluster.count)  \(cluster.signature)")
        }

        XCTAssertGreaterThan(summary.crashCount, 0, "EXC_BAD_ACCESS 必须算进崩溃计数")
        let crashClusters = summary.topErrors.filter { $0.severity == .crash }
        XCTAssertFalse(crashClusters.isEmpty, "至少要有一个 crash 级签名")
        XCTAssertTrue(crashClusters.contains { $0.signature.contains("EXC_BAD_ACCESS")
                        || $0.signature.contains("Fatal error") },
                      "某个 crash 签名的主 token 要能看出崩溃类型，实得 \(crashClusters.map(\.signature))")
        for cluster in crashClusters {
            XCTAssertFalse(cluster.signature.contains("AAAAAAAA"),
                           "签名里绝不能留下 incident id 原值，否则每次崩溃都聚不到一起")
            XCTAssertFalse(cluster.signature.contains("0x000000000000000d"),
                           "签名里的地址必须归一化")
        }
        // 帧可能被挂到同组的另一条事件上，所以跨全部 crash 签名找抛出点。
        XCTAssertTrue(crashClusters.flatMap(\.stackTopFrames).contains(where: { $0.contains("Store.swift") }),
                      "崩溃栈里的 Store.swift 必须出现在栈顶帧里，实得 \(crashClusters.map(\.stackTopFrames))")
        // 纯文本崩溃日志走同一套标题口径，不能把机器字段拼成标题。
        for cluster in crashClusters {
            XCTAssertFalse(cluster.displayMessage.contains("Incident Identifier"),
                           "crash.log 的标题不得含机器字段，实得 \(cluster.displayMessage)")
            XCTAssertFalse(cluster.displayMessage.contains("Exception Codes"),
                           "crash.log 的标题不得含机器字段，实得 \(cluster.displayMessage)")
            XCTAssertTrue(cluster.displayMessage.contains("EXC_BAD_ACCESS")
                            || cluster.displayMessage.contains("Fatal error"),
                          "标题要能看出崩溃类型，实得 \(cluster.displayMessage)")
        }
    }

    /// .ips 的 displayMessage 必须是人能读懂的一句话，不能是裸 JSON 片段；
    /// 并且同一份报告只能产出一条 cluster（逐行解析器与崩溃解析器不能各算一遍）。
    func testIpsReportShowsReadableTitleAndSingleCluster() async throws {
        let header = """
        {"app_name":"TcoderMonitor","app_version":"1.0","bug_type":"309","incident_id":"7B1D9F3E-4A55-4C8D-9E2F-1A2B3C4D5E6F","name":"TcoderMonitor","os_version":"macOS 26.5","timestamp":"2026-09-19 08:13:01.00 +0800"}
        """
        let body = """
        {"bug_type":"309","timestamp":"2026-09-19 08:13:01.00 +0800","procName":"TcoderMonitor",\
        "exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV","subtype":"KERN_INVALID_ADDRESS at 0x000000016f8a8b00","codes":"0x0000000000000001, 0x87b32a038583d000"},\
        "termination":{"flags":0,"code":11,"namespace":"SIGNAL","indicator":"Segmentation fault: 11"},\
        "asi":{"Backtrace":["frame A = 1","frame B = 2"]},\
        "threads":[{"id":1,"name":"com.apple.main-thread","triggered":true,\
        "backtrace":{"frames":[{"image_offset":44720,"symbol":"_platform_strlen","sourceLineInfo":{"file":"Cache.swift","line":210}}]}}],\
        "usedImages":[{"name":"libsystem_platform.dylib","path":"/usr/lib/libsystem_platform.dylib"}]}
        """
        let url = root.appendingPathComponent("Logs").appendingPathComponent("TcoderMonitor-2026-09-19-081301.ips")
        try (header + "\n" + body).write(to: url, atomically: true, encoding: .utf8)

        let summary = try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
        print("--- .ips 单份报告 ---")
        print("CRASH = \(summary.crashCount)  EXCEPTION = \(summary.exceptionCount)")
        for cluster in summary.topErrors {
            print("[\(cluster.severity.rawValue)] ×\(cluster.count)  \(cluster.signature)")
            print("    标题: \(cluster.displayMessage)")
        }

        let crashClusters = summary.topErrors.filter { $0.severity == .crash }
        XCTAssertEqual(crashClusters.count, 1,
                       "一份 .ips 只能产出一条崩溃 cluster，实得 \(crashClusters.map(\.signature))")
        guard let cluster = crashClusters.first else { return }
        XCTAssertEqual(cluster.count, 1, "一次崩溃必须计 1 次，实得 \(cluster.count)")

        // 裸 JSON / 机器字段当标题是用户明确反馈看不懂的问题。
        // 注意 `Cache.swift:210` 里的冒号是合法的，所以只禁 JSON 结构字符与已知机器键。
        for banned in ["{", "}", "\"", "bug_type", "codes", "flags", "Incident Identifier", "asi"] {
            XCTAssertFalse(cluster.displayMessage.lowercased().contains(banned.lowercased()),
                           "displayMessage 不得含 JSON/机器字段「\(banned)」，实得 \(cluster.displayMessage)")
        }
        XCTAssertTrue(cluster.displayMessage.contains("EXC_BAD_ACCESS"),
                      "标题要以 Exception Type 开头，实得 \(cluster.displayMessage)")
        XCTAssertTrue(cluster.displayMessage.contains("SIGSEGV"))
        XCTAssertTrue(cluster.displayMessage.contains("_platform_strlen"),
                      "标题要带崩溃符号，实得 \(cluster.displayMessage)")
        XCTAssertLessThan(cluster.displayMessage.count, 160, "标题要短到能一行读完")
        // 签名仍保留稳定形式，不受标题改写影响。
        XCTAssertTrue(cluster.signature.contains("EXC_BAD_ACCESS"))
        XCTAssertFalse(cluster.signature.contains("87b32a038583"), "签名里的地址必须归一化")
    }

    /// 归属规则：只认报告主名整段等于项目名，"Tcoder" 不得吃掉本工具自己的 "TcoderMonitor" 崩溃。
    func testDiagnosticReportOwnershipIsExactNotSubstring() {
        func report(_ name: String) -> URL { URL(fileURLWithPath: "/tmp/\(name).ips") }
        XCTAssertTrue(LogDiscovery.isOwnDiagnosticReport(report("TcoderMonitor-2026-09-19-081301"),
                                                         projectName: "TcoderMonitor"),
                      "自己的报告必须算自己的")
        XCTAssertFalse(LogDiscovery.isOwnDiagnosticReport(report("TcoderMonitor-2026-09-19-081301"),
                                                          projectName: "Tcoder"),
                       "项目名是另一个可执行名的前缀时不得命中（用户实测踩到的问题）")
        XCTAssertTrue(LogDiscovery.isOwnDiagnosticReport(report("tcoder-2026-09-19-081301"),
                                                         projectName: "Tcoder"),
                      "大小写不同但整段相等仍算命中")
        XCTAssertFalse(LogDiscovery.isOwnDiagnosticReport(report("TcoderHelper-2026-09-19-081301"),
                                                          projectName: "Tcoder"),
                       "主名带后缀的是另一个可执行文件，不得混进来")
        XCTAssertFalse(LogDiscovery.isOwnDiagnosticReport(report("Firefox-2026-09-19-081301"),
                                                          projectName: "Tcoder"),
                       "别的应用的报告一律不读（AGENTS.md 禁区）")
        XCTAssertFalse(LogDiscovery.isOwnDiagnosticReport(report("TcoderMonitor-2026-09-19-081301"),
                                                          projectName: "  "),
                       "项目名为空时一律不命中，避免匹配到全部报告")
    }
}
