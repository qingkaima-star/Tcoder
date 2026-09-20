import XCTest
@testable import TcoderMonitor

/// WS-L 代码与 Git 类页面重样的判据测试。
///
/// 只测**纯函数**（口径派生、三态判定、读数聚合、分类色稳定性、文案措辞）：
/// 不启动 App、不碰渲染，UI 取证由总工统一安排。
final class CodeGitRestyleTests: XCTestCase {

    // MARK: - Helpers

    private func author(_ name: String, _ email: String, commits: Int,
                        last: Date? = nil) -> AuthorStats {
        AuthorStats(name: name, email: email, commits: commits, additions: 0, deletions: 0,
                    filesTouched: 0, firstCommitAt: nil, lastCommitAt: last,
                    activityByHour: [], topDirectories: [:])
    }

    private func bucket(_ date: Date, commits: Int, granularity: BucketGranularity = .week) -> CommitBucket {
        CommitBucket(date: date, commits: commits, additions: 0, deletions: 0, granularity: granularity)
    }

    // MARK: - Git 提交口径（「62 vs 48」那条账）

    func testMergeOnlyGapIsReportedAsMergesNotAsWindowTruncation() {
        // 本仓库形态：窗口远没用满，差额全是合并。
        let scope = GitHistoryScope(totalCommits: 62, nonMergeCommitsAnalysed: 48, windowLimit: 20_000)
        XCTAssertEqual(scope.basis, .complete(mergeCount: 14))
        XCTAssertEqual(scope.mergeCount, 14)
        XCTAssertFalse(scope.isWindowTruncated,
                       "有合并提交不等于窗口被截断，不能再据此拉「只代表这段窗口」的警告横幅")
        XCTAssertTrue(scope.headline.contains("共 62 次提交（含 14 次合并）"), scope.headline)
        XCTAssertTrue(scope.headline.contains("48 次非合并提交"), scope.headline)
        XCTAssertEqual(scope.authorBasis, 48, "作者与代码行的分母必须是不含合并的 48")
        XCTAssertTrue(scope.windowSuffix.isEmpty)
        XCTAssertFalse(GitCommitScopeSection.message(for: scope).contains("不代表全部历史"))
        XCTAssertTrue(scope.totalTileCaption.contains("含 14 次合并"), scope.totalTileCaption)
    }

    func testWindowCappedRepositoryNeverClaimsAnExactMergeCount() {
        // Homebrew 实测：total 50,666 / 窗口 20,000，差额 30,666 里混着没读到的更早历史。
        let scope = GitHistoryScope(totalCommits: 50_666, nonMergeCommitsAnalysed: 20_000,
                                    windowLimit: 20_000)
        XCTAssertEqual(scope.basis, .windowCapped)
        XCTAssertNil(scope.mergeCount, "窗口打满时报不出精确合并数，宁可不写")
        XCTAssertTrue(scope.isWindowTruncated)
        XCTAssertTrue(scope.headline.contains("最近 20,000 次非合并提交"), scope.headline)
        XCTAssertTrue(scope.headline.contains("更早的历史未纳入"), scope.headline)
        XCTAssertTrue(scope.windowSuffix.contains("近 20,000 次提交窗口内"), scope.windowSuffix)
        XCTAssertTrue(GitCommitScopeSection.message(for: scope).contains("不代表全部历史"))
        XCTAssertTrue(scope.authorTileCaption(authorCount: 617).contains("窗口内"),
                      scope.authorTileCaption(authorCount: 617))
    }

    func testLegacyReportWithoutWindowFieldIsItsOwnState() {
        // 旧报告没有 commitsAnalyzed（=0）：既不能说全是合并，也不能说被截断。
        let scope = GitHistoryScope(totalCommits: 62, nonMergeCommitsAnalysed: 0, windowLimit: 20_000)
        XCTAssertEqual(scope.basis, .unknown)
        XCTAssertNil(scope.mergeCount)
        XCTAssertTrue(scope.headline.contains("重新分析后可拆分"), scope.headline)
        XCTAssertEqual(scope.authorBasis, 62, "缺字段时退回旧口径，但文案必须说明")
        XCTAssertFalse(scope.isWindowTruncated)
        XCTAssertEqual(scope.totalTileCaption, "旧报告未记录窗口口径")
    }

    func testMergeFreeHistoryCoversEveryCommit() {
        let scope = GitHistoryScope(totalCommits: 62, nonMergeCommitsAnalysed: 62, windowLimit: 20_000)
        XCTAssertEqual(scope.basis, .complete(mergeCount: 0))
        XCTAssertTrue(scope.headline.contains("历史中没有合并提交"), scope.headline)
        XCTAssertFalse(scope.mergesExplainTheGap)
        XCTAssertEqual(scope.totalTileCaption, "无合并提交 · 已覆盖全部历史")
    }

    func testAuthorTableSumMatchesTheBasisPrintedOnScreen() {
        // 现场核对：作者表求和必须等于页面上那枚「作者统计基准」，否则用户还是会发现对不上。
        let git = GitInsights(totalCommits: 62, commitsAnalyzed: 48,
                              authors: [author("Tcoder Team", "t@tcoder.local", commits: 48)])
        let scope = git.commitScope
        XCTAssertEqual(git.authors.reduce(0) { $0 + $1.commits }, scope.authorBasis)
        XCTAssertEqual(git.authorShare(of: git.authors[0]) ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertNil(GitInsights().authorShare(of: author("x", "x@y", commits: 1)),
                     "分母为 0 时返回 nil，让界面显示 --，而不是算出一个假的 0%")
    }

    func testDiscoveryWordingSeparatesWhereFromWhy() {
        let up = GitInsights(discoveryMode: .parentDirectory, discoveryHops: 2)
        XCTAssertEqual(GitRepositorySourceSection.discoveryCaption(up), "向上 2 层找到")
        XCTAssertTrue(GitRepositorySourceSection.discoveryDetail(up).contains("仓库内部"))
        let down = GitInsights(discoveryMode: .nestedSubdirectory, discoveryHops: 1)
        XCTAssertTrue(GitRepositorySourceSection.discoveryDetail(down).contains("子仓库"))
        XCTAssertEqual(GitRepositorySourceSection.discoveryCaption(GitInsights()), "未找到仓库")
    }

    // MARK: - 趋势读数与时段矩阵

    func testTrendReadoutAggregatesBuckets() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let buckets = [
            bucket(now, commits: 5),
            bucket(now.addingTimeInterval(604_800), commits: 0),
            bucket(now.addingTimeInterval(1_209_600), commits: 9),
        ]
        let summary = GitTrendReadoutBar.summary(of: buckets)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.peak, 9)
        XCTAssertEqual(summary.lowest, 0)
        XCTAssertEqual(summary.emptyBuckets, 1)
        XCTAssertEqual(summary.average, 14.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(summary.unitLabel, "每周")
        XCTAssertTrue(summary.spanCaption.contains("→"), summary.spanCaption)
    }

    func testTrendReadoutOnEmptyBucketsDoesNotInventZeroes() {
        let summary = GitTrendReadoutBar.summary(of: [])
        XCTAssertEqual(summary.count, 0)
        XCTAssertEqual(summary.unitLabel, "无分桶")
        XCTAssertEqual(summary.spanCaption, "无分桶")
    }

    func testAllZeroActivityMeansNoTimestampsNotQuietHours() {
        XCTAssertTrue(GitActivityHeatmap.hasNoTimestamps(
            hourCounts: Array(repeating: 0, count: 24), weekdayCounts: Array(repeating: 0, count: 7)))
        XCTAssertFalse(GitActivityHeatmap.hasNoTimestamps(
            hourCounts: [1] + Array(repeating: 0, count: 23), weekdayCounts: Array(repeating: 0, count: 7)))
    }

    // MARK: - 贡献者分析

    func testBusFactorUsesNonMergeBasisNotMergedTotal() {
        // 窗口口径 48：头名 34/48 = 71% → high；错用含合并的 62 只有 55% → 会被降级成 medium。
        let git = GitInsights(totalCommits: 62, commitsAnalyzed: 48,
                              authors: [author("A", "a@x", commits: 34),
                                        author("B", "b@x", commits: 14)])
        XCTAssertEqual(ContributorAnalysis.busFactorRisk(git), .high)
        // #44 修好后翻正：以前模型用含合并的 62 当分母（55% → medium），
        // 与视图不同总体；现在两侧必须同一个分母、同一个结论。
        XCTAssertEqual(git.busFactorRisk, .high,
                       "模型的分母已换成作者总体（非合并），应与视图同为 71% → high")
        XCTAssertEqual(git.busFactorRisk, ContributorAnalysis.busFactorRisk(git),
                       "模型与视图两套实现必须同分母同结论，否则又会各说一套")
        XCTAssertTrue(ContributorBusFactorSection.message(for: git).contains("分母 = 48 次非合并提交"),
                      ContributorBusFactorSection.message(for: git))
    }

    func testBusFactorWithoutAnyAuthorSaysCannotEvaluate() {
        let message = ContributorBusFactorSection.message(for: GitInsights())
        XCTAssertTrue(message.contains("无法评估 Bus Factor"), message)
        XCTAssertEqual(ContributorAnalysis.busFactorRisk(GitInsights()), .none)
    }

    func testRankingIsStableAndDisplayNameFallsBackToEmail() {
        let anonymous = author("", "zoe@x", commits: 5)
        let named = author("Aaron", "a@x", commits: 5)
        let sorted = ContributorAnalysis.sorted([anonymous, named])
        XCTAssertEqual(sorted.map { ContributorAnalysis.displayName($0) }, ["Aaron", "zoe@x"],
                       "同分时按显示名升序，榜位才不会每次刷新都换")
        XCTAssertEqual(ContributorAnalysis.displayName(anonymous), "zoe@x")
        XCTAssertEqual(ContributorAnalysis.email(anonymous), "zoe@x")
        XCTAssertEqual(ContributorAnalysis.email(author("", "", commits: 1)), "无邮箱记录")
    }

    func testRecentlyActiveWindowIsThirtyDays() {
        let now = Date(timeIntervalSince1970: 1_750_000_000)
        let fresh = author("Fresh", "f@x", commits: 1, last: now.addingTimeInterval(-2 * 86_400))
        let stale = author("Stale", "s@x", commits: 9, last: now.addingTimeInterval(-90 * 86_400))
        let silent = author("Silent", "z@x", commits: 9)
        XCTAssertEqual(ContributorAnalysis.recentlyActive([fresh, stale, silent], now: now).map(\.name),
                       ["Fresh"])
    }

    func testAvatarInitialHandlesCJKLatinAndEmpty() {
        XCTAssertEqual(ContributorAvatar.initial(author: author("张三", "z@x", commits: 1)), "张")
        XCTAssertEqual(ContributorAvatar.initial(author: author("token", "t@x", commits: 1)), "T")
        XCTAssertEqual(ContributorAvatar.initial(author: author("  ", "bob@x", commits: 1)), "B")
        XCTAssertEqual(ContributorAvatar.initial(author: author("", "", commits: 1)), "?")
    }

    func testCategoryColorIsStableAcrossCallsAndInsidePalette() {
        let email = "dev@tcoder.local"
        XCTAssertEqual(CodeGitCategoryColor.index(for: email), CodeGitCategoryColor.index(for: email),
                       "同一作者每次启动必须是同一个颜色——旧实现用 hashValue 取色会随机漂移")
        XCTAssertEqual(CodeGitCategoryColor.index(for: "UPPER@X"),
                       CodeGitCategoryColor.index(for: "upper@x"), "大小写不同的同一邮箱应同色")
        XCTAssertTrue((0..<Theme.Chart.count).contains(CodeGitCategoryColor.index(for: email)))
        XCTAssertTrue((0..<Theme.Chart.count).contains(CodeGitCategoryColor.index(for: "")))
    }

    // MARK: - 代码页三态

    func testCodeGateKeepsNotAnalysedApartFromMeasuredEmpty() {
        XCTAssertEqual(CodeDataGate.state(of: nil), .notAnalysed)
        XCTAssertEqual(CodeDataGate.state(of: CodeMetrics()), .measuredEmpty)
        XCTAssertEqual(CodeDataGate.state(of: CodeMetrics(totalFiles: 3, totalLines: 30)), .analysed)
        XCTAssertNil(CodeDataGate.metrics(of: CodeMetrics()), "扫到空结果时不能继续渲染指标卡")

        let notAnalysed = CodeDataGate.emptyCopy(for: nil, page: "复杂度")
        let measured = CodeDataGate.emptyCopy(for: CodeMetrics(), page: "复杂度")
        XCTAssertNotNil(notAnalysed)
        XCTAssertNotNil(measured)
        XCTAssertNotEqual(notAnalysed?.title, measured?.title)
        XCTAssertTrue(measured!.message.contains("这是测得的结果"), measured!.message)
        XCTAssertTrue(notAnalysed!.message.contains("重新分析"), notAnalysed!.message)
    }

    func testMissingNumbersRenderAsPlaceholderNotZero() {
        XCTAssertEqual(DataAbsence.value("12").display, "12")
        XCTAssertEqual(DataAbsence.measuredEmpty.display, NumberFormat.grouped(0))
        XCTAssertEqual(DataAbsence.notAnalysed.display, "--",
                       "没有证据时必须显示 --，0 会被读成「零风险」这个好消息")
        XCTAssertFalse(DataAbsence.notAnalysed.permitsConclusion)
        XCTAssertEqual(DataAbsence.notAnalysed.effectiveRole(Theme.Semantic.success).name, "neutral",
                       "缺数据时中性角色必须盖掉调用方给的倾向色")
        XCTAssertEqual(DataAbsence.value("0").effectiveRole(Theme.Semantic.success).name, "success")
    }

    /// #47 之后这三处不再是 `--`：分母为 0 属「算不出」，`--` 只留给「没扫/没查」，
    /// 否则用户分不清"这项目真的没有"和"我们没查"（《42》§14.3 第 1 条）。
    /// 字面单点在 `Design/DataAbsence.swift`，四态本身由 `DesignAbsenceStateTests` 钉。
    func testAverageFileLinesUnknownIsPlaceholderNotZero() {
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics()), "算不出")
        XCTAssertEqual(CodeScaleSection.averageFileLines(CodeMetrics(totalFiles: 4, totalLines: 40)), "10.0")
        XCTAssertEqual(CodeMetricsSummaryGrid.shareOf(10, CodeMetrics()), "算不出",
                       "总行数为 0 时没有「占比」这个结论可言，但也不是没扫")
        XCTAssertEqual(CodeRiskAnalysis.averageComplexityValue(CodeMetrics(totalFiles: 1, totalLines: 10)),
                       "算不出", "一个函数都没识别出来时不能显示 0，也不能显示成「没查」")
    }

    func testLanguageMixMergesTailHonestly() {
        let shares = [
            LanguageShare(language: "Swift", fileCount: 40, lineCount: 1_000, share: 0.5),
            LanguageShare(language: "Python", fileCount: 10, lineCount: 400, share: 0.2),
            LanguageShare(language: "Ruby", fileCount: 5, lineCount: 200, share: 0.1),
            LanguageShare(language: "Go", fileCount: 5, lineCount: 200, share: 0.1),
            LanguageShare(language: "JS", fileCount: 2, lineCount: 100, share: 0.05),
            LanguageShare(language: "CSS", fileCount: 2, lineCount: 100, share: 0.05),
            LanguageShare(language: "Sh", fileCount: 1, lineCount: 0, share: 0),
        ]
        let code = CodeMetrics(languages: shares)
        let visible = CodeMetricsView.visibleShares(code, head: 4)
        // 同分时先按行数降序、再按语言名升序：Ruby 与 Go 都是 200 行 / 10%，所以 Go 在前。
        XCTAssertEqual(visible.map(\.language), ["Swift", "Python", "Go", "Ruby", "其他"])
        XCTAssertEqual(visible.last?.lineCount, 200, "「其他」= JS 100 + CSS 100")
        XCTAssertEqual(visible.last?.fileCount, 4)
        XCTAssertTrue(CodeMetricsView.mergedNote(code, head: 4)!.contains("占比最低的 2 种语言"))
        XCTAssertNil(CodeMetricsView.mergedNote(code, head: 8), "没超过展示上限就不该有合并说明")
        XCTAssertEqual(CodeScaleSection.subtitle(code), "按有效代码行计，共 7 种语言，展示前 6 种")
    }

    func testMarkerNoteOnZeroMarkersSaysScannedNotFound() {
        let clean = CodeMetrics(totalFiles: 12, totalLines: 400, codeLines: 300)
        XCTAssertTrue(CodeMarkersSection.markerNote(clean).contains("已完成扫描"))
        XCTAssertFalse(CodeMarkersSection.markerNote(clean).contains("建议优先"))
        XCTAssertEqual(CodeMarkersSection.markerDensityPerKilo(clean), 0)
        let withFixMe = CodeMetrics(totalFiles: 12, totalLines: 400, codeLines: 300, fixmeCount: 3)
        XCTAssertTrue(CodeMarkersSection.markerNote(withFixMe).contains("FIXME 3 处"))
    }

    // MARK: - 风险判据

    func testDuplicationTiersFlipAtTheirDocumentedThresholds() {
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(0).name, "success")
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(CodeRiskAnalysis.duplicationNotableRatio - 0.001).name,
                       "success")
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(CodeRiskAnalysis.duplicationNotableRatio).name, "warning")
        XCTAssertEqual(CodeRiskAnalysis.ratioRole(CodeRiskAnalysis.duplicationHighRatio).name, "danger")
    }

    func testEverySuggestionLineCarriesARealNumber() {
        let block = DuplicatedBlock(occurrences: [
            DuplicatedFragment(path: "/p/a.swift", startLine: 10),
            DuplicatedFragment(path: "/p/b.swift", startLine: 40),
            DuplicatedFragment(path: "/p/c.swift", startLine: 70),
        ], lineCount: 22, similarity: 0.94)
        let code = CodeMetrics(
            totalFiles: 50, totalLines: 9_000, commentLines: 120, codeLines: 7_000,
            todoCount: 9, fixmeCount: 4,
            hugeFiles: [FileHotspot(path: "/p/big.swift", lineCount: 900, risk: .high,
                                    suggestion: "按职责拆分")],
            duplicationRatio: 0.2, duplicatedBlocks: [block])
        let items = CodeRiskAnalysis.suggestions(for: code)
        XCTAssertFalse(items.isEmpty)
        for item in items {
            XCTAssertTrue(item.text.contains { $0.isNumber },
                          "无数字支撑的结论不许出现在建议区：\(item.text)")
        }
        XCTAssertTrue(items.contains { $0.id == "duplication-high" })
        XCTAssertTrue(items.contains { $0.id == "huge-file" })
        XCTAssertTrue(items.contains { $0.id == "markers" })
        XCTAssertTrue(items.contains { $0.id == "comments" })
        XCTAssertEqual(items.first(where: { $0.id == "duplication-high" })?.role.name, "danger")
    }

    func testCleanScanProducesNoSuggestionsAndOneHonestNote() {
        // 注释率要给到提示线以上，否则「注释率偏低」本身就会产出一条建议，测不到空集。
        let code = CodeMetrics(totalFiles: 4, totalLines: 200, commentLines: 20, codeLines: 180)
        XCTAssertTrue(CodeRiskAnalysis.suggestions(for: code).isEmpty)
        let note = CodeRiskAnalysis.noRiskNote(code)
        XCTAssertTrue(note.contains("已完成扫描"), note)
        XCTAssertTrue(note.contains("重复代码率 0.0%"), note)
    }

    func testComplexityDivergenceNeedsFiveHotspots() {
        func hotspots(_ count: Int, cc: Int) -> [FunctionHotspot] {
            (1...count).map {
                FunctionHotspot(name: "f\($0)", filePath: "/p/x.swift", startLine: $0,
                                lineCount: 60, cyclomaticComplexity: cc, parameterCount: 7, risk: .high)
            }
        }
        let few = CodeMetrics(totalFiles: 5, totalLines: 500, codeLines: 400,
                              topComplexFunctions: hotspots(4, cc: 30),
                              averageCyclomaticComplexity: 4)
        XCTAssertNil(CodeRiskAnalysis.relativeComplexitySuggestion(few),
                     "样本不足 5 个就不该断言「平均值被少数函数拉高」")
        let many = CodeMetrics(totalFiles: 5, totalLines: 500, codeLines: 400,
                               topComplexFunctions: hotspots(6, cc: 40), longFunctions: 6,
                               averageCyclomaticComplexity: 4)
        XCTAssertNotNil(CodeRiskAnalysis.relativeComplexitySuggestion(many))
        let items = CodeRiskAnalysis.suggestions(for: many)
        XCTAssertTrue(items.contains { $0.id == "parameters" }, "7 个参数 ≥ 阈值 6，必须点名")
        XCTAssertTrue(items.contains { $0.id == "complexity-high-cluster" })
        XCTAssertEqual(CodeRiskAnalysis.highRiskFunctionCount(many), 6)
    }

    func testDuplicationOccurrenceSummaryCountsTheRest() {
        let block = DuplicatedBlock(occurrences: (1...6).map {
            DuplicatedFragment(path: "/src/dir/file\($0).swift", startLine: $0 * 10)
        }, lineCount: 30, similarity: 0.9)
        let shown = CodeDuplicationBlockRow.occurrenceTitles(block, root: "/src")
        XCTAssertTrue(shown.contains("另有 2 处"), shown)
        XCTAssertEqual(CodeDuplicationBlockRow.occurrenceTitles(block, root: "/src", limit: 6)
            .components(separatedBy: "   ").count, 6)
        XCTAssertTrue(CodeDuplicationBlockRow.hint(block, root: "/src").contains("相似度 90.0%"))
    }

    // MARK: - 依赖页诚实线

    func testUncheckedRowNeverRendersAsSafe() {
        for status in [DependencyRowStatus.versionOnly, .unchecked] {
            XCTAssertEqual(status.role.name, "neutral", "\(status.text) 不得带倾向色")
            XCTAssertNotEqual(status.badgeIcon, .noRisk, "没核对过就不能用对勾")
            XCTAssertNotEqual(status.text, "正常")
        }
        XCTAssertEqual(DependencyRowStatus.verifiedSafe.role.name, "success")
        XCTAssertEqual(DependencyRowStatus.verifiedSafe.badgeIcon, .noRisk)
        XCTAssertEqual(DependencyRowStatus.outdated.role.name, "warning")
        XCTAssertEqual(DependencyRowStatus.vulnerable(count: 2).badgeIcon, .vulnerable)
    }

    func testOfflineEmptyAdvisorySaysNotChecked() {
        let record = DependencyRecord(name: "lodash", version: "4.17.21", ecosystem: .npm,
                                      scope: .runtime, manifestPath: "/p/package.json",
                                      latestKnownVersion: nil, versionCheckSource: .none,
                                      knownVulnerabilities: [])
        let report = DependencyReport(ecosystems: [
            EcosystemReport(ecosystem: .npm, manifestPath: "/p/package.json", lockfileName: nil,
                            dependencies: [record], frameworkMarkers: [])
        ])
        let caption = DependencyAdvisoriesSection.emptyCaption(report)
        XCTAssertTrue(caption.contains("没有查"), caption)
        XCTAssertFalse(caption.contains("未发现已知漏洞"),
                       "离线空列表不得写成 all-clear 句式")
        XCTAssertEqual(DependencyAdvisoriesSection.subtitle(items: [], deps: report),
                       "内置快照与安全公告均未命中")
        XCTAssertEqual(DependencySafetyVerdict(report).badgeIcon, .unverified)
    }

    func testOutdatedCaptionWithoutComparableVersionsIsNotACleanZero() {
        XCTAssertEqual(DependencySummaryGrid.outdatedCaption(DependencyReport()), "没有可判定的依赖")
        let record = DependencyRecord(name: "left-pad", version: "1.0.0", ecosystem: .npm,
                                      scope: .runtime, manifestPath: "/p/package.json",
                                      latestKnownVersion: "2.0.0", versionCheckSource: .bundledSnapshot,
                                      knownVulnerabilities: [])
        let report = DependencyReport(ecosystems: [
            EcosystemReport(ecosystem: .npm, manifestPath: "/p/package.json", lockfileName: nil,
                            dependencies: [record], frameworkMarkers: [])
        ])
        XCTAssertTrue(DependencySummaryGrid.outdatedCaption(report).contains("占依赖总数"),
                      DependencySummaryGrid.outdatedCaption(report))
    }

    func testAdviceLineIsInfoNotSuccess() {
        let item = VulnerabilityItem(id: "off-1", severity: .high, aliases: ["CVE-1"],
                                     targets: ["a", "b", "c", "d", "e"], range: "pkg <1.0",
                                     summary: "越界读取", advice: "建议升级至 1.0.1", score: 7.5,
                                     source: "npm")
        XCTAssertEqual(VulnerabilityRow.adviceRole(item).name, "info",
                       "「建议升级」是修复路径，不是已安全的结论")
        let line = VulnerabilityRow.targetsLine(item)
        XCTAssertTrue(line.hasPrefix("pkg <1.0 → "), line)
        XCTAssertTrue(line.contains("等 5 项"), line)
    }

    // MARK: - 表格列定义

    func testEveryTableHasOneLeadingColumnAndUniqueTitles() {
        let tables: [(String, [DataGridColumn])] = [
            ("complexityFunctions", DataColumns.complexityFunctions),
            ("hugeFiles", DataColumns.hugeFiles),
            ("dependencies", DataColumns.dependencies),
            ("recentCommits", DataColumns.recentCommits),
            ("duplicationBlocks", DataColumns.duplicationBlocks),
        ]
        for (name, columns) in tables {
            XCTAssertEqual(columns.filter { $0.width == nil }.count, 1,
                             "\(name) 必须恰好一个弹性名称列，否则表头与行会错位")
            XCTAssertEqual(columns.filter { $0.width == nil }.first?.alignment, .leading)
            XCTAssertTrue(columns.filter { $0.width != nil }.allSatisfy { $0.alignment != .leading }
                            || name == "recentCommits",
                          "\(name) 的定宽列不左对齐（SHA 列除外：十六进制串按前缀读，左对齐才对）")
            XCTAssertEqual(Set(columns.map(\.title)).count, columns.count, "\(name) 列名重复")
        }
    }

    func testColumnLookupsClampInsteadOfCrashing() {
        let columns = DataColumns.dependencies
        XCTAssertEqual(DataColumns.column(columns, columns.count).width, nil)
        XCTAssertEqual(DataColumns.column(columns, -1).width, nil)
    }

    // MARK: - 第二轮：口径互斥的三态空态

    func testGitAbsenceStatesAreMutuallyExclusive() {
        let notRepo = GitInsights(isRepository: false, totalCommits: 0)
        let empty = GitInsights(isRepository: true, totalCommits: 0)
        let unparsed = GitInsights(isRepository: true, totalCommits: 62, commitsAnalyzed: 0)
        XCTAssertEqual(notRepo.commitAbsence, .notARepository)
        XCTAssertEqual(empty.commitAbsence, .repositoryWithoutCommits)
        XCTAssertEqual(unparsed.commitAbsence, .commitsUnparsed(total: 62))
        XCTAssertEqual(GitInsights(isRepository: true, totalCommits: 62,
                                   commitsAnalyzed: 48).commitAbsence, .available)
    }

    func testAbsenceWordingsNeverBlendNotApplicableWithMeasuredZero() {
        let notRepo = GitDataAbsence.notARepository.copy!
        XCTAssertTrue(notRepo.message.contains("不适用"), notRepo.message)
        XCTAssertFalse(notRepo.title.contains("还没有提交"),
                       "不是仓库不能说成「还没有提交」，那是两件事")

        let measured = GitDataAbsence.repositoryWithoutCommits.copy!
        XCTAssertTrue(measured.message.contains("测得"), measured.message)
        XCTAssertTrue(measured.title.contains("还没有提交"), measured.title)

        let unparsed = GitDataAbsence.commitsUnparsed(total: 62).copy!
        XCTAssertTrue(unparsed.message.contains("不给任何结论"), unparsed.message)
        XCTAssertTrue(unparsed.title.contains("62"), unparsed.title)

        let noAuthors = GitDataAbsence.commitsWithoutAuthors(total: 48).copy!
        XCTAssertTrue(noAuthors.message.contains("不是「零贡献者」"), noAuthors.message)

        XCTAssertNil(GitDataAbsence.available.copy)
        XCTAssertFalse(GitDataAbsence.hasDuplicateTitles(),
                       "四个空态标题必须两两不同，否则等于又合回一句话")
    }

    func testAuthorAbsenceChainsAfterCommitAbsence() {
        let noRepo = GitInsights(isRepository: false)
        XCTAssertEqual(noRepo.authorAbsence, .notARepository, "不是仓库时先说仓库问题")
        let commitsButNoAuthors = GitInsights(isRepository: true, totalCommits: 62,
                                              commitsAnalyzed: 48, authors: [])
        XCTAssertEqual(commitsButNoAuthors.authorAbsence, .commitsWithoutAuthors(total: 48))
        let withAuthors = GitInsights(isRepository: true, totalCommits: 62, commitsAnalyzed: 48,
                                      authors: [author("A", "a@x", commits: 48)])
        XCTAssertEqual(withAuthors.authorAbsence, .available)
    }

    // MARK: - 第二轮：色板与行节奏

    func testMemberColorsNeverCollideWithTheAggregateBlue() {
        XCTAssertEqual(CodeGitCategoryColor.aggregateIndex, 0,
                       "0 号蓝是「主/自身数据」档，合计行与主序列专用")
        for key in ["a@x", "b@x", "Swift", "Python", "dev@tcoder.local", "", "张三 <z@x>"] {
            XCTAssertNotEqual(CodeGitCategoryColor.index(for: key),
                              CodeGitCategoryColor.aggregateIndex,
                              "\(key) 抢到了合计行的颜色")
            XCTAssertTrue((0..<Theme.Chart.count).contains(CodeGitCategoryColor.index(for: key)))
        }
    }

    /// 等宽与行节奏的覆盖面：承载数字的散文文本必须走 `CodeGitType.prose`（自带等宽数字），
    /// 而榜单行只能通过 `.dataTableRow()` 拿行高。两处都用源码扫描钉住，防止下一轮又各写各的。
    func testEveryProseNumberAndRowGoesThroughTheMonospacedHelpers() throws {
        let rowFiles: Set<String> = [
            "Code/CodeViewSupport.swift", "Code/CodeRiskRows.swift",
            "Git/ContributorRows.swift", "Git/GitInsightsCharts.swift",
            "Dependencies/DependencyVerdictRows.swift",
        ]
        let proseTiers = ["label", "microLabel", "narrative", "body", "cardTitle", "pageTitle"]
        var proseFonts: [String] = []
        var missingRhythm: [String] = []
        for file in try wsLSources() {
            for (index, line) in file.lines.enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.starts(with: "//") else { continue }
                if proseTiers.contains(where: { trimmed.contains(".font(Theme.Typo.\($0).font)") }) {
                    proseFonts.append("\(file.name):\(index + 1): \(trimmed.prefix(60))")
                }
            }
            if rowFiles.contains(file.name), !file.body.contains(".dataTableRow()") {
                missingRhythm.append(file.name)
            }
        }
        XCTAssertTrue(proseFonts.isEmpty,
                      "散文文本要走 CodeGitType.prose，数字才保证等宽：\n\(proseFonts.joined(separator: "\n"))")
        XCTAssertTrue(missingRhythm.isEmpty,
                      "这些文件里有榜单行却没引用 .dataTableRow()：\(missingRhythm)")
    }

    func testRowRhythmComesFromOnePlace() {
        XCTAssertEqual(DataRowMetrics.verticalPadding, Theme.Spacing.xs)
        XCTAssertEqual(DataRowMetrics.rowGap, Theme.Spacing.xxs)
        XCTAssertEqual(DataRowMetrics.cellGap, Theme.Spacing.sm)
        XCTAssertEqual(DataRowMetrics.minRowHeight,
                       Theme.Layout.minHitTarget + Theme.Spacing.sm,
                       "行高下限必须可由令牌复算，不接受孤立数字")
        XCTAssertGreaterThanOrEqual(DataRowMetrics.minRowHeight, Theme.Layout.minHitTarget)
    }

    // MARK: - 防回潮棘轮（只扫 WS-L 名下四个目录）

    /// 元测试：证明上面那条棘轮不是空跑。
    /// 每条禁令都要能被一行合成违例命中，否则扫描会变成"永远绿的假安心"。
    func testRatchetPatternsActuallyDetectTheirOwnViolations() throws {
        let samples: [(String, String)] = [
            ("裸字号", #"        Text(x).font(.system(size: 9))"#),
            ("Theme 兼容桥旧色彩入口", "        tint: Theme.accent,"),
            ("Theme.color(for:)", "        .foregroundStyle(Theme.color(for: risk))"),
            ("裸颜色字面量", #"    Color(hex: "5C8DFF"), Color(red: 0.5, green: 0.5, blue: 0.5)"#),
            ("自造透明度", "        .background(status.tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 3))"),
            ("旧分隔线", "                Divider().opacity(0.4)"),
            ("冻结在 Dashboard 的旧件", "            BannerRow(text: note, style: .warning)"),
            ("数字 padding", "            .padding(16)"),
            ("数字 spacing", "        VStack(spacing: 3) {"),
            ("数字尺寸", "                .frame(width: 4, height: 34)"),
            ("行内上下留白绕过 dataTableRow", "        .padding(.vertical, Theme.Spacing.xxs)"),
            ("未登记的裸符号串", #"            Image(systemName: "arrow.up.forward.app")"#),
            ("页面直取 Typo 档而没走等宽入口", "                    .font(Theme.Typo.microLabel.font)"),
            ("绕过 dataTableRow 的行内留白", "                VStack(spacing: Theme.Spacing.xs) {"),
        ]
        for (name, sample) in samples {
            XCTAssertTrue(try wsLForbiddenPattern(named: name).firstMatch(
                in: sample, range: NSRange(location: 0, length: sample.utf16.count)) != nil,
                "禁令「\(name)」匹配不到它本应抓住的写法：\(sample)")
        }
    }

    private func wsLForbiddenPattern(named name: String) throws -> NSRegularExpression {
        let pattern = try XCTUnwrap(Self.forbiddenRawValues.first { $0.name == name }?.pattern,
                                    "棘轮里没有这条禁令：\(name)")
        return try NSRegularExpression(pattern: pattern)
    }

    /// 视图层禁止出现的写法（WS-I §6 的"零新增"断言，作用域只限 WS-L 名下四个目录）。
    /// 注释行不算违例：注释里要引用旧值才能说明为什么换掉它。
    /// `pagesOnly` 的三条只约束页面层——基座 `CodeGit/` 是组件实现点：
    /// `.padding(.vertical` 与 `.font(Theme.Typo.…)` 正是它对外提供 `dataTableRow()`
    /// 与 `CodeGitType.prose()` 的地方，在基座里禁掉等于把定义本身删掉。
    /// 每条禁令都由 `testRatchetPatternsActuallyDetectTheirOwnViolations` 反向验一次，
    /// 防止界符写错导致扫描空转（本项目上一轮就真的空转过）。
    static let forbiddenRawValues: [(name: String, pattern: String, pagesOnly: Bool)] = [
        ("裸字号", #"\.system\(size:"#, false),
        ("Theme 兼容桥旧色彩入口", #"Theme\.(accent|healthy|caution|danger|critical|neutral|gridLine|cardBackground|subtleBackground|monoSmall|monoBody|metricNumber|heroNumber)\b"#, false),
        ("Theme.color(for:)", #"Theme\.color\(for"#, false),
        ("裸颜色字面量", #"Color\((hex|red):"#, false),
        ("自造透明度", #"\.opacity\(0\.[0-9]"#, false),
        ("旧分隔线", #"Divider\(\)"#, false),
        ("冻结在 Dashboard 的旧件", #"(BannerRow|StatLine|LanguageBar)\("#, false),
        ("数字 padding", #"\.padding\((\.[a-z]+, )?[0-9]"#, false),
        ("数字 spacing", #"spacing: [0-9]"#, false),
        ("数字尺寸", #"\b(width|minHeight|maxHeight|height): [0-9]"#, false),
        ("行内上下留白绕过 dataTableRow", #"\.padding\(\.vertical"#, true),
        ("未登记的裸符号串", ##"Image\(systemName: ""##, false),
        ("页面直取 Typo 档而没走等宽入口", #"\.font\(Theme\.Typo\.(label|microLabel|narrative|body|cardTitle|pageTitle)\.font"#, true),
        ("绕过 dataTableRow 的行内留白", #"VStack\(spacing: Theme\.Spacing"#, true),
    ]

    /// WS-I §6 提的"零新增"断言，落在本流自己的目录上：
    /// 视图层不得再出现裸字号/裸色/裸间距/旧兼容桥入口，注释里引用旧值做说明不算违例。
    func testRestyledPagesCarryNoRawVisualValues() throws {
        let forbidden = Self.forbiddenRawValues
        var violations: [String] = []
        for (name, pattern, pagesOnly) in forbidden {
            let regex = try NSRegularExpression(pattern: pattern)
            for file in try wsLSources() where !pagesOnly || !file.name.hasPrefix("CodeGit/") {
                for (index, line) in file.lines.enumerated() {
                    let trimmed = line.trimmingCharacters(in: .whitespaces)
                    if trimmed.starts(with: "//") { continue }
                    if regex.firstMatch(in: trimmed, range: NSRange(location: 0,
                                                                    length: trimmed.utf16.count)) != nil {
                        violations.append("\(name) → \(file.name):\(index + 1): \(trimmed.prefix(64))")
                    }
                }
            }
        }
        XCTAssertTrue(violations.isEmpty,
                      "WS-L 名下页面出现回潮值（\(violations.count) 处）：\n" + violations.joined(separator: "\n"))
    }

    /// 字号下限：本流页面只允许取 `Theme.Typo` 档位，而最低一档 `microLabel` 是 10pt。
    func testSmallestTypefaceOnMyPagesIsAtLeastTenPoints() throws {
        XCTAssertGreaterThanOrEqual(Theme.Typo.microLabel.size, 10,
                                    "低于 10pt 的中文在 macOS 上几乎糊成一团（WS-H §4.2）")
        let text = try wsLSources().map(\.body).joined(separator: "\n")
        XCTAssertFalse(text.contains(".caption2"), "语义 .caption2 会掉到 10pt 以下")
        XCTAssertFalse(text.contains("font(.caption"), "本流页面一律用 Theme.Typo 档位取字")
    }

    private struct SourceFile { let name: String; let body: String
        var lines: [String] { body.components(separatedBy: "\n") } }

    private func wsLSources() throws -> [SourceFile] {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .appendingPathComponent("Sources/TcoderMonitor/Views")
        let fm = FileManager.default
        var out: [SourceFile] = []
        for dir in ["Code", "Git", "Dependencies", "CodeGit"] {
            let url = views.appendingPathComponent(dir)
            let names = (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".swift") {
                let file = url.appendingPathComponent(name)
                guard let body = try? String(contentsOf: file, encoding: .utf8) else { continue }
                out.append(SourceFile(name: "\(dir)/\(name)", body: body))
            }
        }
        // 14 → 13：`CodeGit/CodeGitTable.swift` 于 M0 上提为 `Design/DataTable.swift`
        // 13 → 14（收官轮 WS-X0）：本 App 自扫点名 `CodeRiskAnalysis.suggestions` 138 行 / CC 17，
        // 按类拆出的三个构建器落在同目录新文件 `Code/CodeRiskAdvice.swift`（原文件留在 400 行线内）。
        // 归属没动：多的是 Code 目录里的一处实现分片，仍归本流。
        // （本轮 spec §2.4）。它被 6 个目录的 10 个文件共用，留在一个页面目录下
        // 等于让该页独占全仓的列系统。这条断言本来就是「归属被动过就要响」，
        // 它响了，改的是**记录**而不是把断言删掉。
        XCTAssertEqual(out.count, 14, "WS-L/WS-P 名下应有 14 个视图文件（Code 5 / Git 5 / Dependencies 2 / CodeGit 2），数量变了说明归属被动过；列系统已上提进 Design/，见 Design/DataTable.swift")
        return out
    }
}

private extension GitDataAbsence {
    /// 标题是否出现重复——一旦有人把两种"没有数据"合回一句「……或……」，这里就会红。
    static func hasDuplicateTitles() -> Bool {
        let titles: [String] = [
            GitDataAbsence.notARepository.copy!.title,
            GitDataAbsence.repositoryWithoutCommits.copy!.title,
            GitDataAbsence.commitsUnparsed(total: 7).copy!.title,
            GitDataAbsence.commitsWithoutAuthors(total: 7).copy!.title,
        ]
        return Set(titles).count != titles.count
    }
}

