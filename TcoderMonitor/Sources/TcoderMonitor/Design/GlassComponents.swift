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

/// 带标题行的分区——页面里绝大多数分区的默认形态（40 处在用）。
///
/// **它不再是一块面板**（风格契约 1/2）：不画背景、不描边、不投影。它的全部职责是
/// 「一个 `groupLabel` 小标题 + 内容 + 组间距」。
///
/// 旧实现内部套 `GlassCard(layer: .content)` = 一层 `.regularMaterial` 灰 + 一份投影，
/// 40 处调用点于是叠出「整个界面黑黢黢、很脏」的观感。
///
/// `padding` 默认值从 `Theme.Spacing.cardPadding` 改成 **0**：这 40 处里绝大多数
/// 不显式传，改默认值即一次性去掉卡内 24pt 内边距（无界面里内边距是给盒体用的，
/// 盒体没了它就没理由存在）。页面若确实要留内边距，显式传 `Theme.Spacing.cardPadding`。
struct GlassSection<Content: View>: View {
    var title: String
    var subtitle: String?
    var icon: IconName?
    /// 标题行右侧插槽用 `AnyView?` 而非泛型 trailing：
    /// 与页面自 `SectionCard` 时代起就传 `AnyView` 的调用点保持兼容（该壳已在 #28 删除）。
    var trailing: AnyView?
    var padding: CGFloat
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: IconName? = nil,
        trailing: AnyView? = nil,
        padding: CGFloat = 0,
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
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                HStack(spacing: Theme.Spacing.xs) {
                    if let icon {
                        // 原来是 `Theme.Semantic.accent.textColor`：图标属结构，
                        // 结构一律灰阶，蓝留给交互（风格契约 5）。
                        ThemedIcon(icon, role: .cardHeader)
                            .foregroundStyle(Color.secondary)
                    }
                    Text(localizedCopy(title))
                        .typed(Theme.Typo.groupLabel)
                        .foregroundStyle(.secondary)
                }
                if let subtitle {
                    Text(localizedCopy(subtitle))
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

/// 主行动 / 次级 / 文字按钮。`prominent` 三套系统同一画法：墨填充胶囊 + 反向前景
/// （见 `Glass.swift` 的 `InkCapsuleButtonStyle`），不再吃系统的 `.glassProminent`。
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
                Text(localizedCopy(title)).font(Theme.Typo.body.font)
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
/// 「示例」标记 —— 全仓唯一定义点。
///
/// 原来它在四处各写一遍，而且**两种颜色**：侧栏用 `accent`（绿）、三个页头用 `info`（蓝），
/// 于是同一个项目的同一个标签在同一屏上出现两个颜色（用户实拍：侧栏绿胶囊、页头蓝胶囊）。
/// 取 `neutral` 是判断不是省事：「这是示例数据」是关于数据来源的**事实**，
/// 不是状态（success/warning/danger 都不对），也不是交互（accent 现在专指选中/焦点）。
/// 语义留色、结构去色 —— 一个纯元数据标签就该是灰的。
struct DemoBadge: View {
    var body: some View {
        SemanticBadge("示例", role: Theme.Semantic.neutral)
    }
}

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
            Text(localizedCopy(text))
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(role.textColor)
        }
        .padding(Theme.Spacing.chip)
        .background(role.adaptiveBadgeFill, in: Capsule())
    }
}
