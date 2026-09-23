import Foundation

/// 代码口径的四维：复杂度、重复度、代码质量、注释与可维护性。
/// 曲线选择在 `ScoreCurves.swift`，这里只做「取输入 → 判证据 → 派文案」。
extension WeightedHealthScorer {

    // MARK: - 复杂度

    func complexityOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let code = inputs.code else { return .absent }
        // 三种证据状态，按可信度排序：
        //   1) 分析器给出全仓均值 → 直接用，样本口径后缀不再需要；
        //   2) 没有全仓均值但有热点榜 → 退回热点榜均值，detail 必须标明是样本口径；
        //   3) 两者都没有 → 「一个函数都没测到」，本维度不参与评分。
        //      第 3 支必须按「有没有真的数到函数」判：落盘报告能长成「均值守着 0、分母却是 0」
        //      的自相矛盾形状，而 `HealthCurves.complexity` 拿到 functionCount == 0 会给满分 100。
        let hasRepoMean = code.averageCyclomaticComplexity != nil && code.analyzedFunctionCount > 0
        guard hasRepoMean || !code.topComplexFunctions.isEmpty else { return .absent }
        let curve = scopedComplexityCurve(code, hasRepoMean: hasRepoMean)
        return DimensionOutcome(curve: curve,
                                strengths: complexityStrengths(curve, code),
                                issues: complexityIssues(curve, code),
                                recommendations: complexityAdvice(curve, code))
    }

    /// 口径与 `notingRepoScope` / `notingSample` 的选择保持一致：
    /// 只有「均值非空且分母 >0」才算全仓普查口径，否则退回热点榜口径。
    private func scopedComplexityCurve(_ code: CodeMetrics, hasRepoMean: Bool) -> CurveResult {
        let hotspots = code.topComplexFunctions
        let raw = HealthCurves.complexity(averageCC: complexityMean(code, hasRepoMean: hasRepoMean),
                                          highRiskCount: hotspots.filter { $0.cyclomaticComplexity >= 16 }.count,
                                          maxCC: complexityWorstCC(code),
                                          functionCount: max(code.analyzedFunctionCount, hotspots.count))
        guard hasRepoMean else { return WeightedHealthScorer.notingSample(raw, hotspots.count) }
        return WeightedHealthScorer.notingRepoScope(raw, functionCount: code.analyzedFunctionCount,
                                                    sampleCount: hotspots.count)
    }

    private func complexityMean(_ code: CodeMetrics, hasRepoMean: Bool) -> Double {
        if hasRepoMean, let repoMean = code.averageCyclomaticComplexity { return repoMean }
        let hotspots = code.topComplexFunctions
        guard !hotspots.isEmpty else { return 0 }
        return Double(hotspots.map(\.cyclomaticComplexity).reduce(0, +)) / Double(hotspots.count)
    }

    /// 榜单为空时 `?? 0` 不是测量值，所以「最高 CC」与「N 个函数 ≥16」都只能在榜内有内容时说。
    private func complexityWorstCC(_ code: CodeMetrics) -> Int {
        code.topComplexFunctions.map(\.cyclomaticComplexity).max() ?? 0
    }

    private func complexityStrengths(_ curve: CurveResult, _ code: CodeMetrics) -> [String] {
        guard curve.score >= 85, !code.topComplexFunctions.isEmpty else { return [] }
        return ["函数复杂度可控（最高 CC \(complexityWorstCC(code))）"]
    }

    private func complexityIssues(_ curve: CurveResult, _ code: CodeMetrics) -> [String] {
        guard curve.score <= 60, !code.topComplexFunctions.isEmpty else { return [] }
        let highRisk = code.topComplexFunctions.filter { $0.cyclomaticComplexity >= 16 }.count
        return ["\(highRisk) 个函数圈复杂度 ≥16，最高 \(complexityWorstCC(code))"]
    }

    private func complexityAdvice(_ curve: CurveResult, _ code: CodeMetrics) -> [String] {
        guard curve.score <= 60, !code.topComplexFunctions.isEmpty else { return [] }
        return ["优先拆分最高复杂度函数，用早返回替代嵌套分支"]
    }

    // MARK: - 重复度

    func duplicationOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        // 重复率的分母是代码行。一行代码都没扫到时 `duplicationRatio` 必然是 0，
        // 而 0% 在这里是「没东西可比」，不是「比过、很干净」——曲线的 100 分兜底支
        // 与「重复代码率低」这句优点都别被这个 0 喂出来。
        guard let code = inputs.code, code.codeLines > 0 else { return .absent }
        let curve = HealthCurves.duplication(ratio: code.duplicationRatio, codeLines: code.codeLines)
        return DimensionOutcome(curve: curve,
                                strengths: duplicationStrengths(curve, code),
                                issues: duplicationIssues(curve, code),
                                recommendations: duplicationAdvice(curve))
    }

    private func duplicationStrengths(_ curve: CurveResult, _ code: CodeMetrics) -> [String] {
        // 优点宣称不得越过曲线自己承认的置信度下限（同一条 200 行，见 `HealthCurves.smallSampleCodeLines`）。
        guard curve.score >= 85, code.codeLines >= HealthCurves.smallSampleCodeLines else { return [] }
        return [localizedFormat("重复代码率低（%1$@）",
                                    NumberFormat.percent(code.duplicationRatio, precision: 1))]
    }

    private func duplicationIssues(_ curve: CurveResult, _ code: CodeMetrics) -> [String] {
        guard curve.score <= 60 else { return [] }
        return [localizedFormat("重复代码 %1$@，共 %2$@ 处重复块",
                                    NumberFormat.percent(code.duplicationRatio, precision: 1),
                                    NumberFormat.grouped(code.duplicatedBlocks.count))]
    }

    private func duplicationAdvice(_ curve: CurveResult) -> [String] {
        guard curve.score <= 60 else { return [] }
        return ["抽取重复块为共享工具或基类，优先处理跨服务重复"]
    }

    // MARK: - 代码质量

    func codeQualityOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let code = inputs.code, code.totalFiles > 0 else { return .absent }
        // 分子用**真个数**（`CodeMetrics.hugeFileCount`），不是被截断到 20 的榜单长度：
        // 否则仓库越大越显干净（本 App 扫自己一度把 38/190 = 20% 报成 10.5%）。
        // 旧报告没这个字段时退回榜内计数——那是偏松的口径，必须在 detail 里承认。
        let hugeCount = code.reportedHugeFileCount
        let raw = HealthCurves.codeQuality(hugeFileRatio: Double(hugeCount) / Double(max(code.totalFiles, 1)),
                                           averageFunctionLength: code.averageFunctionLength,
                                           longFunctions: code.longFunctions,
                                           totalFiles: code.totalFiles)
        // 注记**提到外面算**：披露助手那一行必须同时装着标记与榜长
        // （`BoardLengthReadoutRatchetTests` 按行认合法披露句，拆两行就把一句诚实的话判成违例）。
        let boardNote = HealthCurves.boardOnlyNote(raw.detail, listed: code.hugeFiles.count, total: hugeCount)
        let curve = hugeCount > code.hugeFiles.count
            ? CurveResult(score: raw.score, detail: boardNote, risk: raw.risk)
            : raw
        guard let worst = code.hugeFiles.max(by: { $0.lineCount < $1.lineCount }) else {
            return DimensionOutcome(curve: curve, strengths: codeQualityStrengths(curve))
        }
        return DimensionOutcome(curve: curve,
                                strengths: codeQualityStrengths(curve),
                                issues: codeQualityIssues(worst),
                                recommendations: codeQualityAdvice(worst))
    }

    private func codeQualityStrengths(_ curve: CurveResult) -> [String] {
        curve.score >= 85 ? ["文件规模健康，巨大文件占比低"] : []
    }

    private func codeQualityIssues(_ worst: FileHotspot) -> [String] {
        guard worst.lineCount >= 1500 else { return [] }
        let name = worst.path.split(separator: "/").last ?? "?"
        return ["\(name) \(NumberFormat.grouped(worst.lineCount)) 行，远超单文件上限"]
    }

    private func codeQualityAdvice(_ worst: FileHotspot) -> [String] {
        worst.lineCount >= 1500 ? [worst.suggestion] : []
    }

    // MARK: - 注释与可维护性

    func documentationOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        // 注释占比的分母是 totalLines；0 行时曲线给的是 50 分「无源码可评估」占位值，
        // 让一个占位值参与加权（并把在场维度的权重摊薄）等于把没扫到当成中等水平。
        guard let code = inputs.code, code.totalLines > 0 else { return .absent }
        let curve = HealthCurves.documentation(commentRatio: code.commentRatio,
                                               todoCount: code.todoCount, fixmeCount: code.fixmeCount,
                                               totalLines: code.totalLines)
        var outcome = DimensionOutcome(curve: curve)
        if curve.score >= 95 {
            outcome.strengths.append(String(format: "注释密度适中（%.1f%%）", code.commentRatio * 100))
        }
        if curve.score < 70 { outcome.recommendations.append("为公共 API 与复杂分支补充说明性注释") }
        return outcome
    }
}
