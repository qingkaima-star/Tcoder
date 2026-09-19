import SwiftUI

// MARK: - 既有共享组件（从 App/Theme.swift 收编）
//
// 这些是各页当前真正在调用的组件，**初始化签名一律保持原样**，
// 这样基座换血时 11 个页面不需要同时改。内部实现已全部改走令牌与 `surface()`。

/// 给登记表之外的裸符号名套上同一套图标规则。
/// 存在是因为 `EmptyStateView` / `SectionCard` 的 `icon:` 参数至今收字符串
/// （`"doc.text"`、`"waveform"` 这类没进 `IconName` 的名字）；重样时应把它们收进登记表，
/// 届时这个口子可以关掉。
extension Image {
    func themeIcon(_ role: IconRole) -> some View {
        self.font(role.font)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }
}

/// 分区卡（旧入口）。玻璃化版本是 `GlassSection`，它多一个 `IconName` 参数；
/// 这个壳保留 `icon: String?` 以兼容现有调用点。
struct SectionCard<Content: View>: View {
    var title: String
    var subtitle: String?
    var icon: String?
    var trailing: AnyView?
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: String? = nil,
        trailing: AnyView? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        GlassCard(spacing: Theme.Spacing.sm) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let icon {
                            Image(systemName: icon)
                                .themeIcon(.cardHeader)
                                .foregroundStyle(Theme.Semantic.accent.textColor)
                        }
                        Text(title).font(Theme.Typo.cardTitle.font)
                    }
                    if let subtitle {
                        Text(subtitle)
                            .font(Theme.Typo.label.font)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: Theme.Spacing.xs)
                trailing
            }
            content
        }
    }
}

/// 指标 tile。紧凑档内边距 16、圆角 10（同心：外层卡 16 / 内层 tile 10）。
struct MetricTile: View {
    var label: String
    var value: String
    var unit: String?
    var caption: String?
    var tint: Color
    var systemImage: String?

    init(
        label: String,
        value: String,
        unit: String? = nil,
        caption: String? = nil,
        tint: Color = Theme.Semantic.accent.textColor,
        systemImage: String? = nil
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.caption = caption
        self.tint = tint
        self.systemImage = systemImage
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: Theme.Spacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .themeIcon(.badge)
                        .foregroundStyle(tint)
                }
                Text(label)
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                Text(value)
                    .font(Theme.Typo.metricNumber.font)
                    .foregroundStyle(tint)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                }
            }
            if let caption {
                Text(caption)
                    .font(Theme.Typo.label.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.tileHeightCompact,
               alignment: .leading)
        .surface(layer: .contentInset, shape: .rounded(Theme.Radius.md))
    }
}

/// 风险徽标。**色 + 文字 + 图标三通道**，不只靠颜色表意（WS-H §10）。
struct RiskBadge: View {
    var risk: RiskLevel
    var showIcon: Bool = true

    var body: some View {
        SemanticBadge(
            "风险 \(risk.rawValue)",
            role: Theme.Semantic.role(for: risk),
            icon: showIcon ? RiskBadge.icon(for: risk) : nil)
    }

    /// 分级符号按 WS-H §6.4：无=勾、低/中=三角、高/严重=八边形（更高警戒）。
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

    init(fraction: Double, tint: Color = Theme.Semantic.accent.graphicColor, height: CGFloat = 6) {
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
struct EmptyStateView: View {
    var icon: String = "tray"
    var title: String
    var message: String

    var body: some View {
        VStack(spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .themeIcon(.hero)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.Typo.cardTitle.font)
                .foregroundStyle(.secondary)
            Text(message)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .lineSpacing(Theme.Typo.label.lineSpacing)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.emptyMinHeight)
        .padding(Theme.Spacing.xl)
    }
}

/// 分析进行中的浮层。属控件层，所以是本页唯一一处真玻璃落点。
struct ProgressOverlay: View {
    var phase: AnalysisPhase
    var projectName: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("\(projectName) · \(phase.label)")
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .surface(layer: .chrome, shape: .capsule)
    }
}

extension AnalysisPhase {
    var label: String {
        switch self {
        case .idle: return "空闲"
        case .code: return "正在扫描代码规模…"
        case .git: return "正在分析 Git 历史…"
        case .logs: return "正在解析错误日志…"
        case .dependencies: return "正在检查依赖…"
        case .health: return "正在计算健康评分…"
        case .finished: return "分析完成"
        case .failed: return "分析失败"
        }
    }
}
