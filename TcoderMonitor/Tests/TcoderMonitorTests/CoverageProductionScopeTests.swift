import XCTest
@testable import TcoderMonitor

/// OWNER: WS-V #37（覆盖率分母口径）。文件名不以 Code/Git/Dependency/Log/Health/Performance
/// 开头，不与 WS-A/B/C 的 glob 相撞；`CoverageAnalyzerTests.swift` 是总工的，不碰。
///
/// 要修的账：覆盖率的**计分分母**原先把项目自己的测试代码一起算了进去。
/// 测试代码几乎必然被自己的测试覆盖到，于是它是一份高分样本——2026-09-20 实测：
/// 全口径 27047/42137 = 64.19%，其中 `Tests/` 占分母 43.83%（自身 86.38%）、
/// `Sources/` 只有 11080/23651 = 46.85%。
/// 决定性证据：`ee8e7b9`→`1e6319d` 只往 `Tests/` 加了 140 行测试、生产码一行没改，
/// 生产码 46.84%→46.85% 几乎不动，全口径却 64.00%→64.19% **自己涨了**。
/// 这个数字直接进健康评分，所以「不改善生产码也能涨分」的增长项必须被切断。
///
/// 口径集中在 `CoverageScope.isProductionSource`，本文件按 #29 的路子做：
/// 口径**可见**（打印每条规则的命中数）、分母**有正向断言**、
/// 规则本身有**双向**元测试（该排除的排除了，不该误伤的一个不许误伤）。
final class CoverageProductionScopeTests: XCTestCase {

    /// 仓库根（与 `SelfScanDogfoodTests` 同一算法）：本文件 → Tests → TcoderMonitor → 工作树根。
    /// 只给「真实证据的健康分对照」那条用例用。
    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    // MARK: - 夹具

    private func metrics(fromLCov records: [String]) async throws -> CoverageMetrics {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-scope-\(UUID().uuidString)", isDirectory: true)
        let captured = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try records.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)
        return try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
    }

    /// 一条 lcov 记录。`found`/`hit` 故意取整数便于手算。
    private func record(_ source: String, found: Int, hit: Int) -> String {
        "TN:\nSF:\(source)\nFNF:0\nFNH:0\nBRF:0\nBRH:0\nLF:\(found)\nLH:\(hit)\nend_of_record"
    }

    // MARK: - 口径本身：双向元测试

    /// 四条排除条件各自都要命中，且**不许误伤**生产码/普通源码。
    /// 只钉单边等于没修：规则写宽了会把生产码踢出分母（虚高），写窄了测试码还留着（依旧虚高）。
    func testScopePredicateExcludesTheFourShapesAndKeepsProductionOnes() {
        let excluded: [(String, String)] = [
            ("/repo/TcoderMonitor/Tests/TcoderMonitorTests/FooTests.swift", "含 /Tests/ 目录段"),
            ("/repo/.build/arm64/PackageTests.xctest/Contents/MacOS/Runner.swift", "含 PackageTests"),
            ("/repo/.build/checkouts/Gen/Model.swift", "含 /.build/"),
            ("/repo/TcoderMonitor/Sources/Services/LegacyCacheTests.swift", "文件名以 Tests.swift 结尾"),
            ("", "空路径不确定归属，宁缺毋滥"),
        ]
        for (path, why) in excluded {
            XCTAssertFalse(CoverageScope.isProductionSource(path: path), "\(path) 应被排除（\(why)）")
        }

        let included: [(String, String)] = [
            ("/repo/TcoderMonitor/Sources/TcoderMonitor/Models/CoverageMetrics.swift", "生产码绝对路径"),
            ("Sources/App.swift", "生产码相对路径"),
            ("src/a.ts", "前端源码"),
            ("/repo/TcoderMonitor/Sources/Services/TestRunner.swift", "文件名以 Test 开头但不是 Tests.swift"),
            ("/repo/TcoderMonitor/Sources/UI/TestFloorView.swift", "含 Test 字样的类型名"),
            ("/repo/packages/testing-utils/src/help.ts", "小写 testing 目录不算测试码"),
        ]
        for (path, why) in included {
            XCTAssertTrue(CoverageScope.isProductionSource(path: path), "\(path) 不该被排除（\(why)）")
        }
        // 规则条数也要钉住：有人悄悄加第五条排除项，会静默把生产码挪出分母。
        XCTAssertEqual([CoverageScope.testDirectoryMarker, CoverageScope.packageTestsMarker,
                        CoverageScope.buildDirectoryMarker, CoverageScope.swiftTestFileSuffix].count, 4,
                       "口径常量应当只有这四条；加条件必须连同本文件一起改")
    }

    // MARK: - ① 加测试码不得改变生产码覆盖率

    func testAddingTestCodeLeavesTheScoringPercentageUntouched() async throws {
        let production = [
            record("/repo/Sources/A.swift", found: 100, hit: 40),
            record("/repo/Sources/B.swift", found: 100, hit: 40),
        ]
        let before = try await metrics(fromLCov: production)
        let after = try await metrics(fromLCov: production + [
            record("/repo/Tests/A Tests.swift", found: 100, hit: 100),
            record("/repo/Tests/BTests.swift", found: 100, hit: 98),
        ])

        XCTAssertEqual(before.overallLinePercent ?? -1, 40, accuracy: 0.001,
                       "两份生产码各 40/100，计分口径应为 40%")
        XCTAssertEqual(after.overallLinePercent ?? -1, 40, accuracy: 0.001,
                       """
                       只往 Tests/ 加测试就把计分口径改了（\(before.overallLinePercent ?? -1) → \
                       \(after.overallLinePercent ?? -1)）——正是要切断的增长项。
                       """)
        XCTAssertGreaterThan((after.allSourcesLinePercent ?? 0) - (before.allSourcesLinePercent ?? 0), 20,
                             "全口径必须显著上涨（测试码几乎全覆盖）。它没涨说明次要口径被丢了，"
                             + "而不是口径修对了")

        print("【#37 增长项】生产码 \(before.overallLinePercent ?? -1)% → \(after.overallLinePercent ?? -1)%"
            + "（加测试码不变）；全口径 \(String(format: "%.2f", before.allSourcesLinePercent ?? -1))%"
            + " → \(String(format: "%.2f", after.allSourcesLinePercent ?? -1))%（自己涨）")
    }

    // MARK: - ② 全是测试码时不得当成有数据

    func testReportCoveringOnlyTestCodeIsAbsenceNotHundredPercent() async throws {
        let metrics = try await metrics(fromLCov: [
            record("/repo/Tests/AlphaTests.swift", found: 200, hit: 200),
            record("/repo/Tests/BetaTests.swift", found: 100, hit: 99),
        ])
        let report = try XCTUnwrap(metrics.reports.first, "报告本身要留着，全口径读数才有出处")
        XCTAssertEqual(report.linesTotal, 0, "生产码分母必须是 0，不能把测试码算进去")
        XCTAssertFalse(metrics.hasData,
                       "只有测试码被覆盖 = 没有可评分的覆盖率数据；算作有数据就是把 100% 端给用户")
        XCTAssertNil(metrics.overallLinePercent, "nil 而不是 0%，更不是 100%")
        XCTAssertFalse(HealthInputs(coverage: metrics).availableDimensions.contains(.testing),
                       "评分维度列表里不许出现「测试覆盖」")
        XCTAssertEqual(report.allLinesTotal, 300, "全量数字要留着：取证时还得能说清 64% 是怎么来的")
        XCTAssertEqual(report.allLinesCovered, 299)

        let score = WeightedHealthScorer().score(HealthInputs(coverage: metrics))
        XCTAssertFalse(score.components.contains { $0.name == HealthDimension.testing.rawValue },
                       "评分结果里出现了「测试覆盖」分量，等于给零生产码证据发了满分")
    }

    // MARK: - ③ 评分跟着生产码走（阈值一个没改）

    func testScoringComponentFollowsTheProductionCaliber() async throws {
        // 同一份生产码证据（20/100），一份掺进近乎满覆盖的测试码、一份不掺：
        // 两边的「测试覆盖」分量必须**相等**——这就是「不改善生产码也无法涨分」。
        let mixed = try await metrics(fromLCov: [
            record("/repo/Sources/Only.swift", found: 100, hit: 20),
            record("/repo/Tests/BigTests.swift", found: 900, hit: 890),
        ])
        let pure = try await metrics(fromLCov: [
            record("/repo/Sources/Only.swift", found: 100, hit: 20),
        ])
        let mixedScore = WeightedHealthScorer().score(HealthInputs(coverage: mixed))
        let pureScore = WeightedHealthScorer().score(HealthInputs(coverage: pure))
        let mixedTesting = try XCTUnwrap(mixedScore.components.first { $0.name == HealthDimension.testing.rawValue })
        let pureTesting = try XCTUnwrap(pureScore.components.first { $0.name == HealthDimension.testing.rawValue })

        XCTAssertEqual(mixedTesting.score, pureTesting.score,
                       "掺进 890/900 的测试码后「测试覆盖」分量还是变了，说明分母没切干净")
        XCTAssertEqual(mixed.overallLinePercent ?? -1, 20, accuracy: 0.001)
        XCTAssertGreaterThan(mixed.allSourcesLinePercent ?? 0, 90,
                             "全口径应当仍是虚高的那个数（约 91%），两个口径都要能读到才算口径可见")
        XCTAssertLessThan(mixedScore.overall, Int((mixed.allSourcesLinePercent ?? 100).rounded()),
                          "综合分竟然不低于虚高的全口径，说明评分读的还是老口径")
        print("【#37 评分】生产码 20% → 测试覆盖分量 \(pureTesting.score) 分；"
            + "掺测试码后全口径 \(String(format: "%.1f", mixed.allSourcesLinePercent ?? -1))% "
            + "仍是同一个 \(mixedTesting.score) 分，综合分 \(mixedScore.overall)")
    }

    // MARK: - ④ 风险档位跟着生产码走（阈值未动）

    func testRiskLevelDropsWhenTheInflatedPartIsRemoved() async throws {
        // 生产码 55/100（medium 档 40..<60），掺 45/45 测试码后全口径到 100/145≈69%（low 档）。
        let metrics = try await metrics(fromLCov: [
            record("/repo/Sources/Mid.swift", found: 100, hit: 55),
            record("/repo/Tests/MidTests.swift", found: 45, hit: 45),
        ])
        XCTAssertEqual(metrics.overallLinePercent ?? -1, 55, accuracy: 0.001)
        XCTAssertEqual(metrics.riskLevel, .medium, "档位必须由生产码 55% 决定，不是全口径 69% 的 .low")
        // 阈值表本身一个字节都没改：这里只验「同一个阈值表作用在哪个口径上」。
        XCTAssertEqual(CoverageMetrics(reports: [CoverageReport(
            path: "/r/lcov.info", kind: .combined, toolName: "lcov",
            linesCovered: 60, linesTotal: 100, branchesCovered: 0, branchesTotal: nil,
            methodsCovered: 0, methodsTotal: 0)]).riskLevel, .low,
            "60% 仍应落进 .low 档——阈值 60 没动")
    }

    // MARK: - ⑤ 没有文件粒度的格式不许假装区分过

    func testAggregateOnlyFormatsSaySoInsteadOfFakingASplit() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-agg-\(UUID().uuidString)", isDirectory: true)
        let captured = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        // istanbul 的 summary 只有 total 桶，没有源文件粒度。
        try #"{"total":{"lines":{"total":400,"covered":340,"skipped":0,"pct":85.0}}}"#
            .write(to: dir.appendingPathComponent("coverage/coverage-summary.json"),
                   atomically: true, encoding: .utf8)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertEqual(report.scopeGranularity, .aggregateOnly,
                       "只有汇总粒度的格式必须明说，否则它的 400 分母会被当成已经剔过测试码")
        XCTAssertFalse(metrics.scopeIsSeparated)
        XCTAssertEqual(report.linesTotal, report.allLinesTotal ?? -1,
                       "区分不了口径时两个口径必须相等，不许凭空造一个更小的生产码分母")
    }

    // MARK: - ⑥ 落盘兼容：新增字段一律 Optional

    /// `ProjectReport` 会经 `ProjectStore` 落盘。给旧 JSON 加非 Optional 键会让
    /// 整份报告解码失败（`ProjectStoreRoundTripTests` 第 ③ 组钉着这条）。
    func testOldPersistedCoverageJSONStillDecodesAfterTheNewFields() throws {
        let legacy = CoverageReport(
            path: "/old/lcov.info", kind: .unit, toolName: "lcov",
            linesCovered: 30, linesTotal: 100, branchesCovered: 4, branchesTotal: 8,
            methodsCovered: 0, methodsTotal: 0)
        let data = try JSONEncoder().encode(legacy)
        var object = (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        ["allLinesCovered", "allLinesTotal", "allBranchesCovered", "allBranchesTotal",
         "scopeGranularity"].forEach { object.removeValue(forKey: $0) }
        let stripped = try JSONSerialization.data(withJSONObject: object)

        let restored = try JSONDecoder().decode(CoverageReport.self, from: stripped)
        XCTAssertEqual(restored.linesCovered, 30)
        XCTAssertNil(restored.allLinesTotal, "旧数据没有全量字段就该是 nil，而不是解码失败")
        XCTAssertFalse(restored.isScopeSeparated)
    }

    // MARK: - ⑦ 分母守卫：扫描确实看到了测试码

    /// 口径生效的前提是「真的扫到了测试码记录」。一条都没有时，
    /// 「生产码 == 全口径」是空话而不是修好了。
    func testTheSplitActuallyFiredOnRealSizedFixtures() async throws {
        let records = [
            record("/repo/Sources/One.swift", found: 120, hit: 60),
            record("/repo/Sources/Two.swift", found: 80, hit: 30),
            record("/repo/Tests/OneTests.swift", found: 60, hit: 60),
            record("/repo/.build/Checkouts/Gen.swift", found: 20, hit: 20),
        ]
        let metrics = try await metrics(fromLCov: records)
        let report = try XCTUnwrap(metrics.reports.first)
        XCTAssertTrue(report.isScopeSeparated, "lcov 有 SF: 就必须走按文件区分的分支")
        XCTAssertEqual(report.linesTotal, 200, "生产码分母只许有 120 + 80")
        XCTAssertEqual(report.linesCovered, 90)
        XCTAssertEqual(report.allLinesTotal, 280, "全量分母要保住 4 条记录之和")
        XCTAssertEqual(report.allLinesCovered, 170)
        XCTAssertGreaterThan(report.allLinesTotal ?? 0, report.linesTotal,
                             "两个口径相等说明测试码根本没被排除，本文件的结论全部失效")
        print("【#37 口径】生产码 \(report.linesCovered)/\(report.linesTotal)"
            + " = \(String(format: "%.2f", report.linePercent))%；"
            + "全口径 \(report.allLinesCovered ?? 0)/\(report.allLinesTotal ?? 0)"
            + " = \(String(format: "%.2f", report.allLinePercent ?? -1))%（被排除的测试/派生分母 "
            + "\(report.allLinesTotal! - report.linesTotal) 行）")
    }

    // MARK: - ⑧ 真产物取证：改前 / 改后的覆盖率与健康分

    /// 默认跳过（不依赖各工作树各自的 `.build`）。开法与
    /// `SelfScanCoverageAgreementTests` 相同：
    /// ```
    /// ./scripts/locked_build.sh test --enable-code-coverage
    /// xcrun llvm-cov export -format=lcov \
    ///   -instr-profile .build/arm64-apple-macosx/debug/codecov/default.profdata \
    ///   .build/arm64-apple-macosx/debug/TcoderMonitorPackageTests.xctest/Contents/MacOS/TcoderMonitorPackageTests \
    ///   > /tmp/tcoder-self.lcov
    /// TCODER_SELF_LCOV=/tmp/tcoder-self.lcov ./scripts/locked_build.sh test \
    ///   --filter CoverageProductionScopeTests
    /// ```
    /// 同一条真 lcov 分别按「全口径」（改前 Tcoder 用的数）与「生产码口径」（改后）
    /// 喂给评分器，打印两者的百分比与「测试覆盖」分量得分——这是 #37 的验收读数。
    /// 不断言某个具体分数：`HealthCurves.coverage` 一个阈值都没改，
    /// 分数下降本身就是预期结果。
    func testRealSelfScanLCovReportsBothCalibers() async throws {
        let path = ProcessInfo.processInfo.environment["TCODER_SELF_LCOV"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "需显式给一份真 lcov：TCODER_SELF_LCOV=<路径>")
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-self-\(UUID().uuidString)", isDirectory: true)
        let captured = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("coverage/lcov.info"),
                       atomically: true, encoding: .utf8)

        let metrics = try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
        let report = try XCTUnwrap(metrics.reports.first, "真 lcov 没被解析出报告")
        let production = try XCTUnwrap(metrics.overallLinePercent, "生产码口径为 nil 说明分母被清空了")
        let full = try XCTUnwrap(metrics.allSourcesLinePercent)

        // 分母守卫：两个口径都要真量到东西，且生产码分母更小（否则排除没生效）。
        XCTAssertGreaterThan(report.linesTotal, 1_000, "生产码分母异常小：\(report.linesTotal)")
        XCTAssertGreaterThan(report.allLinesTotal ?? 0, report.linesTotal,
                             "全量分母没有大于生产码分母，测试码根本没被排除")
        XCTAssertGreaterThan(full, production,
                             "真 lcov 里全口径不高于生产码口径，说明这条口径在本仓库没起作用")

        // 同一份证据，改前/改后两种喂法。
        var asBefore = report
        asBefore.linesCovered = report.allLinesCovered ?? report.linesCovered
        asBefore.linesTotal = report.allLinesTotal ?? report.linesTotal
        asBefore.scopeGranularity = .aggregateOnly
        let scoreBefore = WeightedHealthScorer().score(
            HealthInputs(coverage: CoverageMetrics(reports: [asBefore])))
        let scoreAfter = WeightedHealthScorer().score(HealthInputs(coverage: metrics))
        let testingBefore = try XCTUnwrap(
            scoreBefore.components.first { $0.name == HealthDimension.testing.rawValue })
        let testingAfter = try XCTUnwrap(
            scoreAfter.components.first { $0.name == HealthDimension.testing.rawValue })

        print("【#37 真 lcov】改前（全口径）\(String(format: "%.2f", full))%"
            + " \(report.allLinesCovered ?? 0)/\(report.allLinesTotal ?? 0)"
            + " → 测试覆盖分量 \(testingBefore.score) 分")
        print("【#37 真 lcov】改后（生产码）\(String(format: "%.2f", production))%"
            + " \(report.linesCovered)/\(report.linesTotal)"
            + " → 测试覆盖分量 \(testingAfter.score) 分；被排除的测试/派生分母 "
            + "\((report.allLinesTotal ?? 0) - report.linesTotal) 行")
        XCTAssertLessThan(testingAfter.score, testingBefore.score,
                          "换了更严的口径而评分分量没下降，说明评分还在读全口径")
    }

    /// #37 真正要交的那个结论：**同一个仓库**，口径切换前后的健康总分各是多少。
    ///
    /// 为什么要单独一条：仓库里并没有提交的覆盖率报告，自扫的 `coverage.hasData`
    /// 本来是 false、`.testing` 维度从不参与自身评分——拿"总分 73 → 73"来交差是空话。
    /// 这里把真 lcov 接进同一套仓库证据（代码/Git/日志/依赖都扫真实仓库），
    /// 再分别按改前（全口径）与改后（生产码）评一次分，才叫"切换前后"。
    ///
    /// 刻意**不往仓库里放 `coverage/lcov.info`**：那会污染工作树、还可能被误提交。
    /// 覆盖率从临时目录读，其余五个分析器照 `SelfScanDogfoodTests` 的组法跑真实仓库根。
    func testRepoWideHealthScoreBeforeAndAfterTheCaliberSwitch() async throws {
        let path = ProcessInfo.processInfo.environment["TCODER_SELF_LCOV"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "需显式给一份真 lcov：TCODER_SELF_LCOV=<路径>")

        // 覆盖率：从临时目录读真 lcov。
        let covDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-health-\(UUID().uuidString)", isDirectory: true)
        let captured = covDir
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        try FileManager.default.createDirectory(
            at: covDir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
            .write(to: covDir.appendingPathComponent("coverage/lcov.info"),
                   atomically: true, encoding: .utf8)
        let coverage = try await CoverageAnalyzer()
            .analyze(projectRoot: covDir, options: .default)

        // 其余五类证据：真实仓库根（与自扫同一口径）。
        let root = Self.repoRoot
        let code = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
        let git = try await ShellGitAnalyzer().analyze(repositoryURL: root)
        let logs = try await FileLogAnalyzer()
            .analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
        let deps = try await ManifestDependencyAnalyzer()
            .analyze(projectRoot: root, allowNetwork: false)

        var asBefore = coverage.reports[0]
        asBefore.linesCovered = asBefore.allLinesCovered ?? asBefore.linesCovered
        asBefore.linesTotal = asBefore.allLinesTotal ?? asBefore.linesTotal
        asBefore.scopeGranularity = .aggregateOnly

        let scorer = WeightedHealthScorer()
        let inputs = HealthInputs(code: code, git: git, logs: logs, dependencies: deps,
                                  coverage: coverage)
        let after = scorer.score(inputs)
        let before = scorer.score(HealthInputs(code: code, git: git, logs: logs,
                                               dependencies: deps,
                                               coverage: CoverageMetrics(reports: [asBefore])))
        let testingAfter = try XCTUnwrap(after.components.first { $0.name == HealthDimension.testing.rawValue })
        let testingBefore = try XCTUnwrap(before.components.first { $0.name == HealthDimension.testing.rawValue })

        XCTAssertGreaterThan(coverage.reports.first?.linesTotal ?? 0, 1_000, "生产码分母异常小")
        XCTAssertLessThan(after.overall, before.overall,
                          "换了更严的口径而总分没降，说明评分仍在读全口径")
        XCTAssertLessThan(testingAfter.score, testingBefore.score)
        // 分母守卫：其余维度必须两边完全同源，差值才只可能来自口径。
        XCTAssertEqual(after.components.filter { $0.name != HealthDimension.testing.rawValue }.map(\.score),
                       before.components.filter { $0.name != HealthDimension.testing.rawValue }.map(\.score),
                       "非覆盖率维度的分数也变了，说明两边喂的不是同一份仓库证据")

        print("【#37 总分】同一仓库真实证据：改前（全口径 "
            + String(format: "%.2f", coverage.allSourcesLinePercent ?? -1) + "%）总分 \(before.overall)"
            + "、测试覆盖分量 \(testingBefore.score)；改后（生产码 "
            + String(format: "%.2f", coverage.overallLinePercent ?? -1) + "%）总分 \(after.overall)"
            + "、测试覆盖分量 \(testingAfter.score)")
    }
}
