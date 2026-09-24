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
            outcome.strengths.append(localizedFormat(
                "提交节奏稳定（日均 %1$@ 次；这个频率只在曲线里折算一次，本句不另加分）",
                GitCadenceEvidence.fixed(cadence.ratePerDay)))
        }
        outcome.issues = ActivityAdvice.staleIssues(daysSinceLast)
        return outcome
    }

    private func activityShortHistory(_ curve: CurveResult, _ cadence: GitCadenceEvidence) -> DimensionOutcome {
        let capped = Swift.min(curve.score, GitCadenceEvidence.shortHistoryScoreCeiling)
        return DimensionOutcome(
            curve: CurveResult(score: capped, detail: HealthCurves.noted(curve.detail, [cadence.shortHistoryNote]),
                               risk: capped < curve.score ? GitCadenceEvidence.risk(afterCappingTo: capped) : curve.risk),
            recommendations: [localizedFormat(
                "提交历史仅 %1$@ 天，样本不足，活跃度不宣称节奏、按 %2$@ 分封顶；跑满一周后重扫即可解锁。",
                GitCadenceEvidence.fixed(cadence.spanDays),
                GitCadenceEvidence.fixed(GitCadenceEvidence.shortHistoryScoreCeiling))])
    }

    private func activityUnknown(_ curve: CurveResult, _ cadence: GitCadenceEvidence,
                                 _ daysSinceLast: Double?) -> DimensionOutcome {
        DimensionOutcome(curve: CurveResult(score: curve.score,
                                            detail: HealthCurves.noted(curve.detail, [cadence.unknownNote]),
                                            risk: curve.risk),
                         issues: ActivityAdvice.staleIssues(daysSinceLast),
                         recommendations: [localizedCopy(
                            "提交历史缺可用的首末时间，日均无法计算，活跃度按曲线最低档计，等重新分析补齐两端再评。")])
    }

    private enum ActivityAdvice {
        static func staleIssues(_ daysSinceLast: Double?) -> [String] {
            guard let days = daysSinceLast, days > 14 else { return [] }
            return [localizedFormat("已 %1$@ 天无提交", HealthCurves.whole(Int(days.rounded())))]
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
        // ⚠ 这一道**必须排在下面那把新地板之前**：`commitBasis == 0` 走 R9 已定的 fail-loud 口径，
        // 不许被"最小总体"抢先兜成"样本不足"（工单 R9b §4.4）。
        guard let top = git.topAuthor, git.authorBasisCommits > 0 else {
            return DimensionOutcome(curve: nil, recommendations: [BusFactorAdvice.noAuthorBasis(git)])
        }
        // 分母必须是作者表的总体（非合并），见 `GitInsights.authorBasisCommits`。
        // 用 totalCommits（含合并）会把 91% 的集中度算成 51%（缺陷 #44）。
        let basis = git.authorBasisCommits
        // 总体小到"一笔提交就能跨档"时，占比这个数**无定义**（既不是"很分散"也不是"很集中"），
        // 所以整维缺席 —— 与"缺席 ≠ 0 分"是同一条线：不参与归一化，不按 0 计入。
        // ⚠ 地板**只管多人**：单人（`activeAuthorCount < 2`）是一条**已经确定**的结论
        // （全部提交都在一个署名上 ⇒ 占比 100%），任何地板都不许把它兜成"无从评估"——
        // 那等于用一条规矩洗掉全表最真实的那条单点风险。判据与推导见 `BusFactorEvidence`。
        if BusFactorEvidence.isShareUndefined(git) {
            return DimensionOutcome(curve: nil, recommendations: [BusFactorAdvice.thinAuthorBasis(git)])
        }
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
            localizedFormat("作者表里没有可算分布的提交（非合并口径 0 笔，含合并共 %1$@ 笔），协作分布不参与本次计分；这一维读的是「署名分布」，要有非合并提交才谈得上分散与否。",
                            NumberFormat.grouped(git.totalCommits))
        }

        /// 理由句必须点名**三个数**：`commitBasis`、`activeAuthorCount`，
        /// 加上"占比无定义"的算术依据（一笔折合多少个百分点、攒到几笔才解锁）。
        /// 只写"样本不足"四个字等于没写（工单 R9b §4.3）。
        static func thinAuthorBasis(_ git: GitInsights) -> String {
            localizedFormat("作者分布的总体只有 %1$@ 笔非合并提交、%2$@ 个活跃署名 —— 一笔提交就折合 %3$@ 占比，跨一个档位只要一两笔 ⇒ 占比无定义，协作分布不参与本次计分（也不按 0 计入）；非合并提交攒到 %4$@ 笔以上重扫即可解锁。",
                            NumberFormat.grouped(git.authorBasisCommits),
                            NumberFormat.grouped(git.activeAuthorCount),
                            NumberFormat.percent(BusFactorEvidence.shareSwing(for: git), precision: 0),
                            NumberFormat.grouped(BusFactorEvidence.minimumCommitBasisForShare))
        }
    }

    private func busFactorStrengths(_ git: GitInsights, _ share: Double) -> [String] {
        guard git.activeAuthorCount >= 4, share < 0.45 else { return [] }
        // 「N 个署名」不是「N 个人」（台账 RD-28 / AGENTS §7 署名口径的诚实边界）：
        // 本仓按流署名，一个署名通常是一条工作流；这句要是写成人数，
        // 就把"哪条流握着这块代码"说成了"多人协作已经很分散"。
        let counted = NumberFormat.grouped(git.activeAuthorCount)
        return [localizedFormat("贡献分布合理（%1$@ 个署名，头号署名占 %2$@；署名按工作流计，不等于 %1$@ 个人）",
                                    counted, NumberFormat.percent(share, precision: 0))]
    }

    private func busFactorIssues(_ top: AuthorStats, _ share: Double) -> [String] {
        guard share > 0.6 else { return [] }
        // 同一条口径：被点出来的是**一个署名**，不是"一个人"；单点风险本身照旧成立，
        // 不许因为换了称呼就把它说轻或说重。
        return [localizedFormat("「%1$@」这个署名占 %2$@ 提交，单点风险高（署名按工作流计，不等同于一个人头）",
                                    top.name, NumberFormat.percent(share, precision: 0))]
    }
}

// MARK: - 协作分布的「最小总体」（RD-46 同族，工单 R9b §4 由总工拍板）

/// 判"作者分布的总体够不够算一个占比"。
///
/// 问题：一个只有 3 笔非合并提交的仓库，`topAuthorShare` 能取到的值只有
/// {0.333, 0.667, 1.0} —— **「两个人各写一半」这个形状在这把尺子上根本表达不出来**。
/// 这时把 66.7% 说成"偏集中"、把 100% 说成"包揽"，量的都是**网格**而不是协作。
enum BusFactorEvidence {
    /// 算得出一个**说得出口**的占比所需的最小非合并提交数：**7 笔**。
    ///
    /// 推导（两条前提，都是仓里已有的数，没有一个是为让本仓过关挑的）：
    /// 1. 总体 N 笔时，头号作者占比只能是 k/N ⇒ **一笔提交折合 1/N** 的占比变化（恒等式）；
    /// 2. `HealthCurves.busFactor` 的调档边界是 0.35 / 0.5 / 0.7（+6 / +2 / −6 / −22 四档），
    ///    其中最窄的一档是 0.35→0.5，宽 **0.15**。
    /// 要"一笔提交"不足以把人推过最窄的一档，需要 `1/N ≤ 0.15` ⇒ N ≥ 6.67 ⇒ **N ≥ 7**。
    /// 边界两侧都是算得出的：N = 6 时一笔 = 16.7% > 15%（跨档只要一笔）；
    /// N = 7 时一笔 = 14.3% ≤ 15%（最窄档需要两笔才跨得过去）。
    /// 所以 7 是"一次提交改不动结论"的**最小**整数，取 6 就是让这条线自己失去意义，
    /// 取 20 或 50 只是把同一个判据挪到没有依据的位置上（并且会更容易把真实单点风险兜成缺席）。
    ///
    /// ⚠ 为什么**不能**复用 `GitCadenceEvidence.minimumSpanDays`（7 天）：那把尺子量的是
    /// **时间跨度够不够说"节奏"**，这一把量的是**总体够不够算"占比"**。两者互不蕴含：
    /// 一天里 squash 出 5,000 笔的仓库跨度不够、总体够；跨了三年只留下 3 笔的仓库
    /// 跨度够、总体不够。数值撞成同一个 7 是巧合，不是同源 ——
    /// 所以这里新写一个常量，并且靠 `ScoreEvidenceFloorTests` 钉住两处**不许**互相引用。
    static let minimumCommitBasisForShare: Int = 7

    /// 曲线最窄一档的宽度（0.35 → 0.5），与 `HealthCurves.busFactor` 的调档表同源；
    /// 对账由测试逐字盯着，两处一旦分叉立刻红。
    static let narrowestShareBand: Double = 0.15

    /// 一笔提交折合多少占比（理由句要把它说出来，不让人自己去心算 1/N）。
    static func shareSwing(for git: GitInsights) -> Double {
        shareSwing(commitBasis: git.authorBasisCommits)
    }

    static func shareSwing(commitBasis: Int) -> Double {
        guard commitBasis > 0 else { return 1 }
        return 1 / Double(commitBasis)
    }

    /// 占比是否**无定义**（总体太小，一笔提交就能跨档）。
    ///
    /// ⚠ 只对多人成立：`activeAuthorCount < 2` 时"全部提交都在一个署名上"是
    /// 一条已经确定的结论（bus factor = 1），不是样本不足 —— 地板对它不适用，
    /// 无论总体多小都要照常出分（并因此拿低分）。这是本条判据的**边界**，
    /// 由 `ScoreEvidenceFloorTests` 用"单人 + 小总体必须仍是低分"钉住。
    static func isShareUndefined(_ git: GitInsights) -> Bool {
        git.activeAuthorCount >= 2 && git.authorBasisCommits < minimumCommitBasisForShare
    }

    /// 界面与 CLI 的缺席原因（`HealthBreakdown.gitAbsence` 读这一份，不留第二把尺子）。
    static func absenceReason(_ git: GitInsights) -> String {
        localizedFormat("非合并口径 %1$@ 笔、%2$@ 个活跃署名，低于评这一维所需的 %3$@ 笔总体 —— 一笔提交折合 %4$@ 占比，占比无定义，本维度不参与计分（也不按 0 计入）。",
                        NumberFormat.grouped(git.authorBasisCommits),
                        NumberFormat.grouped(git.activeAuthorCount),
                        NumberFormat.grouped(minimumCommitBasisForShare),
                        NumberFormat.percent(shareSwing(for: git), precision: 0))
    }
}
