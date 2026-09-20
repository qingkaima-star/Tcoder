import XCTest
@testable import TcoderMonitor

/// 总工亲自补的两条评分诚实性回归（缺陷 #44 / #46）。
///
/// 两条都不是"算错数"，而是**把没有的证据当成好的证据计分**：
/// - #44：作者集中度用「非合并作者提交 ÷ 含合并总提交」，本仓实测把 91.4% 报成 51%，
///   于是单点风险从 `.high` 掉到 `.medium`，协作分布分量白拿分。
/// - #46：一行日志都没扫到时，运行稳定性按默认值 85 计入，而它是全表**权重最高**的一项
///   （0.178），等于凭空贡献 15.1 分；同页的依赖健康与测试覆盖在无数据时是直接缺席的。
///
/// 夹具继承 WS-C 的 `HealthScoreTestCase`，只读复用，不改它任何一条既有期望。
final class HealthEvidenceAbsenceTests: HealthScoreTestCase {

    /// 本仓（Tcoder 扫自己）在 `9757722` 上的真实形状：作者表 152 次、榜首 139 次、含合并 271 次。
    private func singlePointGit() -> GitInsights {
        let first = Date(timeIntervalSinceNow: -40 * 86_400)
        let last = Date(timeIntervalSinceNow: -2 * 86_400)
        return GitInsights(
            isRepository: true,
            branch: "main",
            headSHA: String(repeating: "c", count: 40),
            totalCommits: 271,
            firstCommitAt: first,
            lastCommitAt: last,
            projectAgeDays: 40,
            totalAdditions: 65_787,
            totalDeletions: 22_973,
            filesTouched: 300,
            authors: [
                author(name: "lead", commits: 139, first: first, last: last),
                author(name: "peer", commits: 13, first: first, last: last),
            ]
        )
    }

    // MARK: - #44 分母必须与分子同一个总体

    func testAuthorBasisSumsTheAuthorTableNotTheCommitCount() {
        let git = singlePointGit()
        XCTAssertEqual(git.authorBasisCommits, 152,
                       "作者表求和就是非合并总体，界面与评分都必须用它当分母")
        XCTAssertNotEqual(git.authorBasisCommits, git.totalCommits,
                          "夹具若两侧相等，下面那几条断言就全都失去意义")
    }

    func testConcentrationRiskUsesAuthorBasis() {
        let git = singlePointGit()
        // 139/152 = 91.4% → .high；被 139/271 = 51.3% 误导时会掉成 .medium。
        XCTAssertEqual(git.busFactorRisk, .high,
                       "用含合并的总数当分母会把 91% 的集中度算成 51%，风险等级被腰斩")
        XCTAssertNotEqual(git.busFactorRisk, .medium)
    }

    func testCollaborationDetailNamesItsDenominator() {
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: singlePointGit()))
        guard let component = score.components.first(where: { $0.name == HealthDimension.busFactor.rawValue })
        else { return XCTFail("协作分布维度必须在场，实得 \(score.components.map(\.name))") }
        XCTAssertTrue(component.detail.contains("91%"),
                      "占比必须按非合并总体呈现，实得：\(component.detail)")
        XCTAssertTrue(component.detail.contains("非合并"),
                      "detail 必须把分母的口径写出来，实得：\(component.detail)")
        XCTAssertFalse(component.detail.contains("271"),
                       "含合并总数不该出现在这个比值旁边，实得：\(component.detail)")
    }

    // MARK: - #46 零证据不得换成分数

    func testStabilityIsAbsentRatherThanDefaultedWhenNothingScanned() {
        var blind = healthyLogs()
        blind.totalLinesScanned = 0
        blind.errorCount = 0
        blind.exceptionCount = 0
        blind.crashCount = 0
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: blind))

        XCTAssertFalse(score.components.contains { $0.name == HealthDimension.stability.rawValue },
                       "没扫到一行日志就不该有这个维度；按默认值计入等于用『没查』换分。"
                           + "实得 \(score.components.map { ($0.name, $0.score, $0.weight) })")
        XCTAssertTrue(score.recommendations.contains { $0.contains("没有可扫描的日志") },
                      "缺席必须给出原因，实得 \(score.recommendations)")
        assertWeightsNormalised(score)
        assertOverallMatchesWeightedSum(score)
    }

    /// 反向对照：真扫到日志时这个维度要在场，否则上面那条断言会因为"永远缺席"而永真绿。
    func testStabilityStillScoredWhenLogsWereScanned() {
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: healthyLogs()))
        XCTAssertTrue(score.components.contains { $0.name == HealthDimension.stability.rawValue },
                      "有证据时该维度必须回来；它不在场说明上面的缺席断言是空的")
        assertOverallMatchesWeightedSum(score)
    }

    /// 缺席而不是默认值，总分必须**下降**（本仓实测 73 → 约 70）。
    func testRemovingDefaultedStabilityLowersTheScore() {
        var blind = healthyLogs()
        blind.totalLinesScanned = 0
        let withoutEvidence = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: blind))
        let withEvidence = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: healthyLogs()))
        XCTAssertLessThan(withoutEvidence.overall, withEvidence.overall,
                          "零证据的那次必须更低——默认值 85 分曾经让它反而更高")
    }

    // MARK: - 不变量帮手

    private func assertWeightsNormalised(_ score: HealthScore, file: StaticString = #filePath, line: UInt = #line) {
        let total = score.components.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(total, 1.0, accuracy: 0.001,
                       "维度缺席后权重必须重新归一，实得 \(total)", file: file, line: line)
    }

    private func assertOverallMatchesWeightedSum(_ score: HealthScore, file: StaticString = #filePath, line: UInt = #line) {
        let sum = score.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(score.overall), sum, accuracy: 1.0,
                       "overall 必须等于 Σ(score·weight)（±1），实得 \(score.overall) vs \(sum)",
                       file: file, line: line)
    }
}
