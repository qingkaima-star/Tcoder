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

/// 表面所属的层。选错层是最容易犯的错：嵌在卡里的小分组要的是 `.content`（什么都不画）。
enum GlassLayer: Hashable {
    /// 卡片层（批次 P6，对齐 AiX）：**白面 + 16pt 圆角 + 发丝边 + 一层软影**。
    ///
    /// 为什么现在允许卡片有投影，而上一版把投影全删了：上一版的地面是纯白，
    /// 白纸上再压一张白纸当然只能靠"什么都不画"来分层；本轮地面换成 `#F7F7F7` 之后，
    /// 卡与画布是**两个面**，投影表达的就是"这张卡浮在画布上"。
    /// 参考图实测卡影 8% 黑 / 12pt 模糊 / y 偏移 2pt —— 一层，不许叠第二层。
    ///
    /// ⚠ 分层不能只靠色差：实测画布 `#F6F6F6` 对白卡只有 **1.085:1**，
    /// 低于人眼约 1.15:1 的分层阈值 —— 参考图那 3% 的差是靠边与影补的，
    /// 所以这一层里"边 + 影"是一体的，删掉任何一个都会退成"一整片白"。
    case card
    /// 内容层：**什么都不画**。卡内的分组、读数带靠它保持平铺。
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
    /// 除 `.card` 之外**唯一允许投影的层**（风格契约 6）。
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
        case .card:
            switch shape {
            case .rounded(let radius):
                cardSurface(in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            case .capsule:
                cardSurface(in: Capsule())
            }
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

    /// 卡片层：白面 + 发丝边 + **一层**软影。
    ///
    /// 画法上的两个刻意为之：
    /// ① 影挂在**背景形状**上而不是整棵视图上 —— 挂在外面会让卡里每一行文字也带一份
    ///   12pt 的黑影，实测就是"界面发脏"；
    /// ② 边与影同时存在。只有发丝边在灰画布上像描了个框，只有影则糊成一团；
    ///   参考图两者都有（边 `#EAEAEC` 0.5pt、影 8%/12/y2）。
    private func cardSurface<S: Shape & InsettableShape>(in shape: S) -> some View {
        background {
            shape.fill(Theme.Palette.Surface.card)
                .shadow(color: Theme.Palette.Card.shadowColor,
                        radius: Theme.Palette.Card.shadowRadius,
                        y: Theme.Palette.Card.shadowY)
            shape.strokeBorder(Theme.Palette.Card.hairline,
                               lineWidth: Theme.Palette.Card.hairlineWidth)
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

    /// 给 `Button` 挂样式。
    ///
    /// **主行动不再走 `.glassProminent`**：参考图把最高对比给了唯一的主动作（黑色胶囊 +
    /// 白字，实测 19.8:1），把彩色留给"选中/增量"这类状态；而系统 prominent 玻璃是
    /// 拿强调色当底，一个区域里出现两个按钮时它们一样响 —— 用户判词「没有主次」
    /// 在控件层的落点就是这个。三套系统同一画法，内容观感一致性顺带保住。
    @ViewBuilder
    func glassButtonStyle(_ kind: GlassButtonKind) -> some View {
        switch kind {
        case .prominent:
            self.buttonStyle(InkCapsuleButtonStyle())
        case .bordered:
            // **不再走系统 `.glass`**（2026-09-21 实拍量出来的）：非 key 窗口下它把标签
            // 压成 `#B6B6B6` 落在 `#FAFAFA` 上 = **1.94:1**，AA 文本线是 4.5:1 ——
            // 一个读不清的次级按钮等于没有这个按钮。自绘发丝胶囊顺带把
            // macOS 14/15/26 三套系统的次级按钮画法统一（与 `.prominent` 同一个理由）。
            self.buttonStyle(HairlineCapsuleButtonStyle())
        case .plain:
            if #available(macOS 26.0, *) { self.buttonStyle(.plain) }
            else { self.buttonStyle(PlainButtonStyle()) }
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

/// 主行动按钮：墨填充 + 反向前景的胶囊。前景不是审美选择而是实测结果——
/// 浅底 `#0A0A0A` 上放白字 19.8:1，深底 `#F2F2F5` 上放近黑墨 19.8:1，两版同分。
/// 旧的"强调色玻璃主按钮"之所以被换掉，是因为它和选中态、和另一个按钮同响。
struct InkCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, Theme.Spacing.xs)
            .background(Theme.Palette.Surface.inkFill, in: Capsule())
            .foregroundStyle(Theme.Palette.Surface.onInkFill)
            .opacity(configuration.isPressed ? 0.78 : 1)
    }
}

/// 次级按钮：卡面白底 + 发丝边 + **纯墨标签**。三套 macOS 同一画法。
///
/// 标签必须钉死成 `Surface.ink` 而不是继承系统前景 —— 这条样式存在的全部理由
/// 就是"继承来的那一份在失焦窗口里只有 1.94:1"。
struct HairlineCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, Theme.Spacing.sm)
            .padding(.vertical, Theme.Spacing.xs)
            .foregroundStyle(Theme.Palette.Surface.ink)
            .background {
                Capsule().fill(Theme.Palette.Surface.card)
                Capsule().strokeBorder(Theme.Palette.Card.hairline,
                                       lineWidth: Theme.Palette.Card.hairlineWidth)
            }
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
