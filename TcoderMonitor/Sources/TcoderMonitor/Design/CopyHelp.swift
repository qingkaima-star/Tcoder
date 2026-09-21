import SwiftUI

// MARK: - ⓘ「帮助图标 + tooltip」（全站唯一一份画法）
//
// 要补的洞（《2026-09-21 九页解释性文案盘点表》Y 节）：全站每一处 tooltip 都**匿名**
// 挂在数字或徽标上 —— `LiveNumber(…).help(…)`、`SemanticBadge(…).help(…)`，
// 鼠标得先猜哪里能 hover。本文件给的是看得见的那半个挂载点：一枚问号，停上去才出解释句。
//
// 三条规矩，都由 `CopyHelpBadgeTests` 机器钉住（每条都配"注入坏样例必须红"的元测试）：
//   1. **画法全仓只有一份**。页面里再写一遍「问号图标 + `.help`」即违例。
//      现存唯一一处历史形状（依赖页 `SemanticBadge(…, icon: .unverified).help(…)`）
//      在守卫里**按文件点名挂账、只减不增** —— 那两个文件不归本流写，
//      点名而不静默放行，是为了让还掉的那一天守卫自己变红提醒划条目。
//   2. **上屏前查表**。`help(_:)` 与 `accessibilityLabel(_:)` 收的都是**成品 String**，
//      自己不会查本地化目录（双语方案 §7.1），所以这里显式过 `localizedCopy`：
//      键 = 中文原文，缺一条译文的表现是"退回正确的中文"，不是漏出机器键。
//   3. **默认态零版面成本**。组件只是一枚图标：不铺底、不加材质、不写投影
//      （AGENTS 红线 6：全仓 `.shadow(` 只许 1 处且在 `.floating` 分支里）、
//      不占定宽列 —— 本仓实拍吃过"标签占 160pt 列宽、读数带中间空一段版心"的亏。
//
// 部署下限 macOS 14：`.help(_:)` 自始可用，本文件**一个 `#available` 都不写**
// （AGENTS §3 横切约束 1 禁止页面散写可用性判断，而这里连"集中判断"都不需要）。
// 字号也不在这里造：符号尺寸与字重由 `IconRole.badge` 跟随它所属的文字语境，
// 那条链的源头就是 `Theme.Typo`（`Design/IconTokens.swift` 图标规则 1、2）。

/// 一行解释性文案的 ⓘ 挂载点：短读数留在屏上，长口径进 hover。
///
/// 配合盘点表的判定标签使用：
/// - 「留短藏长」（盘点表 129 槽里 94 槽判这一类）→ `NoteLine(短句, help: 长口径)`，
///   屏上只多一枚问号，一个字符的列宽都不占；
/// - 「藏」→ 直接把 `CopyHelpBadge(整句)` 排在那行读数后面；
/// - ⚠ **承担诚实性告知的那 89 条不许整条藏**（盘点表 Z 节）。判据：这条一旦只有 hover
///   才看得见，用户就会把「没查 / 算不出 / 只是这段窗口的分布」读成一个真实的 0 或一个结论。
///
/// - Parameters:
///   - text: 进 tooltip 的那一句解释。**必须是完整句**：把一个句子拆成两半分别做键，
///     英文态语序必坏（双语方案 §9 / 守卫 `test_noRegisteredKeyIsOnlyAHalfSentence`）。
///   - label: 只给 VoiceOver 的短标签。**不传（本轮唯一在用的形状）时读屏与 hover 同一句**
///     = `text`；显式传时读屏念 `label`。两处 `.help` 的先后次序只在传了不同串时才要紧，
///     本轮没做读屏与 hover 实拍（不能启动 App），已记进汇报的"未覆盖"。
struct CopyHelpBadge: View {
    let text: String
    var label: String?

    init(_ text: String, label: String? = nil) {
        self.text = text
        self.label = label
    }

    /// 问号是**结构**不是数据，一律中性灰（风格契约 5：`info` / `accent` 是交互色，
    /// 拿它们给图标上色就是"给数字上个颜色"那种被砍掉的写法）。颜色只从
    /// `Theme.Semantic` 的既有角色里取，本文件不新造任何一个色值。
    ///
    /// 为什么取成 `static let`：它拿到的本来就是 `DualColor` 在 init 里算好的那一份
    /// 缓存色（`Design/ColorToken.swift`），在 `body` 里每 tick 再引用一次不换来任何
    /// 正确性，只给「渲染路径引用令牌成员」那条棘轮添数（现量 64 / 上限 64，满格）。
    private static let iconColor = Theme.Semantic.neutral.textColor

    var body: some View {
        // 符号走登记表 `IconName.unverified`（= `questionmark.circle`），不在这里散写裸串。
        // `label:` 交给 `ThemedIcon`：它按图标规则 4 同时装配 `.accessibilityLabel` 与 `.help`。
        ThemedIcon(.unverified, role: .badge, label: localizedCopy(label ?? text))
            .foregroundStyle(Self.iconColor)
            // 再显式挂一次 tooltip，为的是「屏上什么字都没有的这枚图标，hover 出去的那句
            // 就是 `text` 本句」这件事在本文件里可读，而不是要靠跳到 `IconTokens` 才知道。
            // `label == nil`（本轮唯一在用的形状）时两处是同一个串，不存在先后问题；
            // 两处不同串时的生效次序未做读屏实拍，已记进本轮"未覆盖"。
            .help(localizedCopy(text))
    }
}
