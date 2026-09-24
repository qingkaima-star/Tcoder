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
                     // 副标题与卡内空态标题原本逐字相同（都是「历史点不足」），隔三行念两遍。
                     // 页尾实拍（.scratch/evidence-8de2d17/light-tail/健康评分.png）抓到后改成
                     // "报数"：这一档真正知道的是**有几个点**，"不足"由下面的空态去说。
                     // ⚠ 这里必须是**整句键 + localizedFormat**，不能是插值拼串：
                     // 插值串没有可查的键，英文态下卡名翻成 "Score Trend" 而这一行还是中文
                     // （英文态取证 `64c5418` 实拍照出来的就是这一格）。
                     subtitle: points.count >= 2
                         ? localizedFormat("共 %1$@ 个历史点 · 全部来自本机落盘的评分记录",
                                           NumberFormat.grouped(points.count))
                         : localizedFormat("只有 %1$@ 个历史点", NumberFormat.grouped(points.count)),
                     icon: .chartLine,
                     // 「怎么让趋势出现」是这条空态里唯一可操作的部分，不能因为版面就丢掉：
                     // 屏上留判定（少于两个点不画线），完整动线进 ⓘ。少一句就是 B 守恒线要红的。
                     // 挂载点从"空态下面独立一行"改成**卡头 trailing**：
                     // 独立成行的 ⓘ 会在这张高卡片左下角长出一枚没邻居的灰点
                     // （页尾实拍 .scratch/evidence-8de2d17/light-tail/健康评分.png）。
                     trailing: points.count >= 2 ? nil
                         : AnyView(CopyHelpBadge("至少完成两次分析后可以看到趋势。"))) {
            if points.count >= 2 {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HealthTrendChart(points: points, gradeBLine: Self.gradeBLine)
                        .frame(height: Theme.Layout.trendChartHeight)
                    readoutStrip
                    // 「不是 0 起点」与「不外推」是这张图的两条防误读声明，留在屏上；
                    // B 级参考线的具体分值与"只连已有点"的实现细节进 ⓘ（线本身已经画出来了）。
                    NoteLine("纵轴固定 0…100 分 · 不做任何外推。",
                             help: localizedFormat("B 级参考线 %1$@ 分；折线只连已有历史点，不外插也不预测。",
                                                   NumberFormat.grouped(Int(Self.gradeBLine))))
                    consistencyNote
                }
            } else {
                // **卡内空态用 `SectionEmptyNote`，不用 `EmptyStateView`**（错误趋势卡早就是这么办的）。
                // `EmptyStateView` 带 140pt 最小高，那一档的判据是"整块区域只有空态"；
                // 这里卡头已经把"这块渲染了"说了，再垫 140 就只剩空洞 ——
                // 页尾实拍（.scratch/evidence-64f2ed4-p21/light-tail/健康评分.png）量到这张卡 290pt 高，
                // 最后一行字停在 0.800 处，下面 150pt 一个字形都没有。
                SectionEmptyNote(text: "历史点不足 · 少于两个点时这里不画线。",
                                 icon: .chartLine)
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
            // 双语 P69b：原来这一格把天数**插在自己肚子里**（`"\(grouped(spanDays)) 天"`），
            // 拼出来的整串从来没有键可查 ⇒ 英文态「跨度」一栏永远铺着中文。
            // 量词键 `%lld 天` 目录里已经登记（英文 1 day / 3 days 走 stringsdict 的复数），
            // 这里**复用**那一条，不另造单数键。
            Theme.Readout.Field("跨度", Self.spanCaption(spanDays))
        }
    }

    /// 「跨度」那一格的读数：中文回填 `N 天`，与改前的 `"\(grouped(n)) 天"` 逐字相同
    /// （千分位由 `localizedCount` 在填完之后补，与全站大读数同一把记法）。
    static func spanCaption(_ days: Int) -> String {
        localizedCount("%lld 天", days)
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
            NoteLine(Self.scoreMismatchNote(last: last.score, current: score),
                     role: Theme.Semantic.warning, icon: .riskWarning,
                     help: "可能是旧记录，也可能是本次评分尚未落盘。")
        }
    }

    /// 「历史末点 N 与本次 M 不一致。」：整句键 + 两个位置参数（双语 P69b）。
    ///
    /// 原来写成 `"历史末点 \(last.score) 与本次 \(score) 不一致。"` ——
    /// `NoteLine` 的 `text` 在渲染点查的是**拼完之后**那一串，目录里不可能有这种键。
    /// 两个数都是**分数、不是可数名词** ⇒ 收 `String` 的 `localizedFormat` 就够，
    /// 不占 `stringsdict` 的复数机器（记进账会让英文硬凑成单数形态）。
    static func scoreMismatchNote(last: Int, current: Int) -> String {
        localizedFormat("历史末点 %1$@ 与本次 %2$@ 不一致。",
                        NumberFormat.grouped(last), NumberFormat.grouped(current))
    }
}

/// 历史点全部来自本机落盘的评分记录；这里只连线，不做任何外推。
struct HealthTrendChart: View {
    let points: [ScoreHistoryPoint]
    let gradeBLine: Double

    /// 历史点直径与 B 级参考线虚线段长，均属图表几何（WS-I §9 例外），随 10pt 轴标签量出来。
    private static let pointSymbolSize: CGFloat = 32
    private static let referenceLineDash: [CGFloat] = [4, 3]

    /// 横轴数据域（首点…末点），只用来判刻度是否贴边。
    private var timeDomain: ClosedRange<Date>? { ChartAxisEdge.domain(points.map(\.date)) }

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
            AxisMarks(values: .stride(by: .day, count: stride)) { value in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                // 尾刻度贴边往左长，否则最后一个日期被卡片右边界切掉半截。
                AxisValueLabel(format: .dateTime.locale(Locale(identifier: "en_US_POSIX")).month(.defaultDigits).day(),
                               anchor: ChartAxisEdge.anchor(for: value.as(Date.self), in: timeDomain))
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
