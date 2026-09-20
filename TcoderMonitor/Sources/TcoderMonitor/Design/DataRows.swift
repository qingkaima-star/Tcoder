import SwiftUI

// 本文件是 `Design/DataTable.swift` 的分片（WS-X7 规模债）。搬的理由是机械的：
// 宿主文件被本 App 自扫点名越过「巨大文件」线。**一个取值都没改**，搬的只是文件位置。
// 列定义、列宽表 `DataColumns`、`tableCell` 出口与**全仓唯一的列头**
// `DataTableHeader` 留在宿主文件——`TableHeaderConvergenceTests` 按那个文件名钉着
// 「列头组件全仓唯一且只有一个落点」。`DataRowMetrics` 搬到这里了，
// 列头与本页各行仍共用同一份行节奏，取的是同一个 `cellGap`。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名照旧。

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
                .frame(width: Theme.Layout.fieldLabelWidth, alignment: .leading)
            // 值**左对齐紧跟标签**，不再 `Spacer` 顶到行尾：
            // 一屏三行键值时，值们竖向成列才可比；拉到两端只剩一条条下划线。
            valueText
                .frame(maxWidth: .infinity, alignment: .leading)
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
///
/// 原为 `private`：列头 `DataTableHeader`（留在 `Design/DataTable.swift`）与本文件的
/// `DataFieldRow` 两头都要用它，`private` 在同模块跨文件不可见，故放宽到模块内
/// （本仓先例见 `BorderlessSurfaceGuardTests.isCode`、`ComplexityCounting.swift` 顶部）。
struct DataOptionalHelp: ViewModifier {
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
    /// **纯量词**（个 / 项 / 行 / 次 / 天）走这里，与数字同一行、小一档；
    /// 解释性口径才走 `caption` 落下一行。原来两者混用：依赖页上排把"项"丢到下一行，
    /// 而代码规模页的「110k 行」把"行"贴在数字右侧 —— 同一屏两种单位尺度（清单 3.12）。
    /// 声明顺序在 `role` 之前：Swift 的成员化初始化器要求实参按声明顺序传，
    /// 排在后面会让"带 role 的那几格"必须把 unit 写到最后，读起来别扭。
    var unit: String?
    var role: Theme.SemanticRole?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
            Text(label)
                .font(CodeGitType.readoutLabel)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .monospacedDigit()
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
                Text(value)
                    .font(CodeGitType.metric)
                    .foregroundStyle(role?.textColor ?? Color.primary)
                    .lineLimit(1)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(CodeGitType.prose(Theme.Typo.microLabel))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
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

// `DataReadoutBar` 已删（零调用）。它给一行聚合数字画了一口井，而契约 3 只许
// 表格/日志/代码块进井 —— 三页重样时把它们逐个"出井"之后，这个壳就再没人用了。
// 留着的风险不是占地方，是下一个人在新表上把它请回来，井又铺回内容层。

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
        // 与 `BannerRow` 同一份配方（原来这里自己铺了一层 15% 色底 = 第二种画法）。
        .bannerRuleSurface(role)
        .accessibilityElement(children: .combine)
    }
}
