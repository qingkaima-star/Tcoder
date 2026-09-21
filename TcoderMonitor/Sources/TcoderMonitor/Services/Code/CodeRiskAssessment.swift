import Foundation

// OWNER: Workstream A (静态代码分析) —— CodeRiskAssessment
//
// 从 FileSystemCodeAnalyzer.swift 拆出，只为守住本工作流的红线（巨大文件不得增加、
// 单函数不超过约 50 行 / CC 16）：**分档判据、阈值数值、`max(risk, .high)` 的抬档顺序
// 一字未改**。`overallRisk` 原来 50 行 / CC 17，现在按三个维度各算各的分，最后取最大。
//
// 阈值常量本身仍留在 `FileSystemCodeAnalyzer.swift`（冻结区，总工与自扫守卫都按那个位置认它），
// 这里只是消费方。原先的 `private` 跨文件后必须放宽到模块内可见，除可见性外没有任何变化。

extension FileSystemCodeAnalyzer {
    func functionRisk(complexity: Int, lineCount: Int) -> RiskLevel {
        var risk: RiskLevel = complexity >= Self.criticalFunctionComplexity ? .critical
            : complexity >= Self.highFunctionComplexity ? .high
            : complexity >= Self.mediumFunctionComplexity ? .medium
            : .low
        if lineCount > 100 {
            risk = max(risk, RiskLevel.high)
        } else if lineCount > Self.longFunctionThreshold {
            risk = max(risk, RiskLevel.medium)
        }
        return risk
    }

    func fileRisk(forLines lines: Int) -> RiskLevel {
        lines > Self.criticalFileLines ? .high : lines > Self.highFileLines ? .medium : .low
    }

    /// 整体风险 = 四个来源各自的分档取最大。分档数值与原来完全一致，
    /// 只是从「一个函数里四条 if 链」改成每条链各成一函数。
    func overallRisk(
        metrics: CodeMetrics,
        hotspotCount: Int,
        longestFileLines: Int
    ) -> RiskLevel {
        var score = 0
        score = max(score, complexityRiskScore(metrics.topComplexFunctions.map(\.risk)))
        score = max(score, duplicationRiskScore(metrics.duplicationRatio))
        score = max(score, fileSizeRiskScore(longestFileLines))
        if hotspotCount > 10 {
            score = max(score, 2)
        }
        switch score {
        case 4: return .critical
        case 3: return .high
        case 2: return .medium
        case 1: return .low
        default: return .none
        }
    }

    /// 复杂度维度：有一个[严重]就顶格；三个以上[高]算高；只有一个[高]或存在[中]各降一档。
    func complexityRiskScore(_ buckets: [RiskLevel]) -> Int {
        if buckets.contains(.critical) { return 4 }
        if buckets.filter { $0 == .high }.count >= 3 { return 3 }
        if buckets.contains(.high) { return 2 }
        if buckets.contains(.medium) { return 1 }
        return 0
    }

    /// 重复率维度的四档门限。
    func duplicationRiskScore(_ ratio: Double) -> Int {
        if ratio >= 0.25 { return 4 }
        if ratio >= 0.15 { return 3 }
        if ratio >= 0.08 { return 2 }
        if ratio > 0 { return 1 }
        return 0
    }

    /// 最大文件维度的三档门限（用的是本类型顶部的冻结阈值，数值不在此处）。
    func fileSizeRiskScore(_ longestFileLines: Int) -> Int {
        if longestFileLines > Self.criticalFileLines { return 3 }
        if longestFileLines > Self.highFileLines { return 2 }
        if longestFileLines > Self.mediumFileLines { return 1 }
        return 0
    }

    // MARK: - Suggestions

    func splitSuggestion(for file: ScannedSourceFile, functions: [FunctionCandidate]) -> String {
        let lines = file.totalLineCount
        let longOnes = functions.filter { $0.lineCount > Self.longFunctionThreshold }
        let longest = functions.map(\.lineCount).max() ?? 0
        let longestName = longestFunctionNameSample(functions)

        if functions.isEmpty {
            if file.codeLineCount * 4 < lines {
                return localizedFormat("%1$@ 文件 %2$@ 行，几乎全是注释或文档：精简历史说明、把示例迁出源码目录，只保留必要的接口注释。",
                                       file.language, NumberFormat.grouped(lines))
            }
            return localizedFormat("%1$@ 文件 %2$@ 行且未被识别出函数（多为配置、模板或数据表）：按领域或路由拆成多个文件，或改为外部数据资源加载。",
                                   file.language, NumberFormat.grouped(lines))
        }
        if !longOnes.isEmpty {
            return localizedFormat("%1$@ 文件 %2$@ 行、含 %3$@ 个超过 %4$@ 行的函数（最长 %5$@ 行，如 %6$@）：先把这些函数按职责抽成独立类型或同类型的 extension，再把跨函数共享的状态收进构造注入的依赖，目标单文件 400 行以内。",
                                   file.language, NumberFormat.grouped(lines),
                                   NumberFormat.grouped(longOnes.count),
                                   String(Self.longFunctionThreshold),
                                   NumberFormat.grouped(longest), longestName)
        }
        let topName = functions.sorted { $0.lineCount > $1.lineCount }.first?.name ?? "未知函数"
        return localizedFormat("%1$@ 文件 %2$@ 行但函数都不长（%3$@ 个，最长 %4$@ 行）：按能力域横向切分成多个文件或子类型（例如解析/渲染/IO 分开），%5$@ 所在的这段职责适合第一个搬出去。",
                               file.language, NumberFormat.grouped(lines),
                               String(functions.count), NumberFormat.grouped(longest), topName)
    }

    func longestFunctionNameSample(_ functions: [FunctionCandidate]) -> String {
        functions
            .sorted { $0.lineCount > $1.lineCount }
            .first?
            .name ?? "未知函数"
    }
}
