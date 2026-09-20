import Foundation

/// 健康评分标定曲线的**团队与运行时族分片**：提交活跃度 / 协作分布 / 运行稳定性 / 依赖健康。
///
/// 与 `ScoreCurvesCode.swift` 同一次拆分的另一半：`ScoreCurves.swift` 被本 App 自扫点名
/// 「巨大文件」（>400 行），按维度族切，**曲线本体、锚点表、detail 文案逐字搬迁，一个字符未改**。
///
/// 依赖健康这一维的证据三态判定（`VulnerabilityEvidence`）仍留在 `ScoreCurves.swift`：
/// 它是「没有证据 ≠ 好证据」这条原则的归属地，不留第二份。
extension HealthCurves {

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
        var recency = ""
        if let days = daysSinceLastCommit, days.isFinite {
            recency = "距今 \(decimal(Swift.max(0, days))) 天无提交"
            if days > 7 {
                // 7 天起线性扣、60 天封顶 -45。
                stalePenalty = Swift.min(45.0, Swift.max(0.0, (days - 7) / 53 * 45))
            }
        }
        let score = ScoreCurve.clamped(base - stalePenalty)
        let detail = joined([
            "日均 \(decimal(rate)) 次提交",
            recency.isEmpty ? "未提供最近提交时间" : recency,
            "累计 \(whole(totalCommits)) 次",
            rate >= 8 ? "速率偏高按碎片化折算" : "",
            stalePenalty > 0 ? "陈旧扣 \(decimal(stalePenalty)) 分" : ""
        ])
        return CurveResult(score: score, detail: detail, risk: graded(score, 85, 65, 45, 25))
    }

    // MARK: - 协作分布

    /// `commitBasis` 是**作者统计的总体**（非合并提交数），不是 `totalCommits`（含合并）。
    /// 分子 `topAuthorShare` 来自作者表，分母若换成含合并的总数就是两个总体相除（缺陷 #44）。
    static func busFactor(risk: RiskLevel, topAuthorShare: Double, activeAuthors: Int, commitBasis: Int) -> CurveResult {
        if commitBasis == 0 {
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
        let singlePoint = activeAuthors == 1 && commitBasis > 50
        if singlePoint { score = Swift.min(score, 8) }
        let shareText = String(format: "%.0f%%", share * 100)
        let detail = joined([
            "最高作者占比 \(shareText)",
            "\(whole(activeAuthors)) 位活跃作者",
            "\(whole(commitBasis)) 次非合并提交",
            share >= 0.7 ? "单人包揽重扣 22 分" : "",
            singlePoint ? "单点作者封顶 8 分" : ""
        ])
        return CurveResult(score: score, detail: detail, risk: risk)
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
        let detail = joined([
            "每千行 \(decimal(Swift.max(0, errorsPerKLoc))) 个错误",
            "崩溃 \(whole(crashCount)) 次",
            "致命 \(whole(fatalCount)) 次",
            "异常 \(whole(exceptionCount)) 次",
            "扫描 \(whole(totalLinesScanned)) 行",
            deducted > 0 ? "扣 \(decimal(deducted)) 分" : ""
        ])
        return CurveResult(score: score, detail: detail, risk: graded(score, 85, 65, 45, 20))
    }

    // MARK: - 依赖健康

    /// 依赖健康曲线。**只在 `VulnerabilityEvidence == .verified` 时调用**：
    /// 未核对/核对未完成时由评分器让整个维度缺席，而不是在这里给个打折的分数——
    /// 「零漏洞」既可能是查过之后干净，也可能压根没查，曲线分不出这两种。
    static func dependencyHealth(vulnerableCount: Int, outdatedCount: Int,
                                 totalDependencies: Int) -> CurveResult {
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
        let detail = joined([
            "依赖 \(whole(totalDependencies)) 个",
            vulnerable > 0 ? "漏洞 \(whole(vulnerable)) 个" : "漏洞核对零命中",
            "落后 \(whole(outdatedCount)) 个占 \(percent(outdatedRatio))",
            deducted > 0 ? "扣 \(decimal(deducted)) 分" : "",
        ])
        return CurveResult(score: score, detail: detail, risk: risk)
    }
}
