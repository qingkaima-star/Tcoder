import SwiftUI

// MARK: - 数据表基座（WS-L）
//
// 这五个页面全是数据密集型榜单，「看起来专业」与「看起来不专业」的差别基本就落在
// 列对齐、数字等宽、行高节奏这三件事上。本文件把它收成一处：
// 列宽与对齐只有这一张表能定义，表头与数据行从同一份 `DataGridColumn` 取布局。

// MARK: 列定义

enum DataGridColumnAlignment: Equatable {
    case leading
    case trailing

    var frameAlignment: Alignment {
        switch self {
        case .leading: return .leading
        case .trailing: return .trailing
        }
    }
}

/// 一列的布局。`width == nil` = 弹性列（名称列），其余一律定宽尾对齐。
struct DataGridColumn: Equatable {
    let title: String
    let width: CGFloat?
    let alignment: DataGridColumnAlignment

    init(_ title: String, _ width: CGFloat? = nil, _ alignment: DataGridColumnAlignment = .trailing) {
        self.title = title
        self.width = width
        self.alignment = alignment
    }
}

/// 全流唯一的列宽表。定宽的依据是**该列最宽内容的实测宽度**，不是手感：
/// 10pt 等宽数字 4 位约 24pt，加尾随单位「行」后取 56；徽标「仅版本比对」在 10pt
/// Medium 加 `Spacing.chip` 内边距后约 84pt。改数值请连同注释里的依据一起改。
enum DataColumns {
    /// 复杂度风险页 · 重复块清单
    static let duplicationBlocks: [DataGridColumn] = [
        DataGridColumn("重复块", nil, .leading),
        DataGridColumn("行数", 56),
        DataGridColumn("出现", 56),
        DataGridColumn("相似度", 64),
        DataGridColumn(" ", 24),
    ]

    /// 复杂度风险页 · 高复杂度函数榜
    static let complexityFunctions: [DataGridColumn] = [
        DataGridColumn("函数", nil, .leading),
        DataGridColumn("起始行", 56),
        DataGridColumn("行数", 56),
        DataGridColumn("圈复杂度", 62),
        DataGridColumn("参数", 44),
        DataGridColumn("风险", 92),
        DataGridColumn(" ", 24),
    ]

    /// 代码规模页 · 巨大文件榜。「相对体量」是与全仓最大文件的比值条，故定宽窄于数字列。
    static let hugeFiles: [DataGridColumn] = [
        DataGridColumn("文件", nil, .leading),
        DataGridColumn("相对体量", 64),
        DataGridColumn("行数", 62),
        DataGridColumn("风险", 92),
        DataGridColumn(" ", 24),
    ]

    /// 依赖分析页 · 依赖表
    static let dependencies: [DataGridColumn] = [
        DataGridColumn("依赖", nil, .leading),
        DataGridColumn("声明版本", 84),
        DataGridColumn("已知最新", 84),
        DataGridColumn("作用域", 60),
        DataGridColumn("状态", 96),
    ]

    /// Git 洞察页 · 最近提交
    static let recentCommits: [DataGridColumn] = [
        DataGridColumn("SHA", 66, .leading),
        DataGridColumn("提交说明", nil, .leading),
        DataGridColumn("文件", 48),
        DataGridColumn("增", 56),
        DataGridColumn("删", 56),
    ]

    /// 贡献者页 · 排行与占比条
    static let shareBar: [DataGridColumn] = [
        DataGridColumn("来源"),
        DataGridColumn("占比", 56),
        DataGridColumn("次数", 68),
    ]

    /// 图例色点边长。6 与 `Radius.sm` 同档，量级约等于 10pt 文字的大写字高——
    /// 再大就开始和文字抢注意力，再小在深色模式下几乎看不见。
    /// 名称列一律显式写 `.leading`：`DataGridColumn` 的默认对齐是尾对齐（数字列占多数），
    /// 弹性列漏写就会把表头拉到列右边。
    static let legendSwatchSide: CGFloat = Theme.Radius.sm

    /// 取列：越界时退回弹性列，免得调用方传错下标直接崩。
    static func column(_ columns: [DataGridColumn], _ index: Int) -> DataGridColumn {
        columns.indices.contains(index) ? columns[index] : DataGridColumn("")
    }
}

extension View {
    /// 把视图钉到某一列的布局上。表头与数据行都走这里，对齐不可能再各写各的。
    @ViewBuilder
    func tableCell(_ column: DataGridColumn) -> some View {
        if let width = column.width {
            frame(width: width, alignment: column.alignment.frameAlignment)
        } else {
            frame(maxWidth: .infinity, alignment: column.alignment.frameAlignment)
        }
    }
}

// MARK: 表头与分隔

struct DataTableHeader: View {
    let columns: [DataGridColumn]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(spacing: DataRowMetrics.cellGap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    Text(column.title)
                        .font(CodeGitType.prose(Theme.Typo.microLabel))
                        .foregroundStyle(.secondary)
                        .tableCell(DataColumns.column(columns, index))
                }
            }
            DataRowSeparator()
        }
        .padding(.top, Theme.Spacing.xxs)
    }
}

/// 行间分隔。内容卡不再用 1px 描边分层（WS-H §3.3），但**表格行之间确有分隔语义**，
/// 所以这里保留一条发丝线，用系统分隔色，深浅外观自动跟随。
struct DataRowSeparator: View {
    var body: some View {
        Rectangle()
            .fill(Theme.Palette.Surface.separator)
            .frame(height: Theme.Stroke.hairline)
    }
}

// MARK: 键值字段行

/// 一行一个字段：标签在左（次级色），值在右（等宽、尾对齐）。
///
/// 取代原先散在卡片里的 `HStack(spacing: 14) { StatLine; StatLine; Spacer }`——
/// 那种写法每个卡片的列间距、基线都不一样，读起来像手摆的。
struct DataFieldRow: View {
    enum ValueStyle {
        /// 数字 / 短结论：等宽尾对齐。
        case number
        /// 名称类正文：常规字面尾对齐。
        case text
        /// 路径 / URL / SHA：等宽窄体，中间省略且可选中复制。
        case path
    }

    let label: String
    let value: String
    var style: ValueStyle = .number
    var valueColor: Color?
    var help: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DataRowMetrics.cellGap) {
            Text(label)
                .font(CodeGitType.prose(Theme.Typo.label))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: Theme.Spacing.sm)
            valueText
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(DataOptionalHelp(help: help))
    }

    @ViewBuilder
    private var valueText: some View {
        let base = Text(value).monospacedDigit().foregroundStyle(valueColor ?? Color.primary)
        switch style {
        case .number:
            base.font(CodeGitType.metric)
        case .text:
            base.font(Theme.Typo.body.font.weight(.medium))
        case .path:
            base.font(CodeGitType.path)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// `.help` 在部分 macOS 版本对 `nil` 参数不友好，包一层只给非空时挂。
private struct DataOptionalHelp: ViewModifier {
    var help: String?

    func body(content: Content) -> some View {
        if let help {
            content.help(help)
        } else {
            content
        }
    }
}

// MARK: 读数条

/// 一行统计读数（WS-H §2.3 对标 Instruments 的读数条）：标签在上、数字在下，
/// 数字一律等宽尾随语义色。用于趋势图上方交代「峰值/均值/区间」这类聚合事实。
struct DataReadout: View {
    let label: String
    let value: String
    var caption: String?
    var role: Theme.SemanticRole?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(CodeGitType.readoutLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
            Text(value)
                .font(CodeGitType.metric)
                .foregroundStyle(role?.textColor ?? Color.primary)
                .lineLimit(1)
                .monospacedDigit()
            if let caption {
                Text(caption)
                    .font(CodeGitType.prose(Theme.Typo.microLabel))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 读数条容器：内嵌面，与外层内容卡形成同心圆角（外 16 / 内 10）。
struct DataReadoutBar<Content: View>: View {
    var spacing: CGFloat = Theme.Spacing.lg
    @ViewBuilder var content: Content

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

// MARK: 占比条

/// 一条占比：来源色点 + 名称 + 量条 + 百分比 + 次数。
///
/// 数字列宽全部取自 `DataColumns.shareBar`，与表头同源于本文件。
struct DataShareBarRow: View {
    let label: String
    let detail: String
    let fraction: Double
    let tint: Color
    var showSwatch: Bool = true
    var percentPrecision: Int = 1

    var body: some View {
        HStack(spacing: DataRowMetrics.cellGap) {
            HStack(spacing: Theme.Spacing.xs) {
                if showSwatch {
                    Circle()
                        .fill(tint)
                        .frame(width: DataColumns.legendSwatchSide,
                               height: DataColumns.legendSwatchSide)
                        .accessibilityHidden(true)
                }
                Text(label)
                    .font(CodeGitType.prose(Theme.Typo.label))
                    .lineLimit(1)
                    .truncationMode(.middle)
                MiniBarGauge(fraction: fraction, tint: tint, height: DataGaugeHeight.inline)
                    .frame(maxWidth: .infinity)
            }
            .tableCell(DataColumns.column(DataColumns.shareBar, 0))

            Text(NumberFormat.percent(fraction, precision: percentPrecision))
                .font(CodeGitType.number(Theme.Typo.microLabel))
                .foregroundStyle(.secondary)
                .tableCell(DataColumns.column(DataColumns.shareBar, 1))

            Text(detail)
                .font(CodeGitType.number(Theme.Typo.microLabel))
                .foregroundStyle(.tertiary)
                .tableCell(DataColumns.column(DataColumns.shareBar, 2))
        }
    }
}

// MARK: 行节奏

/// 榜单行的节奏。五页的表原本各写各的：Git 与依赖行是 `xxs`(4)、
/// 复杂度与重复块行是 `xs`(8) 再叠一层外层 `xxs`，同屏两张表的行高就差 4pt。
/// 这里收成一个来源，行高再也不会随页面漂移。
enum DataRowMetrics {
    /// 行内上下留白。
    static let verticalPadding: CGFloat = Theme.Spacing.xs
    /// 行与行之间（含分隔线两侧）的留白。
    static let rowGap: CGFloat = Theme.Spacing.xxs
    /// 单元格之间的横向间距。
    static let cellGap: CGFloat = Theme.Spacing.sm
    /// 单行榜单行的最小高度：可点区下限 20 + 一行沟槽 12。
    /// 有了下限，"只有名称的一行"和"名称+路径的两行"才不会把整张表拉成锯齿。
    static let minRowHeight: CGFloat = Theme.Layout.minHitTarget + Theme.Spacing.sm
}

/// 一行表格内容：统一上下留白、统一最小行高。
extension View {
    func dataTableRow() -> some View {
        self
            .padding(.vertical, DataRowMetrics.verticalPadding)
            .frame(maxWidth: .infinity, minHeight: DataRowMetrics.minRowHeight,
                   alignment: .leading)
    }
}

// MARK: 量表高度

/// `MiniBarGauge` 的两档高度（WS-H §9：分量表 4–5、tile 内 5–6）。
/// 收在一处，页面里就不再出现 `height: 5` / `height: 6` 这种各写各的漂移。
enum DataGaugeHeight {
    /// 占比条、行内量表。
    static let inline: CGFloat = 5
    /// 指标条里的主量表。
    static let metric: CGFloat = 6
}

// MARK: 行底色

/// 行级淡底色：比徽标底再弱一档，避免整屏表格被高饱和色块盖住。
/// 数值来自 `Opacity.badgeFill` 的一半，不是新造的魔法数。
enum CodeGitRowTint {
    static let alpha = Theme.Palette.Opacity.badgeFill / 2

    static func fill(_ role: Theme.SemanticRole) -> Color {
        role.graphicColor.opacity(alpha)
    }
}

// MARK: 提示条

/// 页面内的口径/告警提示条。取代冻结在 `DashboardView` 里的 `BannerRow`
/// （它自带 `.system(size: 12)` 图标、`cornerRadius: 8`、`opacity(0.10)/(0.30)` 描边，
/// 三处都是 WS-I §2.2/§2.5 点名的漂移值）。这里全部走令牌，并且**不加描边**：
/// 分层靠色底 + 间距，不靠 1pt 线（WS-H §3.3）。
struct DataNotice: View {
    let text: String
    var role: Theme.SemanticRole = Theme.Semantic.info
    var icon: IconName = .info
    /// 登记表尚未收录的符号走这个口子（取值一律来自 `CodeGitSymbol` 的命名常量）。
    var symbol: String?
    /// 图标紧邻已有文字时保持装饰性；纯图标动作才需要 label。
    var iconLabel: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            Group {
                if let symbol {
                    CodeGitSymbol.decorated(symbol, role: .inlineText)
                } else {
                    ThemedIcon(icon, role: .inlineText, label: iconLabel)
                }
            }
            .foregroundStyle(role.textColor)
            Text(text)
                .font(CodeGitType.prose(Theme.Typo.narrative))
                .lineSpacing(Theme.Typo.narrative.lineSpacing)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(role.badgeFill(), in: RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

