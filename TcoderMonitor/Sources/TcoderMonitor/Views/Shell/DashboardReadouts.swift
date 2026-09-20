import Charts
import SwiftUI

/// 总览页专属尺寸。基座 `Theme.Layout` 里没有这些档，
/// 放这里是为了让 `DashboardView` 及其分件里不再流通裸数字（WS-I §2.6）。
///
/// 占比条的三档尺寸（名称列 / 百分比列 / 条厚）已随 `LanguageBar` 一起删除：
/// 基座 `Theme.Share.Row` 用 `Theme.Layout.shareLabelWidth` / `sharePercentWidth` /
/// `gaugeInline` 自己管，页面再留一份就是第二套真相。
enum DashboardLayout {
    /// hero 区评分环的原始尺寸。页面把它放进自适应行里再拉宽。
    /// `HealthView`（WS-M）也在用这一对，改动要同步那页。
    static let heroRingWidth: CGFloat = 170
    static let heroRingHeight: CGFloat = 150
    /// hero 右侧结论区与环之间的间隙。`sm`(12) → `lg`(20)：卡面撤掉之后，
    /// 环与文字之间没有边界替它们分家了，间隙就是唯一的组内分隔（风格契约 8）。
    static let heroGap: CGFloat = Theme.Spacing.lg
}

// MARK: - 统计读数行
//
// 全仓被引用 56 次、跨 WS-L / WS-M 九个页面，所以**入参签名不动**，只把实现换干净。
// 归属：`AGENTS.md` §4 把 `StatLine` 列为设计系统组件，但它一直住在 Dashboard 文件里
// （WS-I §3.5 判为归属错位）。基座 `Design/**` 不归本流所有，故先落到 `Views/Shell/**`
// ——同模块内换文件不破坏任何调用点，将来总工要下沉到 `Design/` 也只是再挪一次。

struct StatLine: View {
    var label: String
    var value: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            Text(value)
                // 数字一律等宽：这是 WS-I §4 那条「全仓 monospacedDigit 命中 = 0」的根修法，
                // 一处改、56 个调用点全站生效。
                // `lineLimit(1)` 同理由：这一格在实时读数旁边，值一旦折成两行，
                // 整行高度被撑开、把下面的脚注往下顶（`1.2 GB/s` 进位时真实发生过）。
                .font(Theme.Typo.label.font.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
                .lineLimit(1)
                .layoutPriority(1)   // 挤不下的时候宁可截标签，也不能截测得值
        }
    }
}

// MARK: - 横幅

enum BannerStyle {
    case warning, info, error

    /// 横幅是「图形 + 文字」，走 `graphic` 层（验收线 3:1），不借文字层那套加深取值。
    var role: Theme.SemanticRole {
        switch self {
        case .warning: return Theme.Semantic.warning
        case .info: return Theme.Semantic.info
        case .error: return Theme.Semantic.danger
        }
    }

    var color: Color { role.graphicColor }

    /// 符号从裸串换成登记表条目：警告=实心三角、错误=八边形（更高警戒，WS-H §6.4）。
    /// 原来 error 用 `xmark.octagon.fill`，与全站「关闭/移除」的 xmark 系混在一起。
    var icon: IconName {
        switch self {
        case .warning: return .riskWarning
        case .info: return .info
        case .error: return .riskSevere
        }
    }
}

struct BannerRow: View {
    var text: String
    var style: BannerStyle = .info

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.xs) {
            ThemedIcon(style.icon, role: .inlineText, selected: true)
                .foregroundStyle(style.role.textColor)
            Text(text)
                .font(Theme.Typo.narrative.font)
                .lineSpacing(Theme.Typo.narrative.lineSpacing)
                .foregroundStyle(.secondary)
            Spacer(minLength: Theme.Spacing.xs)
        }
        .padding(Theme.Spacing.sm)
        .bannerRuleSurface(style.role)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 提示条的表面画法：**左侧一道语义色竖标，不铺色底**。
    ///
    /// 原来这里是 `role.graphicColor.opacity(0.15)` 铺满整条 `Radius.md` 圆角矩形。
    /// 在纯白地面上，一块 1900×40pt 的淡色面是**全页最大的色块**，比它要强调的
    /// 主读数还显眼（用户实拍：Git 页蓝横幅、贡献者页粉横幅、错误日志页米黄横幅、
    /// 依赖页蓝横幅 —— 四页四块，颜色各不相同）。参考图里没有任何整幅色块，
    /// 语义只出现在小面积标记上。
    /// 竖标把彩色面积从约 76000pt² 压到约 80pt²（**降 99.9%**），语义色一个没丢：
    /// 色相仍然说"这是警告 / 提示 / 错误"，位置仍然把它钉在正文左边。
    ///
    /// 抽成一处是为了让 `BannerRow` 与 `DataNotice` 共用同一份配方 ——
    /// 它们本来就是同一个东西的两份实现（#34 之后仍未合并，是"同一件事两种画法"的活样本）。
    func bannerRuleSurface(_ role: Theme.SemanticRole) -> some View {
        overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: Theme.Stroke.emphasis / 2, style: .continuous)
                .fill(role.graphicColor)
                .frame(width: Theme.Stroke.emphasis)
                .padding(.vertical, Theme.Spacing.xs)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 语言 / 占比条
//
// 这里原本住着一份 `LanguageBar`（含自带的 FNV-1a `stableIndex`），已按 #28 / #32 删除：
// 占比条改走基座 `Theme.Share.Row`，取色走 `Theme.Chart.color(forLabel:)`。
// 留两份哈希的后果是「同名同色」只在单页内成立——`Swift` 与 `swift` 会分到不同号位，
// 中文名字也因 UTF-8 字节序 ≠ unicodeScalars 码点序而错位。

// MARK: - CPU 历史曲线

struct CPUHistoryChart: View {
    var snapshots: [SystemSnapshot]

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
            AxisMarks(values: [0, 50, 100]) { _ in
                AxisGridLine().foregroundStyle(Theme.Palette.Surface.separator)
                AxisValueLabel().font(Theme.Typo.microLabel.font.monospacedDigit())
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 3)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute(), centered: false)
                    .font(Theme.Typo.microLabel.font.monospacedDigit())
            }
        }
        .accessibilityLabel("CPU 占用历史曲线")
    }
}
