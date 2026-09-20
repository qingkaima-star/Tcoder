import SwiftUI

// MARK: - 文件角色着色与两张文件表

/// 文件角色 → 语义角色。崩溃最深、错误次之、构建偏提醒、系统 / 应用走信息与中性。
///
/// 这里是**映射**而不是调色板：页内不出现一个颜色字面量，深浅外观与增强对比由
/// `Design/ColorToken.swift` 的双层色统一负责（旧实现是 `Theme.critical` 这类
/// 文字色直接涂在条形上，浅色下实测对比度不够）。
enum LogRoleStyle {
    static func role(for role: LogFileRole) -> Theme.SemanticRole {
        switch role {
        case .crash: return Theme.Semantic.critical
        case .error: return Theme.Semantic.danger
        case .build: return Theme.Semantic.warning
        case .system: return Theme.Semantic.info
        case .application: return Theme.Semantic.neutral
        }
    }
}

// MARK: 受影响源文件

struct LogsAffectedFilesCard: View {
    let logs: LogSummary?

    private static let itemLimit = 10

    var body: some View {
        let ranked = sorted
        guard !ranked.isEmpty else { return AnyView(EmptyView()) }
        let top = Array(ranked.prefix(Self.itemLimit))
        let total = max(1, ranked.reduce(0) { $0 + $1.value })
        return AnyView(
            GlassSection("受影响源文件",
                         subtitle: subtitle(topCount: top.count),
                         icon: .duplicate) {
                // 占比行走基座 `Theme.Share.Row`（《45》§3.3 判的重复形状）。
                // 注意分母：条形与百分比**必须同一个分母**，否则条长和数字各说一套。
                // 上一版条按峰值归一、旁边只给次数，看着一致其实两个口径，这里一起收掉。
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    ForEach(top, id: \.key) { item in
                        Theme.Share.Row(label: (item.key as NSString).lastPathComponent,
                                        fraction: Double(item.value) / Double(total),
                                        percentText: NumberFormat.percent(Double(item.value) / Double(total), precision: 1),
                                        countText: "\(NumberFormat.grouped(item.value)) 次",
                                        color: Theme.Semantic.danger.graphicColor,
                                        // 十行全涂同一个红，色点就把「图例」变成了重复装饰：
                                        // 量条本身已经是那一列的值，颜色在这里不区分任何东西。
                                        showSwatch: false)
                            .help(item.key)
                    }
                }
            }
        )
    }

    private func subtitle(topCount: Int) -> String {
        "按错误出现次数取前 \(topCount) 项 · 条形与百分比同为「占全部出现次数」的比重"
    }

    private var sorted: [(key: String, value: Int)] {
        guard let affected = logs?.affectedFiles else { return [] }
        // 闭式写法会让类型推断超时（Swift 6 之前对字典元素的三元比较尤其慢），拆开即可。
        return affected.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
    }
}

// MARK: 已扫描文件

struct LogsScannedFilesCard: View {
    let logs: LogSummary?

    private static let rowLimit = 40

    var body: some View {
        let files = sorted
        guard !files.isEmpty else { return AnyView(EmptyView()) }
        let shown = Array(files.prefix(Self.rowLimit))
        return AnyView(
            GlassSection("已扫描文件",
                         subtitle: "共 \(NumberFormat.grouped(files.count)) 个 · 按大小降序",
                         icon: .processes) {
                // 行距走风格契约 8 的「列表行 8」：这张表每行 5 列数字，
                // 4pt 会让上下两行的数字读成同一行。
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    DataTableHeader(columns: DataColumns.scannedLogFiles)
                    ForEach(shown) { file in
                        row(file)
                    }
                }
                if files.count > shown.count {
                    NoteLine("另有 \(NumberFormat.grouped(files.count - shown.count)) 个文件未列出。")
                }
            }
        )
    }

    private var sorted: [ScannedLogFile] {
        guard let files = logs?.scannedFiles else { return [] }
        return files.sorted { lhs, rhs in
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.path < rhs.path
        }
    }

    /// 表头与行共用 `DataColumns.scannedLogFiles` 一份列定义（#34）。
    private func row(_ file: ScannedLogFile) -> some View {
        let role = LogRoleStyle.role(for: file.role)
        return HStack(spacing: DataRowMetrics.cellGap) {
            HStack(spacing: Theme.Spacing.xxs) {
                ThemedIcon(.emptyTray, role: .badge).foregroundStyle(role.textColor)
                Text(file.role.rawValue)
            }
            .tableCell(DataColumns.column(DataColumns.scannedLogFiles, 0))
            Text(file.path)
                .font(Theme.Typo.monoSmall.font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .tableCell(DataColumns.column(DataColumns.scannedLogFiles, 1))
                .help(file.path)
            LiveNumber(Self.sizeText(file.sizeBytes), tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.scannedLogFiles, 2))
            LiveNumber(NumberFormat.grouped(file.lineCount), tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.scannedLogFiles, 3))
            LiveNumber(DateFormat.sinceDescription(file.modifiedAt), tier: Theme.Typo.monoSmall)
                .tableCell(DataColumns.column(DataColumns.scannedLogFiles, 4))
        }
    }

    /// 负数意味着 stat 没拿到尺寸，按 -- 处理而不是 0 B。
    static func sizeText(_ bytes: Int64) -> String {
        bytes >= 0 ? Live.bytes(UInt64(bytes)) : Live.missing
    }
}
