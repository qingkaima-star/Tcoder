import SwiftUI

// MARK: - 页面切换（九页导航）
//
// `DetailSection` 的 `rawValue` 同时就是中文页名，并被 `@AppStorage("selectedDetailSection")`
// 持久化，所以 case 与取值都不动；本轮只换图标来源与呈现层。
//
// 图标一律走 `IconName` 登记表（WS-I §7.2 的工单：页面禁止裸符号串）。这修掉两处旧的语义漂移：
//   · 「复杂度风险」原来用 `exclamationmark.triangle.fill`，把风险徽标符号当成了页图标；
//     现在走 `IconName.complexity`（ƒ），三角留给真正的风险徽标。
//   · 「性能监控」原来借用 `IconName.pulse`（心电图），现在走登记表里的仪表符号，
//     macOS 14 上由 `IconAvailability` 自动退回心电图，不会画成空白。

enum DetailSection: String, CaseIterable, Identifiable, Sendable {
    case overview = "总览"
    case code = "代码规模"
    case risk = "复杂度风险"
    case git = "Git 洞察"
    case contributors = "贡献者"
    case performance = "性能监控"
    case logs = "错误日志"
    case dependencies = "依赖分析"
    case health = "健康评分"

    var id: String { rawValue }

    var title: String { rawValue }

    var iconName: IconName {
        switch self {
        case .overview: return .dashboard
        case .code: return .code
        case .risk: return .complexity
        case .git: return .git
        case .contributors: return .people
        case .performance: return .performance
        case .logs: return .logs
        case .dependencies: return .package
        case .health: return .health
        }
    }

    /// 性能页读的是实时采样，没有报告也能看；其余八页都要先扫一次。
    var requiresReport: Bool {
        switch self {
        case .overview, .code, .risk, .git, .contributors, .logs, .dependencies, .health: return true
        case .performance: return false
        }
    }

    /// 没有报告时把需要报告的页禁掉，而不是让用户点进一张空卡。
    /// 纯函数，供单测钉住「性能页永远可达、其余页要先扫」。
    func isReachable(reportAvailable: Bool) -> Bool {
        reportAvailable || !requiresReport
    }
}

// MARK: - 导航条

/// 九页切换条。属**控件层**，所以是全 App 第一处真玻璃落点。
/// 材质规则与侧栏项目行完全一致：未选中 = 内容层内嵌材质，选中 = 升到控件层吃
/// `.chrome`（macOS 26 系统玻璃，更早 = 材质 + 顶缘高光 + 发丝描边）。
/// 一排小胶囊像 Safari 标签栏，而不是九枚描边按钮——描边只留给需要强边界的地方。
struct SectionNavBar: View {
    @Binding var selection: DetailSection
    /// false = 还没有报告。需要报告的页在此时禁用，而不是让用户点进一张空卡。
    var reportAvailable: Bool

    var body: some View {
        // 用菜单「前往」或持久化恢复选中靠后的页时，必须把那一枚滚进视野——
        // 否则选中态在横向滚动区外，键盘与读屏用户会「选中了但看不见」。
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                mergedGlassChrome(spacing: Theme.Spacing.xxs) {
                    HStack(spacing: Theme.Spacing.xxs) {
                        ForEach(DetailSection.allCases) { section in
                            SectionNavChip(
                                section: section,
                                isSelected: section == selection,
                                isEnabled: section.isReachable(reportAvailable: reportAvailable)
                                    // 当前页永远保持可用态：把「正在看的一枚」画成禁用灰，
                                    // 读屏会念出「已禁用」而屏幕上它明明是选中的。
                                    || section == selection
                            ) {
                                withAnimation(.snappy) { selection = section }
                            }
                            .id(section)
                        }
                    }
                }
                // 玻璃/材质都带外投影，不上下留白会在滚动容器边缘被切出一道硬边。
                .padding(.vertical, Theme.Spacing.xxs)
            }
            .onChange(of: selection) { _, target in
                proxy.scrollTo(target, anchor: .center)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("页面切换")
    }
}

private struct SectionNavChip: View {
    var section: DetailSection
    var isSelected: Bool
    var isEnabled: Bool
    var action: () -> Void

    var body: some View {
        selectable
            .buttonStyle(.plain)
            .disabled(!isEnabled)
            .help(isEnabled ? section.title : ShellCopy.notAnalyzed("该项目"))
    }

    /// 选中态必须能被读屏说出来。视觉上它是一枚浮起的玻璃胶囊，
    /// VoiceOver 拿不到这个差别；`.buttonStyle(.plain)` 又不自带选中语义。
    /// 焦点环是否在 `.plain` 下保留，列进 §2 取证项，由九页截图那一轮目视确认。
    @ViewBuilder
    private var selectable: some View {
        let button = Button(action: action) { chipLabel }
        if isSelected {
            button.accessibilityAddTraits(.isSelected)
        } else {
            button
        }
    }

    @ViewBuilder
    private var chipLabel: some View {
        HStack(spacing: Theme.Spacing.xxs) {
            // 变体表意：选中态换 fill 符号（WS-H §6.1 规则 3）
            ThemedIcon(section.iconName, role: .badge, selected: isSelected)
            Text(section.title).font(Theme.Typo.label.font)
        }
        .foregroundStyle(isSelected ? Theme.Semantic.accent.textColor : Color.secondary)
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .frame(minHeight: Theme.Layout.minHitTarget)
        .contentShape(Capsule())
        // 第二轮（目视结论 3）：未选中不再是裸文字，而是和内容层一样的内嵌材质，
        // 选中才升到控件层吃玻璃——**与侧栏项目行、顶栏按钮同一条规则**，
        // 三处于是同一套材质语言，而不是导航条单独发明一种。
        .surface(layer: isSelected ? .chrome : .contentInset, shape: .capsule)
    }
}
