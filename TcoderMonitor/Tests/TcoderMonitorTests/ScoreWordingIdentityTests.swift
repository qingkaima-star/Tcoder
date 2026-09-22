import Foundation
import XCTest
@testable import TcoderMonitor

/// 从 `ScoreWordingTests.swift` 拆出的一节（靶子 3c：署名 ≠ 人数），断言与判据一字未改。
/// 拆的理由只有一个：本仓那把 400 行尺子对产品侧与测试侧同源（`X3TestSizeAuditTests`），
/// 而守卫自己写的修复口径是「拆文件才是修复，改这里的数字不是」。
/// 夹具（`author` / `matureFastGit` / `packageRoot`）仍留在主文件，因此那边的
/// `private` 已放宽到 internal —— 只放宽可见性，没改任何一行取值。
extension ScoreWordingTests {

    // MARK: - 靶子 3c：署名 ≠ 人数，且不许出现"拆署名提分"这种指标游戏

    func test_authorCountsAreReportedAsIdentitiesNotHeadcount() throws {
        let curve = HealthCurves.busFactor(risk: .low, topAuthorShare: 0.3,
                                           activeAuthors: 4, commitBasis: 200)
        XCTAssertTrue(curve.detail.contains("4 个活跃署名"), "曲线要写署名：\(curve.detail)")
        XCTAssertFalse(curve.detail.contains("位活跃作者"), "实得 \(curve.detail)")

        let spread = GitInsights(totalCommits: 400, commitsAnalyzed: 400, authors: [
            author("WS-A", 100), author("WS-B", 100), author("WS-C", 100), author("WS-D", 100)
        ])
        let score = WeightedHealthScorer().score(HealthInputs(git: spread))
        let strength = try XCTUnwrap(score.strengths.first { $0.contains("贡献分布合理") },
                                     "四维各占 25% 必须能说出这句，实得 \(score.strengths)")
        XCTAssertTrue(strength.contains("4 个署名") && strength.contains("不等于 4 个人"),
                      "署名口径的诚实边界必须跟着这句一起上屏：\(strength)")
        XCTAssertFalse(strength.contains("4 人，"), "不许把身份数写成人头：\(strength)")

        let solo = WeightedHealthScorer().score(HealthInputs(git: GitInsights(
            totalCommits: 400, commitsAnalyzed: 400,
            authors: [author("Tcoder Team", 396), author("WS-B", 4)])))
        let issue = try XCTUnwrap(solo.issues.first { $0.contains("单点风险高") },
                                  "实得 \(solo.issues)")
        XCTAssertTrue(issue.contains("署名") && issue.contains("「Tcoder Team」"), "实得 \(issue)")
        XCTAssertFalse(issue.contains("一人承担"), "被点出的是一个署名，不是一个人：\(issue)")
    }

    /// 指标游戏禁令：评分侧任何文案都不许说"改署名/拆署名来提分"。
    /// 元测试同批给出（坏样例必须能被这三个模式抓到），否则这条就是一条永真绿。
    func test_noCopySuggestsGamingTheIdentityMetric() throws {
        let banned = ["拆分署名", "拆成多个署名", "多开署名", "增加署名数", "提升评分", "把分提上去"]
        let files = ["Services/Health/ScoreCurves.swift",
                     "Services/Health/ScoreCurvesTeamRuntime.swift",
                     "Services/Health/HealthTeamDimensions.swift",
                     "Services/Health/HealthCodeDimensions.swift",
                     "Services/Health/HealthRuntimeDimensions.swift",
                     "Services/Health/WeightedHealthScorer.swift",
                     "Views/Health/HealthComponentTable.swift",
                     "Views/Health/HealthAdviceCards.swift",
                     "Views/Health/HealthView.swift"]
        var scanned = 0
        for file in files {
            let url = Self.packageRoot.appendingPathComponent("Sources/TcoderMonitor/" + file)
            guard let raw = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            let source = Self.strippingComments(raw)
            for pattern in banned {
                XCTAssertFalse(source.contains(pattern), "\(file) 出现指标游戏措辞「\(pattern)」")
            }
        }
        XCTAssertEqual(scanned, files.count, "有文件读不到：这条判据的分母缩水了")
        let sabotage = Self.strippingComments("// 建议：把提交拆成多个署名以\n增加署名数就能提升评分")
        XCTAssertTrue(sabotage.contains("增加署名数") && sabotage.contains("提升评分"),
                      "坏样例改不出来 = 这三个模式是摆设")
    }
}
