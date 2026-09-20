import XCTest
@testable import TcoderMonitor

/// WS-R 诚实性 P1 修复钉住的契约：**没有证据 ≠ 好证据**。
///
/// 与已合入的两个正确样板同源（`WeightedHealthScorer` 的复杂度守卫、依赖健康三态）：
/// 某个维度的输入缺失时，该维度**缺席**（不参与计分也不得分），
/// 而不是拿一个偏高的默认分挤进综合分。缺席维度由 `Views/Health` 的「缺失维度」通路呈现。
///
/// 这里只断言**结构**（哪个维度在场/缺席、文案有没有越界宣称、两条硬契约），
/// 不断言任何锚点数值——锚点是用户亲自定的对外承诺，改动等于改产品规约。
final class HonestyP1HealthTests: XCTestCase {

    // MARK: - 空代码报告：一个维度都不该在场

    /// 一个「扫了但什么源码都没扫到」的 CodeMetrics（空目录、纯资源目录、解析器不认识的语言）。
    /// 修复前：重复度按 0% 给满分、注释维度给 50 默认分，综合分凭空落到 80 上下。
    func testCodeReportWithoutASingleScannedLineProducesNoScoredDimension() {
        let result = WeightedHealthScorer().score(HealthInputs(code: CodeMetrics()))

        XCTAssertEqual(result.components.map(\.name), [],
                       "零行代码时四个代码维度都没有证据，不得产出任何分量：\(result.components.map { "\($0.name)=\($0.score)" })")
        XCTAssertEqual(result.overall, 0, "没有可计分证据时综合分必须是 0，不得用默认分凑出一个及格分")
        XCTAssertFalse(result.strengths.contains { $0.contains("重复") },
                       "零代码行不得写「重复代码率低」：\(result.strengths)")
        XCTAssertFalse(result.strengths.contains { $0.contains("注释") },
                       "零代码行不得写注释密度优点：\(result.strengths)")
    }

    // MARK: - 逐维度缺席

    func testDuplicationDimensionIsAbsentWhenThereAreNoCodeLines() {
        var code = CodeMetrics()
        code.totalFiles = 12
        code.totalLines = 900          // 全是注释/空行
        code.commentLines = 900
        code.codeLines = 0              // 一行代码都没扫到
        code.topComplexFunctions = [hotspot(complexity: 9)]
        code.analyzedFunctionCount = 21
        code.averageCyclomaticComplexity = 4

        let components = WeightedHealthScorer().score(HealthInputs(code: code)).components
        XCTAssertFalse(components.contains { $0.name == HealthDimension.duplication.rawValue },
                       "重复率的分母是代码行，0 行时「0% 重复」是没测到而不是查过干净：\(componentList(components))")
        XCTAssertTrue(components.contains { $0.name == HealthDimension.documentation.rawValue },
                       "注释维度有 900 行分母，应当照常在场：\(componentList(components))")
    }

    func testDocumentationDimensionIsAbsentWhenThereAreNoSourceLines() {
        var code = CodeMetrics()
        code.totalFiles = 3
        code.totalLines = 0
        code.codeLines = 0
        code.topComplexFunctions = [hotspot(complexity: 7)]
        code.analyzedFunctionCount = 9
        code.averageCyclomaticComplexity = 3

        let components = WeightedHealthScorer().score(HealthInputs(code: code)).components
        XCTAssertFalse(components.contains { $0.name == HealthDimension.documentation.rawValue },
                       "注释占比的分母 totalLines 为 0 时不得用 50 分默认值占位：\(componentList(components))")
        XCTAssertTrue(components.contains { $0.name == HealthDimension.complexity.rawValue },
                       "复杂度有真实函数证据，不该被牵连：\(componentList(components))")
    }

    /// 曲线在 `functionCount == 0` 时会给满分 100（`HealthCurves.complexity`），
    /// 所以评分器必须自己挡住「均值守着非空但分母为 0」这种自相矛盾的输入——
    /// 落盘的旧报告、外部喂进来的契约对象都可能长成这样。
    func testComplexityDimensionIsAbsentWhenTheDenominatorIsZeroEvenWithANonNilMean() {
        var code = CodeMetrics()
        code.totalFiles = 4
        code.totalLines = 120
        code.codeLines = 100
        code.averageCyclomaticComplexity = 0   // 非 nil，但
        code.analyzedFunctionCount = 0         // 一个函数都没识别出来
        code.topComplexFunctions = []

        let components = WeightedHealthScorer().score(HealthInputs(code: code)).components
        XCTAssertFalse(components.contains { $0.name == HealthDimension.complexity.rawValue },
                       "分母为 0 的均值是「读不懂」，不得评成满分复杂度：\(componentList(components))")
    }

    // MARK: - 优点文案不得越过曲线自己承认的置信度下限

    /// `worst` 在热点榜为空时取的是 `?? 0`，那不是测量出来的最大值。
    /// 全仓均值有证据、热点榜却没内容时，优点句只能不带「最高 CC」这个断言。
    func testComplexityPraiseDoesNotInventAMaximumCCFromAnEmptyHotspotList() {
        var code = CodeMetrics()
        code.totalFiles = 6
        code.totalLines = 800
        code.codeLines = 700
        code.analyzedFunctionCount = 42
        code.averageCyclomaticComplexity = 2.2
        code.topComplexFunctions = []

        let result = WeightedHealthScorer().score(HealthInputs(code: code))
        XCTAssertTrue(result.components.contains { $0.name == HealthDimension.complexity.rawValue },
                      "有全仓均值就有证据，维度该在场：\(componentList(result.components))")
        XCTAssertFalse(result.strengths.contains { $0.contains("最高 CC") },
                       "热点榜为空时「最高 CC 0」是凭空造的测量值：\(result.strengths)")
    }

    /// `HealthCurves.duplication` 对 <200 行的样本自己标注「样本过小，置信度低」。
    /// 优点卡必须守同一条线：小样本可以给分，但不能拿来当仓库级优点宣称。
    func testLowDuplicationIsNotPraisedBelowTheCurvesOwnConfidenceFloor() {
        var tiny = CodeMetrics()
        tiny.totalFiles = 1
        tiny.totalLines = 60
        tiny.codeLines = 50
        tiny.analyzedFunctionCount = 3
        tiny.averageCyclomaticComplexity = 2
        tiny.duplicationRatio = 0

        let tinyResult = WeightedHealthScorer().score(HealthInputs(code: tiny))
        XCTAssertTrue(tinyResult.components.contains { $0.name == HealthDimension.duplication.rawValue },
                      "50 行仍是真实测量，维度在场，只是不配优点：\(componentList(tinyResult.components))")
        XCTAssertFalse(tinyResult.strengths.contains { $0.contains("重复代码率低") },
                       "样本过小（曲线自标置信度低）时不得写「重复代码率低」：\(tinyResult.strengths)")

        var real = tiny
        real.totalFiles = 200
        real.totalLines = 12_000
        real.codeLines = 9_500
        real.analyzedFunctionCount = 310
        real.averageCyclomaticComplexity = 3
        real.duplicationRatio = 0.005
        let realResult = WeightedHealthScorer().score(HealthInputs(code: real))
        XCTAssertTrue(realResult.strengths.contains { $0.contains("重复代码率低") },
                      "有分母的零重复当然算优点：\(realResult.strengths)")
    }

    // MARK: - 两条硬契约在维度缺席时仍然成立

    func testWeightNormalisationAndOverallReconstructionSurviveAbsentDimensions() {
        let partial = CodeMetrics()   // 零证据：全部缺席
        let partialScore = WeightedHealthScorer().score(HealthInputs(code: partial))
        XCTAssertTrue(partialScore.components.isEmpty)
        XCTAssertEqual(partialScore.overall, 0)

        var code = CodeMetrics()
        code.totalFiles = 40
        code.totalLines = 5_000
        code.codeLines = 4_200
        code.commentLines = 300
        code.analyzedFunctionCount = 60
        code.averageCyclomaticComplexity = 5
        code.topComplexFunctions = [hotspot(complexity: 12)]
        code.duplicationRatio = 0.03
        let result = WeightedHealthScorer().score(HealthInputs(code: code))

        XCTAssertFalse(result.components.isEmpty, "有证据时必须有分量，否则下面的契约是空转")
        let weightSum = result.components.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1.0, accuracy: 1e-6,
                       "分量 weight 必须自己归一到 1.0（含缺席维度摊薄之后），实际 \(weightSum)")
        let reconstructed = result.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(result.overall), reconstructed, accuracy: 1.0,
                       "overall 必须等于 Σ(score·weight)：\(result.overall) vs \(reconstructed)")
    }

    // MARK: - 缺日志维度：不再给默认分，整个维度缺席（#46）。
    //         优点口径仍由 WS-C 的 `testStabilityPraiseRequiresActuallyScannedLogs` 钉。

    func testStabilityIsAbsentRatherThanDefaultedWhenNoLogsScanned() {
        var logs = LogSummary()
        logs.totalLinesScanned = 0
        let result = WeightedHealthScorer().score(HealthInputs(logs: logs))

        XCTAssertFalse(result.components.contains { $0.name == HealthDimension.stability.rawValue },
                       "零日志时这个维度必须缺席：它曾是全表权重最高的一项（0.178），"
                           + "按默认分在场等于用『没查』换 15 分。实得 \(componentList(result.components))")
        XCTAssertTrue(result.recommendations.contains { $0.contains("没有可扫描的日志") },
                      "缺席必须说明原因，实得 \(result.recommendations)")
    }

    // MARK: - 夹具

    private func componentList(_ components: [ScoreComponent]) -> String {
        components.map { "\($0.name)=\($0.score)" }.joined(separator: ", ")
    }

    private func hotspot(complexity: Int) -> FunctionHotspot {
        FunctionHotspot(name: "handle", filePath: "Sources/App.swift", startLine: 10,
                        lineCount: 30, cyclomaticComplexity: complexity, parameterCount: 2, risk: .low)
    }
}
