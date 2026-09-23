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
                    // **留短藏长**：屏上留「哪条线是什么」（读图必需），
                    // 与柱状共用纵轴、0…N、台阶取法（{1,2,2.5,5}×10ⁿ，只在这几档里跳）
                    // 这三段次级说明进同一枚 ⓘ（整句仍由 `footnote` 一处产出）。
                    NoteLine(Self.trendReading, help: footnote(buckets))
                }
            } else if logs == nil {
                // **留短藏长**（盘点表 G 组）：屏上留状态那一句（下面为什么没有图），
                // "点了之后这里会出现什么"那句预告进 ⓘ。两支的整句都是目录里原有的键，一字未改。
                SectionEmptyNote(text: "尚未分析", icon: .chartLine,
                                 help: "尚未分析，点「重新分析」后这里按天展示错误、异常与崩溃的分布。")
            } else {
                // 「不画空柱」是这两支共同的诚实性底线（没有分桶依据就不画），屏上的
                // 「暂无趋势数据」已经把"这里没有数"说出口，藏掉的只是**为什么不**。
                SectionEmptyNote(text: "暂无趋势数据", icon: .chartLine,
                                 help: "暂无趋势数据：日志行里没有可解析的时间戳时无法按天分桶，这里不画空柱。")
            }
        }
    }

    /// 屏上那一句读图必需的话（完整口径见 `footnote`）。
    static let trendReading = "柱状为错误 / 异常 / 崩溃按天堆叠，折线为警告数"

    private var plottableBuckets: [LogBucket]? {
        guard let logs, !logs.trend.isEmpty else { return nil }
        return logs.trend.sorted { $0.date < $1.date }
    }

    /// 卡头副标题：**两个复数槽**（天、条）。
    ///
    /// 为什么不能留成插值，也不能拆成两条 `localizedCount`：
    /// 英语这一格里「天」和「条」各自要选单复数（`1 day · peak 1 entry` vs
    /// `2 days · peak 5 entries`），而中文没有这个区分 —— 插值写法在英文态整句中文，
    /// 单数键写法在英文态语法错。两条各查各的键更不行：` · ` 是句子的一部分，
    /// 拆开后没有任何一本目录能决定"哪个槽在前"。
    /// 走 `localizedCount(_:slots:)`（批次 P69c 立的那一枚）。
    private var subtitle: String? {
        guard let logs, !logs.trend.isEmpty else { return nil }
        let peak = logs.trend.map { $0.errors + $0.exceptions + $0.crashes + $0.warnings }.max() ?? 0
        return localizedCount("共 %lld 天 · 单日峰值 %lld 条", slots: [logs.trend.count, peak])
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

    /// 横轴数据域（首桶…末桶），只用来判刻度是否贴边。
    private var timeDomain: ClosedRange<Date>? { ChartAxisEdge.domain(buckets.map(\.date)) }

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
            AxisMarks(values: .stride(by: .day, count: Self.dayStride(buckets))) { value in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                // 固定 POSIX locale：中文系统把刻度写成「3月5日」会挤掉间距。
                // 尾刻度贴边往左长，否则最后一个日期被卡片右边界切掉半截。
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "en_US_POSIX")).month(.defaultDigits).day(),
                               anchor: ChartAxisEdge.anchor(for: value.as(Date.self), in: timeDomain))
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(Color.secondary)
            }
        }
        .accessibilityLabel(Text(localizedCount("错误趋势，%lld 天", buckets.count)))
    }
}
