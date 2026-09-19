import SwiftUI
import Charts

/// OWNER: WS-B / 子代理5 —— Git 洞察页。
/// 所有数据来自 `report?.git`；没有数据时显示空状态，绝不把「未分析」渲染成 0。
struct GitInsightsView: View {
    var report: ProjectReport?

    private static let metricColumns = Array(repeating: GridItem(.flexible(), spacing: 12), count: 4)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let git = report?.git {
                    repositorySourceSection(git)
                    truncationSection(git)
                    metricGrid(git)
                    trendSection(git)
                    activitySection(git)
                    repositorySection(git)
                    nestedCandidatesSection(git)
                    recentCommitsSection(git)
                } else {
                    EmptyStateView(
                        icon: "arrow.triangle.branch",
                        title: "尚未分析 Git 历史",
                        message: "选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示提交趋势、24×7 活跃分布与最近提交记录。\n\(ShellGitAnalyzer.attemptedLocationsText(upward: ShellGitAnalyzer.maxUpwardHops, nested: ShellGitAnalyzer.maxNestedDepth))。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 280)
                }
            }
            .padding(16)
        }
        .scrollContentBackground(.hidden)
    }

    // MARK: - Where this repository came from

    /// 「分析的是哪个仓、怎么找到的」必须一眼可见：只要定位结果偏离了用户所选目录，
    /// 就用横幅说清楚，绝不静默地拿另一个仓库的数字冒充。
    private func repositorySourceSection(_ git: GitInsights) -> some View {
        let root = git.resolvedRepositoryRoot ?? ""
        let selected = report?.project.path ?? ""
        let relocated = git.discoveryMode != .selectedDirectory
            || (!root.isEmpty && ShellGitAnalyzer.canonicalPath(root) != ShellGitAnalyzer.canonicalPath(selected))
        return Group {
            if relocated {
                BannerRow(text: "Git 仓库：\(root) · \(discoveryCaption(git))",
                          style: git.discoveryMode == .nestedSubdirectory ? .warning : .info)
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                    Text("Git 仓库：\(root.isEmpty ? "来源未记录（旧数据，重新分析后可见）" : root)")
                        .font(Theme.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("· \(discoveryCaption(git))")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func discoveryCaption(_ git: GitInsights) -> String {
        switch git.discoveryMode {
        case .selectedDirectory: return "所选目录即仓库"
        case .parentDirectory: return "向上 \(git.discoveryHops) 层找到（所选目录在仓库内部）"
        case .nestedSubdirectory: return "向下 \(git.discoveryHops) 层找到（所选目录本身不是仓库）"
        case .none: return "未找到仓库"
        }
    }

    /// 窗口没盖住全部历史时，先声明清楚再给数字：否则用户会把「最近 2 万条」当成全量人均分布。
    @ViewBuilder
    private func truncationSection(_ git: GitInsights) -> some View {
        if git.historyTruncated {
            BannerRow(text: "提交统计只覆盖最近 \(NumberFormat.grouped(git.commitsAnalyzed)) 条非合并提交"
                + "（仓库共 \(NumberFormat.grouped(git.totalCommits)) 条，含合并）。"
                + "下面的提交趋势、活跃时段与作者占比都只是这段窗口的分布，不代表全部历史。",
                      style: .warning)
        }
    }

    private func windowSuffix(_ git: GitInsights) -> String {
        git.historyTruncated ? " · 仅覆盖已分析的 \(NumberFormat.grouped(git.commitsAnalyzed)) 条" : ""
    }

    // MARK: - Top metrics

    private func metricGrid(_ git: GitInsights) -> some View {
        LazyVGrid(columns: Self.metricColumns, spacing: 12) {
            MetricTile(
                label: "总提交数",
                value: NumberFormat.grouped(git.totalCommits),
                unit: "次",
                caption: commitsCaption(git),
                tint: Theme.accent,
                systemImage: "arrow.triangle.branch"
            )
            MetricTile(
                label: git.historyTruncated ? "窗口跨度" : "项目年龄",
                value: NumberFormat.grouped(git.projectAgeDays),
                unit: "天",
                caption: ageCaption(git),
                tint: Theme.neutral,
                systemImage: "calendar"
            )
            MetricTile(
                label: "最近修改",
                value: LogRecency.describe(git.lastCommitAt),
                caption: latestCommitCaption(git),
                tint: Theme.healthy,
                systemImage: "clock.arrow.circlepath"
            )
            MetricTile(
                label: git.historyTruncated ? "窗口内作者" : "活跃作者",
                value: NumberFormat.grouped(git.activeAuthorCount),
                unit: "人",
                caption: topAuthorCaption(git),
                tint: Theme.caution,
                systemImage: "person.2.fill"
            )
        }
    }

    /// 被截断时，「总提交数」是真值、其余统计只是窗口，两者不能混为一谈。
    private func commitsCaption(_ git: GitInsights) -> String {
        if git.historyTruncated {
            let share = git.totalCommits > 0
                ? NumberFormat.percent(Double(git.commitsAnalyzed) / Double(git.totalCommits), precision: 0)
                : "0%"
            return "已分析最近 \(NumberFormat.grouped(git.commitsAnalyzed)) 条（占全部 \(share)）· 窗口内日均 \(String(format: "%.2f", windowCommitsPerDay(git))) 次"
        }
        return "日均 \(String(format: "%.2f", git.commitsPerDay)) 次 · 项目 \(NumberFormat.grouped(git.projectAgeDays)) 天"
    }

    /// 只按已分析窗口算日均：`GitInsights.commitsPerDay` 拿「含 merge 的真值总数 ÷ 窗口跨度」，
    /// 截断时会虚高一个量级，所以这里必须自己算。
    private func windowCommitsPerDay(_ git: GitInsights) -> Double {
        guard let first = git.firstCommitAt, let last = git.lastCommitAt else { return 0 }
        let days = max(1, Int(last.timeIntervalSince(first) / 86_400))
        return Double(git.commitsAnalyzed) / Double(days)
    }

    private func ageCaption(_ git: GitInsights) -> String {
        guard let first = git.firstCommitAt else { return "首次提交时间未知" }
        let start = DateFormat.dayMonth.string(from: first)
        let suffix = git.historyTruncated ? "（窗口起点，非仓库首次提交）" : ""
        guard let last = git.lastCommitAt else { return "首次提交 \(start)\(suffix)" }
        return "\(start) → \(DateFormat.dayMonth.string(from: last))\(suffix)"
    }

    private func latestCommitCaption(_ git: GitInsights) -> String {
        guard let latest = git.recentCommits.first else {
            return git.lastCommitAt.map { DateFormat.full.string(from: $0) } ?? "无提交记录"
        }
        return "最新：\(latest.subject)"
    }

    private func topAuthorCaption(_ git: GitInsights) -> String {
        // 分母必须同样是窗口口径，否则截断时会把人均占比压到失真。
        guard let top = git.topAuthor, git.commitsAnalyzed > 0 else { return "暂无作者统计" }
        let share = Double(top.commits) / Double(git.commitsAnalyzed)
        let scope = git.historyTruncated ? "窗口内" : "Top"
        return "\(scope): \(top.name) \(NumberFormat.percent(share, precision: 0))"
    }

    // MARK: - Commit trend

    @ViewBuilder
    private func trendSection(_ git: GitInsights) -> some View {
        if let granularity = git.commitsPerPeriod.first?.granularity {
            // Buckets produced by one analysis always share a granularity.
            SectionCard(
                "提交趋势",
                subtitle: "按 \(gitBucketLabel(granularity)) 分桶 · 共 \(git.commitsPerPeriod.count) 桶\(windowSuffix(git))",
                icon: "chart.bar.xaxis"
            ) {
                GitCommitTrendChart(buckets: git.commitsPerPeriod, granularity: granularity)
                    .frame(height: 150)
            }
        } else {
            SectionCard("提交趋势", subtitle: "无分桶数据", icon: "chart.bar.xaxis") {
                EmptyStateView(
                    icon: "chart.bar",
                    title: "暂无提交趋势",
                    message: "Git 分析没有产出按时间分桶的提交数据。"
                )
            }
        }
    }

    // MARK: - 24x7 activity

    @ViewBuilder
    private func activitySection(_ git: GitInsights) -> some View {
        SectionCard(
            "24×7 活跃分布",
            subtitle: "按小时 × 星期的近似强度（数据源只有边际分布）\(windowSuffix(git))",
            icon: "circle.grid.square"
        ) {
            if git.activityByHour.allSatisfy({ $0 == 0 }) && git.activityByWeekday.allSatisfy({ $0 == 0 }) {
                EmptyStateView(
                    icon: "clock",
                    title: "暂无时段分布",
                    message: "提交记录里没有可解析的时间戳。"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    GitActivityHeatmap(hourCounts: git.activityByHour, weekdayCounts: git.activityByWeekday)
                    Text("最活跃时段：\(git.busiestHour.map { "\($0) 时" } ?? "无小时数据") · 本机作者本地时区合并")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Repository meta

    private func repositorySection(_ git: GitInsights) -> some View {
        SectionCard(
            "仓库信息",
            subtitle: "分析于 \(LogRecency.describe(git.analyzedAt))",
            icon: "folder"
        ) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 14) {
                    StatLine(label: "分支", value: git.branch.isEmpty ? "未记录" : git.branch)
                    StatLine(label: "HEAD", value: git.headSHA.isEmpty ? "未记录" : git.headSHA)
                    Spacer(minLength: 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("远端")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text(git.remoteURL.isEmpty ? "未配置" : git.remoteURL)
                        .font(Theme.monoSmall)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    StatLine(label: "触达文件", value: NumberFormat.grouped(git.filesTouched))
                    StatLine(label: "新增", value: NumberFormat.signed(git.totalAdditions))
                    StatLine(label: "删除", value: NumberFormat.signed(-git.totalDeletions))
                    Spacer(minLength: 0)
                }
                HStack(spacing: 14) {
                    StatLine(label: "分析时刻", value: DateFormat.full.string(from: git.analyzedAt))
                    StatLine(label: "首次提交", value: git.firstCommitAt.map { DateFormat.full.string(from: $0) } ?? "未知")
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Nested repositories found underneath

    /// 所选目录本身不是仓库、下面又躺着好几个仓库时，把全部候选摊开给用户看，
    /// 并说明当前分析的是哪一个 —— 让他自己决定要不要单独添加某个。
    @ViewBuilder
    private func nestedCandidatesSection(_ git: GitInsights) -> some View {
        if git.nestedCandidates.count > 1 {
            SectionCard(
                "所选目录下发现 \(git.nestedCandidates.count) 个仓库",
                subtitle: "当前只分析了提交数最多的那一个；如需单独分析其中某个，直接把它添加为项目",
                icon: "square.stack.3d.down.right"
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(git.nestedCandidates) { candidate in
                        GitNestedCandidateRow(candidate: candidate,
                                              isAnalyzed: candidate.path == git.resolvedRepositoryRoot)
                        if candidate.id != git.nestedCandidates.last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Recent commits

    private func recentCommitsSection(_ git: GitInsights) -> some View {
        SectionCard(
            "最近提交",
            subtitle: git.recentCommits.isEmpty
                ? "无提交记录"
                : "显示 \(min(20, git.recentCommits.count)) / \(NumberFormat.grouped(git.recentCommits.count)) 条",
            icon: "list.bullet.rectangle"
        ) {
            if git.recentCommits.isEmpty {
                EmptyStateView(
                    icon: "arrow.triangle.branch",
                    title: "无提交记录",
                    message: "该仓库没有任何可读取的提交，或 Git 分析被跳过。"
                )
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(git.recentCommits.prefix(20)) { commit in
                        GitCommitRow(commit: commit)
                        if commit.id != git.recentCommits.prefix(20).last?.id {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - File private building blocks

private func gitBucketLabel(_ granularity: BucketGranularity) -> String {
    switch granularity {
    case .day: return "日"
    case .week: return "周"
    case .month: return "月"
    }
}

private struct GitCommitRow: View {
    var commit: CommitRecord

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(String(commit.sha.prefix(7)))
                .font(Theme.monoSmall)
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 1) {
                Text(commit.subject).font(.caption).lineLimit(1)
                Text("\(commit.author) · \(LogRecency.describe(commit.date)) · \(NumberFormat.grouped(commit.filesChanged)) 文件")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(NumberFormat.signed(commit.additions))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.healthy)
                Text(NumberFormat.signed(-commit.deletions))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.danger)
            }
        }
    }
}

/// 一个「藏在所选目录下面」的候选仓库。
private struct GitNestedCandidateRow: View {
    var candidate: NestedRepositoryCandidate
    var isAnalyzed: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: isAnalyzed ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isAnalyzed ? Theme.accent : Theme.neutral)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(candidate.directoryName).font(.caption).lineLimit(1)
                    if isAnalyzed {
                        Text("当前分析对象")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                }
                Text(candidate.path)
                    .font(Theme.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text("\(NumberFormat.grouped(candidate.commitCount)) 次提交")
                    .font(.system(size: 10, design: .monospaced))
                Text("\(candidate.branch.isEmpty ? "无分支" : candidate.branch) · \(candidate.lastCommitAt.map { LogRecency.describe($0) } ?? "无提交")")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
    }
}

/// Commit trend bars. `unit` and the axis label format both follow the bucket granularity,
/// because a `CommitBucket.date` is only meaningful at the granularity it was built with.
private struct GitCommitTrendChart: View {
    let buckets: [CommitBucket]
    let granularity: BucketGranularity

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("时间", bucket.date, unit: calendarUnit),
                y: .value("提交", bucket.commits)
            )
            .foregroundStyle(Theme.accent)
            .cornerRadius(1.5)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel(format: axisFormat, centered: false)
                    .font(.system(size: 8))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.gridLine)
                AxisValueLabel().font(.system(size: 8))
            }
        }
    }

    private var calendarUnit: Calendar.Component {
        switch granularity {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    private var axisFormat: Date.FormatStyle {
        // A fixed POSIX locale keeps the tick labels numeric ("3/5", "2024/3") regardless
        // of the user's Chinese system locale.
        let locale = Locale(identifier: "en_US_POSIX")
        switch granularity {
        case .day, .week:
            return .dateTime.locale(locale).month(.defaultDigits).day()
        case .month:
            return .dateTime.locale(locale).year().month(.defaultDigits)
        }
    }
}

/// 7 rows (Monday first) x 24 columns. `GitInsights` only stores the *marginal* hour and
/// weekday histograms, so a true per-(weekday, hour) cell count is impossible: the cell
/// strength is the average of both normalized marginals and is labelled as an approximation.
private struct GitActivityHeatmap: View {
    let hourCounts: [Int]
    let weekdayCounts: [Int]

    private static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]

    var body: some View {
        VStack(spacing: 3) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: 3) {
                    Text(Self.weekdayLabel(weekday))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let strength = intensity(hour: hour, weekday: weekday)
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(Theme.accent.opacity(0.08 + 0.85 * strength))
                            .frame(maxWidth: .infinity, minHeight: 11)
                            .help("\(Self.weekdayLabel(weekday)) \(hour):00 — 近似强度 \(Int((strength * 100).rounded()))%")
                    }
                }
            }
            HStack(spacing: 3) {
                Color.clear.frame(width: 30, height: 1)
                ForEach(0..<24, id: \.self) { hour in
                    Text([0, 6, 12, 18].contains(hour) ? "\(hour)" : "")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }

    private static func weekdayLabel(_ index: Int) -> String {
        weekdayNames[index]
    }

    private var maxHour: Int { hourCounts.max() ?? 0 }
    private var maxWeekday: Int { weekdayCounts.max() ?? 0 }

    private func value(_ array: [Int], _ index: Int) -> Int {
        array.indices.contains(index) ? array[index] : 0
    }

    private func intensity(hour: Int, weekday: Int) -> Double {
        let hourShare = maxHour > 0 ? Double(value(hourCounts, hour)) / Double(maxHour) : 0
        let weekdayShare = maxWeekday > 0 ? Double(value(weekdayCounts, weekday)) / Double(maxWeekday) : 0
        return min(1, max(0, (hourShare + weekdayShare) / 2))
    }
}
