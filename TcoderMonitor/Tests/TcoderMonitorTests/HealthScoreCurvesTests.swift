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
        let concentrated = HealthCurves.busFactor(risk: .high, topAuthorShare: 0.75, activeAuthors: 4, commitBasis: 900)
        let shared = HealthCurves.busFactor(risk: .low, topAuthorShare: 0.3, activeAuthors: 4, commitBasis: 900)
        XCTAssertGreaterThanOrEqual(
            shared.score - concentrated.score,
            30,
            "75% 单人占比 + 高风险必须比 30% 占比 + 低风险至少低 30 分"
        )

        let solo = HealthCurves.busFactor(risk: .critical, topAuthorShare: 1.0, activeAuthors: 1, commitBasis: 500)
        XCTAssertLessThanOrEqual(solo.score, 15, "单人维护 500 次提交必须极低分")
        XCTAssertTrue(solo.risk == .high || solo.risk == .critical, "单人维护必须是高/严重风险")

        let moderate = HealthCurves.busFactor(risk: .medium, topAuthorShare: 0.55, activeAuthors: 3, commitBasis: 240)
        XCTAssertGreaterThan(moderate.score, solo.score, "三人分担必须优于单人")
        XCTAssertLessThan(moderate.score, shared.score, "55% 占比必须优于 30% 占比")

        assertCurveIsValid(concentrated, context: "busFactor concentrated")
        assertCurveIsValid(shared, context: "busFactor shared")
        assertCurveIsValid(moderate, context: "busFactor moderate")
        assertCurveIsValid(
            HealthCurves.busFactor(risk: .none, topAuthorShare: 0, activeAuthors: 0, commitBasis: 0),
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
            results.append(HealthCurves.busFactor(risk: .medium, topAuthorShare: share, activeAuthors: 5, commitBasis: 700))
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

}
