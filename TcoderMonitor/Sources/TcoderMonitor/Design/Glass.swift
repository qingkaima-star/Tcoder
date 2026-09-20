import SwiftUI

// MARK: - 表面与玻璃闸门（全仓唯一落点）
//
// 本文件是 **唯一** 允许出现 `glassEffect` 与 `#available(macOS 26.0, *)` 的地方。
// 页面只调 `GlassCard` / `GlassSection` / `GlassToolbar` / `GlassButton`，
// 或直接用 `View.surface(layer:shape:)`。
// 将来收紧部署下限时，只需要改这一个文件。
//
// ── API 结论来自 `swiftc -typecheck` 编译探针（笔记 42），与《35 基线》有三处出入 ──
//   1. `glassEffect` 的参数类型是 **`Glass`**，不是基线里猜的 `GlassEffect`。
//   2. `Glass` 只有 `regular` / `identity` / `clear` 三个成员。
//   3. `.containerBackground(…, for: .window)` 的 `.window` **要 macOS 15**，
//      属 Scene 配置（`App/TcoderMonitorApp.swift`），已列为交总工的缺口。
//
// ── 「简约无界」对本文件的重写（本轮 spec §2.1）──────────────────────────────
//
// 旧版把三个层都路由到同一个 `materialLayer`，于是有两处系统性错误：
//
//   ① 内容层填 `.regularMaterial`。材质背后无内容时在 macOS 上退化成一平涂半透明灰，
//      实测每一层都比窗口白底更暗：`#FFFFFF → 卡 #E9EBED → tile #E3E5E7`，
//      相邻只有 1.05–1.07:1，低于人眼约 1.15:1 的分层阈值。叠三层 = 「黑黢黢、很脏」。
//      正解不是"换个更淡的材质"，而是**内容层根本不画面**（风格契约 1/2）。
//
//   ② `.shadow` 挂在 `materialLayer` 的公共尾巴上，三个层都吃。40 处 `GlassSection`
//      + 29 处 `MetricTile` + 14 处显式 `surface()` 于是各带一份投影 = 「滥用投影」。
//      正解是把投影移进 `.floating` 专属分支，全仓唯一一处（风格契约 6）。
//
// 附带红利：内容层不再用材质后，**macOS 14 / 15 / 26 三套系统的内容观感完全一致**
// （原来不一致，材质在不同版本折射率不同）。真玻璃只留在控件层与浮层，
// 这正是 Apple「Adopting Liquid Glass」与 HIG Materials 要求的分层。

/// 表面所属的层。选错层是最容易犯的错：内容分组要的是 `.content`（什么都不画）。
enum GlassLayer: Hashable {
    /// 内容层：**什么都不画**。不填背景、不描边、不投影。
    ///
    /// 分组的边界交给两样东西：`Theme.Spacing.group`(32) 的留白，
    /// 与 `Theme.Typo.groupLabel`（10pt medium + 0.6pt 字距）这个安静的小标题。
    case content
    /// 井：内容层**唯一**允许的实心底，只给表格 / 日志列表 / 代码块这类
    /// 真有"内容嵌在里面"语义的东西（风格契约 3）。
    case contentInset
    /// 控件/导航层：macOS 26 真玻璃，更早系统实心 + 发丝描边兜底。**无投影**。
    case chrome
    /// 浮层：菜单、进度浮层这类悬在内容之上的东西。
    /// **全仓唯一允许投影的层**（风格契约 6）—— 投影表达的是"离开纸面"，
    /// 而一张平铺在纸上的卡片没有理由带投影。
    case floating
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
    @ViewBuilder
    func surface(
        layer: GlassLayer = .content,
        shape: GlassShape = .rounded(Theme.Radius.card)
    ) -> some View {
        switch layer {
        case .content:
            // 无面。这一行 `self` 就是本轮最重要的一处删除：它替掉了
            // 「材质灰 + 3% 压黑 + 一份投影」这一整套。
            self
        case .contentInset:
            switch shape {
            case .rounded(let radius):
                outlined(shape: RoundedRectangle(cornerRadius: radius, style: .continuous),
                         fill: Theme.Palette.Surface.well)
            case .capsule:
                outlined(shape: Capsule(), fill: Theme.Palette.Surface.well)
            }
        case .chrome:
            switch shape {
            case .rounded(let radius):
                chromeSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            case .capsule:
                chromeSurface(in: Capsule())
            }
        case .floating:
            switch shape {
            case .rounded(let radius):
                floatingSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            case .capsule:
                floatingSurface(in: Capsule())
            }
        }
    }

    /// 实心 + 发丝描边，**无投影**。井的画法。
    private func outlined<S: InsettableShape>(shape: S, fill: Color) -> some View {
        background {
            shape.fill(fill)
            shape.strokeBorder(Theme.Palette.Surface.separator,
                               lineWidth: Theme.Stroke.hairline)
        }
    }

    /// 控件层：26 上吃系统玻璃，更早系统退回实心 + 发丝描边。两个分支都**不带投影**。
    @ViewBuilder
    private func chromeSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(chromeGlass, in: shape)
        } else {
            outlined(shape: shape, fill: Theme.Palette.Surface.control)
        }
    }

    /// 浮层：控件层的画法 + 全仓唯一一处投影。
    ///
    /// 26 上系统玻璃自带折射与悬浮感，不需要额外投影；投影只加在兜底分支上，
    /// 因为那里没有玻璃，"离开纸面"这件事只能靠影子交代。
    @ViewBuilder
    private func floatingSurface<S: InsettableShape>(in shape: S) -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(chromeGlass, in: shape)
        } else {
            outlined(shape: shape, fill: Theme.Palette.Surface.control)
                .shadow(color: Theme.Elevation.overlay.shadowColor,
                        radius: Theme.Elevation.overlay.radius,
                        y: Theme.Elevation.overlay.yOffset)
        }
    }

    /// 控件层玻璃装配。探针实测 `Glass` 可存储、`.tint` / `.interactive` 可链式，
    /// 将来要染色或让 chip 响应指针就在这里加参数，不要在页面加 `#available`。
    @available(macOS 26.0, *)
    private var chromeGlass: Glass { .regular }

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
