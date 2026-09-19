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
                VStack(alignment: .leading, spacing: Theme.Spacing.xxs) {
                    ForEach(top, id: \.key) { item in
                        Theme.Share.Row(label: (item.key as NSString).lastPathComponent,
                                        fraction: Double(item.value) / Double(total),
                                        percentText: NumberFormat.percent(Double(item.value) / Double(total), precision: 1),
                                        countText: "\(NumberFormat.grouped(item.value)) 次",
                                        color: Theme.Semantic.danger.graphicColor)
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
                Grid(alignment: .trailing, horizontalSpacing: Theme.Spacing.sm,
                     verticalSpacing: Theme.Spacing.xxs) {
                    GridRow {
                        TableHeaderCell("类型", width: DataColumn.fileRole, trailing: false)
                            .gridColumnAlignment(.leading)
                        TableHeaderCell("文件").flexCell().gridColumnAlignment(.leading)
                        TableHeaderCell("大小", width: DataColumn.fileSize, help: "文件字节数（1024 进制）")
                        TableHeaderCell("行数", width: DataColumn.fileLines)
                        TableHeaderCell("修改", width: DataColumn.fileDate)
                    }
                    Divider().gridCellColumns(5)
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

    private func row(_ file: ScannedLogFile) -> some View {
        let role = LogRoleStyle.role(for: file.role)
        return GridRow {
            HStack(spacing: Theme.Spacing.xxs) {
                ThemedIcon(.emptyTray, role: .badge).foregroundStyle(role.textColor)
                Text(file.role.rawValue)
            }
            .frame(width: DataColumn.fileRole, alignment: .leading)
            Text(file.path)
                .font(Theme.Typo.monoSmall.font)
                .foregroundStyle(.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .flexCell()
                .help(file.path)
            LiveNumber(Self.sizeText(file.sizeBytes), tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.fileSize)
            LiveNumber(NumberFormat.grouped(file.lineCount), tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.fileLines)
            LiveNumber(DateFormat.sinceDescription(file.modifiedAt), tier: Theme.Typo.monoSmall)
                .numberCell(DataColumn.fileDate)
        }
    }

    /// 负数意味着 stat 没拿到尺寸，按 -- 处理而不是 0 B。
    static func sizeText(_ bytes: Int64) -> String {
        bytes >= 0 ? Live.bytes(UInt64(bytes)) : Live.missing
    }
}
