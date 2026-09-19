import SwiftUI

// MARK: - Git 洞察页各分区（WS-L）
//
// 从 `GitInsightsView.swift` 拆出来：那个文件已经 500+ 行，再加内容就撞上
// `SelfScanDogfoodTests` 的 800 行棘轮（全仓 ceiling 9，只剩 1 个余量）。
// 拆分优先于加长。

// MARK: - 空态

extension GitDataAbsence {
    /// 数据不在场时的空态视图。三态措辞由 `GitDataAbsence.copy` 决定，
    /// 页面只负责给"数据在场却仍然没有这一份明细"的兜底说法。
    @ViewBuilder func emptyState(fallback: () -> EmptyStateView) -> some View {
        if let copy {
            EmptyStateView(icon: copy.icon, title: copy.title, message: copy.message)
        } else {
            fallback()
        }
    }
}

enum GitInsightsEmptyState {
    static var missingAnalysis: some View {
        EmptyStateView(
            icon: .git,
            title: "尚未分析 Git 历史",
            message: "选择一个本地仓库目录后点击「重新分析」。\n分析完成后这里会显示提交趋势、24×7 活跃分布与最近提交记录。\n"
                + ShellGitAnalyzer.attemptedLocationsText(upward: ShellGitAnalyzer.maxUpwardHops,
                                                         nested: ShellGitAnalyzer.maxNestedDepth)
        )
    }
}

// MARK: - 仓库来源

/// 「分析的是哪个仓、怎么找到的」必须一眼可见：只要定位结果偏离了用户所选目录，
/// 就用提示条说清楚，绝不静默地拿另一个仓库的数字冒充。
struct GitRepositorySourceSection: View {
    let git: GitInsights
    let selectedPath: String

    var body: some View {
        let root = git.resolvedRepositoryRoot ?? ""
        if isRelocated {
            DataNotice(text: "分析的是另一个仓库：\(root)\n\(Self.discoveryCaption(git))",
                       role: git.discoveryMode == .nestedSubdirectory
                           ? Theme.Semantic.warning : Theme.Semantic.info,
                       icon: .riskWarning, iconLabel: "仓库定位偏离")
        } else {
            GlassCard(radius: Theme.Radius.md, padding: Theme.Spacing.md,
                      spacing: Theme.Spacing.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    ThemedIcon(.git, role: .badge)
                        .foregroundStyle(Theme.Semantic.accent.textColor)
                    Text(root.isEmpty ? "来源未记录（旧数据，重新分析后可见）" : root)
                        .font(CodeGitType.path)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: Theme.Spacing.xs)
                    Text(Self.discoveryCaption(git))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                Text(Self.discoveryDetail(git))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var isRelocated: Bool {
        let root = git.resolvedRepositoryRoot ?? ""
        return git.discoveryMode != .selectedDirectory
            || (!root.isEmpty && ShellGitAnalyzer.canonicalPath(root) != ShellGitAnalyzer.canonicalPath(selectedPath))
    }

    static func discoveryCaption(_ git: GitInsights) -> String {
        switch git.discoveryMode {
        case .selectedDirectory: return "所选目录即仓库"
        case .parentDirectory: return "向上 \(NumberFormat.grouped(git.discoveryHops)) 层找到"
        case .nestedSubdirectory: return "向下 \(NumberFormat.grouped(git.discoveryHops)) 层找到"
        case .none: return "未找到仓库"
        }
    }


    /// 把「为什么」和「结果」分开写：用户所选目录在仓库内部还是仓库本身不在这里再重复一遍路径。
    static func discoveryDetail(_ git: GitInsights) -> String {
        switch git.discoveryMode {
        case .selectedDirectory: return "所选目录本身就是仓库根"
        case .parentDirectory: return "所选目录在仓库内部，历史按父仓库统计"
        case .nestedSubdirectory: return "所选目录本身不是仓库，已改用它下面的子仓库"
        case .none: return "该目录下没有可用的 Git 仓库"
        }
    }

}

// MARK: - 提交口径（诚实性修正的落点）

/// 常驻的口径条：把「含合并的真值」和「作者/代码行实际统计的非合并窗口」一次讲清。
///
/// 之前这两套数字在同一屏上并存却从不解释（界面「提交总数 62」vs 作者表求和 48），
/// 用户自己去对账就会发现我们漏了一步。现在它不需要点任何东西就能看到差额的去向。
struct GitCommitScopeSection: View {
    let git: GitInsights

    var body: some View {
        let scope = git.commitScope
        DataNotice(text: Self.message(for: scope),
                   role: scope.isWindowTruncated ? Theme.Semantic.warning : Theme.Semantic.info,
                   icon: scope.isWindowTruncated ? .riskWarning : .info,
                   iconLabel: "提交统计口径")
    }

    static func message(for scope: GitHistoryScope) -> String {
        guard scope.isWindowTruncated else { return scope.headline }
        return scope.headline + "。趋势、时段分布与作者占比都只是这段窗口的分布，不代表全部历史。"
    }

}

// MARK: - 提交趋势

struct GitCommitTrendSection: View {
    let git: GitInsights

    var body: some View {
        if let granularity = git.commitsPerPeriod.first?.granularity {
            GlassSection(
                "提交趋势",
                subtitle: "按 \(gitBucketLabel(granularity)) 分桶 · 共 "
                    + "\(NumberFormat.grouped(git.commitsPerPeriod.count)) 桶\(git.commitScope.windowSuffix)",
                icon: .chartLine
            ) {
                GitTrendReadoutBar(buckets: git.commitsPerPeriod)
                GitCommitTrendChart(buckets: git.commitsPerPeriod, granularity: granularity)
                    .frame(height: Theme.Layout.trendChartHeight)
            }
        } else {
            GlassSection("提交趋势", subtitle: "分桶数据缺席", icon: .chartLine) {
                EmptyStateView(
                    icon: .chartLine,
                    title: "暂无提交趋势",
                    message: "Git 分析没有产出按时间分桶的提交数据，因此这里无法给出峰值或均值。"
                )
            }
        }
    }
}

/// 趋势图上方的读数条（WS-H §2.3 对标 Instruments 的统计读数行）。
/// 只报数，不下结论：均值与峰值都是同一批桶的派生值。
struct GitTrendReadoutBar: View {
    let buckets: [CommitBucket]

    var body: some View {
        DataReadoutBar {
            DataReadout(label: "峰值桶", value: NumberFormat.grouped(summary.peak),
                        caption: summary.unitLabel, role: Theme.Semantic.accent)
            DataReadout(label: "桶均值", value: String(format: "%.1f", summary.average),
                        caption: summary.unitLabel, role: Theme.Semantic.healthy)
            DataReadout(label: "最冷清桶", value: NumberFormat.grouped(summary.lowest),
                        caption: "\(NumberFormat.grouped(summary.emptyBuckets)) 个空桶",
                        role: Theme.Semantic.neutral)
            DataReadout(label: "桶数", value: NumberFormat.grouped(summary.count),
                        caption: summary.spanCaption, role: Theme.Semantic.info)
        }
    }

    /// 读数算不出来时返回全零结构，由调用方决定措辞；这里是纯函数，单测直接钉。
    struct Summary: Equatable {
        let count: Int
        let peak: Int
        let lowest: Int
        let average: Double
        let emptyBuckets: Int
        let unitLabel: String
        let spanCaption: String
    }

    static func summary(of buckets: [CommitBucket]) -> Summary {
        guard let granularity = buckets.first?.granularity else {
            return Summary(count: 0, peak: 0, lowest: 0, average: 0, emptyBuckets: 0,
                           unitLabel: "无分桶", spanCaption: "无分桶")
        }
        let commits = buckets.map(\.commits)
        let unit = "每\(gitBucketLabel(granularity))"
        let first = buckets.first?.date
        let last = buckets.last?.date
        let span = first != nil && last != nil
            ? "\(DateFormat.dayMonth.string(from: first!)) → \(DateFormat.dayMonth.string(from: last!))"
            : "时间区间未知"
        return Summary(
            count: buckets.count,
            peak: commits.max() ?? 0,
            lowest: commits.min() ?? 0,
            average: commits.isEmpty ? 0 : Double(commits.reduce(0, +)) / Double(commits.count),
            emptyBuckets: commits.filter { $0 == 0 }.count,
            unitLabel: unit,
            spanCaption: span
        )
    }

    private var summary: Summary { Self.summary(of: buckets) }
}

// MARK: - 24×7 活跃分布

struct GitActivitySection: View {
    let git: GitInsights

    var body: some View {
        GlassSection(
            "24×7 活跃分布",
            subtitle: "数据源只有边际分布 · 单元格是小时与星期两档归一的近似强度"
                + git.commitScope.windowSuffix,
            icon: .chartLine
        ) {
            if GitActivityHeatmap.hasNoTimestamps(hourCounts: git.activityByHour,
                                                  weekdayCounts: git.activityByWeekday) {
                EmptyStateView(
                    icon: .emptyUnknown,
                    title: "暂无时段分布",
                    message: "提交记录里没有可解析的时间戳，因此无法给出任何时段结论。"
                )
            } else {
                GitActivityHeatmap(hourCounts: git.activityByHour, weekdayCounts: git.activityByWeekday)
                Text(Self.busiestCaption(git))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    static func busiestCaption(_ git: GitInsights) -> String {
        guard let hour = git.busiestHour else { return "小时分布为空，只有星期分布可用" }
        return "最活跃时段：\(hour):00 · 按各作者本地时区合并，未做时区归一"
    }

}

// MARK: - 仓库信息

struct GitRepositoryInfoSection: View {
    let git: GitInsights

    var body: some View {
        GlassSection("仓库信息", subtitle: "分析于 \(LogRecency.describe(git.analyzedAt))", icon: .git) {
            VStack(spacing: DataRowMetrics.rowGap) {
                DataFieldRow(label: "当前分支", value: git.branch.isEmpty ? "未记录" : git.branch,
                             style: .text, valueColor: Theme.Semantic.accent.textColor)
                DataRowSeparator()
                DataFieldRow(label: "HEAD", value: git.headSHA.isEmpty ? "未记录" : git.headSHA,
                             style: .path)
                DataRowSeparator()
                DataFieldRow(label: "远端", value: git.remoteURL.isEmpty ? "未配置" : git.remoteURL,
                             style: .path)
                DataRowSeparator()
                DataReadoutBar {
                    DataReadout(label: "触达文件", value: NumberFormat.grouped(git.filesTouched),
                                caption: "个")
                    DataReadout(label: "新增", value: NumberFormat.signed(git.totalAdditions),
                                caption: "行", role: Theme.Semantic.success)
                    DataReadout(label: "删除", value: NumberFormat.signed(-git.totalDeletions),
                                caption: "行", role: Theme.Semantic.danger)
                    DataReadout(label: "首次提交", value: Self.firstCommitCaption(git),
                                caption: Self.scopeCaption(git))
                }
                .padding(.top, Theme.Spacing.xxs)
            }
        }
    }

    static func firstCommitCaption(_ git: GitInsights) -> String {
        git.firstCommitAt.map { DateFormat.full.string(from: $0) } ?? Theme.Placeholder.missingValue
    }


    /// 「首次提交」在窗口截断时其实是窗口起点，不能让用户读成仓库诞生日。
    static func scopeCaption(_ git: GitInsights) -> String {
        git.commitScope.isWindowTruncated ? "窗口起点，非仓库首次提交" : "仓库首次提交"
    }

}

// MARK: - 所选目录下的其它仓库

/// 所选目录本身不是仓库、下面又躺着好几个仓库时，把全部候选摊开，
/// 并标明当前分析的是哪一个——让用户自己决定要不要单独添加某个。
struct GitNestedCandidatesSection: View {
    let git: GitInsights

    private static let columns: [DataGridColumn] = [
        DataGridColumn("目录"),
        DataGridColumn("提交", 72),
        DataGridColumn("分支", 120),
        DataGridColumn("最近", 96),
    ]

    var body: some View {
        if git.nestedCandidates.count > 1 {
            GlassSection(
                "所选目录下发现 \(NumberFormat.grouped(git.nestedCandidates.count)) 个仓库",
                subtitle: "当前只分析了提交数最多的那一个；要单独分析其中某个，直接把它添加为项目",
                icon: .package
            ) {
                VStack(spacing: DataRowMetrics.rowGap) {
                    DataTableHeader(columns: Self.columns)
                    ForEach(git.nestedCandidates) { candidate in
                        GitNestedCandidateRow(candidate: candidate,
                                              isAnalyzed: candidate.path == git.resolvedRepositoryRoot,
                                              columns: Self.columns)
                    }
                }
            }
        }
    }
}

// MARK: - 最近提交

struct GitRecentCommitsSection: View {
    let git: GitInsights

    static let displayLimit = 20

    var body: some View {
        GlassSection(
            "最近提交",
            subtitle: git.recentCommits.isEmpty
                ? "无提交记录"
                : "显示 \(NumberFormat.grouped(min(Self.displayLimit, git.recentCommits.count))) / "
                    + "\(NumberFormat.grouped(git.recentCommits.count)) 条",
            icon: .processes
        ) {
            if git.recentCommits.isEmpty {
                git.commitAbsence.emptyState {
                    EmptyStateView(
                        icon: .unverified,
                        title: "本次没有取回最近提交明细",
                        message: "历史里有提交，但提交记录本身没有带回任何一行（旧报告或分析中断都会这样）。\n"
                            + "趋势与作者统计仍按已解析的部分给出，这里只说明明细缺失。"
                    )
                }
            } else {
                VStack(spacing: DataRowMetrics.rowGap) {
                    DataTableHeader(columns: DataColumns.recentCommits)
                    let rows = Array(git.recentCommits.prefix(Self.displayLimit))
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, commit in
                        GitCommitRow(commit: commit)
                        if index < rows.count - 1 {
                            DataRowSeparator()
                        }
                    }
                }
            }
        }
    }
}
