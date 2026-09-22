import SwiftUI

// MARK: - 数据表基座（全仓唯一一套列系统，#34 收敛后由八个有表的页面共用）
//
// 行级组件（键值行 / 读数条 / 占比条 / 行节奏 / 量表高度 / 提示条）在 WS-X7 规模债这一轮
// 原样搬到 `Design/DataRows.swift`，取值一字未改；本文件只留**列系统本身**：
// 列定义、列宽表、`tableCell` 出口、列头与分隔。
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
    /// 英文态的列宽。**默认 nil = 沿用中文宽度**，只有量出来装不下的列才写。
    ///
    /// 为什么要有这一档：本文件的定宽规矩是"按该列最宽**可信读数**实测"，
    /// 而中文与英文的最宽读数不是同一个串 ——
    /// 「维度」126pt 装得下「注释与可维护性」，装不下 "Comments and Maintainability"（实测 158pt）。
    /// 出处：`scripts/ax_truncation_sweep.sh` 在英文态九页扫描（`918e23c`）。
    let widthEnglish: CGFloat?
    let alignment: DataGridColumnAlignment
    let help: String?

    /// 当前语言下真正生效的宽度。单元格只许读这一条，不许各自挑 `width`。
    var resolvedWidth: CGFloat? { Theme.Layout.isChineseUI ? width : (widthEnglish ?? width) }

    init(_ title: String, _ width: CGFloat? = nil,
         _ alignment: DataGridColumnAlignment? = nil,
         help: String? = nil, widthEnglish: CGFloat? = nil) {
        self.title = title
        self.width = width
        self.widthEnglish = widthEnglish
        // **弹性列（无定宽）= 名称列 = 一律左对齐**，这个规则收在构造点。
        // 原来默认对齐是尾对齐（数字列占多数），名称列漏写 `.leading` 就会把表头拉到
        // 列右边 —— 代码规模页「来源」、贡献者页「来源」、Git 洞察页「目录」三张表
        // 各现形一次，而同文件注释早就写了"名称列一律显式写 .leading"：
        // 一条只能靠记性的规则就是没有规则。显式传入仍然优先。
        self.alignment = alignment ?? (width == nil ? .leading : .trailing)
        // 列头口径**在构造点就过查表**：`.help(_:)` 收的是成品 String、自己不查目录，
        // 而列名（`title`）在渲染处已经 `localizedCopy` 过 —— 只有 help 漏了，
        // 于是英文态整列表头提示都是中文（2026-09-21 英文态实测 A 类残留的主因之一）。
        self.help = help.map { localizedCopy($0) }
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
        DataGridColumn("维度", 126, .leading, widthEnglish: 160),
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
    /// 表头专用的那一格：**允许折两行**。
    ///
    /// 为什么表头不能沿用 `tableCell` 的"宁可截，不可撑"：那条规矩的理由是
    /// **一个数字在 56pt 的格里换成两行会把整行抬高、五列基线全断**，它管的是数据行。
    /// 表头在分隔线之上、自己一行，折两行不会碰任何数据基线；
    /// 反过来不折的代价是**英文态列名被裁成「Occurren…」**
    /// （`DataGridColumn("出现", 56)` 中文够、英文 "Occurrences" 要 67pt；
    /// 「圈复杂度」62pt 对 "Cyclomatic Complexity" 119pt 更装不下）。
    /// 读数器：`scripts/ax_truncation_sweep.sh`，判据见 `DataTableHeader` 的守卫。
    @ViewBuilder
    func tableHeaderCell(_ column: DataGridColumn) -> some View {
        if let width = column.resolvedWidth {
            frame(width: width, alignment: column.alignment.frameAlignment)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            frame(maxWidth: .infinity, alignment: column.alignment.frameAlignment)
        }
    }

    /// 把视图钉到某一列的布局上。表头与数据行都走这里，对齐不可能再各写各的。
    @ViewBuilder
    func tableCell(_ column: DataGridColumn) -> some View {
        if let width = column.resolvedWidth {
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
            // `.bottom`：某一列的英文名折成两行时，其余列名仍站在同一条底线上，
            // 分隔线到列名的距离在整表里保持一个数。
            HStack(alignment: .bottom, spacing: DataRowMetrics.cellGap) {
                ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                    Text(localizedCopy(column.title))
                        .font(CodeGitType.prose(Theme.Typo.microLabel))
                        .foregroundStyle(.secondary)
                        .tableHeaderCell(DataColumns.column(columns, index))
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
