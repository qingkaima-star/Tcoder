import SwiftUI

// MARK: - 基座组件
//
// 页面重样只需要这四个 + `Design/SharedComponents.swift` 里收编的既有组件。
// 本文件不出现 `#available`，也不出现 `glassEffect`：分层与闸门全在 `Glass.swift`。
//
// 默认值即规范：内容卡 `layer = .content`（标准材质、无玻璃、无描边）。
// 只有侧栏 / 工具条 / 按钮这类控件层才显式传 `.chrome`（WS-H §9）。

/// 内容卡基座。命名沿用任务要求的 `GlassCard`，但默认落在内容层——
/// 真玻璃要显式 `layer: .chrome`，这道门槛是故意的，防止内容区被玻璃糊成一片。
struct GlassCard<Content: View>: View {
    var layer: GlassLayer
    var radius: CGFloat
    var padding: CGFloat
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(
        layer: GlassLayer = .content,
        radius: CGFloat = Theme.Radius.card,
        padding: CGFloat = Theme.Spacing.cardPadding,
        spacing: CGFloat? = Theme.Spacing.sm,
        @ViewBuilder content: () -> Content
    ) {
        self.layer = layer
        self.radius = radius
        self.padding = padding
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(layer: layer, shape: .rounded(radius))
    }
}

/// 带标题行的分区卡——页面里绝大多数卡片的默认形态，也是 `SectionCard` 的继任者。
/// 同心圆角（WS-H §3.3）：外层 `Radius.card`(16)，内部 tile 用 `Radius.md`(10)。
struct GlassSection<Content: View>: View {
    var title: String
    var subtitle: String?
    var icon: IconName?
    /// 标题行右侧插槽。沿用 `SectionCard` 的 `AnyView?` 约定，
    /// 免得为泛型 trailing 一次性改动全部调用点。
    var trailing: AnyView?
    var padding: CGFloat
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: IconName? = nil,
        trailing: AnyView? = nil,
        padding: CGFloat = Theme.Spacing.cardPadding,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing
        self.padding = padding
        self.content = content()
    }

    var body: some View {
        GlassCard(padding: padding, spacing: Theme.Spacing.sm) {
            header
            content
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    if let icon {
                        ThemedIcon(icon, role: .cardHeader)
                            .foregroundStyle(Theme.Semantic.accent.textColor)
                    }
                    Text(title).font(Theme.Typo.cardTitle.font)
                }
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineSpacing(Theme.Typo.label.lineSpacing)
                }
            }
            Spacer(minLength: Theme.Spacing.xs)
            trailing
        }
    }
}

/// 工具条 / 操作行的玻璃胶囊。属控件层，真玻璃下由 `mergedGlassChrome` 归并折射。
struct GlassToolbar<Content: View>: View {
    var spacing: CGFloat
    @ViewBuilder var content: Content

    init(spacing: CGFloat = Theme.Spacing.xs, @ViewBuilder content: () -> Content) {
        self.spacing = spacing
        self.content = content()
    }

    var body: some View {
        mergedGlassChrome(spacing: spacing) {
            HStack(spacing: spacing) {
                content
            }
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .surface(layer: .chrome, shape: .capsule)
        }
    }
}

/// 主行动 / 次级 / 文字按钮。`prominent` 在 macOS 26 上直接吃系统的 `.glassProminent`。
struct GlassButton: View {
    typealias Style = GlassButtonKind

    var title: String
    var icon: IconName?
    var style: Style
    var isEnabled: Bool
    var action: () -> Void

    init(
        _ title: String,
        icon: IconName? = nil,
        style: Style = .bordered,
        isEnabled: Bool = true,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.style = style
        self.isEnabled = isEnabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xxs) {
                if let icon { ThemedIcon(icon, role: .inlineText) }
                Text(title).font(Theme.Typo.body.font)
            }
            .frame(minHeight: Theme.Layout.minHitTarget)
        }
        .buttonStyle(.plain)
        .glassButtonStyle(style)
        .controlSize(style == .prominent ? .large : .regular)
        .disabled(!isEnabled)
    }
}

/// 语义徽标（风险 / 严重度 / 状态）。WS-H §9：胶囊、`sm` 内边距、
/// 10pt Medium 文字、同色 0.15 半透明底，并且**色 + 文字双通道**（不只靠颜色表意）。
struct SemanticBadge: View {
    var text: String
    var role: Theme.SemanticRole
    var icon: IconName?

    init(_ text: String, role: Theme.SemanticRole, icon: IconName? = nil) {
        self.text = text
        self.role = role
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            // 双通道：图标承载语义，颜色只做加强，色觉障碍与灰度下仍然可读
            if let icon { ThemedIcon(icon, role: .badge) }
            Text(text)
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(role.textColor)
        }
        .padding(Theme.Spacing.chip)
        .background(role.badgeFill(), in: Capsule())
    }
}
