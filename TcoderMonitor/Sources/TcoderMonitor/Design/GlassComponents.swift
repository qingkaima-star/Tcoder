import SwiftUI

// MARK: - 基座组件
//
// 页面重样只需要这四个 + `Design/SharedComponents.swift` 里收编的既有组件。
// 本文件不出现 `#available`，也不出现 `glassEffect`：分层与闸门全在 `Glass.swift`。
//
// 默认值即规范：内容卡与分区默认落在 **`.card`**（白面 + 发丝边 + 一层软影，批次 P6 对齐 AiX）。
// 嵌在卡里的平铺分组显式传 `.content`；只有侧栏 / 工具条 / 按钮这类控件层才传 `.chrome`（WS-H §9）。

/// 内容卡基座。命名沿用任务要求的 `GlassCard`。
/// **批次 P6 起默认就是 `.card`**（白面 + 发丝边 + 一层软影）——
/// 参考图里"一块可独立读的信息 = 一张卡"，而 `GlassCard` 正是这个语义的载体。
/// 控件层要显式传 `.chrome`，嵌在卡里的平铺分组要显式传 `.content`。
struct GlassCard<Content: View>: View {
    var layer: GlassLayer
    var radius: CGFloat
    var padding: CGFloat
    var spacing: CGFloat?
    @ViewBuilder var content: Content

    init(
        layer: GlassLayer = .card,
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
/// **批次 P6 起它默认就是一张卡**（`layer: .card`）：地面换成 `#F7F7F7` 之后，
/// 参考图的语言是"有标题的块 = 白卡"，而九页里绝大多数块都有标题。
/// 默认值即规范 —— 40 处调用点一次到位，不需要逐页改。
/// 嵌在卡里的小分组要显式传 `layer: .content`（卡中卡是上一版"叠三层灰"的复发形态）。
///
/// 标题档随之从 `groupLabel`(10pt 字距小标) 升到 `cardTitle`(13pt semibold 纯墨)：
/// 无界面的时代它靠字距当唯一的分组手段；现在分组由卡面负责，
/// 标题就该读起来像标题。**口径说明、三态句式一个字没删**，只降/升排版层级。
struct GlassSection<Content: View>: View {
    var title: String
    var subtitle: String?
    var icon: IconName?
    /// 标题行右侧插槽用 `AnyView?` 而非泛型 trailing：
    /// 与页面自 `SectionCard` 时代起就传 `AnyView` 的调用点保持兼容（该壳已在 #28 删除）。
    var trailing: AnyView?
    var padding: CGFloat
    var layer: GlassLayer
    @ViewBuilder var content: Content

    init(
        _ title: String,
        subtitle: String? = nil,
        icon: IconName? = nil,
        trailing: AnyView? = nil,
        padding: CGFloat = Theme.Spacing.cardPadding,
        layer: GlassLayer = .card,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.trailing = trailing
        self.padding = padding
        self.layer = layer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            header
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(padding)
        .surface(layer: layer, shape: .rounded(Theme.Radius.card))
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xs) {
                        if let icon {
                            // 图标属结构，结构一律灰阶，蓝留给交互（风格契约 5）。
                            ThemedIcon(icon, role: .cardHeader)
                                .foregroundStyle(Color.secondary)
                        }
                        Text(localizedCopy(title))
                            .typed(Theme.Typo.cardTitle)
                            .foregroundStyle(Theme.Palette.Surface.ink)
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
            // 参考图每张卡的标题行下面都有一条发丝线把"说什么"与"说什么内容"分开。
            // 无面版没有这条线（那时标题就是唯一的边界）；现在卡面已经负责边界，
            // 这条线负责的是"标题行是一个整体、它不属于第一条数据"。
            if layer == .card {
                separator
            }
        }
    }

    private var separator: some View {
        Rectangle()
            .fill(Theme.Palette.Surface.separator)
            .frame(height: Theme.Stroke.hairline)
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
        // **这里不能再写 `.buttonStyle(.plain)`**（2026-09-21 实拍抓到）：
        // 同一条链上离 `Button` 最近的那个 style 赢，所以原先这行把
        // 后面 `glassButtonStyle(style)` 的三档全部压成 plain ——
        // 「主行动 = 墨填充胶囊」在界面上从来没出现过，
        // 用户判词「没有主次」「按钮跟参考图不一样」在控件层的真正落点就是这一行。
        // 三档各自的 style 由 `glassButtonStyle` 决定，其中 `.plain` 分支仍然给 plain。
        .glassButtonStyle(style)
        .controlSize(style == .prominent ? .large : .regular)
        .disabled(!isEnabled)
    }
}

/// 语义徽标（风险 / 严重度 / 状态）。WS-H §9：胶囊、`sm` 内边距、
/// 10pt Medium 文字、同色 0.15 半透明底，并且**色 + 文字双通道**（不只靠颜色表意）。
///
/// 它上面曾挂着全仓唯一的 `DemoBadge`（「示例」标记，`SemanticBadge("示例", .neutral)`）。
/// 批次 P7-A 随内置示例数据一起删除 —— 原因记在 `docs/功能真实性清单.md` 的 S1 条：
/// 那套标注只覆盖 3/9 页，另外六页把同一批编造数字当真读数渲染。
/// 这里曾经出现过"同一个标签在同一屏两个颜色"（侧栏绿、页头蓝），取 `neutral`
/// 的理由（语义留色、结构去色）仍然成立，只是这个特定的标签不再有存在的理由。
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
