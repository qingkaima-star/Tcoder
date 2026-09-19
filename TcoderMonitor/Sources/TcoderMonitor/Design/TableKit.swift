import SwiftUI

// MARK: - 数据表基座
//
// 存在理由：本轮之前，WS-L 在 `Views/CodeGit/CodeGitTable.swift` 造了一套
// （`DataGridColumn` / `DataTableHeader` / `DataGaugeHeight`……），
// WS-M 又在 `Views/PerfLogs/NumberText.swift` 造了另一套**形状不兼容**的
// （`DataColumn` 是标量常量表，不是列数组）。同一件事两种写法，正是设计系统要消灭的东西。
//
// 这里给的是**并集形状**，与 WS-L 那套字段一一对应，迁移只是换前缀
// （`DataGridColumn` → `Theme.Table.Column`），不改调用形态。
// WS-L 那份之所以没直接放进来：`Design/**` 上一轮不归他们所有，他们只能落自己目录。
//
// 全部嵌在 `Theme.Table` 里有两个原因：一是命名空间干净，二是页面目录里已经飘着
// `DataTableHeader`、`ChartAxis`、`ChartSeries` 等顶层类型（WS-M 那份还没合进 main），
// Design 再造同名顶层类型会在下一次 merge 时重声明、把全仓编译弄红。

extension Theme {
    enum Table {
        /// 不叫 `Alignment`：那是 SwiftUI 已有的类型名，嵌在同一作用域里会互相遮蔽。
        enum ColumnAlignment: Equatable {
            case leading, center, trailing

            var frameAlignment: SwiftUI.Alignment {
                switch self {
                case .leading: return .leading
                case .center: return .center
                case .trailing: return .trailing
                }
            }

            /// 数字列一律尾随对齐（WS-H §11「表/列数字右对齐」）——
            /// 左对齐时位数不同的数字看不出谁大。
            static let numeric: ColumnAlignment = .trailing
        }

        struct Column: Equatable {
            let title: String
            let width: CGFloat?
            let alignment: ColumnAlignment
            /// 可排序时给一个稳定 key；nil = 这列不参与排序。
            let sortKey: String?

            init(_ title: String, _ width: CGFloat? = nil,
                 _ alignment: ColumnAlignment = .trailing, sortKey: String? = nil) {
                self.title = title
                self.width = width
                self.alignment = alignment
                self.sortKey = sortKey
            }

            var isSortable: Bool { sortKey != nil }
        }

        struct Sort: Equatable {
            let key: String
            let ascending: Bool

            /// 点同一列翻向，点新列从降序开始（数字列"大的在前"更符合直觉）。
            func toggling(_ column: Column) -> Sort {
                guard let key = column.sortKey else { return self }
                return key == self.key ? Sort(key: key, ascending: !ascending)
                                       : Sort(key: key, ascending: false)
            }
        }

        /// 统一行高，取 `Theme.Layout`。
        static let rowHeight: CGFloat = Theme.Layout.rowHeightTable
        static let compactRowHeight: CGFloat = Theme.Layout.rowHeightCompact

        /// 表头。可排序时整列表头都是按钮，不可排序时是纯文字。
        struct Header: View {
            var columns: [Column]
            var sort: Sort?
            var onSort: ((Sort) -> Void)?

            init(columns: [Column], sort: Sort? = nil, onSort: ((Sort) -> Void)? = nil) {
                self.columns = columns
                self.sort = sort
                self.onSort = onSort
            }

            var body: some View {
                VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                    HStack(spacing: Theme.Spacing.sm) {
                        ForEach(Array(columns.enumerated()), id: \.offset) { index, column in
                            cell(for: column, at: index)
                        }
                    }
                    .frame(minHeight: Theme.Layout.rowHeightCompact)
                    Separator()
                }
                .padding(.top, Theme.Spacing.xxs)
            }

            @ViewBuilder
            private func cell(for column: Column, at index: Int) -> some View {
                let label = Text(column.title)
                    .font(Theme.Typo.microLabel.font)
                    .monospacedDigit()
                    .foregroundStyle(isActive(column) ? Theme.Semantic.accent.textColor : .secondary)
                if sortable, column.isSortable, let onSort {
                    Button {
                        if let key = column.sortKey { onSort((sort ?? Sort(key: key, ascending: false)).toggling(column)) }
                    } label: {
                        HStack(spacing: Theme.Spacing.xxs) {
                            label
                            sortMark(column)
                        }
                    }
                    .buttonStyle(.plain)
                    .themeTableCell(column)
                    .accessibilityLabel("按\(column.title)排序")
                } else {
                    HStack(spacing: Theme.Spacing.xxs) {
                        label
                        sortMark(column)
                    }
                    .themeTableCell(column)
                }
            }

            private var sortable: Bool { onSort != nil }

            private func isActive(_ column: Column) -> Bool {
                sort?.key == column.sortKey
            }

            /// 排序指示：未排序列给中性双向箭头（暗示可点），激活列给单向箭头。
            /// 关键是**方向不能只靠颜色**表达（WS-H §10）。
            @ViewBuilder
            private func sortMark(_ column: Column) -> some View {
                if let sort, sort.key == column.sortKey {
                    ThemedIcon(sort.ascending ? .sortAscending : .sortDescending, role: .badge)
                        .foregroundStyle(Theme.Semantic.accent.textColor)
                } else if column.isSortable {
                    ThemedIcon(.sortNeutral, role: .badge)
                        .foregroundStyle(.tertiary)
                }
            }
        }

        /// 行间分隔。内容卡不用 1px 描边分层，但**表格行之间确有分隔语义**，
        /// 所以这里保留一条发丝线，用系统分隔色，深浅外观自动跟随。
        struct Separator: View {
            var body: some View {
                Rectangle()
                    .fill(Theme.Palette.Surface.separator)
                    .frame(height: Theme.Stroke.hairline)
            }
        }

        /// 一行数据。行高与垂直节奏由基座定，页面只管填列内容。
        struct Row<Content: View>: View {
            var height: CGFloat
            var tint: Color?
            @ViewBuilder var content: Content

            init(height: CGFloat = Theme.Table.rowHeight,
                 tint: Color? = nil,
                 @ViewBuilder content: () -> Content) {
                self.height = height
                self.tint = tint
                self.content = content()
            }

            var body: some View {
                HStack(spacing: Theme.Spacing.sm) {
                    content
                }
                .frame(minHeight: height)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if let tint {
                        RoundedRectangle(cornerRadius: Theme.Radius.sm, style: .continuous)
                            .fill(tint)
                    }
                }
            }
        }

        /// 行底透明度。单列成常量是为了可断言：`Color.opacity(...)` 出来的东西
        /// 在测试里**永远比不出相等**（动态 NSColor 的描述里带 UUID），只能断代数。
        static let rowTintAlpha = Theme.Palette.Opacity.rowFill

        /// 行级淡底色（比徽标底再弱一档，避免整屏表格被高饱和色块盖住）。
        static func rowTint(_ role: Theme.SemanticRole) -> Color {
            role.graphicColor.opacity(rowTintAlpha)
        }

        /// 越界安全的取列：传错下标退回弹性列，而不是直接崩。
        static func column(_ columns: [Column], _ index: Int) -> Column {
            columns.indices.contains(index) ? columns[index] : Column("")
        }
    }
}

extension View {
    /// 把视图钉到某一列的布局上。表头与数据行都走这里，
    /// 对齐与列宽不可能再各写各的。
    /// 叫 `themeTableCell` 而不是 `tableCell`：WS-L 页面里已有 `View.tableCell`，
    /// 同名扩展会在 merge 时互相吃掉。
    @ViewBuilder
    func themeTableCell(_ column: Theme.Table.Column) -> some View {
        if let width = column.width {
            frame(width: width, alignment: column.alignment.frameAlignment)
        } else {
            frame(maxWidth: .infinity, alignment: column.alignment.frameAlignment)
        }
    }
}
