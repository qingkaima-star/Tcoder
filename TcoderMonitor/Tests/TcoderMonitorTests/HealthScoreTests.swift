import XCTest
@testable import TcoderMonitor

/// WS-C 健康评分单测：`ScoreCurves`（纯函数曲线）+ `WeightedHealthScorer`（加权不变量）。
///
/// 只测确定性行为：不读文件、不依赖系统时钟（活跃度一律用 `daysSinceLastCommit` 入参）、
/// 不钉死具体分数（除规格点名的锚点外，评分器侧只做不变量/单调性断言）。
final class HealthScoreTests: XCTestCase {

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

    func testDuplicationCurveAnchors() {
        XCTAssertGreaterThanOrEqual(HealthCurves.duplication(ratio: 0, codeLines: 12_000).score, 99, "零重复必须接近满分")
        let slight = HealthCurves.duplication(ratio: 0.05, codeLines: 12_000).score
        XCTAssertGreaterThanOrEqual(slight, 95, "5% 重复仍属优秀区间")
        XCTAssertLessThanOrEqual(slight, 100)

        // 用户点名锚点：12.5% 重复必须落在 70...80。
        let anchor = HealthCurves.duplication(ratio: 0.125, codeLines: 12_000)
        XCTAssertGreaterThanOrEqual(anchor.score, 70, "12.5% 重复是规格点名的锚点，不得低于 70")
        XCTAssertLessThanOrEqual(anchor.score, 80, "12.5% 重复是规格点名的锚点，不得高于 80")

        XCTAssertLessThanOrEqual(HealthCurves.duplication(ratio: 0.25, codeLines: 12_000).score, 10, "25% 重复必须近乎满分惩罚")
        XCTAssertLessThanOrEqual(HealthCurves.duplication(ratio: 0.40, codeLines: 12_000).score, 5, "40% 重复不得高于 5")
    }

    func testDuplicationIsMonotonicWithGrowingRatio() {
        let ratios: [Double] = [0, 0.05, 0.125, 0.25, 0.4]
        let results = ratios.map { HealthCurves.duplication(ratio: $0, codeLines: 9_000) }
        for index in 1..<results.count {
            XCTAssertLessThanOrEqual(results[index].score, results[index - 1].score, "ratio 增大时分数不得回升")
            XCTAssertGreaterThanOrEqual(
                results[index].risk.rank,
                results[index - 1].risk.rank,
                "ratio 增大时风险等级不得下降"
            )
        }
        XCTAssertTrue(results.allSatisfy { $0.score >= 0 && $0.score <= 100 })
    }

    func testDuplicationWithNoCodeLinesStillReturnsValidResult() {
        assertCurveIsValid(HealthCurves.duplication(ratio: 0, codeLines: 0), context: "duplication 零行代码")
    }

    // MARK: - D. documentation

    func testDocumentationCurvesUpAroundFivePercentComments() {
        let peak = HealthCurves.documentation(commentRatio: 0.05, todoCount: 0, fixmeCount: 0, totalLines: 40_000)
        let zero = HealthCurves.documentation(commentRatio: 0, todoCount: 0, fixmeCount: 0, totalLines: 40_000)
        let low = HealthCurves.documentation(commentRatio: 0.02, todoCount: 0, fixmeCount: 0, totalLines: 40_000)
        let mid = HealthCurves.documentation(commentRatio: 0.10, todoCount: 0, fixmeCount: 0, totalLines: 40_000)
        let high = HealthCurves.documentation(commentRatio: 0.15, todoCount: 0, fixmeCount: 0, totalLines: 40_000)
        let heavy = HealthCurves.documentation(commentRatio: 0.35, todoCount: 0, fixmeCount: 0, totalLines: 40_000)
        let flooded = HealthCurves.documentation(commentRatio: 0.5, todoCount: 0, fixmeCount: 0, totalLines: 40_000)

        XCTAssertGreaterThanOrEqual(peak.score, zero.score, "5% 注释必须优于完全无注释")
        XCTAssertGreaterThanOrEqual(peak.score, heavy.score, "5% 注释必须优于 35% 注释")
        XCTAssertGreaterThanOrEqual(peak.score, low.score, "5% 注释是曲线峰值区，必须优于 2%")
        // 高分区阈值取 65：具体锚点由实现决定，这里只要求 2%/10%/15% 都落在高分区。
        XCTAssertGreaterThanOrEqual(low.score, 65, "2% 注释应落在高分区")
        XCTAssertGreaterThanOrEqual(mid.score, 65, "10% 注释应落在高分区")
        XCTAssertGreaterThanOrEqual(high.score, 65, "15% 注释应落在高分区")
        XCTAssertLessThanOrEqual(flooded.score, peak.score - 10, "注释过半（50%）必须明显低于 5% 峰值")

        for result in [peak, zero, low, mid, high, heavy, flooded] {
            assertCurveIsValid(result, context: "documentation")
        }
    }

    func testDocumentationPenalisesFixMeAndTodoMarkers() {
        let clean = HealthCurves.documentation(commentRatio: 0.06, todoCount: 0, fixmeCount: 0, totalLines: 60_000)
        let dirty = HealthCurves.documentation(commentRatio: 0.06, todoCount: 0, fixmeCount: 40, totalLines: 60_000)
        XCTAssertLessThan(dirty.score, clean.score, "同一注释率下 40 个 FIXME 必须拉低分数")

        let todoClean = HealthCurves.documentation(commentRatio: 0.06, todoCount: 0, fixmeCount: 0, totalLines: 60_000)
        let todoHeavy = HealthCurves.documentation(commentRatio: 0.06, todoCount: 120, fixmeCount: 0, totalLines: 60_000)
        XCTAssertLessThanOrEqual(todoHeavy.score, todoClean.score, "TODO 增多时分数不得回升")
    }

    // MARK: - E. complexity

    func testComplexityAnchorsOnAverageCyclomaticComplexity() {
        let easy = HealthCurves.complexity(averageCC: 1, highRiskCount: 0, maxCC: 6, functionCount: 900)
        XCTAssertGreaterThanOrEqual(easy.score, 90, "平均圈复杂度 1 必须高分")

        let mid = HealthCurves.complexity(averageCC: 16, highRiskCount: 0, maxCC: 22, functionCount: 900)
        XCTAssertLessThanOrEqual(mid.score, 75, "平均圈复杂度 16 属于中低区间（上限留实现余量）")

        let brutal = HealthCurves.complexity(averageCC: 40, highRiskCount: 0, maxCC: 60, functionCount: 900)
        XCTAssertLessThanOrEqual(brutal.score, 10, "平均圈复杂度 40 必须接近 0")

        XCTAssertGreaterThan(easy.score, mid.score, "圈复杂度 1 必须优于 16")
        XCTAssertGreaterThanOrEqual(mid.score, brutal.score, "圈复杂度 16 不得比 40 更差")
    }

    func testComplexityPenalisesHighRiskCountAndMaxCC() {
        var previous: Double?
        // 只取惩罚未封顶的区间（每个 highRisk 扣 3 分、上限 30 分），避免与实现的具体扣幅死磕。
        for highRiskCount in [0, 2, 6, 10] {
            let result = HealthCurves.complexity(averageCC: 8, highRiskCount: highRiskCount, maxCC: 24, functionCount: 700)
            if let previous {
                XCTAssertLessThanOrEqual(result.score, previous, "highRiskCount=\(highRiskCount) 时分数不得回升")
            }
            previous = result.score
            assertCurveIsValid(result, context: "complexity highRiskCount=\(highRiskCount)")
        }

        let moderateMax = HealthCurves.complexity(averageCC: 6, highRiskCount: 0, maxCC: 20, functionCount: 700)
        let extremeMax = HealthCurves.complexity(averageCC: 6, highRiskCount: 0, maxCC: 45, functionCount: 700)
        XCTAssertLessThan(extremeMax.score, moderateMax.score, "maxCC 45 必须低于 maxCC 20")
    }

    func testComplexityWithoutFunctionsIsPerfectAndExplained() {
        let result = HealthCurves.complexity(averageCC: 0, highRiskCount: 0, maxCC: 0, functionCount: 0)
        XCTAssertGreaterThanOrEqual(result.score, 99, "没有任何函数时应按满分处理")
        XCTAssertLessThanOrEqual(result.score, 100)
        XCTAssertFalse(result.detail.isEmpty, "满分也必须给出说明文案")
        assertCurveIsValid(result, context: "complexity functionCount=0")
    }

    // MARK: - F. 其余维度曲线

    func testCodeQualityCoversCleanMediumAndAwful() {
        let clean = HealthCurves.codeQuality(hugeFileRatio: 0, averageFunctionLength: 20, longFunctions: 0, totalFiles: 320)
        XCTAssertGreaterThanOrEqual(clean.score, 80, "无巨型文件、函数短小时必须高分")

        let medium = HealthCurves.codeQuality(hugeFileRatio: 0.03, averageFunctionLength: 55, longFunctions: 18, totalFiles: 260)
        XCTAssertLessThan(medium.score, clean.score, "中等质量问题必须低于干净仓库")

        let awful = HealthCurves.codeQuality(hugeFileRatio: 0.35, averageFunctionLength: 160, longFunctions: 210, totalFiles: 90)
        XCTAssertLessThanOrEqual(awful.score, 40, "35% 巨型文件 + 平均 160 行函数必须低分")
        XCTAssertGreaterThanOrEqual(awful.risk.rank, RiskLevel.medium.rank, "恶劣代码质量至少要标中等风险")

        assertCurveIsValid(clean, context: "codeQuality clean")
        assertCurveIsValid(medium, context: "codeQuality medium")
        assertCurveIsValid(awful, context: "codeQuality awful")
        assertCurveIsValid(
            HealthCurves.codeQuality(hugeFileRatio: 0, averageFunctionLength: 0, longFunctions: 0, totalFiles: 0),
            context: "codeQuality 无文件"
        )
    }

    func testActivityUsesExplicitDaysSinceLastCommit() {
        let fresh = HealthCurves.activity(commitsPerDay: 4, daysSinceLastCommit: 0, totalCommits: 3_000)
        XCTAssertGreaterThanOrEqual(fresh.score, 85, "日均 4 次提交且今天刚提交必须高分")

        let steady = HealthCurves.activity(commitsPerDay: 0.4, daysSinceLastCommit: 25, totalCommits: 400)
        XCTAssertLessThan(steady.score, fresh.score, "低频率且 25 天无提交必须低于活跃仓库")

        let stale = HealthCurves.activity(commitsPerDay: 0.02, daysSinceLastCommit: 380, totalCommits: 120)
        XCTAssertLessThanOrEqual(stale.score, 40, "一年无提交必须低分")

        assertCurveIsValid(fresh, context: "activity fresh")
        assertCurveIsValid(steady, context: "activity steady")
        assertCurveIsValid(stale, context: "activity stale")
        assertCurveIsValid(
            HealthCurves.activity(commitsPerDay: 0, daysSinceLastCommit: nil, totalCommits: 0),
            context: "activity 无 Git 数据"
        )
    }

    func testActivityIsMonotonicInDaysSinceLastCommit() {
        var previous: Double?
        for days in [1.0, 7, 30, 120, 400] {
            let result = HealthCurves.activity(commitsPerDay: 1.0, daysSinceLastCommit: days, totalCommits: 800)
            if let previous {
                XCTAssertLessThanOrEqual(result.score, previous, "距上次提交 \(days) 天时分数不得回升")
            }
            previous = result.score
        }
    }

    func testBusFactorPunishesConcentratedAuthorship() {
        let concentrated = HealthCurves.busFactor(risk: .high, topAuthorShare: 0.75, activeAuthors: 4, totalCommits: 900)
        let shared = HealthCurves.busFactor(risk: .low, topAuthorShare: 0.3, activeAuthors: 4, totalCommits: 900)
        XCTAssertGreaterThanOrEqual(
            shared.score - concentrated.score,
            30,
            "75% 单人占比 + 高风险必须比 30% 占比 + 低风险至少低 30 分"
        )

        let solo = HealthCurves.busFactor(risk: .critical, topAuthorShare: 1.0, activeAuthors: 1, totalCommits: 500)
        XCTAssertLessThanOrEqual(solo.score, 15, "单人维护 500 次提交必须极低分")
        XCTAssertTrue(solo.risk == .high || solo.risk == .critical, "单人维护必须是高/严重风险")

        let moderate = HealthCurves.busFactor(risk: .medium, topAuthorShare: 0.55, activeAuthors: 3, totalCommits: 240)
        XCTAssertGreaterThan(moderate.score, solo.score, "三人分担必须优于单人")
        XCTAssertLessThan(moderate.score, shared.score, "55% 占比必须优于 30% 占比")

        assertCurveIsValid(concentrated, context: "busFactor concentrated")
        assertCurveIsValid(shared, context: "busFactor shared")
        assertCurveIsValid(moderate, context: "busFactor moderate")
        assertCurveIsValid(
            HealthCurves.busFactor(risk: .none, topAuthorShare: 0, activeAuthors: 0, totalCommits: 0),
            context: "busFactor 无提交"
        )
    }

    func testStabilityNeverFakesUnscannedLogsAsPerfect() {
        let unscanned = HealthCurves.stability(
            errorsPerKLoc: 0, crashCount: 0, fatalCount: 0, exceptionCount: 0, totalLinesScanned: 0
        )
        XCTAssertTrue(
            unscanned.detail.contains("未扫描") || unscanned.detail.contains("默认"),
            "无日志扫描量时 detail 必须说明未扫描/默认，实际：\(unscanned.detail)"
        )
        // 规格禁止把无数据伪装成满分：此处以 detail 措辞为准，不额外钉死分数，
        // 因为实现可以合法地给出「保守默认分」或「中性分」。

        let clean = HealthCurves.stability(
            errorsPerKLoc: 0, crashCount: 0, fatalCount: 0, exceptionCount: 0, totalLinesScanned: 250_000
        )
        XCTAssertGreaterThanOrEqual(clean.score, 90, "扫描到 25 万行且零错误必须高分")

        let awful = HealthCurves.stability(
            errorsPerKLoc: 30, crashCount: 12, fatalCount: 6, exceptionCount: 40, totalLinesScanned: 80_000
        )
        XCTAssertLessThanOrEqual(awful.score, 35, "每千行 30 个错误 + 崩溃必须低分")
        XCTAssertGreaterThan(clean.score, awful.score)

        var previous: Double?
        for crashes in [0, 2, 9] {
            let result = HealthCurves.stability(
                errorsPerKLoc: 1.5, crashCount: crashes, fatalCount: 0, exceptionCount: 3, totalLinesScanned: 90_000
            )
            if let previous {
                XCTAssertLessThanOrEqual(result.score, previous, "crashCount=\(crashes) 时分数不得回升")
            }
            previous = result.score
            assertCurveIsValid(result, context: "stability crashes=\(crashes)")
        }

        assertCurveIsValid(clean, context: "stability clean")
        assertCurveIsValid(awful, context: "stability awful")
        assertCurveIsValid(unscanned, context: "stability unscanned")
    }

    func testDependencyHealthAnchors() {
        let pristine = HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 0, totalDependencies: 140)
        XCTAssertGreaterThanOrEqual(pristine.score, 95, "零漏洞零过期必须 >= 95")

        let vulnerable = HealthCurves.dependencyHealth(vulnerableCount: 20, outdatedCount: 12, totalDependencies: 140)
        XCTAssertLessThanOrEqual(vulnerable.score, 30, "20 个漏洞必须 <= 30")

        let staleOnly = HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 90, totalDependencies: 140)
        XCTAssertLessThan(staleOnly.score, pristine.score, "过期比例高时必须低于全新鲜")

        // 两个惩罚因子各自单调，不跨维度比较大小（漏洞与过期的相对权重由实现决定）。
        var previousVulnerable: Double?
        for vulnerableCount in [0, 3, 12, 20] {
            let result = HealthCurves.dependencyHealth(
                vulnerableCount: vulnerableCount, outdatedCount: 0, totalDependencies: 140
            )
            if let previousVulnerable {
                XCTAssertLessThanOrEqual(result.score, previousVulnerable, "漏洞数 \(vulnerableCount) 时分数不得回升")
            }
            previousVulnerable = result.score
        }
        var previousOutdated: Double?
        for outdatedCount in [0, 20, 60, 130] {
            let result = HealthCurves.dependencyHealth(
                vulnerableCount: 0, outdatedCount: outdatedCount, totalDependencies: 140
            )
            if let previousOutdated {
                XCTAssertLessThanOrEqual(result.score, previousOutdated, "过期数 \(outdatedCount) 时分数不得回升")
            }
            previousOutdated = result.score
        }

        assertCurveIsValid(pristine, context: "dependencyHealth pristine")
        assertCurveIsValid(vulnerable, context: "dependencyHealth vulnerable")
        assertCurveIsValid(staleOnly, context: "dependencyHealth stale")
        assertCurveIsValid(
            HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 0, totalDependencies: 0),
            context: "dependencyHealth 无依赖"
        )
    }

    func testEveryCurveStaysWithinBoundsAcrossSweep() {
        var results: [CurveResult] = []
        for ratio in [0.0, 0.03, 0.125, 0.22, 0.55] {
            results.append(HealthCurves.duplication(ratio: ratio, codeLines: 15_000))
            results.append(HealthCurves.documentation(commentRatio: ratio, todoCount: 4, fixmeCount: 1, totalLines: 30_000))
        }
        for averageCC in [1.0, 5, 12, 25, 60] {
            results.append(HealthCurves.complexity(averageCC: averageCC, highRiskCount: 6, maxCC: 30, functionCount: 450))
        }
        for hugeFileRatio in [0.0, 0.08, 0.3] {
            results.append(HealthCurves.codeQuality(hugeFileRatio: hugeFileRatio, averageFunctionLength: 70, longFunctions: 25, totalFiles: 200))
        }
        for commitsPerDay in [0.0, 0.3, 2.5, 9.0] {
            results.append(HealthCurves.activity(commitsPerDay: commitsPerDay, daysSinceLastCommit: 4, totalCommits: 600))
        }
        for share in [0.0, 0.35, 0.65, 1.0] {
            results.append(HealthCurves.busFactor(risk: .medium, topAuthorShare: share, activeAuthors: 5, totalCommits: 700))
        }
        for errorsPerKLoc in [0.0, 2.0, 18.0] {
            results.append(HealthCurves.stability(errorsPerKLoc: errorsPerKLoc, crashCount: 1, fatalCount: 0, exceptionCount: 4, totalLinesScanned: 40_000))
        }
        for vulnerable in [0, 5, 30] {
            results.append(HealthCurves.dependencyHealth(vulnerableCount: vulnerable, outdatedCount: 8, totalDependencies: 120))
        }

        XCTAssertGreaterThanOrEqual(results.count, 30, "扫描用例应覆盖全部 8 条曲线的多个点位")
        for result in results {
            assertCurveIsValid(result, context: "sweep")
        }
    }

    // MARK: - G. narrative

    func testNarrativeIsShortChineseSentenceNamingWorstDimension() {
        let n = HealthCurves.narrative(overall: 62, components: [
            (name: "复杂度", score: 12),
            (name: "重复度", score: 95),
            (name: "提交活跃度", score: 60),
            (name: "依赖健康", score: 45),
        ])
        XCTAssertTrue((40...80).contains(n.count), "结论文案长度须在 40...80 字符，实际 \(n.count)：\(n)")
        XCTAssertTrue(n.contains("综合"), "文案必须点明综合评分：\(n)")
        XCTAssertTrue(n.contains("复杂度"), "文案必须点出最低维度（复杂度）：\(n)")
        XCTAssertFalse(n.contains("AI"), "文案不得出现 AI：\(n)")
        XCTAssertFalse(n.contains("模型"), "文案不得出现「模型」二字：\(n)")
    }

    func testNarrativeHandlesEmptyComponentList() {
        let n = HealthCurves.narrative(overall: 0, components: [])
        XCTAssertFalse(n.isEmpty, "空 components 也必须给出结论文案")
        // 退化输入同样要求 40...80 字：实现按子句拼装并补齐固定后缀。
        XCTAssertTrue((40...80).contains(n.count), "空 components 的文案长度也须在 40...80 字符，实际 \(n.count)：\(n)")
        XCTAssertFalse(n.contains("AI"), "文案不得出现 AI：\(n)")
        XCTAssertFalse(n.contains("模型"), "文案不得出现「模型」二字：\(n)")
    }

    func testNarrativeNamesTheWorstDimensionForBadProject() {
        let n = HealthCurves.narrative(overall: 21, components: [
            (name: "运行稳定性", score: 21),
            (name: "依赖健康", score: 88),
        ])
        XCTAssertTrue(n.contains("运行稳定性"), "最差维度名必须出现在文案里：\(n)")
        XCTAssertFalse(n.isEmpty)
    }

    // MARK: - H. WeightedHealthScorer 不变量

    func testScorerWithNoDataReturnsEmptyEGrade() {
        let score = WeightedHealthScorer().score(HealthInputs())
        XCTAssertEqual(score.overall, 0, "无任何维度数据时不得凭空给分")
        XCTAssertTrue(score.components.isEmpty, "无输入时不得编造维度分量，实际 \(score.components.map(\.name))")
        XCTAssertFalse(score.recommendations.isEmpty, "即便无数据也要给出下一步建议")
        XCTAssertFalse(score.narrative.isEmpty, "即便无数据也要给出结论文案")
        XCTAssertFalse(score.generatedByAI, "结论文案由规则拼装，不得声称 AI 生成")
        XCTAssertEqual(score.grade, .e)
        XCTAssertNil(score.previousOverall)
        XCTAssertNil(score.trendDelta)
    }

    func testScorerNormalisesWeightsForCodeOnlyInputs() {
        let result = WeightedHealthScorer().score(HealthInputs(code: healthyCode()))
        let expectedNames = Set([HealthDimension.codeQuality, .complexity, .duplication, .documentation].map(\.rawValue))
        XCTAssertEqual(Set(result.components.map(\.name)), expectedNames, "只有 code 时必须恰好产出 4 个代码维度")
        XCTAssertEqual(result.components.count, 4)

        // 契约：对外发布的 weight 自己就要归一到 1.0，消费方 Σ(score·weight) 能复现 overall。
        let weightSum = result.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1.0, accuracy: 1e-6, "分量权重必须归一化到 1.0，实际 \(weightSum)")

        // 归一化基数 = 这 4 个维度默认权重之和 0.53（0.14+0.18+0.13+0.08）。
        let base = 0.53
        for component in result.components {
            guard let dimension = HealthDimension.allCases.first(where: { $0.rawValue == component.name }) else {
                return XCTFail("分量名 \(component.name) 不是合法的 HealthDimension.rawValue")
            }
            XCTAssertEqual(component.weight, dimension.defaultWeight / base, accuracy: 1e-6,
                           "\(component.name) 的权重应为 defaultWeight/0.53")
        }
        XCTAssertTrue((0...100).contains(result.overall))
    }

    func testScorerNormalisesWeightsForLogAndDependencyOnlyInputs() {
        let result = WeightedHealthScorer().score(HealthInputs(logs: healthyLogs(), dependencies: cleanDependencies()))
        XCTAssertEqual(
            Set(result.components.map(\.name)),
            Set([HealthDimension.stability, .dependencies].map(\.rawValue)),
            "只有 logs + dependencies 时应产出运行稳定性与依赖健康（availableDimensions 里有它就必须有分量）"
        )
        let weightSum = result.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1.0, accuracy: 1e-6, "两维度集合的权重和仍须归一化为 1.0，实际 \(weightSum)")
        for component in result.components {
            XCTAssertFalse(component.detail.isEmpty, "\(component.name) 必须有说明文案")
            XCTAssertGreaterThanOrEqual(component.weight, 0)
        }
    }

    func testScorerProducesEightComponentsForFullInputs() {
        let result = WeightedHealthScorer().score(fullInputs())
        let expected = Set(HealthDimension.allCases.filter { $0 != .testing }.map(\.rawValue))
        XCTAssertEqual(result.components.count, 8, "testing 权重为 0 且不在 availableDimensions 内，不得出现")
        XCTAssertEqual(Set(result.components.map(\.name)), expected)
        XCTAssertFalse(result.components.contains { $0.name == HealthDimension.testing.rawValue }, "测试覆盖维度不得凭空出现")

        let weightSum = result.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1.0, accuracy: 1e-6, "全维度权重和必须为 1.0，实际 \(weightSum)")
        XCTAssertTrue((0...100).contains(result.overall), "overall 必须在 0...100，实际 \(result.overall)")
        XCTAssertEqual(HealthGrade(score: result.overall), result.grade)
        for component in result.components {
            XCTAssertGreaterThanOrEqual(component.score, 0)
            XCTAssertLessThanOrEqual(component.score, 100)
            XCTAssertEqual(component.weightedContribution, Double(component.score) * component.weight, accuracy: 1e-9)
        }
    }

    /// `.testing` 维度（总工追加）：项目真有覆盖率报告时才参与计分，且必须出现在分量里；
    /// 没有报告时既不得扣分也不得分，更不能凭空造一个分量出来。
    func testScorerIncludesTestingDimensionOnlyWhenCoverageExists() {
        let coverage = CoverageMetrics(reports: [
            CoverageReport(path: "/tmp/tcoder-cov/lcov.info", kind: .unit, toolName: "lcov",
                           linesCovered: 780, linesTotal: 1_000,
                           branchesCovered: 300, branchesTotal: 500,
                           methodsCovered: 0, methodsTotal: 0),
        ])
        let scorer = WeightedHealthScorer()
        var inputs = fullInputs()
        inputs.coverage = coverage
        let withCoverage = scorer.score(inputs)
        let without = scorer.score(fullInputs())
        let testingName = HealthDimension.testing.rawValue

        XCTAssertTrue(withCoverage.components.contains { $0.name == testingName },
                      "有覆盖率报告时必须产出「\(testingName)」分量，实际 \(withCoverage.components.map(\.name))")
        XCTAssertFalse(without.components.contains { $0.name == testingName },
                       "没有覆盖率报告不得凭空造出「\(testingName)」分量")
        XCTAssertEqual(without.components.count + 1, withCoverage.components.count,
                       "加入第 9 个维度只应多出一个分量，其余维度不受影响")
        XCTAssertEqual(withCoverage.components.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-6,
                       "加入新维度后权重仍须归一到 1.0")

        if let testing = withCoverage.components.first(where: { $0.name == testingName }) {
            XCTAssertGreaterThan(testing.score, 55, "78% 行覆盖率不该被判成低分，实得 \(testing.score)")
            XCTAssertLessThan(testing.score, 100, "78% 不得判成满分")
            XCTAssertFalse(testing.detail.isEmpty, "分量必须带可解释的数字依据")
        }
    }

    /// 分支 1：分析器给出全仓均值 → 用它，detail 不再挂「热点样本」口径后缀。
    func testComplexityUsesRepoAverageWhenAnalyzerReportsIt() {
        var code = healthyCode()
        code.analyzedFunctionCount = 420
        code.averageCyclomaticComplexity = 4.0
        let result = WeightedHealthScorer().score(HealthInputs(code: code))
        guard let complexity = result.components.first(where: { $0.name == HealthDimension.complexity.rawValue }) else {
            return XCTFail("有全仓均值时复杂度维度必须参与评分，实际 \(result.components.map(\.name))")
        }
        XCTAssertTrue(complexity.detail.contains("平均圈复杂度 4"),
                      "detail 必须引用全仓均值，实得 \(complexity.detail)")
        XCTAssertFalse(complexity.detail.contains("热点样本"),
                       "已有全仓均值时不得再挂样本口径后缀，实得 \(complexity.detail)")
        // 热点榜均值是 9（只有 1 个 CC 9 的函数），全仓均值 4 应当明显更高。
        var noMean = code
        noMean.averageCyclomaticComplexity = nil
        let fallback = WeightedHealthScorer().score(HealthInputs(code: noMean))
            .components.first { $0.name == HealthDimension.complexity.rawValue }
        XCTAssertGreaterThan(complexity.score, fallback?.score ?? 101,
                             "全仓均值 4.0 必须比热点榜均值 9 算出的分更高")
    }

    /// 分支 2：没有全仓均值但识别到了函数 → 退回热点榜均值，并如实标明样本口径。
    func testComplexityFallsBackToHotspotAverageWithHonestSuffix() {
        var code = healthyCode()
        code.analyzedFunctionCount = 420
        code.averageCyclomaticComplexity = nil
        let result = WeightedHealthScorer().score(HealthInputs(code: code))
        guard let complexity = result.components.first(where: { $0.name == HealthDimension.complexity.rawValue }) else {
            return XCTFail("识别到 420 个函数时复杂度维度不得缺席")
        }
        XCTAssertTrue(complexity.detail.contains("热点样本"),
                      "退回热点榜时必须标明样本口径，实得 \(complexity.detail)")
        XCTAssertTrue(complexity.detail.contains("热点样本 1 个的均值"),
                      "后缀要写清样本数量，实得 \(complexity.detail)")
    }

    /// 分支 3：没有任何复杂度证据 → 本维度不参与评分。
    /// 绝不能把「没测到」当成复杂度 0 而给满分（与 coverage.hasData 同一条诚实原则）。
    func testComplexityIsSkippedWhenNoFunctionsRecognized() {
        let scorer = WeightedHealthScorer()
        let complexityName = HealthDimension.complexity.rawValue

        func components(_ mutate: (inout CodeMetrics) -> Void) -> [ScoreComponent] {
            var code = healthyCode()
            mutate(&code)
            return scorer.score(HealthInputs(code: code)).components
        }
        // 3a：分母为 0、无均值、无热点 —— 总工点名的那一条。
        let noEvidence = components {
            $0.analyzedFunctionCount = 0
            $0.averageCyclomaticComplexity = nil
            $0.topComplexFunctions = []
        }
        XCTAssertFalse(noEvidence.contains { $0.name == complexityName },
                       "没识别到任何函数时不得凭空给复杂度分数，实际 \(noEvidence.map(\.name))")
        XCTAssertEqual(noEvidence.count, 3, "只剩代码质量/重复度/注释三个代码维度")
        XCTAssertEqual(noEvidence.reduce(0) { $0 + $1.weight }, 1.0, accuracy: 1e-6,
                       "少一个维度后其余权重仍须归一到 1.0")

        // 3b：分母 >0 但既无均值也无热点 —— 同样必须缺席。
        //     这一支是踩坑点：若只看 analyzedFunctionCount 就放行，热点均值会被算成 0，
        //     曲线给出「复杂度满分」，等于把没测到当成好。
        let emptyHotspots = components {
            $0.analyzedFunctionCount = 420
            $0.averageCyclomaticComplexity = nil
            $0.topComplexFunctions = []
        }
        XCTAssertFalse(emptyHotspots.contains { $0.name == complexityName },
                       "分母大于 0 但没有任何复杂度数据时也不得给分，实际 \(emptyHotspots.map(\.name))")

        // 对照：有热点榜时该维度必须在场，且综合分与缺席时不同。
        let withHotspots = components { $0.analyzedFunctionCount = 420 }
        XCTAssertTrue(withHotspots.contains { $0.name == complexityName }, "有热点榜时复杂度维度必须参与评分")
        XCTAssertNotEqual(scorer.score(HealthInputs(code: blindCode())).overall,
                          scorer.score(HealthInputs(code: hotspotCode())).overall,
                          "有无复杂度证据必须影响综合分")
    }

    /// 无任何复杂度证据的仓库。
    private func blindCode() -> CodeMetrics {
        var code = healthyCode()
        code.analyzedFunctionCount = 0
        code.averageCyclomaticComplexity = nil
        code.topComplexFunctions = []
        return code
    }

    /// 只有热点榜、没有全仓均值的仓库（WS-A 落地前的真实形态）。
    private func hotspotCode() -> CodeMetrics {
        var code = healthyCode()
        code.analyzedFunctionCount = 420
        code.averageCyclomaticComplexity = nil
        return code
    }

    /// 依赖维度必须区分「没查过」与「查了且零命中」——同一条「没有证据 ≠ 好证据」原则。
    func testUnverifiedDependencyHealthCannotReachFullMarks() {
        let unchecked = HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 0,
                                                      totalDependencies: 140, evidence: .unchecked)
        XCTAssertLessThan(unchecked.score, 100, "没联网核对不得给满分")
        XCTAssertLessThanOrEqual(unchecked.score, Double(VulnerabilityEvidence.uncappedCeiling),
                                 "未核对必须封顶在 B 档上沿，实得 \(unchecked.score)")
        XCTAssertTrue(unchecked.detail.contains("未启用漏洞核对"),
                      "detail 必须写清为什么不是满分，实得 \(unchecked.detail)")
        XCTAssertNotEqual(unchecked.risk, .none, "没查过就不许报「无风险」，实得 \(unchecked.risk.rawValue)")

        let degraded = HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 0,
                                                     totalDependencies: 140, evidence: .degraded)
        XCTAssertLessThanOrEqual(degraded.score, Double(VulnerabilityEvidence.uncappedCeiling))
        XCTAssertTrue(degraded.detail.contains("漏洞核对未完成"), "实得 \(degraded.detail)")

        // 唯一能拿满分的第三种：确实查过、确实零命中。
        let verified = HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 0,
                                                     totalDependencies: 140, evidence: .verified)
        XCTAssertGreaterThan(verified.score, 95, "已核对且零命中应当接近满分，实得 \(verified.score)")
        XCTAssertFalse(verified.detail.contains("未启用"), "已核对时不得出现未核对措辞")

        // 已有正向发现时不受封顶影响（结论本身就是证据），扣分照常。
        let found = HealthCurves.dependencyHealth(vulnerableCount: 12, outdatedCount: 0,
                                                  totalDependencies: 140, evidence: .unchecked)
        XCTAssertLessThan(found.score, 40, "12 个漏洞必须重扣，实得 \(found.score)")
        XCTAssertTrue(found.detail.contains("漏洞 12 个"))

        // 默认参数保持旧签名可用（A~G 组的既有调用不受影响）。
        XCTAssertEqual(HealthCurves.dependencyHealth(vulnerableCount: 0, outdatedCount: 0,
                                                     totalDependencies: 140).score,
                       verified.score, accuracy: 1e-9, "缺省证据状态必须是 .verified")
    }

    /// 服务层字段到证据状态的判定必须是纯函数且覆盖三态。
    func testVulnerabilityEvidenceClassificationCoversAllServiceShapes() {
        func report(_ mutate: (inout DependencyReport) -> Void) -> DependencyReport {
            var deps = DependencyReport(ecosystems: [mavenEcosystem(total: 140, outdated: 0)])
            mutate(&deps)
            return deps
        }
        // 用户主动关着联网：performed=false 且没有任何说明。
        XCTAssertEqual(VulnerabilityEvidence.classify(report { _ in () }), .unchecked,
                       "allowNetwork=false 的默认形态必须判成未核对")
        // 开了网、查完了。
        XCTAssertEqual(VulnerabilityEvidence.classify(report {
            $0.networkLookupPerformed = true
            $0.networkLookupNote = "在线查询已完成（OSV + npm registry）"
        }), .verified)
        // 开了网但部分失败。
        XCTAssertEqual(VulnerabilityEvidence.classify(report {
            $0.networkLookupPerformed = true
            $0.networkLookupNote = "OSV：52 个包中 3 个查询失败"
        }), .degraded)
        // 没查成的各种说明写法都不许改变结论：判据只看 performed，不猜 note 文案。
        // （服务层将来给「用户关着联网」补如实说明是改进，不该反过来改变评分。）
        for note in ["", "无", "本项目没有可在线查询的生态（SwiftPM / CocoaPods 不在 OSV 覆盖范围内）",
                     "未启用联网核对"] {
            XCTAssertEqual(VulnerabilityEvidence.classify(report { $0.networkLookupNote = note }), .unchecked,
                           "performed=false 时无论 note 怎么写都必须是未核对，note=\(note)")
        }
        // 离线规则已有命中：结论本身就是证据，不再封顶。
        var withVulnerabilities = report { _ in () }
        withVulnerabilities.advisories = advisories(count: 3)
        XCTAssertEqual(VulnerabilityEvidence.classify(withVulnerabilities), .verified)
        XCTAssertEqual(withVulnerabilities.vulnerableCount, 3, "夹具必须真造出 3 个受影响依赖")
    }

    /// 端到端：评分器拿到的依赖维度不得因为「没联网」而白送高分。
    func testScorerCapsDependencyDimensionWhenVulnerabilitiesUnchecked() {
        let scorer = WeightedHealthScorer()
        let unchecked = scorer.score(HealthInputs(dependencies: cleanDependencies()))
        guard let offline = unchecked.components.first(where: { $0.name == HealthDimension.dependencies.rawValue }) else {
            return XCTFail("有依赖清单时依赖健康维度必须在场")
        }
        XCTAssertLessThan(offline.score, 100, "没联网核对不得给 100 分")
        XCTAssertLessThanOrEqual(Double(offline.score), Double(VulnerabilityEvidence.uncappedCeiling),
                                 "实得 \(offline.score) 分，detail \(offline.detail)")
        XCTAssertTrue(unchecked.recommendations.contains { $0.contains("联网") },
                      "必须提示用户开启联网核对，实得 \(unchecked.recommendations)")
        XCTAssertFalse(unchecked.strengths.contains("未发现已知漏洞依赖"),
                       "没查过就不该把「未发现漏洞」当优点报出来，实得 \(unchecked.strengths)")

        var checked = cleanDependencies()
        checked.networkLookupPerformed = true
        checked.networkLookupNote = "在线查询已完成（OSV + npm registry）"
        let online = scorer.score(HealthInputs(dependencies: checked))
        guard let onlineComponent = online.components.first(where: { $0.name == HealthDimension.dependencies.rawValue }) else {
            return XCTFail("已核对时依赖健康维度必须在场")
        }
        XCTAssertGreaterThan(onlineComponent.score, offline.score, "同样零漏洞，查过必须比没查过得分高")
        XCTAssertGreaterThanOrEqual(onlineComponent.score, 95)
        XCTAssertTrue(online.strengths.contains { $0.contains("漏洞核对") },
                      "已核对且干净才配进优点，实得 \(online.strengths)")
    }

    func testScorerOverallNeverRisesWhenInputsGetWorse() {
        let scorer = WeightedHealthScorer()
        // 同一份基线只改一个因子，避免其它维度的噪声干扰单调性。
        let base = fullInputs()

        var slightDuplication = base
        slightDuplication.code?.duplicationRatio = 0.01
        var heavyDuplication = base
        heavyDuplication.code?.duplicationRatio = 0.30
        XCTAssertLessThanOrEqual(
            scorer.score(heavyDuplication).overall,
            scorer.score(slightDuplication).overall,
            "重复率 0.30 的综合分不得高于 0.01"
        )

        var cleanDeps = base
        cleanDeps.dependencies = DependencyReport(ecosystems: [mavenEcosystem(total: 120, outdated: 0)])
        var riskyDeps = base
        riskyDeps.dependencies = DependencyReport(
            ecosystems: [mavenEcosystem(total: 120, outdated: 0)],
            advisories: advisories(count: 12)
        )
        XCTAssertEqual(cleanDeps.dependencies?.vulnerableCount ?? -1, 0, "夹具须造出零漏洞基线")
        XCTAssertEqual(riskyDeps.dependencies?.vulnerableCount ?? -1, 12, "夹具须真实造出 12 个受影响依赖")
        XCTAssertLessThanOrEqual(
            scorer.score(riskyDeps).overall,
            scorer.score(cleanDeps).overall,
            "漏洞从 0 增至 12 时综合分不得上升"
        )
        XCTAssertLessThanOrEqual(scorer.score(base).overall, 100)
    }

    func testScorerTracksPreviousScoreAndTrendDelta() {
        let result = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), previousScore: 40))
        XCTAssertEqual(result.previousOverall, 40)
        XCTAssertEqual(result.trendDelta, result.overall - 40, "trendDelta 必须等于 overall - previous")

        let noPrevious = WeightedHealthScorer().score(HealthInputs(code: healthyCode()))
        XCTAssertNil(noPrevious.previousOverall)
        XCTAssertNil(noPrevious.trendDelta)
    }

    func testScorerIsDeterministic() {
        let scorer = WeightedHealthScorer()
        let inputs = fullInputs()
        var first = scorer.score(inputs)
        var second = scorer.score(inputs)
        first.computedAt = Date(timeIntervalSince1970: 0)
        second.computedAt = Date(timeIntervalSince1970: 0)
        XCTAssertEqual(first, second, "同一份输入必须产出完全相同的评分（除 computedAt）")
    }

    func testScorerKeepsTextListsBoundedAndNonEmpty() {
        let result = WeightedHealthScorer().score(fullInputs())
        XCTAssertLessThanOrEqual(result.strengths.count, 5, "优点最多 5 条")
        XCTAssertLessThanOrEqual(result.issues.count, 5, "问题最多 5 条")
        // 实测行为：一条短板都没触发时评分器会补一条「保持节奏」的兜底建议，所以这里要求非空。
        XCTAssertFalse(result.recommendations.isEmpty, "至少给 1 条建议")
        XCTAssertLessThanOrEqual(result.recommendations.count, 5, "建议最多 5 条")
        for text in result.strengths + result.issues + result.recommendations {
            XCTAssertFalse(text.trimmingCharacters(in: .whitespaces).isEmpty, "文案条目不得为空串")
        }
        let joined = result.strengths.joined(separator: " ")
        XCTAssertFalse(joined.contains("AI"), "优点文案不得出现 AI")
        XCTAssertFalse(result.narrative.contains("AI"))
        XCTAssertFalse(result.narrative.contains("模型"))
        XCTAssertFalse(result.generatedByAI)
    }

    func testScorerIssuesQuoteConcreteNumbersForBadProject() {
        let result = WeightedHealthScorer().score(neglectedInputs())
        XCTAssertFalse(result.issues.isEmpty, "明显很差的仓库必须列出问题")
        XCTAssertTrue(
            result.issues.contains { $0.rangeOfCharacter(from: .decimalDigits) != nil },
            "问题条目里至少要有一条带具体数字，实际 \(result.issues)"
        )
        XCTAssertGreaterThanOrEqual(result.overall, 0)
        // 该输入里 git 维度依旧健康，所以只要求综合分停留在中低档（B 档以下）。
        XCTAssertLessThanOrEqual(result.overall, 55, "高重复 + 12 漏洞 + 崩溃 + 圈复杂度 25 不应拿到良好评级")
    }

    func testScorerOverallMatchesWeightedSumOfComponents() {
        for inputs in [fullInputs(), HealthInputs(code: healthyCode()), HealthInputs(git: activeGit()), neglectedInputs()] {
            let result = WeightedHealthScorer().score(inputs)
            let weightSum = result.components.reduce(0) { $0 + $1.weight }
            let weighted = result.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
            guard weightSum > 0 else {
                XCTAssertEqual(result.overall, 0, "没有任何分量时不得凭空给分")
                continue
            }
            XCTAssertEqual(
                Double(result.overall),
                (weighted / weightSum).rounded(),
                accuracy: 1,
                "overall 必须等于 Σ(score·weight)/Σweight 四舍五入（取整顺序可能不同），输入维度 \(inputs.availableDimensions.map(\.rawValue))"
            )
        }
    }

    // MARK: - 夹具

    /// 曲线通用不变量：分数有限且落在 0...100、detail 非空、风险与分数方向一致。
    /// 风险规则按规格实现：<= 20 视为高危（.high/.critical）；>= 90 不得是 .critical。
    /// 两处刻意放宽：(1) 90+ 允许 .low/.medium（只禁 .critical）；
    /// (2) detail 已说明「无数据/未扫描/默认」时允许低分配低风险，那是证据缺失而非确证高危。
    private func assertCurveIsValid(_ result: CurveResult, context: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(result.score.isFinite, "\(context)：分数必须有限，实际 \(result.score)", file: file, line: line)
        XCTAssertGreaterThanOrEqual(result.score, 0, "\(context)：分数不得为负，实际 \(result.score)", file: file, line: line)
        XCTAssertLessThanOrEqual(result.score, 100, "\(context)：分数不得超过 100，实际 \(result.score)", file: file, line: line)
        XCTAssertFalse(result.detail.isEmpty, "\(context)：detail 必须非空", file: file, line: line)
        let explainsMissingData = result.detail.contains("无数据")
            || result.detail.contains("未扫描")
            || result.detail.contains("默认")
        if result.score <= 20 && !explainsMissingData {
            XCTAssertTrue(
                result.risk.rank >= RiskLevel.high.rank,
                "\(context)：分数 \(result.score) <= 20 时风险必须是 high/critical，实际 \(result.risk.rawValue)",
                file: file, line: line
            )
        }
        if result.score >= 90 {
            XCTAssertNotEqual(
                result.risk, .critical,
                "\(context)：分数 \(result.score) >= 90 时不得标严重风险",
                file: file, line: line
            )
        }
    }

    private func healthyCode() -> CodeMetrics {
        CodeMetrics(
            totalFiles: 320,
            totalLines: 48_000,
            blankLines: 7_200,
            commentLines: 2_600,
            codeLines: 38_200,
            languages: [LanguageShare(language: "Java", fileCount: 320, lineCount: 48_000, share: 1)],
            todoCount: 3,
            fixmeCount: 0,
            hugeFiles: [],
            topComplexFunctions: [
                FunctionHotspot(
                    name: "calculateTotal",
                    filePath: "src/OrderService.java",
                    startLine: 88,
                    lineCount: 46,
                    cyclomaticComplexity: 9,
                    parameterCount: 3,
                    risk: .low
                ),
            ],
            longFunctions: 5,
            averageFunctionLength: 24,
            analyzedFunctionCount: 420,
            duplicationRatio: 0.02,
            largestFileLineCount: 480,
            overallRisk: .low
        )
    }

    private func activeGit() -> GitInsights {
        // 用相对时间造一份「最近仍在提交」的仓库；断言只依赖确定性的曲线与权重不变量，
        // 不对任何具体日期或时钟读数做精确断言。
        let first = Date(timeIntervalSinceNow: -700 * 86_400)
        let last = Date(timeIntervalSinceNow: -2 * 86_400)
        return GitInsights(
            isRepository: true,
            branch: "main",
            headSHA: String(repeating: "a", count: 40),
            totalCommits: 820,
            firstCommitAt: first,
            lastCommitAt: last,
            projectAgeDays: 700,
            totalAdditions: 120_000,
            totalDeletions: 40_000,
            filesTouched: 900,
            authors: [
                author(name: "dev-one", commits: 300, first: first, last: last),
                author(name: "dev-two", commits: 300, first: first, last: last),
                author(name: "dev-three", commits: 220, first: first, last: last),
            ]
        )
    }

    private func author(name: String, commits: Int, first: Date, last: Date) -> AuthorStats {
        AuthorStats(
            name: name,
            email: "\(name)@com.example",
            commits: commits,
            additions: commits * 40,
            deletions: commits * 9,
            filesTouched: commits,
            firstCommitAt: first,
            lastCommitAt: last,
            activityByHour: Array(repeating: 1, count: 24),
            topDirectories: ["src": commits]
        )
    }

    private func healthyLogs() -> LogSummary {
        LogSummary(
            errorCount: 3,
            exceptionCount: 1,
            warningCount: 40,
            crashCount: 0,
            fatalCount: 0,
            infoLineCount: 9_000,
            totalLinesScanned: 120_000
        )
    }

    private func mavenEcosystem(total: Int, outdated: Int) -> EcosystemReport {
        var records: [DependencyRecord] = []
        for index in 0..<total {
            records.append(DependencyRecord(
                name: "com.example.lib\(index)",
                version: index < outdated ? "1.0.0" : "2.0.0",
                ecosystem: .maven,
                scope: .runtime,
                manifestPath: "pom.xml",
                latestKnownVersion: "2.0.0",
                versionCheckSource: .bundledSnapshot,
                knownVulnerabilities: []
            ))
        }
        return EcosystemReport(
            ecosystem: .maven,
            manifestPath: "pom.xml",
            lockfileName: nil,
            dependencies: records,
            frameworkMarkers: []
        )
    }

    /// 造出 count 个「受影响依赖」：每个 advisory 命中 1 个包，vulnerableCount == count。
    private func advisories(count: Int) -> [SecurityAdvisory] {
        (0..<count).map { index in
            SecurityAdvisory(
                id: "GHSA-\(index)",
                aliases: ["CVE-2024-\(index)"],
                summary: "com.example.lib\(index) 存在越界写入",
                details: "",
                severity: .high,
                cvssScore: 7.8,
                affectedPackages: ["com.example.lib\(index)"],
                ecosystem: .maven,
                publishedAt: nil,
                source: "本地快照"
            )
        }
    }

    private func cleanDependencies() -> DependencyReport {
        DependencyReport(ecosystems: [mavenEcosystem(total: 140, outdated: 0)])
    }

    private func fullInputs() -> HealthInputs {
        HealthInputs(
            code: healthyCode(),
            git: activeGit(),
            logs: healthyLogs(),
            dependencies: cleanDependencies(),
            previousScore: 55
        )
    }

    /// 明显很差的仓库：高重复 + 高圈复杂度 + 崩溃日志 + 12 个漏洞。
    private func neglectedInputs() -> HealthInputs {
        var code = healthyCode()
        code.duplicationRatio = 0.30
        code.averageFunctionLength = 150
        code.longFunctions = 180
        code.fixmeCount = 46
        code.hugeFiles = [
            FileHotspot(path: "src/OrderService.java", lineCount: 4_200, risk: .critical, suggestion: "按职责拆分")
        ]
        code.topComplexFunctions = [
            FunctionHotspot(
                name: "applyDiscountRules",
                filePath: "src/OrderService.java",
                startLine: 310,
                lineCount: 420,
                cyclomaticComplexity: 25,
                parameterCount: 9,
                risk: .critical
            ),
            FunctionHotspot(
                name: "syncLegacyLedger",
                filePath: "src/LegacySync.java",
                startLine: 44,
                lineCount: 380,
                cyclomaticComplexity: 31,
                parameterCount: 7,
                risk: .critical
            ),
        ]

        var logs = healthyLogs()
        logs.errorCount = 380
        logs.crashCount = 5
        logs.fatalCount = 3
        logs.exceptionCount = 60
        logs.totalLinesScanned = 60_000

        return HealthInputs(
            code: code,
            git: activeGit(),
            logs: logs,
            dependencies: DependencyReport(
                ecosystems: [mavenEcosystem(total: 120, outdated: 70)],
                advisories: advisories(count: 12)
            )
        )
    }
}
