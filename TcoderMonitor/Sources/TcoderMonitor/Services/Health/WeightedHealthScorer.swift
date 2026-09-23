import Foundation

/// WS-C 健康评分入口：所有 0~100 的分数都由 `HealthCurves` 的显式锚点折算得出，
/// 本文件只负责三件事 —— 取分量、把权重归一化后加权、按同一批分量派生「代码口径」副读数。
///
/// 为什么不内联算法：这套分数是要对外承诺「依据是什么」的收费点，
/// 锚点表集中在 ScoreCurves.swift 里才能逐条标定与回归（HealthScoreTests A~G 就是它的契约）。
///
/// 逐维度的曲线选择与文案派生在三个扩展文件里（按维度族切分，每族一个文件）：
/// `HealthCodeDimensions.swift`（代码口径成员）、`HealthTeamDimensions.swift`（Git 历史两项）、
/// `HealthRuntimeDimensions.swift`（日志/依赖/覆盖率）。
final class WeightedHealthScorer: HealthScoringProviding {
    func score(_ inputs: HealthInputs) -> HealthScore {
        var components: [ScoreComponent] = []
        var texts = DimensionTexts()
        for dimension in inputs.availableDimensions {
            let outcome = evaluate(dimension, inputs)
            // 缺席维度的文案照样要留：「没有可扫描的日志所以本维度不计分」这条建议，
            // 恰恰是分数缺席的解释，不能因为不计分就把它一起丢掉。
            texts.absorb(outcome)
            guard let curve = outcome.curve else { continue }
            components.append(ScoreComponent(name: dimension.rawValue, score: WeightedHealthScorer.clamped(curve.score),
                                             weight: dimension.defaultWeight,
                                             detail: curve.detail, risk: curve.risk))
        }

        let totalWeight = components.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return WeightedHealthScorer.noEvidenceScore(inputs, texts) }

        // 契约：对外发布的 weight 自身归一到 1.0，消费方 Σ(score·weight) 能复现 overall。
        let normalized = components.map { var copy = $0; copy.weight = copy.weight / totalWeight; return copy }
        let overall = WeightedHealthScorer.clamped(
            normalized.reduce(0.0) { $0 + Double($1.score) * $1.weight })
        if texts.recommendations.isEmpty {
            // 这句垫白以前写「保持提交节奏」—— 一条**没有任何维度报出来的**节奏建议，
            // 与曲线对同一个日均频率的折算各说一次（台账 RD-29 的双计形态）。
            // 现在只说能证实的部分：没有建议 = 在场分量都在可接受区间，且没人被额外加分。
            texts.recommendations.append("当前无明显短板：在场维度都落在可接受区间，"
                + "综合分只由这些分量按权重算出，没有额外加分项。")
        }

        return HealthScore(
            computedAt: Date(),
            overall: overall,
            previousOverall: inputs.previousScore,
            components: normalized.sorted { $0.score < $1.score },
            strengths: Array(texts.strengths.prefix(5)),
            issues: Array(texts.issues.prefix(5)),
            recommendations: Array(texts.recommendations.prefix(5)),
            narrative: HealthCurves.narrative(overall: overall,
                                              components: normalized.map { (name: $0.name, score: $0.score) }),
            generatedByAI: false,
            codeScope: WeightedHealthScorer.codeScope(from: normalized)
        )
    }

    // MARK: - 逐维度分派

    private func evaluate(_ dimension: HealthDimension, _ inputs: HealthInputs) -> DimensionOutcome {
        switch dimension {
        case .complexity: return complexityOutcome(inputs)
        case .duplication: return duplicationOutcome(inputs)
        case .codeQuality: return codeQualityOutcome(inputs)
        case .documentation: return documentationOutcome(inputs)
        case .activity: return activityOutcome(inputs)
        case .busFactor: return busFactorOutcome(inputs)
        case .stability: return stabilityOutcome(inputs)
        case .dependencies: return dependenciesOutcome(inputs)
        case .testing: return testingOutcome(inputs)
        }
    }

    // MARK: - 代码口径副读数

    /// 只在**已计分的分量**里按 `belongsToCodeScope` 挑成员，用同一套归一化权重再加权。
    /// 刻意不复用曲线、不改任何分值：两个数必须来自同一批分量，否则同一份报告自己打自己脸。
    static func codeScope(from components: [ScoreComponent]) -> HealthSubScore? {
        let memberNames = Set(HealthDimension.allCases.filter(\.belongsToCodeScope).map(\.rawValue))
        let included = components.filter { memberNames.contains($0.name) }
        guard !included.isEmpty else { return nil }
        let excluded = components.filter { !memberNames.contains($0.name) }.map(\.name)
        let weightSum = included.reduce(0.0) { $0 + $1.weight }
        guard weightSum > 0 else { return nil }
        return HealthSubScore(
            label: "工程质量（代码口径）",
            overall: clamped(included.reduce(0.0) { $0 + Double($1.score) * ($1.weight / weightSum) }),
            includedDimensions: included.map(\.name),
            excludedDimensions: excluded,
            note: codeScopeNote(excluded: excluded)
        )
    }

    /// 排除项必须自己说清为什么被排除——否则这个副读数就是"挑好看的口径"。
    private static func codeScopeNote(excluded: [String]) -> String {
        guard !excluded.isEmpty else {
            return "本次所有参与计分的维度都属于代码口径，因此它与综合分同源同值。"
        }
        return "代码口径只统计靠改本仓库代码就能抬起来的维度；已排除 \(excluded.joined(separator: "、"))"
            + "——它们量的是提交历史的节奏与署名分布、第三方依赖与运行日志，不是这份代码本身的好坏。"
    }

    // MARK: - 无证据时的兜底报告

    /// 全部候选维度都因缺证据而缺席时，不能拿「请先添加项目」这套引导文案把真实原因盖掉：
    /// 项目可能扫得好好的（比如已经列出 52 个依赖），只是这一维度不敢计分。
    private static func noEvidenceScore(_ inputs: HealthInputs, _ texts: DimensionTexts) -> HealthScore {
        let guidance = "先在侧栏「添加项目」选择本地仓库目录，或点右上角「重新分析」采集指标。"
        let keptRecommendations = texts.recommendations.isEmpty ? [guidance] : texts.recommendations
        let keptIssues = texts.issues.isEmpty ? ["尚无可用指标"] : texts.issues
        let narrative = inputs.availableDimensions.isEmpty
            ? "尚无可用指标，无法给出健康评分；选择项目目录后会自动完成采集。"
            : "已采集到输入，但\(inputs.availableDimensions.map(\.rawValue).joined(separator: "、"))"
                + "各维度都缺少可计分证据，本次不给出综合分，避免把没测到当成好结果。"
        return HealthScore(
            computedAt: Date(),
            overall: 0,
            previousOverall: inputs.previousScore,
            components: [],
            strengths: [],
            issues: Array(keptIssues.prefix(5)),
            recommendations: Array(keptRecommendations.prefix(5)),
            narrative: narrative,
            generatedByAI: false
        )
    }

    // MARK: - Helpers

    /// 没有全仓均值、只能用热点榜均值算复杂度时，把样本口径写进文案，
    /// 避免读者把这个数当成全仓平均（`CodeMetrics.topComplexFunctions` 是封顶的榜单）。
    static func notingSample(_ curve: CurveResult, _ sampleCount: Int) -> CurveResult {
        guard sampleCount > 0 else { return curve }
        return CurveResult(score: curve.score,
                           detail: HealthCurves.noted(curve.detail,
                                                      [localizedFormat("热点样本 %1$@ 个的均值",
                                                                       NumberFormat.grouped(sampleCount))]),
                           risk: curve.risk)
    }

    /// 第①支的 detail 是**混合口径**：均值来自全仓普查，但 `CC≥16` 个数与最大 CC 只能从
    /// 截断到 20 条的热点榜里数（`Models` 没给全仓分布）。不写清楚就会被读成「全仓有 N 个
    /// 函数 CC≥16」，而那个 N 实际上只是榜内计数——这是扣分项，报小了会高估健康度。
    static func notingRepoScope(_ curve: CurveResult, functionCount: Int, sampleCount: Int) -> CurveResult {
        let meanScope = functionCount > 0
            ? localizedFormat("均值为全仓 %1$@ 个函数", HealthCurves.whole(functionCount))
            : localizedCopy("均值为全仓")
        let note = sampleCount > 0
            ? localizedFormat("%1$@；CC≥16 与最大 CC 只统计热点榜前 %2$@ 个",
                              meanScope, HealthCurves.whole(sampleCount))
            : meanScope
        return CurveResult(score: curve.score, detail: HealthCurves.noted(curve.detail, [note]),
                           risk: curve.risk)
    }

    static func clamped(_ value: Double) -> Int { min(100, max(0, Int(value.rounded()))) }
}

/// 一个维度对报告的贡献：曲线（nil = 缺证据、不参与计分）+ 三组文案。
/// 用返回值而不是 `inout` 参数，是为了让每个维度函数只有一条出口、便于逐条单测。
struct DimensionOutcome: Sendable {
    var curve: CurveResult?
    var strengths: [String] = []
    var issues: [String] = []
    var recommendations: [String] = []

    static let absent = DimensionOutcome(curve: nil)
}

/// 汇总各维度文案的容器（保持"先缺席说明、后正常建议"的原有拼装顺序）。
struct DimensionTexts {
    var strengths: [String] = []
    var issues: [String] = []
    var recommendations: [String] = []

    mutating func absorb(_ outcome: DimensionOutcome) {
        strengths.append(contentsOf: outcome.strengths)
        issues.append(contentsOf: outcome.issues)
        recommendations.append(contentsOf: outcome.recommendations)
    }
}
