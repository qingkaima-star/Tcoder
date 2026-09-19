import SwiftUI

// MARK: - 贡献者页的行件与分析口径（WS-L）
//
// 从 `ContributorsView.swift` 拆出：整页连行件一起写会撞上 800 行棘轮。
// 这里的 `ContributorAnalysis` 是纯函数集合，占比分母与 Bus Factor 阈值都能被单测直接钉住。

enum ContributorAnalysis {
    /// 视图自己按提交数降序，不依赖上游数组顺序；同分时按显示名升序，保证刷新后榜位不跳。
    static func sorted(_ authors: [AuthorStats]) -> [AuthorStats] {
        authors.sorted {
            if $0.commits != $1.commits { return $0.commits > $1.commits }
            return displayName($0) < displayName($1)
        }
    }

    static func displayName(_ author: AuthorStats) -> String {
        if !author.name.isEmpty { return author.name }
        return author.email.isEmpty ? "未知作者" : author.email
    }

    static func email(_ author: AuthorStats) -> String {
        author.email.isEmpty ? "无邮箱记录" : author.email
    }

    /// 近 30 天有过提交的作者。窗口用 `activeAuthorCount` 的口径读不出来，所以在这算。
    static func recentlyActive(_ authors: [AuthorStats], now: Date = Date()) -> [AuthorStats] {
        authors.filter { author in
            guard let last = author.lastCommitAt else { return false }
            return now.timeIntervalSince(last) <= 30 * 86_400
        }
    }

    /// 头像与占比条的分类色：全 App 唯一一套 `Theme.Chart`，按邮箱稳定哈希取色。
    ///
    /// 必须稳定：Swift 的 `hashValue` 每进程随机化，用它取色会让同一位作者
    /// 每次启动换一种颜色（旧实现正是如此，WS-I §2.1① 点名）。
    static func color(for email: String) -> Color {
        CodeGitCategoryColor.color(for: email)
    }

    /// 与 `GitInsights.busFactorRisk` 同一套阈值，但分母换成**非合并窗口**：
    /// 模型是冻结的，它拿含合并的 `totalCommits` 做分母，仓库越大越低估集中度风险。
    static func busFactorRisk(_ git: GitInsights) -> RiskLevel {
        let base = git.commitScope.authorBasis
        guard let top = git.topAuthor, base > 0 else { return .none }
        let share = Double(top.commits) / Double(base)
        if git.activeAuthorCount <= 1 && base > 50 { return .critical }
        if share > 0.7 { return .high }
        if share > 0.5 { return .medium }
        return .low
    }

    /// 榜首之外不额外给" crown "，排名数字已经承载了顺序信息；这里只负责取前三的色阶语义。
    static func rankRole(_ rank: Int) -> Theme.SemanticRole {
        switch rank {
        case 1: return Theme.Semantic.accent
        case 2...3: return Theme.Semantic.healthy
        default: return Theme.Semantic.neutral
        }
    }

    /// 目录热点：字典无序，按次数降序、目录名升序取前 3。
    static func topDirectories(_ author: AuthorStats, limit: Int = 3) -> [(String, Int)] {
        author.topDirectories
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { ($0.key, $0.value) }
    }
}

// MARK: - 贡献者行

struct ContributorRow: View {
    let author: AuthorStats
    let rank: Int
    let git: GitInsights

    /// 头像边长：24 可点区下限 + 一档间距，与相邻 13pt 正文成比例。
    private static let avatarSide: CGFloat = Theme.Layout.minHitTarget + Theme.Spacing.xxs

    private var tint: Color { ContributorAnalysis.color(for: author.email) }

    private var share: Double? {
        guard let value = git.authorShare(of: author) else { return nil }
        return min(1, max(0, value))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                ContributorAvatar(author: author, tint: tint, side: Self.avatarSide)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text("#\(NumberFormat.grouped(rank))")
                            .font(CodeGitType.number(Theme.Typo.microLabel))
                            .foregroundStyle(ContributorAnalysis.rankRole(rank).textColor)
                        Text(ContributorAnalysis.displayName(author))
                            .font(Theme.Typo.body.font.weight(.semibold))
                            .lineLimit(1)
                    }
                    Text(ContributorAnalysis.email(author))
                        .font(CodeGitType.path)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    ContributorDirectoryChips(author: author)
                }
                Spacer(minLength: Theme.Spacing.sm)
                VStack(alignment: .trailing, spacing: Theme.Spacing.xxs) {
                    Text("\(NumberFormat.grouped(author.commits)) 次")
                        .font(CodeGitType.number(Theme.Typo.metricMid))
                    Text("\(NumberFormat.signed(author.additions)) / \(NumberFormat.signed(-author.deletions))")
                        .font(CodeGitType.number(Theme.Typo.monoSmall))
                        .foregroundStyle(.secondary)
                        .help("代码变更量 \(NumberFormat.grouped(author.totalChurn)) 行 · "
                            + "触达 \(NumberFormat.grouped(author.filesTouched)) 个文件")
                    Text(author.lastActiveDescription)
                        .font(Theme.Typo.microLabel.font)
                        .foregroundStyle(.tertiary)
                }
            }

            HStack(spacing: Theme.Spacing.sm) {
                MiniBarGauge(fraction: share ?? 0, tint: tint, height: 5)
                    .frame(maxWidth: .infinity)
                Text(share.map { NumberFormat.percent($0, precision: 1) }
                     ?? Theme.Placeholder.missingValue)
                    .font(CodeGitType.number(Theme.Typo.microLabel))
                    .foregroundStyle(.secondary)
                    .tableCell(DataColumns.column(DataColumns.shareBar, 1))
                    .help(share == nil
                          ? "报告里没有可用的提交分母，占比无法计算"
                          : "占非合并提交 \(NumberFormat.grouped(git.commitScope.authorBasis)) 次的比例")
            }

            ContributorHourRow(counts: author.activityByHour, tint: tint)
        }
        .padding(.vertical, Theme.Spacing.xxs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("第 \(rank) 位 \(ContributorAnalysis.displayName(author))，"
            + "\(author.commits) 次提交，新增 \(author.additions) 行，删除 \(author.deletions) 行")
    }
}

/// 作者首字母色标。
///
/// 观感换掉了：原来是"分类色实心圆 + 白字 + 白描边"，而 `Theme.Chart` 里深色模式的黄
/// (`#FFD60A`) 上放白字只有约 1.5:1，等于把字母糊掉。现在统一成"同色环形描边 + 同色字母 +
/// 15% 同色底"，与全站徽标同一套语言，深浅两种外观都不需要为每个色值再配一个 onFill。
struct ContributorAvatar: View {
    let author: AuthorStats
    let tint: Color
    var side: CGFloat = Theme.Layout.minHitTarget + Theme.Spacing.xxs

    var body: some View {
        Text(Self.initial(author: author))
            .font(Theme.Typo.cardTitle.font)
            .foregroundStyle(tint)
            .frame(width: side, height: side)
            .background(tint.opacity(Theme.Palette.Opacity.badgeFill), in: Circle())
            .overlay(Circle().strokeBorder(tint, lineWidth: Theme.Stroke.hairline * 2))
            .help("\(ContributorAnalysis.displayName(author)) · \(ContributorAnalysis.email(author))")
    }

    /// 中文取首字、拉丁取首字母大写；空名回退邮箱首字符，最后才是 `?`。
    static func initial(author: AuthorStats) -> String {
        func firstUpper(_ source: String) -> String? {
            let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = trimmed.first else { return nil }
            return String(first).uppercased()
        }
        return firstUpper(author.name) ?? firstUpper(author.email) ?? "?"
    }
}

/// 目录热点胶囊。用设计系统的 `SemanticBadge`（10pt Medium、`Spacing.chip` 内边距、
/// 同色 0.15 底、胶囊），取代原先本文件里手写的 `size: 9 + padding 5/2 + opacity(0.12)`。
struct ContributorDirectoryChips: View {
    let author: AuthorStats

    var body: some View {
        let directories = ContributorAnalysis.topDirectories(author)
        if directories.isEmpty {
            Text("未记录目录")
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: Theme.Spacing.xs) {
                ForEach(Array(directories.enumerated()), id: \.offset) { _, entry in
                    SemanticBadge("\(Self.tail(entry.0)) · \(NumberFormat.grouped(entry.1))",
                                  role: Theme.Semantic.neutral)
                        .help("\(entry.0) · \(entry.1) 次改动")
                }
            }
        }
    }

    static func tail(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// 单成员 24 小时分布，高度按该成员自己的峰值归一。
/// 柱高与间距属图表几何（WS-I §9 豁免），但颜色与空档一律走令牌：
/// 空格子用系统分隔色，不再自造 `Color.primary.opacity(0.06)`。
struct ContributorHourRow: View {
    let counts: [Int]
    let tint: Color

    private static let height: CGFloat = Theme.Layout.minHitTarget
    /// 标签列宽：两个汉字 + 余量。
    private static let labelWidth: CGFloat = Theme.Layout.minHitTarget + Theme.Spacing.xxs

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text("时段")
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
                .frame(width: Self.labelWidth, alignment: .leading)
            HStack(alignment: .bottom, spacing: Theme.Stroke.emphasis) {
                ForEach(0..<24, id: \.self) { hour in
                    bar(for: hour)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("各小时提交分布，峰值 \(peak) 次")
    }

    private var peak: Int { max(1, counts.max() ?? 0) }

    @ViewBuilder
    private func bar(for hour: Int) -> some View {
        let value = hour < counts.count ? counts[hour] : 0
        let ratio = Double(value) / Double(peak)
        RoundedRectangle(cornerRadius: Theme.Radius.none, style: .continuous)
            .fill(value == 0 ? Theme.Palette.Surface.separator
                             : tint.opacity(Theme.Palette.Opacity.gradientMid * (0.4 + ratio)))
            .frame(maxWidth: .infinity)
            .frame(height: value == 0 ? Theme.Stroke.emphasis
                                      : max(Theme.Stroke.emphasis, Self.height * CGFloat(ratio)))
            .help("\(String(format: "%02d", hour)):00 · \(value) 次提交")
    }
}
