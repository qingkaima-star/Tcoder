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
        XCTAssertEqual(metrics.unreadableDirectoryCount, 0,
                       "一个目录都没挡住时这一格必须是 0（一句真话），不能留 nil 让人以为没统计")
    }

    /// 目录读不动时必须自己报名字（P7-C 余量）。以前枚举失败被 `try?` 吞成空数组，
    /// 于是"这个子树我们根本没看过"在界面上长成"该项目没有产出覆盖率报告"——
    /// 那是关于我们的事实，被写成了关于项目的结论。
    func testUnreadableDirectoryIsCountedNotSwallowed() async throws {
        try write("locked/lcov.info", "SF:a.ts\nLF:100\nLH:50\nend_of_record\n")
        let blocked = root.appendingPathComponent("locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
        // 收尾必须把权限还回来：还不回来 `tearDown` 就删不掉这棵夹具，
        // 残骸会喂给下一轮扫描当"真实数据"（本仓踩过两类：/tmp 夹具喂假绿、仓库内沙箱喂假红）。
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path) }

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        XCTAssertNotNil(metrics.unreadableDirectoryCount, "每次分析都要写下这一格")
        if metrics.unreadableDirectoryCount == 0 {
            throw XCTSkip("本机允许枚举 0o000 目录（例如以 root 跑测试），此时计数为 0 是正确行为")
        }
        XCTAssertGreaterThanOrEqual(metrics.unreadableDirectoryCount ?? -1, 1)
        XCTAssertFalse(metrics.hasData, "被挡住的那份报告不该被算成扫到了数据")

        let note = MissingDimensionReason.testingAbsence(coverage: metrics) ?? ""
        XCTAssertTrue(note.contains("个目录没能读取"), "扫描面不完整必须一起上屏：\(note)")
        XCTAssertTrue(note.hasPrefix("该项目没有产出覆盖率报告"),
                      "前半句仍是那句结论，后半句才补上我们没看完：\(note)")
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
