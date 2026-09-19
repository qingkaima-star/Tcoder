import SwiftUI

/// Tcoder 设计系统的**兼容转发层**。
///
/// 令牌与组件本身已经全部搬到 `Sources/TcoderMonitor/Design/**`：
///   - `Theme.Semantic` / `Theme.Palette` / `Theme.Typo` / `Theme.Spacing`
///     / `Theme.Radius` / `Theme.Stroke` / `Theme.Elevation` / `Theme.Layout` / `Theme.Chart`
///     → `Design/ThemeTokens.swift`、`Design/ColorToken.swift`
///   - `GlassCard` / `GlassSection` / `GlassToolbar` / `GlassButton` / `SemanticBadge`
///     → `Design/GlassComponents.swift`，闸门在 `Design/Glass.swift`
///   - `MetricTile` / `RiskBadge` / `SeverityBadge` / `MiniBarGauge`
///     / `EmptyStateView` / `ProgressOverlay` / `IconName` / `ThemedIcon`
///     （`SectionCard` 已在 #28 删除：41 处调用全部迁到 `GlassSection`，零引用后不留壳）
///     → `Design/SharedComponents.swift`、`Design/IconTokens.swift`
///
/// **下面这一层 `deprecated` 转发是临时桥**：九个页面此刻仍在被 WS-A/B/C 并行改写，
/// 一次性把 `Theme.accent` 这类入口抽掉会让他们的在途改动全线编译不过。
/// 总工的拆桥路径：各页重样时把旧名换成新语义名（IDE 的 deprecation 提示就是工单），
/// 全仓 `Theme\.(accent|healthy|caution|danger|critical|neutral|cardBackground|subtleBackground|gridLine|mono(Small|Body)|metricNumber|heroNumber|color\(for)` 归零后，
/// 删掉本文件里的 `// MARK: - 兼容转发` 整段即可，Design/** 不需要跟着改。
enum Theme {}

// MARK: - 兼容转发（临时桥，勿新增用法）

extension Theme {
    // 旧色彩入口 → 语义色的**文字层**。
    // 注意这是一次有意的观感变化：旧值是单档裸 RGB，深色模式下普遍不到 4.5:1；
    // 转发到 `text` 层之后，浅深两套都到达标线（见 DesignTokenTests）。
    @available(*, deprecated, message: "改用 Theme.Semantic.accent.textColor（交互层用 Color.accentColor）")
    static var accent: Color { Semantic.accent.textColor }

    @available(*, deprecated, message: "改用 Theme.Semantic.success.textColor")
    static var healthy: Color { Semantic.success.textColor }

    @available(*, deprecated, message: "改用 Theme.Semantic.warning.textColor")
    static var caution: Color { Semantic.warning.textColor }

    @available(*, deprecated, message: "改用 Theme.Semantic.danger.textColor")
    static var danger: Color { Semantic.danger.textColor }

    @available(*, deprecated, message: "改用 Theme.Semantic.critical.textColor")
    static var critical: Color { Semantic.critical.textColor }

    @available(*, deprecated, message: "改用 Theme.Semantic.neutral.textColor")
    static var neutral: Color { Semantic.neutral.textColor }

    @available(*, deprecated, message: "改用 Theme.Palette.Surface.card")
    static var cardBackground: Color { Palette.Surface.card }

    @available(*, deprecated, message: "改用 Theme.Palette.Surface.window")
    static var subtleBackground: Color { Palette.Surface.window }

    @available(*, deprecated, message: "改用 Theme.Palette.Surface.separator（内容卡已不再用描边分层）")
    static var gridLine: Color { Palette.Surface.separator }

    @available(*, deprecated, message: "改用 Theme.Semantic.role(for:).textColor")
    static func color(for risk: RiskLevel) -> Color {
        Semantic.role(for: risk).textColor
    }

    @available(*, deprecated, message: "改用 Theme.Semantic.role(forScore:)（已去蓝档、改单调；nil 走 neutral）")
    static func color(forScore score: Int) -> Color {
        Semantic.role(forScore: score).textColor
    }

    // 旧字号入口 → 排版令牌。`metricNumber` 26→28、`heroNumber` 48→40，
    // 并且两处都从 `.rounded` 退回 SF 默认 + monospacedDigit（WS-H §4.1）。
    @available(*, deprecated, message: "改用 Theme.Typo.monoSmall.font")
    static var monoSmall: Font { Typo.monoSmall.font }

    @available(*, deprecated, message: "改用 Theme.Typo.monoBody.font")
    static var monoBody: Font { Typo.monoBody.font }

    @available(*, deprecated, message: "改用 Theme.Typo.metricNumber.font")
    static var metricNumber: Font { Typo.metricNumber.font }

    @available(*, deprecated, message: "改用 Theme.Typo.heroMetric.font")
    static var heroNumber: Font { Typo.heroMetric.font }
}

// MARK: - 仍在使用的非设计工具

extension Color {
    /// 仅供 `Models` 里以字符串形式冻结的 `colorHex` 兜底解析。
    /// 视图层请走 `Theme.Semantic.role(for:)`，不要新写 `Color(hex:)`。
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = Double((value & 0xFF0000) >> 16) / 255
        let green = Double((value & 0x00FF00) >> 8) / 255
        let blue = Double(value & 0x0000FF) / 255
        self = Color(red: red, green: green, blue: blue)
    }
}

extension Double {
    var asPercentString: String { NumberFormat.percent(self, precision: 1) }
}
