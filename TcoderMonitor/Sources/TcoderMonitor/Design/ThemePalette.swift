import SwiftUI

// 本文件是 `Design/ThemeTokens.swift` 的分片（WS-X7 规模债）。搬的理由是机械的：
// 宿主文件被本 App 自扫点名越过「巨大文件」线。**一个取值都没改**，搬的只是文件位置。
// 语义色 `Theme.Semantic` 与排版 `Theme.Typo` 留在宿主文件：
// `docs/九页实拍读数.md` 按那个文件名钉着语义色取值、
// `DesignTokenCacheGuardTests` 按那个文件名钉着 `TypeToken` 的 init 形状。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名照旧。

// MARK: - 表面与透明度

extension Theme {
    enum Palette {
        /// 卡片与窗口背景：跟随系统，自动适配深浅色与「增强对比」。
        enum Surface {
            static let card = Color(nsColor: .controlBackgroundColor)
            static let window = Color(nsColor: .windowBackgroundColor)
            /// 表格/区块分隔线。内容卡不再用 1px 描边分层（WS-H §3.3），
            /// 只有确有分隔语义的地方用它。
            static let separator = Color(nsColor: .separatorColor)

            // ↓ 「简约无界」四个地面令牌。取值权威 = 本轮 spec §1 风格契约 1/3/4。
            //
            // 这四条存在的首要理由是**反证**：旧实现的内容层走 `.regularMaterial`，
            // 而材质背后无内容时在 macOS 上退化成一平涂半透明灰，实测每层都比窗口白底更暗
            // （`#FFFFFF → #E9EBED → #E3E5E7`，相邻只有 1.05:1，低于人眼 ~1.15:1 的分层阈值），
            // 叠三层就是「黑黢黢、很脏」。同一段里 `Surface.card` 早在 `controlBackgroundColor`
            // 上定义好了却**全仓零引用** —— 所以《BorderlessSurfaceGuardTests》现在既查
            // 「画了不该画的」也查「定义了没人用的」，只查前者会原样复发。

            /// 唯一页面底色（风格契约 1）。
            ///
            /// **2026-09-20 夜二次修订：浅色从 `#F1F1F3` 改成纯白，深色从 `#1C1C1E` 改成纯黑。**
            /// 上一版照参考图取了"桌面灰"，但漏了参考图的另一半：它是**纯白面板压在灰桌上**
            /// 的两级结构（同一张图实测桌面 `#EFEFF2`、卡内 `#F5F5F5`），而我这一轮把内容层的
            /// 面全去掉了，于是灰桌成了唯一底色。实拍读数：81.3% 像素落在 235–249 这一条灰带里，
            /// 纯白只占 5.1% —— 用户判词「不要用灰色底，显脏」在像素上就是这个分布。
            ///
            /// 还有一条更硬的理由：`DesignAppearance.referenceSurface` 一直是
            /// `#FFFFFF / #1E1E1E`（编译产物实测），也就是**全部 3:1 图形色断言本来就按白底算**。
            /// 地面定成 `#F1F1F3` 等于让真实像素比断言低 12%（`#2CA94C` 断言 3.05、真实 2.70），
            /// 守卫绿着、屏幕不达标。地面回白之后，断言与像素第一次是同一把尺子。
            static let ground = DualColor(lightHex: 0xFFFFFF, darkHex: 0x000000).color
            /// 井：内容层唯一允许的实心底（风格契约 3），只给表格 / 日志列表 / 代码块。
            /// 浅色从 `#EAEAEC` 提到 `#F5F5F7`：地面已经变白，井只要"比白暗一档"就够，
            /// 再深就成了上一版那种"灰块压灰底"的脏源。
            static let well = DualColor(lightHex: 0xF5F5F7, darkHex: 0x1C1C1E).color
            /// 控件层在 macOS ≤ 15 的实心兜底（26 上由系统玻璃接管）。
            static let control = DualColor(lightHex: 0xFFFFFF, darkHex: 0x2D2D2F).color
            /// 主读数纯墨（风格契约 4）。34pt 及以上的数字必须用它。
            ///
            /// **为什么不能用 `.primary`**：macOS 的 `labelColor` 是 85% 不透明黑，
            /// 铺在 `ground` 上合成出来约 `#262626` —— 实测正是重构前全页最暗像素
            /// `#2F2F2F` 的来源，而它落在**小号正文**上；参考图最暗像素 `#000000`
            /// 落在**最大的数字**上。「没有主次」在像素层面的定义就是这个错位。
            static let ink = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F2F5).color
            /// 主行动填充（参考图右上角那颗黑色 "Share" 胶囊）。
            ///
            /// 为什么主按钮是墨而不是强调色：参考图把**最高对比**给了唯一的主动作
            /// （`#0A0A0A` 底 + 白字，实测 19.8:1），把**彩色**留给"选中/增量"这类状态。
            /// 我们原来反过来——主按钮吃强调色玻璃，于是每个区域都在喊。
            /// 深浅两版各自翻转到极端：浅底黑胶囊白字、深底白胶囊黑字，都是 19.8:1。
            static let inkFill = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F2F5).color
            /// 压在 `inkFill` 上的前景，必须与它反向。
            static let onInkFill = DualColor(lightHex: 0xFFFFFF, darkHex: 0x0A0A0A).color
        }

        /// 透明度只留三档，收编现仓散落的 0.04/0.08/0.12/0.14/0.15/0.25。
        enum Opacity {
            static let gradientTop = 0.30
            static let gradientMid = 0.40
            static let gradientBottom = 0.50
            /// badge / 标签半透明同色底（WS-H §9）
            static let badgeFill = 0.15
            /// 密集实时曲线的面积顶色。WS-H §5.4 的 0.30 在 96–110pt 高的实时曲线上
            /// 过浓（WS-M 重样时实测改到 0.16 并留了「待回归规范」的注释）。
            /// 这里收成一档有名有姓的强度，页面不必再造常量；默认档是否换成它交总工。
            static let gradientAreaSoft = 0.16
            /// 图表面积渐变的收尾值
            static let gradientFloor = 0.02
        }
    }
}
