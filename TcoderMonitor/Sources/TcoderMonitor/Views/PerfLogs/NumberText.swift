import SwiftUI

// MARK: - 实时数字与单元格观感（性能 / 日志 / 健康三页共用）
//
// 活动监视器的专业感来自两件极小的事：**列宽定死** 与 **数字等宽**。
// 这两件事一旦各页自己写就会漂（WS-I §4 实测全仓 `.monospacedDigit()` 命中 0），
// 所以数字取色、单元格对齐、占位符着色全部收在这一个文件里。
//
// #34 起，**列头与列宽不再归本文件管**：全仓唯一一套列系统在
// `Views/CodeGit/CodeGitTable.swift`（`DataGridColumn` / `DataTableHeader` / `.tableCell`），
// 原先这里的 `TableHeaderCell` 与那 14 个 `DataColumn` 列宽常量已随收敛删除。
// 下面剩下的三个宽度都不是列：两个是「错误聚类」列表的行内列（那张列表没有列头），
// 一个是排序控件。

/// 非列头的定宽：没有列头的列表与控件用得到的宽度。
/// **新表格的列宽不许加到这里**，请去 `DataColumns` 声明一份 `[DataGridColumn]`。
enum PerfLogWidths {
    /// 错误聚类列表 · 出现次数。
    static let count: CGFloat = 56
    /// 错误聚类列表 · 样本序号（个位数，只用来把样本对齐）。
    static let sampleIndex: CGFloat = 22
    /// 进程页排序分段控件。取值 = 两个选项里较长那条「按 CPU 核当量」的实测宽度。
    static let sortPicker: CGFloat = 208
}

/// 量表厚度。《40 WS-H》§9 只给两档：分量表 4、tile 内 5–6，
/// 页面不再各写一个 height 魔法数（占位空行也用同一档，保证等高）。
enum BarThickness {
    static let tile: CGFloat = 5
    static let component: CGFloat = 4
}

/// 会实时变化的数字。等宽 + 右对齐 + 定宽三件事一起做，缺证据时强制中性色。
struct LiveNumber: View {
    var text: String
    var tier: Theme.TypeToken
    var realTint: Color
    var width: CGFloat?

    init(_ text: String,
         tier: Theme.TypeToken = Theme.Typo.metricMid,
         tint: Color = .primary,
         width: CGFloat? = nil) {
        self.text = text
        self.tier = tier
        self.realTint = tint
        self.width = width
    }

    var body: some View {
        Text(text)
            .font(tier.font)                       // 数字档位自带 monospacedDigit
            .foregroundStyle(Live.tint(text, real: realTint))
            .frame(width: width, alignment: .trailing)
            .contentTransition(.numericText())
            .lineLimit(1)
            .minimumScaleFactor(0.85)
            .accessibilityLabel(text)
    }
}

/// 一行口径 / 状态说明：图标 + 文字双通道（WS-H §10「不只靠颜色表意」）。
/// 三页的「本次采样失败 / 未启用 / 已核对零命中」都走它，句式因此只有一处定义。
struct NoteLine: View {
    var text: String
    var role: Theme.SemanticRole
    var icon: IconName

    init(_ text: String, role: Theme.SemanticRole = Theme.Semantic.neutral, icon: IconName = .info) {
        self.text = text
        self.role = role
        self.icon = icon
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xxs) {
            ThemedIcon(icon, role: .badge)
                .foregroundStyle(role.textColor)
            Text(text)
                .font(Theme.Typo.label.font)
                .foregroundStyle(.secondary)
                .lineSpacing(Theme.Typo.label.lineSpacing)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}

extension View {
    /// 定宽数值格：右对齐，刷新时列宽不动。
    /// 有列头的数据表请改用它旁边的 `.tableCell(列)`（列宽从列定义来，#34）；
    /// 这里只服务没有列头的列表与复合列里的子截。
    func numberCell(_ width: CGFloat) -> some View {
        frame(width: width, alignment: .trailing)
    }

    /// 变宽文本格（路径、详情）：左对齐并吃掉剩余宽度。同上，有列头的表用 `.tableCell(列)`。
    func flexCell() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}
