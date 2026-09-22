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
            // ⚠ 门槛**不许在这里再抄一个数字**：优点句「提交节奏稳定」与这句「速率偏高按碎片化折算」
            // 说的是同一个数，两处各写一遍就会出现"一处当优点、一处当扣分理由"（台账 RD-29）。
            // 两处现在同源于 `GitCadenceEvidence.steadyCadenceCommitsPerDay`（值仍是 8，没动过）。
            rate >= GitCadenceEvidence.steadyCadenceCommitsPerDay ? "速率偏高按碎片化折算" : "",
            stalePenalty > 0 ? "陈旧扣 \(decimal(stalePenalty)) 分" : ""
        ])
        return CurveResult(score: score, detail: detail, risk: graded(score, 85, 65, 45, 25))
    }

    // MARK: - 协作分布

    /// `commitBasis` 是**作者统计的总体**（非合并提交数），不是 `totalCommits`（含合并）。
    /// 分子 `topAuthorShare` 来自作者表，分母若换成含合并的总数就是两个总体相除（缺陷 #44）。
    ///
    /// ⚠️ **`commitBasis == 0` 这一支在生产路径上不可达**（WS-R9 实测，台账 RD-29 的结案）：
    /// 唯一调用方 `WeightedHealthScorer.busFactorOutcome` 现在把"没有可算作者分布的总体"
    /// 直接判成整维缺席（`curve: nil` ⇒ `HealthBreakdown.missingDimensions`），压根不进来这里；
    /// 而 `authorBasisCommits` 是作者表求和、每个署名至少 1 笔，`topAuthor == nil` 时上面那条
    /// 守卫也已经把维度摘掉了。**结构上也没有"0 笔非合并提交却有提交"的仓库**：
    /// `git log --no-merges` 至少返回那个根提交（`.scratch/r9-fixture/` 的合并夹具实测：
    /// 1 笔非合并 + 19 次合并 ⇒ 总体 20，不是 0）。所以这里**不保留任何占位分**。
    ///
    /// 旧写法是 `score 70 + 「提交记录过少，暂不评估协作分布」` —— 话说不评估、数照进加权。
    /// 现在这条只剩一个用途：**万一守卫被改动、0 真的漏进来，宁可当场把综合分砸出一个
    /// 显眼的 0/严重风险，也绝不再悄悄抬一手**（fail-loud 而不是 fail-open）。
    /// 没有用 `assertionFailure`：本文件的直接调用方还包括单测
    /// （`HealthScoreCurvesTests` 就拿 `commitBasis: 0` 敲过一次边界），
    /// 在测试进程里 trap 等于把别人那条用例改成崩溃。
    static func busFactor(risk: RiskLevel, topAuthorShare: Double, activeAuthors: Int, commitBasis: Int) -> CurveResult {
        if commitBasis <= 0 {
            return CurveResult(score: 0, detail: "作者分布总体为 0，本维度不该计分（内部守卫）",
                               risk: .critical)
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
            // 「署名」不是「人数」（台账 RD-28）：`activeAuthors` 数的是 git 作者身份，
            // 本仓按流署名 ⇒ 一个署名可能是一条工作流，也可能是同一个人在两台机器上。
            "\(whole(activeAuthors)) 个活跃署名",
            "\(whole(commitBasis)) 次非合并提交",
            share >= 0.7 ? "单一署名包揽重扣 22 分" : "",
            singlePoint ? "单一署名封顶 8 分" : ""
        ])
        return CurveResult(score: score, detail: detail, risk: risk)
    }

    // MARK: - 运行稳定性

    /// 运行稳定性曲线。
    ///
    /// **分母换掉了，锚点表一个数字都没动。**
    /// 整改前 `errorsPerKLoc` 的量程是「错误数 ÷ 源码行数 × 1000」（调用方在
    /// `HealthRuntimeDimensions.stabilityOutcome`），于是**往仓库里加代码就能让同样多的
    /// 错误显得更稳定** —— 源码行数不是运行暴露量，它是"这个项目写了多少行"。
    /// 现在分母换成**本次扫到的日志行数**（`totalLinesScanned`）：它至少随运行时长增长，
    /// 与代码体量无关，"加代码 = 更稳定" 这条路被 `HealthStabilityDenominatorTests` 钉死。
    ///
    /// ⚠️ 保留边界（交总工复核，不是本流自己收口）：锚点值 0 / 0.5 / 1.5 / 3 / 6 / 12 / 25
    /// 当年是按"每千行**代码**"标定的，直接搬到"每千行**日志**"上属于换了量程沿用刻度。
    /// 本轮只做正确性修正（不伪分母、不为提指标动任何锚点），**独立样本重新标定归总工**，
    /// 已登记在 Obsidian `110` 的契约缺口一节。
    /// `detail` 由 `HealthCurves.joined` 限到 60 字（评分卡那一行放不下长句），
    /// 所以**"证据不足"那几句不在这里**，在 `WeightedHealthScorer` 的 recommendations 里。
    ///
    /// ⚠️ **`totalLinesScanned == 0` 那一支（85 分 + 「按默认值计」）在生产路径上不可达**
    /// （WS-R9 实测，工单靶子 2 的结案）：唯一调用方 `HealthRuntimeDimensions.stabilityOutcome`
    /// 先判 `logs.totalLinesScanned > 0`，不满足就整维缺席并把原因写进建议；
    /// 真子进程同形状实测 —— `score <夹具> --log=<0 字节文件>` 打的是
    /// 「缺席维度… 运行稳定性 — 未发现可读的日志文件。」，综合分与"完全没日志"一字不差（66）。
    /// ⇒ **它是死支，不是一个已修掉的扣分缺陷**；建议下一轮整块删除或改成断言级。
    /// 本流没有自己删它，两个理由：① 别的流的单测
    /// （`HealthScoreCurvesTests+ActivityAndNarrative.testStabilityNeverFakesUnscannedLogsAsPerfect`）
    /// 直接拿 `totalLinesScanned: 0` 敲这一支并断言 detail 措辞，改成 `assertionFailure`
    /// 等于把别人的用例改成崩溃；② 判死代码要先查 stash 与重复实现（AGENTS §7），删归总工。
    /// 取而代之留了一条**可达性守卫**（`ScoreWordingTests`）：guard 一变没、第二调用点一出现就红。
    static func stability(errorsPerKiloLogLines: Double, crashCount: Int, fatalCount: Int,
                          exceptionCount: Int, totalLinesScanned: Int) -> CurveResult {
        if totalLinesScanned == 0 {
            // 死支（见上面那段）：没扫到日志就不假装满分，也不假装零分。
            return CurveResult(score: 85, detail: "未扫描到运行日志，本维度按默认值计", risk: .low)
        }
        let base = ScoreCurve.piecewise(Swift.max(0, errorsPerKiloLogLines), through: [
            (x: 0, score: 100), (x: 0.5, score: 92), (x: 1.5, score: 78), (x: 3, score: 58),
            (x: 6, score: 32), (x: 12, score: 12), (x: 25, score: 0)
        ])
        let crashPenalty = Swift.min(48.0, Double(Swift.max(0, crashCount)) * 12)
        let fatalPenalty = Swift.min(24.0, Double(Swift.max(0, fatalCount)) * 8)
        let exceptionPenalty = Swift.min(15.0, Double(Swift.max(0, exceptionCount) / 5) * 3)
        let deducted = crashPenalty + fatalPenalty + exceptionPenalty
        let score = ScoreCurve.clamped(base - deducted)
        let detail = joined([
            "每千行日志 \(decimal(Swift.max(0, errorsPerKiloLogLines))) 个错误",
            "确认崩溃 \(whole(crashCount)) 次",
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
