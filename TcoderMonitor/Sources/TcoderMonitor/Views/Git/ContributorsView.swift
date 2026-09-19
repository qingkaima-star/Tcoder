import SwiftUI

/// OWNER: WS-L —— Git 贡献者页。
///
/// 2026-09-19 重样（WS-L）：头像与占比条的分类色全部改走 `Theme.Chart` 单一色板 +
/// FNV-1a 稳定哈希（原来是文件里 8 个 `Color(hex:)`，深色模式无变体）；字号、圆角、
/// 间距、图标全部取自 `Design/` 令牌；「贡献者」表头与术语按 WS-H §1.3 归一。
/// 占比分母与 Git 洞察页共用 `GitHistoryScope`，两页不会再各说一套。
struct ContributorsView: View {
    var report: ProjectReport?

    var body: some View {
        DataPageScaffold {
            if let git = report?.git {
                if git.authors.isEmpty {
                    EmptyStateView(
                        icon: .people,
                        title: "该仓库暂无贡献者数据",
                        message: "仓库可能是空仓库，或历史里只有不带作者信息的合并提交。\n"
                            + "提交一次普通改动后重新分析即可看到排行。"
                    )
                } else {
                    let authors = ContributorAnalysis.sorted(git.authors)
                    ContributorBusFactorSection(git: git)
                    ContributorsMetricGrid(git: git, authors: authors)
                    ContributorRankingSection(git: git, authors: authors)
                    ContributorConcentrationSection(git: git, authors: authors)
                }
            } else {
                EmptyStateView(
                    icon: .people,
                    title: "尚未分析 Git 历史",
                    message: "选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示贡献者排行、代码变更量与活跃时段分布。"
                )
            }
        }
    }
}

// MARK: - Bus Factor 结论

struct ContributorBusFactorSection: View {
    let git: GitInsights

    var body: some View {
        DataNotice(text: Self.message(for: git), role: Self.role(for: git),
                   icon: Self.icon(for: git), iconLabel: "贡献集中度结论")
    }

    static func role(for git: GitInsights) -> Theme.SemanticRole {
        switch ContributorAnalysis.busFactorRisk(git) {
        case .critical, .high: return Theme.Semantic.danger
        case .medium: return Theme.Semantic.warning
        case .low: return Theme.Semantic.healthy
        case .none: return Theme.Semantic.neutral
        }
    }

    static func icon(for git: GitInsights) -> IconName {
        switch ContributorAnalysis.busFactorRisk(git) {
        case .critical, .high: return .riskSevere
        case .medium: return .riskWarning
        case .low: return .noRisk
        case .none: return .unverified
        }
    }

    /// 结论句必须带分母口径：单人占比是相对**非合并窗口**算的，不说清就等于借了真值的名。
    static func message(for git: GitInsights) -> String {
        let scope = git.commitScope
        guard let top = git.topAuthor, scope.authorBasis > 0 else {
            return "没有可用的提交作者统计，无法评估 Bus Factor。"
        }
        let share = NumberFormat.percent(Double(top.commits) / Double(scope.authorBasis), precision: 0)
        let name = ContributorAnalysis.displayName(top)
        let basis = "（分母 = \(NumberFormat.grouped(scope.authorBasis)) 次非合并提交）"
        switch ContributorAnalysis.busFactorRisk(git) {
        case .critical:
            return "单点风险：\(basis) 全部来自 \(name) 一人，活跃作者仅 "
                + "\(NumberFormat.grouped(git.activeAuthorCount)) 人。"
        case .high:
            return "\(share) 的提交由 \(name) 一人完成 \(basis)，存在单点风险。"
        case .medium:
            return "\(share) 的提交来自 \(name) \(basis)，建议安排代码评审与交接。"
        case .low:
            return "贡献分布健康：\(NumberFormat.grouped(git.activeAuthorCount)) 位活跃作者，"
                + "最高占比 \(share)（\(name)）。"
        case .none:
            return "作者样本不足以判断集中度。"
        }
    }
}

// MARK: - 指标条

struct ContributorsMetricGrid: View {
    let git: GitInsights
    let authors: [AuthorStats]

    private static let columns = [GridItem(.adaptive(minimum: Theme.Layout.tileMinWidth),
                                           spacing: Theme.Spacing.gutter)]

    var body: some View {
        let scope = git.commitScope
        LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.gutter) {
            MetricTile(
                label: "贡献者",
                value: NumberFormat.grouped(authors.count),
                icon: .people,
                unit: "人",
                caption: scope.authorTileCaption(authorCount: git.activeAuthorCount),
                tint: Theme.Semantic.accent.textColor
            )
            MetricTile(
                label: "头部作者占比",
                value: Self.topShare(git).map { NumberFormat.percent($0, precision: 0) },
                icon: .topContributor,
                caption: git.topAuthor.map {
                    "\(ContributorAnalysis.displayName($0)) · \(NumberFormat.grouped($0.commits)) 次"
                } ?? "无作者数据",
                tint: Theme.Semantic.role(for: ContributorAnalysis.busFactorRisk(git)).textColor
            )
            MetricTile(
                label: "累计变更",
                value: scope.authorBasis > 0
                    ? NumberFormat.compact(git.totalAdditions + git.totalDeletions) : nil,
                unit: "行",
                caption: "\(NumberFormat.signed(git.totalAdditions)) / "
                    + "\(NumberFormat.signed(-git.totalDeletions)) · 按非合并提交统计",
                tint: Theme.Semantic.neutral.textColor
            )
            MetricTile(
                label: "近 30 天活跃",
                value: NumberFormat.grouped(ContributorAnalysis.recentlyActive(authors).count),
                symbol: CodeGitSymbol.recency,
                unit: "人",
                caption: Self.recentlyActiveCaption(authors),
                tint: Theme.Semantic.success.textColor
            )
        }
    }

    static func topShare(_ git: GitInsights) -> Double? {
        let scope = git.commitScope
        guard let top = git.topAuthor, scope.authorBasis > 0 else { return nil }
        return Double(top.commits) / Double(scope.authorBasis)
    }

    static func recentlyActiveCaption(_ authors: [AuthorStats]) -> String {
        guard let best = ContributorAnalysis.recentlyActive(authors)
            .max(by: { ($0.lastCommitAt ?? .distantPast) < ($1.lastCommitAt ?? .distantPast) }) else {
            return "近 30 天无人提交"
        }
        return "最近：\(ContributorAnalysis.displayName(best)) · \(best.lastActiveDescription)"
    }
}

// MARK: - 排行

struct ContributorRankingSection: View {
    let git: GitInsights
    let authors: [AuthorStats]

    static let displayLimit = 30

    var body: some View {
        let shown = Array(authors.prefix(Self.displayLimit))
        GlassSection(
            "贡献者排行",
            subtitle: "按提交数降序 · 展示 \(NumberFormat.grouped(shown.count)) / "
                + "\(NumberFormat.grouped(authors.count)) 人 · \(git.commitScope.headline)",
            icon: .people
        ) {
            VStack(spacing: Theme.Spacing.sm) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, author in
                    ContributorRow(author: author, rank: index + 1, git: git)
                    if index < shown.count - 1 {
                        DataRowSeparator()
                    }
                }
                if authors.count > Self.displayLimit {
                    Text("另有 \(NumberFormat.grouped(authors.count - Self.displayLimit)) 位贡献者未展示")
                        .font(Theme.Typo.microLabel.font)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
    }
}

// MARK: - 集中度

struct ContributorConcentrationSection: View {
    let git: GitInsights
    let authors: [AuthorStats]

    var body: some View {
        let scope = git.commitScope
        let top = Array(authors.prefix(3))
        let base = max(1, scope.authorBasis)
        let topCommits = top.reduce(0) { $0 + $1.commits }
        GlassSection(
            "贡献集中度",
            subtitle: "Bus Factor \(NumberFormat.grouped(max(1, top.count))) · 前 3 名合计 "
                + "\(NumberFormat.percent(Double(topCommits) / Double(base), precision: 0))"
                + scope.windowSuffix,
            icon: .chartLine
        ) {
            VStack(spacing: Theme.Spacing.xs) {
                DataTableHeader(columns: DataColumns.shareBar)
                DataShareBarRow(
                    label: "前 3 名合计",
                    detail: "\(NumberFormat.grouped(topCommits)) 次",
                    fraction: Double(topCommits) / Double(base),
                    tint: Theme.Chart.color(at: 0)
                )
                ForEach(top) { author in
                    DataShareBarRow(
                        label: ContributorAnalysis.displayName(author),
                        detail: "\(NumberFormat.grouped(author.commits)) 次",
                        fraction: Double(author.commits) / Double(base),
                        tint: ContributorAnalysis.color(for: author.email)
                    )
                }
            }
            if git.activeAuthorCount <= 1 {
                DataNotice(text: "全部提交仅来自 1 位贡献者，任何离队都会让项目停摆。",
                           role: Theme.Semantic.danger, icon: .riskSevere,
                           iconLabel: "单人风险")
            } else if ContributorAnalysis.busFactorRisk(git).rank >= RiskLevel.high.rank {
                DataNotice(
                    text: "其余 \(NumberFormat.grouped(git.activeAuthorCount - 1)) 位作者合计不足 "
                        + "\(NumberFormat.percent(1 - Double(top.first?.commits ?? 0) / Double(base), precision: 0))，"
                        + "缺少可接手的第二人。",
                    role: Theme.Semantic.warning, icon: .riskWarning, iconLabel: "交接风险")
            }
        }
    }
}
