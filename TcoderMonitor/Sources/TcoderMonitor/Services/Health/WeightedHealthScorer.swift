import Foundation

/// WS-C 健康评分入口：所有 0~100 的分数都由 `HealthCurves` 的显式锚点折算得出，
/// 本文件只负责三件事 —— 取输入、按分数派生中文优点/问题/建议、把权重归一化后加权。
///
/// 为什么不内联算法：这套分数是要对外承诺「依据是什么」的收费点，
/// 锚点表集中在 ScoreCurves.swift 里才能逐条标定与回归（HealthScoreTests A~G 就是它的契约）。
final class WeightedHealthScorer: HealthScoringProviding {
    func score(_ inputs: HealthInputs) -> HealthScore {
        var strengths: [String] = []
        var issues: [String] = []
        var recommendations: [String] = []

        var components: [ScoreComponent] = []
        for dimension in inputs.availableDimensions {
            guard let curve = evaluate(dimension, inputs, &strengths, &issues, &recommendations) else { continue }
            components.append(ScoreComponent(name: dimension.rawValue, score: clamped(curve.score),
                                             weight: dimension.defaultWeight,
                                             detail: curve.detail, risk: curve.risk))
        }

        if components.isEmpty {
            // 全部候选维度都因缺证据而缺席时，不能拿「请先添加项目」这套引导文案把真实原因盖掉：
            // 项目可能扫得好好的（比如已经列出 52 个依赖），只是这一维度不敢计分。
            let guidance = "先在侧栏「添加项目」选择本地仓库目录，或点右上角「重新分析」采集指标。"
            let keptRecommendations = recommendations.isEmpty ? [guidance] : recommendations
            let keptIssues = issues.isEmpty ? ["尚无可用指标"] : issues
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

        // 契约：对外发布的 weight 自身归一到 1.0，消费方 Σ(score·weight) 能复现 overall。
        let totalWeight = components.reduce(0.0) { $0 + $1.weight }
        guard totalWeight > 0 else { return HealthScore(overall: 0) }
        components = components.map { var copy = $0; copy.weight = copy.weight / totalWeight; return copy }

        let overall = clamped(components.reduce(0.0) { $0 + Double($1.score) * $1.weight })
        if recommendations.isEmpty {
            recommendations.append("当前无明显短板，保持提交节奏并持续监控新增高复杂度函数。")
        }

        return HealthScore(
            computedAt: Date(),
            overall: overall,
            previousOverall: inputs.previousScore,
            components: components.sorted { $0.score < $1.score },
            strengths: Array(strengths.prefix(5)),
            issues: Array(issues.prefix(5)),
            recommendations: Array(recommendations.prefix(5)),
            narrative: HealthCurves.narrative(overall: overall,
                                              components: components.map { (name: $0.name, score: $0.score) }),
            generatedByAI: false
        )
    }

    // MARK: - 逐维度取曲线

    private func evaluate(_ dimension: HealthDimension, _ inputs: HealthInputs,
                          _ strengths: inout [String], _ issues: inout [String],
                          _ recommendations: inout [String]) -> CurveResult? {
        switch dimension {
        case .complexity:
            guard let code = inputs.code else { return nil }
            // 三种证据状态，按可信度排序：
            //   1) 分析器给出全仓均值 → 直接用，样本口径后缀不再需要；
            //   2) 没有全仓均值但有热点榜 → 退回热点榜均值，detail 必须标明是样本口径；
            //   3) 两者都没有 → 「一个函数都没测到」，本维度不参与评分。
            //      注意第 3 支必须按「有没有测到东西」判，不能只看 analyzedFunctionCount：
            //      分母 >0 但榜单为空时热点均值会算成 0，曲线会把「没测到」当成复杂度 0 给满分，
            //      那正是这条诚实原则要挡住的。与 `.testing` 的 `coverage.hasData` 同源。
            // WS-A 自 `f55e4a0` 起真的在填这两个字段（真实仓库 self-scan：均值 4.13、分母 1134），
            // 所以有函数的仓库现在走第①支；第③支留给「一个函数都没测到」的空目录/纯资源目录。
            let hotspots = code.topComplexFunctions
            guard code.averageCyclomaticComplexity != nil || !hotspots.isEmpty else { return nil }
            let highRisk = hotspots.filter { $0.cyclomaticComplexity >= 16 }.count
            let worst = hotspots.map(\.cyclomaticComplexity).max() ?? 0
            let hasRepoMean = code.averageCyclomaticComplexity != nil
            let mean = code.averageCyclomaticComplexity
                ?? (hotspots.isEmpty ? 0
                    : Double(hotspots.map(\.cyclomaticComplexity).reduce(0, +)) / Double(hotspots.count))
            let curve = HealthCurves.complexity(averageCC: mean, highRiskCount: highRisk, maxCC: worst,
                                                functionCount: max(code.analyzedFunctionCount, hotspots.count))
            if curve.score >= 85 { strengths.append("函数复杂度可控（最高 CC \(worst)）") }
            if curve.score <= 60 {
                issues.append("\(highRisk) 个函数圈复杂度 ≥16，最高 \(worst)")
                recommendations.append("优先拆分最高复杂度函数，用早返回替代嵌套分支")
            }
            return hasRepoMean ? notingRepoScope(curve, functionCount: code.analyzedFunctionCount,
                                                 sampleCount: hotspots.count)
                : notingSample(curve, hotspots.count)

        case .duplication:
            guard let code = inputs.code else { return nil }
            let curve = HealthCurves.duplication(ratio: code.duplicationRatio, codeLines: code.codeLines)
            if curve.score >= 85 { strengths.append(String(format: "重复代码率低（%.1f%%）", code.duplicationRatio * 100)) }
            if curve.score <= 60 {
                issues.append(String(format: "重复代码 %.1f%%，共 %d 处重复块",
                                     code.duplicationRatio * 100, code.duplicatedBlocks.count))
                recommendations.append("抽取重复块为共享工具或基类，优先处理跨服务重复")
            }
            return curve

        case .codeQuality:
            guard let code = inputs.code, code.totalFiles > 0 else { return nil }
            let hugeRatio = Double(code.hugeFiles.count) / Double(max(code.totalFiles, 1))
            let curve = HealthCurves.codeQuality(hugeFileRatio: hugeRatio,
                                                 averageFunctionLength: code.averageFunctionLength,
                                                 longFunctions: code.longFunctions,
                                                 totalFiles: code.totalFiles)
            if curve.score >= 85 { strengths.append("文件规模健康，巨大文件占比低") }
            if let worst = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }), worst.lineCount >= 1500 {
                issues.append("\(worst.path.split(separator: "/").last ?? "?") \(NumberFormat.grouped(worst.lineCount)) 行，远超单文件上限")
                recommendations.append(worst.suggestion)
            }
            return curve

        case .documentation:
            guard let code = inputs.code else { return nil }
            let curve = HealthCurves.documentation(commentRatio: code.commentRatio,
                                                   todoCount: code.todoCount, fixmeCount: code.fixmeCount,
                                                   totalLines: code.totalLines)
            if curve.score >= 95 { strengths.append(String(format: "注释密度适中（%.1f%%）", code.commentRatio * 100)) }
            if curve.score < 70 { recommendations.append("为公共 API 与复杂分支补充说明性注释") }
            return curve

        case .activity:
            guard let git = inputs.git, git.totalCommits > 0 else { return nil }
            let daysSinceLast = git.lastCommitAt.map { Date().timeIntervalSince($0) / 86_400 }
            let curve = HealthCurves.activity(commitsPerDay: git.commitsPerDay,
                                             daysSinceLastCommit: daysSinceLast,
                                             totalCommits: git.totalCommits)
            if git.commitsPerDay >= 8 { strengths.append(String(format: "提交节奏稳定（日均 %.1f 次）", git.commitsPerDay)) }
            if let days = daysSinceLast, days > 14 { issues.append(String(format: "已 %.0f 天无提交", days)) }
            return curve

        case .busFactor:
            guard let git = inputs.git, let top = git.topAuthor, git.totalCommits > 0 else { return nil }
            let share = Double(top.commits) / Double(git.totalCommits)
            let curve = HealthCurves.busFactor(risk: git.busFactorRisk, topAuthorShare: share,
                                               activeAuthors: git.activeAuthorCount,
                                               totalCommits: git.totalCommits)
            if git.activeAuthorCount >= 4 && share < 0.45 {
                strengths.append("贡献分布合理（\(git.activeAuthorCount) 人，头号作者占 \(NumberFormat.percent(share, precision: 0))）")
            }
            if share > 0.6 {
                issues.append(String(format: "%@ 一人承担 %.0f%% 提交，单点风险高", top.name, share * 100))
            }
            return curve

        case .stability:
            guard let logs = inputs.logs else { return nil }
            // 密度需要代码规模做分母；没有 code 时退化成「按绝对值当每千行计」，
            // 宁可偏严也不把证据缺失算成满分（availableDimensions 承诺了这个维度在场）。
            let lines = inputs.code?.codeLines ?? 0
            let faults = logs.errorCount + logs.exceptionCount
            let perKloc = lines > 0 ? Double(faults) / Double(lines) * 1000 : Double(faults)
            let curve = HealthCurves.stability(errorsPerKLoc: perKloc, crashCount: logs.crashCount,
                                               fatalCount: logs.fatalCount, exceptionCount: logs.exceptionCount,
                                               totalLinesScanned: logs.totalLinesScanned)
            // 一行日志都没扫到时不得写「近期无崩溃」——那是把「没看到」说成「没有」。
            // 曲线那边已经如实标了「未扫描到运行日志，本维度按默认值计」，
            // 优点卡必须跟它一个口径，否则同一份报告自己打自己脸。
            if logs.totalLinesScanned > 0, logs.crashCount == 0, perKloc < 0.5 {
                strengths.append("已扫描 \(NumberFormat.grouped(logs.totalLinesScanned)) 行日志，未见崩溃")
            } else if logs.totalLinesScanned == 0 {
                recommendations.append("当前没有可扫描的日志，运行稳定性按默认值计；放入 Logs/error.log 或附加日志文件后才有结论。")
            }
            if let worst = logs.topErrors.first, worst.count >= 10 {
                issues.append("\(worst.displayMessage) 出现 \(worst.count) 次（最近 \(worst.lastSeenDescription)）")
                recommendations.append("优先修复 Top Errors 首位，它通常掩盖了下游连锁异常")
            }
            return curve

        case .dependencies:
            guard let deps = inputs.dependencies, deps.totalDependencies > 0 else { return nil }
            // 「零漏洞」有两种可能：查过之后干净，或者压根没查。没查过就不参与评分，
            // 绝不能把「没核对」渲染成「依赖零风险」——那是拿收费点换假绿灯。
            switch VulnerabilityEvidence.classify(deps) {
            case .unchecked:
                let uncovered = deps.uncoveredEcosystemNames
                recommendations.append(uncovered.isEmpty
                    ? "未做在线漏洞核对，依赖健康本维度暂不计分；开启「联网核对」后重扫才有结论。"
                    : "未做在线漏洞核对，依赖健康本维度暂不计分（内置规则未覆盖：\(uncovered.joined(separator: "、"))）。")
                return nil
            case .degraded:
                recommendations.append("漏洞核对未完成（部分包查询失败），依赖健康本维度暂不计分；重跑联网核对后再计。")
                return nil
            case .verified:
                break
            }
            let curve = HealthCurves.dependencyHealth(vulnerableCount: deps.vulnerableCount,
                                                      outdatedCount: deps.outdatedCount,
                                                      totalDependencies: deps.totalDependencies)
            if deps.vulnerableCount == 0 {
                // 走到这里说明确实核对过，这句安全背书才有依据。
                strengths.append("已完成漏洞核对，\(deps.totalDependencies) 个依赖零命中")
            } else {
                issues.append("\(deps.vulnerableCount) 个已知漏洞，\(deps.outdatedCount) 个版本过旧")
                recommendations.append("先升级带严重漏洞的依赖，再统一处理过期版本")
            }
            return curve

        case .testing:
            // 覆盖率没有锚点曲线（数据只有行/分支两个百分比），保持分段计分。
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
            return CurveResult(score: Double(score),
                               detail: String(format: "行覆盖 %.1f%%，分支覆盖 %@", line,
                                              coverage.overallBranchPercent.map { String(format: "%.1f%%", $0) } ?? "无数据"),
                               risk: coverage.riskLevel)
        }
    }

    // MARK: - Helpers

    /// 没有全仓均值、只能用热点榜均值算复杂度时，把样本口径写进文案，
    /// 避免读者把这个数当成全仓平均（`CodeMetrics.topComplexFunctions` 是封顶的榜单）。
    private func notingSample(_ curve: CurveResult, _ sampleCount: Int) -> CurveResult {
        guard sampleCount > 0 else { return curve }
        return CurveResult(score: curve.score, detail: curve.detail + "（热点样本 \(sampleCount) 个的均值）",
                           risk: curve.risk)
    }

    /// 第①支的 detail 是**混合口径**：均值来自全仓普查，但 `CC≥16` 个数与最大 CC 只能从
    /// 截断到 20 条的热点榜里数（`Models` 没给全仓分布）。不写清楚就会被读成「全仓有 N 个
    /// 函数 CC≥16」，而那个 N 实际上只是榜内计数——这是扣分项，报小了会高估健康度。
    private func notingRepoScope(_ curve: CurveResult, functionCount: Int, sampleCount: Int) -> CurveResult {
        let meanScope = functionCount > 0 ? "均值为全仓 \(functionCount) 个函数" : "均值为全仓"
        let riskScope = sampleCount > 0 ? "；CC≥16 与最大 CC 只统计热点榜前 \(sampleCount) 个" : ""
        return CurveResult(score: curve.score, detail: curve.detail + "（\(meanScope)\(riskScope)）",
                           risk: curve.risk)
    }

    private func clamped(_ value: Double) -> Int { min(100, max(0, Int(value.rounded()))) }
}
