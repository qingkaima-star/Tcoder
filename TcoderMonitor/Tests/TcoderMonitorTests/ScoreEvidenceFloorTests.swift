/// OWNER: WS-R9b 证据下限与死支清理（分支 `ws/r9-wording`）—— 工单 §2 与 §4 的守卫。
///
/// 两把尺子都只管一件事：**证据不够的时候不许给分、也不许按 0 计入**。
/// 两个数值都不是挑出来的，推导写在源码注释里，本文件把推导本身当断言对象：
///
/// * 运行稳定性的证据下限 `StabilityEvidence.minimumLogLines` = 2,000 真日志行 ——
///   来自「一次错误的密度量子 1000/N 不得跨过曲线的最小台阶 0.5 每千行」；
/// * 协作分布的最小总体 `BusFactorEvidence.minimumCommitBasisForShare` = 7 笔非合并提交 ——
///   来自「一笔提交折合 1/N 占比、不得跨过曲线最窄的一档 0.15」。
///
/// ⚠ 本文件不许出现「分数应该更高/更低」的断言：两条地板的方向都是把分打掉（封顶 / 缺席），
/// 「只压不抬」与「不许洗白单点风险」各有一条反例专门盯着。
/// 死支删除之后，「不许凭空给分」这条不变式由两件事一起钉：
/// `ScoreWordingTests` 的调用点可达性钉子 + 本文件的占位分回潮扫描。
import XCTest
@testable import TcoderMonitor

final class ScoreEvidenceFloorTests: HealthScoreTestCase {

    private var stabilityName: String { HealthDimension.stability.rawValue }
    private var busFactorName: String { HealthDimension.busFactor.rawValue }

    // MARK: - 夹具（真值全部手写死，不取自实现输出）

    private func logFixture(lines: Int, errors: Int = 0, crashes: Int = 0) -> LogSummary {
        LogSummary(scannedFiles: lines > 0
            ? [ScannedLogFile(path: "/fixture/app.log", sizeBytes: Int64(lines) * 40,
                              lineCount: lines, modifiedAt: Date(), role: .application)] : [],
            errorCount: errors, crashCount: crashes, totalLinesScanned: lines)
    }

    private func stabilityScore(_ logs: LogSummary) -> HealthScore {
        WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: logs))
    }

    private func stabilityComponent(_ logs: LogSummary) -> ScoreComponent? {
        stabilityScore(logs).components.first { $0.name == stabilityName }
    }

    /// 作者表是我手写的：总体 = 这些数之和，占比我自己算。
    private func git(_ shares: [(String, Int)]) -> GitInsights {
        let total = shares.reduce(0) { $0 + $1.1 }
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        let last = Date(timeIntervalSince1970: 1_760_000_000)
        return GitInsights(totalCommits: total, commitsAnalyzed: total, firstCommitAt: first, lastCommitAt: last,
                           authors: shares.map { author(name: $0.0, commits: $0.1, first: first, last: last) })
    }

    // MARK: - ① 推导本身是断言对象（运行稳定性）

    /// 2,000 这条线是算出来的：一笔错误的量子跨过最小台阶 0.5 的那个 N 就是它。
    func test_minimumLogLinesIsDerivedFromTheErrorQuantum() {
        let step = StabilityEvidence.finestDensityStepPerKiloLogLines
        XCTAssertEqual(StabilityEvidence.minimumLogLines, Int(1_000 / step),
                       "下限与它自己那两条前提不再等价 ⇒ 这个数是挑的，不是推的")
        XCTAssertGreaterThan(StabilityEvidence.errorQuantumPerKilo(logLines: 1_999), step,
                             "边界反例：1,999 行时一次错误就跨过最小台阶")
        XCTAssertLessThanOrEqual(StabilityEvidence.errorQuantumPerKilo(logLines: 2_000), step,
                                 "边界正例：2,000 行时一次错误正好落在台阶上、不越过去")
        XCTAssertTrue(StabilityEvidence.errorQuantumPerKilo(logLines: 0).isInfinite,
                      "零行日志的量子必须无定义，不许读成一个可以参加比较的数")
    }

    /// 台阶尺子必须与曲线锚点表同源：锚点被改而下限没重推 ⇒ 立刻红。
    func test_finestStepStillMatchesTheCurveAnchorTable() throws {
        let source = try strippedHealthSource("ScoreCurvesTeamRuntime.swift")
        let gaps = try StabilityAnchorProbe.anchorGaps(in: source, function: "stability")
        XCTAssertEqual(gaps.min(), StabilityEvidence.finestDensityStepPerKiloLogLines,
                       "曲线最小台阶已不是 \(StabilityEvidence.finestDensityStepPerKiloLogLines)，"
                        + "证据下限必须重新推导")
    }

    /// 元测试：上面那条扫描不是永真绿 —— 合成一份改坏的锚点表，它必须数出不同的台阶。
    func test_anchorGapProbeActuallyReadsTheTable() throws {
        let tampered = """
        static func piecewise(_ x: Double) -> Double {
            ScoreCurve.piecewise(x, through: [
                (x: 0, score: 100), (x: 0.25, score: 96), (x: 6, score: 32), (x: 25, score: 0)
            ])
        }
        """
        let gaps = try StabilityAnchorProbe.anchorGaps(in: tampered, function: "piecewise")
        XCTAssertEqual(gaps.min(), 0.25, "探针读不到被改坏的锚点表 ⇒ 上一条守卫是假绿")
        XCTAssertNotEqual(gaps.min(), StabilityEvidence.finestDensityStepPerKiloLogLines)
    }

    // MARK: - ② 修前可复现的反例：3 行空日志不再等于满分

    /// 工单 §2 的现场：3 行空日志 ⇒ 每千行 0 个错误 ⇒ 曲线满分（实测综合分 66 → 81）。
    /// 修后这一维仍出分，但被封顶到「普通稳定仓库的水位」，并上屏写明「未判定」。
    func test_threeEmptyLinesNoLongerBuyAFullScore() throws {
        let thin = try XCTUnwrap(stabilityComponent(logFixture(lines: 3)))
        XCTAssertEqual(thin.score, Int(StabilityEvidence.thinEvidenceScoreCeiling),
                       "薄证据必须被压到封顶值，实得 \(thin.score)")
        XCTAssertLessThan(thin.score, 100, "「3 行没出错」不配与「跑了半年没出错」拿同一个数")
        XCTAssertTrue(thin.detail.contains("证据太薄·未判定"), "降档要上屏：\(thin.detail)")
        XCTAssertTrue(thin.detail.contains("2,000 行") || thin.detail.contains("2000 行"),
                      "下限值要点名，不许只说样本不足：\(thin.detail)")

        let score = stabilityScore(logFixture(lines: 3))
        XCTAssertTrue(score.recommendations.contains { $0.contains("证据太薄") },
                      "降档理由要进建议，实得 \(score.recommendations)")
        XCTAssertFalse(score.strengths.contains { $0.contains("未见确认崩溃") },
                       "同一道下限必须管住优点句（工单 §2 末段）：3 行不配零错误背书，实得 \(score.strengths)")
    }

    /// 边界上下各一份：1,999 行封顶、2,000 行出分并写明分母。
    func test_floorBoundaryHoldsOnBothSides() throws {
        let below = try XCTUnwrap(stabilityComponent(logFixture(lines: 1_999)))
        let at = try XCTUnwrap(stabilityComponent(logFixture(lines: 2_000)))
        XCTAssertEqual(below.score, Int(StabilityEvidence.thinEvidenceScoreCeiling))
        XCTAssertGreaterThan(at.score, below.score, "恰好等于下限还不放行 ⇒ 这条线画在了两侧都缺席的地方")
        XCTAssertFalse(at.detail.contains("证据太薄"), "够线了仍标未判定 = 把判据写成常驻免责声明：\(at.detail)")
        XCTAssertTrue(at.detail.contains("2,000") || at.detail.contains("2000"),
                      "出分时要把分母写在脸上：\(at.detail)")
    }

    /// 第三组夹具（正常体量）：1 万行零错误本来就是满分，加了地板之后一字不动。
    func test_normalVolumeIsUntouchedByTheFloor() throws {
        let healthy = try XCTUnwrap(stabilityComponent(logFixture(lines: 10_000)))
        XCTAssertFalse(healthy.detail.contains("证据太薄"))
        XCTAssertEqual(healthy.score, 100, "地板只管薄证据，够量的读数不许被它碰到")
    }

    /// 封顶**只会压低**：4 次确认崩溃本来已经把读数打到 60 以下，封顶必须是空操作；
    /// 但「证据太薄·未判定」照样上屏 —— 薄是真、分低也是真，两件事不互相抵消。
    func test_capOnlyLowersAndNeverRaisesABadReading() throws {
        let crashing = try XCTUnwrap(stabilityComponent(logFixture(lines: 500, crashes: 4)))
        XCTAssertLessThan(crashing.score, Int(StabilityEvidence.thinEvidenceScoreCeiling),
                          "夹具没落进封顶区 ⇒ 这条判据测不到只压不抬")
        XCTAssertLessThanOrEqual(crashing.score, 52, "4 次确认崩溃的扣分不许被封顶抬回去")
        XCTAssertTrue(crashing.detail.contains("证据太薄·未判定"), "标记与封顶分开判：\(crashing.detail)")
        XCTAssertTrue(crashing.detail.contains("确认崩溃 4 次"), "分子侧一行不许动：\(crashing.detail)")
    }

    // MARK: - ③ 死支删除之后，「不许凭空给分」靠什么钉住

    /// 曲线本体不许再有任何「没扫到日志」的占位分（85 那一支已删，回潮即红）。
    /// 读的是**剥注释之后**的源码 —— 本流在调用点旁边写了历史说明，不剥就会被自己冤枉。
    func test_curveHasNoDefaultPlaceholderScoreLeftBehind() throws {
        let source = try strippedHealthSource("ScoreCurvesTeamRuntime.swift")
        XCTAssertFalse(source.contains("按默认值计"),
                       "那句占位文案回来了 ⇒ 零分母又能换 15.1 分（缺陷 #46 复活）")
        XCTAssertFalse(source.contains("totalLinesScanned == 0"),
                       "曲线里又出现按行数兜底的分支 ⇒ 出口归属从调用点搬回曲线，判据要重谈")
    }

    /// 元测试：这条扫描不是永真绿 —— 把那句写回一份合成源码，它必须抓得到。
    func test_placeholderScanIsNotPermanentlyGreen() {
        let sabotaged = Self.strippingComments("""
        static func stability(totalLinesScanned: Int) -> CurveResult {
            if totalLinesScanned == 0 {
                return CurveResult(score: 85, detail: "未扫描到运行日志，本维度按默认值计")
            }
        }
        """)
        XCTAssertTrue(sabotaged.contains("按默认值计"))
        XCTAssertTrue(sabotaged.contains("totalLinesScanned == 0"))
    }

    /// 零分母那一支必须仍然走三态判据（硬线 2：三种样子不许混成一种）。
    func test_zeroDenominatorBranchRoutesThroughTheThreeStateProbe() throws {
        let source = try strippedHealthSource("HealthRuntimeDimensions.swift")
        let guardAt = try XCTUnwrap(source.range(of: "guard logs.totalLinesScanned > 0 else"),
                                    "零行那道 guard 没了 ⇒ 三态出口的地基变了")
        let end = source.index(guardAt.upperBound, offsetBy: 200, limitedBy: source.endIndex) ?? source.endIndex
        XCTAssertTrue(source[guardAt.upperBound..<end].contains("StabilityAdvice.noDenominatorAdvice"),
                      "零分母那一支不走三态判据了 ⇒ 三种输入又要被挤成一句话")
    }

    // MARK: - ④ 最小总体（协作分布）：推导 + 边界两侧

    func test_minimumCommitBasisIsDerivedFromTheNarrowestBand() {
        XCTAssertEqual(BusFactorEvidence.minimumCommitBasisForShare,
                       Int((1 / BusFactorEvidence.narrowestShareBand).rounded(.up)),
                       "总体下限与它的两条前提不再等价 ⇒ 这个数是挑的")
        XCTAssertGreaterThan(BusFactorEvidence.shareSwing(commitBasis: 6),
                             BusFactorEvidence.narrowestShareBand, "边界反例：6 笔时一笔就能跨档")
        XCTAssertLessThanOrEqual(BusFactorEvidence.shareSwing(commitBasis: 7),
                                 BusFactorEvidence.narrowestShareBand, "边界正例：7 笔时一笔跨不过最窄档")
    }

    /// 反例：总体恰好在下限之下 ⇒ 整维缺席、不进加权、不按 0 计入，理由点名三个数。
    func test_populationJustBelowTheFloorAbsentsTheDimension() {
        let smallGit = git([("甲", 4), ("乙", 2)])
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: smallGit))
        XCTAssertFalse(score.components.contains { $0.name == busFactorName },
                       "6 笔总体不配一个占比读数")
        XCTAssertTrue(HealthBreakdown.missingDimensions(of: score).contains(.busFactor))
        XCTAssertTrue(score.recommendations.contains { $0.contains("占比无定义") },
                      "缺席要说出为什么无定义，实得 \(score.recommendations)")
        var report = ProjectReport(project: MonitoredProject(name: "r9b", path: "/tmp/r9b"))
        report.git = smallGit
        let reason = MissingDimensionReason.text(for: .busFactor, report: report)
        XCTAssertTrue(reason.contains("6 笔") && reason.contains("2 个活跃署名"),
                      "界面那句必须点名 commitBasis 与 activeAuthorCount：\(reason)")
        XCTAssertTrue(HealthBreakdown.isSumConsistent(
            HealthBreakdown.sumOfContributions(HealthBreakdown.rows(for: score)), with: score.overall))
    }

    /// 正例：恰好等于下限 ⇒ 出分，并把口径（按几笔统计）写在脸上。
    func test_populationExactlyAtTheFloorIsScoredAndStatesItsBasis() throws {
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(),
                                                              git: git([("甲", 4), ("乙", 3)])))
        let component = try XCTUnwrap(score.components.first { $0.name == busFactorName })
        XCTAssertTrue(component.detail.contains("7 次非合并提交"),
                      "出分时必须写明本维按几笔统计：\(component.detail)")
    }

    /// 反例（专防地板洗白单点风险）：**单人**再小的总体也照常出分并且仍是低分。
    func test_floorCannotWashOutSingleAuthorRisk() throws {
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: git([("甲", 3)])))
        let component = try XCTUnwrap(score.components.first { $0.name == busFactorName },
                                      "单人 3 笔被地板兜成缺席 ⇒ 全表最真实的那条风险被洗掉")
        XCTAssertFalse(score.recommendations.contains { $0.contains("占比无定义") },
                       "单人谈不上占比无定义：全部提交都在一个署名上就是 100%")
        XCTAssertLessThan(component.score, 40, "单人包揽必须仍是低分，实得 \(component.score)")
    }

    /// `commitBasis == 0` 的 R9 fail-loud 口径不许被新地板抢先兜住（工单 §4.4）。
    /// 夹具形状是"仓库有提交、作者表是空的"（含合并口径 5 笔）—— 写成 `git([])` 会连
    /// `totalCommits > 0` 那道 guard 一起失守，测的就不是这一档了。
    func test_zeroBasisStillTakesTheFailLoudPathNotTheFloor() {
        var mergedOnly = git([])
        mergedOnly.totalCommits = 5
        mergedOnly.commitsAnalyzed = 5
        mergedOnly.authors = []
        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), git: mergedOnly))
        XCTAssertTrue(score.recommendations.contains { $0.contains("非合并口径 0 笔") },
                      "0 总体必须走 R9 那句而不是新地板那句，实得 \(score.recommendations)")
        XCTAssertFalse(score.recommendations.contains { $0.contains("占比无定义") },
                       "没有总体与总体太小是两件事，不许共用一句")
    }

    /// 两把尺子不许互相引用：数值都落在 7 纯属巧合，并成一条就是给「天数够 ⇒ 总体够」背书。
    func test_twoFloorsDoNotShareOneRuler() throws {
        let team = try strippedHealthSource("HealthTeamDimensions.swift")
        XCTAssertFalse(team.contains("GitCadenceEvidence.minimumSpanDays"),
                       "总体地板开始读那把天数尺子了 ⇒ 两件不同的事被并成一件")
        XCTAssertFalse(team.contains("minimumLogLines"),
                       "稳定性那把行数尺子被借去量提交数 ⇒ 量纲已经错了")
    }

    /// 地板只管缺席那一维，不许顺手把综合分整体拉走（缺席 = 不参与归一化）。
    func test_absentPopulationDoesNotDragTheOverallDown() {
        let thin = WeightedHealthScorer().score(HealthInputs(code: healthyCode(),
                                                             git: git([("甲", 2), ("乙", 1)])))
        let full = WeightedHealthScorer().score(HealthInputs(code: healthyCode(),
                                                             git: git([("甲", 200), ("乙", 120)])))
        XCTAssertFalse(thin.components.contains { $0.name == busFactorName })
        XCTAssertTrue(full.components.contains { $0.name == busFactorName },
                      "对照夹具不成立：两组必须分叉，否则上面那条断言是空的")
        for score in [thin, full] {
            XCTAssertTrue(HealthBreakdown.isSumConsistent(
                HealthBreakdown.sumOfContributions(HealthBreakdown.rows(for: score)), with: score.overall))
        }
    }

    // MARK: - 帮手

    private func strippedHealthSource(_ name: String) throws -> String {
        let path = ScoreWordingTests.packageRoot
            .appendingPathComponent("Sources/TcoderMonitor/Services/Health/\(name)").path
        return Self.strippingComments(try String(contentsOfFile: path, encoding: .utf8))
    }

    /// 剥注释这件事本仓只有一把尺子（`ScoreWordingTests` 的那条守卫在用），这里复用、不抄第二份。
    private static func strippingComments(_ source: String) -> String {
        ScoreWordingTests.strippingComments(source)
    }
}

/// 从曲线源码里把某个函数的锚点表 x 值抽出来、算相邻台阶宽度。
///
/// 独立性要点：这里不引用任何曲线常量，只认字面量 ——
/// 锚点表被改过而证据下限没重推，这里立刻数得出不同的台阶。
enum StabilityAnchorProbe {
    enum ProbeError: Error { case functionMissing(String), tableMissing, anchorsTooFew }

    static func anchorGaps(in source: String, function: String) throws -> [Double] {
        guard let at = source.range(of: "func \(function)(") else { throw ProbeError.functionMissing(function) }
        let tail = source[at.lowerBound...]
        guard let open = tail.range(of: "through: ["), let close = tail.range(of: "])") else {
            throw ProbeError.tableMissing
        }
        let table = String(tail[open.upperBound..<close.lowerBound])
        let pattern = try NSRegularExpression(pattern: "x:[[:space:]]*(-?[0-9.]+)")
        let matches = pattern.matches(in: table, range: NSRange(table.startIndex..., in: table))
        let xs = matches.compactMap { match -> Double? in
            guard let range = Range(match.range(at: 1), in: table) else { return nil }
            return Double(table[range])
        }
        guard xs.count >= 2 else { throw ProbeError.anchorsTooFew }
        return zip(xs.dropFirst(), xs).map { abs($0 - $1) }
    }
}
