import SwiftUI

// MARK: - 数据表与实时数字的观感基座（性能 / 日志 / 健康三页共用）
//
// 活动监视器的专业感来自两件极小的事：**列宽定死** 与 **数字等宽**。
// 这两件事一旦各页自己写就会漂（WS-I §4 实测全仓 `.monospacedDigit()` 命中 0），
// 所以列宽、单元格对齐、占位符着色全部收在这一个文件里。

/// 三页数据表的列宽。取值按「该列最大可信读数」量出来，
/// 例如内存列要放得下 `123.4 GB`、打开文件列要放得下 `12,345`。
enum DataColumn {
    // 进程表
    static let pid: CGFloat = 52
    static let cpuCores: CGFloat = 62
    static let memory: CGFloat = 76
    static let threads: CGFloat = 50
    static let openFiles: CGFloat = 66

    // 日志页
    static let count: CGFloat = 56
    static let fileSize: CGFloat = 72
    static let fileLines: CGFloat = 78
    static let fileDate: CGFloat = 78
    static let fileRole: CGFloat = 76
    static let sampleIndex: CGFloat = 22

    // 健康页
    static let dimension: CGFloat = 126
    static let score: CGFloat = 30
    static let scoreGauge: CGFloat = 44
    static let weight: CGFloat = 50
    static let contribution: CGFloat = 52

    // 控件
    static let sortPicker: CGFloat = 208
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

/// 表头单元格。10pt Medium —— WS-H §4.2 的全仓文字下限，比现状的 8/9pt 可读。
struct TableHeaderCell: View {
    var title: String
    var width: CGFloat?
    var trailingAligned: Bool
    var help: String?

    init(_ title: String, width: CGFloat? = nil, trailing: Bool = true, help: String? = nil) {
        self.title = title
        self.width = width
        self.trailingAligned = trailing
        self.help = help
    }

    var body: some View {
        Text(title)
            .font(Theme.Typo.microLabel.font)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: trailingAligned ? .trailing : .leading)
            .modifier(HelpModifier(text: help))
    }
}

private struct HelpModifier: ViewModifier {
    var text: String?

    func body(content: Content) -> some View {
        if let text { content.help(text) } else { content }
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
    /// 定宽数值格：与表头同源，右对齐，刷新时列宽不动。
    func numberCell(_ width: CGFloat) -> some View {
        frame(width: width, alignment: .trailing)
    }

    /// 变宽文本格（进程名、路径、详情）：左对齐并吃掉剩余宽度。
    func flexCell() -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
    }
}
