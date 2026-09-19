import Foundation

/// 健康评分标定曲线：每个维度的分数都由显式锚点线性折算，保证「分数可解释、依据可对外承诺」。
/// 纯函数、无 I/O、无状态；加权与落盘由调用方（WeightedHealthScorer）负责。

struct CurveResult: Sendable, Equatable {
    var score: Double
    var detail: String
    var risk: RiskLevel
}

enum ScoreCurve {
    /// 唯一的插值原语：所有分数只能由锚点表插值得出，便于逐条标定与回归测试。
    static func piecewise(_ value: Double, through points: [(x: Double, score: Double)]) -> Double {
        guard value.isFinite else { return 0 }
        let anchors = points.filter { $0.x.isFinite && $0.score.isFinite }
        guard let first = anchors.first, let last = anchors.last else { return 0 }
        if value <= first.x { return first.score }
        if value >= last.x { return last.score }
        for index in 1..<anchors.count {
            let high = anchors[index]
            guard value <= high.x else { continue }
            let low = anchors[index - 1]
            let span = high.x - low.x
            guard span > 0 else { return high.score }
            let t = (value - low.x) / span
            return low.score + (high.score - low.score) * t
        }
        return last.score
    }

    static func clamped(_ value: Double, _ low: Double = 0, _ high: Double = 100) -> Double {
        guard low.isFinite, high.isFinite else { return 0 }
        let lower = Swift.min(low, high)
        let upper = Swift.max(low, high)
        guard value.isFinite else { return lower }
        if value <= lower { return lower }
        if value >= upper { return upper }
        return value
    }
}

enum HealthCurves {

    // MARK: - 复杂度

    static func complexity(averageCC: Double, highRiskCount: Int, maxCC: Int, functionCount: Int) -> CurveResult {
        if functionCount == 0 {
            return CurveResult(score: 100, detail: "未发现可计数的函数体", risk: .none)
        }
        let base = ScoreCurve.piecewise(averageCC, through: [
            (x: 1, score: 100), (x: 3, score: 92), (x: 5, score: 80), (x: 8, score: 60),
            (x: 12, score: 38), (x: 16, score: 22), (x: 25, score: 6), (x: 40, score: 0)
        ])
        let highRiskPenalty = Swift.min(30.0, Double(Swift.max(0, highRiskCount)) * 3)
        let outlierPenalty = maxCC >= 40 ? 10.0 : 0
        let deducted = highRiskPenalty + outlierPenalty
        let score = ScoreCurve.clamped(base - deducted)
        var detail = "平均圈复杂度 \(decimal(averageCC))，\(whole(highRiskCount)) 个函数 CC≥16，最大 \(maxCC)"
        if deducted > 0 { detail += "，基准 \(decimal(base)) 分扣 \(decimal(deducted)) 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: graded(score, 80, 60, 40, 22))
    }

    // MARK: - 重复度

    static func duplication(ratio: Double, codeLines: Int) -> CurveResult {
        // 2% 以内视作识别噪声（满分平台）；5%→98、12.5%→75、25%→4 是对外标定基准。
        let value = ScoreCurve.clamped(ratio, 0, 1)
        let score = ScoreCurve.clamped(ScoreCurve.piecewise(value, through: [
            (x: 0, score: 100), (x: 0.02, score: 100), (x: 0.05, score: 98), (x: 0.08, score: 88),
            (x: 0.125, score: 75), (x: 0.18, score: 45), (x: 0.25, score: 4), (x: 0.35, score: 0)
        ]))
        let lines = Swift.max(0, codeLines)
        let detail: String
        if lines < 200 {
            detail = "重复率 \(percent(value))，样本过小，按 \(whole(lines)) 行代码估计，置信度低"
        } else {
            detail = "重复率 \(percent(value))，按 \(whole(lines)) 行代码统计"
        }
        return CurveResult(score: score, detail: bounded(detail), risk: graded(score, 90, 70, 45, 15))
    }

    // MARK: - 代码质量

    static func codeQuality(hugeFileRatio: Double, averageFunctionLength: Int, longFunctions: Int, totalFiles: Int) -> CurveResult {
        if totalFiles == 0 {
            return CurveResult(score: 100, detail: "未发现可评估的源码文件", risk: .none)
        }
        let hugeScore = ScoreCurve.piecewise(ScoreCurve.clamped(hugeFileRatio, 0, 1), through: [
            (x: 0, score: 100), (x: 0.02, score: 92), (x: 0.05, score: 78),
            (x: 0.10, score: 58), (x: 0.20, score: 28), (x: 0.35, score: 5)
        ])
        let lengthScore = ScoreCurve.piecewise(Double(Swift.max(0, averageFunctionLength)), through: [
            (x: 10, score: 100), (x: 20, score: 92), (x: 35, score: 78),
            (x: 55, score: 55), (x: 90, score: 25), (x: 150, score: 2)
        ])
        let longPenalty = Swift.min(20.0, Double(Swift.max(0, longFunctions) / 10) * 2)
        let score = ScoreCurve.clamped((hugeScore + lengthScore) / 2 - longPenalty)
        var detail = "巨大文件占比 \(percent(hugeFileRatio))，平均函数 \(whole(averageFunctionLength)) 行，共 \(whole(totalFiles)) 个文件"
        if longPenalty > 0 { detail += "，\(whole(longFunctions)) 个超长函数扣 \(decimal(longPenalty)) 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: graded(score, 90, 70, 45, 15))
    }

    // MARK: - 注释与可维护性

    static func documentation(commentRatio: Double, todoCount: Int, fixmeCount: Int, totalLines: Int) -> CurveResult {
        if totalLines == 0 {
            return CurveResult(score: 50, detail: "无源码可评估", risk: graded(50, 85, 65, 45, 25))
        }
        // 峰值在 5%，2%~15% 为最佳带；两端都掉分——注释过多同样是维护成本，50% 只给 20 分。
        let ratio = ScoreCurve.clamped(commentRatio, 0, 1)
        let base = ScoreCurve.piecewise(ratio, through: [
            (x: 0, score: 35), (x: 0.005, score: 55), (x: 0.02, score: 92), (x: 0.05, score: 100),
            (x: 0.10, score: 98), (x: 0.15, score: 86), (x: 0.22, score: 62), (x: 0.35, score: 35),
            (x: 0.50, score: 20)
        ])
        let todoPenalty = Swift.min(8.0, Double(Swift.max(0, todoCount) / 20) * 1)
        let fixmePenalty = Swift.min(12.0, Double(Swift.max(0, fixmeCount) / 5) * 2)
        let deducted = todoPenalty + fixmePenalty
        let score = ScoreCurve.clamped(base - deducted)
        let band: String
        if ratio < 0.02 { band = "低于 2% 最佳下限" }
        else if ratio > 0.15 { band = "注释过多同样扣分" }
        else { band = "落在 2%~15% 最佳区间" }
        var detail = "注释占比 \(percent(ratio))（\(band)），TODO \(whole(todoCount)) 个，FIXME \(whole(fixmeCount)) 个，源码 \(whole(totalLines)) 行"
        if deducted > 0 { detail += "，标记扣 \(decimal(deducted)) 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: graded(score, 85, 65, 45, 25))
    }

    // MARK: - 提交活跃度

    static func activity(commitsPerDay: Double, daysSinceLastCommit: Double?, totalCommits: Int) -> CurveResult {
        if totalCommits == 0 {
            return CurveResult(score: 15, detail: "无提交记录", risk: graded(15, 85, 65, 45, 25))
        }
        // 速率超过 4 次/天后掉头：高频小提交是碎片化，不该比稳定节奏拿更高分。
        let rate = Swift.max(0.0, commitsPerDay)
        let base = ScoreCurve.piecewise(rate, through: [
            (x: 0, score: 18), (x: 0.2, score: 45), (x: 0.5, score: 65), (x: 1, score: 80),
            (x: 2, score: 90), (x: 4, score: 95), (x: 8, score: 92), (x: 20, score: 80)
        ])
        var stalePenalty = 0.0
        var recencyText = "未提供最近提交时间"
        if let days = daysSinceLastCommit, days.isFinite {
            recencyText = "距今 \(decimal(Swift.max(0, days))) 天无提交"
            if days > 7 {
                // 7 天起线性扣、60 天封顶 -45。
                stalePenalty = Swift.min(45.0, Swift.max(0.0, (days - 7) / 53 * 45))
            }
        }
        let score = ScoreCurve.clamped(base - stalePenalty)
        var detail = "日均 \(decimal(rate)) 次提交，\(recencyText)，累计 \(whole(totalCommits)) 次"
        if rate >= 8 { detail += "，速率偏高按碎片化折算" }
        if stalePenalty > 0 { detail += "，陈旧扣 \(decimal(stalePenalty)) 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: graded(score, 85, 65, 45, 25))
    }

    // MARK: - 协作分布

    static func busFactor(risk: RiskLevel, topAuthorShare: Double, activeAuthors: Int, totalCommits: Int) -> CurveResult {
        if totalCommits == 0 {
            return CurveResult(score: 70, detail: "提交记录过少，暂不评估协作分布", risk: .none)
        }
        let base = ScoreCurve.piecewise(Double(risk.rank), through: [
            (x: 0, score: 100), (x: 1, score: 88), (x: 2, score: 62), (x: 3, score: 28), (x: 4, score: 10)
        ])
        let share = ScoreCurve.clamped(topAuthorShare, 0, 1)
        let adjustment: Double
        if share <= 0.35 { adjustment = 6 }
        else if share < 0.5 { adjustment = 2 }
        else if share < 0.7 { adjustment = -6 }
        else { adjustment = -22 }
        var score = ScoreCurve.clamped(base + adjustment)
        let singlePoint = activeAuthors == 1 && totalCommits > 50
        if singlePoint { score = Swift.min(score, 8) }
        let shareText = String(format: "%.0f%%", share * 100)
        var detail = "最高作者占比 \(shareText)，\(whole(activeAuthors)) 位活跃作者，\(whole(totalCommits)) 次提交"
        if share >= 0.7 { detail += "，单人包揽重扣 22 分" }
        if singlePoint { detail += "，单点作者封顶 8 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: risk)
    }

    // MARK: - 运行稳定性

    static func stability(errorsPerKLoc: Double, crashCount: Int, fatalCount: Int, exceptionCount: Int, totalLinesScanned: Int) -> CurveResult {
        if totalLinesScanned == 0 {
            // 没扫到日志就不假装满分：给偏高的默认分，并在文案里标明是默认值。
            return CurveResult(score: 85, detail: "未扫描到运行日志，本维度按默认值计", risk: .low)
        }
        let base = ScoreCurve.piecewise(Swift.max(0, errorsPerKLoc), through: [
            (x: 0, score: 100), (x: 0.5, score: 92), (x: 1.5, score: 78), (x: 3, score: 58),
            (x: 6, score: 32), (x: 12, score: 12), (x: 25, score: 0)
        ])
        let crashPenalty = Swift.min(48.0, Double(Swift.max(0, crashCount)) * 12)
        let fatalPenalty = Swift.min(24.0, Double(Swift.max(0, fatalCount)) * 8)
        let exceptionPenalty = Swift.min(15.0, Double(Swift.max(0, exceptionCount) / 5) * 3)
        let deducted = crashPenalty + fatalPenalty + exceptionPenalty
        let score = ScoreCurve.clamped(base - deducted)
        var detail = "每千行 \(decimal(Swift.max(0, errorsPerKLoc))) 个错误，崩溃 \(whole(crashCount)) 次，致命 \(whole(fatalCount)) 次，异常 \(whole(exceptionCount)) 次，扫描 \(whole(totalLinesScanned)) 行"
        if deducted > 0 { detail += "，扣 \(decimal(deducted)) 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: graded(score, 85, 65, 45, 20))
    }

    // MARK: - 依赖健康

    static func dependencyHealth(vulnerableCount: Int, outdatedCount: Int, totalDependencies: Int) -> CurveResult {
        if totalDependencies == 0 {
            return CurveResult(score: 100, detail: "未发现依赖清单", risk: .none)
        }
        let vulnerable = Swift.max(0, vulnerableCount)
        let vulnerablePenalty = Swift.min(70.0, Double(vulnerable) * 14)
        let outdatedRatio = ScoreCurve.clamped(Double(Swift.max(0, outdatedCount)) / Double(Swift.max(1, totalDependencies)), 0, 1)
        // 这里 piecewise 标定的是「扣分幅度」而非分数本身，基准恒为 100。
        let outdatedPenalty = ScoreCurve.piecewise(outdatedRatio, through: [
            (x: 0, score: 0), (x: 0.1, score: 6), (x: 0.25, score: 18), (x: 0.5, score: 32), (x: 0.8, score: 45)
        ])
        let deducted = vulnerablePenalty + outdatedPenalty
        let score = ScoreCurve.clamped(100 - deducted)
        let risk: RiskLevel
        if vulnerable == 0 { risk = outdatedRatio > 0.25 ? .low : .none }
        else if vulnerable <= 2 { risk = .medium }
        else if vulnerable <= 9 { risk = .high }
        else { risk = .critical }
        var detail = "依赖 \(whole(totalDependencies)) 个，漏洞 \(whole(vulnerable)) 个，落后 \(whole(outdatedCount)) 个占 \(percent(outdatedRatio))"
        if deducted > 0 { detail += "，扣 \(decimal(deducted)) 分" }
        return CurveResult(score: score, detail: bounded(detail), risk: risk)
    }

    // MARK: - 总评

    /// 由各分量真实分数拼装的一句总评，长度收敛到 40~80 字。
    static func narrative(overall: Int, components: [(name: String, score: Int)]) -> String {
        let score = Int(ScoreCurve.clamped(Double(overall), 0, 100).rounded())
        let grade = HealthGrade(score: score).rawValue
        let ranked = components.sorted {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.name < $1.name
        }
        var candidate = "综合 \(score) 分（\(grade) 级）。"
        switch ranked.count {
        case 0:
            candidate += "当前没有任何维度可供评估，评分依据缺失，建议先完成代码与 Git 分析再看总分。"
        case 1:
            let only = ranked[0]
            candidate += "目前仅 \(only.name)（\(only.score) 分）这一个维度有可用数据，它同时也是最低项，建议优先\(advice(for: only.name))。"
        case 2:
            let low = ranked[0]
            let high = ranked[1]
            candidate += "主要拖累来自 \(low.name)（\(low.score) 分），\(high.name)（\(high.score) 分）相对较好；建议优先\(advice(for: low.name))。"
        default:
            let first = ranked[0]
            let second = ranked[1]
            let best = ranked[ranked.count - 1]
            candidate += "主要拖累来自 \(first.name)（\(first.score) 分）与 \(second.name)（\(second.score) 分）；"
            candidate += "\(best.name)（\(best.score) 分）是当前亮点。建议优先\(advice(for: first.name))。"
        }
        return fittedNarrative(candidate)
    }

    /// 长度收敛：超 80 字按子句边界丢弃，不足 40 字补固定后缀，最后再兜底截断。
    private static func fittedNarrative(_ candidate: String) -> String {
        var clauses: [String] = []
        var current = ""
        for character in candidate {
            current.append(character)
            if character == "。" || character == "；" || character == "，" {
                clauses.append(current)
                current = ""
            }
        }
        if !current.isEmpty { clauses.append(current) }

        var result = ""
        for clause in clauses {
            if result.count + clause.count > 80 { break }
            result += clause
        }
        if result.isEmpty { result = String(Array(candidate).prefix(79)) }
        if let last = result.last, last == "，" || last == "；" || last == "、" {
            result.removeLast()
            result.append("。")
        }
        if !result.hasSuffix("。") { result += "。" }

        let pads = ["其余维度处于可接受区间。", "建议保持观察，待各维度数据补齐后复核。"]
        var padIndex = 0
        while result.count < 40, padIndex < pads.count, result.count + pads[padIndex].count <= 80 {
            result += pads[padIndex]
            padIndex += 1
        }

        let characters = Array(result)
        if characters.count > 80 { return String(characters.prefix(79)) + "。" }
        return result
    }

    private static func advice(for dimensionName: String) -> String {
        switch dimensionName {
        case HealthDimension.complexity.rawValue: return "拆解 CC≥16 的函数"
        case HealthDimension.duplication.rawValue: return "抽取重复代码块"
        case HealthDimension.codeQuality.rawValue: return "拆分超大文件与超长函数"
        case HealthDimension.documentation.rawValue: return "补齐关键注释并清理待办标记"
        case HealthDimension.activity.rawValue: return "保持稳定提交节奏"
        case HealthDimension.busFactor.rawValue: return "分摊单点作者的改动评审"
        case HealthDimension.stability.rawValue: return "排查崩溃与高频错误"
        case HealthDimension.dependencies.rawValue: return "升级有已知漏洞的依赖"
        case HealthDimension.testing.rawValue: return "补充自动化测试"
        default: return "处理「\(dimensionName)」"
        }
    }

    // MARK: - 内部工具

    private static func graded(_ score: Double, _ noneAt: Double, _ lowAt: Double, _ mediumAt: Double, _ highAt: Double) -> RiskLevel {
        if score >= noneAt { return .none }
        if score >= lowAt { return .low }
        if score >= mediumAt { return .medium }
        if score >= highAt { return .high }
        return .critical
    }

    /// UI 文案预算 60 字：极端输入下宁可截断也不换行，避免撑破行高。
    private static func bounded(_ text: String) -> String {
        let characters = Array(text)
        guard characters.count > 60 else { return text }
        return String(characters.prefix(60))
    }

    /// 手写定点格式化，不走 Locale，保证任何系统语言下 detail 里的数字都一致。
    private static func decimal(_ value: Double, _ digits: Int = 1) -> String {
        guard value.isFinite else { return "0" }
        let fractionDigits = Swift.max(0, Swift.min(4, digits))
        let boundedValue = Swift.max(-9_999_999_999.0, Swift.min(9_999_999_999.0, value))
        let scale = pow(10.0, Double(fractionDigits))
        let negative = boundedValue < 0
        var text = String(Int((Swift.abs(boundedValue) * scale).rounded()))
        if fractionDigits > 0 {
            while text.count <= fractionDigits { text = "0" + text }
            let characters = Array(text)
            let split = characters.count - fractionDigits
            var fraction = String(characters[split...])
            while fraction.hasSuffix("0") { fraction.removeLast() }
            text = fraction.isEmpty
                ? String(characters[0..<split])
                : String(characters[0..<split]) + "." + fraction
        }
        return (negative && text != "0") ? "-" + text : text
    }

    private static func percent(_ ratio: Double, _ digits: Int = 1) -> String {
        decimal(Swift.max(0, ratio) * 100, digits) + "%"
    }

    private static func whole(_ value: Int) -> String {
        String(Swift.max(0, value))
    }
}
