import SwiftUI

/// OWNER: WS-B / 子代理4 —— Git 贡献者页。
/// 全部数据来自 `report?.git`；未分析与「真没有作者」是两种空状态，不渲染 0。
struct ContributorsView: View {
    var report: ProjectReport?

    private static let displayLimit = 30
    private static let metricColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let git = report?.git {
                    if git.authors.isEmpty {
                        EmptyStateView(
                            icon: "person.2.fill",
                            title: "该仓库暂无贡献者数据",
                            message: "仓库可能是空仓库，或历史里只有不带作者信息的合并提交。\n提交一次普通改动后重新分析即可看到排行。"
                        )
                        .frame(maxWidth: .infinity, minHeight: 280)
                    } else {
                        let authors = sortedAuthors(git)
                        BusFactorBanner(git: git)
                        metricGrid(git, authors: authors)
                        rankingCard(git, authors: authors)
                        concentrationCard(git, authors: authors)
                    }
                } else {
                    EmptyStateView(
                        icon: "person.2.fill",
                        title: "尚未分析 Git 历史",
                        message: "选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示贡献者排行、代码变更量与活跃时段分布。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    /// 视图自己按提交数排序，不依赖上游数组顺序。
    private func sortedAuthors(_ git: GitInsights) -> [AuthorStats] {
        git.authors.sorted {
            if $0.commits != $1.commits { return $0.commits > $1.commits }
            return displayName($0) < displayName($1)
        }
    }

    // MARK: - Summary tiles

    private func metricGrid(_ git: GitInsights, authors: [AuthorStats]) -> some View {
        LazyVGrid(columns: Self.metricColumns, spacing: 12) {
            MetricTile(
                label: "贡献者",
                value: NumberFormat.grouped(authors.count),
                unit: "人",
                caption: git.historyTruncated
                    ? "活跃 \(NumberFormat.grouped(git.activeAuthorCount)) 人 · 已分析 \(NumberFormat.grouped(git.commitsAnalyzed)) / \(NumberFormat.grouped(git.totalCommits)) 次提交"
                    : "活跃 \(NumberFormat.grouped(git.activeAuthorCount)) 人 · 共 \(NumberFormat.grouped(git.totalCommits)) 次提交",
                tint: Theme.accent,
                systemImage: "person.2.fill"
            )
            MetricTile(
                label: "头部作者占比",
                value: topShare(git).map { NumberFormat.percent($0, precision: 0) } ?? "—",
                caption: git.topAuthor.map { "\(displayName($0)) · \(NumberFormat.grouped($0.commits)) 次" } ?? "无作者数据",
                tint: Theme.color(for: gitBusFactorRisk(git)),
                systemImage: "crown.fill"
            )
            MetricTile(
                label: "累计变更",
                value: NumberFormat.compact(git.totalAdditions + git.totalDeletions),
                unit: "行",
                caption: "\(NumberFormat.signed(git.totalAdditions)) / \(NumberFormat.signed(-git.totalDeletions))",
                tint: Theme.neutral,
                systemImage: "arrow.up.arrow.down"
            )
            MetricTile(
                label: "近 30 天活跃",
                value: NumberFormat.grouped(recentlyActive(authors).count),
                unit: "人",
                caption: recentlyActiveCaption(authors),
                tint: Theme.healthy,
                systemImage: "clock.arrow.circlepath"
            )
        }
    }

    private func topShare(_ git: GitInsights) -> Double? {
        let base = gitShareBase(git)
        guard let top = git.topAuthor, base > 0 else { return nil }
        return Double(top.commits) / Double(base)
    }

    private func recentlyActive(_ authors: [AuthorStats]) -> [AuthorStats] {
        authors.filter { author in
            guard let last = author.lastCommitAt else { return false }
            return Date().timeIntervalSince(last) <= 30 * 86_400
        }
    }

    private func recentlyActiveCaption(_ authors: [AuthorStats]) -> String {
        let recent = recentlyActive(authors)
        guard let best = recent.max(by: { ($0.lastCommitAt ?? .distantPast) < ($1.lastCommitAt ?? .distantPast) }) else {
            return "近 30 天无人提交"
        }
        return "最近：\(displayName(best)) · \(best.lastActiveDescription)"
    }

    // MARK: - Ranking

    private func rankingCard(_ git: GitInsights, authors: [AuthorStats]) -> some View {
        let shown = Array(authors.prefix(Self.displayLimit))
        return SectionCard(
            "贡献者排行",
            subtitle: "按提交数降序 · 展示 \(shown.count) / \(NumberFormat.grouped(authors.count)) 人",
            icon: "person.text.rectangle"
        ) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, author in
                    ContributorRow(author: author, rank: index + 1, totalCommits: gitShareBase(git))
                    if index < shown.count - 1 {
                        Divider().opacity(0.4)
                    }
                }
                if authors.count > Self.displayLimit {
                    Text("其他 \(NumberFormat.grouped(authors.count - Self.displayLimit)) 位贡献者未展示")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 2)
                }
            }
        }
    }

    // MARK: - Concentration

    private func concentrationCard(_ git: GitInsights, authors: [AuthorStats]) -> some View {
        let top = Array(authors.prefix(3))
        let total = max(1, gitShareBase(git))
        let topCommits = top.reduce(0) { $0 + $1.commits }
        return SectionCard(
            "贡献集中度",
            subtitle: "Bus Factor \(max(1, top.count)) · 前 3 名合计 \(NumberFormat.percent(Double(topCommits) / Double(total), precision: 0))",
            icon: "chart.pie.fill"
        ) {
            VStack(alignment: .leading, spacing: 9) {
                ShareBarRow(
                    label: "前 3 名合计",
                    detail: "\(NumberFormat.grouped(topCommits)) 次",
                    fraction: Double(topCommits) / Double(total),
                    tint: Theme.accent
                )
                ForEach(top) { author in
                    ShareBarRow(
                        label: displayName(author),
                        detail: "\(NumberFormat.grouped(author.commits)) 次",
                        fraction: Double(author.commits) / Double(total),
                        tint: contributorColor(for: author.email)
                    )
                }
                if git.activeAuthorCount <= 1 {
                    BannerRow(text: "全部提交仅来自 1 位贡献者，任何离队都会让项目停摆。", style: .error)
                } else if gitBusFactorRisk(git) >= .high {
                    BannerRow(
                        text: "其余 \(NumberFormat.grouped(git.activeAuthorCount - 1)) 位作者合计不足 \(NumberFormat.percent(1 - Double(top.first?.commits ?? 0) / Double(total), precision: 0))，缺少可接手的第二人。",
                        style: .warning
                    )
                }
            }
        }
    }
}

// MARK: - Bus factor banner

private struct BusFactorBanner: View {
    let git: GitInsights

    var body: some View {
        BannerRow(text: message, style: style)
    }

    private var risk: RiskLevel { gitBusFactorRisk(git) }

    private var style: BannerStyle {
        switch risk {
        case .critical, .high: return .error
        case .medium: return .warning
        default: return .info
        }
    }

    private var message: String {
        guard let top = git.topAuthor, gitShareBase(git) > 0 else {
            return "尚无提交作者统计，无法评估 Bus Factor。"
        }
        let share = NumberFormat.percent(Double(top.commits) / Double(gitShareBase(git)), precision: 0)
        let name = displayName(top)
        switch risk {
        case .critical:
            return "100% 依赖单人：\(share) 的提交来自 \(name)，活跃作者仅 \(git.activeAuthorCount) 人，属于严重单点风险。"
        case .high:
            return "\(share) 的提交由 \(name) 一人完成，存在单点风险。"
        case .medium:
            return "\(share) 的提交来自 \(name)，建议安排代码评审与交接。"
        default:
            return "贡献分布健康：\(git.activeAuthorCount) 位活跃作者，最高占比 \(share)（\(name)）。"
        }
    }
}

// MARK: - Contributor row

private struct ContributorRow: View {
    let author: AuthorStats
    let rank: Int
    let totalCommits: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                AvatarBadge(author: author, tint: tint)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 5) {
                        Text("#\(rank)")
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .foregroundStyle(.tertiary)
                        Text(title).font(.callout.weight(.semibold)).lineLimit(1)
                    }
                    Text(subtitle)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    DirectoryChips(directories: topDirectories(author))
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(NumberFormat.grouped(author.commits)) 次")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    Text("\(NumberFormat.signed(author.additions)) / \(NumberFormat.signed(-author.deletions))")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .help("代码变更量 \(NumberFormat.grouped(author.totalChurn)) 行 · 触达 \(NumberFormat.grouped(author.filesTouched)) 个文件")
                    Text(author.lastActiveDescription)
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }
            HStack(spacing: 8) {
                MiniBarGauge(fraction: share, tint: tint, height: 5)
                    .frame(maxWidth: .infinity)
                Text(NumberFormat.percent(share, precision: 1))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 46, alignment: .trailing)
            }
            HourActivityRow(counts: author.activityByHour, tint: tint)
        }
        .padding(.vertical, 2)
    }

    private var tint: Color { contributorColor(for: author.email) }

    private var share: Double {
        totalCommits > 0 ? Double(author.commits) / Double(totalCommits) : 0
    }

    private var title: String { displayName(author) }

    private var subtitle: String {
        author.email.isEmpty ? "无邮箱记录" : author.email
    }

    /// 字典无序：按次数降序、目录名升序，取前 3 个。
    private func topDirectories(_ author: AuthorStats) -> [(String, Int)] {
        author.topDirectories
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(3)
            .map { ($0.key, $0.value) }
    }
}

private struct AvatarBadge: View {
    let author: AuthorStats
    let tint: Color

    var body: some View {
        Text(initial)
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint, in: Circle())
            .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .help("\(author.name.isEmpty ? "未知作者" : author.name) · \(author.email.isEmpty ? "无邮箱" : author.email)")
    }

    /// 中文取第一个字，拉丁文取首字母大写；空名回退到邮箱首字符。
    private var initial: String {
        let name = author.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = name.first { return String(first).uppercased() }
        let email = author.email.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = email.first { return String(first).uppercased() }
        return "?"
    }
}

private struct DirectoryChips: View {
    let directories: [(String, Int)]

    var body: some View {
        if directories.isEmpty {
            EmptyView()
        } else {
            HStack(spacing: 4) {
                ForEach(Array(directories.enumerated()), id: \.offset) { _, entry in
                    Text("\(short(entry.0)) · \(NumberFormat.grouped(entry.1))")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Theme.neutral)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Theme.neutral.opacity(0.12), in: Capsule())
                        .help("\(entry.0) · \(entry.1) 次改动")
                }
            }
        }
    }

    private func short(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

/// 单成员 24 小时提交分布；高度按该成员自己的峰值归一。
private struct HourActivityRow: View {
    let counts: [Int]
    let tint: Color

    private static let height: CGFloat = 16

    var body: some View {
        HStack(spacing: 6) {
            Text("时段")
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
                .frame(width: 22, alignment: .leading)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(0..<24, id: \.self) { hour in
                    bar(for: hour)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: Self.height)
    }

    private var peak: Int { max(1, counts.max() ?? 0) }

    @ViewBuilder
    private func bar(for hour: Int) -> some View {
        let value = hour < counts.count ? counts[hour] : 0
        let ratio = Double(value) / Double(peak)
        RoundedRectangle(cornerRadius: 1, style: .continuous)
            .fill(value == 0 ? Color.primary.opacity(0.06) : tint.opacity(0.35 + 0.65 * ratio))
            .frame(maxWidth: .infinity)
            .frame(height: value == 0 ? 2 : max(3, Self.height * CGFloat(ratio)))
            .help("\(String(format: "%02d", hour)):00 · \(value) 次提交")
    }
}

private struct ShareBarRow: View {
    let label: String
    let detail: String
    let fraction: Double
    let tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.caption)
                .lineLimit(1)
                .frame(width: 96, alignment: .leading)
            MiniBarGauge(fraction: fraction, tint: tint, height: 6)
                .frame(maxWidth: .infinity)
            Text(NumberFormat.percent(fraction, precision: 0))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 58, alignment: .trailing)
        }
    }
}

// MARK: - Stable avatar colors

private let contributorPalette: [Color] = [
    Color(hex: "5C8DFF"), Color(hex: "2FA84F"), Color(hex: "E8A33D"), Color(hex: "D9534F"),
    Color(hex: "8E6FD8"), Color(hex: "1FA8B8"), Color(hex: "C2589B"), Color(hex: "6F7C91"),
]

/// 必须跨启动稳定，所以用 FNV-1a；Swift 的 hashValue 每个进程随机化。
private func contributorColor(for email: String) -> Color {
    var hash: UInt64 = 0xcbf2_9ce4_8422_2325
    for scalar in email.lowercased().unicodeScalars {
        hash ^= UInt64(scalar.value)
        hash = hash &* 0x0000_0100_0000_01B3
    }
    return contributorPalette[Int(hash % UInt64(contributorPalette.count))]
}

private func displayName(_ author: AuthorStats) -> String {
    if !author.name.isEmpty { return author.name }
    return author.email.isEmpty ? "未知作者" : author.email
}

/// 占比的分母必须和分子同口径：`totalCommits` 是**含 merge 的仓库真值**，而
/// `AuthorStats.commits` 只数到分析窗口里的非合并提交。历史被截断时两者相除会把
/// 人均占比压到失真（50,666 条的仓里，窗口内的头号作者会被显示成 6%），
/// 所以一律退回 `commitsAnalyzed`；旧数据没有该字段时（=0）才用 totalCommits 兜底。
private func gitShareBase(_ git: GitInsights) -> Int {
    git.commitsAnalyzed > 0 ? git.commitsAnalyzed : git.totalCommits
}

/// 与 `GitInsights.busFactorRisk` 同一套阈值，但分母换成窗口口径 —— 模型是冻结的，
/// 它用 totalCommits 做分母，截断时会系统性低估集中度风险。
private func gitBusFactorRisk(_ git: GitInsights) -> RiskLevel {
    let base = gitShareBase(git)
    guard let top = git.topAuthor, base > 0 else { return .none }
    let share = Double(top.commits) / Double(base)
    if git.activeAuthorCount <= 1 && base > 50 { return .critical }
    if share > 0.7 { return .high }
    if share > 0.5 { return .medium }
    return .low
}
