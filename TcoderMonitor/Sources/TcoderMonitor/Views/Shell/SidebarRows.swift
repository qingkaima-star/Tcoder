import SwiftUI

// 本文件是 `Views/Shell/ProjectSidebar.swift` 的分片（WS-X7 规模债）。
// 搬的理由是机械的：宿主文件被本 App 自扫点名越过「巨大文件」线。
// **一个取值都没改**，搬的只是文件位置：两枚都是「侧栏行内构件」，
// 宿主文件留下的是列表本体、引导卡、项目行与底栏——
// 它必须原地留着 `"selectedDetailSection"` 键名（九页取证靠它传页）、
// 右键菜单里那条 `Divider()`（`BorderlessSurfaceGuardTests` 的白名单是按路径给的）、
// 以及读数格的 `monospacedDigit` 写法（`ShellDesignTests` 按文件钉）。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名与全部注释照旧。


// MARK: - 视图行（九页导航的一行）

/// 侧栏里的一页。
///
/// 为什么是手动选中态而不是 `List(selection:)`：项目与页面是**两根选择轴**，
/// 一根绑定塞不下两个语义（选中页面会把当前项目选没）。代价是系统不替我画高亮，
/// 所以这里自己画一枚 accent 淡底 —— 但只有**实心淡底**这一件事，
/// 无描边、无投影（风格契约 6：全仓唯一一处投影在 `.floating`）。
struct AnalysisSectionRow: View {
    var section: DetailSection
    var isSelected: Bool
    /// false = 这一页要先扫一次才有数据。禁用而不是藏起来，
    /// 藏起来用户会以为这个功能不存在。
    var isEnabled: Bool
    var action: () -> Void

    /// 窗口活动状态。项目行走的是系统原生高亮（失焦自动退灰），导航行是手绘底色，
    /// 不跟着退就会出现「同一个侧栏，两种选中状态色」。
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        label
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(isEnabled ? section.title : ShellCopy.notAnalyzed(.thisProject))
    }

    /// 选中态必须能被读屏说出来。视觉上它是一枚淡底行，
    /// VoiceOver 拿不到这个差别；`.buttonStyle(.plain)` 又不自带选中语义。
    @ViewBuilder
    private var label: some View {
        let button = Button(action: action) { rowContent }
        if isSelected {
            button.accessibilityAddTraits(.isSelected)
        } else {
            button
        }
    }

    private var rowContent: some View {
        HStack(spacing: Theme.Spacing.xs) {
            // 变体表意：选中态换 fill 符号（WS-H §6.1 规则 3）。图标一律灰阶，
            // 蓝只留给交互（风格契约 5）。
            ThemedIcon(section.iconName, role: .badge, selected: isSelected)
            Text(localizedCopy(section.title))
                .font(Theme.Typo.body.font)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.xxs)
        }
        .foregroundStyle(isSelected ? selectionTextColor : Color.secondary)
        .padding(.horizontal, ShellLayout.rowPadding)
        .padding(.vertical, Theme.Spacing.xxs)
        .frame(maxWidth: .infinity, minHeight: ShellLayout.rowMinHeight, alignment: .leading)
        .background {
            if isSelected {
                // 与上面项目行的**原生**选中态同一种画法：圆角矩形 + 实心强调色 + 反色文字。
                // 这里原来是一枚满宽 `Capsule`，而原生那款是带内缩的圆角行 ——
                // 同一个侧栏里上下两段两种形状（满宽胶囊 vs 内缩圆角），
                // 用户实拍里一眼能看出「不规整」。
                // 窗口失焦时原生那款会退成灰，这里跟着退，否则又变成两种状态色。
                RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                    .fill(selectionFill)
                    .padding(.horizontal, Theme.Spacing.xxs)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous))
    }

    /// 选中底色的唯一来源：活动窗口用强调色，非活动退成中性灰（与系统原生高亮同步）。
    private var selectionFill: Color {
        activeState == .inactive
            ? Color(nsColor: .quaternaryLabelColor)
            : Theme.Semantic.accent.graphicColor
    }

    /// 反色文字**只在强调色底上成立**。底色退成中性灰时文字必须跟着退回纯墨：
    /// 白字压 `quaternaryLabelColor` 实测只有约 1.3:1 —— 实拍九页侧栏**每一页**的
    /// 当前页名都读不清，因为截图时窗口不是 key 窗口，选中态正是那枚灰底。
    private var selectionTextColor: Color {
        Self.usesReversedText(active: activeState)
            ? Theme.Semantic.accent.onFillColor : Theme.Palette.Surface.ink
    }

    /// 纯函数，供单测钉住（`Color` 由动态 `NSColor` 包出来，两次取值不相等，测不了）。
    /// `.key`（键盘驱动的活动态）与 `.active` 一样是强调色底，只有 `.inactive` 退灰。
    static func usesReversedText(active: ControlActiveState) -> Bool { active != .inactive }
}

/// 项目健康色点。**未评分必须是空心灰圈**，不能是红点。
///
/// 旧写法 `Theme.color(forScore: report?.health?.overall ?? 0)` 把「从没扫过」渲染成
/// `danger` 最危险的红，和同一行「未分析」的文字自相矛盾（WS-I §3.4 / WS-H §1.4#2 / WS-D #6
/// 三家都点到这一条）。着色走 `graphic` 层：色块是非文本图形，验收线 3:1，
/// 不必借用文字层那套加深的取值。
struct HealthDot: View {
    var score: Int?

    var body: some View {
        let role = Theme.Semantic.role(forScore: score)
        Circle()
            .fill(Self.kind(for: score) == .hollow ? Color.clear : role.graphicColor)
            .overlay {
                if Self.kind(for: score) == .hollow {
                    Circle().stroke(role.graphicColor, lineWidth: Theme.Stroke.emphasis)
                }
            }
            .frame(width: ShellLayout.statusDotDiameter, height: ShellLayout.statusDotDiameter)
            .accessibilityHidden(true)
    }

    /// 画法做成纯函数，供单测钉住「未评分不得出现实心着色点」这条诚实线
    /// （`MetricTile.displayValue` 用的是同一套路子）。
    static func kind(for score: Int?) -> DotKind {
        score == nil ? .hollow : .filled
    }

    enum DotKind: Hashable {
        case filled
        case hollow
    }
}
