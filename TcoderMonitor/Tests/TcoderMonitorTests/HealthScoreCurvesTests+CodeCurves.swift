/// OWNER: WS-X3 TestSplit —— 自 HealthScoreCurvesTests.swift 拆出，重复率/注释率/复杂度/代码质量四条曲线的锚点与单调性。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension HealthScoreCurvesTests {

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

}
