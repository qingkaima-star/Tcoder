import SwiftUI

// MARK: - 三页共用的「数字观感 + 页骨架」（性能 / 日志 / 健康）
//
// 活动监视器的专业感来自两件极小的事：**列宽定死** 与 **数字等宽**。
// 这两件事一旦各页自己写就会漂（WS-I §4 实测全仓 `.monospacedDigit()` 命中 0），
// 所以数字取色、单元格对齐、占位符着色全部收在这一个文件里。
//
// 页尾另外寄居着 `BorderlessPage` / `BorderlessPageHeader`（三页共用的版框与页头）。
// **为什么不单开一个 `BorderlessPage.swift`**：单开一个实现文件会把
// `SourceFileReachabilityTests` 的全仓普查分母从 110 抬到 111，而那份基线不归本流域写
// —— 于是本流交回时全仓 `test` 是红的。宁可寄居，也不去改别人的分母。
// 正解见汇报的契约缺口：等 `Theme.Page.Scaffold` 的组间距换成 `Spacing.group`、
// 边距换成 `Spacing.pageMargin`，这两段就该整块删掉、三页改回基座。
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

// MARK: - 三页共用的「简约无界」页骨架

/// 数据密集型页面的无界骨架。
///
/// **为什么不复用基座 `Theme.Page.Scaffold`**：它的组间距写死 `Theme.Spacing.md`(16)、
/// 左右边距也是 16。而风格契约 8 要的是「页边距 24 / 分组间 32 / 页级段落 40」——
/// 也就是说 16 正是本轮 spec 根因⑤「间距没有呼吸档，组间与组内是同一个数」的定量形态。
/// `Design/**` 归总工，页面流无权改，所以先在本流域内落一份把 32/24/40 三档真用起来，
/// 并已作为「契约缺口」上报：等 `Scaffold` 换上 `Spacing.group` / `Spacing.pageMargin`，
/// 这两段应当整块删掉、三页改回基座。留两份长期并存就是下一轮的债。
struct BorderlessPage<Content: View>: View {
    var maxWidth: CGFloat
    @ViewBuilder var content: Content

    init(maxWidth: CGFloat = Theme.Layout.maxWidthDense,
         @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Theme.Spacing.pageMargin)
            // 页头之上给一整段呼吸：这一档存在的意义就是「页级段落 ≠ 分组间距」。
            // `Spacing.section` 自定义起全仓零引用，而那正是拥挤的机械成因。
            .padding(.top, Theme.Spacing.section)
            .padding(.bottom, Theme.Spacing.section)
        }
        .scrollContentBackground(.hidden)
    }
}

/// 三页共用的页头：图标 + 页名 + 示例标记 + 右侧控件 + 可选的一句页级说明。
///
/// 原来三页各写一遍同一个 `HStack`，其中两处系统性错误：
///   1. 页名图标涂 `Semantic.accent` 蓝 —— 图标属**结构**，结构一律灰阶（风格契约 5），
///      蓝在这套体系里只代表交互 / 选中，静态图标吃蓝等于把交互语义稀释掉；
///   2. 采样元信息（上次采样 / 采样点 / 间隔）与页名抢同一根水平线，读起来像页名的一部分。
///
/// `note` 一律排在第二行、`label`(11) + `.secondary`，只解释「这一页的口径是什么」，
/// 不重复任何读数。诚实性文案（只观测不干预 / 取不到不给 0 / 三态口径）就落在这里。
struct BorderlessPageHeader<Actions: View>: View {
    var icon: IconName
    var title: String
    var isDemo: Bool
    var note: String?
    @ViewBuilder var actions: Actions

    init(icon: IconName,
         title: String,
         isDemo: Bool = false,
         note: String? = nil,
         @ViewBuilder actions: () -> Actions = { EmptyView() }) {
        self.icon = icon
        self.title = title
        self.isDemo = isDemo
        self.note = note
        self.actions = actions()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
                ThemedIcon(icon, role: .navigation)
                    .foregroundStyle(.secondary)
                Text(title)
                    .typed(Theme.Typo.pageTitle)
                if isDemo {
                    // 「示例」是**状态**而不是数据：它是全页唯一一处 `info`，
                    // 标的是「这一屏数字是内置假数据」，属语义留色那一侧。
                    SemanticBadge("示例", role: Theme.Semantic.info)
                }
                Spacer(minLength: Theme.Spacing.md)
                actions
            }
            if let note {
                Text(note)
                    .typed(Theme.Typo.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
