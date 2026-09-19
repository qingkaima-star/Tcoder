import SwiftUI

// MARK: - 表面与玻璃闸门（全仓唯一落点）
//
// 本文件是 **唯一** 允许出现 `glassEffect` 与 `#available(macOS 26.0, *)` 的地方。
// 页面只调 `GlassCard` / `GlassSection` / `GlassToolbar` / `GlassButton`。
// 将来收紧部署下限时，只需要改这一个文件。
//
// ── API 结论来自 `swiftc -typecheck` 编译探针（笔记 42），与《35 基线》有三处出入 ──
//   1. `glassEffect` 的参数类型是 **`Glass`**，不是基线里猜的 `GlassEffect`。
//      基线 §2 那条 ❌ 是类型名写错，不是 API 不存在：`Glass` 可以存进变量、可以链式修饰。
//   2. `Glass` 只有 `regular` / `identity` / `clear` 三个成员
//      （`.thin` / `.thick` / `.adaptive` / `.glossy` 探针均报 "has no member"）。
//   3. 基线没提的坑：`.containerBackground(.thinMaterial, for: .window)` 的 `.window`
//      **要 macOS 15**，在 `-target arm64-apple-macos14.0` 下直接编译失败。
//      它属于 Scene 配置（`App/TcoderMonitorApp.swift`，WS-G 无权改），已列为交总工的缺口。
//
// 实测 `if #available(macOS 26.0, *)` 包裹后，整套玻璃 API 在 macOS 14 目标下编译通过，
// 所以不需要、也不允许把 `Package.swift` 的 `.v14` 抬高。
//
// ── 分层规则（WS-H §9，Apple「Don't use Liquid Glass in the content layer」）──
//   内容层：标准材质 `.regularMaterial`，**不放玻璃、不加 1px 描边**，靠间距 + 同心圆角分层。
//           附带好处：内容层在 macOS 14/15/26 上长得一模一样，不存在第二种形态。
//   控件层：侧栏、工具条、按钮 —— 只有这里在 26 上吃真玻璃，更早系统退回 ultraThinMaterial。

/// 表面所属的层。选错层是最容易犯的错：内容卡要的是 `.content`。
enum GlassLayer: Hashable {
    /// 内容层：标准结构材质，跨系统一致，无玻璃、无描边。
    case content
    /// 内容层里的嵌入式紧凑面（指标 tile、内嵌小卡），比外层再压一档亮度。
    case contentInset
    /// 控件/导航层：macOS 26 真玻璃，更早系统材质 + 发丝描边兜底。
    case chrome
}

/// 表面形状。
enum GlassShape {
    case rounded(CGFloat)
    case capsule
}

/// 当前平台实际生效的控件层档位。诊断与单测用，页面不得据此散写分支。
enum GlassMode: Hashable, CaseIterable {
    case liquid
    case material

    var isLiquid: Bool { self == .liquid }
}

enum GlassEngine {
    static var mode: GlassMode {
        if #available(macOS 26.0, *) { return .liquid }
        return .material
    }
}

extension View {
    /// 加一层设计系统表面。
    ///
    /// 控件层的兜底分支不是"凑合能看"：旧系统上纯材质在浅/深两种外观下都会失去边界，
    /// 所以兜底额外加了顶缘高光（给材质方向性）和 1pt 发丝描边（把元素从窗口里拎出来）。
    @ViewBuilder
    func surface(
        layer: GlassLayer = .content,
        shape: GlassShape = .rounded(Theme.Radius.card)
    ) -> some View {
        switch layer {
        case .content:
            switch shape {
            case .rounded(let radius):
                materialLayer(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                              material: .regular, sheen: false, hairline: false, dimmed: false)
            case .capsule:
                materialLayer(shape: Capsule(), material: .regular,
                              sheen: false, hairline: false, dimmed: false)
            }
        case .contentInset:
            switch shape {
            case .rounded(let radius):
                materialLayer(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                              material: .regular, sheen: false, hairline: false, dimmed: true)
            case .capsule:
                materialLayer(shape: Capsule(), material: .regular,
                              sheen: false, hairline: false, dimmed: true)
            }
        case .chrome:
            if #available(macOS 26.0, *) {
                switch shape {
                case .rounded(let radius):
                    self.glassEffect(chromeGlass,
                                     in: .rect(cornerRadius: radius, style: .continuous))
                case .capsule:
                    self.glassEffect(chromeGlass, in: Capsule())
                }
            } else {
                switch shape {
                case .rounded(let radius):
                    materialLayer(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                                  material: .ultraThin, sheen: true, hairline: true, dimmed: false)
                case .capsule:
                    materialLayer(shape: Capsule(), material: .ultraThin,
                                  sheen: true, hairline: true, dimmed: false)
                }
            }
        }
    }

    /// 控件层玻璃装配。探针实测 `Glass` 可存储、`.tint` / `.interactive` 可链式，
    /// 将来要染色或让 chip 响应指针就在这里加参数，不要在页面加 `#available`。
    @available(macOS 26.0, *)
    private var chromeGlass: Glass { .regular }

    private func materialLayer<S: InsettableShape>(
        shape: S,
        material: Material,
        sheen: Bool,
        hairline: Bool,
        dimmed: Bool
    ) -> some View {
        background {
            shape
                .fill(material)
                .overlay(shape.fill(Color.primary.opacity(dimmed ? 0.03 : 0)))
                .overlay {
                    if sheen {
                        shape.fill(LinearGradient(
                            colors: [Color.white.opacity(0.14), Color.clear],
                            startPoint: .top, endPoint: .center))
                    }
                }
                .overlay {
                    if hairline {
                        shape.strokeBorder(Theme.Palette.Surface.separator,
                                           lineWidth: Theme.Stroke.separator)
                    }
                }
                .shadow(color: Theme.Elevation.card.shadowColor,
                        radius: Theme.Elevation.card.radius,
                        y: Theme.Elevation.card.yOffset)
        }
    }

    // MARK: 控件层玻璃按钮
    //
    // 玻璃按钮样式必须挂在 `Button` 站点上才生效（挂在 label 上会被系统忽略），
    // 所以这里提供 View 修饰器而不是 ButtonStyle 选择器，让 `#available` 仍只落在本文件。

    /// 给 `Button` 挂玻璃样式。真玻璃走系统的 `.glass` / `.glassProminent`。
    @ViewBuilder
    func glassButtonStyle(_ kind: GlassButtonKind) -> some View {
        if #available(macOS 26.0, *) {
            switch kind {
            case .prominent: self.buttonStyle(.glassProminent)
            case .bordered: self.buttonStyle(.glass)
            case .plain: self.buttonStyle(.plain)
            }
        } else {
            switch kind {
            case .prominent: self.buttonStyle(FallbackProminentButtonStyle())
            case .bordered: self.buttonStyle(FallbackBorderedButtonStyle())
            case .plain: self.buttonStyle(PlainButtonStyle())
            }
        }
    }
}

/// 玻璃归并容器：真玻璃下相邻控件由系统折射合并（[LG] 明确要求自定义玻璃用它归并），
/// 兜底下退化成原样透出、不改变布局。WS-H §9 要求控件层用它。
/// 写成自由函数而不是 `View` 静态成员：后者在调用点得写 `Self.mergedGlassChrome`，容易踩空。
@ViewBuilder
func mergedGlassChrome<Content: View>(
    spacing: CGFloat = Theme.Spacing.gutter,
    @ViewBuilder _ content: () -> Content
) -> some View {
    if #available(macOS 26.0, *) {
        GlassEffectContainer(spacing: spacing, content: content)
    } else {
        content()
    }
}

/// 玻璃按钮的三档语义。页面通过 `GlassButton(style:)` 间接使用。
enum GlassButtonKind: Hashable {
    /// 主行动：一个区域里最多一个
    case prominent
    /// 次级
    case bordered
    /// 弱化为文字按钮
    case plain
}

/// 兜底分支的主行动按钮：着色填充 + 由 `onFill` 择优出来的前景。
/// 前景色不是审美选择，是实测结果——蓝色填充上放白字只有 3.1:1，放近黑墨是 6.0:1。
struct FallbackProminentButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .background(
                Theme.Semantic.accent.graphicColor,
                in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
            .foregroundStyle(Theme.Semantic.accent.onFillColor)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

struct FallbackBorderedButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xxs)
            .surface(layer: .chrome, shape: .rounded(Theme.Radius.md))
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
