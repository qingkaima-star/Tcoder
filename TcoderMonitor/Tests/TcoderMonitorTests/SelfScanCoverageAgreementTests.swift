import XCTest
@testable import TcoderMonitor

/// OWNER: 总工程师（覆盖率读数与 `llvm-cov` 的一致性取证）
///
/// 为什么要这一条：2026-09-20 主线删掉 988 行基座代码又加了 559 行测试之后，
/// README 里那组"与 llvm-cov 逐位一致"的数字（`10618/23611`）**静默过期**了，
/// 因为全仓没有任何测试引用过真 lcov——`CoverageAnalyzerTests` 7 条全吃合成夹具。
/// 合成夹具能证明"解析逻辑对"，证明不了"对着真实产物也算对"。
///
/// 跑法（默认跳过，避免依赖各工作树各自的 `.build`）：
///   TCODER_SELF_LCOV=<某份真 lcov.info> ./scripts/locked_build.sh test
/// 生成一份真 lcov：
///   ./scripts/locked_build.sh test --enable-code-coverage
///   xcrun llvm-cov export -format=lcov \
///     -instr-profile .build/arm64-apple-macosx/debug/codecov/default.profdata \
///     .build/arm64-apple-macosx/debug/TcoderMonitorPackageTests.xctest/Contents/MacOS/TcoderMonitorPackageTests
final class SelfScanCoverageAgreementTests: XCTestCase {

    /// 与 `CoverageAnalyzer` **零共享代码**的独立汇总：只认 lcov 的记录级 `LF:`/`LH:`。
    /// 两边算法必须不同，否则"一致"只是同一份代码自我确认。
    ///
    /// #37 之后这里同时产出**两个口径**：`production*` 用下面这套**自己写死的**排除条件，
    /// 刻意不调用 `CoverageScope.isProductionSource`——那正是"独立见证"的意义：
    /// 两边各自理解「什么算测试代码」，数字还相等，才算对上了。
    private struct IndependentTally {
        var records = 0
        var linesFound = 0
        var linesHit = 0
        var productionRecords = 0
        var productionLinesFound = 0
        var productionLinesHit = 0
        var files: [String] = []
    }

    /// 独立实现的口径判定。改动它必须同时改 `CoverageScope`，两边一起动才算一致。
    private func independentIsProductionSource(_ path: String) -> Bool {
        if path.isEmpty { return false }
        if path.contains("/Tests/") { return false }
        if path.contains("PackageTests") { return false }
        if path.contains("/.build/") { return false }
        if path.split(separator: "/").last.map({ $0.hasSuffix("Tests.swift") }) ?? false { return false }
        return true
    }

    private func tallyLcov(_ text: String) -> IndependentTally {
        var t = IndependentTally()
        var seenLFInRecord = false
        var inProduction = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SF:") {
                let path = String(line.dropFirst(3))
                t.files.append(path)
                inProduction = independentIsProductionSource(path)
            } else if line.hasPrefix("LF:") {
                // 一份记录里可能重复出现 LF（多工具合并），按"每条记录只取第一条"计，
                // 与 lcov 惯例一致；重复出现要能看出来，所以同时记 records 数。
                if !seenLFInRecord, let v = Int(line.dropFirst(3)) {
                    t.linesFound += v
                    if inProduction { t.productionLinesFound += v }
                    seenLFInRecord = true
                }
            } else if line.hasPrefix("LH:") {
                if let v = Int(line.dropFirst(3)) {
                    t.linesHit += v
                    if inProduction { t.productionLinesHit += v }
                }
            } else if line == "end_of_record" {
                t.records += 1
                if inProduction { t.productionRecords += 1 }
                seenLFInRecord = false
                inProduction = false
            }
        }
        return t
    }

    // MARK: - 机制：独立汇总器自己也要被测（否则它坏了会让一致性用例"永远绿"）

    func testIndependentLcovTallyMatchesHandComputedExpectation() throws {
        let fixture = """
        TN:
        SF:Sources/A.swift
        LF:200
        LH:156
        end_of_record
        SF:Sources/B.swift
        LF:100
        LH:72
        end_of_record
        """
        let t = tallyLcov(fixture)
        XCTAssertEqual(t.records, 2, "两条记录都要被数到")
        XCTAssertEqual(t.linesFound, 300)
        XCTAssertEqual(t.linesHit, 228)
        XCTAssertEqual(t.files, ["Sources/A.swift", "Sources/B.swift"])
        // 全生产码时两个口径必须相等，且分母不许为 0（否则"口径生效"是空话）。
        XCTAssertEqual(t.productionLinesFound, 300)
        XCTAssertEqual(t.productionLinesHit, 228)
        XCTAssertEqual(t.productionRecords, 2)
    }

    /// 掺进测试码之后，独立汇总器的两个口径必须分开——它自己也要被验一次，
    /// 否则它退化成「生产码 == 全量」时，下面的一致性用例会一起变成永真。
    func testIndependentTallySeparatesTestCodeRecords() throws {
        let fixture = """
        TN:
        SF:/repo/Sources/A.swift
        LF:100
        LH:40
        end_of_record
        SF:/repo/Tests/ATests.swift
        LF:100
        LH:100
        end_of_record
        SF:/repo/.build/Gen/Model.swift
        LF:50
        LH:50
        end_of_record
        """
        let t = tallyLcov(fixture)
        XCTAssertEqual(t.records, 3)
        XCTAssertEqual(t.linesFound, 250, "全口径分母要保住所有记录")
        XCTAssertEqual(t.linesHit, 190)
        XCTAssertEqual(t.productionRecords, 1, "只有 Sources 那条算生产码")
        XCTAssertEqual(t.productionLinesFound, 100)
        XCTAssertEqual(t.productionLinesHit, 40)
    }

    /// 同一份合成内容喂给真 `CoverageAnalyzer`，与独立汇总器**相等**——
    /// 这条不受 env 门控，保证"一致性"这件事在默认测试轮里也被机制性地守着。
    /// #37 起两个口径都要对得上：只对一个口径，两边同时错也看不出来。
    func testAnalyzerAgreesWithIndependentTallyOnSyntheticReport() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-agree-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        let fixture = """
        TN:
        SF:Sources/A.swift
        LF:200
        LH:156
        end_of_record
        SF:Sources/B.swift
        LF:100
        LH:72
        end_of_record
        """
        try fixture.write(
            to: dir.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)

        let expected = tallyLcov(fixture)
        let metrics = try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.linesTotal, expected.linesFound)
        XCTAssertEqual(report.linesCovered, expected.linesHit)
        XCTAssertEqual(report.allLinesTotal, expected.linesFound, "全口径分母要一致")
        XCTAssertEqual(report.allLinesCovered, expected.linesHit, "全口径分子要一致")
        XCTAssertGreaterThan(report.linesTotal, 0, "分母为 0 的一致性没有意义")
    }

    /// 混合口径的合成报告：两套**互不共享代码**的实现必须各自把测试码剔出去，
    /// 且剔完还剩同样的数。这才是 #37 那条口径改动的验收位。
    func testAnalyzerAndIndependentTallyAgreeOnMixedProductionAndTestRecords() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-mixed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        let fixture = """
        TN:
        SF:/repo/Sources/Only.swift
        LF:120
        LH:60
        end_of_record
        SF:/repo/Tests/OnlyTests.swift
        LF:60
        LH:60
        end_of_record
        SF:/repo/.build/checkouts/Gen/Model.swift
        LF:20
        LH:20
        end_of_record
        """
        try fixture.write(
            to: dir.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)

        let truth = tallyLcov(fixture)
        let metrics = try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)

        XCTAssertEqual(report.linesTotal, truth.productionLinesFound, "计分分母与独立汇总不一致")
        XCTAssertEqual(report.linesCovered, truth.productionLinesHit, "计分分子与独立汇总不一致")
        XCTAssertEqual(report.allLinesTotal, truth.linesFound, "全量分母与独立汇总不一致")
        XCTAssertEqual(report.allLinesCovered, truth.linesHit, "全量分子与独立汇总不一致")
        XCTAssertGreaterThan(report.allLinesTotal ?? 0, report.linesTotal,
                             "两个口径相等说明两边都没真的排除测试码——一致性会退化成自我确认")
        XCTAssertEqual(metrics.overallLinePercent ?? -1, 50, accuracy: 0.001, "生产码 60/120 = 50%")
        XCTAssertEqual(metrics.allSourcesLinePercent ?? -1, 70, accuracy: 0.001, "全口径 140/200 = 70%")
        XCTAssertTrue(report.isScopeSeparated, "lcov 有 SF: 记录就必须走按文件区分的分支")
    }

    // MARK: - 真实产物：与 llvm-cov 导出的 lcov 逐位对齐

    func testAnalyzerMatchesLlvmCovExportedLcov() async throws {
        let path = ProcessInfo.processInfo.environment["TCODER_SELF_LCOV"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "需显式给一份真 lcov：TCODER_SELF_LCOV=<路径>")
        let url = URL(fileURLWithPath: path)
        let text = try String(contentsOf: url, encoding: .utf8)

        let truth = tallyLcov(text)
        // 正向断言分母非零且确实是"真实规模"的产物——分母为 0 的一致性就是永真绿。
        XCTAssertGreaterThan(truth.records, 50, "真 lcov 应有几十条以上记录，实得 \(truth.records)")
        XCTAssertGreaterThan(truth.linesFound, 10_000, "分母异常小，八成是 lcov 没导全")

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-real-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try text.write(
            to: dir.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)

        // 全口径：与独立汇总逐位一致（这条原本就有）。
        XCTAssertEqual(report.allLinesTotal ?? report.linesTotal, truth.linesFound,
                       "分析器全量分母与独立汇总不一致（lcov 记录数 \(truth.records)）")
        XCTAssertEqual(report.allLinesCovered ?? report.linesCovered, truth.linesHit,
                       "分析器全量分子与独立汇总不一致")
        XCTAssertEqual(metrics.allSourcesLinePercent ?? 0,
                       Double(truth.linesHit) / Double(truth.linesFound) * 100,
                       accuracy: 0.01)

        // 计分口径：两边各自算的生产码也必须一致，且分母不许为 0。
        XCTAssertGreaterThan(truth.productionRecords, 0, "独立汇总一条生产码都没认出来，八成是路径口径漂了")
        XCTAssertEqual(report.linesTotal, truth.productionLinesFound,
                       "分析器生产码分母与独立汇总不一致")
        XCTAssertEqual(report.linesCovered, truth.productionLinesHit,
                       "分析器生产码分子与独立汇总不一致")

        // 把真实数字打进输出，供 README 的「这些数字是跟谁对齐的」逐字引用。
        let fullPercent = Double(truth.linesHit) / Double(truth.linesFound) * 100
        let productionPercent = Double(truth.productionLinesHit) / Double(truth.productionLinesFound) * 100
        print("【自扫覆盖率对齐】全口径 LH=\(truth.linesHit) LF=\(truth.linesFound)"
              + " =\(String(format: "%.2f", fullPercent))%（记录 \(truth.records)/\(truth.files.count)）")
        print("【自扫覆盖率对齐】生产码 LH=\(truth.productionLinesHit)"
              + " LF=\(truth.productionLinesFound) =\(String(format: "%.2f", productionPercent))%"
              + "（记录 \(truth.productionRecords)）；分析器 "
              + "\(report.linesCovered)/\(report.linesTotal) =\(String(format: "%.2f", metrics.overallLinePercent ?? 0))%")
        print("【自扫覆盖率对齐】被排除的测试/派生分母 "
              + "\(truth.linesFound - truth.productionLinesFound) 行"
              + "（占分母 \(String(format: "%.2f", Double(truth.linesFound - truth.productionLinesFound) / Double(truth.linesFound) * 100))%）")
    }
}
