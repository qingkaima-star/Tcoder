import Charts
import SwiftUI

// MARK: - Hero：健康评分环 + 结论区
//
// 首屏第一眼。两处旧写法直接误导用户，本轮一并修：
//   1. `score ?? 0` 让「没评分」画成 0 分红色满环（WS-I §3.4 / WS-D #6）；
//   2. 优点 / 问题用 `plus.circle` / `minus.circle`，读起来像「加钱 / 减分」，
//      换成登记表里的对勾与三角，才是「已确认」与「需注意」的双通道。

struct HealthRing: View {
    /// nil = 未评分。必须画成空心灰圈 + `DataAbsence.notAnalysed` 的字面，不能画成 0 分。
    var score: Int?
    var grade: HealthGrade?
    var trend: Int?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 环心**数字位**的唯一字符串来源：`readout`（眼睛）与 `accessibilitySummary`（读屏）
    /// 都只从这里取（《42》§14.3 第 2 条）。
    ///
    /// 谁在这两个出口各自写字面（哪怕写的都是 `--`），下一次措辞改动就会只落到其中一边，
    /// 于是看到环里是 `--`、VoiceOver 念出另一句。`DesignAbsenceStateTests` 把这条钉成断言。
    static func scoreText(for score: Int?) -> String {
        DataAbsence.optional(score.map(String.init)).display
    }

    var body: some View {
        let role = Theme.Semantic.role(forScore: score)
        ZStack {
            Circle()
                .stroke(Theme.Palette.Surface.separator,
                        lineWidth: ShellLayout.ringLineWidth)
            if let score {
                Circle()
                    .trim(from: 0, to: CGFloat(min(max(score, 0), 100)) / 100)
                    .stroke(role.graphicColor,
                            style: StrokeStyle(lineWidth: ShellLayout.ringLineWidth,
                                               lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    // WS-H §10：动效可关。环形补间只是让分数变化不那么突兀，
                    // 开了「减弱动态效果」就不该还转。
                    .animation(reduceMotion ? nil : .smooth, value: score)
            }
            readout(role: role)
        }
        .padding(Theme.Spacing.md)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("健康评分")
        .accessibilityValue(accessibilitySummary)
    }

    /// 读屏出口：环心里三处信息（分数、等级、趋势）在视觉上并排，读屏要一次说全，
    /// 否则会只念一个数字、把「A」和「+3」丢掉。
    ///
    /// 未评分那一支**必须**与视觉出口 `scoreText(for:)` 给同一个串（《42》§14.3 第 2 条）：
    /// 只改这边的措辞，`DesignAbsenceStateTests` 那条「两个出口同串」就红。
    static func accessibilityText(score: Int?, grade: HealthGrade?, trend: Int?) -> String {
        guard let score else { return scoreText(for: nil) }
        var parts = [localizedFormat("%1$@ 分", scoreText(for: score))]
        if let grade { parts.append(localizedFormat("%1$@ 级", localizedCopy(grade.rawValue))) }
        if let trend, trend != 0 { parts.append(localizedFormat("较上次 %@", NumberFormat.signed(trend))) }
        return parts.joined(separator: "，")
    }

    private var accessibilitySummary: String {
        Self.accessibilityText(score: score, grade: grade, trend: trend)
    }

    private func readout(role: Theme.SemanticRole) -> some View {
        VStack(spacing: Theme.Spacing.xs) {
            Text(Self.scoreText(for: score))
                .font(Theme.Typo.heroMetric.font)
                // 56pt 的数字**一律纯墨**，健康语义交给外面那圈环（`role.graphicColor`）。
                // 原来这里涂 `role.textColor`，于是深色模式下一个 61 分的中档分数会以整块
                // 色板里最响的那颗黄（旧 `#FFD60A`，相对亮度 0.694，比 danger 的 0.258
                // 亮 2.7 倍）占住页面最大的面积 —— 参考图最响的墨永远给最大的数，
                // 彩色只出现在小面积的状态标记上。「没有主次」在首屏就是这一行。
                // 未评分那一支仍走 neutral：空读数不该和真实读数一样响。
                .foregroundStyle(score == nil ? Theme.Semantic.neutral.textColor
                                              : Theme.Palette.Surface.ink)
            subline(role: role)
        }
    }

    @ViewBuilder
    private func subline(role: Theme.SemanticRole) -> some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text("/100")
                .font(Theme.Typo.microLabel.font.monospacedDigit())
                .foregroundStyle(.tertiary)
            if let grade {
                Text(grade.rawValue)
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(role.textColor)
            }
            if let trend, trend != 0 {
                // 双通道：箭头符号 + 有符号数字，不只靠红绿（WS-H §4.3 / §10）
                HStack(spacing: Theme.Spacing.xxs) {
                    ThemedIcon(trend > 0 ? .trendUp : .trendDown, role: .badge)
                    Text(NumberFormat.signed(trend))
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                }
                .foregroundStyle(trend > 0 ? Theme.Semantic.success.textColor
                                           : Theme.Semantic.danger.textColor)
            }
        }
    }
}

/// Hero 区：左环右结论。
///
/// **它不再是一块卡**（风格契约 1/2）：外面那层 `GlassCard` 撤了。基座把 `.content`
/// 改成什么都不画之后，那张卡只剩下 24pt 内边距还在把内容往中间挤，
/// 而版框已经由页面的 `Spacing.pageMargin` 负责 —— 留着它等于凭空多一层缩进。
/// 分组线交给上面的 `groupLabel` 小标题与留白。
struct HealthHeroCard: View {
    var health: HealthScore?

    var body: some View {
        HStack(alignment: .top, spacing: DashboardLayout.heroGap) {
            HealthRing(score: health?.verdict,
                       grade: health?.verdictGrade,
                       trend: health?.trendDelta)
                .frame(width: DashboardLayout.heroRingWidth,
                       height: DashboardLayout.heroRingHeight)
            narrative
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var narrative: some View {
        if let health {
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("工程健康评分")
                    .typed(Theme.Typo.groupLabel)
                    .foregroundStyle(.secondary)
                findings(health)
                if !health.narrative.isEmpty {
                    Text(health.narrative)
                        .font(Theme.Typo.narrative.font)
                        .lineSpacing(Theme.Typo.narrative.lineSpacing)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
                Spacer(minLength: Theme.Spacing.xs)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            EmptyStateView(
                icon: IconName.emptyUnknown.rawValue,
                title: ShellCopy.notAnalyzed(.thisProject),
                message: "点击右上角「重新分析」，扫描代码规模、Git 历史、日志与依赖之后这里会出现评分与结论。"
            )
        }
    }

    /// 优点与问题各取 3 条（WS-H §8.1）。两条都空时明说，而不是留一块空白让人以为没渲染。
    @ViewBuilder
    private func findings(_ health: HealthScore) -> some View {
        let strengths = Array(health.strengths.prefix(3))
        let issues = Array(health.issues.prefix(3))
        if strengths.isEmpty && issues.isEmpty {
            Text(ShellCopy.scannedButFoundNone(.strengthsAndRisks))
                .font(Theme.Typo.narrative.font)
                .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                ForEach(strengths, id: \.self) { item in
                    findingRow(item, icon: .noRisk, role: Theme.Semantic.success)
                }
                ForEach(issues, id: \.self) { item in
                    findingRow(item, icon: .riskWarning, role: Theme.Semantic.warning)
                }
            }
        }
    }

    private func findingRow(_ text: String, icon: IconName, role: Theme.SemanticRole) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            ThemedIcon(icon, role: .inlineText, selected: true)
                .foregroundStyle(role.textColor)
            Text(text)
                .font(Theme.Typo.narrative.font)
                .lineLimit(1)
        }
    }
}

// MARK: - CPU 历史曲线

struct CPUHistoryChart: View {
    var snapshots: [SystemSnapshot]

    /// 时间轴刻度格式。**窗口不足 10 分钟时必须降到秒**：
    /// 实拍总览页出现 `03:57` 与 `03:57` 并排 —— 三个自动刻度落进同一分钟，
    /// 轴看起来像坏了，而它其实什么都没说错，只是分辨率不够。
    static func axisTimeFormat(span: TimeInterval) -> Date.FormatStyle {
        span < 600 ? .dateTime.hour().minute().second() : .dateTime.hour().minute()
    }

    private var timeDomain: ClosedRange<Date>? { ChartAxisEdge.domain(snapshots.map(\.timestamp)) }

    private var windowSpan: TimeInterval {
        guard let timeDomain else { return 0 }
        return max(0, timeDomain.upperBound.timeIntervalSince(timeDomain.lowerBound))
    }

    var body: some View {
        Chart(snapshots) { snapshot in
            AreaMark(
                x: .value("时间", snapshot.timestamp),
                y: .value("CPU", snapshot.cpuUsage * 100)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(ChartSeries.gradient())
            LineMark(
                x: .value("时间", snapshot.timestamp),
                y: .value("CPU", snapshot.cpuUsage * 100)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(ChartSeries.lineColor)
            .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.chartLine))
        }
        .chartYScale(domain: 0...100)
        // 这一张的轴没收窄（0...100 定值），加裁剪是**把规则钉死**而不是修当下的 bug：
        // `AreaMark` 一旦配收窄轴就会把填充画到绘图区外（见 ChartChrome 里那条注释），
        // 谁以后把这里改成自适应轴，不需要重新发现一遍这个坑。守卫：
        // `BorderlessSurfaceGuardTests.test_areaChartsClipTheirPlotArea`。
        .chartPlotStyle { $0.clipped() }
        .chartYAxis {
            // **必须显式 `.leading`**：SwiftUI 的默认是 `.automatic`，在这张图上落到**右边**，
            // 而性能/健康/日志/Git 四页的曲线全都显式写了 `.leading` ——
            // 于是同一个 App 里"纵轴一会儿在左一会儿在右"（实拍总览页 100/50/0 靠右）。
            // 守卫：`test_yAxisLabelsAllSitOnTheLeadingSide`。
            AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel().font(Theme.Typo.microLabel.font.monospacedDigit())
            }
        }
        .chartXAxis {
            // 步长走**与性能页同一把档位**（`ChartScale`），不再用 `.automatic(desiredCount: 3)`：
            // 自动档在首启那种十几秒的短窗口里只给两枚标签，且都挤在右半边
            // （交付头实拍量到中心在 47% 与 92%），左半段没有任何时间参照。
            // 刻度表也自己给（同一个 `ChartScale`）：`.stride` 会被 Charts 丢掉域下界那一枚。
            AxisMarks(values: ChartScale.secondsTicks(
                            domain: timeDomain,
                            strideSeconds: ChartScale.boundedSecondsStride(windowSeconds: windowSpan))
                      ) { value in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel(format: Self.axisTimeFormat(span: windowSpan),
                               anchor: ChartAxisEdge.anchor(for: value.as(Date.self), in: timeDomain))
                    .font(Theme.Typo.microLabel.font.monospacedDigit())
            }
        }
        .accessibilityLabel("CPU 占用历史曲线")
    }
}
