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
        let notes = HealthBreakdown.shiftNotes(rows)
        XCTAssertEqual(notes.count, 2)
        XCTAssertTrue(notes.contains { $0.hasPrefix("复杂度 18%→") })

        let alone = HealthBreakdown.rows(for: score([component(.complexity, 60)]))
        XCTAssertTrue(HealthBreakdown.shiftNotes(alone).contains("复杂度 18%→100%"),
                      "唯一在场维度被摊到 100%，这正是要写出来的摊分，不能省掉")
    }

    // MARK: - 显示名映射（模型冻结词 → 规范词）

    func testDuplicationDisplaysTheStandardTerm() {
        XCTAssertEqual(DimensionDisplay.name("重复度"), "重复代码率")
        XCTAssertEqual(DimensionDisplay.name(.duplication), "重复代码率")
        XCTAssertEqual(DimensionDisplay.name("复杂度"), "复杂度", "未登记的词原样透出，不做二次创作")
    }

    // MARK: - 未评分不给 0 分环

    func testUnscoredRingShowsPlaceholderAndNotZero() {
        XCTAssertEqual(HealthScoreRing.scoreText(nil), "--")
        XCTAssertEqual(HealthScoreRing.scoreText(0), "0")
        XCTAssertTrue(HealthScoreRing.forcesNeutral(for: nil))
        XCTAssertFalse(HealthScoreRing.forcesNeutral(for: 0), "真 0 分是结论，与没评分是两件事")
    }

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
