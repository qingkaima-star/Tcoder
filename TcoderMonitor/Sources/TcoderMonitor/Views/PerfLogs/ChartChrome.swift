import SwiftUI
import Charts

// MARK: - 三页共用的图表层
//
// 三条硬规则：
//   1. **颜色只有一个来源**：单序列曲线一律纯墨（`ChartSeries.lineColor`），
//      带严重度 / 风险 / 分数语义的走 `Theme.Semantic.*.graphicColor`。
//      三页没有「一张图里两条以上序列」的场合，所以 `Theme.Chart` 分类板在这儿无调用方
//      （本轮删掉四枚号位常量的理由见 `ChartSeries` 注释）。
//   2. **轴不能跟着数据抖**：纵轴走台阶函数，横轴走固定 stride 或相对秒数，
//      实时追加一帧时刻度不会重新洗牌。
//   3. **轴必须自报口径**：单位写在刻度上（`%` / `条`），收窄过要写明不是 0 起点，
//      否则两张同构的 0…100 图会被读成同一件事（总工截图复核提的问题 3）。

// `ChartSeries` 已上提进 `Design/ChartTokens.swift`（本轮 M1 集成）：
// 它是全仓图表取色的唯一规则，另两条页面流也要用同一份，不能各养一套。

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
    let axis: ChartAxis
    let timeAxis: TimeAxis
    let summary: String
    let yLabel: (Double) -> String
    /// 非 nil 时横轴改用「距今 N 秒」，以这个时间为「现在」。
    let relativeReference: Date?

    init(points: [Point],
         xOf: @escaping (Point) -> Date,
         yOf: @escaping (Point) -> Double,
         valueName: String,
         axis: ChartAxis,
         timeAxis: TimeAxis,
         summary: String,
         yLabel: @escaping (Double) -> String = { ChartScale.plainLabel($0) },
         relativeReference: Date? = nil) {
        self.points = points
        self.xOf = xOf
        self.yOf = yOf
        self.valueName = valueName
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
                .foregroundStyle(ChartSeries.gradient())
            LineMark(x: .value("时间", xOf(point)), y: .value(valueName, yOf(point)))
                .interpolationMethod(.monotone)
                .foregroundStyle(ChartSeries.lineColor)
                .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.emphasis))
        }
        .chartYScale(domain: axis.minValue...axis.maxValue)
        // **绘图区必须裁剪**。这条不是装饰，是"图会盖住别的区块"的止血点：
        // 纵轴被 `adaptivePercentAxis` 收窄成 75...100 之后，落在下限以下的真实读数
        // （CPU 掉到 20%、内存那一帧 `used > total` 给到 >100%）仍会按数据坐标换算，
        // `AreaMark` 的填充于是画到绘图区**外面**，一路糊住下面的轴脚注与下一个分组。
        // 用户 23:05 那句「太乱了」的实证就是这一片灰（像素从 y≈500pt 一直渐变到 y≈780pt）。
        // 只裁绘制、**不夹数据**：轴外的那些点仍然真实存在，脚注与 `rejected` 计数照旧说话。
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            AxisMarks(position: .leading, values: axis.ticks) { value in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                // **绝对色 `Color.secondary`，不是层级 `.secondary`**：层级样式会与宿主
                // 环境里的层级连乘（0.55×0.55≈0.30）。深色态实测这条轴的刻度只剩
                // `#464646`（对纯黑约 2.2:1），五档全部读不出，而总览页同类刻度没被连乘 ——
                // 同一个 App 两页的轴一深一浅。守卫 `test_chartAxisLabelsNeverUseHierarchicalStyle`。
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yLabel(number))
                            .font(Theme.Typo.monoSmall.font)
                            .foregroundStyle(Color.secondary)
                    }
                }
            }
        }
        .chartXAxis {
            if case .seconds(let stride) = timeAxis {
                AxisMarks(values: .stride(by: .second, count: stride)) { value in
                    AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                    // 尾刻度贴右边界往左长（`centered: false` 会把它切成 `08:27…`，
                    // 规则见 `ChartAxisEdge`）。
                    AxisValueLabel(anchor: ChartAxisEdge.anchor(for: value.as(Date.self),
                                                               in: timeDomain)) {
                        if let date = value.as(Date.self) {
                            Text(xLabel(for: date))
                                .font(Theme.Typo.monoSmall.font)
                                .foregroundStyle(Color.secondary)
                        }
                    }
                }
            }
            if case .days(let stride) = timeAxis {
                AxisMarks(values: .stride(by: .day, count: stride)) { value in
                    AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                    AxisValueLabel(format: .dateTime.locale(Self.axisLocale).month(.defaultDigits).day(),
                                   anchor: ChartAxisEdge.anchor(for: value.as(Date.self), in: timeDomain))
                        .font(Theme.Typo.monoSmall.font)
                        .foregroundStyle(Color.secondary)
                }
            }
        }
        // 顶格 y 轴刻度（"100%"）是**垂直居中钉在第一个刻度上**的，
        // 于是它会探出绘图区上沿，压住上面那行「分子/分母…」说明
        // （英文态实拍量到两者只差 3px、字脚相压）。留一档 `xs` 的头寸。
        .padding(.top, Theme.Spacing.xs)
        .accessibilityLabel(summary)
    }

    /// 轴标签固定 POSIX locale：中文系统下「3月5日」会把间距挤掉。
    static var axisLocale: Locale { Locale(identifier: "en_US_POSIX") }

    /// 横轴的数据域（首点…末点），只用来判"这个刻度是不是贴着边界"。
    private var timeDomain: ClosedRange<Date>? { ChartAxisEdge.domain(points.map(xOf)) }

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

/// 图的抬头 + 当前读数：名称、**分子分母口径**、读数三件事都在一行。
///
/// 原来行首有一枚按号位取色的圆点，本轮删了：单序列图里没有需要分辨的两条线，
/// 那枚点不携带任何信息，只是把「磁盘=紫、网络=青」这种无中生有的倾向性涂在版面上
/// （风格契约 5）。颜色没了之后名称从 10pt 抬到 11pt 补回识别度 ——
/// **层级靠字号与墨色分，不靠色相分**，这就是「简约无界」在一行图例上的落地。
struct SeriesLegend: View {
    var name: String
    /// 分子 / 分母的交代，例如「已用 12.4 GB / 总量 32 GB」。
    var basis: String?
    var value: String

    var body: some View {
        // 两行制：第一行「名称 …… 读数」，第二行整行给口径。
        // 原来三段挤一行、中间靠 `Spacer` 撑开，于是 1900pt 宽的画布上名称与读数之间
        // 出现约 1200pt 的空档（用户说的「拉到两端、中间没有可对齐的列」），
        // 而最先被吃掉的一定是口径那一段 —— 截完之后恰好把用户要核对的「已用 X GB」截掉。
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                Text(name)
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: Theme.Spacing.xs)
                // 读数用墨色：小字号彩字在浅底上过不了 4.5:1，而且颜色在这里不表意。
                LiveNumber(value, tier: Theme.Typo.monoBody)
            }
            if let basis {
                // 口径里带的是测得值（已用字节 / 总量），不得用 `.tertiary`。
                Text(basis)
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }
}
