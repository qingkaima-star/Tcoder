import SwiftUI
import Charts

// MARK: - Git 洞察页的图表与表格行（WS-L）
//
// 图表是这页唯一允许"比文字更抢眼"的东西，所以线宽、取色、坐标轴字号全部取自令牌：
// 轴标签 10pt（`Typo.microLabel`，全仓文字下限）。
//
// **取色一律走 `ChartSeries`**（本轮集成修正）：这页的趋势柱与 24×7 矩阵都是
// **单序列**，所以颜色只有一个 —— 主线纯墨，空格子走分隔色。以前它们各自取
// `Theme.Chart` 的 0 号位并自养两个 alpha 端点，于是同一段历史在总览上是蓝的、
// 在这页也是蓝的、在性能页是黑的：三家各一套约定。多类别（语言占比、作者占比条）
// 才用 `CodeGitCategoryColor` 的稳定索引色，那一档没动。

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
            // 单序列图：一张图只有一批柱子，"按号位取色"要解决的问题（分辨哪条是哪条）
            // 在这里不存在。旧写法取 `Theme.Chart` 的 0 号位，于是同一段历史在总览上是
            // 蓝的、在这页也是蓝的、在性能页是黑的 —— 三套约定并存。收进 `ChartSeries`
            // 的唯一规则：单序列 = 纯墨（`Design/ChartTokens.swift` 上提后全仓同此）。
            .foregroundStyle(ChartSeries.lineColor)
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
    /// 星期标签列宽：容纳「周三」两个汉字 + 一字母余量。
    private static let rowLabelWidth = Theme.Spacing.xl
    /// 矩阵格子的间隙属图表几何，不是榜单行节奏——所以它不走 `DataRowMetrics`，
    /// 但也不留裸 `VStack(spacing: Theme.Spacing…)`，免得下一个人以为漏了统一。
    private static let cellGap = Theme.Spacing.xxs

    @State private var hovered: (weekday: Int, hour: Int)? = nil

    private static var gridHeight: CGFloat { Self.rowLabelWidth * 7 + Self.cellGap * 6 }
    private static var totalHeight: CGFloat { 2 + Self.gridHeight + 14 }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let labelW = Self.rowLabelWidth
            let gap = Self.cellGap
            let topPad: CGFloat = 2
            let axisH: CGFloat = 14
            let cellW = max(1, (size.width - labelW - gap * 23) / 24)
            let cellH = Self.rowLabelWidth
            Canvas { ctx, _ in
                for w in 0..<7 {
                    let y = topPad + CGFloat(w) * (cellH + gap)
                    ctx.draw(
                        Text(Self.weekdayNames[w])
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(CodeGitType.number(Theme.Typo.microLabel)),
                        at: CGPoint(x: 0, y: y + cellH / 2), anchor: .leading)
                    for h in 0..<24 {
                        let strength = intensity(hour: h, weekday: w)
                        let x = labelW + CGFloat(h) * (cellW + gap)
                        let rect = CGRect(x: x, y: y, width: cellW, height: cellH)
                        // 强度已经是 0~1 的归一比，直接当不透明度用：
                        // 空格子 = 分隔色（与 `ContributorHourRow` 的零柱同一约定），
                        // 有值的格子 = 主线纯墨按强度加浓。
                        // 旧写法在这里自养 `idleAlpha = badgeFill/2` 与
                        // `peakAlpha = Opacity.gradientBottom` 两个端点常量，而
                        // `gradientBottom` 的令牌含义是「面积渐变的收尾值」——
                        // 借一个语义属于别处的令牌当热力峰值，就是本轮要收掉的第三套
                        // 图表取色约定。现在端点不再需要常量：0 与 1 由强度本身给出。
                        let color = strength > 0
                            ? ChartSeries.lineColor.opacity(strength)
                            : Theme.Palette.Surface.separator
                        ctx.fill(Path(roundedRect: rect, cornerRadius: 2), with: .color(color))
                    }
                }
                for h in 0..<24 where [0, 6, 12, 18].contains(h) {
                    let x = labelW + CGFloat(h) * (cellW + gap) + cellW / 2
                    ctx.draw(
                        Text("\(h)")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .font(CodeGitType.number(Theme.Typo.microLabel)),
                        at: CGPoint(x: x, y: topPad + Self.gridHeight + axisH / 2), anchor: .center)
                }
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let w = Int(((point.y - topPad) / (cellH + gap)).rounded(.down))
                    let h = Int(((point.x - labelW) / (cellW + gap)).rounded(.down))
                    hovered = (0..<7).contains(w) && (0..<24).contains(h) ? (w, h) : nil
                case .ended:
                    hovered = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let cell = hovered {
                    let strength = intensity(hour: cell.hour, weekday: cell.weekday)
                    Text("\(Self.weekdayNames[cell.weekday]) \(String(format: "%02d", cell.hour)):00 — 近似强度 "
                        + "\(Int((strength * 100).rounded()))%")
                        .font(CodeGitType.number(Theme.Typo.microLabel))
                        .padding(Theme.Spacing.xxs)
                        // 同 ContributorHourRow：悬停浮层属 `.floating`，不散写材质与圆角数字。
                        .surface(layer: .floating, shape: .rounded(Theme.Radius.sm))
                }
            }
        }
        .frame(height: Self.totalHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("24 小时与星期的近似活跃分布矩阵")
        .help("提交活跃度按星期与小时近似分布；强度为两条边际归一边际的平均值，是近似值")
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
            // SHA 是一行**标识符文本**，不是按钮：它没有动作、不导航，`.textSelection`
            // 只是让人能复制。以前给它涂 accent 蓝，于是表里每一行都像可点，
            // 而真正可点的行（巨大文件榜）反而没有蓝。标识符一律等宽 + `.secondary`。
            Text(String(commit.sha.prefix(7)))
                .font(CodeGitType.path)
                .foregroundStyle(.secondary)
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
                    .foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
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
                .foregroundStyle(.secondary)
                .tableCell(DataColumns.column(columns, 3))
        }
        .dataTableRow()
    }
}
