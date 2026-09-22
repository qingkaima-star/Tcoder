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
        // **跨度必须报"图上这一段"**：原来这里印的是 `windowSeconds`（缓冲区窗口 ~135 秒），
        // 而图只画 `history.suffix(chartPointLimit)` ≈ 19 点 × 1.5 秒 ≈ 28.5 秒，
        // 轴与相对档用的又都是 `actualSpanSeconds` ⇒ 同一张卡上两个口径
        // （交付头 `64f2ed4` 逐张人眼复核抓到：标题写 135 秒，轴上只有 −12s）。
        // 本文件早就为"别谎报跨度"准备了 `actualSpanSeconds`，只是标题这一处没用它。
        localizedFormat("最近 %1$@ 点 · %2$@ · 窗口约 %3$@ 秒",
                        NumberFormat.grouped(points.count),
                        cadenceText,
                        "\(Int(actualSpanSeconds))")
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
                // **留短藏长**：屏上留「N/M 点可用」这个数（它决定这条线还有没有证据），
                // 完整句式进 ⓘ；ⓘ 里那条仍是目录里的整句键，原文一字未改。
                NoteLine("可信点不够画曲线（\(NumberFormat.grouped(trusted.count))/\(NumberFormat.grouped(points.count))）",
                         role: Theme.Semantic.warning, icon: .riskWarning,
                         help: localizedFormat("本窗口没有足够的可信内存读数可画曲线（%1$@/%2$@ 点可用）。",
                                               NumberFormat.grouped(trusted.count),
                                               NumberFormat.grouped(points.count)))
                    .frame(height: Theme.Layout.chartMinHeight, alignment: .center)
            }
        }
    }

    /// 轴口径全部写在卡面上：**收窄过就必须承认不是 0 起点**（盘点表 Z 节「轴不能骗人」）。
    /// 本轮的搬法：屏上那一行压成**紧凑读数**（横轴步长 + 两条纵轴区间 + 会不会读错的那句结论），
    /// 「窗口为什么切成距今秒数」「轴什么时候会收窄」这两段次级说明进 ⓘ 的 hover。
    /// ⚠ 「不是 0 起点」这五个字不许进 ⓘ —— 藏掉它，陡峭的曲线就会被读成暴涨。
    private var axisNotes: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            NoteLine("横轴 \(axisStrideReading) · 纵轴 CPU \(cpuAxis.domainText)% / 内存 \(memoryAxis.domainText)% · "
                     + (axisIsZoomed ? "轴不是 0 起点" : "两张图均为 0 起点"),
                     role: axisIsZoomed ? Theme.Semantic.warning : Theme.Semantic.neutral,
                     icon: axisIsZoomed ? .riskWarning : .info,
                     help: Self.axisCaliber)
            let rejected = SystemReadings.rejectedMemoryPoints(points)
            if rejected > 0 {
                // 剔除的**个数**留在屏上（它决定这条线还剩多少证据），判据进 ⓘ。
                NoteLine("内存曲线已剔除 \(NumberFormat.grouped(rejected)) 个无证据读数",
                         role: Theme.Semantic.warning, icon: .riskWarning,
                         help: Self.rejectedMemoryCaliber)
            }
        }
    }

    /// 任一纵轴带下限 = 轴被收窄过。
    private var axisIsZoomed: Bool { cpuAxis.isZoomed || memoryAxis.isZoomed }

    /// 横轴那一格怎么读（屏上只留这一小截，理由在 ⓘ 里）。
    private var axisStrideReading: String {
        usesRelativeAxis ? "距今秒数"
            : "每 \(ChartScale.secondsStride(windowSeconds: actualSpanSeconds)) 秒一格"
    }

    /// 进 ⓘ 的轴口径：**必须是完整句**（半句键在英文态语序必坏），
    /// 且原句「带下限的轴是为看清走势而收窄的，不是 0 起点」一字不改地搬进来——
    /// 本轮只换落点（屏上 → hover），不改口径也不删口径。
    /// 秒数与两个收窄触发点一律从 `ChartScale` 取，页面不写第二个真值（性能 spec §5.1）。
    static let axisCaliber =
        "横轴：窗口不足 \(Int(ChartScale.relativeAxisLimitSeconds)) 秒（或少于 8 个点）时改标距今秒数——"
        + "绝对时钟在这个尺度上没有区分度；否则每格步长从固定档位里选，不按点数现算，免得点数一变整个时间轴就重排。"
        + "带下限的轴是为看清走势而收窄的，不是 0 起点：内存长期在九成是 macOS 的常态，"
        + "0…100 的域里 93→97 的波动只够画 4pt，肉眼看是一条直线，所以峰值过 "
        + "\(Int(ChartScale.zoomTriggerPercent))% 收到 50…100、过 \(Int(ChartScale.midZoomPercent))% 收到 75…100。"

    /// 「无证据读数」的剔除判据：与 `SystemReadings.trustedMemoryPoints` 同一份口径。
    static let rejectedMemoryCaliber =
        "引擎给出压力档 unknown 或字节数为 0 的点不进曲线：剔掉多少个就在屏上报多少个，不补 0、也不静默丢。"

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
