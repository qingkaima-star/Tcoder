import SwiftUI

// Theme 的令牌区。`Theme` 本体声明在 App/Theme.swift（兼容转发层），
// 这里用 extension 挂嵌套命名空间，保证"页面只写语义名"这条规则有唯一落点。
//
// 取值权威 = 《40 WS-H 设计语言规范》§3–§6。本文件只做一件事：把规范里的数字
// 变成有类型的常量。双层色（graphic / text）是为同时满足 WS-H §10 的两条验收线，
// 依据见 `SemanticRole` 注释与笔记 42。
//
// 本轮（WS-X7 规模债）把两块**度量**原样搬出去了，取值一字未改：
// 表面与透明度在 `Design/ThemePalette.swift`，间距 / 圆角 / 描边 / 高度 / 版面在
// `Design/ThemeMetrics.swift`。它们与本文件一样是 `extension Theme` 的嵌套命名空间。

// MARK: - 缺证据占位（「没查 / 查不了」那一态的字面）

extension Theme {
    /// 《40 WS-H》§7.3：有数据 = 真值（**含真 0**）；查了但空 = `0` + 「未发现」；
    /// 没查 / 查失败 = 下面这个占位。把这一态写成 0，就是把"没证据"伪装成"结论"。
    ///
    /// 这里只是**字面本体**。要不要用这个字面由 `Design/DataAbsence.swift` 决定：
    /// 缺数据一共有四态（`value` / `measuredEmpty` / `indeterminate` / `notAnalysed`），
    /// 只有 `notAnalysed` 用 `--`；「除零算不出」与「查了但是空的」各有自己的字面。
    /// 页面请取 `DataAbsence.display`，不要再来手写第 N 处 `?? Theme.Placeholder.missingValue`
    /// （#47 之前全仓有 15 处，逐处清单见《42》§14；现存处数由 `DesignAbsenceStateTests` 钉住）。
    enum Placeholder {
        static let missingValue = "--"
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
    /// **对 §5.2 的两处偏离（已备案）**：浅色模式的 success / warning 图形色
    /// 从 `#34C759` / `#FF9F0A` 压暗到 `#2CA94C` / `#D18208`
    /// （同色相、factor 0.82~0.90），压到刚好跨过 §10 的 3:1 线（实测 3.05 / 3.04）。
    /// 深色模式仍用规范原值。要还原：把这两个 `graphicLight` 改回 §5.2 的原始值即可，
    /// 代价是浅色下进度条/曲线低于验收线。
    struct SemanticRole: Hashable {
        let name: String
        let text: DualColor
        let graphic: DualColor
        /// 画在 `graphic` 填充之上的前景色，逐角色、逐外观择优。
        /// 必须是双层：`critical` 的浅底填充是深红（配白才够 6.5:1），
        /// 而它的深底填充是浅鲑红（配墨才够 6.7:1）——单值必然有一侧不达标。
        let onFill: DualColor
        /// badge 底色两档预计算（`Opacity.badgeFill` 铺在对应外观的图形色上）。
        ///
        /// 存在理由与 `DualColor.color` 同源：`badgeFill(in:)` 是徽标/提示条每行都要
        /// 调的口子，改前每次调用现算 `token.color.opacity(0.15)`，于是每次视图图更新
        /// 按徽标数 new 一批 `Color`。这里在 init 里算好，方法体退化成一次分支取值，
        /// **结果与改前逐字节相同**（同一个 `ColorToken.color` 乘同一个透明度）。
        let badgeFillLight: Color
        let badgeFillDark: Color
        /// 渲染点用的那一份：**随外观自动换档**。`badgeFill(in:)` 只服务断言与自检。
        let adaptiveBadgeFill: Color

        init(name: String, textLight: UInt32, textDark: UInt32,
             graphicLight: UInt32, graphicDark: UInt32,
             onFill: DualColor = DualColor(lightHex: 0x111111, darkHex: 0x111111)) {
            self.name = name
            self.text = DualColor(lightHex: textLight, darkHex: textDark)
            self.graphic = DualColor(lightHex: graphicLight, darkHex: graphicDark)
            self.onFill = onFill
            self.badgeFillLight = Self.makeBadgeFill(of: self.graphic.light)
            self.badgeFillDark = Self.makeBadgeFill(of: self.graphic.dark)
            self.adaptiveBadgeFill = Self.makeAdaptiveBadgeFill(of: self.graphic)
        }

        /// badge 底色：**按当次外观选档**的动态色。
        ///
        /// 为什么需要它：渲染点（`SemanticBadge`）拿不到"当前是浅色还是深色"，
        /// 只能调 `badgeFill(in:)`，于是那个 `= .light` 默认值等于**在深色态铺浅色档的底色**
        /// —— 浅色档来自压暗过的 `graphicLight`，铺在黑地上比深色档更闷，
        /// 两批实拍里"胶囊像描边"就是这么来的（批次 P5）。
        /// 闭包只在这里进 `NSColor(name:)`，构造发生在角色 init，不在渲染路径上。
        private static func makeAdaptiveBadgeFill(of graphic: DualColor) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return (isDark ? graphic.dark : graphic.light).nsColor
                    .withAlphaComponent(Theme.Palette.Opacity.badgeFill)
            })
        }

        /// badge 底色的构造点。**写成静态函数而不是计算属性**，理由同
        /// `DualColor.makeDynamicNSColor`：计算属性体就是"每次访问现造"。
        private static func makeBadgeFill(of token: ColorToken) -> Color {
            token.color.opacity(Theme.Palette.Opacity.badgeFill)
        }

        var textColor: Color { text.color }
        var graphicColor: Color { graphic.color }
        /// 跟随外观切换的前景墨色。
        var onFillColor: Color { onFill.color }

        /// badge 底色：图形色低透明度铺在表面上（WS-H §9 统一 0.15）。
        /// 值已在 init 里算好，这里只做选择，不再 new `Color`。
        ///
        /// **参数没有默认值**（批次 P5）：以前写 `= .light`，于是渲染点一句
        /// `role.badgeFill()` 就在深色态铺了浅色档。渲染点本来也不知道当前外观，
        /// 所以它该用 `adaptiveBadgeFill`；这个口子只留给"明确知道自己在算哪一态"的断言。
        func badgeFill(in appearance: DesignAppearance) -> Color {
            switch appearance {
            case .light: return badgeFillLight
            case .dark: return badgeFillDark
            }
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
        /// 强调色。**从这一版起钉死为绿色，不再跟随用户系统强调色**。
        ///
        /// 为什么不再跟随系统：用户给的锚点图用亮绿做唯一强调色，而系统强调色在本机是蓝——
        /// 于是"选中态"这一类最重要的反馈跟着每个人的系统设置漂，参考图里那套
        /// "结构去色、语义留色、强调只有一种" 就永远对不齐。钉死的代价是失去系统联动，
        /// 换来的是像素可反查、断言可计算（这条角色从此进 `measurable`，与其余六个同线）。
        ///
        /// 三档各自的存在理由（数值 = 对 `ground` 与对白色前景双向实测）：
        /// - `graphic` 浅 `#15803D`：对白底 5.02:1，白字压上去 5.02:1。**同时**过
        ///   非文本 3:1 与文本 4.5:1 两条线，所以它既能画进度条也能当选中胶囊底。
        ///   深 `#15803D`：对纯黑 4.19:1、白字压上去 5.02:1。**两版取同一个值**是算出来的——
        ///   深底想更亮一档（如 `#0E8A45`）时，白字于其上只剩 4.43:1，反而跌破 4.5 线。
        /// - `text` 浅 `#0D7130`：对白底 6.11:1，**压在自己 15% badge 底上 4.98:1**。
        ///   原来取 `#0E7A32`（对白底 5.46:1，看着更宽裕），但 badge 底是"同色 15% 铺白底"，
        ///   合成后亮度掉到 0.806，文字对比被压成 **4.45:1** —— 差 0.05 就是不过线，
        ///   而这条线是 `testSemanticTextClearsWCAG_AA_OnBadgeFill` 实测出来的，不是估的。
        ///   深 `#59E08A`：对纯黑 12.45:1。
        /// - `onFill` 一律白：`graphic` 做填充时前景取白，两版都 ≥4.5。
        ///
        /// 与 `success` 的关系是**刻意同族不同档**：`success` 管数据（健康/涨），
        /// `accent` 管交互（选中/焦点/主行动旁的状态）。参考图本来就让绿色同时承担
        /// "品牌"与"正向"两义，两者在屏幕上从不相邻（一个在导航、一个在数据位）。
        /// **批次 P6：强调色从绿换成 AiX 的 azure 蓝**（用户裁定，规范
        /// `docs/界面语言-对齐AiX.md`）。参考图实测选中胶囊是 `#2B76DB`，
        /// 但白字压上去只有 **4.48:1**（差 0.02 不过 AA），而本仓的 AA 线是硬约束，
        /// 所以取**同色相、可过线的最近值** `#2A6FD3`：白字 4.92:1、白底图形 4.92:1。
        /// 深浅两版仍取同一个图形值（原理由见上一版注释：深底想更亮一档时白字会跌破 4.5）。
        static let accent = SemanticRole(
            name: "accent", textLight: 0x1D63C6, textDark: 0x7FB4FF,
            graphicLight: 0x2A6FD3, graphicDark: 0x2A6FD3,
            onFill: DualColor(lightHex: 0xFFFFFF, darkHex: 0xFFFFFF))

        static let success = SemanticRole(
            name: "success", textLight: 0x157A32, textDark: 0x5BE28A,
            graphicLight: 0x2CA94C, graphicDark: 0x30D158)

        // **70–84 的 teal 档已于 2026-09-21 退役**（批次 P5）。实拍反查证明它是全仓
        // 第二套强调色相：浅色 `#2AA694`（色相 171°）与 `success` 的 `#2CA94C`（124°）
        // 在总览/健康评分两页各占 0.33%~0.38% 像素，用户看到的是"两种绿"，
        // 而同一列里 84 和 89 一个青一个绿。分数色阶因此收成一族绿：色相只承担
        // "好 / 需注意 / 差"的语义，程度由旁边的数字承担（见 `role(forScore:)`）。

        /// 需注意（55–69 分 / 中风险）：橙。
        static let warning = SemanticRole(
            name: "warning", textLight: 0x8A5000, textDark: 0xFF9F0A,
            graphicLight: 0xD18208, graphicDark: 0xFF9F0A)

        static let danger = SemanticRole(
            name: "danger", textLight: 0xC2251C, textDark: 0xFF6B63,
            graphicLight: 0xFF3B30, graphicDark: 0xFF453A)

        /// 比 danger 更深一档。它是唯一 `onFill` 需要跟着外观翻转的角色。
        static let critical = SemanticRole(
            name: "critical", textLight: 0x8E1A13, textDark: 0xFF8A85,
            graphicLight: 0xB3261E, graphicDark: 0xFF6961,
            // 浅底深红配白字（6.54），深底浅鲑红配墨字（6.69）
            onFill: DualColor(lightHex: 0xFFFFFF, darkHex: 0x111111))

        /// 批次 P6：**一个蓝**。参考图里只有一种蓝，而 `accent` 换成 azure 之后
        /// 若 `info` 还留系统蓝 `#007AFF`，就成了批次 P5 刚消灭的那种"两支同族色相"
        /// （用户读到的是"两套强调色"）。所以 info 并入 accent 那一支，
        /// 日志等级与交互态靠**图标与位置**区分，不靠色相。
        ///
        /// `onFill` 必须**跟着一起搬**：默认档是给绿/黄/红那几支准备的近黑墨 `#111111`
        /// （黑字压 `#2CA94C` 过线），压在本支 azure 上只有 **3.88:1**。
        /// 门禁 `testOnFillForegroundClearsWCAG_AA_InBothAppearances` 第一次跑就抓到——
        /// "并入同一支"如果只改色值不改前景，等于把填充态留成一个不过线的组合。
        static let info = SemanticRole(
            name: "info", textLight: 0x1D63C6, textDark: 0x7FB4FF,
            graphicLight: 0x2A6FD3, graphicDark: 0x2A6FD3,
            onFill: DualColor(lightHex: 0xFFFFFF, darkHex: 0xFFFFFF))

        static let neutral = SemanticRole(
            name: "neutral", textLight: 0x5F5F64, textDark: 0xA9A9AE,
            graphicLight: 0x8E8E93, graphicDark: 0x98989D)

        /// 参与对比度断言的角色。**从 accent 钉死之日起，全部角色都进这条线**——
        /// 以前 accent 因为跟随系统强调色而"数值不可断言"，只能单列；现在它是钉死的
        /// 绿色，没有理由豁免。谁再把某个角色改回系统动态色，就必须同时把它从这里摘出去，
        /// 那等于承认"这个数我不负责"，`DesignTokenTests` 的注册表断言会拦住这种操作。
        static let measurable: [SemanticRole] =
            [accent, success, warning, danger, critical, info, neutral]

        static let all: [SemanticRole] = measurable

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

        /// 健康分 → 角色。**一族绿**（批次 P5）：色相只表达"好 / 需注意 / 差"三档语义，
        /// 程度交给数字本身。旧的 70–84 teal 中间档已退役 —— 它让同一列里 84 与 89
        /// 出现两个色相，用户读成"两套强调色"（WS-H §5.2 去蓝档的同一类错误）。
        /// `nil` = 未评分，落 neutral，不进着色（呼应 WS-D #6）。
        static func role(forScore score: Int?) -> SemanticRole {
            guard let score else { return neutral }
            switch score {
            case 70...: return success
            case 55..<70: return warning
            case 1..<55: return danger
            default: return critical   // 0 分，且仅在确有数据时才会走到这里
            }
        }
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
        /// 字距（pt）。无界风格里分区标题是**唯一的分组线索**，靠加字距把它从正文里
        /// 拎出来，而不是靠底色、描边或图标色。带默认值，故 12 处既有成员式初始化不受影响。
        ///
        /// ⚠️ **`Font` 没有任何字距 API**（实测 `Font.kerning` 与 `Font.tracking` 都不存在，
        /// 字距只在 `Text` / `View` 层）。所以这一档**不经过 `font`**，由 `View.typed(_:)`
        /// 一次性套上（`Design/SharedComponents.swift`）。
        /// 用 `.font(token.font)` 会静默丢掉字距 —— 分区标题一律走 `.typed(...)`，
        /// 《BorderlessSurfaceGuardTests》钉着这条。
        var tracking: CGFloat = 0

        /// 该档的 `Font`，**在令牌构造时算一次**（13 档 = 全 App 13 个 `Font` 对象）。
        ///
        /// 改前它是计算属性 `var font: Font { Font.system(...) }`，而 `.font(` 全仓有
        /// 183 处调用、其中不少在 `ForEach` / `AxisMark` 闭包里 —— 每次视图图更新都
        /// 重新 new 一批 `Font`。`Theme.Typo.*` 全部住在 `static let` 上，所以把 `Font`
        /// 收进 init 就等于"每档只造一次"，取用退化成一次成员读取。
        /// 这是**纯缓存改造**：`token.font` 的名字、类型、调用形状一字未动。
        let font: Font

        init(name: String, size: CGFloat, weight: Font.Weight, design: Font.Design,
             monospacedDigits: Bool, lineSpacing: CGFloat, tracking: CGFloat = 0) {
            self.name = name
            self.size = size
            self.weight = weight
            self.design = design
            self.monospacedDigits = monospacedDigits
            self.lineSpacing = lineSpacing
            self.tracking = tracking
            let base = Font.system(size: size, weight: weight, design: design)
            self.font = monospacedDigits ? base.monospacedDigit() : base
            DesignTokenMeter.record(.font)
        }
    }

    /// 字族一律 `.system`（SF Pro）。中文由系统回退 PingFang SC——CoreText 实测
    /// `CTFontCreateForString("健康评分")` → `PingFangSC-Regular`（断言写在 DesignTokenTests）。
    /// 手写 `Font.custom("PingFang SC")` 会破坏等宽数字与字重联动，WS-H §4.1 明确禁止。
    ///
    /// 数字一律弃用 `.rounded`：向活动监视器的原生观感靠拢，这是刻意的取舍（WS-H §4.1）。
    enum Typo {
        // 数据大字。
        //
        // 「简约无界」把跨度从 4:1（旧 40/28/18）拉到 5.6:1。旧值不是审美选择，是
        // 「没有主次」的定量形态之一：全仓 122 次 `Typo.*` 引用里 67% 挤在 10–12pt，
        // 大字档只占 6%，`heroMetric` 全仓仅 3 处调用 —— 最大与最小差 4 倍，
        // 眼睛无从判断哪个才是这一页的主角。
        static let heroMetric = TypeToken(name: "heroMetric", size: 56, weight: .bold, design: .default, monospacedDigits: true, lineSpacing: 4)
        static let metricNumber = TypeToken(name: "metricNumber", size: 34, weight: .semibold, design: .default, monospacedDigits: true, lineSpacing: 4)
        /// 必须与 `pageTitle` 一起抬：`DesignTokenTests` 钉的是严格递减链
        /// `heroMetric > metricNumber > metricMid > pageTitle > cardTitle`，
        /// 只抬 `pageTitle` 而把这一档留在 18 会破链，且报的是「字号顺序」而不是「值不对」，
        /// 很容易被误归因成别人改坏了。
        static let metricMid = TypeToken(name: "metricMid", size: 22, weight: .semibold, design: .default, monospacedDigits: true, lineSpacing: 3)

        // 中文标题 / 正文 / 说明
        static let pageTitle = TypeToken(name: "pageTitle", size: 20, weight: .semibold, design: .default, monospacedDigits: false, lineSpacing: 2)
        static let cardTitle = TypeToken(name: "cardTitle", size: 13, weight: .semibold, design: .default, monospacedDigits: false, lineSpacing: 2)
        /// **分区标题的唯一档**，取代 `cardTitle` 承担这件事。
        ///
        /// 这是对 WS-H §4 的一处修订（本轮 spec §1.1 备案）：无界面里标题是**唯一的分组线索**
        /// —— 没有卡面、没有描边、没有图标底色替它说话 —— 所以它必须比内容更轻、更安静，
        /// 而不是更像一块面板的名字。13pt semibold 会被读成「这里开始有一个盒子」。
        /// 字距 0.6pt 是把它从正文里拎出来的唯一手段。
        static let groupLabel = TypeToken(name: "groupLabel", size: 10, weight: .medium, design: .default, monospacedDigits: false, lineSpacing: 2, tracking: 0.6)
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
            pageTitle, cardTitle, groupLabel, body, narrative, label, microLabel,
            monoBody, monoSmall, monoLabel,
        ]

        /// 承载实时数字的档位——单测据此守住 monospacedDigit。
        static let numericTiers: [TypeToken] = [heroMetric, metricNumber, metricMid,
                                                 monoBody, monoSmall, monoLabel]
    }
}
