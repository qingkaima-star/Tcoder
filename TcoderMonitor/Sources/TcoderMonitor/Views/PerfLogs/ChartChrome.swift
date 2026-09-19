import SwiftUI
import Charts

// MARK: - 三页共用的图表层
//
// 三条硬规则：
//   1. **颜色只有一个来源**：分类序列走 `Theme.Chart`，带严重度语义的走 `Theme.Semantic.*.graphicColor`。
//      页面里再出现一个 `Color(...)` 就等于再造一套调色板——现状正是两套彼此不同的散色。
//   2. **轴不能跟着数据抖**：纵轴走台阶函数，横轴走固定 stride 或相对秒数，
//      实时追加一帧时刻度不会重新洗牌。
//   3. **轴必须自报口径**：单位写在刻度上（`%` / `条`），收窄过要写明不是 0 起点，
//      否则两张同构的 0…100 图会被读成同一件事（总工截图复核提的问题 3）。

/// 序列取号表。**新增图表必须在这里登记号位**，不在页面里挑颜色。
enum ChartSeries {
    /// 资源曲线：按色相距离取号，避免相邻两条读成同色。
    static let cpu = 0        // 蓝 · 主 / 自身数据
    static let memory = 2     // 橙 · 关注
    static let disk = 4       // 紫
    static let network = 6    // 青
    static let healthTrend = 0

    static func color(_ index: Int) -> Color { Theme.Chart.color(at: index) }

    /// 面积填充顶色不透明度。
    ///
    /// ⚠️ 偏离《40 WS-H》§5.4 的 0.30，是有实测依据的偏离：95% 上下的内存曲线用 0.30 填充时，
    /// 面积把自己的 1.5pt 曲线糊在下面，整张图读成一个纯色矩形——监控页里
    /// 「只看得出满、看不出走势」是硬伤（总工截图复核问题 1）。
    /// 这里取 0.16（约为规范档的一半，仍明显高于 `Opacity.gradientFloor` 0.02），
    /// 同时把曲线加到 `Stroke.emphasis`(2pt) 压在填充之上。
    /// **要还原成规范值**：把本常量改回 `Theme.Palette.Opacity.gradientTop`
    /// 并把 `lineWidth` 退回 `Theme.Stroke.chartLine`。
    static let areaTopOpacity = 0.16

    /// 面积渐变：同色顶到底 `areaTopOpacity` → `gradientFloor`。
    static func gradient(_ index: Int) -> LinearGradient {
        let color = color(index)
        return LinearGradient(
            stops: [
                .init(color: color.opacity(areaTopOpacity), location: 0),
                .init(color: color.opacity(Theme.Palette.Opacity.gradientFloor), location: 1),
            ],
            startPoint: .top, endPoint: .bottom)
    }

    /// 严重度 / 风险 / 分数是**有序**语义，走语义角色的图形层而不是分类板的序号，
    /// 这样「崩溃比错误更深」在色阶上保持单调。
    static func color(for severity: LogSeverity) -> Color { Theme.Semantic.role(for: severity).graphicColor }
    static func color(for risk: RiskLevel) -> Color { Theme.Semantic.role(for: risk).graphicColor }
    static func color(forScore score: Int?) -> Color { Theme.Semantic.role(forScore: score).graphicColor }
}

/// 时间轴刻度方式。秒级用于实时曲线，天级用于日志与评分历史。
enum TimeAxis: Equatable {
    case seconds(Int)
    case days(Int)
}

/// 一条纵轴。`minValue` 不是 0 时就是**收窄过的轴**，界面必须写明（`isZoomed`）。
struct ChartAxis: Equatable {
    let minValue: Double
    let step: Double
    let maxValue: Double

    init(minValue: Double = 0, step: Double, maxValue: Double) {
        self.minValue = minValue
        self.step = step
        self.maxValue = maxValue
    }

    var isZoomed: Bool { minValue > 0 }

    /// 自报口径的轴说明。
    var domainText: String {
        let lower = Self.plain(minValue)
        let upper = Self.plain(maxValue)
        return isZoomed ? "\(lower)…\(upper)" : "0…\(upper)"
    }

    var ticks: [Double] {
        guard step > 0, maxValue > minValue else { return [minValue] }
        var result: [Double] = []
        var value = minValue
        var count = 0
        while value <= maxValue + step * 0.001, count < 14 {
            result.append(value)
            value += step
            count += 1
        }
        return result
    }

    static func plain(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(format: "%.1f", value)
    }
}

enum ChartScale {
    /// 峰值上方的留白，避免曲线贴顶被读成「爆表」。
    static let headroom = 1.2
    /// 期望的刻度格数（0 之外的段数）。
    static let desiredTickCount = 4

    static let percentMax = 100.0
    static let percentTicks: [Double] = [0, 25, 50, 75, 100]

    /// 标准百分比轴：0…100%，每 25 一格（活动监视器的历史图就是这个域）。
    static var percentAxis: ChartAxis {
        ChartAxis(step: percentMax / Double(desiredTickCount), maxValue: percentMax)
    }

    /// 占用率类曲线的轴：峰值低时用标准 0…100，峰值高时**收窄到顶端一段并标明非 0 起点**。
    ///
    /// 为什么要收窄：内存长期在 90%+ 是 macOS 的常态（文件缓存），
    /// 0…100 的域里 93→97 的波动只有 4pt 高，肉眼看是一条直线；
    /// 硬撑着「轴必须从 0 开始」等于把走势藏起来。代价是必须把口径写在图上。
    static let zoomTriggerPercent = 60.0
    static let midZoomPercent = 85.0

    static func adaptivePercentAxis(peakPercent: Double?) -> ChartAxis {
        guard let peak = peakPercent, peak.isFinite, peak >= zoomTriggerPercent else { return percentAxis }
        if peak < midZoomPercent { return ChartAxis(minValue: 50, step: 10, maxValue: 100) }
        return ChartAxis(minValue: 75, step: 5, maxValue: 100)
    }

    /// 计数轴：步长至少为 1 且取整，避免出现「2.5 条」这种刻度
    /// （`axis(peak:)` 的 {1,2,2.5,5}×10ⁿ 台阶在峰值很小时会给出 0.5 步长，那是给字节速率准备的）。
    static func countAxis(peak: Double) -> ChartAxis {
        guard peak.isFinite, peak > 0 else { return ChartAxis(step: 1, maxValue: 4) }
        let target = peak * headroom
        let step = max(1, niceStep(target / Double(desiredTickCount)).rounded())
        let maxValue = max(step, (target / step).rounded(.up) * step)
        return ChartAxis(step: step, maxValue: maxValue)
    }

    /// 把候选步长抬到 `{1, 2, 2.5, 5} × 10ⁿ`。轴只在这几个台阶之间跳，逐帧改轴被消掉。
    static func niceStep(_ candidate: Double) -> Double {
        guard candidate.isFinite, candidate > 0 else { return 1 }
        let magnitude = pow(10, floor(log10(candidate)))
        for factor in [1.0, 2.0, 2.5, 5.0, 10.0] {
            let stepped = factor * magnitude
            if stepped >= candidate - 1e-12 { return stepped }
        }
        return 10 * magnitude
    }

    /// 由窗口峰值推出稳定轴：`上限 = ceil(峰值 × 留白 / 步长) × 步长`。
    static func axis(peak: Double) -> ChartAxis {
        guard peak.isFinite, peak > 0 else { return ChartAxis(step: 1, maxValue: 4) }
        let target = peak * headroom
        let step = niceStep(target / Double(desiredTickCount))
        let maxValue = (target / step).rounded(.up) * step
        guard step > 0, maxValue.isFinite, maxValue > step else { return ChartAxis(step: 1, maxValue: 4) }
        return ChartAxis(step: step, maxValue: maxValue)
    }

    static func peak(_ values: [Double]) -> Double {
        values.filter { $0.isFinite }.max() ?? 0
    }

    /// 实时窗口约 135 秒：30 秒一格给 4~5 个刻度。步长从固定档位里选，不按点数现算，
    /// 否则点数一变整个时间轴就重排。
    static func secondsStride(windowSeconds: TimeInterval) -> Int {
        let candidates = [1, 2, 5, 15, 30, 60, 120, 300, 600, 1800]
        let wanted = max(windowSeconds, 1) / Double(desiredTickCount + 1)
        return candidates.first { Double($0) >= wanted } ?? 3600
    }

    /// 窗口短于这个长度时，绝对时钟标签（`22:22`）在一分钟内没有区分度，
    /// 改用「距今 N 秒」的相对轴（总工截图复核问题 2）。
    static let relativeAxisLimitSeconds = 60.0

    static func usesRelativeAxis(windowSeconds: TimeInterval, pointCount: Int) -> Bool {
        windowSeconds < relativeAxisLimitSeconds || pointCount < 8
    }

    /// 相对秒数标签。以最新一帧为「现在」，其余按负秒数。
    static func relativeSecondsText(_ date: Date, reference: Date) -> String {
        let delta = reference.timeIntervalSince(date)
        if delta < 0.75 { return "现在" }
        return "-\(Int(delta.rounded()))s"
    }

    /// 日志按天分桶：跨度越大步长越粗，全部落在 1/2/3/5/7/14 这几个可读档位上。
    static func dayStride(spanDays: Int) -> Int {
        switch spanDays {
        case ...0: return 1
        case 1...6: return 1
        case 7...13: return 2
        case 14...20: return 3
        case 21...40: return 5
        case 41...70: return 7
        default: return 14
        }
    }
}

// MARK: - 单序列「面积 + 曲线」

/// CPU、内存、评分历史三处同源，轴的确定性、10pt 等宽轴标签、相对时间轴只有一份实现。
struct LiveSeriesChart<Point: Identifiable>: View {
    let points: [Point]
    let xOf: (Point) -> Date
    let yOf: (Point) -> Double
    let valueName: String
    let series: Int
    let axis: ChartAxis
    let timeAxis: TimeAxis
    let yLabel: (Double) -> String
    let summary: String
    /// 非 nil 时横轴改用「距今 N 秒」，以这个时间为「现在」。
    let relativeReference: Date?

    init(points: [Point],
         xOf: @escaping (Point) -> Date,
         yOf: @escaping (Point) -> Double,
         valueName: String,
         series: Int,
         axis: ChartAxis,
         timeAxis: TimeAxis,
         summary: String,
         yLabel: @escaping (Double) -> String = { ChartScale.plainLabel($0) },
         relativeReference: Date? = nil) {
        self.points = points
        self.xOf = xOf
        self.yOf = yOf
        self.valueName = valueName
        self.series = series
        self.axis = axis
        self.timeAxis = timeAxis
        self.summary = summary
        self.yLabel = yLabel
        self.relativeReference = relativeReference
    }

    var body: some View {
        Chart(points) { point in
            AreaMark(x: .value("时间", xOf(point)), y: .value(valueName, yOf(point)))
                .interpolationMethod(.monotone)
                .foregroundStyle(ChartSeries.gradient(series))
            LineMark(x: .value("时间", xOf(point)), y: .value(valueName, yOf(point)))
                .interpolationMethod(.monotone)
                .foregroundStyle(ChartSeries.color(series))
                .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.emphasis))
        }
        .chartYScale(domain: axis.minValue...axis.maxValue)
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yLabel(number))
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            if case .seconds(let stride) = timeAxis {
                AxisMarks(values: .stride(by: .second, count: stride)) { value in
                    AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xLabel(for: date))
                                .font(Theme.Typo.monoSmall.font)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if case .days(let stride) = timeAxis {
                AxisMarks(values: .stride(by: .day, count: stride)) { _ in
                    AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                    AxisValueLabel(format: .dateTime.locale(Self.axisLocale).month(.defaultDigits).day(),
                                   centered: false)
                        .font(Theme.Typo.monoSmall.font)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(summary)
    }

    /// 轴标签固定 POSIX locale：中文系统下「3月5日」会把间距挤掉。
    static var axisLocale: Locale { Locale(identifier: "en_US_POSIX") }

    private func xLabel(for date: Date) -> String {
        guard let reference = relativeReference else {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "HH:mm:ss"
            return formatter.string(from: date)
        }
        return ChartScale.relativeSecondsText(date, reference: reference)
    }
}

extension ChartScale {
    /// 轴标签的默认写法：整数值不带小数点。
    static func plainLabel(_ value: Double) -> String { ChartAxis.plain(value) }
}

/// 图例 + 当前读数：色块、名称、**分子分母口径**、读数四件事都在一行。
struct SeriesLegend: View {
    /// 图例色点直径。属图表几何（WS-I §9 列为例外），跟着 10pt 文字量出来的一格。
    private static let dotDiameter: CGFloat = 6

    var name: String
    var series: Int
    /// 分子 / 分母的交代，例如「已用 12.4 GB / 总量 32 GB」。
    var basis: String?
    var value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Circle()
                .fill(ChartSeries.color(series))
                .frame(width: Self.dotDiameter, height: Self.dotDiameter)
            Text(name)
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.secondary)
            if let basis {
                Text(basis)
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Theme.Spacing.xs)
            // 读数用墨色：曲线色只负责「哪条线」，小字号彩字在白卡上过不了 4.5:1。
            LiveNumber(value, tier: Theme.Typo.monoBody)
        }
    }
}
