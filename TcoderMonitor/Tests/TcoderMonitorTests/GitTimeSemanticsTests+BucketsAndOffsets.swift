/// OWNER: WS-X3 TestSplit —— 自 GitTimeSemanticsTests.swift 拆出，日/周/月粒度按作者时区、零填充与上限语义、主导偏移的确定性。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension GitTimeSemanticsTests {

    /// 只测 `GitAggregation` 不够——缺陷长在 `ShellGitAnalyzer` 递进去的那把日历上。
    /// 这条钉住「makeInsights 的 commitsPerPeriod 用作者当地切」，回退成 UTC 立刻变红。
    func testMakeInsightsBucketsByAuthorLocalTimezone() {
        let pair = [commit("c1", localDays: 5, localHour: 23, offset: Self.eastEight),
                    commit("c2", localDays: 6, localHour: 2, offset: Self.eastEight)]
        let insights = ShellGitAnalyzer.makeInsights(commits: pair, branch: "main",
                                                     headSHA: "abc1234", remoteURL: "")
        XCTAssertEqual(insights.commitsPerPeriod.count, 2,
                       "分析器产出的日桶数：期望 2（当地），实得 \(counts(insights.commitsPerPeriod))")
        XCTAssertEqual(counts(insights.commitsPerPeriod), [1, 1])
        XCTAssertEqual(insights.commitsPerPeriod.map(\.granularity), [.day, .day], "14 小时跨度按日分桶")
        // 同一批输入在 UTC 日历下只有 1 桶，所以"两个桶"这件事只可能来自修好的接线。
        XCTAssertEqual(GitAggregation.buckets(from: pair, granularity: .day,
                                              calendar: GitAggregation.utcCalendar()).count, 1,
                       "对照口径失效，本条断言将失去意义")
    }

    func testWeekBucketFollowsAuthorLocalMonday() {
        // 当地 2026-09-21（周一）03:00 +08:00 = 2026-09-20 19:00Z：UTC 口径会把它算进**上一周**。
        let one = [commit("w1", localDays: 7, localHour: 3, offset: Self.eastEight)]
        let local = GitAggregation.buckets(from: one, granularity: .week,
                                           calendar: GitAggregation.authorCalendar(for: one))
        let utc = GitAggregation.buckets(from: one, granularity: .week,
                                         calendar: GitAggregation.utcCalendar())
        XCTAssertEqual(local.count, 1, "分母为 0 就是假零")
        // 手算：ISO 周起点 = 2026-09-21T00:00+08:00 = 周一锚点 + 7 天 - 8 小时。
        XCTAssertEqual(local[0].date.timeIntervalSince1970,
                       Self.mondayUTC + 7 * 86_400 - Double(Self.eastEight), accuracy: 0.5,
                       "周桶起点必须是当地的周一零点")
        // 旧口径落在上一周（2026-09-14T00:00Z 那一格），差整整 7 天。
        XCTAssertEqual(utc[0].date.timeIntervalSince1970, Self.mondayUTC, accuracy: 0.5,
                       "UTC 口径把周一凌晨归到上一周，这才是原来的错样子")
    }

    func testMonthBucketFollowsAuthorLocalCalendarMonth() {
        // 当地 2026-10-01 00:00 +08:00 = 2026-09-30 16:00Z：UTC 口径会把它归进 9 月。
        let one = [commit("m1", localDays: 17, localHour: 0, offset: Self.eastEight)]
        let local = GitAggregation.buckets(from: one, granularity: .month,
                                           calendar: GitAggregation.authorCalendar(for: one))
        let utc = GitAggregation.buckets(from: one, granularity: .month,
                                         calendar: GitAggregation.utcCalendar())
        XCTAssertEqual(local.count, 1, "分母为 0 就是假零")
        // 手算：当地月首 = 2026-10-01T00:00+08:00 = 周一锚点 + 17 天 - 8 小时。
        XCTAssertEqual(local[0].date.timeIntervalSince1970,
                       Self.mondayUTC + 17 * 86_400 - Double(Self.eastEight), accuracy: 0.5,
                       "月桶起点必须是当地的月初零点")
        // 旧口径给的是 2026-09-01T00:00Z = 周一锚点 - 13 天。
        XCTAssertEqual(utc[0].date.timeIntervalSince1970, Self.mondayUTC - 13 * 86_400, accuracy: 0.5,
                       "UTC 口径把 10 月的头一天算进 9 月")
        XCTAssertGreaterThan(local[0].date, utc[0].date)
    }

    func testInteriorGapStillZeroFilledOnAuthorLocalGrid() {
        let trio = [commit("g1", localDays: 0, localHour: 23, offset: Self.eastEight),
                    commit("g2", localDays: 1, localHour: 23, offset: Self.eastEight),
                    commit("g3", localDays: 3, localHour: 1, offset: Self.eastEight)]
        let buckets = GitAggregation.buckets(from: trio, granularity: .day,
                                             calendar: GitAggregation.authorCalendar(for: trio))
        XCTAssertEqual(counts(buckets), [1, 1, 0, 1], "空那天必须补 0 桶，实得 \(counts(buckets))")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.commits }, trio.count, "补桶不许造出提交")
        XCTAssertTrue(buckets.enumerated().dropFirst().allSatisfy { index, bucket in
            bucket.date > buckets[index - 1].date
        }, "桶按时间严格升序")
    }

    /// `fillLimit = 120` 的语义原样：跨度 120 桶照补、121 桶只出不空桶。
    func testFillLimitSemanticsUnchanged() {
        let exactlyLimit = [commit("f1", localDays: 0, localHour: 9, offset: Self.eastEight),
                            commit("f2", localDays: 119, localHour: 9, offset: Self.eastEight)]
        let filled = GitAggregation.buckets(from: exactlyLimit, granularity: .day,
                                            calendar: GitAggregation.authorCalendar(for: exactlyLimit))
        XCTAssertEqual(filled.count, 120, "120 桶以内照旧补空，实得 \(filled.count)")
        XCTAssertEqual(filled.filter { $0.commits == 0 }.count, 118, "补出来的必须全是 0 提交桶")

        let overLimit = [commit("f1", localDays: 0, localHour: 9, offset: Self.eastEight),
                         commit("f2", localDays: 120, localHour: 9, offset: Self.eastEight)]
        let sparse = GitAggregation.buckets(from: overLimit, granularity: .day,
                                            calendar: GitAggregation.authorCalendar(for: overLimit))
        XCTAssertEqual(sparse.count, 2, "超出 fillLimit 后只出非空桶，实得 \(sparse.count)")
        XCTAssertEqual(counts(sparse), [1, 1])
    }

    func testDominantOffsetUsesMajorityAndStaysDeterministic() {
        let mixed = [commit("a1", localDays: 0, localHour: 9, offset: Self.eastEight),
                     commit("a2", localDays: 1, localHour: 9, offset: Self.eastEight),
                     commit("a3", localDays: 2, localHour: 9, offset: Self.eastEight),
                     commit("b1", localDays: 3, localHour: 9, offset: Self.westFive)]
        XCTAssertEqual(GitAggregation.dominantAuthorOffset(of: mixed), Self.eastEight,
                       "多数人的时区就是这批提交的『当地』")
        XCTAssertEqual(GitAggregation.dominantAuthorOffset(of: mixed.reversed()), Self.eastEight,
                       "输入顺序不得改变结论")
        XCTAssertEqual(GitAggregation.authorCalendar(for: mixed).timeZone.secondsFromGMT(),
                       Self.eastEight, "日历必须真的带上了这个偏移")
        XCTAssertNil(GitAggregation.dominantAuthorOffset(of: []), "没有提交就没有作者时区")
        XCTAssertEqual(GitAggregation.authorCalendar(for: []).timeZone.secondsFromGMT(), 0,
                       "空输入退回 UTC 中立格点（此时也不会有桶）")
    }

    /// 并列时靠"更接近 UTC、再取更小的有符号值"打破，且**永远同一个结果**。
    func testDominantOffsetTieBreakIsATotalOrder() {
        let tie = [commit("e1", localDays: 0, localHour: 5, offset: 3_600),
                   commit("w1", localDays: 0, localHour: 5, offset: -3_600)]
        XCTAssertEqual(GitAggregation.dominantAuthorOffset(of: tie), -3_600,
                       "计数并列、距 UTC 等距时取有符号值更小的那个")
        let threeWay = [commit("z1", localDays: 0, localHour: 5, offset: 7_200),
                        commit("z2", localDays: 1, localHour: 5, offset: -7_200),
                        commit("z3", localDays: 2, localHour: 5, offset: 0)]
        XCTAssertEqual(GitAggregation.dominantAuthorOffset(of: threeWay), 0,
                       "三方并列时取最接近 UTC 的 0")
    }

    /// 跨时区仓库：桶键必须仍落在同一把格子上，**一条提交都不许从趋势里消失**。
    /// 这是"每条提交各按自己偏移切"那个方案被否掉的直接原因。
    func testMixedOffsetRepositoryKeepsEveryCommit() {
        var commits: [ParsedCommit] = []
        for day in 0..<6 {
            commits.append(commit("e\(day)", localDays: day, localHour: 23, offset: Self.eastEight))
        }
        // 少数派的 -05:00 本地第 4 天凌晨，落进主导（+08:00）格子的第 4 天。
        commits.append(commit("w9", localDays: 4, localHour: 2, offset: Self.westFive))
        let buckets = GitAggregation.buckets(from: commits, granularity: .day,
                                             calendar: GitAggregation.authorCalendar(for: commits))
        XCTAssertFalse(buckets.isEmpty, "分母为 0 就是假零")
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.commits }, commits.count,
                       "分桶之和必须等于提交数，实得 \(counts(buckets))（有人掉出趋势了）")
        XCTAssertEqual(counts(buckets), [1, 1, 1, 1, 2, 1],
                       "6 个当地日全在格子上，少数派并进同号格，不许冒出 0 提交空桶")
        XCTAssertEqual(buckets.map { $0.date.timeIntervalSince1970 }.sorted(),
                       buckets.map { $0.date.timeIntervalSince1970 }, "输出必须已按时间排序")
    }

    /// 畸形偏移不许崩、也不许丢提交（`dominantAuthorOffset` 照实上报，日历侧自行兜底）。
    func testAbsurdAuthorOffsetDegradesSafely() {
        let weird = [commit("x1", localDays: 0, localHour: 3, offset: 90_000),
                     commit("x2", localDays: 1, localHour: 3, offset: 90_000)]
        XCTAssertEqual(GitAggregation.dominantAuthorOffset(of: weird), 90_000,
                       "偏移选取必须照实上报，兜底发生在日历那一层")
        let buckets = GitAggregation.buckets(from: weird, granularity: .day,
                                             calendar: GitAggregation.authorCalendar(for: weird))
        XCTAssertEqual(buckets.reduce(0) { $0 + $1.commits }, weird.count, "畸形偏移也不许丢提交")
        XCTAssertEqual(counts(buckets), [1, 1], "两条相隔整天的提交仍各占一格")
        XCTAssertEqual(GitAggregation.buckets(from: [], granularity: .day,
                                              calendar: GitAggregation.authorCalendar(for: [])), [],
                       "空输入返回空数组")
    }

}
