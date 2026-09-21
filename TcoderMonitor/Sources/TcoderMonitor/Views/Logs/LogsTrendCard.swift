import SwiftUI
import Charts

// MARK: - 错误趋势

/// 按天堆叠柱（错误 / 异常 / 崩溃）+ 警告折线。
///
/// 三处统一：颜色走 `Theme.Semantic` 的严重度图形层（不再有一页一套的私色）、
/// 纵轴走台阶函数（帧帧改轴会抖）、横轴走固定天步长（点数一变刻度就重排）。
struct LogsTrendCard: View {
    let logs: LogSummary?

    var body: some View {
        GlassSection("错误趋势", subtitle: subtitle, icon: .chartLine) {
            if let buckets = plottableBuckets {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    LogTrendChart(buckets: buckets)
                        .frame(height: Theme.Layout.trendChartHeight)
                    // **留短藏长**：屏上留"哪条线是什么"（读图必需），
                    // 与柱状共用纵轴、0…N、台阶取法（{1,2,2.5,5}×10ⁿ，只在这几档里跳）
                    // 这三段次级说明进同一枚 ⓘ（整句仍由 `footnote` 一处产出）。
                    NoteLine(Self.trendReading, help: footnote(buckets))
                }
            } else if logs == nil {
                SectionEmptyNote(text: "尚未分析，点「重新分析」后这里按天展示错误、异常与崩溃的分布。",
                                 icon: .chartLine)
            } else {
                SectionEmptyNote(text: "暂无趋势数据：日志行里没有可解析的时间戳时无法按天分桶，这里不画空柱。",
                                 icon: .chartLine)
            }
        }
    }

    /// 屏上那一句读图必需的话（完整口径见 `footnote`）。
    static let trendReading = "柱状为错误 / 异常 / 崩溃按天堆叠，折线为警告数"

    private var plottableBuckets: [LogBucket]? {
        guard let logs, !logs.trend.isEmpty else { return nil }
        return logs.trend.sorted { $0.date < $1.date }
    }

    private var subtitle: String? {
        guard let logs, !logs.trend.isEmpty else { return nil }
        let peak = logs.trend.map { $0.errors + $0.exceptions + $0.crashes + $0.warnings }.max() ?? 0
        return "共 \(NumberFormat.grouped(logs.trend.count)) 天 · 单日峰值 \(NumberFormat.grouped(peak)) 条"
    }

    private func footnote(_ buckets: [LogBucket]) -> String {
        let axis = LogTrendChart.axis(for: buckets)
        return "柱状为错误 / 异常 / 崩溃按天堆叠，折线为警告数（与柱状共用纵轴）。"
            + "纵轴 0…\(NumberFormat.grouped(Int(axis.maxValue))) 条，按 {1,2,2.5,5}×10ⁿ 台阶取轴。"
    }
}

/// 一条堆叠序列：显示名 + 严重度 + 取值路径。
private struct LogSeries: Identifiable {
    let name: String
    let severity: LogSeverity
    let value: KeyPath<LogBucket, Int>
    var id: String { name }
}

struct LogTrendChart: View {
    let buckets: [LogBucket]

    private static let stack: [LogSeries] = [
        LogSeries(name: "错误", severity: .error, value: \.errors),
        LogSeries(name: "异常", severity: .exception, value: \.exceptions),
        LogSeries(name: "崩溃", severity: .crash, value: \.crashes),
    ]

    /// 柱帽圆角属图表几何，不是排版圆角（WS-I §9 把图表几何列为例外）。
    private static let barRadius: CGFloat = 1.5
    /// 警告折线用虚线：与堆叠柱分开靠的是线型，不是再多加一种颜色。
    private static let warningLineDash: [CGFloat] = [3, 2]

    /// 计数轴：步长取整且至少 1，避免出现「0.5 条」这种刻度
    /// （通用 `axis(peak:)` 的台阶是为字节速率设计的，峰值很小时会给到 0.5）。
    static func axis(for buckets: [LogBucket]) -> ChartAxis {
        let values = buckets.map { Double($0.errors + $0.exceptions + $0.crashes + $0.warnings) }
        return ChartScale.countAxis(peak: ChartScale.peak(values))
    }

    static func dayStride(_ buckets: [LogBucket]) -> Int {
        guard let first = buckets.first?.date, let last = buckets.last?.date else { return 1 }
        let days = Calendar.current.dateComponents([.day], from: first, to: last).day ?? 0
        return ChartScale.dayStride(spanDays: days)
    }

    var body: some View {
        let axis = Self.axis(for: buckets)
        return Chart(buckets) { bucket in
            ForEach(Self.stack) { series in
                BarMark(x: .value("日期", bucket.date, unit: .day),
                        y: .value("条数", bucket[keyPath: series.value]))
                    .foregroundStyle(by: .value("类型", series.name))
                    .cornerRadius(Self.barRadius)
            }
            LineMark(x: .value("日期", bucket.date, unit: .day),
                     y: .value("条数", bucket.warnings))
                .foregroundStyle(Theme.Semantic.warning.graphicColor)
                .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.chartLine, dash: Self.warningLineDash))
                .interpolationMethod(.monotone)
        }
        .chartForegroundStyleScale(domain: Self.stack.map(\.name),
                                   range: Self.stack.map { ChartSeries.color(for: $0.severity) })
        .chartLegend(position: .top, alignment: .leading, spacing: Theme.Spacing.xxs)
        .chartYScale(domain: 0...axis.maxValue)
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
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
            AxisMarks(values: .stride(by: .day, count: Self.dayStride(buckets))) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                // 固定 POSIX locale：中文系统把刻度写成「3月5日」会挤掉间距。
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "en_US_POSIX")).month(.defaultDigits).day(),
                               centered: false)
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(Color.secondary)
            }
        }
        .accessibilityLabel(Text(localizedFormat("错误趋势，%@ 天", NumberFormat.grouped(buckets.count))))
    }
}
