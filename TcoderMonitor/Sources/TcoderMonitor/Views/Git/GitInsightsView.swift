import SwiftUI
import Charts

/// OWNER: WS-L —— Git 洞察页。
///
/// 2026-09-19 重样（WS-L）：版面、字号、图标、卡片全部改走 `Design/` 令牌与
/// `Views/CodeGit/` 数据表基座；并修掉一条诚实性缺陷——页头「总提交数」是含合并的仓库真值，
/// 下面作者表求和是不含合并的窗口值，两者从来不同却从没解释过（见 `GitHistoryScope`）。
///
/// 数据只来自 `report?.git`；「没分析过」和「分析过但没有提交」是两种空态，都不渲染成 0。
struct GitInsightsView: View {
    var report: ProjectReport?

    var body: some View {
        DataPageScaffold {
            if let git = report?.git {
                GitRepositorySourceSection(git: git, selectedPath: report?.project.path ?? "")
                GitCommitScopeSection(git: git)
                GitInsightsMetricGrid(git: git)
                GitCommitTrendSection(git: git)
                GitActivitySection(git: git)
                GitRepositoryInfoSection(git: git)
                GitNestedCandidatesSection(git: git)
                GitRecentCommitsSection(git: git)
            } else {
                GitInsightsEmptyState.missingAnalysis
            }
        }
    }
}

// MARK: - 指标条

/// 四枚指标 tile。列数交给自适应断点（WS-H §3.2）：写死 4 列在窄窗口里会把数字挤成两行。
struct GitInsightsMetricGrid: View {
    let git: GitInsights

    private static let columns = [GridItem(.adaptive(minimum: Theme.Layout.tileMinWidth),
                                           spacing: Theme.Spacing.gutter)]

    var body: some View {
        let scope = git.commitScope
        LazyVGrid(columns: Self.columns, spacing: Theme.Spacing.gutter) {
            MetricTile(
                label: "总提交数",
                value: NumberFormat.grouped(git.totalCommits),
                icon: .git,
                unit: "次",
                caption: scope.totalTileCaption,
                tint: Theme.Semantic.accent.textColor
            )
            MetricTile(
                label: "作者统计基准",
                value: scope.nonMergeCommitsAnalysed > 0
                    ? NumberFormat.grouped(scope.authorBasis)
                    : nil,
                symbol: CodeGitSymbol.marker,
                unit: "次",
                caption: Self.authorBasisCaption(scope),
                tint: Theme.Semantic.healthy.textColor
            )
            MetricTile(
                label: scope.isWindowTruncated ? "窗口跨度" : "项目年龄",
                value: git.projectAgeDays > 0 ? NumberFormat.grouped(git.projectAgeDays) : nil,
                symbol: CodeGitSymbol.calendar,
                unit: "天",
                caption: Self.ageCaption(git, scope: scope),
                tint: Theme.Semantic.neutral.textColor
            )
            MetricTile(
                label: "最近修改",
                value: git.lastCommitAt.map { LogRecency.describe($0) },
                symbol: CodeGitSymbol.recency,
                caption: Self.latestCommitCaption(git),
                tint: Theme.Semantic.success.textColor
            )
            MetricTile(
                label: scope.isWindowTruncated ? "窗口内作者" : "活跃作者",
                value: NumberFormat.grouped(git.activeAuthorCount),
                icon: .people,
                unit: "人",
                caption: scope.authorTileCaption(authorCount: git.activeAuthorCount),
                tint: Theme.Semantic.warning.textColor
            )
        }
    }

    /// 第二个 tile 专门承载「48」这个数字：它必须和第一个 tile 的「62」并排出现，
    /// 用户才能自己在屏幕上把账对上，而不是去翻下面的作者表求和。
    static func authorBasisCaption(_ scope: GitHistoryScope) -> String {
        switch scope.basis {
        case .complete(let merges):
            return merges > 0
                ? "已排除 \(NumberFormat.grouped(merges)) 次合并提交"
                : "历史中无合并提交"
        case .windowCapped:
            return "窗口内非合并提交"
        case .unknown:
            return "旧报告未记录该口径"
        }
    }


    static func ageCaption(_ git: GitInsights, scope: GitHistoryScope) -> String {
        guard let first = git.firstCommitAt else { return "首次提交时间未知" }
        let start = DateFormat.dayMonth.string(from: first)
        let suffix = scope.isWindowTruncated ? "（窗口起点）" : ""
        guard let last = git.lastCommitAt else { return "始于 \(start)\(suffix)" }
        return "\(start) → \(DateFormat.dayMonth.string(from: last))\(suffix)"
    }


    static func latestCommitCaption(_ git: GitInsights) -> String {
        guard let latest = git.recentCommits.first else {
            return git.lastCommitAt.map { DateFormat.full.string(from: $0) } ?? "无提交记录"
        }
        return "最新：\(latest.subject)"
    }

}
