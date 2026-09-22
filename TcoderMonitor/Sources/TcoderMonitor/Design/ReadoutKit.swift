import SwiftUI

// MARK: - 读数 / 占比 / 页面骨架
//
// 只保留**有真实调用方**的四件：`Readout.Field`(12) / `Readout.Bar`(2) /
// `Share.Row`(2) / `Page.Scaffold`(3)。#28 里删掉了 `Readout.Metric`（页面用 `DataReadout`，
// 41 处）、`Notice`（页面用 `DataNotice`）、`Sidebar.Item`（WS-K 自绘）、`Empty.Card`
// （WS-M 有 `HealthNotScoredCard`/`HealthNoInputCard`）——它们零引用，留着就是装饰。
//
// 上一轮的背景是：三条流不能改 Design，只能各自造，
// 结果同一个「标签 + 数字」在三页长出三种实现（WS-L `DataFieldRow`/`DataReadout`、
// WS-M `LiveNumber`、WS-K `StatLine`）。这里收成一套。
//
// ⚠️ 关于"缺证据必须中性"：#28 曾在这里配 `Theme.Evidence` 三态类型把它焊进类型，
// 因页面零引用已删。**#47 的正解不是重造我这版**，而是上提 WS-L 那份有活用户的
// `DataAbsence` —— 它现在住在 `Design/DataAbsence.swift`，四态（多一个「除零算不出」），
// 全仓 15 处手写占位写法已逐处换走，剩余处数由 `DesignAbsenceStateTests` 只减不增地把守。

// MARK: 键值读数

extension Theme {
    /// 一行「标签 + 值」读数。**标签占定宽、值紧跟左对齐**（与 `DataFieldRow` 同一份列宽），
    /// 一屏多行时值们竖向成列才可比。缺证据的值由调用方给 `DataAbsence` 字面。
    enum Readout {
        /// 键值行：标签列 + 值列。
        struct Field: View {
            var label: String
            var value: String
            var style: Style
            var role: Theme.SemanticRole?
            var help: String?
            /// 标签列宽。`nil` = 不占列、标签与值贴着排 —— 只给**卡头 trailing 位**这种
            /// "本身就一行、没有第二行可对齐"的场合；两行以上的键值区必须给列宽，
            /// 否则值与值对不上，就又退回 `label + Spacer + 值` 那个老形状。
            var labelWidth: CGFloat?

            enum Style {
                /// 等宽数字档（表格里读值）
                case number
                /// 11pt 等宽：函数名、文件名、依赖名
                case identifier
                /// 10pt 等宽小字：路径、SHA、邮箱
                case path
                /// 正文档：文字结论
                case text
            }

            init(_ label: String, _ value: String, style: Style = .number,
                 role: Theme.SemanticRole? = nil, help: String? = nil,
                 labelWidth: CGFloat? = Theme.Layout.fieldLabelWidthForLanguage) {
                self.label = label
                self.value = value
                self.style = style
                self.role = role
                self.help = help
                self.labelWidth = labelWidth
            }

            var body: some View {
                // **与 `DataFieldRow` 同一套两列几何**（标签定宽、值紧跟左对齐）。
                // 这里原来是 `label + Spacer + 值`：版框从 1040 收到 1240 之后，
                // 「上次 …………… 无记录」被拉到相距约 1500px，中间什么都没有 ——
                // 同一个毛病 H3 已经在 `DataFieldRow` 上治过一遍，而这是它的第二份实现。
                // 两份壳可以并存（字档不同），**列宽只能有一个来源**，所以走同一个令牌。
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(localizedCopy(label))
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        // `width: nil` 时 `frame(width:)` 就是"用固宽"，
                        // 所以定宽列与贴着排两种形态共用同一行代码。
                        .frame(width: labelWidth, alignment: .leading)
                    valueText
                        .themeHelp(help)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(minHeight: Theme.Layout.rowHeightCompact)
            }

            private var valueText: some View {
                groupFor(style)
                    .foregroundStyle(role?.textColor ?? Color.primary)
                    .lineLimit(1)
            }

            @ViewBuilder
            private func groupFor(_ style: Style) -> some View {
                switch style {
                case .number:
                    Text(localizedCopy(value)).font(Self.numberFont)
                case .identifier:
                    Text(localizedCopy(value)).font(Theme.Typo.monoLabel.font)
                case .path:
                    Text(localizedCopy(value)).font(Theme.Typo.monoSmall.font)
                        .truncationMode(.middle)   // 长路径要保住尾部目录名
                case .text:
                    Text(localizedCopy(value)).font(Theme.Typo.body.font)
                }
            }

            /// `label` 档 + 等宽数字。这一档不在 `Theme.Typo` 表里（它是"借字号换属性"的
            /// 组合），所以缓存只能落在本类型上：`static let` 一次，逐行读数不再现造 `Font`。
            private static let numberFont: Font = Theme.Typo.label.font.monospacedDigit()
        }

        // `Theme.Readout.Bar` 已删（零调用）：它内部自带 `.contentInset`，
        // 给一行键值读数画井。健康页两处重样时改成无面读数带之后没人用了。
        // 与 `DataReadoutBar` 同一个教训：零调用的井壳留着，就会被请回内容层。
    }

    /// 占比条行：名称 + 量条 + 百分比 + 次数。
    /// 取代《45》§3.3 判为重复的 `LanguageBar` / `ShareBarRow` 两套。
    /// 结构占比**不染色点**（风格契约 5：结构去色），要表意的用色由调用方显式传。
    enum Share {
        struct Row: View {
            var label: String
            var detail: String?
            var fraction: Double
            var percentText: String
            var countText: String?
            var color: Color
            var showSwatch: Bool
            var gaugeHeight: CGFloat

            init(label: String,
                 detail: String? = nil,
                 fraction: Double,
                 percentText: String,
                 countText: String? = nil,
                 color: Color,
                 showSwatch: Bool = true,
                 gaugeHeight: CGFloat = Theme.Layout.gaugeInline) {
                self.label = label
                self.detail = detail
                self.fraction = fraction
                self.percentText = percentText
                self.countText = countText
                self.color = color
                self.showSwatch = showSwatch
                self.gaugeHeight = gaugeHeight
            }

            /// 结构占比（语言名、作者名、生态名、文件名）——**数据块蓝、不染色点**。
            ///
            /// 这里翻过一次车，两次理由都记下来，免得第三次再翻：
            /// ① 最早按 key 稳定取 `Theme.Chart` 序列色 → 一个小区块里绿/棕/琥珀/红/蓝五色，
            ///    颜色被当成"区分序列"用，而名字就写在条的左边，那是装饰性用色（该删）；
            /// ② 收口时把它整体改成**纯墨**，理由是"最长的那根条自然成为视觉重点"——
            ///    但这正撞在风格契约 4 上：最重的墨只许给最大的数（52,832 那一级），
            ///    一根 1300pt 长的实心黑条比主读数还重，等于让数据块去抢主角。
            /// 现在的口径与 `ChartSeries.dataMarkColor` 的文档同源：**数据块蓝、结构灰墨**，
            /// 蓝不与数字争"最重"，又让条与文字/轨道/分隔线分层。
            /// 实拍证据：同一份语言占比，代码规模页（显式传 dataMarkColor）是蓝的，
            /// 总览页（走本默认）是黑的 —— 一个量两种颜色，就是本行以前那个默认造成的。
            /// 需要颜色表意的地方（风险 / 健康档 / 增删）仍由调用方显式传 `color:`。
            init(label: String, detail: String? = nil, fraction: Double,
                 percentText: String, countText: String? = nil) {
                self.init(label: label, detail: detail, fraction: fraction,
                          percentText: percentText, countText: countText,
                          color: ChartSeries.dataMarkColor,
                          showSwatch: false)
            }

            var body: some View {
                HStack(spacing: Theme.Spacing.xs) {
                    if showSwatch {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm / 2, style: .continuous)
                            .fill(color)
                            .frame(width: Theme.Layout.legendSwatchSide,
                                   height: Theme.Layout.legendSwatchSide)
                    }
                    Text(localizedCopy(label))
                        .font(Theme.Typo.label.font)
                        .lineLimit(1)
                        // 名称列定宽是**特性**（所有条从同一 x 起画，才能横向比长短），
                        // 但文件名这类尾部带扩展名的串按尾截会把 `.swift` 整段吃掉
                        // （错误日志页「受影响源文件」实测只剩 `PerfInvalid…`）。
                        // 中间截断保住头与尾，列宽与对齐都不动。
                        .truncationMode(.middle)
                        .frame(width: Theme.Layout.shareLabelWidth, alignment: .leading)
                    if let detail {
                        Text(detail)
                            .font(Theme.Typo.microLabel.font)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    MiniBarGauge(fraction: fraction, tint: color, height: gaugeHeight)
                    Text(percentText)
                        // 占比与次数是**测得值**：不等宽的话每 1.5 秒刷新一次就左右抖一次
                        // （`microLabel` 的 `monospacedDigits` 是 false，这里必须显式要）。
                        .font(Theme.Typo.microLabel.font.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Layout.sharePercentWidth, alignment: .trailing)
                    if let countText {
                        Text(countText)
                            .font(Theme.Typo.microLabel.font.monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .frame(width: Theme.Layout.shareCountWidth, alignment: .trailing)
                    }
                }
                .frame(minHeight: Theme.Layout.rowHeightCompact)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 数据密集型页面的**唯一**骨架：页边距 24 / 分组间 32 / 页级段落 40，
    /// 正文列在超宽屏上居中限宽。
    ///
    /// 限宽是规范要求的（WS-H §3.2）：否则 5K 屏上一行拉到两千多像素，
    /// 表格数字与名称之间的关系就断了。
    ///
    /// **本轮（M0→M1）把三档间距换成 `Spacing.pageMargin/group/section`**。
    /// 旧值是 `md`(16) 组间 + `md`(16) 页边距 + `xl`(24) 顶底 —— 而卡片**内部**条目间距
    /// 也是 12~16。组间与组内同一个数，正是 spec 根因⑤「间距没有呼吸档」的定量形态，
    /// 也就是「拥挤」的机械成因。
    ///
    /// 曾并存过三份同职责骨架（本件、`Views/CodeGit/CodeGitDesignKit.swift` 的
    /// `DataPageScaffold` 逐字复制品、WS-W 在 `Views/PerfLogs/BorderlessPage.swift` 的临时变体）。
    /// 后两份应删除并改回本件；`BorderlessPageGuardTests` 钉住「全仓只许一份页骨架」。
    enum Page {
        /// 页级 H1：**九页一致**，且一屏只有一个大标题。
        ///
        /// 原来只有性能/日志/评分三页自己手写过一份标题行（图标 + 20pt 标题 +
        /// 右侧控件 + 一行口径说明），另外六页直接从节标题起 ——
        /// 于是"页面层"这件事有三种状态；而那三页又叠在项目名的 20pt 之下，
        /// 一屏出现两个同级大标题（用户判词「不规整」在页级上的落点）。
        ///
        /// 层级重排照参考图：**项目名降成面包屑（11pt 元数据），节名升成唯一 H1**。
        /// 参考图顶部就是 `Workspaces / Sales` 一行小字，下面 `Accounting` 才是大标题。
        ///
        /// 这里曾挂过一枚「示例」徽标（`isDemo:` 参数）。批次 P7-A 随内置示例数据
        /// 一起删除：那套装置只覆盖 3/9 页，另外六页把同一批编造数字当真读数渲染，
        /// **标注机制本身成了假数据的遮羞布**。界面上不再存在"示例项目"，
        /// 于是也不再需要"这一屏是假的"这句话。
        struct Header<Actions: View>: View {
            var title: String
            var titleIcon: IconName?
            /// 口径声明的一句话（诚实性文案的落点，不许省）。
            var subtitle: String?
            @ViewBuilder var actions: Actions

            init(title: String,
                 icon: IconName? = nil,
                 subtitle: String? = nil,
                 @ViewBuilder actions: () -> Actions = { EmptyView() }) {
                self.title = title
                self.titleIcon = icon
                self.subtitle = subtitle
                // 存**结果**而不是闭包：与 `Scaffold.content` 同一个写法，
                // 把非逃逸的 builder 参数在 init 里就地求值，避免
                // "assigning non-escaping parameter to an @escaping closure"。
                self.actions = actions()
            }

            var body: some View {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                        if let titleIcon {
                            // 图标灰阶：颜色留给语义与交互，结构不抢注意力（风格契约 5）。
                            ThemedIcon(titleIcon, role: .navigation)
                                .foregroundStyle(.secondary)
                        }
                        // **必须是 `LocalizedStringKey`**：`title` 是 `String`，
                        // `Text(String)` 走的是 verbatim 初始化、**不查本地化表**，
                        // 于是目录里登记了英文也永远显示中文。这是双语最容易踩的空转：
                        // 机制接好了、表也翻了，界面上一个字都没变。
                        Text(LocalizedStringKey(title)).typed(Theme.Typo.pageTitle)
                        Spacer(minLength: Theme.Spacing.md)
                        actions
                    }
                    if let subtitle {
                        Text(localizedCopy(subtitle))
                            .typed(Theme.Typo.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }

        struct Scaffold<Content: View>: View {
            @ViewBuilder var content: Content

            /// **没有 `maxWidth` 参数是刻意的**：版框宽度全仓一个值，页面想跳也跳不了。
            /// 三档时代的切 tab 左右跳 100pt，就是「不规整」的来源（见 `Layout.maxWidthPage`）。
            init(@ViewBuilder content: () -> Content) {
                self.content = content()
            }

            /// 只在取证滚动那一趟用一次，之后不再干预。
            @State private var didScrollToTail = false

            var body: some View {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                            content
                        }
                        .frame(maxWidth: Theme.Layout.maxWidthPage, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.horizontal, Theme.Spacing.pageMargin)
                        // 页头之上与页尾各给一整段呼吸：这一档存在的意义就是
                        // 「页级段落 ≠ 分组间距」。`Spacing.section` 自定义起全仓零引用。
                        .padding(.top, Theme.Spacing.section)
                        .padding(.bottom, Theme.Spacing.section)
                        // 取证用的页尾锚点。**不设 `TCODER_CAPTURE_SCROLL` 时这个视图不存在**，
                        // 所以产品路径零改动（1pt 透明条也会参与布局，不能常驻）。
                        if CaptureScroll.scrollToTail {
                            Color.clear.frame(height: 1).id(CaptureScroll.tailID)
                        }
                    }
                    .scrollContentBackground(.hidden)
                    .task {
                        guard CaptureScroll.scrollToTail, !didScrollToTail else { return }
                        // 等一帧布局稳定再滚，否则 `scrollTo` 会按还没展开的高度算偏移。
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        proxy.scrollTo(CaptureScroll.tailID, anchor: .bottom)
                        didScrollToTail = true
                    }
                }
            }
        }
    }
}

extension View {
    /// 有 help 才挂 tooltip，避免给整表每个单元格塞一个空 help。
    @ViewBuilder
    func themeHelp(_ text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}
