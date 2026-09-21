import SwiftUI

// 本文件是 `Design/SharedComponents.swift` 的分片（WS-X8 实现文件规模闸门）。
// 搬的理由是机械的：本 App 自扫点名宿主文件越过「巨大文件」线
// （`FileSystemCodeAnalyzer.mediumFileLines` = 400 行），而这条口径现在由
// `SourcesSizeAuditTests` 机器把守。**一个取值、一处画法都没改**，搬的只是文件位置。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名照旧。

/// 横向读数带：若干 `MetricTile` 排成一行，**无卡面**。
///
/// 存在理由：旧总览是四块 `.contentInset` 灰盒，每块自带一份投影。读数带把「分组」
/// 这件事交给发丝线与留白，一次去掉 4 个面 + 4 份投影，同时让 34pt 的纯墨数字
/// 成为这一行唯一的重音 —— 对标活动监视器的底栏排法。
///
/// 分隔线由**调用方**在 tile 之间插 `Divider()`（SwiftUI 的 `Divider` 在 `HStack`
/// 里画竖线）。不在这里自动插：各页 tile 数不同，自动插会让守卫数不出真实线数。
/// 读数带 / 列之间的**唯一竖线**画法（发丝宽 + 上下留一小截，不顶满格高）。
///
/// 原来全站有三种竖线：这一条、SwiftUI 的 `Divider()`、以及 `DataRowSeparator()`
/// 的横版 —— 同一件事三种画法，粗细与颜色各不相同，同屏两张表就能看出不一致。
/// 现在分工写死：**竖线用它，横线用 `DataRowSeparator()`，`Divider()` 只许留在
/// 系统菜单里**（守卫 `BorderlessSurfaceGuardTests.test_dividerIsConfinedToSystemMenus`）。
/// 从 `Views/CodeGit/` 上提到这里，是因为它服务的对象（`ReadoutStrip`）就在本文件。
/// 读数带列间分隔。**只能出现在 `DataReadoutBand` 里**。
struct DataBandSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.Surface.separator)
            .frame(width: Theme.Stroke.hairline)
            .padding(.vertical, Theme.Spacing.xxs)
            .accessibilityHidden(true)
    }
}

/// 读数带内**脚注块预留的行数**。由 `ReadoutStrip` 注入，`MetricTile` 消费。
///
/// 两批实拍都点名"同排四格底边参差"：一格脚注一行、另一格两行，
/// 而 `HStack(alignment: .top)` 只保证顶边齐 ⇒ 底边必然不齐。
/// 正解**不是把长脚注截掉**（口径脚注截了就等于丢掉可核对性，§10.3 的红线），
/// 而是让每格的脚注块预留同样高的行位：一行时留白，两行时填满，底边自然齐。
private struct TileCaptionReserveKey: EnvironmentKey {
    static let defaultValue: Int? = nil
}

extension EnvironmentValues {
    var tileCaptionReserve: Int? {
        get { self[TileCaptionReserveKey.self] }
        set { self[TileCaptionReserveKey.self] = newValue }
    }
}

/// 读数带脚注块的统一行位。**两行**：一行是数据摘要的常态，第二行留给
/// 口径/单位这类必须完整显示的说明；要三行才说完的信息不该住在 KPI 带里
/// （该挪到节副标题或说明区）。
enum TileCaptionLayout {
    static let reserveLines = 2

    /// 预留高度按 `Theme.Typo.label` 的字号与中文行距算出来，不写魔法数。
    /// `reserve == nil` = 不在读数带里（独立使用），只保证自然高度，不预留。
    static func minHeight(reserve: Int?) -> CGFloat {
        guard let reserve else { return 0 }
        let lines = CGFloat(reserve)
        let tier = Theme.Typo.label
        return tier.size * lines + tier.lineSpacing * (lines - 1)
    }
}

struct ReadoutStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            content
        }
        .environment(\.tileCaptionReserve, TileCaptionLayout.reserveLines)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 风险徽标。**色 + 文字 + 图标三通道**，不只靠颜色表意（WS-H §10）。
///
/// 分级符号按 WS-H §6.4：无=勾、低/中=三角、高/严重=八边形（更高警戒）。
/// ⚠️ 曾有过一个 `verified:` 入参用来把「没查」降级成问号徽标，#28 里删了：
/// 页面零调用，依赖页的诚实性实际由 `DependencySafetyVerdict` + `IconName.unverified` 承担。
/// 若哪天又要这条机制，别复活旧壳——按《42》「占位文本收敛清单」一次性把三态收进类型。
struct RiskBadge: View {
    var risk: RiskLevel
    var showIcon: Bool = true

    var body: some View {
        // 运行时漏翻台账抓到：`"风险：\(risk.rawValue)"` 是**拼接串**，
        // 查表拿到的键是拼完的整串（`风险：高`），目录里对不上 ⇒ 英文态一片中文。
        // 正解是两段各自查表：模板走整句键，档位名走自己的键。
        SemanticBadge(
            localizedFormat("风险：%@", localizedCopy(risk.rawValue)),
            role: Theme.Semantic.role(for: risk),
            icon: showIcon ? RiskBadge.icon(for: risk) : nil)
    }

    static func icon(for risk: RiskLevel) -> IconName {
        switch risk {
        case .none: return .noRisk
        case .low, .medium: return .riskWarning
        case .high, .critical: return .riskSevere
        }
    }
}

/// 日志等级徽标。原来直读 `severity.colorHex`，现在走 `Theme.Semantic.role(for:)` 映射。
struct SeverityBadge: View {
    var severity: LogSeverity

    var body: some View {
        SemanticBadge(severity.rawValue,
                      role: Theme.Semantic.role(for: severity),
                      icon: SeverityBadge.icon(for: severity))
    }

    static func icon(for severity: LogSeverity) -> IconName {
        switch severity {
        case .fatal, .crash: return .crash
        case .error, .exception: return .riskSevere
        case .warning: return .riskWarning
        case .info: return .info
        case .trace, .debug: return .noRisk
        }
    }
}

/// 迷你胶囊量表：轨道用系统分隔色，前景用语义图形色。
/// 高度两档（WS-H §9）：分量表 4、tile 内 5–6，默认取 6。
struct MiniBarGauge: View {
    var fraction: Double
    var tint: Color
    var height: CGFloat

    init(fraction: Double, tint: Color = Theme.Semantic.accent.graphicColor,
                height: CGFloat = Theme.Layout.gaugeMetric) {
        self.fraction = fraction
        self.tint = tint
        self.height = height
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.Palette.Surface.separator)
                Capsule()
                    .fill(tint)
                    .frame(width: max(2, proxy.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: height)
    }
}

/// 空态。数据缺失时必须走这里，而不是显示 0 假装是真实结果。
/// **节级**空态：一行说明，不占版面。
///
/// 与 `EmptyStateView`（**页级**空态：图标 + 标题 + 解释 + 140pt 留白）的分工是刻意的：
/// 错误日志页实拍里，"没有可读的日志文件"这件事被说了四遍 —— 顶部横幅一遍、
/// 「错误概览」副标题一遍、「错误趋势」整块空态一遍、「高频错误」整块空态又一遍，
/// 每遍都带一枚大图标和 140pt 留白，于是页面看起来是坏的。
/// 页级空态负责"这一屏为什么没有内容 + 下一步做什么"，说一次；
/// 节级空态只负责"这一节因此画不出什么"，一行、`secondary`、不铺留白。
struct SectionEmptyNote: View {
    var text: String
    var icon: IconName = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            ThemedIcon(icon, role: .badge)
                .foregroundStyle(.tertiary)
            Text(localizedCopy(text))
                .font(Theme.Typo.label.font)
                // `.secondary` 而不是 `.tertiary`：这是一句要读的说明，
                // 实拍里 tertiary 的 11pt 灰字几乎读不出（清单 3.11 的伴生问题）。
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}
