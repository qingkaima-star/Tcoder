import SwiftUI

// MARK: - 读数 / 占比 / 提示 / 侧栏 / 页面骨架
//
// 只保留**有真实调用方**的三件：`Readout.Field`(12) / `Readout.Bar`(2) /
// `Share.Row`(2) / `Page.Scaffold`(3)。#28 里删掉了 `Readout.Metric`（页面用 `DataReadout`，
// 41 处）、`Notice`（页面用 `DataNotice`）、`Sidebar.Item`（WS-K 自绘）、`Empty.Card`
// （WS-M 有 `HealthNotScoredCard`/`HealthNoInputCard`）——它们零引用，留着就是装饰。
//
// 上一轮的背景是：三条流不能改 Design，只能各自造，
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
