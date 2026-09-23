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

    /// RD-25 改判：这个夹具**正是**"带文件粒度的 lcov + 只有汇总桶的 istanbul 摘要"混在一起扫。
    /// 旧期望 78% = (50+340)/(100+400) —— 两份报告的覆盖范围无从核对，相加得到的是伪精确数
    /// （台账 RD-25 点名的形状）。现在的判据：**只按可核对的那份给数，另一份分开留档并点名**。
    /// 断言里同时钉住"修前那个数"，防止有人把它当回归改回去。
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

        let result = try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root, options: .default)
        let metrics = result.metrics
        XCTAssertEqual(metrics.reports.count, 1, "只有带文件粒度、可核对的那份进总数")
        XCTAssertEqual(metrics.overallLinePercent ?? 0, 50, accuracy: 0.01, "真值 = lcov 那份 50/100")
        XCTAssertNil(metrics.overallBranchPercent, "汇总粒度那份的分支数不许再并进总分")
        XCTAssertEqual(result.merge.dropped.first?.reason, .aggregateOnlyCannotCrossCheck)
        XCTAssertTrue(result.merge.separateReadings.contains { $0.toolName == "istanbul / nyc" },
                      "被拒合并的那份读数要留着可查，不许当成「没扫到」")
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: [(50, 100), (340, 400)]), 78, accuracy: 0.01,
                       "修前读数就是这句：两份直接累加 = 390/500 = 78%")
        XCTAssertTrue(result.merge.statement.contains("总数未覆盖全部报告"), result.merge.statement)
    }

    /// 同一批源码、unit 与 integration 各报一个命中率、且**都没有逐行记录** ⇒
    /// 两份说的是同一批行还是不同行，报告本身没写。相加(132/200=66%)与取一份都不是联合覆盖。
    /// RD-25 的判据：按行能并就并（下面那条用例），不能并就**分开呈现、不给总数**。
    func testUnitAndIntegrationWithoutLineRecordsProduceNoFakeUnion() async throws {
        try write("coverage/unit/lcov.info", "SF:a.ts\nLF:100\nLH:78\nend_of_record\n")
        try write("coverage/integration/lcov.info", "SF:a.ts\nLF:100\nLH:54\nend_of_record\n")

        let result = try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root, options: .default)
        XCTAssertNil(result.metrics.overallLinePercent, "拿不出行集合就不许给联合覆盖率")
        XCTAssertEqual(result.merge.basis, .nothingMergeable)
        XCTAssertEqual(result.merge.conflictingFileCount, 1)
        XCTAssertEqual(result.merge.separateReadings.count, 2, "两份读数都要留着（分开呈现的数据源）")
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: [(78, 100), (54, 100)]), 66, accuracy: 0.01,
                       "修前读数：两份直接累加 = 132/200 = 66%")
    }

    /// 同一个夹具换成**带 `DA:` 逐行记录**的形状 ⇒ 联合覆盖率算得出来，且必须给数。
    /// unit 命中 1..78、integration 命中 25..100 ⇒ 并集 1..100 = **100/100**；
    /// 相加得到的是 (78+76)/200 = 77%（旧读数）。
    func testUnitAndIntegrationWithLineRecordsAreUnioned() async throws {
        var unit = "SF:a.ts\n", integration = "SF:a.ts\n"
        for line in 1...100 {
            unit += "DA:\(line),\(line <= 78 ? 1 : 0)\n"
            integration += "DA:\(line),\(line >= 25 ? 1 : 0)\n"
        }
        unit += "LF:100\nLH:78\nend_of_record\n"
        integration += "LF:100\nLH:76\nend_of_record\n"
        try write("coverage/unit/lcov.info", unit)
        try write("coverage/integration/lcov.info", integration)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.linesTotal, 100, "同一个文件的两份报告只算一次分母")
        XCTAssertEqual(report.linesCovered, 100, "命中集合求并：1..78 ∪ 25..100 = 全部 100 行")
        XCTAssertEqual(metrics.overallLinePercent ?? 0, 100, accuracy: 0.01)
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
        // 判据没变（**扫描面不完整必须一起上屏**），只是那句话现在由 §6.1 一个形状生产：
        // 口径从"另有 N 个目录没能读取"合并成"…N 个目录读不动（权限或已消失）"，
        // 两类截断（深度 / 40 份上限 / 读不动）不再各造一套说法。
        XCTAssertTrue(note.contains("读不动"), "扫描面不完整必须一起上屏（§6.1 那句现在真有读者）：\(note)")
        XCTAssertEqual(metrics.unexaminedDirectories, ["locked"],
                       "没看的目录要逐条给稳定坐标，一行摘要不算台账")
        XCTAssertFalse(metrics.absenceClaimIsSound, "有目录没看 ⇒ \"该项目没有报告\"这句不成立")
        // RD-55：这条以前钉的是 `hasPrefix("该项目没有产出覆盖率报告")` ——
        // 也就是**要求**页面上先印一句同一个测试对象刚刚判为不成立的结论，
        // 再补一句把它推翻的话。前半句收窄成"看得见的部分里"才是这句话的本意。
        XCTAssertTrue(note.hasPrefix("看得见的部分里没有发现覆盖率报告"),
                      "有目录没看 ⇒ 前半句必须自己收窄范围：\(note)")
        XCTAssertFalse(note.contains("该项目没有产出覆盖率报告"),
                       "不成立的结论照样上屏（两本账打脸）：\(note)")
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

        let result = try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root, options: .default)
        // RD-25：两份都只有汇总桶，彼此覆盖范围无从核对 ⇒ 解析照常、**总分不给**。
        XCTAssertNil(result.metrics.overallLinePercent)
        XCTAssertEqual(result.merge.basis, .nothingMergeable)
        let readings = result.merge.separateReadings
        XCTAssertEqual(Set(readings.map(\.toolName)), ["coverage.py", "clover"],
                       "五格式解析能力不许因为「不给总数」而退化，读数要一份不落地留着")
        let clover = try XCTUnwrap(readings.first { $0.toolName == "clover" })
        XCTAssertEqual(clover.linesCovered, 425)
        XCTAssertEqual(clover.linesTotal, 500)
        let python = try XCTUnwrap(readings.first { $0.toolName == "coverage.py" })
        XCTAssertEqual(python.linesCovered, 620)
        XCTAssertEqual(python.linesTotal, 1000)
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: [(620, 1000), (425, 500)]),
                       1045.0 / 1500.0 * 100, accuracy: 0.01, "修前读数：两份汇总直接累加相除 = 69.67%")
    }
}
