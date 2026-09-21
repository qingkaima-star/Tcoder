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
    /// 节奏文案，由页面从 `MachSystemMonitor` 的唯一真值派生（暂停时显示"采样已暂停"，
    /// 而不是继续宣称一个固定节奏）。页面里不许再写第二个节拍字面量（性能 spec §5.1）。
    let cadenceText: String

    /// 两个点连出来是一条直线，看起来像「趋势」，其实是采样未到；三个点起才画。
    private static let minPointsToPlot = 3

    var body: some View {
        GlassSection("实时曲线", subtitle: subtitle, icon: .chartLine) {
            if points.count < Self.minPointsToPlot {
                EmptyStateView(icon: IconName.chartLine.rawValue,
                               title: "正在采集首个样本",
                               message: "至少 3 个点之后才有曲线可画。这里不预先给出估算形状。")
            } else {
                // 两张图是两个同级并列的叙事单元 → 组间 `group`(32)。
                // 原来它们与脚注都挤在 `md`(16) 上，跟图例与图之间同一个数，
                // 眼睛分不出「一张图结束了」。
                VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                    cpuBlock
                    memoryBlock
                    axisNotes
                }
            }
        }
    }

    private var subtitle: String {
        localizedFormat("最近 %1$@ 点 · %2$@ · 窗口约 %3$@ 秒",
                        NumberFormat.grouped(points.count),
                        cadenceText,
                        "\(Int(windowSeconds))")
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
                         basis: Self.cpuBasis(context: context),
                         value: Live.percent(SystemReadings.cpuFraction(context), precision: 0))
            LiveSeriesChart(points: points,
                            xOf: \.timestamp,
                            yOf: { $0.cpuUsage * ChartScale.percentMax },
                            valueName: "占用率",
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
                         basis: Self.memoryBasis(context: context),
                         value: Live.percent(SystemReadings.memoryFraction(context), precision: 0))
            if trusted.count >= Self.minPointsToPlot {
                LiveSeriesChart(points: trusted,
                                xOf: \.timestamp,
                                yOf: { $0.memoryFraction * ChartScale.percentMax },
                                valueName: "在用率",
                                axis: axis,
                                timeAxis: timeAxis,
                                summary: memorySummary(trusted.count, axis),
                                yLabel: Self.percentLabel,
                                relativeReference: usesRelativeAxis ? referenceDate : nil)
                    .frame(height: Theme.Layout.chartMinHeight)
            } else {
                // 可信点不够时说明为什么没有线，而不是画一条 0 线冒充平稳。
                NoteLine(localizedFormat("本窗口没有足够的可信内存读数可画曲线（%1$@/%2$@ 点可用）。",
                                           NumberFormat.grouped(trusted.count),
                                           NumberFormat.grouped(points.count)),
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
                     // 这一句不能用 markdown 星号做强调：`NoteLine` 走 `Text(String)`
                     // 逐字初始化、不解析 markdown，星号会原样上屏（实测屏幕上出现过 `**`）。
                     + (cpuAxis.isZoomed || memoryAxis.isZoomed
                        ? "带下限的轴是为看清走势而收窄的，不是 0 起点。"
                        : "两张图均为 0 起点。"))
            let rejected = SystemReadings.rejectedMemoryPoints(points)
            if rejected > 0 {
                NoteLine("内存曲线已剔除 \(NumberFormat.grouped(rejected)) 个无证据读数（引擎给出压力档 unknown 或字节数为 0）。",
                         role: Theme.Semantic.warning, icon: .riskWarning)
            }
        }
    }

    static func percentLabel(_ value: Double) -> String { "\(ChartAxis.plain(value))%" }

    static func cpuBasis(context: SampleContext) -> String {
        guard let cores = SystemReadings.coreCount(context) else { return localizedCopy("分母：全部核心") }
        // 键里写 `100%%`：这条走 `localizedFormat` → `String(format:)`，
        // 裸 `%` 会被**静默吃掉尾巴**（方案 §9，实测「95% 的提交…」→「95 的提交…」）。
        // `%%` 经 format 回填成 "100%"，中文侧一字不变；英文值同理也要写 `%%`。
        return localizedFormat("分子/分母：正在使用的核数 / %@ 核，100%% = 全部核心跑满",
                               NumberFormat.grouped(cores))
    }

    static func memoryBasis(context: SampleContext) -> String {
        let used = Live.bytes(SystemReadings.memoryUsedBytes(context))
        let total = Live.bytes(SystemReadings.memoryTotalBytes(context))
        return localizedFormat("分子/分母：已用 %1$@ / 总量 %2$@", used, total)
    }

    private func cpuSummary(_ axis: ChartAxis) -> String {
        guard let fraction = SystemReadings.cpuFraction(context) else { return localizedCopy("CPU 曲线，等待可信读数") }
        return localizedFormat("CPU 曲线，%1$@ 个点，当前 %2$@，纵轴 %3$@",
                               NumberFormat.grouped(points.count),
                               Live.percent(fraction, precision: 0),
                               axis.domainText)
    }

    private func memorySummary(_ count: Int, _ axis: ChartAxis) -> String {
        "内存在用率曲线，\(NumberFormat.grouped(count)) 个可信点，当前 \(Live.percent(SystemReadings.memoryFraction(context), precision: 0))，纵轴 \(axis.domainText)"
    }
}
