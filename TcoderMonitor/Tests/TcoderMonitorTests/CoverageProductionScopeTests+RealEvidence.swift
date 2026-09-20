/// OWNER: WS-X3 TestSplit —— 自 CoverageProductionScopeTests.swift 拆出，落盘兼容、分母非零、真 lcov 与改前改后总分对照。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CoverageProductionScopeTests {

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
    ///
    /// #39：输入形状不具备证明力时先 skip（原因里带两个口径的数字），
    /// 而不是把"这份 lcov 只含 Sources"报成实现坏了。
    func testRealSelfScanLCovReportsBothCalibers() async throws {
        let path = ProcessInfo.processInfo.environment["TCODER_SELF_LCOV"] ?? ""
        try XCTSkipUnless(!path.isEmpty, "需显式给一份真 lcov：TCODER_SELF_LCOV=<路径>")
        let text = try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8)
        let metrics = try await metricsWritingLCov(text, labeled: path)
        let report = try XCTUnwrap(metrics.reports.first, "真 lcov 没被解析出报告：\(path)")
        let evidence = try evidence(from: metrics, input: path)

        // 分母守卫：生产码分母必须真有真实规模。太小 = 指错文件，这是真错，不 skip。
        XCTAssertGreaterThan(evidence.productionDenominator, 1_000,
                             "生产码分母异常小：\(evidence.productionDenominator)（\(path)）")
        // 只有「这份输入压根没有测试码记录」才算无证明力 -> skip，并把数字摊开。
        try XCTSkipUnless(evidence.canProveGap, evidence.skipReason)
        XCTAssertGreaterThan(evidence.fullPercent, evidence.productionPercent,
                             "有被排除的记录却两个口径相等，说明排除没真的作用到分母上：\(path)")

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

        print("【#37 真 lcov】输入 \(path)")
        print("【#37 真 lcov】改前（全口径）\(String(format: "%.2f", evidence.fullPercent))%"
            + " \(report.allLinesCovered ?? 0)/\(report.allLinesTotal ?? 0)"
            + " → 测试覆盖分量 \(testingBefore.score) 分")
        print("【#37 真 lcov】改后（生产码）\(String(format: "%.2f", evidence.productionPercent))%"
            + " \(report.linesCovered)/\(report.linesTotal)"
            + " → 测试覆盖分量 \(testingAfter.score) 分；被排除的测试/派生分母 "
            + "\(evidence.excludedLines) 行")
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
        let coverage = try await metricsWritingLCov(
            try String(contentsOf: URL(fileURLWithPath: path), encoding: .utf8), labeled: path)
        let evidence = try evidence(from: coverage, input: path)
        XCTAssertGreaterThan(evidence.productionDenominator, 1_000,
                             "生产码分母异常小：\(evidence.productionDenominator)（\(path)）")
        // #39：先判证明力，再花真实仓库扫描的代价——无证明力的输入不该跑完四个分析器
        // 才 skip，也不该在"总分必须下降"上报红。
        try XCTSkipUnless(evidence.canProveGap, evidence.skipReason)

        // 其余四类证据：真实仓库根（与自扫同一口径）。
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
        let after = scorer.score(HealthInputs(code: code, git: git, logs: logs,
                                              dependencies: deps, coverage: coverage))
        let before = scorer.score(HealthInputs(code: code, git: git, logs: logs,
                                               dependencies: deps,
                                               coverage: CoverageMetrics(reports: [asBefore])))
        let testingAfter = try XCTUnwrap(after.components.first { $0.name == HealthDimension.testing.rawValue })
        let testingBefore = try XCTUnwrap(before.components.first { $0.name == HealthDimension.testing.rawValue })

        XCTAssertLessThan(after.overall, before.overall,
                          "换了更严的口径而总分没降，说明评分仍在读全口径")
        XCTAssertLessThan(testingAfter.score, testingBefore.score)
        // 分母守卫：其余维度必须两边完全同源，差值才只可能来自口径。
        XCTAssertEqual(after.components.filter { $0.name != HealthDimension.testing.rawValue }.map(\.score),
                       before.components.filter { $0.name != HealthDimension.testing.rawValue }.map(\.score),
                       "非覆盖率维度的分数也变了，说明两边喂的不是同一份仓库证据")

        print("【#37 总分】输入 \(path)，排除分母 \(evidence.excludedLines) 行")
        print("【#37 总分】同一仓库真实证据：改前（全口径 "
            + String(format: "%.2f", evidence.fullPercent) + "%）总分 \(before.overall)"
            + "、测试覆盖分量 \(testingBefore.score)；改后（生产码 "
            + String(format: "%.2f", evidence.productionPercent) + "%）总分 \(after.overall)"
            + "、测试覆盖分量 \(testingAfter.score)")
    }

    /// 不依赖任何外部文件：合成两份形状不同的 lcov，验证 `CaliberEvidence`
    /// 这个「有没有证明力」的判据本身是对的两边——含测试码的必须
    /// `canProveGap == true` 且排除行数 == 手算值；只含 Sources 的必须
    /// `canProveGap == false`（真产物用例就该对它 skip，而不是报红）。
    /// 少了这条，skip 分支就是一次没人跑过的写死出口：哪天它退化成"永远 skip"，
    /// 上面两条真产物用例会静默变成永久绿。
    func testProofPowerJudgementHoldsBothWays() async throws {
        // 有证明力：生产码 200 行（命中 80）+ 测试码 100 行（命中 95）+ .build 副本 50 行（命中 50）。
        let mixed = try await metrics(fromLCov: [
            record("/repo/Sources/A.swift", found: 200, hit: 80),
            record("/repo/Tests/ATests.swift", found: 100, hit: 95),
            record("/repo/.build/checkouts/Gen.swift", found: 50, hit: 50),
        ])
        let mixedEvidence = try evidence(from: mixed, input: "合成：含 Tests 与 .build")
        XCTAssertEqual(mixedEvidence.excludedLines, 150, "被排除的分母必须恰好是 100 + 50")
        XCTAssertEqual(mixedEvidence.productionDenominator, 200)
        XCTAssertEqual(mixedEvidence.fullDenominator, 350)
        XCTAssertTrue(mixedEvidence.canProveGap,
                      "这份输入明明有口径差却判成无证明力，等于把真产物用例变成永久 skip")
        XCTAssertEqual(mixedEvidence.productionPercent, 40, accuracy: 0.001, "80/200")
        XCTAssertEqual(mixedEvidence.fullPercent, 64.2857, accuracy: 0.001, "225/350")
        XCTAssertNotEqual(mixedEvidence.productionPercent, mixedEvidence.fullPercent)

        // 无证明力：仓库本地那种「只导 target 源码」的报告，形状完全合法。
        let productionOnly = try await metrics(fromLCov: [
            record("/repo/Sources/A.swift", found: 200, hit: 80),
            record("/repo/Sources/B.swift", found: 100, hit: 60),
        ])
        let weak = try evidence(from: productionOnly, input: "合成：只含 Sources")
        XCTAssertEqual(weak.excludedLines, 0)
        XCTAssertFalse(weak.canProveGap,
                       "没有测试码记录却判成有证明力，真产物用例就会在合法输入上报红")
        XCTAssertEqual(weak.productionPercent, weak.fullPercent, accuracy: 0.0001)
        XCTAssertTrue(weak.skipReason.contains("排除分母 0 行"),
                      "skip 原因必须讲清为什么证不了：\(weak.skipReason)")
        XCTAssertTrue(weak.skipReason.contains("46.67") && weak.skipReason.contains("300"),
                      "skip 原因要带实际数字（140/300 = 46.67%，两个口径都是 300 分母）：\(weak.skipReason)")
        print("【#39 证明力】含 Tests 的输入排除 \(mixedEvidence.excludedLines) 行 → 可证；"
            + "只含 Sources 的输入排除 0 行 → 判无证明力")
        print("【#39 skip 原因样例】\(weak.skipReason)")
    }

}
