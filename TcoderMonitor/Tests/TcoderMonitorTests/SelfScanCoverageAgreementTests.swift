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
    private struct IndependentTally {
        var records = 0
        var linesFound = 0
        var linesHit = 0
        var files: [String] = []
    }

    private func tallyLcov(_ text: String) -> IndependentTally {
        var t = IndependentTally()
        var seenLFInRecord = false
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("SF:") {
                t.files.append(String(line.dropFirst(3)))
            } else if line.hasPrefix("LF:") {
                // 一份记录里可能重复出现 LF（多工具合并），按"每条记录只取第一条"计，
                // 与 lcov 惯例一致；重复出现要能看出来，所以同时记 records 数。
                if !seenLFInRecord, let v = Int(line.dropFirst(3)) {
                    t.linesFound += v
                    seenLFInRecord = true
                }
            } else if line.hasPrefix("LH:") {
                if let v = Int(line.dropFirst(3)) { t.linesHit += v }
            } else if line == "end_of_record" {
                t.records += 1
                seenLFInRecord = false
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
    }

    /// 同一份合成内容喂给真 `CoverageAnalyzer`，与独立汇总器**相等**——
    /// 这条不受 env 门控，保证"一致性"这件事在默认测试轮里也被机制性地守着。
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

        XCTAssertEqual(report.linesTotal, truth.linesFound,
                       "分析器分母与独立汇总不一致（lcov 记录数 \(truth.records)）")
        XCTAssertEqual(report.linesCovered, truth.linesHit,
                       "分析器分子与独立汇总不一致")
        XCTAssertEqual(metrics.overallLinePercent ?? 0,
                       Double(truth.linesHit) / Double(truth.linesFound) * 100,
                       accuracy: 0.01)

        // 把真实数字打进输出，供 README 的「这些数字是跟谁对齐的」逐字引用。
        print("【自扫覆盖率对齐】记录=\(truth.records) LH=\(truth.linesHit) LF=\(truth.linesFound)"
              + " 分析器=\(report.linesCovered)/\(report.linesTotal)"
              + " 百分比=\(String(format: "%.2f", metrics.overallLinePercent ?? 0))%")
    }
}
