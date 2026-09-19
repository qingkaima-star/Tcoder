import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-M 健康评分页显示层契约：权重摊分、缺失维度原因、未评分不给 0 分环。
final class HealthDisplayTests: XCTestCase {

    private func score(_ components: [ScoreComponent], overall: Int = 80) -> HealthScore {
        var health = HealthScore()
        health.components = components
        health.overall = overall
        return health
    }

    private func component(_ dimension: HealthDimension, _ scoreValue: Int) -> ScoreComponent {
        ScoreComponent(name: dimension.rawValue, score: scoreValue,
                       weight: dimension.defaultWeight, detail: "\(dimension.rawValue) 详情",
                       risk: .low)
    }

    // MARK: - 权重摊分

    func testPresentWeightsAreRenormalizedToUnity() {
        let rows = HealthBreakdown.rows(for: score([component(.codeQuality, 90), component(.complexity, 60)]))
        XCTAssertEqual(rows.count, 2)
        let sum = rows.reduce(0) { $0 + $1.effectiveWeight }
        XCTAssertEqual(sum, 1.0, accuracy: 0.0001, "缺失维度不参与，在场维度的乘数必须自己加回 1")
    }

    func testRowsSortByBiggestDragFirst() {
        // 代码质量 90 分 × 0.4375 = 39.4；复杂度 60 分 × 0.5625 = 33.75 → 复杂度在前。
        let rows = HealthBreakdown.rows(for: score([component(.codeQuality, 90), component(.complexity, 60)]))
        XCTAssertEqual(rows.first?.component.name, HealthDimension.complexity.rawValue)
        XCTAssertEqual(rows[0].contribution, 33.75, accuracy: 0.01)
        XCTAssertEqual(rows[0].lostPoints, 0.5625 * 40, accuracy: 0.01)
        XCTAssertEqual(rows[0].fullMarks, 56.25, accuracy: 0.01)
    }

    func testDegenerateWeightSetsProduceNoRows() {
        XCTAssertEqual(HealthBreakdown.rows(for: score([])).count, 0)
        let rows = HealthBreakdown.rows(for: score([
            ScoreComponent(name: "自研维度", score: 50, weight: 0, detail: "", risk: .low),
        ]))
        XCTAssertTrue(rows.isEmpty, "既不在内置表里、权重又是 0 的分量无法归一，直接不出行")
    }

    func testUnknownDimensionFallsBackToScorerWeight() {
        let rows = HealthBreakdown.rows(for: score([
            ScoreComponent(name: "自研维度", score: 70, weight: 0.5, detail: "", risk: .low),
        ]))
        XCTAssertEqual(rows.count, 1)
        XCTAssertNil(rows[0].baseWeight)
        XCTAssertEqual(rows[0].effectiveWeight, 1.0, accuracy: 0.0001)
    }

    func testSumMismatchIsFlaggedInsteadOfSilentlyRounding() {
        let rows = HealthBreakdown.rows(for: score([component(.codeQuality, 90), component(.complexity, 60)]))
        let sum = HealthBreakdown.sumOfContributions(rows)
        XCTAssertFalse(HealthBreakdown.isSumConsistent(sum, with: 80))
        XCTAssertTrue(HealthBreakdown.isSumConsistent(sum, with: Int(sum.rounded())))
    }

    // MARK: - 缺失维度必须说明原因（验收点 6）

    func testMissingDimensionsListEveryUnscoredRole() {
        let missing = HealthBreakdown.missingDimensions(of: score([component(.codeQuality, 90)]))
        XCTAssertEqual(missing.count, HealthDimension.allCases.count - 1)
        XCTAssertFalse(missing.contains(.codeQuality))
        XCTAssertTrue(missing.contains(.testing))
    }

    func testMissingReasonsNameTheActualCause() {
        XCTAssertFalse(MissingDimensionReason.text(for: .testing, report: nil).isEmpty)
        XCTAssertTrue(MissingDimensionReason.text(for: .testing, report: nil).contains("扫描"))

        var report = ProjectReport(project: MonitoredProject(name: "x", path: "/tmp/x"))
        XCTAssertTrue(MissingDimensionReason.text(for: .activity, report: report).contains("Git"))
        XCTAssertTrue(MissingDimensionReason.text(for: .stability, report: report).contains("日志"))
        XCTAssertTrue(MissingDimensionReason.text(for: .dependencies, report: report).contains("清单"))

        report.failedSections = ["代码扫描"]
        XCTAssertTrue(MissingDimensionReason.text(for: .complexity, report: report).contains("失败"),
                      "分析器失败过就说失败，不能写成「没有该维度」")
    }

    func testWeightShiftNoteOnlyAppearsWhenWeightActuallyChanged() {
        let rows = HealthBreakdown.rows(for: score([component(.codeQuality, 90), component(.complexity, 60)]))
        let notes = HealthBreakdown.shiftNotes(rows, missingCount: 7)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.hasPrefix("复杂度 18%→") })

        let alone = HealthBreakdown.rows(for: score([component(.complexity, 60)]))
        XCTAssertTrue(HealthBreakdown.shiftNotes(alone, missingCount: 8).contains("复杂度 18%→100%"),
                      "唯一在场维度被摊到 100%，这正是要写出来的摊分，不能省掉")
    }

    // MARK: - 权重口径的陈述必须有条件（总工点名的那句矛盾）

    /// 前提事实：内置权重表合计是 **110%**，不是 100%。
    /// 所以「全维度在场」时每个乘数也已被整体折算过 ——
    /// 旧文案一句无脑说「已摊到在场维度」、另一句无脑说「权重未做摊分」，两句同时错。
    func testTableWeightSumIsOneHundredTenPercent() {
        XCTAssertEqual(HealthBreakdown.tableWeightSum, 1.10, accuracy: 1e-9,
                       "口径变了就要回头改文案分支，这条是那句话的事实基础")
    }

    /// 评分器发布形态：`weight = defaultWeight / Σ在场`（WS-C 的 HealthScoreTests 已钉住 Σ=1）。
    private func scorerShapedScore(_ dimensions: [HealthDimension], scores: [Int] = [80]) -> HealthScore {
        let presentSum = dimensions.reduce(0) { $0 + $1.defaultWeight }
        var items: [ScoreComponent] = []
        for (index, dimension) in dimensions.enumerated() {
            items.append(ScoreComponent(name: dimension.rawValue,
                                        score: scores[min(index, scores.count - 1)],
                                        weight: dimension.defaultWeight / presentSum,
                                        detail: "", risk: .low))
        }
        return score(items)
    }

    func testFullCoverageAttributesTheShiftToTheTableNotToMissingDims() {
        let all = HealthDimension.allCases
        let health = scorerShapedScore(all)
        let rows = HealthBreakdown.rows(for: health)
        XCTAssertEqual(rows.count, all.count)
        for row in rows {
            XCTAssertEqual(HealthBreakdown.shiftCause(for: row, rows: rows, missingCount: 0),
                           .tableNormalization, "\(row.name)")
            let tooltip = HealthBreakdown.weightTooltip(for: row, rows: rows, missingCount: 0)
            XCTAssertTrue(tooltip.contains("没有维度缺席"), tooltip)
            XCTAssertFalse(tooltip.contains("等比摊入"), "全在场时不得宣称缺席摊分：\(tooltip)")
        }
        let summary = HealthBreakdown.normalizationSummary(rows: rows, missingCount: 0)
        XCTAssertTrue(summary.contains("整体折算"), summary)
        XCTAssertFalse(summary.contains("未做摊分"), "表合计 110% 时这句是假的：\(summary)")
    }

    func testSubsetAttributesTheShiftToMissingDimensions() {
        let present: [HealthDimension] = [.codeQuality, .complexity]
        let rows = HealthBreakdown.rows(for: scorerShapedScore(present))
        let missing = HealthDimension.allCases.count - present.count
        for row in rows {
            XCTAssertEqual(HealthBreakdown.shiftCause(for: row, rows: rows, missingCount: missing),
                           .missingDimensions, "\(row.name)")
            XCTAssertTrue(HealthBreakdown.weightTooltip(for: row, rows: rows, missingCount: missing)
                          .contains("\(missing) 个维度缺席"))
        }
        XCTAssertTrue(HealthBreakdown.normalizationSummary(rows: rows, missingCount: missing)
                      .contains("缺失 \(missing) 个维度"))
    }

    /// 对不上任何一种模型时，界面要说「对不上」，而不是硬套一个原因。
    func testUnfittingWeightsSayTheyAreUnexplained() {
        let health = score([
            ScoreComponent(name: HealthDimension.complexity.rawValue, score: 60, weight: 0.9, detail: "", risk: .low),
            ScoreComponent(name: HealthDimension.duplication.rawValue, score: 70, weight: 0.1, detail: "", risk: .low),
        ])
        let rows = HealthBreakdown.rows(for: health)
        for row in rows {
            XCTAssertEqual(HealthBreakdown.shiftCause(for: row, rows: rows, missingCount: 7), .unexplained)
            XCTAssertTrue(HealthBreakdown.weightTooltip(for: row, rows: rows, missingCount: 7).contains("对不上"))
        }
    }

    func testUnknownDimensionTooltipNeverInventsATableShare() {
        let rows = HealthBreakdown.rows(for: score([
            ScoreComponent(name: "自研维度", score: 70, weight: 1.0, detail: "", risk: .low),
        ]))
        let tooltip = HealthBreakdown.weightTooltip(for: rows[0], rows: rows, missingCount: 0)
        XCTAssertTrue(tooltip.contains("不在内置权重表里"), tooltip)
        XCTAssertFalse(tooltip.contains("摊"), "不在表里的维度没有任何「原始占比」可摊：\(tooltip)")
    }

    // MARK: - 显示名映射（模型冻结词 → 规范词）

    func testDuplicationDisplaysTheStandardTerm() {
        XCTAssertEqual(DimensionDisplay.name("重复度"), "重复代码率")
        XCTAssertEqual(DimensionDisplay.name(.duplication), "重复代码率")
        XCTAssertEqual(DimensionDisplay.name("复杂度"), "复杂度", "未登记的词原样透出，不做二次创作")
    }

    // MARK: - 未评分不给 0 分环
    //
    // 环本体已并入 WS-K 的共享 `HealthRing`（Views/Shell/DashboardHero.swift），
    // 那边由 `ShellDesignTests` 盯空心圈；这里只钉本页依赖的**取色决策**，
    // 避免同一个断言在两处各写一份。

    func testUnscoredColorIsNeutralNotDanger() {
        XCTAssertEqual(Theme.Semantic.role(forScore: nil).name, "neutral")
        XCTAssertEqual(Theme.Semantic.role(forScore: 0).name, "critical")
        XCTAssertEqual(Theme.Semantic.role(forScore: 92).name, "success")
        XCTAssertEqual(Theme.Semantic.role(forScore: 75).name, "healthy")
    }

    func testTrendAveragesRefuseEmptyInput() {
        XCTAssertNil(HealthTrendCard.average([]))
        XCTAssertEqual(HealthTrendCard.average([10, 20, 30]), 20)
    }

    func testGradeBLineMatchesTheModelThreshold() {
        XCTAssertEqual(HealthTrendCard.gradeBLine, 70)
        XCTAssertEqual(HealthGrade(score: 70), .b)
        XCTAssertEqual(HealthGrade(score: 69), .c)
    }
}
