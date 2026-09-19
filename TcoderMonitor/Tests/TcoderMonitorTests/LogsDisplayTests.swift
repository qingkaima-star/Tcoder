import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-M 日志页显示层契约：三态、趋势轴、文件表。
final class LogsDisplayTests: XCTestCase {

    private func summary(lines: Int = 0, files: Int = 0, errors: Int = 0) -> LogSummary {
        var logs = LogSummary()
        logs.totalLinesScanned = lines
        logs.errorCount = errors
        if files > 0 {
            logs.scannedFiles = (0..<files).map {
                ScannedLogFile(path: "/tmp/l\($0).log", sizeBytes: 1024, lineCount: 10,
                               modifiedAt: Date(), role: .error)
            }
        }
        return logs
    }

    // MARK: - 三态：没分析 / 没文件 / 真的 0

    func testMissingAnalysisIsNotZeroErrors() {
        XCTAssertNil(LogReading.count(nil) { $0.errorCount }, "没跑过分析不能报 0")
        XCTAssertNil(LogReading.count(summary(lines: 0, files: 0)) { $0.errorCount },
                     "跑了但一个文件都没读到，仍然是「没证据」")
        XCTAssertEqual(LogReading.count(summary(lines: 500, files: 1)) { $0.errorCount }, 0,
                       "读到了文件、错误确实是 0 —— 这是结论，必须显示 0")
    }

    func testTheTwoMissingSentencesAreDistinct() {
        XCTAssertEqual(LogReading.caption(nil) { _ in "x" }, "尚未分析")
        XCTAssertEqual(LogReading.caption(summary()) { _ in "x" }, "未发现日志文件")
        XCTAssertEqual(LogReading.caption(summary(lines: 10, files: 1)) { _ in "已核对" }, "已核对")
    }

    func testPerKiloNeedsATrustworthyDenominator() {
        XCTAssertNil(LogReading.perKiloCode(nil, code: nil))
        var code = CodeMetrics()
        code.codeLines = 0
        XCTAssertNil(LogReading.perKiloCode(summary(lines: 10, files: 1), code: code),
                     "有效代码行为 0 时不能算出每千行错误数")
        code.codeLines = 4000
        XCTAssertEqual(LogReading.perKiloCode(summary(lines: 10, files: 1), code: code), 0)
    }

    func testWarningShareOnlyWhenLinesWereScanned() {
        var logs = summary(lines: 0, files: 1)
        logs.warningCount = 3
        XCTAssertNil(LogReading.warningShareOfScanned(logs))
        logs.totalLinesScanned = 300
        XCTAssertEqual(LogReading.warningShareOfScanned(logs) ?? 0, 0.01, accuracy: 0.0001)
    }

    // MARK: - 趋势轴

    private func bucket(on day: Int, errors: Int, warnings: Int = 0, exceptions: Int = 0, crashes: Int = 0) -> LogBucket {
        let date = Calendar.current.date(byAdding: .day, value: day, to: Date()) ?? Date()
        return LogBucket(date: date, errors: errors, warnings: warnings, exceptions: exceptions, crashes: crashes)
    }

    func testTrendAxisUsesTheSharedIntegerCountAxis() {
        let buckets = [bucket(on: 0, errors: 4), bucket(on: 1, errors: 12, warnings: 6)]
        let axis = LogTrendChart.axis(for: buckets)
        XCTAssertEqual(axis, ChartScale.countAxis(peak: 18),
                       "峰值 = 堆叠柱与警告折线共用的最大值，轴走同一套台阶")
        XCTAssertEqual(axis.ticks.last, axis.maxValue)
        XCTAssertTrue(axis.ticks.allSatisfy { $0 == $0.rounded() }, "\(axis.ticks)")
        let empty = LogTrendChart.axis(for: [])
        XCTAssertGreaterThanOrEqual(empty.step, 1, "没有桶时也要给一条能画的整数轴")
        XCTAssertGreaterThan(empty.maxValue, 0)
        // 单日 1 条时最容易出现小数刻度。
        let single = LogTrendChart.axis(for: [bucket(on: 0, errors: 1)])
        XCTAssertTrue(single.ticks.allSatisfy { $0 == $0.rounded() }, "\(single.ticks)")
        XCTAssertGreaterThanOrEqual(single.maxValue, 1)
    }

    func testDayStrideFollowsSpan() {
        XCTAssertEqual(LogTrendChart.dayStride([bucket(on: 0, errors: 1)]), 1)
        XCTAssertEqual(LogTrendChart.dayStride([bucket(on: 0, errors: 1), bucket(on: 9, errors: 1)]), 2)
    }

    // MARK: - 文件表

    func testNegativeFileSizeReadsAsMissing() {
        XCTAssertEqual(LogsScannedFilesCard.sizeText(-1), "--")
        XCTAssertEqual(LogsScannedFilesCard.sizeText(0), "0 B")
        XCTAssertEqual(LogsScannedFilesCard.sizeText(1024), "1.0 KB")
    }

    /// 文件角色只能映射到 `Design/` 里的语义角色，页内不许出现一个颜色字面量。
    func testFileRolesMapToSemanticRolesWithoutInventingColors() {
        XCTAssertEqual(LogRoleStyle.role(for: .crash).name, "critical")
        XCTAssertEqual(LogRoleStyle.role(for: .error).name, "danger")
        XCTAssertEqual(LogRoleStyle.role(for: .build).name, "warning")
        XCTAssertEqual(LogRoleStyle.role(for: .system).name, "info")
        XCTAssertEqual(LogRoleStyle.role(for: .application).name, "neutral")
    }
}
