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
        Theme.Page.Scaffold {
            Theme.Page.Header(title: "贡献者", icon: .people)
            if let git = report?.git {
                if git.authors.isEmpty {
                    git.authorAbsence.emptyState {
                        EmptyStateView(icon: .people, title: "没有可展示的贡献者",
                                       message: "作者数据缺失，排行与占比都不成立。")
                    }
                } else {
                    let authors = ContributorAnalysis.sorted(git.authors)
                    GroupStack {
                        ContributorBusFactorSection(git: git)
                        ContributorsMetricGrid(git: git, authors: authors)
                    }
                    GroupStack {
                        ContributorRankingSection(git: git, authors: authors)
                        ContributorConcentrationSection(git: git, authors: authors)
                    }
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

    /// 风险 → 角色一律走 `Theme.Semantic.role(for:)` 这**唯一一处**判定。
    /// 这里原来自己写了一份 switch，且 `.low` 涂 `healthy`（青绿）—— 与全局
    /// `role(for risk: RiskLevel)` 的 `.low → success` 不一致，是全仓第二套强调色相
    /// 的实际来源之一（批次 P5，两批实拍独立点名"两种绿"）。
    static func role(for git: GitInsights) -> Theme.SemanticRole {
        Theme.Semantic.role(for: ContributorAnalysis.busFactorRisk(git))
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

/// 主角 = **头部作者占比**（纯数字百分比），其余三条走无面读数带。
///
/// 旧形态：`LazyVGrid` 四枚 tile，各涂 accent / role色 / neutral / success。
/// 契约 5 之后只剩一种颜色留在这儿：Bus Factor 的**状态**。而那个状态本来就由
/// `ContributorBusFactorSection` 的 `DataNotice` 用「色 + 文字 + 图标」三通道说清楚了，
/// 不需要再用 tile 数字的颜色复述一遍 —— 所以四枚 tile 的 tint 全部删掉，
/// 「头部作者占比」升为主角并回到纯墨。
///
/// **占比的分母口径必须跟着主角**：`topShare` 除的是非合并窗口，不是提交真值，
/// 那句 `authorTileCaption` 一个字都不能少，否则 42% 会被读成「42% 的全部历史」。
struct ContributorsMetricGrid: View {
    let git: GitInsights
    let authors: [AuthorStats]

    var body: some View {
        let scope = git.commitScope
        GlassSection("贡献集中度读数", subtitle: scope.headline, icon: .people) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataHeroReadout(value: Self.topShare(git).map { NumberFormat.percent($0, precision: 0) }
                                    ?? DataAbsence.notAnalysed.display,
                                unit: nil,
                                // 分母口径**由本节副标题 `scope.headline` 说一次**，
                                // 主角的 note 不再复述（同一个 GlassSection 里隔两行说两遍
                                // 同一个数字）。但 `authorBasis == 0` 那一支必须自己说：
                                // 那时 headline 给不出分母，"没有分母"这件事就是结论本身。
                                note: (git.topAuthor.map {
                                    "\(ContributorAnalysis.displayName($0)) · 一人完成 · "
                                        + "\(NumberFormat.grouped($0.commits)) 次"
                                } ?? "无作者数据")
                                    + (scope.authorBasis > 0
                                       ? ""
                                       : "（\(DataAbsence.indeterminate.textDisplay)）"))

                ReadoutStrip {
                    MetricTile(
                        label: "贡献者",
                        value: NumberFormat.grouped(authors.count),
                        icon: .people,
                        unit: "人",
                        caption: scope.authorTileCaption(authorCount: git.activeAuthorCount)
                    )
                    DataBandSeparator()
                    MetricTile(
                        label: "累计变更",
                        value: scope.authorBasis > 0
                            ? NumberFormat.compact(git.totalAdditions + git.totalDeletions) : nil,
                        unit: "行",
                        caption: "\(NumberFormat.signed(git.totalAdditions)) / "
                            + "\(NumberFormat.signed(-git.totalDeletions)) · 按非合并提交统计"
                    )
                    DataBandSeparator()
                    MetricTile(
                        label: "近 30 天活跃",
                        value: NumberFormat.grouped(ContributorAnalysis.recentlyActive(authors).count),
                        symbol: CodeGitSymbol.recency,
                        unit: "人",
                        caption: Self.recentlyActiveCaption(authors)
                    )
                }
            }
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

    /// 30 行排行一次摊开是「不规整拥挤」最典型的一处。收成 8 行 + 展开，
    /// 未展示的人数必须继续写在屏幕上。
    static let displayLimit = 8

    @State private var expanded = false

    var body: some View {
        let shown = visibleRows
        GlassSection(
            "贡献者排行",
            // 这一节只说**这一节特有的事实**（排序与可见条数）。
            // 原来把 `commitScope.headline` 整句再嵌一遍 —— 而 headline 正是上一节
            // 「贡献集中度读数」的副标题，于是同一屏出现两次逐字相同的口径句
            // （用户判词「太乱了」在密度这一维的落点：一屏 5 处「非合并提交」）。
            subtitle: "按提交数降序 · 展示 \(NumberFormat.grouped(shown.count)) / "
                + "\(NumberFormat.grouped(authors.count)) 人",
            icon: .people
        ) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                DataTableWell {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, author in
                        ContributorRow(author: author, rank: index + 1, git: git)
                        if index < shown.count - 1 {
                            DataRowSeparator()
                        }
                    }
                }
                if authors.count > Self.displayLimit {
                    DataDisclosureButton(expanded: expanded,
                                         hiddenCount: authors.count - Self.displayLimit,
                                         noun: "位贡献者") {
                        expanded.toggle()
                    }
                }
                DataFootnote(text: Self.truncationNote(authors: authors, shown: shown.count))
            }
        }
    }

    private var visibleRows: [AuthorStats] {
        expanded ? authors : Array(authors.prefix(Self.displayLimit))
    }

    /// 副标题里的「展示 N / M」已经说了数量，这里补的是**折叠这件事本身**，
    /// 展开之后必须翻成「已全部展示」，不能留一句过期的「另有 N 位」。
    static func truncationNote(authors: [AuthorStats], shown: Int) -> String {
        let total = authors.count
        guard total > shown else {
            return "共 \(NumberFormat.grouped(total)) 位贡献者，已全部展示。"
        }
        return "另有 \(NumberFormat.grouped(total - shown)) 位贡献者未展示。"
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
            DataTableWell {
                DataTableHeader(columns: DataColumns.shareBar)
                DataShareBarRow(
                    label: "前 3 名合计",
                    detail: "\(NumberFormat.grouped(topCommits)) 次",
                    fraction: Double(topCommits) / Double(base),
                    // 合计 = 「自身/主体数据」，新规则下它就是纯墨。
                    // 旧写法取 `Theme.Chart` 的 0 号位 —— 与总览那两处「182,430 涂成
                    // info 蓝」同一形状（本轮已由基座改成墨），这里跟着收口。
                    // 下面每位作者仍走稳定索引色：那才是「按 key 分辨类别」的合法用途。
                    tint: ChartSeries.lineColor
                )
                // 作者条也收墨。原来的自辩是「颜色替读者把同一作者的条与点连起来」，
                // 但这一节没有配图上的点，名字就写在条左边 —— 与 `Theme.Share.Row`、
                // `ContributorHourRow` 同一判断：不携带信息的用色就是装饰性用色。
                ForEach(top) { author in
                    DataShareBarRow(
                        label: ContributorAnalysis.displayName(author),
                        detail: "\(NumberFormat.grouped(author.commits)) 次",
                        fraction: Double(author.commits) / Double(base),
                        tint: Theme.Palette.Surface.ink
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
