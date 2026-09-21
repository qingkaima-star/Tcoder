import SwiftUI
import Charts

/// OWNER: WS-L / WS-P —— Git 洞察页。
///
/// 2026-09-20 无界化（WS-P，本轮）。这一页是五页里最挤的：8 个顶层分区平铺、
/// 5 枚各自一色的 tile、2 层灰盒、12 处 `.tertiary`。改动：
/// - **主角 = 总提交数**（纯数字 56pt 纯墨），它的 `note` 槽就是那句 merge 口径
///   `scope.totalTileCaption`。**口径句子一字未改，只是从 tile 的说明位升到了主角旁边**
///   ——「共 62 次提交」与「作者统计基于 48 次非合并提交」必须在同一屏上并排，
///   用户才不需要自己去对账（这是 WS-L 背的那条功能性诚实修正，不是装饰）。
/// - 5 枚 tile → 一条 `ReadoutStrip`（列间 `DataBandSeparator`），**全部显式 `tint:` 删除**，
///   回到纯墨。它们的 `caption`（含 `authorBasisCaption` 的四种口径分支）全部原文保留。
/// - 8 个分区收成 3 个段落（段落 40 / 分组 32 / 组内 16）。
/// - 所有 `DataReadoutBar` 出井、所有表格进井、`.tertiary` 归零。
///
/// 数据只来自 `report?.git`；「没分析过」和「分析过但没有提交」是两种空态，都不渲染成 0。
struct GitInsightsView: View {
    var report: ProjectReport?

    var body: some View {
        Theme.Page.Scaffold {
            Theme.Page.Header(title: "Git 洞察", icon: .git)
            if let git = report?.git {
                GroupStack {
                    GitRepositorySourceSection(git: git, selectedPath: report?.project.path ?? "")
                    GitCommitScopeSection(git: git)
                    GitInsightsMetricGrid(git: git)
                }
                GroupStack {
                    GitCommitTrendSection(git: git)
                    GitActivitySection(git: git)
                }
                GroupStack {
                    GitRepositoryInfoSection(git: git)
                    GitNestedCandidatesSection(git: git)
                    GitRecentCommitsSection(git: git)
                }
            } else {
                GitInsightsEmptyState.missingAnalysis
            }
        }
    }
}

// MARK: - 指标条

/// 主角读数 + 四条辅助读数。**无面**：旧形态是 `LazyVGrid` 里五块 `.contentInset`
/// 灰盒，每块自带一份投影，且五枚各涂一色（accent / healthy / neutral / success / warning），
/// 于是「提交数」和「活跃作者」看起来像两个不同性质的结论 —— 它们都只是测得值。
///
/// 列数交给 `ReadoutStrip` 的横向排布；窄窗口下 tile 会各自换行而不是挤成两行数字。
struct GitInsightsMetricGrid: View {
    let git: GitInsights

    var body: some View {
        let scope = git.commitScope
        // 「以下均为测得值，口径见上方口径条」整句进 ⓘ（盘点表 D1 判「藏」）：
        // 它是**指向另一处文案的指路句**，不改变任何数字的读法，屏上没必要占一行。
        // 落点在 `GlassSection` 标题行的 `trailing:` 槽 —— 分组副标题槽没有 `help:`，
        // 而这一句没有可留的短半句（留了就是把同一件事说两遍）。
        GlassSection("提交规模",
                     icon: .git,
                     trailing: AnyView(CopyHelpBadge("以下均为测得值，口径见上方口径条"))) {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                DataHeroReadout(value: NumberFormat.grouped(git.totalCommits),
                                unit: "次",
                                note: scope.totalTileCaption)

                ReadoutStrip {
                    MetricTile(
                        label: "作者统计基准",
                        value: scope.nonMergeCommitsAnalysed > 0
                            ? NumberFormat.grouped(scope.authorBasis)
                            : nil,
                        symbol: CodeGitSymbol.marker,
                        unit: "次",
                        caption: Self.authorBasisCaption(scope)
                    )
                    DataBandSeparator()
                    MetricTile(
                        label: scope.isWindowTruncated ? "窗口跨度" : "项目年龄",
                        value: git.projectAgeDays > 0 ? NumberFormat.grouped(git.projectAgeDays) : nil,
                        symbol: CodeGitSymbol.calendar,
                        unit: "天",
                        caption: Self.ageCaption(git, scope: scope)
                    )
                    DataBandSeparator()
                    MetricTile(
                        label: "最近修改",
                        // 整串「49 秒前」以前进 value ⇒ 单位词一起吃到 34pt 大数档，
                        // 实拍里它是全页最重的墨，比本页真正的最大数还抢眼（批次 P5）。
                        // 拆成数字 + 单位两段，与左邻「项目年龄 / 天」同一画法。
                        value: git.lastCommitAt.map { LogRecency.split($0).value },
                        symbol: CodeGitSymbol.recency,
                        unit: git.lastCommitAt.flatMap { LogRecency.split($0).unit },
                        caption: Self.latestCommitCaption(git),
                        // 提交标题是**用户内容**，长度不可控（实测一条 60+ 字的中文标题
                        // 把这一格撑成三行、四格基线全歪）。它不是口径，截断可回读：
                        // 完整标题挂在这格的 tooltip 上。
                        captionLineLimit: 2
                    )
                    .help(Self.latestCommitCaption(git))
                    DataBandSeparator()
                    MetricTile(
                        label: scope.isWindowTruncated ? "窗口内作者" : "活跃作者",
                        value: NumberFormat.grouped(git.activeAuthorCount),
                        icon: .people,
                        unit: "人",
                        caption: scope.authorTileCaption(authorCount: git.activeAuthorCount)
                    )
                }
            }
        }
    }

    /// 第二个 tile 专门承载「48」这个数字：它必须和主角的「62」并排出现，
    /// 用户才能自己在屏幕上把账对上，而不是去翻下面的作者表求和。
    static func authorBasisCaption(_ scope: GitHistoryScope) -> String {
        switch scope.basis {
        case .complete(let merges):
            return merges > 0
                ? localizedFormat("已排除 %1$@ 次合并提交", NumberFormat.grouped(merges))
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
        return localizedFormat("最新：%@", latest.subject)
    }

}

// MARK: - 提交趋势（自 `GitInsightsSections.swift` 整块搬入，逐字节、不改行为）
//
// 为什么搬回宿主文件而不是新开文件：`GitInsightsSections.swift` 已到 400 行实现线
// （`SourcesSizeAuditTests`），而本片不许新建 `Sources/**` 文件
// （`SourceFileReachabilityTests.censusBaseline` 只由总工改）。趋势两类型与本页同宿主，
// 于是把最重的一块挪回来腾出空间放本轮的 ⓘ。

// MARK: - 提交趋势

struct GitCommitTrendSection: View {
    let git: GitInsights

    var body: some View {
        if let granularity = git.commitsPerPeriod.first?.granularity {
            GlassSection(
                "提交趋势",
                subtitle: localizedFormat("按 %1$@ 分桶 · 共 %2$@ 桶%3$@",
                                           gitBucketLabel(granularity),
                                           NumberFormat.grouped(git.commitsPerPeriod.count),
                                           git.commitScope.windowSuffix),
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
///
/// 本轮两件事：`DataReadoutBar` 给四个数字画了一层井（井按契约 3 只许给表格/日志/
/// 代码块），换成无面读数带；四个 `role` 全删 —— 峰值/均值/最冷清/桶数都是**测得值**，
/// 旧代码把它们涂成 accent / healthy / neutral / info 四色，等于用颜色假装它们是四种结论。
struct GitTrendReadoutBar: View {
    let buckets: [CommitBucket]

    var body: some View {
        ReadoutStrip {
            DataReadout(label: "峰值桶", value: NumberFormat.grouped(summary.peak),
                        caption: summary.unitLabel)
            DataBandSeparator()
            DataReadout(label: "桶均值", value: String(format: "%.1f", summary.average),
                        caption: summary.unitLabel)
            DataBandSeparator()
            DataReadout(label: "最冷清桶", value: NumberFormat.grouped(summary.lowest),
                        caption: localizedFormat("%@ 个空桶", NumberFormat.grouped(summary.emptyBuckets)))
            DataBandSeparator()
            DataReadout(label: "桶数", value: NumberFormat.grouped(summary.count),
                        caption: summary.spanCaption)
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
        let unit = localizedFormat("每%@", gitBucketLabel(granularity))
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
