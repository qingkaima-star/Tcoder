import XCTest
@testable import TcoderMonitor

/// OWNER: WS-J 自食其果。守的是 `Services/Coverage/CoverageAnalyzer.swift`
/// —— 全仓库唯一既不属 WS-A/B/C 任何 glob、也不在冻结区里的 Services 文件，
/// 所以自扫清单点名它时，只有 WS-J 能动。
///
/// 两组断言：
/// 1. **行为钉**：istanbul 解析器的每条分支语义（尤其是"lines 为 0 时不回退到
///    statements"这种一眼看不出来的口径），重构必须逐条保持。
/// 2. **复杂度棘轮**：用 Tcoder 自己的 `ComplexityEngine` 量这个函数，
///    只许越改越简单。阈值写死成字面量，抬高产品阈值不会让这里变松。
final class SelfScanCoverageRegressionTests: XCTestCase {

    /// 产品侧 `highFunctionComplexity` 的字面量副本：低于它才算摘掉[高]风险帽子。
    private static let complexityRatchet = 21

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-wsj-cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// istanbul 的产物就落在 `coverage/`，而 `ScanOptions.defaultSkipDirectories`
    /// 恰好会跳过这个名字——分析器专门为此开了小灶，这里要沿着真实路径走。
    private func analyzeIstanbul(_ json: String) async throws -> CoverageMetrics {
        let dir = root.appendingPathComponent("coverage", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try json.write(to: dir.appendingPathComponent("coverage-summary.json"),
                       atomically: true, encoding: .utf8)
        return try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
    }

    // MARK: - 行为钉

    func testIstanbulLinesBucketIsUsedAndAbsentBucketsStayNil() async throws {
        let metrics = try await analyzeIstanbul("""
        {"total":{"lines":{"total":100,"covered":61,"pct":61}}}
        """)
        guard let report = metrics.reports.first else {
            return XCTFail("lines 有数据时必须产出报告")
        }
        XCTAssertEqual(report.linesTotal, 100)
        XCTAssertEqual(report.linesCovered, 61)
        XCTAssertEqual(report.toolName, "istanbul / nyc")
        XCTAssertEqual(report.branchesCovered, 0)
        XCTAssertNil(report.branchesTotal, "没有 branches 桶时必须是 nil，不能谎报 0/0")
        XCTAssertEqual(report.methodsTotal, 0)
    }

    func testIstanbulFallsBackToStatementsOnlyWhenLinesMissing() async throws {
        let metrics = try await analyzeIstanbul("""
        {"total":{"statements":{"total":420,"covered":350,"pct":83.3}}}
        """)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.linesTotal, 420, "lines 缺失时退回 statements")
        XCTAssertEqual(report.linesCovered, 350)
    }

    /// 这条是重构最容易悄悄改掉的地方：lines **存在但为 0** 时不回退，
    /// 直接判 no-data。原实现就是 `metric("lines") ?? metric("statements")`
    /// 之后再 `guard resolved.total > 0`，两级判断不能合并。
    func testIstanbulDoesNotFallBackWhenLinesBucketIsPresentButZero() async throws {
        let metrics = try await analyzeIstanbul("""
        {"total":{"lines":{"total":0,"covered":0,"pct":0},
                  "statements":{"total":420,"covered":350,"pct":83.3}}}
        """)
        XCTAssertFalse(metrics.hasData,
                       "lines 桶存在且为 0 时必须判 no-data，偷偷用 statements 会虚报覆盖率")
    }

    func testIstanbulKeepsZeroTotalBranchesAsNil() async throws {
        let metrics = try await analyzeIstanbul("""
        {"total":{"lines":{"total":80,"covered":40},
                  "branches":{"total":0,"covered":0},
                  "functions":{"total":12,"covered":9}}}
        """)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.linesTotal, 80)
        XCTAssertEqual(report.branchesCovered, 0)
        XCTAssertNil(report.branchesTotal, "分支总数 0 要报 nil，别让它显示成 0/0 覆盖")
        XCTAssertEqual(report.methodsCovered, 9)
        XCTAssertEqual(report.methodsTotal, 12)
    }

    /// `pct` 字段被原实现算了出来却从没进过 `CoverageReport`
    /// （百分比是 `linePercent` 自己派生的）。缺 pct 也不该影响结果。
    func testIstanbulDerivesResultsWithoutPctField() async throws {
        let metrics = try await analyzeIstanbul("""
        {"total":{"lines":{"total":200,"covered":150}}}
        """)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.linePercent, 75, accuracy: 0.001)
    }

    // MARK: - 复杂度棘轮（用 Tcoder 量自己）

    func testIstanbulParserComplexityStaysOffTheHighRiskList() async throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/Services/Coverage/CoverageAnalyzer.swift")
        let files = await SourceTreeScanner(options: .default).scan(root: url.deletingLastPathComponent()).files
        let target = try XCTUnwrap(
            files.first { $0.url.lastPathComponent == "CoverageAnalyzer.swift" },
            "分析器必须扫到被测文件，否则这条棘轮是空跑")
        let measured = ComplexityEngine.functions(in: target)
        let parser = measured.first { $0.name.contains("parseIstanbulSummary") }
        let candidate = try XCTUnwrap(parser, "复杂度引擎认不出 parseIstanbulSummary，棘轮失效")

        XCTAssertLessThan(candidate.complexity, Self.complexityRatchet,
                          "parseIstanbulSummary 的 CC 涨回了 \(candidate.complexity)（≥\(Self.complexityRatchet) 会被工具自己判[高]风险）")
        print("【WS-J 棘轮】parseIstanbulSummary CC=\(candidate.complexity)（门限 \(Self.complexityRatchet)）、\(candidate.lineCount) 行")
    }
}
