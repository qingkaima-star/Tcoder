import XCTest
@testable import TcoderMonitor

/// WS-C 健康评分单测：`WeightedHealthScorer` 的加权不变量与综合分契约。
///
/// 只测确定性行为：不读文件、不依赖系统时钟（活跃度一律用 `daysSinceLastCommit` 入参）、
/// 不钉死具体分数（除规格点名的锚点外，评分器侧只做不变量/单调性断言）。
/// 拆自 HealthScoreTests.swift，断言与用例一字未改（WS-V）。
final class HealthScoreScorerTests: HealthScoreTestCase {
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
        // 均值的来源必须写明是全仓多少个函数，否则「平均圈复杂度 4」读起来像凭空冒出来的。
        XCTAssertTrue(complexity.detail.contains("均值为全仓 420 个函数"),
                      "detail 必须标明均值的全仓分母，实得 \(complexity.detail)")
        // CC≥16 个数与最大 CC 只能从截断的热点榜数出来，混在同一句里必须标出榜内口径，
        // 否则会被读成「全仓有 N 个函数 CC≥16」——那是把风险报小。
        XCTAssertTrue(complexity.detail.contains("CC≥16 与最大 CC 只统计热点榜前"),
                      "混合口径必须逐项标明统计范围，实得 \(complexity.detail)")
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

}
