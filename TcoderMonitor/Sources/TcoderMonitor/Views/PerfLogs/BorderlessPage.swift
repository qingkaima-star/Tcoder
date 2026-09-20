import SwiftUI

// MARK: - 三页共用的「简约无界」页骨架
//
// 性能 / 日志 / 健康三页共一份版框：组间 32、页边距 24、页头 40。
// 三页原来各写一份 ScrollView + padding，正是「同一个东西长三遍」的债，
// 所以收成一处；两份基座组件（`Theme.Page.Scaffold`、各页 header）在下面说明为什么不能直接用。

/// 数据密集型页面的无界骨架。
///
/// **为什么不复用基座 `Theme.Page.Scaffold`**：它的组间距写死 `Theme.Spacing.md`(16)、
/// 左右边距也是 16。而风格契约 8 要的是「页边距 24 / 分组间 32 / 页级段落 40」——
/// 也就是说 16 正是本轮 spec 根因⑤「间距没有呼吸档，组间与组内是同一个数」的定量形态。
/// `Design/**` 归总工，页面流无权改，所以先在本流域内落一份把 32/24/40 三档真用起来，
/// 并已作为「契约缺口」上报：等 `Scaffold` 换上 `Spacing.group` / `Spacing.pageMargin`，
/// 这个文件应当整份删掉、三页改回基座。留两份长期并存就是下一轮的债。
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
            // 页头之上给一整段呼吸：这一档存在的意义就是「页级段落 ≠ 分组间距」，
            // `Spacing.section` 自定义起全仓零引用，正是拥挤的机械成因。
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
///   2. 说明行与页名抢同一水平线，读起来像页名的一部分。
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
