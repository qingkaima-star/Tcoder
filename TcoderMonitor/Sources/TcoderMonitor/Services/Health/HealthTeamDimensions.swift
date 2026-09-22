import Foundation

/// Git 历史的两维：提交活跃度、协作分布。
/// 这两项**不受改代码影响**（历史长度、署名分布是既成事实），所以它们被
/// `HealthDimension.belongsToCodeScope` 排除在「工程质量（代码口径）」之外。
extension WeightedHealthScorer {

    // MARK: - 提交活跃度

    func activityOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let git = inputs.git, git.totalCommits > 0 else { return .absent }
        let daysSinceLast = git.lastCommitAt.map { Date().timeIntervalSince($0) / 86_400 }
        // 缺陷 #43：冻结区的 `git.commitsPerDay` 分母是 `max(1, Int(跨度/86400))`，
        // 历史不足 48 小时时那个分母被兜成 1 天，"日均"就退化成"提交总数"
        // （本仓实测 14.4 小时跨度 → 界面「提交节奏稳定（日均 271.0 次）」，271 = 总数）。
        // 字段在冻结区不改，改成在这里**另算一个浮点跨度的速率**并按历史长度分三态：
        // 样本不足就不写优点、分数封顶；连首末时刻都没有就承认"速率无定义"。
        let cadence = GitCadenceEvidence.assess(git)
        let curve = HealthCurves.activity(commitsPerDay: cadence.rateForCurve,
                                          daysSinceLastCommit: daysSinceLast,
                                          totalCommits: git.totalCommits)
        switch cadence.status {
        case .sufficient: return activitySufficient(curve, cadence, daysSinceLast)
        case .shortHistory: return activityShortHistory(curve, cadence)
        case .unknown: return activityUnknown(curve, cadence, daysSinceLast)
        }
    }

    private func activitySufficient(_ curve: CurveResult, _ cadence: GitCadenceEvidence,
                                    _ daysSinceLast: Double?) -> DimensionOutcome {
        var outcome = DimensionOutcome(curve: curve)
        if cadence.ratePerDay >= GitCadenceEvidence.steadyCadenceCommitsPerDay {
            // ⚠ 尾巴那句不是修辞，是**去重**（台账 RD-29）：同一个 `ratePerDay` 已经被曲线
            // 折算过一次（越过 8 次/天还要掉头扣分），优点卡再说一遍"稳定"就成了
            // 同一条事实声称两次贡献。门槛两处同源，见 `ScoreCurvesTeamRuntime.activity`。
            outcome.strengths.append(String(format: "提交节奏稳定（日均 %.1f 次；这个频率只在曲线里折算一次，本句不另加分）",
                                            cadence.ratePerDay))
        }
        outcome.issues = ActivityAdvice.staleIssues(daysSinceLast)
        return outcome
    }

    private func activityShortHistory(_ curve: CurveResult, _ cadence: GitCadenceEvidence) -> DimensionOutcome {
        let capped = Swift.min(curve.score, GitCadenceEvidence.shortHistoryScoreCeiling)
        return DimensionOutcome(
            curve: CurveResult(score: capped, detail: curve.detail + cadence.shortHistoryNote,
                               risk: capped < curve.score ? GitCadenceEvidence.risk(afterCappingTo: capped) : curve.risk),
            recommendations: ["提交历史仅 "
                + "\(GitCadenceEvidence.fixed(cadence.spanDays)) 天，样本不足，"
                + "活跃度不宣称节奏、按 \(GitCadenceEvidence.fixed(GitCadenceEvidence.shortHistoryScoreCeiling)) 分封顶；"
                + "跑满一周后重扫即可解锁。"])
    }

    private func activityUnknown(_ curve: CurveResult, _ cadence: GitCadenceEvidence,
                                 _ daysSinceLast: Double?) -> DimensionOutcome {
        DimensionOutcome(curve: CurveResult(score: curve.score, detail: curve.detail + cadence.unknownNote,
                                            risk: curve.risk),
                         issues: ActivityAdvice.staleIssues(daysSinceLast),
                         recommendations: ["提交历史缺可用的首末时间，日均无法计算，"
                             + "活跃度按曲线最低档计，等重新分析补齐两端再评。"])
    }

    private enum ActivityAdvice {
        static func staleIssues(_ daysSinceLast: Double?) -> [String] {
            guard let days = daysSinceLast, days > 14 else { return [] }
            return [String(format: "已 %.0f 天无提交", days)]
        }
    }

    // MARK: - 协作分布

    func busFactorOutcome(_ inputs: HealthInputs) -> DimensionOutcome {
        guard let git = inputs.git, git.totalCommits > 0 else { return .absent }
        // 「没有可算作者分布的总体」必须在**这里**判成整维缺席，不能留给曲线兜一个占位分：
        // 旧写法是 `max(git.authorBasisCommits, 1)`，把 0 折成"1 笔非合并提交"再算占比 ——
        // 那一笔还是根提交本身，等于拿一条记录冒充一个分布（台账 RD-29 的同族形态）。
        // 现在走 `stability` / `dependencies` 已经在用的那条路：`curve: nil` ⇒
        // 进 `HealthBreakdown.missingDimensions`（界面与 CLI 都点名原因），份额按在场维度等比摊入。
        guard let top = git.topAuthor, git.authorBasisCommits > 0 else {
            return DimensionOutcome(curve: nil, recommendations: [BusFactorAdvice.noAuthorBasis(git)])
        }
        // 分母必须是作者表的总体（非合并），见 `GitInsights.authorBasisCommits`。
        // 用 totalCommits（含合并）会把 91% 的集中度算成 51%（缺陷 #44）。
        let basis = git.authorBasisCommits
        let share = Double(top.commits) / Double(basis)
        let curve = HealthCurves.busFactor(risk: git.busFactorRisk, topAuthorShare: share,
                                           activeAuthors: git.activeAuthorCount, commitBasis: basis)
        return DimensionOutcome(curve: curve,
                                strengths: busFactorStrengths(git, share),
                                issues: busFactorIssues(top, share))
    }

    /// 这一维缺席时**必须出声**：只把它从分量表里摘掉，读分的人看到的是"少了一维"，
    /// 而不是"这一维为什么没算"。（与 `StabilityAdvice.missingLogAdvice` 同一形态。）
    private enum BusFactorAdvice {
        static func noAuthorBasis(_ git: GitInsights) -> String {
            "作者表里没有可算分布的提交（非合并口径 0 笔，含合并共 \(NumberFormat.grouped(git.totalCommits)) 笔），"
                + "协作分布不参与本次计分；这一维读的是「署名分布」，要有非合并提交才谈得上分散与否。"
        }
    }

    private func busFactorStrengths(_ git: GitInsights, _ share: Double) -> [String] {
        guard git.activeAuthorCount >= 4, share < 0.45 else { return [] }
        // 「N 个署名」不是「N 个人」（台账 RD-28 / AGENTS §7 署名口径的诚实边界）：
        // 本仓按流署名，一个署名通常是一条工作流；这句要是写成人数，
        // 就把"哪条流握着这块代码"说成了"多人协作已经很分散"。
        let counted = NumberFormat.grouped(git.activeAuthorCount)
        return ["贡献分布合理（\(counted) 个署名，头号署名占 \(NumberFormat.percent(share, precision: 0))；"
            + "署名按工作流计，不等于 \(counted) 个人）"]
    }

    private func busFactorIssues(_ top: AuthorStats, _ share: Double) -> [String] {
        guard share > 0.6 else { return [] }
        // 同一条口径：被点出来的是**一个署名**，不是"一个人"；单点风险本身照旧成立，
        // 不许因为换了称呼就把它说轻或说重。
        return [String(format: "「%@」这个署名占 %.0f%% 提交，单点风险高（署名按工作流计，不等同于一个人头）",
                       top.name, share * 100)]
    }
}
