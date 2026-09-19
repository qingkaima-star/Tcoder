import SwiftUI
import Charts

// MARK: - Git 洞察页的图表与表格行（WS-L）
//
// 图表是这页唯一允许"比文字更抢眼"的东西，所以线宽、面积渐变、坐标轴字号全部取自令牌：
// 曲线 1.5pt（`Stroke.chartLine`）、面积 0.30 → 0.02（`Opacity.gradientTop/gradientFloor`）、
// 轴标签 10pt（`Typo.microLabel`，全仓文字下限）。

func gitBucketLabel(_ granularity: BucketGranularity) -> String {
    switch granularity {
    case .day: return "日"
    case .week: return "周"
    case .month: return "月"
    }
}

// MARK: - 提交趋势

struct GitCommitTrendChart: View {
    let buckets: [CommitBucket]
    let granularity: BucketGranularity

    /// 柱子顶角只取一个描边宽度档，比 `Radius.sm`(6) 克制：桶宽常年在 10pt 以下，
    /// 6pt 圆角会把每根柱子削成胶囊，读起来不像时间轴。
    private static let barCorner: CGFloat = Theme.Stroke.emphasis

    var body: some View {
        Chart(buckets) { bucket in
            BarMark(
                x: .value("时间", bucket.date, unit: calendarUnit),
                y: .value("提交", bucket.commits)
            )
            .foregroundStyle(Theme.Chart.color(at: CodeGitCategoryColor.aggregateIndex))
            .cornerRadius(Self.barCorner)
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 6)) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel(format: axisFormat, centered: false)
                    // AxisMark 链上没有 .monospacedDigit()，所以走已开等宽数字的字体档。
                    .font(CodeGitType.number(Theme.Typo.microLabel))
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel().font(CodeGitType.number(Theme.Typo.microLabel))
            }
        }
        .accessibilityLabel("提交趋势，按\(gitBucketLabel(granularity))分桶，共 \(NumberFormat.grouped(buckets.count)) 桶")
    }

    private var calendarUnit: Calendar.Component {
        switch granularity {
        case .day: return .day
        case .week: return .weekOfYear
        case .month: return .month
        }
    }

    /// 固定 POSIX locale：刻度数字必须恒为 "3/5"、"2024/3" 这种纯数字形态，
    /// 不能随用户的中文系统语言变成「3月5日」——那会把 6 个刻度挤成两行。
    private var axisFormat: Date.FormatStyle {
        let locale = Locale(identifier: "en_US_POSIX")
        switch granularity {
        case .day, .week:
            return .dateTime.locale(locale).month(.defaultDigits).day()
        case .month:
            return .dateTime.locale(locale).year().month(.defaultDigits)
        }
    }
}

// MARK: - 24×7 活跃分布

/// 7 行（周一开头）× 24 列。`GitInsights` 只存**边际**的小时与星期直方图，
/// 拿不到逐（星期, 小时）的计数，所以单元格强度是两条归一边际的平均值，
/// 卡片副标题与 tooltip 都把它标成近似值——不能装作是真实矩阵。
struct GitActivityHeatmap: View {
    let hourCounts: [Int]
    let weekdayCounts: [Int]

    private static let weekdayNames = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]
    /// 空格子与最忙格子的不透明度，两端都取自透明度刻度，不再是 0.08/0.85 这种杂值。
    private static let idleAlpha = Theme.Palette.Opacity.badgeFill / 2
    private static let peakAlpha = Theme.Palette.Opacity.gradientBottom
    /// 星期标签列宽：容纳「周三」两个汉字 + 一字母余量。
    private static let rowLabelWidth = Theme.Spacing.xl
    /// 矩阵格子的间隙属图表几何，不是榜单行节奏——所以它不走 `DataRowMetrics`，
    /// 但也不留裸 `VStack(spacing: Theme.Spacing…)`，免得下一个人以为漏了统一。
    private static let cellGap = Theme.Spacing.xxs

    var body: some View {
        VStack(spacing: Self.cellGap) {
            ForEach(0..<7, id: \.self) { weekday in
                HStack(spacing: Self.cellGap) {
                    Text(Self.weekdayNames[weekday])
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: Self.rowLabelWidth, alignment: .leading)
                    ForEach(0..<24, id: \.self) { hour in
                        let strength = intensity(hour: hour, weekday: weekday)
                        Rectangle()
                            .fill(Theme.Chart.color(at: CodeGitCategoryColor.aggregateIndex)
                                .opacity(Self.idleAlpha + (Self.peakAlpha - Self.idleAlpha) * strength))
                            .frame(maxWidth: .infinity, minHeight: Self.rowLabelWidth)
                            .help("\(Self.weekdayNames[weekday]) \(hour):00 — 近似强度 "
                                + "\(Int((strength * 100).rounded()))%")
                    }
                }
            }
            HStack(spacing: Self.cellGap) {
                Color.clear.frame(width: Self.rowLabelWidth, height: Theme.Stroke.hairline)
                ForEach(0..<24, id: \.self) { hour in
                    Text([0, 6, 12, 18].contains(hour) ? "\(hour)" : "")
                        .font(CodeGitType.number(Theme.Typo.microLabel))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("24 小时与星期的近似活跃分布矩阵")
    }

    /// 两条边际全零 = 时间戳根本没解析出来，这是「没有数据」，不是「没人半夜提交」。
    static func hasNoTimestamps(hourCounts: [Int], weekdayCounts: [Int]) -> Bool {
        hourCounts.allSatisfy { $0 == 0 } && weekdayCounts.allSatisfy { $0 == 0 }
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

// MARK: - 最近提交行

struct GitCommitRow: View {
    let commit: CommitRecord

    private var columns: [DataGridColumn] { DataColumns.recentCommits }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DataRowMetrics.cellGap) {
            Text(String(commit.sha.prefix(7)))
                .font(CodeGitType.path)
                .foregroundStyle(Theme.Semantic.accent.textColor)
                .tableCell(DataColumns.column(columns, 0))
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                Text(commit.subject)
                    .font(CodeGitType.prose(Theme.Typo.body))
                    .lineLimit(1)
                Text("\(commit.author.isEmpty ? "未知作者" : commit.author) · "
                    + "\(LogRecency.describe(commit.date)) · "
                    + "\(DateFormat.full.string(from: commit.date))")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .tableCell(DataColumns.column(columns, 1))

            Text(NumberFormat.grouped(commit.filesChanged))
                .font(CodeGitType.number(Theme.Typo.monoSmall))
                .foregroundStyle(.secondary)
                .tableCell(DataColumns.column(columns, 2))
                .help("本次提交触达 \(NumberFormat.grouped(commit.filesChanged)) 个文件")

            Text(NumberFormat.signed(commit.additions))
                .font(CodeGitType.number(Theme.Typo.monoSmall))
                .foregroundStyle(Theme.Semantic.success.textColor)
                .tableCell(DataColumns.column(columns, 3))

            Text(NumberFormat.signed(-commit.deletions))
                .font(CodeGitType.number(Theme.Typo.monoSmall))
                .foregroundStyle(Theme.Semantic.danger.textColor)
                .tableCell(DataColumns.column(columns, 4))
        }
        .dataTableRow()
    }
}

// MARK: - 候选仓库行

struct GitNestedCandidateRow: View {
    let candidate: NestedRepositoryCandidate
    let isAnalyzed: Bool
    let columns: [DataGridColumn]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DataRowMetrics.cellGap) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                ThemedIcon(isAnalyzed ? .noRisk : .emptyUnknown, role: .badge,
                           label: isAnalyzed ? "当前分析对象" : "未被分析")
                    .foregroundStyle(isAnalyzed
                        ? Theme.Semantic.success.textColor
                        : Theme.Semantic.neutral.textColor)
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        Text(candidate.directoryName)
                            .font(CodeGitType.prose(Theme.Typo.body))
                            .lineLimit(1)
                        if isAnalyzed {
                            SemanticBadge("当前分析对象", role: Theme.Semantic.accent, icon: .info)
                        }
                    }
                    Text(candidate.path)
                        .font(CodeGitType.path)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }
            .tableCell(DataColumns.column(columns, 0))

            Text(NumberFormat.grouped(candidate.commitCount))
                .font(CodeGitType.number(Theme.Typo.monoSmall))
                .foregroundStyle(isAnalyzed ? Color.primary : Color.secondary)
                .tableCell(DataColumns.column(columns, 1))
                .help("该仓库含合并共 \(NumberFormat.grouped(candidate.commitCount)) 次提交")

            Text(candidate.branch.isEmpty ? "无分支" : candidate.branch)
                .font(CodeGitType.path)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .tableCell(DataColumns.column(columns, 2))

            Text(candidate.lastCommitAt.map { LogRecency.describe($0) } ?? "无提交")
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .tableCell(DataColumns.column(columns, 3))
        }
        .dataTableRow()
    }
}
