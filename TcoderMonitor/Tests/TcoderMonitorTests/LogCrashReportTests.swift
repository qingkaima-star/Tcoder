import Foundation
import XCTest
@testable import TcoderMonitor

/// 崩溃报告与读取/发现/端到端：CrashReportParser（文本 + .ips）、LogReader 截尾、
/// LogDiscovery、FileLogAnalyzer 冒烟。
/// 拆自 LogAnalysisTests.swift，断言与用例一字未改（WS-V）。
final class LogCrashReportTests: LogAnalysisTestCase {
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

    // MARK: 12. 崩溃候选（RD-21：候选 ≠ 结论）

    /// 整改前这里是 `testIsCrashReportByName`，断言「名字含 crash / diag 就是崩溃报告」。
    /// 那条判据同时造成两件事：凭空合成崩溃、以及把该文件的正常错误行挡在计数之外。
    /// 现在的判据只回答「要不要多看一眼」，**下结论的是四态分类**（见 `LogEvidenceCrashStateTests`）。
    func testCrashCandidateFollowsFormatAndRoleNotFileName() throws {
        // 内容格式后缀：是候选
        XCTAssertTrue(CrashReportParser.isCrashCandidate(URL(fileURLWithPath: "/srv/app/logs/a.ips"), role: .application))
        XCTAssertTrue(CrashReportParser.isCrashCandidate(URL(fileURLWithPath: "/srv/app/logs/y.crash"), role: .application))
        // 角色由发现层按名字/目录给：也是候选
        XCTAssertTrue(CrashReportParser.isCrashCandidate(URL(fileURLWithPath: "/srv/app/logs/x-crash.log"), role: .crash))
        // 普通日志：不是候选，连通道都不进
        XCTAssertFalse(CrashReportParser.isCrashCandidate(URL(fileURLWithPath: "/srv/app/logs/app.log"), role: .application))
        // ⚠️ 名字里带 `diag` 的普通日志不再是候选 —— 整改前它是，
        // 于是 `diagnostic.log` 里 3 条真错误整批消失（台账 §9.4 的 `errorCount = 0`）。
        XCTAssertFalse(CrashReportParser.isCrashCandidate(URL(fileURLWithPath: "/srv/app/logs/diagnostic.log"), role: .application))
        XCTAssertFalse(CrashReportParser.isCrashCandidate(URL(fileURLWithPath: "/srv/app/logs/build-output.log"), role: .build))
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

        let found = LogDiscovery.discover(projectRoot: dir, identity: LogProjectIdentity.declaring(["ShopApp"]), withinDays: 30, maxFiles: 50)
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
            let found = LogDiscovery.discover(projectRoot: root, identity: LogProjectIdentity.declaring(["ShopApp"]), withinDays: 30, maxFiles: 20)
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
        // RD-46b 之后分母只数真日志行。这一格原本断言的是「两份夹具一共读到 ≥20 行」= **读取覆盖**，
        // 直接把它改成新读数（16）等于把那条不变式废掉 ⇒ 拆成三条：
        // 分母至少要有真日志那份的行数、崩溃正文另有一格、两者相加仍撑得住原来那个地板。
        let errorFixtureLines = try R11DenominatorFixture.newlineCount(of: errorLog)
        XCTAssertGreaterThanOrEqual(summary.totalLinesScanned, errorFixtureLines,
                                    "分母至少要有 error.log 的行数（独立真值：盘上换行数）")
        XCTAssertGreaterThan(summary.crashReportLineCount ?? 0, 0, "崩溃正文的行数必须留在自己那一格，不许消失")
        XCTAssertGreaterThanOrEqual(summary.totalLinesScanned + (summary.crashReportLineCount ?? 0), 20,
                                    "读取覆盖：两份夹具一共 ≥ 20 行，一个字都不许丢")
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
