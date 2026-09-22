import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-F 夹具实验室 · 覆盖率：五种报告格式的手写真值对账，以及分母为零必须按「缺席」而非 0% 处理。
/// 拆自 ManifestLabFixtureTests.swift，断言与用例一字未改（WS-V）。
final class ManifestLabCoverageTests: ManifestLabTestCase {
    // MARK: - 2. 覆盖率

    func testCoverageReportsMatchHandWrittenNumbers() async throws {
        let outcome = try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root,
                                                                     options: .default)
        let coverage = outcome.metrics
        // RD-25：全部读数（进总数的 + 被分开留档的）。旧断言只看 `coverage.reports`，
        // 那时那里头躺着五份**被直接相加**的报告 —— 正是本轮要修的伪精确形状。
        let readings = coverage.reports + outcome.merge.separateReadings

        print("=== WS-F 夹具 · 覆盖率实测 ===")
        print("发现报告文件 \(coverage.scannedFileCount) 个，计入总数 \(coverage.reports.count) 份，"
            + "分开留档 \(outcome.merge.separateReadings.count) 份")
        print("合并台账：\(outcome.merge.statement)")
        for report in readings {
            print("  \(report.toolName) kind=\(report.kind.rawValue)"
                + " 行 \(report.linesCovered)/\(report.linesTotal) = \(String(format: "%.2f", report.linePercent))%"
                + " 分支 \(report.branchesCovered)/\(report.branchesTotal.map(String.init) ?? "nil")"
                + " 方法 \(report.methodsCovered)/\(report.methodsTotal)"
                + "  <- \(report.path.replacingOccurrences(of: root.path, with: ""))")
        }
        let line = coverage.overallLinePercent ?? -1
        let branch = coverage.overallBranchPercent ?? -1
        print("合计行覆盖 \(String(format: "%.6f", line))%  分支 \(String(format: "%.4f", branch))%"
            + "  单测口径 \(coverage.unit.map { String(format: "%.1f", $0.linePercent) } ?? "无")"
            + "  风险 \(coverage.riskLevel.rawValue)")

        XCTAssertEqual(coverage.scannedFileCount, 5, "五份报告都要被发现（含 target/ 与 coverage/ 里的）")
        XCTAssertEqual(readings.count, 5, "五份报告的读数一份都不许丢（分开呈现）")
        XCTAssertEqual(coverage.reports.count, 0,
                       "五份互不可核对的报告不得凑成一个项目总数")
        XCTAssertFalse(coverage.hasData, "有报告 ≠ 有可信的总分")

        func report(_ tool: String, _ suffix: String) throws -> CoverageReport {
            try require(readings.first { $0.toolName == tool && $0.path.hasSuffix(suffix) },
                        "缺报告 \(tool) @ \(suffix)")
        }

        // lcov：LH/LF、BRH/BRF、FNH/FNF 各自对齐，且 /unit/ 路径要归成单元测试
        let lcov = try report("lcov", "frontend/coverage/unit/lcov.info")
        XCTAssertEqual(lcov.linesCovered, 75)
        XCTAssertEqual(lcov.linesTotal, 100)
        XCTAssertEqual(lcov.branchesCovered, 24)
        XCTAssertEqual(lcov.branchesTotal, 40)
        XCTAssertEqual(lcov.methodsCovered, 15)
        XCTAssertEqual(lcov.methodsTotal, 20)
        XCTAssertEqual(lcov.kind, .unit, "路径含 /unit/ 必须归类为单元测试")

        // istanbul：取 total.lines 的 covered/total，不能被 statements 顶掉
        let istanbul = try report("istanbul / nyc", "coverage-summary.json")
        XCTAssertEqual(istanbul.linesCovered, 300, "必须用 total.lines，不能被 statements(315/420) 顶掉")
        XCTAssertEqual(istanbul.linesTotal, 400)
        XCTAssertEqual(istanbul.branchesCovered, 78)
        XCTAssertEqual(istanbul.branchesTotal, 120)
        XCTAssertEqual(istanbul.methodsCovered, 45)
        XCTAssertEqual(istanbul.methodsTotal, 60)
        XCTAssertEqual(istanbul.linePercent, 75, accuracy: 1e-9)

        // JaCoCo：必须取 report 级 counter（文档末尾那组），不能累加各 package 的 counter
        let jacoco = try report("JaCoCo", "jacoco.xml")
        XCTAssertEqual(jacoco.linesCovered, 175, "report 级 LINE covered=175")
        XCTAssertEqual(jacoco.linesTotal, 200, "report 级 LINE 25+175=200；累加 package/class counter 会虚报成 140")
        XCTAssertEqual(jacoco.branchesCovered, 60)
        XCTAssertEqual(jacoco.branchesTotal, 80)
        XCTAssertEqual(jacoco.methodsCovered, 40)
        XCTAssertEqual(jacoco.methodsTotal, 50)
        XCTAssertNotEqual(jacoco.linesTotal, 140, "140 = 各 package counter 累加的错误口径")

        let coveragePy = try report("coverage.py", "coverage.xml")
        XCTAssertEqual(coveragePy.linesCovered, 200)
        XCTAssertEqual(coveragePy.linesTotal, 250)
        XCTAssertEqual(coveragePy.branchesCovered, 52)
        XCTAssertEqual(coveragePy.branchesTotal, 80)

        let clover = try report("clover", "clover.xml")
        XCTAssertEqual(clover.linesCovered, 90, "取 project 级 metrics（最后一组），不是文件级 28")
        XCTAssertEqual(clover.linesTotal, 120)

        // RD-25 改判：旧断言 `line == 840/1070 = 78.5%`、`branch == 214/320` 是**五份报告
        // 的 covered 与 total 各自累加相除**得到的 —— 五种生态的报告彼此覆盖了哪些文件根本没有
        // 共同口径（istanbul 的 `total.lines` 与 JaCoCo 的 report 级 LINE 计的不是同一批行），
        // 那个数精确到小数点后九位，却是彻底的伪精确。现在的判据：**不给总数**。
        _ = line
        _ = branch
        XCTAssertNil(coverage.overallLinePercent,
                     "五份互不可核对的汇总报告不得累加成一个总数：\(outcome.merge.statement)")
        XCTAssertNil(coverage.overallBranchPercent)
        XCTAssertEqual(outcome.merge.basis, .nothingMergeable)
        XCTAssertEqual(outcome.merge.dropped.count, 5, "五份全部点名（含那份 DA 与 LF 对不上的 lcov）")
        XCTAssertTrue(readings.allSatisfy { $0.generationText.isEmpty == false },
                      "每一份报告都要能生成一句时间描述（哪怕是未知）")
        XCTAssertEqual(coverage.riskLevel, .none, "没有总数 ⇒ 风险档也不许编")
        XCTAssertNil(coverage.unit)
        XCTAssertNil(coverage.integration, "夹具里没有集成测试路径的报告")
    }

    /// 分母为 0 必须是「无数据」，不能伪装成 0%。
    func testZeroDenominatorCoverageIsAbsenceNotZeroPercent() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("acme-zero-cov-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let fm = FileManager.default
        try fm.createDirectory(at: base.appendingPathComponent("coverage", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("target/jacoco", isDirectory: true),
                               withIntermediateDirectories: true)
        try fm.createDirectory(at: base.appendingPathComponent("py/coverage", isDirectory: true),
                               withIntermediateDirectories: true)
        try "TN:x\nSF:a.ts\nLF:0\nLH:0\nFNF:0\nFNH:0\nend_of_record\n"
            .write(to: base.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)
        try #"<?xml version="1.0"?><report><counter type="LINE" missed="0" covered="0"/></report>"#
            .write(to: base.appendingPathComponent("target/jacoco/jacoco.xml"), atomically: true, encoding: .utf8)
        try #"{"total":{"lines":{"total":0,"covered":0,"pct":0.0}}}"#
            .write(to: base.appendingPathComponent("py/coverage/coverage-summary.json"), atomically: true, encoding: .utf8)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: base, options: .default)
        print("=== WS-F 夹具 · 零分母 ===")
        print("扫到 \(metrics.scannedFileCount) 个候选、计入 \(metrics.reports.count) 份"
            + "  hasData=\(metrics.hasData)  overall=\(metrics.overallLinePercent.map { "\($0)" } ?? "nil")")
        XCTAssertEqual(metrics.scannedFileCount, 3, "三份报告都要被看到")
        XCTAssertTrue(metrics.reports.isEmpty, "分母为 0 的报告不得作为有效数据计入")
        XCTAssertFalse(metrics.hasData)
        XCTAssertNil(metrics.overallLinePercent, "无数据必须是 nil，不能是 0%")
        XCTAssertNil(metrics.overallBranchPercent)
        XCTAssertEqual(metrics.riskLevel, .none)
    }

}
