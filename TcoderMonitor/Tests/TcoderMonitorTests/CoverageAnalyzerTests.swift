import XCTest
@testable import TcoderMonitor

/// Chief-engineer tests for the coverage reader (requirement #8 of the spec).
/// Each case writes its own throwaway fixture so the suite never depends on
/// repository state or on another workstream's files.
final class CoverageAnalyzerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ relative: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    func testLcovTotalsAcrossRecords() async throws {
        try write("coverage/lcov.info", """
        TN:
        SF:src/a.java
        FNF:12
        FNH:10
        BRF:40
        BRH:28
        LF:200
        LH:156
        end_of_record
        SF:src/b.swift
        LF:100
        LH:72
        BRF:20
        BRH:12
        end_of_record
        """)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertTrue(metrics.hasData)
        XCTAssertEqual(metrics.reports.count, 1)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.toolName, "lcov")
        XCTAssertEqual(report.linesCovered, 228)
        XCTAssertEqual(report.linesTotal, 300)
        XCTAssertEqual(report.branchesTotal, 60)
        XCTAssertEqual(metrics.overallLinePercent ?? 0, 76, accuracy: 0.01)
    }

    func testJaCoCoUsesReportLevelCountersOnly() async throws {
        // The per-class counter appears first; only the trailing report-level
        // counters may be used, otherwise coverage would be double counted.
        try write("server/target/site/jacoco/jacoco.xml", """
        <?xml version="1.0" encoding="UTF-8"?>
        <report>
          <package name="com/example">
            <class name="com/example/A"><counter type="LINE" missed="10" covered="5"/></class>
          </package>
          <counter type="INSTRUCTION" missed="200" covered="800"/>
          <counter type="BRANCH" missed="60" covered="40"/>
          <counter type="LINE" missed="300" covered="700"/>
          <counter type="METHOD" missed="20" covered="80"/>
        </report>
        """)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.toolName, "JaCoCo")
        XCTAssertEqual(report.linesTotal, 1000, "must not add the per-class counter")
        XCTAssertEqual(report.linesCovered, 700)
        XCTAssertEqual(report.branchesTotal, 100)
        XCTAssertEqual(metrics.overallLinePercent ?? 0, 70, accuracy: 0.01)
    }

    func testIstanbulSummaryAndMixedTools() async throws {
        try write("web/coverage/coverage-summary.json", """
        {"total":{
          "lines":{"total":400,"covered":340,"skipped":0,"pct":85.0},
          "branches":{"total":120,"covered":90,"pct":75.0},
          "functions":{"total":60,"covered":50,"pct":83.3},
          "statements":{"total":420,"covered":350,"pct":83.3}
        }}
        """)
        try write("coverage/lcov.info", """
        SF:src/a.ts
        LF:100
        LH:50
        end_of_record
        """)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertEqual(metrics.reports.count, 2)
        // 390 covered of 500 lines across both tools.
        XCTAssertEqual(metrics.overallLinePercent ?? 0, 78, accuracy: 0.01)
        XCTAssertNotNil(metrics.overallBranchPercent)
    }

    func testUnitAndIntegrationKindsAreSeparated() async throws {
        try write("coverage/unit/lcov.info", "SF:a.ts\nLF:100\nLH:78\nend_of_record\n")
        try write("coverage/integration/lcov.info", "SF:a.ts\nLF:100\nLH:54\nend_of_record\n")

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertEqual(metrics.unit?.linePercent ?? 0, 78, accuracy: 0.01)
        XCTAssertEqual(metrics.integration?.linePercent ?? 0, 54, accuracy: 0.01)
    }

    func testMissingReportsYieldNoDataRatherThanZero() async throws {
        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertFalse(metrics.hasData)
        XCTAssertNil(metrics.overallLinePercent)
        XCTAssertEqual(metrics.riskLevel, .none)
    }

    /// Third-party coverage is not our project's coverage, but `build/` and
    /// `target/` must be traversed — that is where Gradle and Maven put the reports.
    func testExcludesThirdPartyButIncludesGeneratedReportDirs() async throws {
        try write("node_modules/pkg/coverage/lcov.info", "SF:x\nLF:100\nLH:10\nend_of_record\n")
        try write("build/reports/jacoco/test/jacocoTestReport.xml", """
        <report><counter type="LINE" missed="40" covered="60"/></report>
        """)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertEqual(metrics.reports.count, 1)
        XCTAssertEqual(metrics.reports.first?.toolName, "JaCoCo")
        XCTAssertEqual(metrics.overallLinePercent ?? 0, 60, accuracy: 0.01)
    }

    func testCoveragePyAndCloverFormats() async throws {
        try write("coverage.xml", """
        <?xml version="1.0"?>
        <coverage line-rate="0.62" branch-rate="0.4" lines-covered="620" lines-valid="1000"
                  branches-covered="80" branches-valid="200" version="7.4">
          <packages></packages>
        </coverage>
        """)
        try write("clover.xml", """
        <?xml version="1.0"?>
        <coverage>
          <project>
            <metrics files="12" loc="900" ncloc="700" classes="0"/>
            <metrics statements="500" coveredstatements="425" conditionals="100" coveredconditionals="70"/>
          </project>
        </coverage>
        """)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertEqual(metrics.reports.count, 2)
        let tools = Set(metrics.reports.map(\.toolName))
        XCTAssertEqual(tools, ["coverage.py", "clover"])
        let clover = try XCTUnwrap(metrics.reports.first { $0.toolName == "clover" })
        XCTAssertEqual(clover.linesCovered, 425)
        XCTAssertEqual(clover.linesTotal, 500)
    }
}
