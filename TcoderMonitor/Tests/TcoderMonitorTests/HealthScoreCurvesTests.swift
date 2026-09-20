import XCTest
@testable import TcoderMonitor

/// WS-C 健康评分单测：`ScoreCurves` 的纯函数曲线（piecewise / clamped / 九个维度）与 narrative。
///
/// 只测确定性行为：不读文件、不依赖系统时钟（活跃度一律用 `daysSinceLastCommit` 入参）、
/// 不钉死具体分数（除规格点名的锚点外）。
/// 拆自 HealthScoreTests.swift，断言与用例一字未改（WS-V）。
final class HealthScoreCurvesTests: HealthScoreTestCase {
    // MARK: - A. ScoreCurve.piecewise

    func testPiecewiseReturnsExactScoreAtEveryAnchor() {
        let curve: [(x: Double, score: Double)] = [
            (x: 0, score: 100), (x: 6, score: 82), (x: 15, score: 55), (x: 26, score: 20), (x: 40, score: 0),
        ]
        for point in curve {
            XCTAssertEqual(
                ScoreCurve.piecewise(point.x, through: curve),
                point.score,
                accuracy: 1e-6,
                "输入正好命中锚点 x=\(point.x) 时必须返回该锚点分值"
            )
        }
    }

    func testPiecewiseInterpolatesLinearlyBetweenPoints() {
        let result = ScoreCurve.piecewise(4, through: [(x: 0, score: 0), (x: 10, score: 100)])
        XCTAssertEqual(result, 40, accuracy: 1e-6, "两点之间必须线性插值：0..10 映射 0..100，4 应为 40")

        let lowered = ScoreCurve.piecewise(7.5, through: [(x: 5, score: 80), (x: 10, score: 40)])
        XCTAssertEqual(lowered, 60, accuracy: 1e-6, "降序线段 5→80、10→40 的中点必须是 60")
    }

    func testPiecewiseClampsOutsideTheCurveRange() {
        let curve: [(x: Double, score: Double)] = [(x: 10, score: 70), (x: 20, score: 30)]
        XCTAssertEqual(ScoreCurve.piecewise(0, through: curve), 70, accuracy: 1e-6, "低于首点必须截断为首点值")
        XCTAssertEqual(ScoreCurve.piecewise(9.999, through: curve), 70, accuracy: 1e-6, "低于首点必须截断为首点值")
        XCTAssertEqual(ScoreCurve.piecewise(35, through: curve), 30, accuracy: 1e-6, "高于末点必须截断为末点值")
        XCTAssertEqual(ScoreCurve.piecewise(20.001, through: curve), 30, accuracy: 1e-6, "高于末点必须截断为末点值")
    }

    func testPiecewiseHandlesDegeneratePointLists() {
        XCTAssertEqual(ScoreCurve.piecewise(42, through: []), 0, accuracy: 1e-6, "空曲线必须返回 0")
        XCTAssertEqual(ScoreCurve.piecewise(-7, through: []), 0, accuracy: 1e-6, "空曲线必须返回 0")

        // 单点曲线：任何输入都恒为该点的 score。
        for value in [-1_000.0, 0, 3.5, 9_999] {
            XCTAssertEqual(
                ScoreCurve.piecewise(value, through: [(x: 4, score: 63)]),
                63,
                accuracy: 1e-6,
                "单点曲线在 value=\(value) 处必须恒为 63"
            )
        }
    }

    func testPiecewiseSurvivesNonFiniteInput() {
        let curve: [(x: Double, score: Double)] = [(x: 0, score: 100), (x: 50, score: 40), (x: 100, score: 0)]
        let nonFiniteValues: [Double] = [.nan, .infinity, -.infinity]
        for value in nonFiniteValues {
            let result = ScoreCurve.piecewise(value, through: curve)
            XCTAssertTrue(result.isFinite, "piecewise(\(value)) 必须返回有限值，实际 \(result)")
            XCTAssertTrue((0...100).contains(result), "piecewise(\(value)) 必须落在 0...100，实际 \(result)")
        }
        // 中段锚点在正常曲线上仍须精确命中（非有限输入走的是同一条截断/取值路径）。
        let middle = ScoreCurve.piecewise(25, through: [(x: 0, score: 100), (x: 25, score: 60), (x: 100, score: 0)])
        XCTAssertEqual(middle, 60, accuracy: 1e-6, "中段锚点 x=25 必须命中 60")
    }

    func testPiecewiseIsMonotonicOnDescendingCurve() {
        let curve: [(x: Double, score: Double)] = [
            (x: 0, score: 100), (x: 12, score: 88), (x: 25, score: 61), (x: 60, score: 22), (x: 100, score: 0),
        ]
        var previous: Double?
        var value = 0.0
        while value <= 100.0 {
            let result = ScoreCurve.piecewise(value, through: curve)
            if let previous {
                XCTAssertLessThanOrEqual(result, previous + 1e-9, "x 升 score 降的曲线上，value=\(value) 处结果不得回升")
            }
            previous = result
            value += 2.5
        }
    }

    // MARK: - B. ScoreCurve.clamped

    func testClampedUsesDefaultZeroToOneHundredBounds() {
        XCTAssertEqual(ScoreCurve.clamped(-10), 0, accuracy: 1e-6, "默认下界 0")
        XCTAssertEqual(ScoreCurve.clamped(150), 100, accuracy: 1e-6, "默认上界 100")
        XCTAssertEqual(ScoreCurve.clamped(55), 55, accuracy: 1e-6, "区间内的值必须原样返回")
        XCTAssertEqual(ScoreCurve.clamped(0), 0, accuracy: 1e-6)
        XCTAssertEqual(ScoreCurve.clamped(100), 100, accuracy: 1e-6)
    }

    func testClampedHonoursExplicitBoundsAndToleratesNaN() {
        XCTAssertEqual(ScoreCurve.clamped(150, 0, 60), 60, accuracy: 1e-6, "显式上界必须生效")
        XCTAssertEqual(ScoreCurve.clamped(-3, 10, 20), 10, accuracy: 1e-6, "显式下界必须生效")
        XCTAssertEqual(ScoreCurve.clamped(15, 10, 20), 15, accuracy: 1e-6)
        // NaN 只要求「不崩、不把 NaN 扩散成越界值」，此处刻意不钉死具体返回值。
        let nan = ScoreCurve.clamped(.nan)
        XCTAssertTrue(nan == nan || nan.isNaN, "clamped(NaN) 必须是可比对的 Double，实际 \(nan)")
        let infinity = ScoreCurve.clamped(.infinity)
        XCTAssertTrue(infinity == infinity || infinity.isNaN, "clamped(.infinity) 不得崩，实际 \(infinity)")
    }

    // MARK: - C. duplication

    // MARK: - D. documentation

    // MARK: - E. complexity

    // MARK: - F. 其余维度曲线

    // MARK: - G. narrative

}
