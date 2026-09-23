import Foundation

/// 健康评分标定曲线的**代码族分片**：复杂度 / 重复度 / 代码质量 / 注释与可维护性。
///
/// 为什么单独一个文件（不是新口径）：`ScoreCurves.swift` 被本 App 自扫点名「巨大文件」
/// （>400 行），按 `HealthCurves` 的**维度族**切片是唯一不动任何锚点的拆法——
/// 曲线本体、锚点表、detail 文案在此文件与 `ScoreCurves.swift` 之间**逐字搬迁，一个字符未改**。
///
/// 锚点数字仍属对外承诺：改这里等于改规约，必须连 `HealthScoreTests` A~G 一起改。
/// 共用的插值原语（`ScoreCurve.piecewise` / `clamped`）、标定常量
/// `HealthCurves.smallSampleCodeLines`、格式化与风险分档工具都留在 `ScoreCurves.swift`，
/// 这里只是调用方——同一个原语不留第二份（两份口径并存时，错的那套常在喂数据）。
///
/// ⚠ 批次 P58 改过本文件的 detail 文案**写法**（片段插值 → 整句键 + 位置参数）：
/// 中文态输出逐字未变，变的是英文态能不能查到译文。锚点表一个数字都没动。
extension HealthCurves {

    // MARK: - 复杂度

    /// **调用前置条件：`functionCount > 0`（`HealthCurves` 的锚点契约）。**
    /// 没有任何函数时这里给的是满分 + 「未发现可计数的函数体」——那是**曲线层的口径**，
    /// 由 `HealthScoreTests.testComplexityWithoutFunctionsIsPerfectAndExplained` 钉住。
    /// 评分器不得拿它当「读不懂 = 简单」的证据：`WeightedHealthScorer` 的复杂度分支
    /// 在均值/分母/热点榜三者都没有证据时让整个维度缺席，而不是调到这里。
    static func complexity(averageCC: Double, highRiskCount: Int, maxCC: Int, functionCount: Int) -> CurveResult {
        if functionCount == 0 {
            return CurveResult(score: 100, detail: localizedCopy("未发现可计数的函数体"), risk: .none)
        }
        let base = ScoreCurve.piecewise(averageCC, through: [
            (x: 1, score: 100), (x: 3, score: 92), (x: 5, score: 80), (x: 8, score: 60),
            (x: 12, score: 38), (x: 16, score: 22), (x: 25, score: 6), (x: 40, score: 0)
        ])
        let highRiskPenalty = Swift.min(30.0, Double(Swift.max(0, highRiskCount)) * 3)
        let outlierPenalty = maxCC >= 40 ? 10.0 : 0
        let deducted = highRiskPenalty + outlierPenalty
        let score = ScoreCurve.clamped(base - deducted)
        let detail = joined([
            localizedFormat("平均圈复杂度 %1$@", decimal(averageCC)),
            localizedFormat("%1$@ 个函数 CC≥16", whole(highRiskCount)),
            localizedFormat("最大 %1$@", whole(maxCC)),
            deducted > 0 ? localizedFormat("基准 %1$@ 分扣 %2$@ 分", decimal(base), decimal(deducted)) : ""
        ])
        return CurveResult(score: score, detail: detail, risk: graded(score, 80, 60, 40, 22))
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
        if lines < smallSampleCodeLines {
            detail = joined([
                localizedFormat("重复率 %1$@", percent(value)),
                localizedFormat("样本过小，按 %1$@ 行代码估计，置信度低", whole(lines))
            ])
        } else {
            detail = joined([
                localizedFormat("重复率 %1$@", percent(value)),
                localizedFormat("按 %1$@ 行代码统计", whole(lines))
            ])
        }
        return CurveResult(score: score, detail: detail, risk: graded(score, 90, 70, 45, 15))
    }

    // MARK: - 代码质量

    static func codeQuality(hugeFileRatio: Double, averageFunctionLength: Int, longFunctions: Int, totalFiles: Int) -> CurveResult {
        if totalFiles == 0 {
            return CurveResult(score: 100, detail: localizedCopy("未发现可评估的源码文件"), risk: .none)
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
        let detail = joined([
            localizedFormat("巨大文件占比 %1$@", percent(hugeFileRatio)),
            localizedFormat("平均函数 %1$@ 行", whole(averageFunctionLength)),
            localizedFormat("共 %1$@ 个文件", whole(totalFiles)),
            longPenalty > 0 ? localizedFormat("%1$@ 个超长函数扣 %2$@ 分",
                                              whole(longFunctions), decimal(longPenalty)) : ""
        ])
        return CurveResult(score: score, detail: detail, risk: graded(score, 90, 70, 45, 15))
    }

    // MARK: - 注释与可维护性

    /// **调用前置条件：`totalLines > 0`。** 0 行时返回的 50 分是「无源码可评估」的占位口径，
    /// 不是测量结果；评分器遇到零分母时让整个维度缺席（`.documentation` 分支的 guard），
    /// 免得一个占位值参与加权、把在场维度的权重摊薄。
    static func documentation(commentRatio: Double, todoCount: Int, fixmeCount: Int, totalLines: Int) -> CurveResult {
        if totalLines == 0 {
            return CurveResult(score: 50, detail: localizedCopy("无源码可评估"), risk: graded(50, 85, 65, 45, 25))
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
        if ratio < 0.02 { band = localizedCopy("低于 2% 最佳下限") }
        else if ratio > 0.15 { band = localizedCopy("注释过多同样扣分") }
        else { band = localizedCopy("落在 2%~15% 最佳区间") }
        let detail = joined([
            localizedFormat("注释占比 %1$@（%2$@）", percent(ratio), band),
            localizedFormat("TODO %1$@ 个", whole(todoCount)),
            localizedFormat("FIXME %1$@ 个", whole(fixmeCount)),
            localizedFormat("总行 %1$@（含空行与注释）", whole(totalLines)),
            deducted > 0 ? localizedFormat("标记扣 %1$@ 分", decimal(deducted)) : ""
        ])
        return CurveResult(score: score, detail: detail, risk: graded(score, 85, 65, 45, 25))
    }
}
