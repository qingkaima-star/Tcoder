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
    /// 脚注的「留短藏长」槽：屏上留 `caption` 那一句短的，长口径进 ⓘ。
    /// 有了它就不必把 44 字的口径整句塞进 `caption` —— 那个槽被 `reserveLines = 2`
    /// 钉着，长句撑开会歪掉同排四格的基线（`GitInsightsMetricGrid` 就为此单独设过
    /// `captionLineLimit: 2`）。画法仍复用全站唯一的 `CopyHelpBadge`。
    var captionHelp: String? = nil
    var tint: Color
    var systemImage: String?
    /// 量条槽。**位置是规则，不是选择**：量条属于数字，必须钉在值下面那一行，
    /// 同排四格才在同一条基线上。原来它由调用方叠在整枚 tile **之后**，
    /// 于是本格脚注一换行（两行口径）就把量条推下去约 20pt ——
    /// 实拍性能页：CPU 的条比内存低半格，磁盘/网络根本没有条，四格基线全断。
    var gauge: MetricGauge = .none
    /// 脚注行数上限。`nil` = **不截断**（默认，口径脚注丢掉一半等于丢掉可核对性）。
    /// 只有**数据摘要**才传数字：提交标题、路径这类长度由用户内容决定的串不是口径，
    /// 它撑成三行会把整条读数带的基线弄歪，截断 + tooltip 才是对的处理。
    var captionLineLimit: Int? = nil
    @Environment(\.tileCaptionReserve) private var tileCaptionReserve

    /// 量条槽的三种状态。`.empty` 是**占位等高**：同排有别的格子画条时，
    /// 没有可信分母的格子也要把那一行留出来（画一条假的满格线比不画更误导）。
    enum MetricGauge {
        case none
        case empty
        case value(Double, Color)
    }

    /// 窄态下读数与单位允许等比缩到的下限。
    ///
    /// 只有一个数、且写在**基座**里：散在各调用点的缩放系数会变成"每页缩得不一样"，
    /// 而那正是这轮要修的"同一档两种色"的横向版本。
    /// 0.8 的取法：`metricNumber` 那档缩到 0.8 之后仍明显大于脚注字号，
    /// 主次不丢；再低就开始与脚注糊成一片。
    static let metricNumberMinimumScale = 0.8

    init(
        label: String,
        value: String?,
        unit: String? = nil,
        caption: String? = nil,
        captionHelp: String? = nil,
        tint: Color = Theme.Palette.Surface.ink,
        systemImage: String? = nil,
        gauge: MetricGauge = .none,
        captionLineLimit: Int? = nil
    ) {
        self.label = label
        self.value = value
        self.unit = unit
        self.caption = caption
        self.captionHelp = captionHelp
        self.tint = tint
        self.systemImage = systemImage
        self.gauge = gauge
        self.captionLineLimit = captionLineLimit
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
                Text(localizedCopy(label))
                    .typed(Theme.Typo.groupLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                Text(Self.displayValue(value))
                    .font(Theme.Typo.metricNumber.font)
                    .foregroundStyle(Self.tint(value: value, fallback: tint))
                    .contentTransition(.numericText())
                    // **数字与单位不许从中间折行**。窄态（本 App 自己的 `minWidth` 1080）
                    // 实拍性能页：磁盘那格折成「128 MB/」+「s」，单位被劈开读起来像坏版，
                    // 内存那格把「GB」整块挤到第二行、与旁边的「/ 48.0 GB」错位。
                    // 装不下时**等比缩一档**而不是折行——缩了仍是一个数，劈开就是两个错。
                    .lineLimit(1)
                    .minimumScaleFactor(Self.metricNumberMinimumScale)
                if let unit {
                    Text(localizedCopy(unit))
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(Self.metricNumberMinimumScale)
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
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                    Text(localizedCopy(caption))

                    .font(Theme.Typo.label.font)
                    // 原来是 `.tertiary`：测得值不得用 tertiary。全仓 42 处 `.tertiary`
                    // 里落在数字上的那些，是「没有主次」在文字侧的另一半成因。
                    .foregroundStyle(.secondary)
                    // **口径脚注不许截断**：`lineLimit(2)` + 定高 72 让超两行的口径整段消失，
                    // 而 caption 装的正是"这个数字怎么量出来的"——丢掉它等于把可核对性丢掉。
                    // 与定宽表格格相反：格子里宁可截不可撑（撑了五列基线全断），
                    // 脚注宁可撑不可截（行高由条带里最高的那格决定，顶部对齐后数字仍同高）。
                    // 唯一的例外是 `captionLineLimit`：数据摘要不是口径。
                    .lineLimit(captionLineLimit)
                    .fixedSize(horizontal: false, vertical: true)
                    if let captionHelp {
                        CopyHelpBadge(captionHelp)
                    }
                }
            }
            // 没有脚注的格子也要把那块行位留出来，否则同排底边必然差一截。
            if caption == nil {
                Color.clear
                    .frame(height: TileCaptionLayout.minHeight(reserve: tileCaptionReserve))
                    .allowsHitTesting(false)
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

struct EmptyStateView: View {
    var icon: String = "tray"
    var title: String
    var message: String
    /// 空态自带的动作槽。**为什么要有它**：首屏空态原先只有一句说明，
    /// 唯一的入口在左侧引导卡里 —— 用户看得见说明、够不着按钮，
    /// 这正是"假的死页面"的一种。动作必须由空态自己带出来，
    /// 而不是让调用方在外面再套一个 VStack（套在外面会被下面的
    /// `minHeight: emptyMinHeight` 顶开，实拍里按钮落在文字下方 140pt 处）。
    var action: AnyView? = nil
    /// 空态自带的 ⓘ 说明槽（《碎文案收进 ⓘ》一轮补的）。
    ///
    /// **为什么必须做在组件里**：调用方若在 `EmptyStateView` 外面再套一层 `VStack`
    /// 去挂 `CopyHelpBadge`，会被下面的 `minHeight: emptyMinHeight` 顶开 ——
    /// 实拍里那枚问号会落在说明文字下方一大段空白处，等于没挂。
    /// 与 `action` 完全同一个理由。默认 `nil` 时产出 `EmptyView`，现有调用点一字不改。
    var help: String? = nil

    var body: some View {
        // **左对齐**。全站九页都是左基线，只有空态居中 —— 实拍里它是全 App 唯一的
        // 居中段落，浮在一整块空白正中，看起来像"没加载完"而不是"这里没有数据"。
        // 空态是一句陈述，不是一枚奖章，不需要被供在页面中间。
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            Image(systemName: icon)
                .themeIcon(.cardHeader)
                .foregroundStyle(.tertiary)
            Text(localizedCopy(title))
                .font(Theme.Typo.cardTitle.font)
                .foregroundStyle(.secondary)
            Text(localizedCopy(message))
                .font(Theme.Typo.label.font)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.leading)
                .lineSpacing(Theme.Typo.label.lineSpacing)
            if let help {
                // 走全站唯一的 ⓘ 画法（`Design/CopyHelp.swift`），不在这里自己拼问号。
                CopyHelpBadge(help)
            }
            if let action {
                // 与说明之间给一档组内间距，别贴着；它是这一块的收尾动作。
                action.padding(.top, Theme.Spacing.xs)
            }
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
    /// 已回来的分析路数（0…`ProgressOverlay.sectionTotal`）。
    /// **只有"几路回来了"是真可报的进度**：五路是 `async let` 并行跑的，
    /// 不存在"现在在做哪一路"这件事（批次 P7-C 删掉的就是那五档假顺序）。
    var completedSections: Int = ProgressOverlay.sectionTotal

    static let sectionTotal = 5

    /// 整句键 + 位置参数。`Text(String)` 与插值串都不查表，所以**必须**先本地化再拼。
    private var progressCopy: String {
        localizedFormat("已完成 %1$@/%2$@ 路",
                        String(max(0, min(completedSections, Self.sectionTotal))),
                        String(Self.sectionTotal))
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.xs) {
            ProgressView().controlSize(.small)
            Text("\(projectName) · \(localizedCopy(phase.label))")
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
                // 它挂在顶栏里，而项目名是用户自选目录名（可以 40 个字符）。
                // 不限宽就会把整条工具栏撑开、把右侧按钮推出窗口。
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 260, alignment: .leading)
                .help("\(projectName) · \(localizedCopy(phase.label))")
            if phase == .scanning {
                Text(localizedCopy(progressCopy))
                    .font(Theme.Typo.microLabel.font)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .help(localizedCopy("五路分析并行执行，这个数字是已经返回的路数，不是顺序进度"))
            }
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.xs)
        .surface(layer: .floating, shape: .capsule)
    }
}

extension AnalysisPhase {
    /// **返回的是键，不是成品句**：三个渲染点各自 `localizedCopy(...)` 之后再进 `Text`。
    /// 这里不能预先查表 —— `label` 在 `body` 之外求值时机会变（`help(_:)` 的参数是
    /// `String`，`Text(String)` 又不查表），一旦哪天有人在 init 里取一次存下来，
    /// 切换系统语言就不会再刷新这一行。
    var label: String {
        switch self {
        case .idle: return "空闲"
        case .scanning: return "正在并行分析五路指标…"
        case .finished: return "分析完成"
        case .failed: return "五路分析全部失败"
        }
    }
}
