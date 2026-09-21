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
            // `card` 原来走 `controlBackgroundColor`（跟随系统）。批次 P6 把它**钉死**：
            // 新语言的层次关系是"画布 #F7F7F7 上压纯白卡"，差值只有 3%，
            // 交给系统色就等于把这 3% 交给每个人的系统设置去决定——
            // 与本仓把 `accent` 钉死的理由同族（可反查像素、可算断言）。
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
            /// **2026-09-21 批次 P6：地面从纯白改回"画布灰" `#F7F7F7`。**
            /// 用户裁定全量对齐 AiX（规范 `docs/界面语言-对齐AiX.md`）。
            /// 这次和上一版"桌面灰"的区别是**层次关系对了**：
            /// 上一版是灰画布上**什么都不抬**（81.3% 像素挤在 235–249 那条灰带里）⇒ 显脏；
            /// AiX 是灰画布上压**纯白卡片**（实测画布 `#F7F7F7`、卡内 `#FFFFFF`），
            /// 3% 的亮度差就是"抬起来"的全部来源。所以判据也跟着改：
            /// 不再要求"地面必须纯白"，改为要求**卡片与画布亮度差 ≥3%**。
            /// 深色侧没有参考图，按同一层次关系推导（画布 < 卡片），已在规范里备案。
            static let ground = DualColor(lightHex: 0xF7F7F7, darkHex: 0x0E0E10).color
            /// 卡片面：新语言里**唯一被抬起来的那一层**（参考图实测纯白）。
            static let card = DualColor(lightHex: 0xFFFFFF, darkHex: 0x1C1E22).color
            /// 侧栏地面：参考图实测 `#F9F9F8`，比内容画布**亮一档**。
            /// 侧栏与内容的分界靠这个色差，不靠分隔线（也不靠描边）。
            static let sidebar = DualColor(lightHex: 0xF9F9F8, darkHex: 0x131315).color
            /// 页标题墨：参考图 H1 实测 `#313131`（软黑）。
            /// 只给页标题用；**最大的数字仍然吃 `ink`**——"最重的墨给最大的数"这条没变。
            static let headingInk = DualColor(lightHex: 0x313131, darkHex: 0xEDEDF0).color
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

        /// 卡片层的三个常量（批次 P6）。**边与影同时存在才像参考图**：
        /// 只有发丝边会显廉价，只有投影会在灰画布上糊成一团。
        enum Card {
            /// 圆角**只有一个来源**：`Theme.Radius.card`。这里再写一个数就是两套口径，
            /// 而卡片层同时用到"形状"与"边/影"两处，两处各取一个值时错的那处不会报错、只会不圆。
            static let cornerRadius: CGFloat = Theme.Radius.card
            static let hairline = DualColor(lightHex: 0xEAEAEC, darkHex: 0x2A2A2E).color
            static let hairlineWidth: CGFloat = 0.5
            /// 8% 黑、12pt 模糊、y 偏移 2pt —— 一层，不许叠加第二层。
            static let shadowOpacity = 0.08
            static let shadowRadius: CGFloat = 12
            static let shadowY: CGFloat = 2
            /// 影子颜色合成成一档给调用点用，避免每个渲染点自己 `Color.black.opacity(0.08)`。
            static let shadowColor = Color.black.opacity(shadowOpacity)
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
