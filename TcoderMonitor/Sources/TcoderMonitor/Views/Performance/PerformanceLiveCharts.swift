import SwiftUI

/// 实时曲线卡：CPU 与内存两张历史图。
///
/// 轴规则（针对总工截图复核的问题 1 / 2 / 3）：
///   * 纵轴单位直接写在刻度上（`0% / 50% / 100%`），并在图例里交代分子分母；
///   * 长期高位时轴**收窄**到 50…100 或 75…100，同时在卡面上写明「非 0 起点」；
///   * 窗口短于 60 秒或点数太少时，横轴改「-6s … 现在」，避免整分钟只剩一个 `22:22`。
struct PerformanceLiveCharts: View {
    let points: [SystemSnapshot]
    let context: SampleContext
    let windowSeconds: TimeInterval

    /// 两个点连出来是一条直线，看起来像「趋势」，其实是采样未到；三个点起才画。
    private static let minPointsToPlot = 3

    var body: some View {
        GlassSection("实时曲线", subtitle: subtitle, icon: .chartLine) {
            if points.count < Self.minPointsToPlot {
                EmptyStateView(icon: IconName.chartLine.rawValue,
                               title: "正在采集首个样本",
                               message: "至少 3 个点之后才有曲线可画。这里不预先给出估算形状。")
            } else {
                VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                    cpuBlock
                    memoryBlock
                    axisNotes
                }
            }
        }
    }

    private var subtitle: String {
        "最近 \(NumberFormat.grouped(points.count)) 点 · 每 1.5 秒 · 窗口约 \(Int(windowSeconds)) 秒"
    }

    private var trustedMemory: [SystemSnapshot] { SystemReadings.trustedMemoryPoints(points) }

    private var cpuAxis: ChartAxis {
        ChartScale.adaptivePercentAxis(peakPercent: ChartScale.peak(points.map { $0.cpuUsage * ChartScale.percentMax }))
    }

    private var memoryAxis: ChartAxis {
        let peak = ChartScale.peak(trustedMemory.map { $0.memoryFraction * ChartScale.percentMax })
        return ChartScale.adaptivePercentAxis(peakPercent: trustedMemory.isEmpty ? nil : peak)
    }

    /// 实际时间跨度：窗口刚启动时只有几个点，用「点数 × 间隔」会谎报跨度。
    private var actualSpanSeconds: TimeInterval {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return windowSeconds }
        return max(1.5, last.timeIntervalSince(first))
    }

    private var usesRelativeAxis: Bool {
        ChartScale.usesRelativeAxis(windowSeconds: actualSpanSeconds, pointCount: points.count)
    }

    private var timeAxis: TimeAxis {
        .seconds(ChartScale.secondsStride(windowSeconds: actualSpanSeconds))
    }

    private var referenceDate: Date { points.last?.timestamp ?? Date() }

    private var cpuBlock: some View {
        let axis = cpuAxis
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            SeriesLegend(name: "CPU 占用率",
                         series: ChartSeries.cpu,
                         basis: Self.cpuBasis(context: context),
                         value: Live.percent(SystemReadings.cpuFraction(context), precision: 0))
            LiveSeriesChart(points: points,
                            xOf: \.timestamp,
                            yOf: { $0.cpuUsage * ChartScale.percentMax },
                            valueName: "占用率",
                            series: ChartSeries.cpu,
                            axis: axis,
                            timeAxis: timeAxis,
                            summary: cpuSummary(axis),
                            yLabel: Self.percentLabel,
                            relativeReference: usesRelativeAxis ? referenceDate : nil)
                .frame(height: Theme.Layout.chartMinHeight)
        }
    }

    private var memoryBlock: some View {
        let axis = memoryAxis
        let trusted = trustedMemory
        return VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            SeriesLegend(name: "内存在用率",
                         series: ChartSeries.memory,
                         basis: Self.memoryBasis(context: context),
                         value: Live.percent(SystemReadings.memoryFraction(context), precision: 0))
            if trusted.count >= Self.minPointsToPlot {
                LiveSeriesChart(points: trusted,
                                xOf: \.timestamp,
                                yOf: { $0.memoryFraction * ChartScale.percentMax },
                                valueName: "在用率",
                                series: ChartSeries.memory,
                                axis: axis,
                                timeAxis: timeAxis,
                                summary: memorySummary(trusted.count, axis),
                                yLabel: Self.percentLabel,
                                relativeReference: usesRelativeAxis ? referenceDate : nil)
                    .frame(height: Theme.Layout.chartMinHeight)
            } else {
                // 可信点不够时说明为什么没有线，而不是画一条 0 线冒充平稳。
                NoteLine("本窗口没有足够的可信内存读数可画曲线（\(NumberFormat.grouped(trusted.count))/\(NumberFormat.grouped(points.count)) 点可用）。",
                         role: Theme.Semantic.warning, icon: .riskWarning)
                    .frame(height: Theme.Layout.chartMinHeight, alignment: .center)
            }
        }
    }

    /// 轴口径全部写在卡面上：收窄过就必须承认不是 0 起点。
    private var axisNotes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            NoteLine("横轴：\(usesRelativeAxis ? "距今秒数（窗口不足 \(Int(ChartScale.relativeAxisLimitSeconds)) 秒，时钟读数没有区分度）" : "每 \(ChartScale.secondsStride(windowSeconds: actualSpanSeconds)) 秒一格")。"
                     + "纵轴：CPU \(cpuAxis.domainText)%、内存 \(memoryAxis.domainText)%。"
                     + (cpuAxis.isZoomed || memoryAxis.isZoomed ? "带下限的轴是**为看清走势而收窄的**，不是 0 起点。" : "两张图均为 0 起点。"))
            let rejected = SystemReadings.rejectedMemoryPoints(points)
            if rejected > 0 {
                NoteLine("内存曲线已剔除 \(NumberFormat.grouped(rejected)) 个不可信读数（空闲 / 可清除页计数缺失）。",
                         role: Theme.Semantic.warning, icon: .riskWarning)
            }
        }
    }

    static func percentLabel(_ value: Double) -> String { "\(ChartAxis.plain(value))%" }

    static func cpuBasis(context: SampleContext) -> String {
        guard let cores = SystemReadings.coreCount(context) else { return "分母：全部核心" }
        return "分子/分母：正在使用的核数 / \(cores) 核，100% = 全部核心跑满"
    }

    static func memoryBasis(context: SampleContext) -> String {
        let used = Live.bytes(SystemReadings.memoryUsedBytes(context))
        let total = Live.bytes(SystemReadings.memoryTotalBytes(context))
        return "分子/分母：已用 \(used) / 总量 \(total)"
    }

    private func cpuSummary(_ axis: ChartAxis) -> String {
        guard let fraction = SystemReadings.cpuFraction(context) else { return "CPU 曲线，等待可信读数" }
        return "CPU 曲线，\(NumberFormat.grouped(points.count)) 个点，当前 \(Live.percent(fraction, precision: 0))，纵轴 \(axis.domainText)"
    }

    private func memorySummary(_ count: Int, _ axis: ChartAxis) -> String {
        "内存在用率曲线，\(NumberFormat.grouped(count)) 个可信点，当前 \(Live.percent(SystemReadings.memoryFraction(context), precision: 0))，纵轴 \(axis.domainText)"
    }
}
