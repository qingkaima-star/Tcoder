import SwiftUI

// MARK: - 既有共享组件（从 App/Theme.swift 收编）
//
// 这些是各页当前真正在调用的组件，**初始化签名一律保持原样**，
// 这样基座换血时 11 个页面不需要同时改。内部实现已全部改走令牌与 `surface()`。

// MARK: - 排版令牌的消费端入口
//
// `Theme.Typo` 只负责把规范里的数字变成有类型的常量（见 `ThemeTokens.swift`），
// 下面这个扩展负责**把它们完整地套上去**。

extension View {
    /// 一次性套上某个排版令牌的全部表现：字型、字距、行高。
    ///
    /// 为什么不直接写 `.font(token.font)`：`Font` **没有任何字距 API**
    /// （实测 `Font.kerning` 与 `Font.tracking` 都不存在，字距只在 `Text` / `View` 层）。
    /// 于是 `groupLabel` 那 0.6pt 字距一旦靠调用点自己补，就一定会被漏 ——
    /// 而无界面里字距是分区标题**唯一**的分组手段，漏掉它等于分组消失。
    /// 收成一个入口，是为了让"漏掉"这件事没有写法可以表达。
    ///
    /// 住在这个文件而不是单开 `Design/Typography.swift`：单开的纯扩展文件会被
    /// `SourceFileReachabilityTests` 判成「不声明顶层类型的匿名分片」而要求逐个取证，
    /// 为一个 30 行的修饰器去动全仓可达性普查的分母，代价大于收益。
    /// 这里已有 `Image.themeIcon` 这个同类先例。
    func typed(_ token: Theme.TypeToken) -> some View {
        self.font(token.font)
            .tracked(token.tracking)
            .spaced(token.lineSpacing)
    }

    @ViewBuilder
    private func tracked(_ tracking: CGFloat) -> some View {
        if tracking == 0 { self } else { self.tracking(tracking) }
    }

    @ViewBuilder
    private func spaced(_ lineSpacing: CGFloat) -> some View {
        if lineSpacing == 0 { self } else { self.lineSpacing(lineSpacing) }
    }
}

/// 给登记表之外的裸符号名套上同一套图标规则。
/// 存在是因为 `EmptyStateView` 的 `icon:` 参数至今收字符串（`"doc.text"`、`"waveform"`
/// 这类没进 `IconName` 的名字）；重样时应把它们收进登记表，届时这个口子可以关掉。
extension Image {
    func themeIcon(_ role: IconRole) -> some View {
        self.font(role.font)
            .symbolRenderingMode(.hierarchical)
            .accessibilityHidden(true)
    }
}

/// 指标读数。**它不再是一块面**（风格契约 1）：无背景、无描边、无投影。
///
/// 旧版是一块 `.contentInset` 灰盒（实测 `#E3E5E7`，比页面底暗 13 个 RGB 阶）且自带一份
/// 投影，全仓 29 处调用点 = 29 个灰盒 + 29 份投影。现在它只是三行文字：
/// `groupLabel`(10) 标签 / `metricNumber`(34) 纯墨数字 / `label`(11) 说明。
/// 横向排成一行时用 `ReadoutStrip`，列间发丝线替掉原来的盒体边界。
///
/// `value` 收 Optional（WS-I §3.4 的空态契约）：**"没查到" 必须渲染成 `--` + 中性色，
/// 不能渲染成 0**。0 是结论、`--` 是没证据，两者在监控类 App 里差一个事故。
/// 传 nil 时前景强制回 neutral，盖掉调用方给的 tint——因为"没数据"本身不该带任何倾向色。
struct MetricTile: View {
    var label: String
    var value: String?
    var unit: String?
    var caption: String?
    var tint: Color
    var systemImage: String?
    /// 量条槽。**位置是规则，不是选择**：量条属于数字，必须钉在值下面那一行，
    /// 同排四格才在同一条基线上。原来它由调用方叠在整枚 tile **之后**，
    /// 于是本格脚注一换行（两行口径）就把量条推下去约 20pt ——
    /// 实拍性能页：CPU 的条比内存低半格，磁盘/网络根本没有条，四格基线全断。
    var gauge: MetricGauge = .none

    /// 量条槽的三种状态。`.empty` 是**占位等高**：同排有别的格子画条时，
    /// 没有可信分母的格子也要把那一行留出来（画一条假的满格线比不画更误导）。
    enum MetricGauge {
        case none
        case empty
        case value(Double, Color)
    }

    init(
        label: String,
        value: String?,
        unit: String? = nil,
        caption: String? = nil,
        tint: Color = Theme.Palette.Surface.ink,
        systemImage: String? = nil,
        gauge: MetricGauge = .none
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.caption = caption
        self.tint = tint
        self.systemImage = systemImage
        self.gauge = gauge
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            HStack(spacing: Theme.Spacing.xxs) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .themeIcon(.badge)
                        // 图标不再吃倾向色：标签是结构，结构一律灰阶（风格契约 5）。
                        .foregroundStyle(Color.secondary)
                }
                Text(label)
                    .typed(Theme.Typo.groupLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                Text(Self.displayValue(value))
                    .font(Theme.Typo.metricNumber.font)
                    .foregroundStyle(Self.tint(value: value, fallback: tint))
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                }
            }
            // 量条钉在**值与脚注之间**，四格才共一条基线（见 `MetricGauge` 那段注释）。
            switch gauge {
            case .none:
                EmptyView()
            case .empty:
                Color.clear.frame(height: Theme.Layout.gaugeInline)
            case let .value(fraction, graphic):
                MiniBarGauge(fraction: fraction, tint: graphic,
                             height: Theme.Layout.gaugeInline)
            }
            if let caption {
                Text(caption)
                    .font(Theme.Typo.label.font)
                    // 原来是 `.tertiary`：测得值不得用 tertiary。全仓 42 处 `.tertiary`
                    // 里落在数字上的那些，是「没有主次」在文字侧的另一半成因。
                    .foregroundStyle(.secondary)
                    // **口径脚注不许截断**：`lineLimit(2)` + 定高 72 让超两行的口径整段消失，
                    // 而 caption 装的正是"这个数字怎么量出来的"——丢掉它等于把可核对性丢掉。
                    // 与定宽表格格相反：格子里宁可截不可撑（撑了五列基线全断），
                    // 脚注宁可撑不可截（行高由条带里最高的那格决定，顶部对齐后数字仍同高）。
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.tileHeightCompact,
               alignment: .leading)
    }

    /// 缺证据时的显示值。纯函数，供单测钉住。字面走全仓单点 `DataAbsence`（#47）。
    static func displayValue(_ raw: String?) -> String { DataAbsence.optional(raw).display }

    /// 无值时是否强制中性色（忽略调用方给的倾向色）。
    /// 单独抽成谓词是为了可测——`Color` 由动态 `NSColor` 包出来，两次取值不相等。
    static func forcesNeutralTint(for raw: String?) -> Bool { raw == nil }

    /// 有值用调用方给的**语义**倾向色，无值一律中性。
    ///
    /// 调用方请只传语义色（`success` / `warning` / `danger` / `critical`）。
    /// 把 `info` 或 `accent` 当数据色用是风格契约 5 禁止的 —— 旧
    /// `DashboardView.codeScaleCard` 把 `182,430` 涂成 `info` 蓝，
    /// 而蓝同时是链接与选中色，一个颜色两个意思。默认值现在是纯墨 `Surface.ink`。
    static func tint(value raw: String?, fallback: Color) -> Color {
        forcesNeutralTint(for: raw) ? Theme.Semantic.neutral.textColor : fallback
    }
}

/// 横向读数带：若干 `MetricTile` 排成一行，**无卡面**。
///
/// 存在理由：旧总览是四块 `.contentInset` 灰盒，每块自带一份投影。读数带把「分组」
/// 这件事交给发丝线与留白，一次去掉 4 个面 + 4 份投影，同时让 34pt 的纯墨数字
/// 成为这一行唯一的重音 —— 对标活动监视器的底栏排法。
///
/// 分隔线由**调用方**在 tile 之间插 `Divider()`（SwiftUI 的 `Divider` 在 `HStack`
/// 里画竖线）。不在这里自动插：各页 tile 数不同，自动插会让守卫数不出真实线数。
/// 读数带 / 列之间的**唯一竖线**画法（发丝宽 + 上下留一小截，不顶满格高）。
///
/// 原来全站有三种竖线：这一条、SwiftUI 的 `Divider()`、以及 `DataRowSeparator()`
/// 的横版 —— 同一件事三种画法，粗细与颜色各不相同，同屏两张表就能看出不一致。
/// 现在分工写死：**竖线用它，横线用 `DataRowSeparator()`，`Divider()` 只许留在
/// 系统菜单里**（守卫 `BorderlessSurfaceGuardTests.test_dividerIsConfinedToSystemMenus`）。
/// 从 `Views/CodeGit/` 上提到这里，是因为它服务的对象（`ReadoutStrip`）就在本文件。
/// 读数带列间分隔。**只能出现在 `DataReadoutBand` 里**。
struct DataBandSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.Surface.separator)
            .frame(width: Theme.Stroke.hairline)
            .padding(.vertical, Theme.Spacing.xxs)
            .accessibilityHidden(true)
    }
}

struct ReadoutStrip<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Spacing.lg) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 风险徽标。**色 + 文字 + 图标三通道**，不只靠颜色表意（WS-H §10）。
///
/// 分级符号按 WS-H §6.4：无=勾、低/中=三角、高/严重=八边形（更高警戒）。
/// ⚠️ 曾有过一个 `verified:` 入参用来把「没查」降级成问号徽标，#28 里删了：
/// 页面零调用，依赖页的诚实性实际由 `DependencySafetyVerdict` + `IconName.unverified` 承担。
/// 若哪天又要这条机制，别复活旧壳——按《42》「占位文本收敛清单」一次性把三态收进类型。
struct RiskBadge: View {
    var risk: RiskLevel
    var showIcon: Bool = true

    var body: some View {
        SemanticBadge(
            "风险 \(risk.rawValue)",
            role: Theme.Semantic.role(for: risk),
            icon: showIcon ? RiskBadge.icon(for: risk) : nil)
    }

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

    init(fraction: Double, tint: Color = Theme.Semantic.accent.graphicColor,
                height: CGFloat = Theme.Layout.gaugeMetric) {
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
/// **节级**空态：一行说明，不占版面。
///
/// 与 `EmptyStateView`（**页级**空态：图标 + 标题 + 解释 + 140pt 留白）的分工是刻意的：
/// 错误日志页实拍里，"没有可读的日志文件"这件事被说了四遍 —— 顶部横幅一遍、
/// 「错误概览」副标题一遍、「错误趋势」整块空态一遍、「高频错误」整块空态又一遍，
/// 每遍都带一枚大图标和 140pt 留白，于是页面看起来是坏的。
/// 页级空态负责"这一屏为什么没有内容 + 下一步做什么"，说一次；
/// 节级空态只负责"这一节因此画不出什么"，一行、`secondary`、不铺留白。
struct SectionEmptyNote: View {
    var text: String
    var icon: IconName = .info

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            ThemedIcon(icon, role: .badge)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(Theme.Typo.label.font)
                // `.secondary` 而不是 `.tertiary`：这是一句要读的说明，
                // 实拍里 tertiary 的 11pt 灰字几乎读不出（清单 3.11 的伴生问题）。
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

struct EmptyStateView: View {
    var icon: String = "tray"
    var title: String
    var message: String

    var body: some View {
        // **左对齐**。全站九页都是左基线，只有空态居中 —— 实拍里它是全 App 唯一的
        // 居中段落，浮在一整块空白正中，看起来像"没加载完"而不是"这里没有数据"。
        // 空态是一句陈述，不是一枚奖章，不需要被供在页面中间。
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .themeIcon(.cardHeader)
                .foregroundStyle(.tertiary)
            Text(title)
                .font(Theme.Typo.cardTitle.font)
                .foregroundStyle(.secondary)
            Text(message)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
                .lineSpacing(Theme.Typo.label.lineSpacing)
        }
        .frame(maxWidth: .infinity, minHeight: Theme.Layout.emptyMinHeight, alignment: .topLeading)
        .padding(Theme.Spacing.xl)
    }
}

/// 周期/档位选择器：一排纯文字，选中项加粗、取纯墨并画一条发丝下划线。
///
/// 为什么不用 `.pickerStyle(.segmented)`：它给选中项画一枚**灰底胶囊**，
/// 那是白底改造之后全站仅剩的一处"灰底选中"（错误日志页实拍），
/// 而且与钉死的绿色强调、与侧栏的实心选中态都对不齐 —— 同一件事第三种画法。
/// 参考图的周期选择器就是 `Week / Month / Quarter / Year` 一排字，
/// 靠字重与下划线表达选中，一个底色都不铺。
struct TextSegmentedPicker<Value: Hashable>: View {
    var options: [Value]
    var label: (Value) -> String
    var selection: Value
    var onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            ForEach(options, id: \.self) { option in
                let isOn = option == selection
                Button { onSelect(option) } label: {
                    Text(label(option))
                        .font(isOn ? Theme.Typo.label.font.weight(.semibold)
                                   : Theme.Typo.label.font)
                        .foregroundStyle(isOn ? Theme.Palette.Surface.ink : Color.secondary)
                        .padding(.bottom, Theme.Spacing.xxs)
                        .overlay(alignment: .bottom) {
                            if isOn {
                                Rectangle()
                                    .fill(Theme.Palette.Surface.ink)
                                    .frame(height: Theme.Stroke.hairline)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
        .accessibilityElement(children: .contain)
    }
}

/// 分析进行中的浮层。它悬在内容之上，所以是**全仓唯一**该带投影的东西（风格契约 6）。
struct ProgressOverlay: View {
    var phase: AnalysisPhase
    var projectName: String

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("\(projectName) · \(phase.label)")
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
                // 它挂在顶栏里，而项目名是用户自选目录名（可以 40 个字符）。
                // 不限宽就会把整条工具栏撑开、把右侧按钮推出窗口。
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
                .help("\(projectName) · \(phase.label)")
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .surface(layer: .floating, shape: .capsule)
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
