import XCTest
@testable import TcoderMonitor

/// WS-R #38：覆盖率报告必须自带「是哪生成的」，否则一份陈旧 lcov 能长期冒充新鲜数据进健康分。
///
/// 现场（总工实测，本仓库自己的产物）：`TcoderMonitor/coverage/lcov.info` 是 .gitignore
/// 挡着的本地文件，过期数小时、跨几十上百个提交，而 `CoverageReport` 既不携带也不展示
/// 生成时间——界面上没有任何一处说它是哪天的。与 #25 同族，只是这次对象是用户报告。
///
/// 两条红线也一起钉住：
/// ① 新字段必须 **Optional**（`ProjectReport` 经 `ProjectStore` 落盘，
///    给旧 JSON 加非 Optional 键会让整份报告解码失败并被 `try?` 吞成「没数据」）；
/// ② 报告陈旧只能「说出来」，不许「当作没有」——不许为了分数好看把时间隐藏掉。
final class HonestyP1CoverageFreshnessTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ws-r-cov-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - ① 生成时间来自文件本身

    func testAnalyzerReadsTheReportGenerationTimeFromFilesystem() async throws {
        let written = try writeLcov(to: "coverage/lcov.info")
        let stale = Date(timeIntervalSinceNow: -40 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: stale], ofItemAtPath: written.path)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: tempRoot, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)

        XCTAssertNotNil(report.generatedAt, "文件 mtime 是真实存在的证据，必须带出来")
        XCTAssertEqual(report.generatedAt?.timeIntervalSince1970 ?? 0,
                       stale.timeIntervalSince1970, accuracy: 2,
                       "生成时间必须就是那份文件的 mtime，不是本次分析时刻")
        XCTAssertTrue(report.generationText.contains("报告生成于"), report.generationText)
        XCTAssertTrue(report.generationText.contains(DateFormat.full.string(from: stale)),
                      "读数旁边要能看见具体日期：\(report.generationText)")
        print("【#38 现场】改前这一行不存在（只有口径与来源）；改后：\(metrics.generationSummaryText ?? "无")")
    }

    /// 与 #35 的分别要能说清：mtime 的分钟是文件系统记的，不是我们编的，所以照原样显示。
    func testGenerationTextKeepsTheFilesystemsOwnMinutePrecision() async throws {
        let written = try writeLcov(to: "coverage/lcov.info")
        // 取一个带非零分钟的时刻，确认没有像 #35 那样被抹成 0 点、也没被凑成整点。
        let stamp = Date(timeIntervalSince1970: 1_760_000_000)   // 2025-10-09 07:33 UTC
        try FileManager.default.setAttributes([.modificationDate: stamp], ofItemAtPath: written.path)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: tempRoot, options: .default)
        let text = try XCTUnwrap(metrics.reports.first?.generationText)

        XCTAssertTrue(text.contains(DateFormat.full.string(from: stamp)), text)
        XCTAssertFalse(text.contains("00:00"), "mtime 有真实分钟，不该被抹成日首：\(text)")
    }

    // MARK: - ② 拿不到时间必须明说，且不得当成新鲜

    func testMissingGenerationTimeSaysUnknownInsteadOfLookingFresh() {
        var report = CoverageReport(path: "/tmp/x/lcov.info", kind: .unit, toolName: "lcov",
                                    linesCovered: 100, linesTotal: 200,
                                    branchesCovered: 0, branchesTotal: nil,
                                    methodsCovered: 0, methodsTotal: 0)
        report.generatedAt = nil

        XCTAssertTrue(report.generationText.contains("未知生成时间"), report.generationText)
        XCTAssertFalse(report.generationText.contains("最新"), "拿不到时间就不许有任何新鲜措辞：\(report.generationText)")
        XCTAssertFalse(report.generationText.contains(":"))   // 未知时不该挤出时分
    }

    /// 多份报告时按**最旧**的那份说话，无时间的单独计数（失败面只许往大报）。
    func testSummaryNamesTheOldestReportAndCountsTheUndatedOnes() throws {
        let metrics = CoverageMetrics(reports: [
            report("a", generatedAt: Date(timeIntervalSinceNow: -60)),
            report("b", generatedAt: Date(timeIntervalSinceNow: -40 * 86_400)),
            report("c", generatedAt: nil),
        ])
        let summary = try XCTUnwrap(metrics.generationSummaryText)

        XCTAssertTrue(summary.contains("最旧报告生成于"), summary)
        XCTAssertTrue(summary.contains(DateFormat.full.string(from: Date(timeIntervalSinceNow: -40 * 86_400))),
                      "必须报最旧那份，不是最新那份：\(summary)")
        XCTAssertTrue(summary.contains("1 份无生成时间"), "没时间的要单独说出来：\(summary)")
        XCTAssertTrue(summary.contains("3 份"), "份数要说出来，免得读者以为是一个数：\(summary)")
    }

    func testNoReportsProduceNoGenerationClaim() {
        XCTAssertNil(CoverageMetrics(reports: []).generationSummaryText,
                     "没有报告时不编造一句生成时间")
    }

    // MARK: - 红线：新字段必须 Optional，旧 JSON 缺键仍要能解出来

    /// 手写一份**不含** `generatedAt` 的旧 JSON：解码必须成功且该字段为 nil。
    /// 非 Optional 会让整份 `CoverageMetrics` 解码失败，`ProjectStore` 的 `try?`
    /// 会把它静默吞成「没有覆盖率数据」——用户看到的是报告消失，而不是报错。
    func testLegacyCoverageJSONWithoutTheNewKeyStillDecodes() throws {
        let legacy = Data("""
        {"analyzedAt":600000000.0,"scannedFileCount":1,
         "reports":[{"path":"/tmp/old/lcov.info","kind":"单元测试","toolName":"lcov",
                     "linesCovered":10,"linesTotal":20,"branchesCovered":0,
                     "methodsCovered":0,"methodsTotal":0}]}
        """.utf8)

        let decoded = try JSONDecoder().decode(CoverageMetrics.self, from: legacy)
        XCTAssertEqual(decoded.reports.count, 1)
        XCTAssertNil(decoded.reports[0].generatedAt, "旧 JSON 里没这个键，必须解成 nil 而不是整份失败")
        XCTAssertEqual(decoded.overallLinePercent ?? 0, 50, accuracy: 0.01,
                       "旧报告的可计分内容不许因为新字段而丢失")
    }

    func testGenerationTimeSurvivesEncodingRoundTrip() throws {
        let stamp = Date(timeIntervalSince1970: 1_760_000_000)
        let metrics = CoverageMetrics(reports: [report("round", generatedAt: stamp)])
        let decoded = try JSONDecoder().decode(CoverageMetrics.self, from: try JSONEncoder().encode(metrics))
        XCTAssertEqual(decoded.reports.first?.generatedAt?.timeIntervalSince1970 ?? 0,
                       stamp.timeIntervalSince1970, accuracy: 1)
    }

    // MARK: - 取证：拿自扫分数说话前先看到它多旧
    //
    // `SelfScan*.swift` 是 WS-J 名下，我不动；这条用例只为把同一句证据打进全量日志。
    func testPrintWhatAgeTheLocalCoverageArtefactActuallyIs() async throws {
        // 仓库根按 `SelfScanHarness.repoRoot` 同样的方式推导（`#filePath` 往上两级），
        // 不写死绝对路径——工作树是会被人 `git worktree remove` 的。
        let moduleRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
        let metrics = try await CoverageAnalyzer().analyze(projectRoot: moduleRoot, options: .default)

        print("【#38 现场】\(moduleRoot.lastPathComponent) 覆盖率读数："
            + "\(metrics.overallLinePercent.map { String(format: "%.2f%%", $0) } ?? "无数据")"
            + " ｜ \(metrics.generationSummaryText ?? "无报告（本树没有本地覆盖率产物，评分里该维度缺席）")")
        XCTAssertTrue(metrics.reports.allSatisfy { $0.generationText.isEmpty == false },
                      "每一份报告都必须能生成一句时间描述（哪怕是未知）")
    }

    // MARK: - 夹具

    private func report(_ name: String, generatedAt: Date?) -> CoverageReport {
        var report = CoverageReport(path: "/tmp/\(name)/lcov.info", kind: .unit, toolName: "lcov",
                                    linesCovered: 10, linesTotal: 20,
                                    branchesCovered: 0, branchesTotal: nil,
                                    methodsCovered: 0, methodsTotal: 0)
        report.generatedAt = generatedAt
        return report
    }

    @discardableResult
    private func writeLcov(to relative: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("""
        SF:Sources/TcoderMonitor/App/AppState.swift
        LF:100
        LH:80
        end_of_record
        SF:Tests/TcoderMonitorTests/DummyTests.swift
        LF:100
        LH:95
        end_of_record
        """.utf8).write(to: url)
        return url
    }
}
