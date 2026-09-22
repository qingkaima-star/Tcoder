/// OWNER: WS-R9 评分口径与措辞（分支 `ws/r9-wording`）—— 工单 R9 三条靶子的守卫。
///
/// 判据对象是**评分口径与措辞**，不是分值：本文件不许出现"分数应该更高/更低"的断言，
/// 也不钉任何阈值数字（阈值与权重都在冻结口径里，本流一个字节没改）。
///
/// 靶子 1（RD-29）：`HealthCurves.busFactor` 的 `commitBasis == 0` 那一支原先给
/// `score 70 + 「提交记录过少，暂不评估协作分布」` —— 话说不评估、数照进加权。
/// 先证可达性（见下面 `test_zeroAuthorBasis…` 与 Obsidian `121`），再把占位分摘掉：
/// 「没有可算作者分布的总体」由 `WeightedHealthScorer.busFactorOutcome` 判成**整维缺席**，
/// 走 `HealthBreakdown.missingDimensions` 那条已存在的路，并把原因显示到界面上。
///
/// 四态各自可观测：正例（有总体照常计分）/ 反例（0 总体必须缺席）/
/// 未知（`git == nil`：不是仓库）/ 失败（`failedSections` 含「Git 分析」）。
import XCTest
@testable import TcoderMonitor

final class ScoreWordingTests: HealthScoreTestCase {

    private var busFactorName: String { HealthDimension.busFactor.rawValue }
    private var activityName: String { HealthDimension.activity.rawValue }

    /// 作者表为空、但仓库有提交（含合并口径）—— 靶子 1 的输入形状。
    private func gitWithoutAuthorBasis(commits: Int = 5) -> GitInsights {
        var git = GitInsights(totalCommits: commits, commitsAnalyzed: commits)
        git.authors = []
        return git
    }

    private func report(git: GitInsights?, failed: [String] = []) -> ProjectReport {
        var report = ProjectReport(project: MonitoredProject(name: "r9", path: "/tmp/r9"))
        report.git = git
        report.attemptedAt = Date()
        report.failedSections = failed
        return report
    }

    // MARK: - ① 反例：0 总体 ⇒ 整维缺席，且不进加权

    func test_zeroAuthorBasis_absentsTheWholeDimensionInsteadOfScoringAPlaceholder() throws {
        let score = WeightedHealthScorer().score(HealthInputs(git: gitWithoutAuthorBasis()))

        XCTAssertFalse(score.components.contains { $0.name == busFactorName },
                       "协作分布必须整维缺席，不许带一个占位分参与加权")
        XCTAssertTrue(HealthBreakdown.missingDimensions(of: score).contains(.busFactor),
                      "缺席要能在 missingDimensions 里被点名（界面与 CLI 都读这一份）")
        XCTAssertTrue(score.recommendations.contains { $0.contains("协作分布不参与本次计分") },
                      "缺席还要出声：实得 \(score.recommendations)")

        // 独立真值：只有活跃度在场时，综合分只能等于活跃度自己 —— 没有任何东西替它抬一手。
        let activity = try XCTUnwrap(score.components.first { $0.name == activityName })
        XCTAssertEqual(score.overall, activity.score,
                       "综合分被没证据的那一维动过了：overall \(score.overall) vs 在场项 \(activity.score)")
        XCTAssertTrue(HealthBreakdown.isSumConsistent(HealthBreakdown.sumOfContributions(
            HealthBreakdown.rows(for: score)), with: score.overall))
    }

    // MARK: - ② 曲线本体：70 那个占位分不许回来

    func test_busFactorCurve_noLongerReturnsTheSeventyPlaceholder() {
        let guardCase = HealthCurves.busFactor(risk: .none, topAuthorShare: 0,
                                               activeAuthors: 0, commitBasis: 0)
        XCTAssertNotEqual(guardCase.score, 70, "「暂不评估」不配有一个进加权的数")
        XCTAssertTrue(guardCase.detail.contains("不该计分"),
                      "死支必须自报「这不是评估结果」：\(guardCase.detail)")
        XCTAssertEqual(guardCase.risk, .critical,
                       "万一守卫被改动，宁可当场砸出一个显眼的低分，也不许悄悄抬一手")
        assertCurveIsValid(guardCase, context: "busFactor 无总体（内部守卫）")

        // 负数同样不许走正常计分
        let negative = HealthCurves.busFactor(risk: .low, topAuthorShare: 0.5,
                                              activeAuthors: 2, commitBasis: -3)
        XCTAssertEqual(negative.score, guardCase.score, "负总体必须与零总体同一处理")
    }

    /// 反例的边界：有一笔总体时**不许**被新守卫顺手摘掉（否则就是往判死方向改口径）。
    func test_singleCommitBasis_isStillScored() {
        let curve = HealthCurves.busFactor(risk: .low, topAuthorShare: 1.0,
                                           activeAuthors: 1, commitBasis: 1)
        XCTAssertGreaterThan(curve.score, 0, "一笔总体虽然单薄，但它是证据，不能按没证据处理")
        XCTAssertTrue(curve.detail.contains("1 次非合并提交"),
                      "总体只有 1 笔时必须把分母写在脸上：\(curve.detail)")
    }

    // MARK: - ③ 上屏：这一维为什么不参与计分，要看得见

    func test_missingReason_namesTheNoAuthorBasisCase() {
        let text = MissingDimensionReason.text(for: .busFactor, report: report(git: gitWithoutAuthorBasis()))
        XCTAssertTrue(text.contains("非合并") && text.contains("不参与计分"),
                      "第③档要说出「没有可算总体」，不许落到兜底句：\(text)")
    }

    /// 未知态：压根不是仓库（`git == nil`）时不许套用第③档那句话。
    func test_missingReason_forNonRepositoryStaysDistinct() {
        let text = MissingDimensionReason.text(for: .busFactor, report: report(git: nil))
        XCTAssertTrue(text.contains("不是 Git 仓库"), "实得 \(text)")
        XCTAssertFalse(text.contains("非合并"), "没取到历史与没有总体是两件事，不许混成一句")
    }

    /// 零提交仓库：是仓库、但一笔提交都没有 —— 第②档。
    func test_missingReason_forEmptyRepository() {
        let text = MissingDimensionReason.text(for: .busFactor,
                                               report: report(git: GitInsights(totalCommits: 0)))
        XCTAssertTrue(text.contains("没有任何提交"), "实得 \(text)")
    }

    /// 失败态：整路分析器报过失败时，原因必须是"那一路失败了"，不是"这一维没总体"。
    func test_missingReason_whenGitAnalyzerFailed() {
        let text = MissingDimensionReason.text(for: .busFactor,
                                               report: report(git: gitWithoutAuthorBasis(), failed: ["Git 分析"]))
        XCTAssertTrue(text.contains("失败"), "实得 \(text)")
    }

    // MARK: - ④ 可达性钉子：死支不许被改活

    /// `HealthCurves.busFactor` 的 0 总体那一支只剩"内部守卫"一个用途，所以它**必须**不可达：
    /// 唯一的生产调用点在 `HealthTeamDimensions.busFactorOutcome`，那里已经先判
    /// `authorBasisCommits > 0`。这条判据读的是源码形状 —— 一旦有人加第二个调用点
    /// 而不再先判总体，它就红（这正是它存在的理由：可达路径一变就响）。
    ///
    /// ⚠ **先剥注释再判**（与 `SourceFileReachabilityTests` 同一立场）：本流在调用点旁边
    /// 写了"旧写法是 `max(…, 1)`"这样的历史说明，不剥注释就会让第一条守卫被自己的注释骗过去、
    /// 第二条被自己的注释冤枉成红（实测踩过一次，红的是这条）。
    func test_busFactorCurveCallSiteIsStillGuardedByAnExplicitBasisCheck() throws {
        let path = Self.packageRoot.appendingPathComponent(
            "Sources/TcoderMonitor/Services/Health/HealthTeamDimensions.swift").path
        let raw = try String(contentsOfFile: path, encoding: .utf8)
        let source = Self.strippingComments(raw)
        let callAt = try XCTUnwrap(source.range(of: "HealthCurves.busFactor("),
                                   "调用点没了 —— 那这条判据的对象就变了，请连本流结论一起更新")
        let beforeCall = String(source[source.startIndex..<callAt.lowerBound])
        XCTAssertTrue(beforeCall.contains("git.authorBasisCommits > 0"),
                      "调用点前面的 `authorBasisCommits > 0` 守卫不见了 ⇒ 0 总体又能进加权")
        XCTAssertFalse(source.contains("max(git.authorBasisCommits, 1)"),
                       "把 0 折成 1 的伪装又回来了：一条记录不能冒充一个分布")
    }

    /// 行注释与块注释都剥掉，只留真代码。
    static func strippingComments(_ source: String) -> String {
        let block = try! NSRegularExpression(pattern: #"/\*.*?\*/"#, options: [.dotMatchesLineSeparators])
        let range = NSRange(source.startIndex..., in: source)
        let withoutBlocks = block.stringByReplacingMatches(in: source, options: [],
                                                           range: range, withTemplate: "")
        return withoutBlocks.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            guard let slash = line.range(of: "//") else { return String(line) }
            return String(line[..<slash.lowerBound])
        }.joined(separator: "\n")
    }

    /// 分母自证：上面那条"读源码"的判据不是永真绿 —— 剥注释这件事本身要能被证伪。
    func test_reachabilityGuardActuallyLooksAtSomething() throws {
        let sample = """
        // 旧写法是 max(git.authorBasisCommits, 1)，把 0 折成 1
        guard let top = git.topAuthor, git.authorBasisCommits > 0 else { return .absent }
        let curve = HealthCurves.busFactor(risk: git.busFactorRisk, topAuthorShare: share, commitBasis: basis)
        """
        let stripped = Self.strippingComments(sample)
        XCTAssertFalse(stripped.contains("max(git.authorBasisCommits, 1)"),
                       "注释没剥掉：那条断言会被自己写的历史说明冤枉成红")
        XCTAssertTrue(stripped.contains("git.authorBasisCommits > 0"), "真代码被剥没了：扫描器读不到东西")
        let sabotaged = stripped.replacingOccurrences(of: "git.authorBasisCommits > 0", with: "true")
        XCTAssertFalse(sabotaged.contains("git.authorBasisCommits > 0"),
                       "这条元测试坏了（改坏样例改不出红），上面的守卫就是永真绿")
    }

    // MARK: - 夹具

    static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }
}
