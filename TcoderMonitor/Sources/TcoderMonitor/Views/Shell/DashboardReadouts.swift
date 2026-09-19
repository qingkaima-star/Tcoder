import Charts
import SwiftUI

/// 总览页专属尺寸。基座 `Theme.Layout` 里没有这些档，
/// 放这里是为了让 `DashboardView` 及其分件里不再流通裸数字（WS-I §2.6）。
enum DashboardLayout {
    /// 语言占比条的名称列。72 是「Objective-C」这类长名在一行内的下限。
    static let shareNameColumnWidth: CGFloat = 72
    /// 占比数字列。等宽数字 + 定宽，实时刷新时条形才不会左右晃。
    static let shareValueColumnWidth: CGFloat = 40
    /// hero 区评分环的原始尺寸。页面把它放进 `GlassCard` 里再自适应拉宽。
    static let heroRingWidth: CGFloat = 170
    static let heroRingHeight: CGFloat = 150
    /// hero 右侧结论区与环之间的间隙。
    static let heroGap: CGFloat = Theme.Spacing.sm
    /// 占比条厚度。WS-H §9 只给了两档：分量表 4、tile 内 5–6。
    static let gaugeHeight: CGFloat = 6
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
            Text(value)
                // 数字一律等宽：这是 WS-I §4 那条「全仓 monospacedDigit 命中 = 0」的根修法，
                // 一处改、56 个调用点全站生效。
                .font(Theme.Typo.label.font.weight(.semibold).monospacedDigit())
                .foregroundStyle(.primary)
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
        .bannerTintedSurface(style.role)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// 淡色提示底：语义**图形**色 × 统一一档透明度铺在 `Radius.md` 圆角矩形上，不叠描边。
    ///
    /// 内容层的分层靠材质 + 间距，不靠 1px 描边（WS-H §3.3），所以原来那圈
    /// `strokeBorder(color.opacity(0.3))` 去掉了。抽出来是为了让 `BannerRow` 与
    /// 总览的「可行动失败详情卡」共用同一份配方，而不是把同一段样式抄两遍。
    func bannerTintedSurface(_ role: Theme.SemanticRole) -> some View {
        background(role.graphicColor.opacity(Theme.Palette.Opacity.badgeFill),
                   in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
    }
}

// MARK: - 语言 / 占比条

struct LanguageBar: View {
    var share: LanguageShare

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            Text(share.language)
                .font(Theme.Typo.microLabel.font)
                .frame(width: DashboardLayout.shareNameColumnWidth, alignment: .leading)
                .lineLimit(1)
            MiniBarGauge(
                fraction: share.share,
                tint: Self.color(for: share.language),
                height: DashboardLayout.gaugeHeight
            )
            Text(NumberFormat.percent(share.share, precision: 0))
                .font(Theme.Typo.microLabel.font.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: DashboardLayout.shareValueColumnWidth, alignment: .trailing)
        }
    }

    /// 分类色取自全站唯一的一套图表色板（`Theme.Chart`），并且**必须稳定**。
    ///
    /// 旧写法是 `palette[abs(share.language.hashValue) % palette.count]`，而 Swift 的
    /// `hashValue` 每进程随机播种 —— 同一门语言每次启动换一个颜色（WS-I §2.1① 判为
    /// 设计缺陷，实际上是功能缺陷：色板失去了「同色=同语言」的表意能力）。
    /// FNV-1a 与 `ContributorsView` 里的做法一致；那份实现属 WS-L 文件，等总工把它下沉到
    /// `Design/` 后两处合并。
    static func color(for language: String) -> Color {
        Theme.Chart.color(at: stableIndex(language, count: Theme.Chart.count))
    }

    /// 稳定哈希取色位。纯函数，供单测钉住「同名同色、跨进程不变」。
    static func stableIndex(_ key: String, count: Int) -> Int {
        guard count > 0 else { return 0 }
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash % UInt64(count))
    }
}

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
            .foregroundStyle(Theme.Chart.areaGradient(at: 0))
            LineMark(
                x: .value("时间", snapshot.timestamp),
                y: .value("CPU", snapshot.cpuUsage * 100)
            )
            .interpolationMethod(.monotone)
            .foregroundStyle(Theme.Chart.color(at: 0))
            .lineStyle(StrokeStyle(lineWidth: Theme.Stroke.chartLine))
        }
        .chartYScale(domain: 0...100)
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
