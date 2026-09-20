import SwiftUI

// MARK: - 数据表基座（全仓唯一一套列系统，#34 收敛后由八个有表的页面共用）
//
// 这八个页面（代码规模 / 复杂度风险 / Git 洞察 / 贡献者 / 依赖 / 性能 / 日志 / 健康）
// 全是数据密集型榜单，「看起来专业」与「看起来不专业」的差别基本就落在
// 列对齐、数字等宽、行高节奏这三件事上。本文件把它收成一处：
// 列宽与对齐只有这一张表能定义，表头与数据行从同一份 `DataGridColumn` 取布局。
//
// **为什么是这一套活下来**：`Design/TableKit.swift` 里的基座件 `Theme.Table`（零调用）
// 已在 `ed58dd5` 被 WS-G #28 删除，删除理由写明它是「与页面既有两套不兼容的第三条路」，
// 而它自己那份并集形状就是照本文件的 `DataGridColumn` 抄的（见该文件被删前的头注释）。
// 同一提交里另一套是 WS-M 的 `TableHeaderCell`（逐格手写 + `Grid`），它把列宽写成标量常量、
// 表头与行的对齐各写一次，正是 #34 要消灭的第二次发散。故本轮把三页迁到本套、删掉那一套。
//
// 页面侧用法（八页一致，共 11 处列头）：`static let columns: [DataGridColumn]` → 表头 `DataTableHeader(columns:)`
// → 行内每格 `.tableCell(DataColumns.column(Self.columns, i))`。
// 不要在本文件之外再写第二个「表头长什么样」的定义。

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
/// `help` 只被**列头**消费（整列口径说明，悬停在列名上）；逐行变化的口径仍由页面
/// 自己挂在单元格上，不要塞进列定义——列头是整列静态文案，写不得只对部分行成立的原因
/// （`HealthBreakdown.weightColumnHelp` 这条就是被 #32 纠正过一次）。
struct DataGridColumn: Equatable {
    let title: String
    let width: CGFloat?
    let alignment: DataGridColumnAlignment
    let help: String?

    init(_ title: String, _ width: CGFloat? = nil,
         _ alignment: DataGridColumnAlignment? = nil, help: String? = nil) {
        self.title = title
        self.width = width
        // **弹性列（无定宽）= 名称列 = 一律左对齐**，这个规则收在构造点。
        // 原来默认对齐是尾对齐（数字列占多数），名称列漏写 `.leading` 就会把表头拉到
        // 列右边 —— 代码规模页「来源」、贡献者页「来源」、Git 洞察页「目录」三张表
        // 各现形一次，而同文件注释早就写了"名称列一律显式写 .leading"：
        // 一条只能靠记性的规则就是没有规则。显式传入仍然优先。
        self.alignment = alignment ?? (width == nil ? .leading : .trailing)
        self.help = help
    }
}

/// 全仓唯一的列宽表（#34 之后八页共用，原先 WS-M 那 14 个标量常量并到下面来了）。
/// 定宽的依据是**该列最宽可信读数的实测宽度**，不是手感：
/// 10pt 等宽数字 4 位约 24pt，加尾随单位「行」后取 56；徽标「仅版本比对」在 10pt
/// Medium 加 `Spacing.chip` 内边距后约 84pt；内存列要放得下 `123.4 GB`、
/// 打开文件列要放得下 `12,345`。改数值请连同注释里的依据一起改。
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

    // MARK: #34 迁入的三页（原 WS-M `TableHeaderCell` + `DataColumn` 标量常量那套）

    /// 性能页 · 进程占用排行。列名与列序与迁移前逐字相同（`TableHeaderConvergenceTests`
    /// 拿这份快照做断言，改动必须是有意识的）。
    static let processes: [DataGridColumn] = [
        DataGridColumn("进程名称", nil, .leading),
        DataGridColumn("PID", 52, help: "进程号，只读展示"),
        DataGridColumn("CPU 核", 62, help: "单核等价：1.00 = 占满一个核心，可大于 1"),
        DataGridColumn("内存", 76, help: "常驻内存 RSS"),
        DataGridColumn("线程", 50, help: "task_info 返回的线程数"),
        DataGridColumn("打开文件", 66, help: "进程当前持有的描述符数量"),
    ]

    /// 日志页 · 已扫描文件。
    static let scannedLogFiles: [DataGridColumn] = [
        DataGridColumn("类型", 76, .leading),
        DataGridColumn("文件", nil, .leading),
        DataGridColumn("大小", 72, help: "文件字节数（1024 进制）"),
        DataGridColumn("行数", 78),
        DataGridColumn("修改", 78),
    ]

    /// 健康页 · 维度分量。得分列是「量表 + 数字」两截拼的复合列，表头宽度取
    /// 量表 + 行内间距 + 数字之和（`Grid` 时代列宽由行内容自己撑出来，
    /// 迁到定宽列之后必须把这段间距算进表头，否则表头会比数据短 4pt 而错位）。
    /// 两截各自的宽度也留在这里，页面不再各写一个 `frame(width:)` 魔法数。
    static let healthScoreGauge: CGFloat = 44
    static let healthScoreNumber: CGFloat = 30
    static let healthScoreColumn: CGFloat = healthScoreGauge + Theme.Spacing.xxs + healthScoreNumber
    static let healthComponents: [DataGridColumn] = [
        DataGridColumn("维度", 126, .leading),
        DataGridColumn("得分", healthScoreColumn,
                       help: "该维度 0~100 分，条形按同一比例"),
        DataGridColumn("权重", 50, help: HealthBreakdown.weightColumnHelp),
        DataGridColumn("贡献", 52, help: "得分 × 归一化权重"),
        DataGridColumn("详情", nil, .leading),
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
                // **定宽格不许折行**，这条收在这里而不是逐格写 `lineLimit`：
                // 一个数字在 56pt 的格里换成两行，就把整行抬高、五列基线全断
                // （Git 洞察「增/删」列遇 `+1,234,567`、依赖「版本」列遇
                // `>=1.2.3, <2.0.0` 都是这个形状）。宁可截，不可撑。
                // 弹性列（名称 / 详情）不在此列 —— 它们本来就该换行，行高由最长按钮决定。
                .lineLimit(1)
        } else {
            frame(maxWidth: .infinity, alignment: column.alignment.frameAlignment)
        }
    }
}

// MARK: 表头与分隔

/// **全仓唯一的表格列头**（#34）。列名、列宽、对齐、口径提示全部从 `columns` 取，
/// 与数据行同源，所以「表头写一套、行写另一套」这种错位在这套里写不出来。
/// 末尾自带一条发丝分隔线，页面不要再补 `Divider()`。
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
                        .modifier(DataOptionalHelp(help: column.help))
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

