import SwiftUI

// MARK: - 读数 / 占比 / 提示 / 侧栏 / 页面骨架
//
// 都是"各页一定会要、基座却没有"的行级组件：上一轮之前三条流一边等基座一边自己造，
// 结果同一个「标签 + 数字」在三页长出三种实现（WS-L `DataFieldRow`/`DataReadout`、
// WS-M `LiveNumber`、WS-K `StatLine`）。这里给一套并集，并且把**缺证据必须中性**
// 焊进类型：要显示数字就得走 `Theme.Evidence`，拿不到"随手一个 String + 绿色"。

// MARK: 键值读数

extension Theme {
    /// 一行「标签 + 数字」读数。数字一律等宽右对齐，缺证据自动中性。
    enum Readout {
        /// 键值行：标签在左、值在右（表格里的路径/SHA/权重也用它）。
        struct Field: View {
            var label: String
            var value: String
            var style: Style
            var role: Theme.SemanticRole?
            var help: String?

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
                 role: Theme.SemanticRole? = nil, help: String? = nil) {
                self.label = label
                self.value = value
                self.style = style
                self.role = role
                self.help = help
            }

            var body: some View {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.sm) {
                    Text(label)
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: Theme.Spacing.xs)
                    valueText
                        .themeHelp(help)
                }
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
                    Text(value).font(Theme.Typo.label.font.monospacedDigit())
                case .identifier:
                    Text(value).font(Theme.Typo.monoLabel.font)
                case .path:
                    Text(value).font(Theme.Typo.monoSmall.font)
                        .truncationMode(.middle)   // 长路径要保住尾部目录名
                case .text:
                    Text(value).font(Theme.Typo.body.font)
                }
            }
        }

        /// 一行统计读数：标签在上、数字在下。用于趋势图上方交代峰值/均值/区间。
        /// `evidence` 收 `Theme.Evidence`：`nil` 值在这里根本表达不出来，
        /// 所以"没扫过"不可能被误写成 0 或绿色结论。
        struct Metric: View {
            var label: String
            var evidence: Theme.Evidence
            var unit: String?
            var caption: String?
            var role: Theme.SemanticRole
            var tier: Theme.TypeToken

            init(_ label: String,
                 evidence: Theme.Evidence,
                 unit: String? = nil,
                 caption: String? = nil,
                 role: Theme.SemanticRole = Theme.Semantic.neutral,
                 tier: Theme.TypeToken = Theme.Typo.metricMid) {
                self.label = label
                self.evidence = evidence
                self.unit = unit
                self.caption = caption
                self.role = role
                self.tier = tier
            }

            var body: some View {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    Text(label)
                        .font(Theme.Typo.label.font)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                        Text(evidence.displayText)
                            .font(tier.font)
                            .foregroundStyle(evidence.tint(role))
                            .contentTransition(.numericText())
                        if let unit {
                            Text(unit).font(Theme.Typo.microLabel.font).foregroundStyle(.secondary)
                        }
                    }
                    if let caption {
                        Text(caption)
                            .font(Theme.Typo.microLabel.font)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
            }
        }

        /// 读数条容器：内嵌面，与外层内容卡形成同心圆角（外 16 / 内 10）。
        struct Bar<Content: View>: View {
            var spacing: CGFloat
            @ViewBuilder var content: Content

            init(spacing: CGFloat = Theme.Spacing.lg, @ViewBuilder content: () -> Content) {
                self.spacing = spacing
                self.content = content()
            }

            var body: some View {
                HStack(alignment: .top, spacing: spacing) {
                    content
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .surface(layer: .contentInset, shape: .rounded(Theme.Radius.md))
            }
        }
    }

    /// 占比条行：色点 + 名称 + 量条 + 百分比 + 次数。
    /// 取代《45》§3.3 判为重复的 `LanguageBar` / `ShareBarRow` 两套。
    /// 色点与量条同色，色值只能来自 `Theme.Chart`（按稳定键或按登记号位）。
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

            /// 按稳定键取色（语言名、作者名、生态名）——同一键跨启动永远同色。
            init(label: String, detail: String? = nil, fraction: Double,
                 percentText: String, countText: String? = nil) {
                self.init(label: label, detail: detail, fraction: fraction,
                          percentText: percentText, countText: countText,
                          color: Theme.Chart.color(forLabel: label))
            }

            var body: some View {
                HStack(spacing: Theme.Spacing.xs) {
                    if showSwatch {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm / 2, style: .continuous)
                            .fill(color)
                            .frame(width: Theme.Layout.legendSwatchSide,
                                   height: Theme.Layout.legendSwatchSide)
                    }
                    Text(label)
                        .font(Theme.Typo.label.font)
                        .lineLimit(1)
                        .frame(width: Theme.Layout.shareLabelWidth, alignment: .leading)
                    if let detail {
                        Text(detail)
                            .font(Theme.Typo.microLabel.font)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                    MiniBarGauge(fraction: fraction, tint: color, height: gaugeHeight)
                    Text(percentText)
                        .font(Theme.Typo.microLabel.font)
                        .foregroundStyle(.secondary)
                        .frame(width: Theme.Layout.sharePercentWidth, alignment: .trailing)
                    if let countText {
                        Text(countText)
                            .font(Theme.Typo.microLabel.font)
                            .foregroundStyle(.tertiary)
                            .frame(width: Theme.Layout.shareCountWidth, alignment: .trailing)
                    }
                }
                .frame(minHeight: Theme.Layout.rowHeightCompact)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 页面内的口径 / 告警提示条。取代 `BannerRow`
    /// （它自带 `.system(size: 12)` 图标、`cornerRadius: 8`、`opacity(0.10)/(0.30)` 描边，
    /// 三处都是《45》§2.2/§2.5 点名的漂移值）。**不加描边**：分层靠色底 + 间距。
    enum Notice {
        struct Bar: View {
            var text: String
            var role: Theme.SemanticRole
            var icon: IconName
            var iconLabel: String?

            init(_ text: String, role: Theme.SemanticRole = Theme.Semantic.info,
                 icon: IconName = .info, iconLabel: String? = nil) {
                self.text = text
                self.role = role
                self.icon = icon
                self.iconLabel = iconLabel
            }

            var body: some View {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                    ThemedIcon(icon, role: .inlineText, label: iconLabel)
                        .foregroundStyle(role.textColor)
                    Text(text)
                        .font(Theme.Typo.narrative.font)
                        .monospacedDigit()
                        .lineSpacing(Theme.Typo.narrative.lineSpacing)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Theme.Spacing.md)
                .padding(.vertical, Theme.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(role.badgeFill(),
                            in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
                .accessibilityElement(children: .combine)
            }
        }

        /// 行内轻量口径标签：给曲线轴、表头这类位置补一句"这数字是怎么来的"。
        static func inline(_ text: String, role: Theme.SemanticRole = Theme.Semantic.info) -> some View {
            Text(text)
                .font(Theme.Typo.microLabel.font)
                .monospacedDigit()
                .foregroundStyle(role.textColor)
                .padding(.horizontal, Theme.Spacing.xxs)
                .background(role.badgeFill(), in: Capsule())
                .accessibilityLabel(text)
        }
    }

    /// 侧栏项目行。`HealthDot` 的三态是这里的诚实性关键：
    /// 没扫过的项目必须是**灰色空心圈**，不能是 0 分的实心红点
    /// （WS-I §3.4 点名的 `RootView:150` 缺陷）。
    enum Sidebar {
        struct Item: View {
            var title: String
            var subtitle: String?
            var icon: IconName
            var score: Int?
            var isScored: Bool
            var isSelected: Bool

            init(title: String, subtitle: String? = nil, icon: IconName,
                 score: Int?, isScored: Bool = true, isSelected: Bool = false) {
                self.title = title
                self.subtitle = subtitle
                self.icon = icon
                self.score = score
                self.isScored = isScored
                self.isSelected = isSelected
            }

            var body: some View {
                HStack(spacing: Theme.Spacing.xs) {
                    ThemedIcon(icon, role: .inlineText, selected: isSelected)
                        .foregroundStyle(isSelected ? Theme.Semantic.accent.textColor
                                                     : Theme.Semantic.neutral.textColor)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(title).font(Theme.Typo.body.font).lineLimit(1)
                        if let subtitle {
                            Text(subtitle)
                                .font(Theme.Typo.microLabel.font)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: Theme.Spacing.xs)
                    healthDot
                }
                .frame(minHeight: Theme.Layout.rowHeightSidebar)
                .contentShape(Rectangle())
                .accessibilityElement(children: .combine)
            }

            /// 未评分显示 `--`，**不显示 0**：0 分是结论，`--` 是没证据。
            var scoreText: String {
                isScored ? (score.map(String.init) ?? Theme.Placeholder.missingValue)
                          : Theme.Placeholder.missingValue
            }

            /// 三态：未评分=空心中性圈；有分=实心按单调色阶着色。
            @ViewBuilder
            private var healthDot: some View {
                let side: CGFloat = 10
                if !isScored {
                    Circle()
                        .strokeBorder(Theme.Semantic.neutral.graphicColor,
                                      lineWidth: Theme.Stroke.separator)
                        .frame(width: side, height: side)
                        .accessibilityLabel("尚未分析")
                } else {
                    let role = Theme.Semantic.role(forScore: score)
                    Circle()
                        .fill(role.graphicColor)
                        .frame(width: side, height: side)
                        .accessibilityLabel(isScored
                                            ? "健康评分 \(scoreText)"
                                            : "尚未分析，评分 \(scoreText)")
                }
            }
        }
    }

    /// 三态空态卡。与 `EmptyStateView`（"这里什么都没有"）的分工：这个组件负责说清
    /// **为什么没有**——没扫、还是扫过确实空。两者图标不同
    /// （`questionmark.circle` vs `tray`），前者绝不能画成对勾或绿色。
    enum Empty {
        struct Card: View {
            var evidence: Theme.Evidence
            var title: String
            var message: String?

            init(evidence: Theme.Evidence, title: String, message: String? = nil) {
                self.evidence = evidence
                self.title = title
                self.message = message
            }

            var icon: IconName {
                switch evidence {
                case .measured, .scannedEmpty: return .emptyTray
                case .notCollected: return .unverified       // 没查 = 问号，不是对勾
                }
            }

            var defaultCopy: String {
                switch evidence {
                case .measured: return "暂无内容"
                case .scannedEmpty: return Theme.Evidence.scannedEmptyCopy + "相关条目"
                case .notCollected: return "尚未分析，先运行一次扫描"
                }
            }

            var body: some View {
                VStack(spacing: Theme.Spacing.xs) {
                    ThemedIcon(icon, role: .hero)
                        .foregroundStyle(Theme.Semantic.neutral.graphicColor)
                    Text(title).font(Theme.Typo.cardTitle.font).foregroundStyle(.secondary)
                    Text(message ?? defaultCopy)
                        .font(Theme.Typo.label.font)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(Theme.Typo.label.lineSpacing)
                }
                .frame(maxWidth: .infinity, minHeight: Theme.Layout.emptyMinHeight)
                .padding(Theme.Spacing.xl)
                .accessibilityElement(children: .combine)
            }
        }
    }

    /// 数据密集型页面的统一骨架：左右 16、顶 24、卡与卡 16，正文列超宽屏居中限宽。
    /// 限宽是规范要求的（WS-H §3.2）：否则 5K 屏上一行拉到两千多像素，
    /// 表格数字与名称之间的关系就断了。
    enum Page {
        struct Scaffold<Content: View>: View {
            var maxWidth: CGFloat
            @ViewBuilder var content: Content

            init(maxWidth: CGFloat = Theme.Layout.maxWidthReading,
                 @ViewBuilder content: () -> Content) {
                self.maxWidth = maxWidth
                self.content = content()
            }

            var body: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                        content
                    }
                    .frame(maxWidth: maxWidth, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.horizontal, Theme.Spacing.md)
                    .padding(.top, Theme.Spacing.xl)
                    .padding(.bottom, Theme.Spacing.xl)
                }
                .scrollContentBackground(.hidden)
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
