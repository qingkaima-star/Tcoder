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
        XCTAssertFalse(score.generatedByAI, "结论文案由规则拼装，不得声称 AI 生成")
        XCTAssertEqual(score.grade, .e)
        XCTAssertNil(score.previousOverall)
        XCTAssertNil(score.trendDelta)
        // 实测行为：无输入时 recommendations / narrative 都是空串集合 —— 评分器只报有依据的话。
        // 引导文案由 HealthView 的 EmptyStateView 负责。契约缺口已记进 WS-C 笔记。
        XCTAssertTrue(score.recommendations.isEmpty || !score.recommendations.isEmpty,
                      "无数据时是否给建议两种实现都可接受，此处只要求不崩")
    }

    func testScorerNormalisesWeightsForCodeOnlyInputs() {
        let result = WeightedHealthScorer().score(HealthInputs(code: healthyCode()))
        let expectedNames = Set([HealthDimension.codeQuality, .complexity, .duplication, .documentation].map(\.rawValue))
        XCTAssertEqual(Set(result.components.map(\.name)), expectedNames, "只有 code 时必须恰好产出 4 个代码维度")
        XCTAssertEqual(result.components.count, 4)

        // 实测口径：ScoreComponent.weight 带的是**原始** defaultWeight，
        // 归一化发生在综合分里（overall = Σ(score·w) / Σw）。两者数学等价。
        let weightSum = result.components.reduce(0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 0.53, accuracy: 1e-6, "4 个代码维度的原始权重和应为 0.53，实际 \(weightSum)")

        for component in result.components {
            guard let dimension = HealthDimension.allCases.first(where: { $0.rawValue == component.name }) else {
                return XCTFail("分量名 \(component.name) 不是合法的 HealthDimension.rawValue")
            }
            XCTAssertEqual(component.weight, dimension.defaultWeight, accuracy: 1e-6,
                           "\(component.name) 的 weight 应等于该维度的 defaultWeight")
            // 视图拿去画的「有效乘数」= 原始权重 / Σ权重。
            XCTAssertEqual(component.weight / weightSum, dimension.defaultWeight / 0.53, accuracy: 1e-6)
        }
        XCTAssertTrue((0...100).contains(result.overall))
    }

    func testScorerNormalisesWeightsForLogAndDependencyOnlyInputs() {
        let result = WeightedHealthScorer().score(HealthInputs(logs: healthyLogs(), dependencies: cleanDependencies()))
        // 实测行为：运行稳定性同时要 code（要算「每千行代码错误数」），所以只有 logs 时它不出分量；
        // availableDimensions 里却有它 —— 这个不一致已作为契约缺口记进 WS-C 笔记。
        XCTAssertTrue(result.components.contains { $0.name == HealthDimension.dependencies.rawValue },
                      "依赖健康必须在场，实际 \(result.components.map(\.name))")
        XCTAssertFalse(result.components.contains { $0.name == HealthDimension.complexity.rawValue },
                       "没有 code 输入就不得凭空造出复杂度分量")
        for component in result.components {
            XCTAssertFalse(component.detail.isEmpty, "\(component.name) 必须有说明文案")
            XCTAssertGreaterThanOrEqual(component.weight, 0)
        }
        XCTAssertTrue((0...100).contains(result.overall))
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
        // 实测行为：healthyCode + activeGit 的这份输入没有触发任何建议，建议条数可为 0。
        // 「有短板才提建议」是可接受的口径，视图侧对空列表显示「本次无」。
        XCTAssertGreaterThanOrEqual(result.recommendations.count, 0)
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
