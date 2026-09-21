import SwiftUI

// MARK: - 三页共用的「数字观感」（性能 / 日志 / 健康）
//
// 活动监视器的专业感来自两件极小的事：**列宽定死** 与 **数字等宽**。
// 这两件事一旦各页自己写就会漂（WS-I §4 实测全仓 `.monospacedDigit()` 命中 0），
// 所以数字取色、单元格对齐、占位符着色全部收在这一个文件里。
//
// 本文件**只放数字与单元格的观感**。它曾先后寄居过两份"看着像共用件、其实越界"的东西，
// 都已删除，写在这里免得有人再放回来：
//   1. `BorderlessPage`（自造页骨架）—— 总工 `48443d9` 把基座 `Theme.Page.Scaffold`
//      换成 `pageMargin/group/section` 三档，并钉了「全仓只许一份页骨架」
//      （`pageScaffoldDeclarations` 按 `Scaffold` / `BorderlessPage` 字样识别）。
//      三页现全部走 `Theme.Page.Scaffold`。**再想加骨架：名字带这两个词就会被拦。**
//   2. `PerfLogsPageHeader`（三页共用的页头）—— 「页头」这件事全仓只许一套画法，
//      归 `Views/ProjectDetailView.swift` 与 `Views/Shell/**`（WS-O 名下）。
//      页面目录里养一份页头 = 两套页头并存，正是用户说的「东一个系一个」。
//      三页现在各自写**页内小标题**（页名 + 本页口径一句 + 本页控件），
//      不碰项目名 / 路径 / 分析时间。需要基座提供通用页头件请报契约缺口给总工，
//      由他加进 `Design/`，**不要在页面目录里养**。
//
// #34 起，**列头与列宽不再归本文件管**：全仓唯一一套列系统在
// `Design/DataTable.swift`（`DataColumn` / `DataTableHeader` / `.tableCell`，
// 自 `Views/CodeGit/CodeGitTable.swift` 上提），
// 原先这里的 `TableHeaderCell` 与那 14 个 `DataColumn` 列宽常量已随收敛删除。
// 下面剩下的三个宽度都不是列：两个是「错误聚类」列表的行内列（那张列表没有列头），
// 一个是排序控件。

/// 非列头的定宽：没有列头的列表与控件用得到的宽度。
/// **新表格的列宽不许加到这里**，请去 `DataColumns` 声明一份 `[DataGridColumn]`。
enum PerfLogWidths {
    /// 错误聚类列表 · 出现次数。
    /// 「N 次」列。56 装得下 4 位（`1,234 次` ≈ 52pt），装不下 5 位：
    /// 一个 panic 循环刷出 `12,345 次` 约 70pt，13pt 等宽 + `lineLimit(1)` 会截成
    /// `12,34…` —— 错误签名计数恰好是最不该被截的数字。量到 72。
    static let count: CGFloat = 72
    /// 错误聚类列表 · 样本序号（个位数，只用来把样本对齐）。
    static let sampleIndex: CGFloat = 22
    /// 进程页排序分段控件。取值 = 两个选项里较长那条「按 CPU 核当量」的实测宽度。
    static let sortPicker: CGFloat = 208
}

// 量表厚度不再在本文件造档：`BarThickness`（tile 5 / component 4）已收口到
// `Theme.Layout.gaugeInline`(5) / `gaugeMetric`(6)。分量表原来那个 4pt 在基座里没有对应档，
// 差 1pt 换掉一份私有刻度是划算的 —— 「令牌定义了却没人用」正是本轮的病因。

/// 会实时变化的数字。等宽 + 右对齐 + 定宽三件事一起做，缺证据时强制中性色。
///
/// 默认前景是**纯墨 `Surface.ink`** 而不是 `.primary`：`labelColor` 只有 85% 黑，
/// 铺在 `ground` 上合成出来约 `#262626`，而参考图最暗像素落在最大的数字上（`#000000`）。
/// 「最重的墨给最重要的数」在这个组件上的落地就是：凡是要人盯着读的那个跳动的数，
/// 一律墨色；`.primary` 退回给 13pt 以下正文。
struct LiveNumber: View {
    var text: String
    var tier: Theme.TypeToken
    var realTint: Color
    var width: CGFloat?

    init(_ text: String,
         tier: Theme.TypeToken = Theme.Typo.metricMid,
         tint: Color = Theme.Palette.Surface.ink,
         width: CGFloat? = nil) {
        self.text = text
        self.tier = tier
        self.realTint = tint
        self.width = width
    }

    var body: some View {
        // 查表之后才谈得上英文态：`Text(变量)` 走 verbatim 初始化（双语方案 §7.1）。
        // 本组件收的多半是纯数字，查不到就原样返回，代价是一次字典查找；
        // 也有带单位的形态（`LogsErrorClusters` 传 `\(…) 次`）—— 那一条要修的是
        // **调用点的半句键**，不是这里，已记进本轮汇报。
        Text(localizedCopy(text))
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
            // 全仓 15 处 `NoteLine(…)` 调用点都从这一行上屏，此前它一个字都不查
            // （盘点表 Y 节缺口 1）：`PerformanceMatcherEditor` 那句「匹配模式对进程名…」
            // 在英文目录里已有键，却因为这里不查而永远是中文。
            Text(localizedCopy(text))
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

