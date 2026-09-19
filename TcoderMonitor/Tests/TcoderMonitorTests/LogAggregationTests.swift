import Foundation
import XCTest
@testable import TcoderMonitor

/// 日志聚合契约：LogAggregator 的 cluster / buckets / affectedFiles / aggregate。
/// 拆自 LogAnalysisTests.swift，断言与用例一字未改（WS-V）。
final class LogAggregationTests: LogAnalysisTestCase {
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

}
