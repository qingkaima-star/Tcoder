import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X3 TestSplit —— **Tests 自己的规模与复杂度闸门**。
///
/// 工具自扫的「巨大文件待办单」（`SelfScanDogfoodTests`）口径是 400 行，但 `ceiling = 0`
/// 只钉住 >800 行那一条，且它只报数不判失败。本轮收官真修对 Tests 的要求是三条一起达标，
/// 三条的尺子全部**引用产品侧既有口径**，本文件一个新数字都不造：
///   * `FileSystemCodeAnalyzer.mediumFileLines` = 400 行 —— 待办单用的同一口径
///   * `FileSystemCodeAnalyzer.longFunctionThreshold` = 50 行 —— 「超长函数」同一口径
///   * `SelfScanHarnessCase.complexFunctionBar` = 16 —— 「高圈复杂度」同一口径
///
/// 函数边界与圈复杂度直接走 `ComplexityEngine`（自扫报告「圈复杂度热点」就是它数的），
/// 文件行数走 `SelfScanHarnessCase.wcStyleLineCount`（`wc -l` 口径，与只减不增棘轮同一把尺子）。
/// 自己另写一份切分逻辑必然与产品侧漂移 —— 那等于给同一件事配两把尺子。
///
/// 扫描面只到 `Tests/TcoderMonitorTests/**`：Sources 的规模债是 WS-X1 的账，不在这条门里。
final class X3TestSizeAuditTests: SelfScanHarnessCase {

    private static let fileLineBar = FileSystemCodeAnalyzer.mediumFileLines
    private static let functionLineBar = FileSystemCodeAnalyzer.longFunctionThreshold

    private struct Offender {
        var file: String
        var function: String
        var lines: Int
        var complexity: Int
    }

    private struct Audit {
        var fileLines: [(name: String, lines: Int)] = []
        var offenders: [Offender] = []
        var functions: Int = 0
    }

    /// 六个判据共用一次全仓走树（`SourceTreeScanner` 是产品侧扫描器，扫一次要几秒）。
    private static let auditStore = AuditCache()

    private actor AuditCache {
        private var cached: Audit?
        func value(orMake make: @Sendable () async throws -> Audit) async rethrows -> Audit {
            if let cached { return cached }
            let fresh = try await make()
            cached = fresh
            return fresh
        }
    }

    private func audit() async throws -> Audit {
        try await Self.auditStore.value {
            let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
            var result = Audit()
            for file in files where file.url.path.contains("/Tests/TcoderMonitorTests/")
                && file.url.pathExtension == "swift" {
                let name = file.url.lastPathComponent
                let text = try String(contentsOf: file.url, encoding: .utf8)
                result.fileLines.append((name, Self.wcStyleLineCount(text)))
                let functions = ComplexityEngine.functions(in: file)
                result.functions += functions.count
                for function in functions {
                    guard function.lineCount > Self.functionLineBar
                        || function.complexity >= Self.complexFunctionBar else { continue }
                    result.offenders.append(Offender(file: name, function: function.name,
                                                     lines: function.lineCount,
                                                     complexity: function.complexity))
                }
            }
            return result
        }
    }

    private static func roster(_ offenders: [Offender]) -> String {
        offenders.sorted { $0.file != $1.file ? $0.file < $1.file : $0.lines > $1.lines }
            .map { "  \($0.file):\($0.function) \($0.lines) 行 CC=\($0.complexity)" }
            .joined(separator: "\n")
    }

    // MARK: - 判据

    /// **剩余超长函数的点名清单**（WS-X3 本轮把 Tests 的 22 个 >400 行文件拆完、
    /// 并把所有 CC ≥16 的函数降到 16 以下之后，还欠这些函数：它们的体量大都是
    /// 「一条断言一块」的用例本体或字符串型夹具，拆法要逐条想清楚，不能为了数字砍断言）。
    ///
    /// 这不是把 50 行的口径放宽——口径仍是 `longFunctionThreshold`，这里钉的是**现状**：
    /// 清单里的人被拆掉之后必须**从清单里划掉**，新增一个长函数则当场变红。
    /// 与 `SelfScanDogfoodTests` 的 `ceiling = 0` 同一种只减不增写法。
    private static let longFunctionWorkList: Set<String> = [
        "CodeAnalyzerScanTests+ComplexityAndFunctions.swift:testFunctionIdentificationAcrossPythonGoAndJavaScriptClosure",
        "CodeAnalyzerTests+AnalyzeScale.swift:testAnalyzeFixtureDirectorySatisfiesAllInvariants",
        "CodeAnalyzerTests+AnalyzeScale.swift:testAnalyzeRealRepositoryKeepsInvariants",
        "CodeAnalyzerTests+LanguagesAndDuplication.swift:testDuplicationDetectedAcrossNearlyIdenticalFiles",
        "CoverageProductionScopeTests+RealEvidence.swift:testRepoWideHealthScoreBeforeAndAfterTheCaliberSwitch",
        "DependencyNetworkLiveTests.swift:testOnlineRegistryLookupReturnsRealLatestVersionsForPackagesMissingFromSnapshot",
        "DependencyNetworkTimeoutTests.swift:testHardTimeoutAbortsAtBudgetInsteadOfHanging",
        "DesignTokenCacheGuardTests+ScannerMeta.swift:test_scannersCatchThePreChangeShapes",
        "GitTimeSemanticsTests.swift:testRealRepositoryBucketsMatchGitGroundTruth",
        "LogAggregationTests.swift:testAggregateSumsLinesCountsAndWindow",
        "LogFixtureClusterTests.swift:testClusterRealJavaStackAndCrashLog",
        "ManifestLabCodeMetricsTests.swift:testCodeMetricsOnKnownMarkersHugeFilesAndClones",
        // 总工 00:53 从 main 逐字取回的既有计时用例（WS-X3 机械拆分时掉了，比对用例名抓到）。
        // 69 行的体量全是「一次测量一步」的顺序代码，切碎会让计时窗口被函数调用污染；挂账不隐藏。
        "PerfMainThreadBudgetTests.swift:testHeartbeatSplitIsMeasuredNotGuessed",
        "ManifestLabCoverageTests.swift:testCoverageReportsMatchHandWrittenNumbers",
        "ManifestLabDependencyTests.swift:testManifestLabDependencyCountsVersionsAndScopes",
        "ManifestLabLogAndGitTests.swift:testLogCountsClustersAndCrashAnchorsMatchLedger",
        "ManifestLabLogAndGitTests.swift:testGitInsightsOnRealMultiAuthorHistory",
        "ManifestLabTree+CodeAndCoverage.swift:writeCoverageReports",
        "ManifestLabTree+Manifests.swift:writeManifestsMaven",
        "ManifestLabTree+Manifests.swift:writeManifestsNpm",
        "ManifestLabTree+Manifests.swift:writeManifestsSwiftPM",
        "ManifestLabTree+Manifests.swift:writeManifestsGradle",
        "ManifestLabTree+OtherManifests.swift:writeManifestsGoAndRust",
        "ManifestLabTree+OtherManifests.swift:writeManifestsPythonRubyAndDotNet",
        "ManifestLabTree+SourceMaterial.swift:orderOrchestrator",
        "ManifestLabTree+SourceMaterial.swift:userService",
        "ManifestLabTree.swift:makeGitRepository",
        "PerfMainThreadBudgetTests.swift:testPersistenceMainThreadCostIsMeasuredNotGuessed",
        "PerformanceLiveSampleTests.swift:testLiveSamplerProducesActivityMonitorComparableNumbers",
        "ProjectStoreRoundTripTests.swift:testWrittenRegistryReportAndHistoryReadBackEquivalent",
        "SelfScanConventionGates.swift:testKnownSelfScanDefectsArePinned",
        "SelfScanCoverageAgreementTests.swift:testAnalyzerMatchesLlvmCovExportedLcov",
        "SelfScanDogfoodTests.swift:testGitSelfReportMatchesGitGroundTruth",
        "SelfScanHugeFileMechanismTests.swift:testSyntheticFileOverTheBarIsSeenWhileUnderBarIsNot",
        "ShellBorderlessTests+SurfaceAndScanner.swift:test_symbolAndSpacingScannersCatchSyntheticViolations",
        "SourceFileReachabilityTests+EvidenceRoster.swift:testCollisionNamesAreNotAcceptedAsEvidence",
    ]

    func testTestsPopulationStaysWithinAllThreeBars() async throws {
        let result = try await audit()

        // 分母守卫：扫不到东西 / 一个函数都没认出来，判据就成了永真绿——先在这里红。
        XCTAssertGreaterThanOrEqual(result.fileLines.count, 70,
                                    "Tests 目录只扫到 \(result.fileLines.count) 个 .swift 文件，扫描面退化了")
        XCTAssertGreaterThanOrEqual(result.functions, 900,
                                    "Tests 里只认出 \(result.functions) 个函数，函数切分退化了")

        let overFiles = result.fileLines.filter { $0.lines > Self.fileLineBar }
        XCTAssertTrue(overFiles.isEmpty, """
        Tests 里 \(overFiles.count) 个文件超 \(Self.fileLineBar) 行（产品侧「巨大文件」同一口径）：
        \(overFiles.map { "  \($0.name) \($0.lines) 行" }.joined(separator: "\n"))
        拆文件才是修复，改这里的数字不是。
        """)

        let overFunctions = result.offenders.filter { $0.lines > Self.functionLineBar }
        // 只减不增：新出现在清单外的长函数即失败；清单内的被拆掉后要把它从清单里划掉。
        let unexpected = Set(overFunctions.map { "\($0.file):\($0.function)" })
            .subtracting(Self.longFunctionWorkList)
        XCTAssertTrue(unexpected.isEmpty, """
        Tests 里出现\(Self.functionLineBar) 行口径之外、且不在派工清单里的新长函数：
        \(Self.roster(overFunctions.filter { unexpected.contains("\($0.file):\($0.function)") }))
        要么就地拆成小步骤，要么把名字加进 `longFunctionWorkList` 并向总工说明理由——
        悄悄抬高 `functionLineBar` 不在选项里（那是冻结口径）。
        """)
        let stale = Self.longFunctionWorkList
            .subtracting(Set(overFunctions.map { "\($0.file):\($0.function)" }))
        XCTAssertTrue(stale.isEmpty, """
        派工清单里 \(stale.count) 个函数已经达标了，把它们从 `longFunctionWorkList` 划掉：
        \(stale.sorted().joined(separator: "\n"))
        """)

        let hot = result.offenders.filter { $0.complexity >= Self.complexFunctionBar }
        XCTAssertTrue(hot.isEmpty, """
        Tests 里 \(hot.count) 个函数圈复杂度 ≥ \(Self.complexFunctionBar)（工具判「高」风险那条线）：
        \(Self.roster(hot))
        """)
        print("【X3 规模闸门】Tests \(result.fileLines.count) 个文件 / \(result.functions) 个函数，"
            + "最大文件 \(result.fileLines.map(\.lines).max() ?? 0) 行、"
            + "最长函数 \(result.offenders.map(\.lines).max() ?? 0) 行、"
            + "最高 CC \(result.offenders.map(\.complexity).max() ?? 0)；"
            + "口径：文件≤\(Self.fileLineBar) 行、函数≤\(Self.functionLineBar) 行、CC<\(Self.complexFunctionBar)")
    }

    // MARK: - 元测试：尺子失效当场可见（故意写坏一个 60 行的函数）

    func testAuditRulerCatchesASyntheticallyLongFunction() async throws {
        var body = ""
        for index in 1...56 { body += "        let v\(index) = \(index) * 2\n" }
        body += "        return v1 + v56\n"
        let synthetic = """
        import Foundation
        enum X3ProbeTarget {
            static func deliberatelyLong() -> Int {
        \(body)}
            static func deliberatelyShort() -> Int {
                return 1
            }
        }
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("x3-testsize-audit-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try synthetic.write(to: dir.appendingPathComponent("X3ProbeTarget.swift"),
                            atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }

        let files = await SourceTreeScanner(options: .default).scan(root: dir).files
        XCTAssertEqual(files.count, 1, "夹具没被产品侧扫描器收进来，元测试本身失效")
        let functions = ComplexityEngine.functions(in: files[0])
            .reduce(into: [String: FunctionCandidate]()) { acc, f in acc[f.name] = f }
        let long = try XCTUnwrap(functions["deliberatelyLong"], "尺子没认出 60 行的那个函数")
        let short = try XCTUnwrap(functions["deliberatelyShort"], "尺子连 3 行的函数都没认出")
        XCTAssertGreaterThan(long.lineCount, Self.functionLineBar,
                             "60 行的函数没被判超限，函数边界切错了（实测 \(long.lineCount) 行）")
        XCTAssertLessThanOrEqual(short.lineCount, Self.functionLineBar,
                                 "3 行的函数被判超限，尺子不可能通过这轮（实测 \(short.lineCount) 行）")
        print("【X3 元测试】合成夹具：长函数 \(long.lineCount) 行 CC=\(long.complexity)，"
            + "短函数 \(short.lineCount) 行 CC=\(short.complexity)")
    }
}
