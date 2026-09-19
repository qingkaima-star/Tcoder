import Foundation

/// Chief-engineer fallback scorer. Kept self-contained (no dependency on
/// ScoreCurves.swift) so it can be dropped in regardless of WS-C's progress.
final class WeightedHealthScorer: HealthScoringProviding {
    func score(_ inputs: HealthInputs) -> HealthScore {
        let available = inputs.availableDimensions

        var components: [ScoreComponent] = []
        var strengths: [String] = []
        var issues: [String] = []
        var recommendations: [String] = []

        for dimension in available {
            guard let component = evaluate(dimension, inputs, &strengths, &issues, &recommendations)
            else { continue }
            components.append(component)
        }

        if components.isEmpty {
            return HealthScore(
                computedAt: Date(),
                overall: 0,
                previousOverall: inputs.previousScore,
                components: [],
                strengths: [],
                issues: ["尚无可用指标"],
                recommendations: ["先在侧栏「添加项目」选择本地仓库目录，或点右上角「重新分析」采集指标。"],
                narrative: "尚无可用指标，无法给出健康评分；选择项目目录后会自动完成采集。",
                generatedByAI: false
            )
        }

        // Contract: published component weights must themselves sum to 1.0, so a
        // consumer recomputing sum(score * weight) reproduces `overall` exactly.
        let totalWeight = components.reduce(0) { $0 + $1.weight }
        guard totalWeight > 0 else { return HealthScore(overall: 0) }
        components = components.map { var c = $0; c.weight = c.weight / totalWeight; return c }

        let overall = Int(components.reduce(0.0) { $0 + Double($1.score) * $1.weight }.rounded())
        let clampedOverall = min(100, max(0, overall))

        if recommendations.isEmpty {
            recommendations.append("当前无明显短板，保持提交节奏并持续监控新增高复杂度函数。")
        }

        return HealthScore(
            computedAt: Date(),
            overall: clampedOverall,
            previousOverall: inputs.previousScore,
            components: components.sorted { $0.score < $1.score },
            strengths: Array(strengths.prefix(5)),
            issues: Array(issues.prefix(5)),
            recommendations: Array(recommendations.prefix(5)),
            narrative: Self.narrative(overall: clampedOverall, components: components),
            generatedByAI: false
        )
    }

    // MARK: Per-dimension evaluation

    private func evaluate(
        _ dimension: HealthDimension,
        _ inputs: HealthInputs,
        _ strengths: inout [String],
        _ issues: inout [String],
        _ recommendations: inout [String]
    ) -> ScoreComponent? {
        switch dimension {
        case .complexity:
            guard let code = inputs.code else { return nil }
            let hot = code.topComplexFunctions.filter { $0.cyclomaticComplexity >= 16 }.count
            let worst = code.topComplexFunctions.map(\.cyclomaticComplexity).max() ?? 0
            var value = 100.0
            value -= Double(hot) * 4
            value -= max(0, Double(worst) - 10) * 1.8
            value -= max(0, Double(code.averageFunctionLength) - 25) * 0.8
            let score = clamp(value)
            if score >= 85 { strengths.append("函数复杂度可控（最高 CC \(worst)）") }
            if score <= 60 {
                issues.append("\(hot) 个函数圈复杂度 ≥16，最高 \(worst)")
                recommendations.append("优先拆分最高复杂度函数，用早返回替代嵌套分支")
            }
            return component(dimension, score, "最高 CC \(worst)，\(hot) 个函数 ≥16，平均函数长 \(code.averageFunctionLength) 行",
                             risk(forCC: worst, hot: hot))

        case .duplication:
            guard let code = inputs.code else { return nil }
            let percent = code.duplicationRatio * 100
            let score: Int
            switch percent {
            case ..<5: score = 100
            case ..<12: score = clamp(100 - (percent - 5) * 3)
            case ..<25: score = clamp(79 - (percent - 12) * 3.1)
            default: score = clamp(max(0, 39 - (percent - 25) * 1.6))
            }
            if score >= 85 { strengths.append(String(format: "重复代码率低（%.1f%%）", percent)) }
            if score <= 60 {
                issues.append(String(format: "重复代码 %.1f%%，共 %d 处重复块", percent, code.duplicatedBlocks.count))
                recommendations.append("抽取重复块为共享工具或基类，优先处理跨服务重复")
            }
            return component(dimension, score, String(format: "重复率 %.1f%%（%.0f 行命中重复块）", percent, Double(code.codeLines) * code.duplicationRatio),
                             percent >= 25 ? .high : percent >= 12 ? .medium : .low)

        case .codeQuality:
            guard let code = inputs.code, code.totalFiles > 0 else { return nil }
            let hugeShare = Double(code.hugeFiles.count) / Double(max(code.totalFiles, 1)) * 100
            var value = 100.0
            value -= max(0, hugeShare - 0.5) * 12
            value -= Double(code.fixmeCount) * 0.6
            value -= Double(code.todoCount) * 0.15
            let score = clamp(value)
            if score >= 85 { strengths.append("文件规模健康，巨大文件占比低") }
            if let worst = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }), worst.lineCount >= 1500 {
                issues.append("\(worst.path.split(separator: "/").last ?? "?") \(NumberFormat.grouped(worst.lineCount)) 行，远超单文件上限")
                recommendations.append(worst.suggestion)
            }
            return component(dimension, score, String(format: "%d 个超大文件（占比 %.2f%%），FIXME %d 处",
                                                      code.hugeFiles.count, hugeShare, code.fixmeCount),
                             hugeShare > 3 ? .high : hugeShare > 1 ? .medium : .low)

        case .documentation:
            guard let code = inputs.code else { return nil }
            let ratio = code.commentRatio * 100
            let score: Int
            switch ratio {
            case ..<1: score = 45
            case ..<2: score = 70
            case ..<5: score = 88
            case ...15: score = 100
            default: score = clamp(100 - (ratio - 15) * 2.5)
            }
            if score >= 95 { strengths.append(String(format: "注释密度适中（%.1f%%）", ratio)) }
            if score < 70 { recommendations.append("为公共 API 与复杂分支补充说明性注释") }
            return component(dimension, score, String(format: "注释行占比 %.1f%%", ratio), ratio < 2 ? .medium : .low)

        case .activity:
            guard let git = inputs.git, git.totalCommits > 0 else { return nil }
            let perDay = git.commitsPerDay
            let daysSinceLast = git.lastCommitAt.map { Date().timeIntervalSince($0) / 86_400 } ?? 999
            var value = 40.0
            value += min(45, perDay * 1.6)
            value += daysSinceLast < 1 ? 15 : daysSinceLast < 3 ? 8 : daysSinceLast < 14 ? 0 : -15
            let score = clamp(value)
            if perDay >= 8 { strengths.append(String(format: "提交节奏稳定（日均 %.1f 次）", perDay)) }
            if daysSinceLast > 14 { issues.append(String(format: "已 %.0f 天无提交", daysSinceLast)) }
            return component(dimension, score, String(format: "日均 %.1f 次提交，最近一次 %@",
                                                      perDay, LogRecency.describe(git.lastCommitAt)),
                             daysSinceLast > 30 ? .medium : .low)

        case .busFactor:
            guard let git = inputs.git, let top = git.topAuthor, git.totalCommits > 0 else { return nil }
            let share = Double(top.commits) / Double(git.totalCommits)
            let authors = git.activeAuthorCount
            var value = 100.0
            value -= max(0, (share - 0.4)) * 130
            value -= authors <= 1 ? 45 : authors <= 2 ? 22 : authors <= 3 ? 8 : 0
            let score = clamp(value)
            if authors >= 4 && share < 0.45 { strengths.append("贡献分布合理（\(authors) 人，头号作者占 \(NumberFormat.percent(share, precision: 0))）") }
            if share > 0.6 { issues.append(String(format: "%@ 一人承担 %.0f%% 提交，单点风险高", top.name, share * 100)) }
            return component(dimension, score, "\(authors) 位活跃作者，头号占 \(NumberFormat.percent(share, precision: 0))", git.busFactorRisk)

        case .stability:
            guard let logs = inputs.logs else { return nil }
            // Density needs the code size; without it fall back to absolute counts
            // rather than dropping the whole dimension (availableDimensions promises it).
            let lines = inputs.code?.codeLines ?? 0
            let faults = logs.errorCount + logs.exceptionCount
            let perKloc = lines > 0 ? Double(faults) / Double(lines) * 1000 : Double(faults)
            var value = 100.0
            value -= perKloc * 6
            value -= Double(logs.crashCount) * 0.9
            value -= Double(logs.todayErrorCount) * 0.05
            let score = clamp(value)
            if logs.crashCount == 0 && perKloc < 0.5 { strengths.append("近期无崩溃，错误密度低") }
            if let worst = logs.topErrors.first, worst.count >= 10 {
                issues.append("\(worst.displayMessage) 出现 \(worst.count) 次（最近 \(worst.lastSeenDescription)）")
                recommendations.append("优先修复 Top Errors 首位，它通常掩盖了下游连锁异常")
            }
            let densityText = lines > 0
                ? String(format: "每千行 %.2f 个错误", perKloc)
                : "\(faults) 个错误（无代码规模，按绝对值计）"
            return component(dimension, score, "\(densityText)，崩溃 \(logs.crashCount) 次",
                             logs.overallRisk)

        case .dependencies:
            guard let deps = inputs.dependencies, deps.totalDependencies > 0 else { return nil }
            var value = 100.0
            value -= Double(deps.vulnerableCount) * 9
            value -= Double(deps.outdatedCount) * 1.5
            let score = clamp(value)
            if deps.vulnerableCount == 0 { strengths.append("未发现已知漏洞依赖") }
            if deps.vulnerableCount > 0 {
                issues.append("\(deps.vulnerableCount) 个已知漏洞，\(deps.outdatedCount) 个版本过旧")
                recommendations.append("先升级带严重漏洞的依赖，再统一处理过期版本")
            }
            return component(dimension, score, "\(deps.totalDependencies) 个依赖，漏洞 \(deps.vulnerableCount)，过旧 \(deps.outdatedCount)",
                             deps.riskLevel)

        case .testing:
            guard let coverage = inputs.coverage, coverage.hasData,
                  let line = coverage.overallLinePercent else { return nil }
            let score: Int
            switch line {
            case ..<20: score = 20
            case ..<40: score = 40
            case ..<60: score = 62
            case ..<75: score = 78
            case ..<85: score = 90
            default: score = 100
            }
            if line >= 75 { strengths.append(String(format: "测试覆盖率 %.1f%%", line)) }
            else { recommendations.append(String(format: "将行覆盖率从 %.1f%% 提升到 75%% 以上", line)) }
            return component(dimension, score,
                             String(format: "行覆盖 %.1f%%，分支覆盖 %@", line,
                                    coverage.overallBranchPercent.map { String(format: "%.1f%%", $0) } ?? "无数据"),
                             coverage.riskLevel)
        }
    }

    // MARK: Helpers

    private func component(_ dimension: HealthDimension, _ score: Int, _ detail: String,
                           _ risk: RiskLevel) -> ScoreComponent {
        ScoreComponent(name: dimension.rawValue, score: clamp(Double(score)),
                       weight: dimension.defaultWeight, detail: detail, risk: risk)
    }

    private func clamp(_ value: Double) -> Int { min(100, max(0, Int(value.rounded()))) }

    private func risk(forCC worst: Int, hot: Int) -> RiskLevel {
        if worst >= 40 || hot >= 20 { return .critical }
        if worst >= 25 || hot >= 10 { return .high }
        if worst >= 16 || hot >= 4 { return .medium }
        return hot > 0 ? .low : .none
    }

    private static func narrative(overall: Int, components: [ScoreComponent]) -> String {
        let grade = HealthGrade(score: overall)
        let best = components.max(by: { $0.score < $1.score })
        let worst = components.min(by: { $0.score < $1.score })
        var text = "综合 \(overall)/100（\(grade.rawValue)）"
        if let best { text += "；最稳的是\(best.name)" }
        if let worst, worst.score < 80 { text += "，最需改进是\(worst.name)（\(worst.score) 分）" }
        else { text += "；各维度均衡" }
        return text + "。"
    }
}
