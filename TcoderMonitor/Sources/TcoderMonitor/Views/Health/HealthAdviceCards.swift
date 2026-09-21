import SwiftUI
import Charts

// MARK: - 优点 / 问题 / 建议

/// 三张结论卡。列表为空是「查了但没命中」（②），不是「没查」（③）——
/// 能走到这一步说明分量已经算出来了，所以句式统一写成「未识别到」。
///
/// 三张卡从 `LazyVGrid(adaptive 320)` 收成**单列 + `Spacing.group`(32)**：
/// `GlassSection` 自基座起不再画面板，三列长短不一的文字并排 12pt 会互相吃进对方的
/// 行距里 ——「不规整拥挤」在去面之后只能靠间距解决，不能靠把盒子加回来解决。
struct HealthAdviceGrid: View {
    let health: HealthScore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
            AdviceCard(title: "优点",
                       items: health.strengths,
                       role: Theme.Semantic.success,
                       icon: .noRisk,
                       subtitle: "本次评分里做得好的地方",
                       emptyNote: "已完成计算，未识别到突出项。")
            AdviceCard(title: "问题",
                       items: health.issues,
                       role: Theme.Semantic.danger,
                       icon: .riskSevere,
                       subtitle: "拉低综合分的地方",
                       emptyNote: "已完成计算，未识别到风险项。")
            AdviceCard(title: "建议",
                       items: health.recommendations,
                       role: Theme.Semantic.neutral,
                       icon: .disclose,
                       subtitle: "由上面的数字按规则派生",
                       emptyNote: "没有可派生的建议：上面没有待改项。")
        }
    }
}

struct AdviceCard: View {
    let title: String
    let items: [String]
    let role: Theme.SemanticRole
    let icon: IconName
    let subtitle: String
    let emptyNote: String

    var body: some View {
        GlassSection(title, subtitle: subtitle, icon: icon) {
            if items.isEmpty {
                // 「已完成计算，未识别到突出项」是 ② 那一态的**结论**，不是被灰掉的占位符。
                Text(emptyNote)
                    .font(Theme.Typo.narrative.font)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Spacing.xs)
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                            ThemedIcon(icon, role: .badge).foregroundStyle(role.textColor)
                            // 句子本身回到墨色：一条 12pt 的红字长句既难读，又把「颜色」
                            // 这个唯一还能表达语义的通道花在**整段正文**上。
                            // 语义由左边的图标（色 + 形双通道）与这张卡的 `groupLabel` 标题承担。
                            Text(item)
                                .font(Theme.Typo.narrative.font)
                                .foregroundStyle(.primary)
                                .lineSpacing(Theme.Typo.narrative.lineSpacing)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }
}

// MARK: - 评分趋势

struct HealthTrendCard: View {
    let health: HealthScore?
    let points: [ScoreHistoryPoint]

    /// 等级 B 的分数线，与 `HealthGrade.init(score:)` 保持一致。
    static let gradeBLine = 70.0

    var body: some View {
        GlassSection("评分趋势",
                     subtitle: points.count >= 2
                         ? "共 \(NumberFormat.grouped(points.count)) 个历史点 · 全部来自本机落盘的评分记录"
                         : "历史点不足",
                     icon: .chartLine) {
            if points.count >= 2 {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HealthTrendChart(points: points, gradeBLine: Self.gradeBLine)
                        .frame(height: Theme.Layout.trendChartHeight)
                    readoutStrip
                    NoteLine("纵轴固定 0…100 分，B 级参考线 \(Int(Self.gradeBLine)) 分；折线只连已有历史点，不做任何外推。")
                    consistencyNote
                }
            } else {
                EmptyStateView(icon: IconName.chartLine.rawValue,
                               title: "历史点不足",
                               message: "至少完成两次分析后可以看到趋势。少于两个点时这里不画线。")
            }
        }
    }

    @ViewBuilder
    private var readoutStrip: some View {
        let scores = points.map { Double($0.score) }
        // 四件统计量一件不少。**不再用 `Theme.Readout.Bar`**：它内部画一口
        // `.contentInset` 实心井，而契约 3 里井只给表格 / 日志列表 / 代码块，
        // 一行键值读数不是井（`Readout.Bar` 本体在 `Design/` 里，归总工，已报契约缺口）。
        // `Readout.Field` 什么都不画，直接排就是无界版读数条。
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Theme.Readout.Field("最高", Live.fixed(scores.max(), digits: 0))
            Theme.Readout.Field("最低", Live.fixed(scores.min(), digits: 0))
            Theme.Readout.Field("均值", Live.fixed(Self.average(scores), digits: 1))
            Theme.Readout.Field("跨度", "\(NumberFormat.grouped(spanDays)) 天")
        }
    }

    private var spanDays: Int {
        guard let first = points.first?.date, let last = points.last?.date else { return 0 }
        return max(0, Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0)
    }

    static func average(_ scores: [Double]) -> Double? {
        guard !scores.isEmpty else { return nil }
        return scores.reduce(0, +) / Double(scores.count)
    }

    @ViewBuilder
    private var consistencyNote: some View {
        // `verdict` 而不是 `overall`：无证据那一份的 0 是占位，
        // 拿它去比历史末点会凭空报一条"评分不一致"的警告（批次 P7-B）。
        if let health, let score = health.verdict, let last = points.last, last.score != score {
            NoteLine("历史末点 \(last.score) 与本次 \(score) 不一致：可能是旧记录，或本次评分尚未落盘。",
                     role: Theme.Semantic.warning, icon: .riskWarning)
        }
    }
}

/// 历史点全部来自本机落盘的评分记录；这里只连线，不做任何外推。
struct HealthTrendChart: View {
    let points: [ScoreHistoryPoint]
    let gradeBLine: Double

    /// 历史点直径与 B 级参考线虚线段长，均属图表几何（WS-I §9 例外），随 10pt 轴标签量出来。
    private static let pointSymbolSize: CGFloat = 32
    private static let referenceLineDash: [CGFloat] = [4, 3]

    var body: some View {
        Chart(points) { point in
            LineMark(x: .value("时间", point.date), y: .value("分数", Double(point.score)))
                .interpolationMethod(.monotone)
                // 趋势线本身是结构 → 纯墨；**语义在点上**（每个点按当次分数档着色）。
                .foregroundStyle(ChartSeries.lineColor)
                .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.chartLine))

            PointMark(x: .value("时间", point.date), y: .value("分数", Double(point.score)))
                .foregroundStyle(ChartSeries.color(forScore: point.score))
                .symbolSize(Self.pointSymbolSize)

            RuleMark(y: .value("B 级线", gradeBLine))
                .foregroundStyle(Theme.Semantic.warning.graphicColor)
                .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.separator, dash: Self.referenceLineDash))
                .annotation(position: .top, alignment: .leading) {
                    Text("B 级线")
                        .font(Theme.Typo.microLabel.font)
                        .foregroundStyle(.secondary)
                }
        }
        .chartYScale(domain: 0...ChartScale.percentMax)
        .chartYAxis {
            AxisMarks(position: .leading, values: ChartScale.percentTicks) { value in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(NumberFormat.grouped(Int(number)))
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: stride)) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "en_US_POSIX")).month(.defaultDigits).day(),
                               centered: false)
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(Color.secondary)
            }
        }
        .accessibilityLabel(Text(localizedFormat("评分趋势，%@ 个历史点", NumberFormat.grouped(points.count))))
    }

    private var stride: Int {
        guard let first = points.first?.date, let last = points.last?.date else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return ChartScale.dayStride(spanDays: days)
    }
}
