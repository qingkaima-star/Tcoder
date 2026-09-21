import SwiftUI

// 本文件是 `Design/ThemeTokens.swift` 的分片（WS-X7 规模债）。搬的理由是机械的：
// 宿主文件被本 App 自扫点名越过「巨大文件」线。**一个取值都没改**，搬的只是文件位置。
// 语义色 `Theme.Semantic` 与排版 `Theme.Typo` 留在宿主文件：
// `docs/九页实拍读数.md` 按那个文件名钉着语义色取值、
// `DesignTokenCacheGuardTests` 按那个文件名钉着 `TypeToken` 的 init 形状。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名照旧。

// MARK: - 间距 / 圆角 / 描边 / 高度 / 版面

extension Theme {
    /// 4pt 原子单位、8pt 主节奏（WS-H §3.1）。
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let sm: CGFloat = 12
        static let md: CGFloat = 16
        static let lg: CGFloat = 20
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let section: CGFloat = 40
        /// 栅格沟槽：规范定为 12，与 `sm` 同值，单列语义名便于页面表达意图。
        static let gutter: CGFloat = 12
        /// 徽标 / chip 内边距。注意这是 WS-H 自身的一处不一致：§9 明确 badge 用 6pt，
        /// 但 §3.1 的间距刻度里没有 6 这一档。此处按 §9 的显式值单列，
        /// 是否并回刻度交总工定夺（已写进笔记 42 的冲突清单）。
        static let chip: CGFloat = 6
        /// 内容卡内边距。20 → 24（无界面靠更大的内边距补回被拿掉的盒体边界）。
        static let cardPadding: CGFloat = 24
        /// 紧凑卡 / 指标 tile 内边距。
        static let tilePadding: CGFloat = 16

        /// 主分组间距（风格契约 8）。
        ///
        /// 「拥挤」的机械成因不是东西多，是**组间与组内是同一个数**：旧总览主区块之间用
        /// `md`=16、网格里用 `gutter`=12，而卡片内部条目间距也是 12 —— 没有任何东西告诉
        /// 眼睛「一组在这里结束」。这一档存在的唯一目的就是把组界显出来。
        static let group: CGFloat = 32
        /// 页面左右内边距。16 → 24：无界面里留白就是版框，边距太窄会让整页读起来像一坨。
        static let pageMargin: CGFloat = 24
    }

    /// 从现仓 7 种收敛到 5 档（WS-H §3.3）。同心原则：外层 lg → 内层 md/sm。
    enum Radius {
        static let none: CGFloat = 0
        static let sm: CGFloat = 6
        static let md: CGFloat = 10
        /// 内容卡/区块卡默认圆角。注意：旧值是 10，本轮按规范抬到 16。
        static let card: CGFloat = 16
        /// 逻辑上等于 Capsule。给必须传数值的 API 用。
        static let full: CGFloat = 999
    }

    enum Stroke {
        static let hairline: CGFloat = 0.5
        static let separator: CGFloat = 1
        static let emphasis: CGFloat = 2
        /// 曲线线宽（WS-H §5.4）。
        static let chartLine: CGFloat = 1.5
    }

    /// 阴影只服务于"没有真玻璃"的分支——macOS 26 上由系统玻璃接管景深。
    struct ElevationToken: Hashable {
        let color: ColorToken
        let opacity: Double
        let radius: CGFloat
        let yOffset: CGFloat

        var shadowColor: Color { color.color.opacity(opacity) }
    }

    enum Elevation {
        static let flat = ElevationToken(color: ColorToken(hex: 0), opacity: 0, radius: 0, yOffset: 0)
        static let card = ElevationToken(color: ColorToken(hex: 0), opacity: 0.06, radius: 6, yOffset: 1)
        static let raised = ElevationToken(color: ColorToken(hex: 0), opacity: 0.12, radius: 14, yOffset: 5)
        static let overlay = ElevationToken(color: ColorToken(hex: 0), opacity: 0.22, radius: 24, yOffset: 10)
    }

    /// 版面锚点（WS-H §3.2 / §3.4）。把断点写成令牌，页面里就不该再出现魔法宽度。
    enum Layout {
        /// **九页共用一个版框宽度**。原来三档（reading 1040 / overview 1200 / dense 1240）
        /// 的直接后果是：切一次 tab 内容整体左右跳 100pt，实拍量到左边距 585 / 610–650 / 965
        /// 三套、右边距五套 —— 用户判词「不规整」在版面上指的就是这个。
        /// 取 1240 是因为它是最窄的那档装不下的表（健康五列、性能图例）实测要的宽度，
        /// 版框只能按最宽的住户定；阅读型的行宽问题另有出口（段落组件自己收口），
        /// 不该拿整页版框去替一段文字让步。
        static let maxWidthPage: CGFloat = 1240
        /// 键值行的**标签列**宽。原来标签左、值右、中间一个 `Spacer`，
        /// 在 1040–1240pt 的页宽上就是"两个词被拉到相距约 1900px，中间没有结构"
        /// （依赖页三行、Git 页路径行都这样，是「对不齐」观感的主因之一）。
        /// 改成真正的两列：标签占定宽，值紧跟其后左对齐 —— 值与值之间于是能竖向比对。
        static let fieldLabelWidth: CGFloat = 160
        /// **定宽标签列的宽度必须跟着界面语言走。** 160pt 是按中文最宽标签量的；
        /// 同一批标签翻成英文后要 200pt 才不被省略号截断
        /// （`EnglishWidthAuditTests` 逐条量过：`Comments and Maintainability` 159pt、
        /// `Engineering Quality (code basis)` 171pt）。
        /// 固定一档的做法等于"只测中文、英文听天由命"——英文态实拍里就是这么翻车的。
        static let fieldLabelWidthEnglish: CGFloat = 200
        /// 当前语言该用哪一档。判定方式刻意**不读 `Locale`**：
        /// 取证跑的是 `-AppleLanguages "(en)"`，而 `Locale.current` 会跟着系统区域走，
        /// 两者不一致时量出来的宽度就对不上真正上屏的那一版。查表最可靠。
        static var fieldLabelWidthForLanguage: CGFloat {
            localizedCopy("口径") == "口径" ? fieldLabelWidth : fieldLabelWidthEnglish
        }
        /// 指标 tile 自适应最小宽度（一行四 → 自动折两列/单列）
        static let tileMinWidth: CGFloat = 220
        /// 双列内容卡并排所需的最小列宽
        static let twoColumnMinWidth: CGFloat = 420
        static let tileHeightCompact: CGFloat = 72
        static let tileHeightWithGauge: CGFloat = 88
        static let chartMinHeight: CGFloat = 110
        static let trendChartHeight: CGFloat = 150
        /// 可点区下限
        static let minHitTarget: CGFloat = 20
        /// 空态卡最小高度：低于这个高度，"这里什么都没有"会被读成"这里没渲染"
        static let emptyMinHeight: CGFloat = 140

        // ↓ 本轮补：三条流重样时都在页面里自造了这些尺寸，说明缺档，不是缺自觉
        /// 紧凑行（读数列、图例行）。
        static let rowHeightCompact: CGFloat = 22
        /// 图例色点边长。WS-L 曾借 `Radius.sm`(6) 当尺寸用——值对但语义错，单列一档。
        static let legendSwatchSide: CGFloat = 6

        /// 占比条的三列定宽（取 WS-L 72/96 与 WS-M 56 的实测值，避免每页各量一次）。
        static let shareLabelWidth: CGFloat = 96
        static let sharePercentWidth: CGFloat = 44
        static let shareCountWidth: CGFloat = 56

        /// 量表高度两档（WS-H §9：tile 内 5–6）。
        /// 收在这儿，页面里就不该再有 `height: 5` / `height: 6` 各写各的。
        static let gaugeInline: CGFloat = 5
        static let gaugeMetric: CGFloat = 6
    }
}
