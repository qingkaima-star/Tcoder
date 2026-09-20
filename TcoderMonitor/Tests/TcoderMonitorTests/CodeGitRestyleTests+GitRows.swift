/// OWNER: WS-X3 TestSplit —— 自 CodeGitRestyleTests.swift 拆出，Git 口径横幅、作者表、活跃度与 bus factor 的读数形状。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension CodeGitRestyleTests {

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

}
