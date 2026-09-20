/// OWNER: WS-X3 TestSplit —— 自 CoverageProductionScopeTests.swift 拆出，口径本身：四类排除形状、加测试码不改生产覆盖率、无数据≠100%。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CoverageProductionScopeTests {

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

}
