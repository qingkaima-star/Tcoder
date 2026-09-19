import SwiftUI

// Theme 的令牌区。`Theme` 本体声明在 App/Theme.swift（兼容转发层），
// 这里用 extension 挂嵌套命名空间，保证"页面只写语义名"这条规则有唯一落点。
//
// 取值权威 = 《40 WS-H 设计语言规范》§3–§6。本文件只做一件事：把规范里的数字
// 变成有类型的常量。双层色（graphic / text）是为同时满足 WS-H §10 的两条验收线，
// 依据见 `SemanticRole` 注释与笔记 42。

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

// MARK: - 语义色

extension Theme {
    /// 一个语义角色的分层取值。选成员按"这段颜色拿来读、拿来涂、还是涂了再往上读字"决定：
    ///
    /// - `graphic`：图表线/柱、进度条、色块。**非文本，验收线 3:1**（WS-H §10）。
    /// - `text`：文字与图标前景。**验收线 4.5:1**，且浅深两套各自达标。
    ///
    /// 为什么非要拆两层：WS-H §5.2 定的系统色（浅mode `#34C759` 绿 / `#FF9F0A` 橙）
    /// 直接当文字放在浅色白卡上实测只有 **2.22 / 2.06 : 1**——连它自己 §10 的非文本
    /// 3:1 线都过不了。所以图形层保留系统色相，文字层另配加深的取值。
    ///
    /// **对 §5.2 的三处偏离（已备案）**：浅色模式的 success / warning / healthy 图形色
    /// 从 `#34C759` / `#FF9F0A` / `#2FB8A5` 压暗到 `#2CA94C` / `#D18208` / `#2AA694`
    /// （同色相、factor 0.82~0.90），压到刚好跨过 §10 的 3:1 线（实测 3.05 / 3.04 / 3.02）。
    /// 深色模式仍用规范原值。要还原：把这三个 `graphicLight` 改回 §5.2 的原始值即可，
    /// 代价是浅色下进度条/曲线低于验收线。
    struct SemanticRole: Hashable {
        let name: String
        let text: DualColor
        let graphic: DualColor
        /// 画在 `graphic` 填充之上的前景色，逐角色、逐外观择优。
        /// 必须是双层：`critical` 的浅底填充是深红（配白才够 6.5:1），
        /// 而它的深底填充是浅鲑红（配墨才够 6.7:1）——单值必然有一侧不达标。
        let onFill: DualColor
        /// 系统动态色优先的角色（如 accent 跟随用户强调色）在这里放 `Color`；
        /// 为 nil 表示该角色的 graphic 是数值令牌、可参与对比度断言。
        let systemGraphic: Color?

        init(name: String, textLight: UInt32, textDark: UInt32,
             graphicLight: UInt32, graphicDark: UInt32,
             onFill: DualColor = DualColor(lightHex: 0x111111, darkHex: 0x111111)) {
            self.name = name
            self.text = DualColor(lightHex: textLight, darkHex: textDark)
            self.graphic = DualColor(lightHex: graphicLight, darkHex: graphicDark)
            self.onFill = onFill
            self.systemGraphic = nil
        }

        /// 跟随系统色的角色（accent）。无法用数值断言，报告里单列。
        init(systemNamed name: String, system: Color, textLight: UInt32, textDark: UInt32) {
            self.name = name
            self.text = DualColor(lightHex: textLight, darkHex: textDark)
            self.graphic = DualColor(lightHex: 0x0A82FF, darkHex: 0x0A84FF)
            self.onFill = DualColor(lightHex: 0x111111, darkHex: 0x111111)
            self.systemGraphic = system
        }

        var textColor: Color { text.color }
        var graphicColor: Color { systemGraphic ?? graphic.color }
        /// 跟随外观切换的前景墨色。
        var onFillColor: Color { onFill.color }

        /// badge 底色：图形色低透明度铺在表面上（WS-H §9 统一 0.15）。
        func badgeFill(in appearance: DesignAppearance = .light) -> Color {
            graphic.token(in: appearance).color.opacity(Theme.Palette.Opacity.badgeFill)
        }

        /// 以下三个对比度口子供单测与自检使用。
        func contrastTextOnSurface(in appearance: DesignAppearance) -> Double {
            text.token(in: appearance).contrastRatio(with: appearance.referenceSurface)
        }

        func contrastTextOnBadgeFill(in appearance: DesignAppearance) -> Double {
            let ink = text.token(in: appearance)
            let bg = graphic.token(in: appearance).composited(
                over: appearance.referenceSurface, alpha: Theme.Palette.Opacity.badgeFill)
            return ink.contrastRatio(with: bg)
        }

        func contrastGraphicOnSurface(in appearance: DesignAppearance) -> Double {
            graphic.token(in: appearance).contrastRatio(with: appearance.referenceSurface)
        }

        func contrastOnOwnFill(in appearance: DesignAppearance) -> Double {
            onFill.token(in: appearance).contrastRatio(with: graphic.token(in: appearance))
        }
    }

    enum Semantic {
        static let accent = SemanticRole(
            systemNamed: "accent", system: Color.accentColor,
            textLight: 0x1D4ED8, textDark: 0x8AB4F8)

        static let success = SemanticRole(
            name: "success", textLight: 0x157A32, textDark: 0x5BE28A,
            graphicLight: 0x2CA94C, graphicDark: 0x30D158)

        /// 70–84 档的"偏绿/teal"，补上健康色阶的单调中间档（WS-H §5.2 去蓝档）。
        static let healthy = SemanticRole(
            name: "healthy", textLight: 0x0E7A63, textDark: 0x5AD8C0,
            graphicLight: 0x2AA694, graphicDark: 0x4ED8C0)

        static let warning = SemanticRole(
            name: "warning", textLight: 0x8A5000, textDark: 0xFFD60A,
            graphicLight: 0xD18208, graphicDark: 0xFFD60A)

        static let danger = SemanticRole(
            name: "danger", textLight: 0xC2251C, textDark: 0xFF6B63,
            graphicLight: 0xFF3B30, graphicDark: 0xFF453A)

        /// 比 danger 更深一档。它是唯一 `onFill` 需要跟着外观翻转的角色。
        static let critical = SemanticRole(
            name: "critical", textLight: 0x8E1A13, textDark: 0xFF8A85,
            graphicLight: 0xB3261E, graphicDark: 0xFF6961,
            // 浅底深红配白字（6.54），深底浅鲑红配墨字（6.69）
            onFill: DualColor(lightHex: 0xFFFFFF, darkHex: 0x111111))

        static let info = SemanticRole(
            name: "info", textLight: 0x0A5BCC, textDark: 0x7DBBFF,
            graphicLight: 0x007AFF, graphicDark: 0x0A84FF)

        static let neutral = SemanticRole(
            name: "neutral", textLight: 0x5F5F64, textDark: 0xA9A9AE,
            graphicLight: 0x8E8E93, graphicDark: 0x98989D)

        /// 参与对比度断言的角色（accent 的 graphic 随系统强调色，数值不可断言，单列）。
        static let measurable: [SemanticRole] =
            [success, healthy, warning, danger, critical, info, neutral]

        static let all: [SemanticRole] = [accent] + measurable

        /// 风险等级 → 角色。沿用旧映射（WS-H §5.3 判定该映射合理），换成双层色。
        static func role(for risk: RiskLevel) -> SemanticRole {
            switch risk {
            case .none: return neutral
            case .low: return success
            case .medium: return warning
            case .high: return danger
            case .critical: return critical
            }
        }

        /// 日志等级 → 角色。原八个 hex 收成六个：trace/debug 同为中性，
        /// exception 并入 critical。这层映射替掉视图里的 `Color(hex: severity.colorHex)`。
        static func role(for severity: LogSeverity) -> SemanticRole {
            switch severity {
            case .trace, .debug: return neutral
            case .info: return info
            case .warning: return warning
            case .error: return danger
            case .exception, .fatal, .crash: return critical
            }
        }

        /// 健康分 → 角色。**单调色阶，去掉旧的蓝档**（WS-H §1.4#2：蓝是交互/链接色，
        /// 一色一义）。`nil` = 未评分，落 neutral，不进着色（呼应 WS-D #6）。
        static func role(forScore score: Int?) -> SemanticRole {
            guard let score else { return neutral }
            switch score {
            case 85...: return success
            case 70..<85: return healthy
            case 55..<70: return warning
            case 1..<55: return danger
            default: return critical   // 0 分，且仅在确有数据时才会走到这里
            }
        }
    }
}

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
        /// 内容卡内边距（规范用 lg=20 取代现状 14）。
        static let cardPadding: CGFloat = 20
        /// 紧凑卡 / 指标 tile 内边距。
        static let tilePadding: CGFloat = 16
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
        /// 阅读/列表型页面上限
        static let maxWidthReading: CGFloat = 1040
        /// 概览型
        static let maxWidthOverview: CGFloat = 1120
        /// 数据密集型（性能、健康）
        static let maxWidthDense: CGFloat = 1240
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

// MARK: - 排版

extension Theme {
    /// 字号令牌带上元数据而不只是 `Font`：单测据此断言"所有数字档位都开了 monospacedDigit"，
    /// 并守住"任何文字 ≥ 10pt"这条硬下限。指标实时跳动时数字宽度不能变，否则整块布局会抖。
    struct TypeToken {
        let name: String
        let size: CGFloat
        let weight: Font.Weight
        let design: Font.Design
        let monospacedDigits: Bool
        /// 中文正文用 1.5–1.6 倍行高（WS-H §4.2），换算成 SwiftUI 的 lineSpacing 追加值。
        let lineSpacing: CGFloat

        var font: Font {
            let base = Font.system(size: size, weight: weight, design: design)
            return monospacedDigits ? base.monospacedDigit() : base
        }
    }

    /// 字族一律 `.system`（SF Pro）。中文由系统回退 PingFang SC——CoreText 实测
    /// `CTFontCreateForString("健康评分")` → `PingFangSC-Regular`（断言写在 DesignTokenTests）。
    /// 手写 `Font.custom("PingFang SC")` 会破坏等宽数字与字重联动，WS-H §4.1 明确禁止。
    ///
    /// 数字一律弃用 `.rounded`：向活动监视器的原生观感靠拢，这是刻意的取舍（WS-H §4.1）。
    enum Typo {
        // 数据大字
        static let heroMetric = TypeToken(name: "heroMetric", size: 40, weight: .bold, design: .default, monospacedDigits: true, lineSpacing: 4)
        static let metricNumber = TypeToken(name: "metricNumber", size: 28, weight: .semibold, design: .default, monospacedDigits: true, lineSpacing: 4)
        static let metricMid = TypeToken(name: "metricMid", size: 18, weight: .semibold, design: .default, monospacedDigits: true, lineSpacing: 3)

        // 中文标题 / 正文 / 说明
        static let pageTitle = TypeToken(name: "pageTitle", size: 17, weight: .semibold, design: .default, monospacedDigits: false, lineSpacing: 2)
        static let cardTitle = TypeToken(name: "cardTitle", size: 13, weight: .semibold, design: .default, monospacedDigits: false, lineSpacing: 2)
        static let body = TypeToken(name: "body", size: 13, weight: .regular, design: .default, monospacedDigits: false, lineSpacing: 3)
        static let narrative = TypeToken(name: "narrative", size: 12, weight: .regular, design: .default, monospacedDigits: false, lineSpacing: 3)
        static let label = TypeToken(name: "label", size: 11, weight: .regular, design: .default, monospacedDigits: false, lineSpacing: 2)
        /// 微标签/表头/坐标轴。**全仓文字下限**，不得再有更小的档。
        static let microLabel = TypeToken(name: "microLabel", size: 10, weight: .medium, design: .default, monospacedDigits: false, lineSpacing: 2)

        /// 11pt 等宽：表格里放代码标识符（函数名、文件名、依赖名）用。
        /// 存在理由：WS-L 重样时点名「设计系统没有 11pt 等宽档」，只能从 `label`(11) 借字号
        /// 再换成等宽字面——那等于在页面里造了一档令牌。层级靠颜色与字重区分，不靠再缩字号。
        static let monoLabel = TypeToken(name: "monoLabel", size: 11, weight: .medium, design: .monospaced, monospacedDigits: true, lineSpacing: 2)

        // 等宽数据面（路径、PID、代码、日志）
        static let monoBody = TypeToken(name: "monoBody", size: 13, weight: .regular, design: .monospaced, monospacedDigits: true, lineSpacing: 2)
        static let monoSmall = TypeToken(name: "monoSmall", size: 10, weight: .regular, design: .monospaced, monospacedDigits: true, lineSpacing: 2)

        static let all: [TypeToken] = [
            heroMetric, metricNumber, metricMid,
            pageTitle, cardTitle, body, narrative, label, microLabel,
            monoBody, monoSmall, monoLabel,
        ]

        /// 承载实时数字的档位——单测据此守住 monospacedDigit。
        static let numericTiers: [TypeToken] = [heroMetric, metricNumber, metricMid,
                                                 monoBody, monoSmall, monoLabel]
    }
}
