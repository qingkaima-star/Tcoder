/// OWNER: WS-X3 TestSplit —— 自 HealthScoreCurvesTests.swift 拆出，活跃度/BusFactor/稳定性/依赖健康与总评文案。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension HealthScoreCurvesTests {

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
