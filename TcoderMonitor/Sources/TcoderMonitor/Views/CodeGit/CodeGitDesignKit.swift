import SwiftUI

// MARK: - 代码 / Git 类页面的重样基座（WS-L / WS-P）
//
// 服务对象：`Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**` 五个页面。
// 为什么不放进 `Design/`：`Design/**` 与 `App/Theme.swift` 归总工，本流只被授权改自己
// 那三个视图目录 + 本目录，所以按 AGENTS.md §4「需要新组件写在自己的目录里」落在这里。
// 唯一例外是缺数据四态 `DataAbsence`：#47 把它上提进了 `Design/DataAbsence.swift`
// （全仓单点，见本文件末节的说明）。
// 令牌一律引用既成的 `Theme.Radius / Spacing / Typo / Semantic / Chart / Layout`，
// 本文件不新造任何颜色、字号、圆角或间距数值。
//
// **墨色的四种情况**（风格契约 5 的展开，五页一律照此判，别只认"去色"两个字）：
// - 数据 / 读数 / 文本 → `Theme.Palette.Surface.ink`（34pt 及以上）或 `.primary`（正文）
// - 可点的东西（按钮、链接、展开控件、选中态）→ `Theme.Semantic.accent`，**交互本身就是语义，保留**
// - 状态（风险等级、CVE 严重度、增/删）→ `Theme.Semantic.role(for:)`，**保留**
// - 图表里区分类别的序列色 → `Theme.Chart` 调色板（`CodeGitCategoryColor`），**保留**
// 要砍的只有一种：**把 `info` / `accent` 当"给数字上个颜色"用**。
//
// **本轮（简约无界 M1）它多了一个职责**：五页的分组节奏、井、主角读数、脚注全部
// 只能从这里拿。理由不是洁癖 —— 本流旧守卫 `CodeGitRestyleTests.forbiddenRawValues`
// 把页面层的 `VStack(spacing: Theme.Spacing…)`、`.padding(.vertical` 与 `Divider()`
// 三样都判为违例（`pagesOnly` 那两条正是豁免本目录的），所以页面**写不出**自定义容器，
// 只能调用这里起了名字的档位。规约逼出了正确的结构：节奏是设计系统的，不是每页各摆一次。

// MARK: - 页面骨架：只许一份，所以本目录**不再有一份**

// **这里原来叫 `DataPageScaffold`，本轮删了。**
//
// 总工在 `48443d9` 实拍三家进度时发现全仓并存三份同职责页骨架：
// `Design/ReadoutKit.swift` 的 `Theme.Page.Scaffold`（Health/Logs/Performance 在用）、
// 本文件这份**逐字复制品**（body 完全相同）、以及 WS-W 的 `Views/PerfLogs/BorderlessPage.swift`。
// 那正是「东一个系一个」在代码层的形态。裁定：唯一那份住在 `Design/`，
// 五页改用 `Theme.Page.Scaffold`，`BorderlessSurfaceGuardTests.test_exactlyOnePageScaffold`
// 在 M2 强制只许一份。
//
// 随之修正的是档位分工：基座那份把 `Spacing.section`(40) 落在**页顶/页底留白**，
// 页面内是单层 `Spacing.group`(32)。所以我原来那层 `PageParagraph`(40) 一并删掉 ——
// 留着它就会出现「页内段落 40 > 页边距外 32」的倒挂，等于自己造第二条骨架。

/// **主分组**容器（`Spacing.group` = 32）。把属于同一次阅读的几块绑在一起。
///
/// 页面里不许自己写 `VStack(spacing: Theme.Spacing…)` 来排 `GlassSection`：
/// 两条规矩从不同方向逼到同一个结论 —— `CodeGitRestyleTests.forbiddenRawValues`
/// 把那种紧贴写法判为 `pagesOnly` 违例（基座豁免，因为容器实现只能写在基座），
/// `CodeGitBorderlessTests.handRolledGroupContainers` 则直接抓「VStack 里排着 section」。
/// 理由是同一个：**间距一旦由页面各自摆，档位就不归设计系统管了**。
struct GroupStack<Content: View>: View {
    var spacing: CGFloat = Theme.Spacing.group
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - 主角读数（风格契约 4：最重的墨给最大的数）

/// 页面的**唯一主角读数**：56pt + `Surface.ink` 纯墨。
///
/// 三条硬规则，都由 `CodeGitBorderlessTests` 机器钉住：
/// 1. **每页最多一个**。旧五页里最大 56、次大 34 各涂各的倾向色，眼睛找不到主角。
/// 2. **必须给纯数字**。含中文的读数落在 10~22pt（spec §7 风险 4：中文在 56pt 下偏笨重）。
/// 3. **一律纯墨**。`Theme.Palette.Surface.ink`，`.primary` 不够黑（实测 `labelColor`
///    只有 85% 不透明黑，铺在 `ground` 上合成约 `#262626`，正是重构前全页最暗像素的来源）。
struct DataHeroReadout: View {
    /// 主角本体。只放数字与单位符号，中文标签交给 `note`。
    let value: String
    /// 紧跟其后的单位（`次` / `行` / `%`）。它属于主角，但只有 `label`(11) 高。
    var unit: String?
    /// 一句话口径，11pt `.secondary`。诚实性文案的常见落点，**不许省**。
    var note: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Spacing.xs) {
            // 三个渲染点都必须查表：`Text(变量)` 走 verbatim 初始化，
            // 目录里翻了也不会变（双语方案 §7.1）。`DataHeroReadout` 住在 Views/
            // 而守卫 5 原来只扫 Design/ ⇒ 这里是漏网的渲染点（英文实拍抓到）。
            Text(localizedCopy(value))
                .typed(Theme.Typo.heroMetric)
                .foregroundStyle(Theme.Palette.Surface.ink)
                .contentTransition(.numericText())
            if let unit {
                Text(localizedCopy(unit))
                    .font(CodeGitType.prose(Theme.Typo.label))
                    .foregroundStyle(.secondary)
            }
            if let note {
                Text(localizedCopy(note))
                    .font(CodeGitType.prose(Theme.Typo.label))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Spacing.xs)
        }
    }
}

// MARK: - 读数带（去面）

/// 横向读数带：若干 `DataReadout` 排成一行，列间竖发丝线，**不画面**。
///
/// 为什么不用 `Design/DataTable.swift` 的 `DataReadoutBar`：它给读数画了一层**井**
/// （`.contentInset`），而风格契约 3 把井限定给「表格 / 日志列表 / 代码块」——
/// 聚合数字不是表格。旧五页有 7 处走它，于是全页到处是灰底方块，正是「脏」的形态之一。
///
/// 为什么不用 `Design/SharedComponents.swift` 的 `ReadoutStrip` 而要在本目录另立一个：
/// `ReadoutStrip` 的文档要求调用方自己在列间插 `Divider()`，而本流旧守卫把页面层的
/// `Divider()` 判为违例（「旧分隔线」那条禁令，`pagesOnly = false`，全四目录生效）。
/// 两头都走不通，于是这里给一根有名字的竖线：`Rectangle` + `Surface.separator`，
/// 宽度取 `Stroke.hairline`，页面里不再出现 `Divider()` 字面。**已作为契约缺口报总工。**
// `DataReadoutBand` 已删：它与基座 `ReadoutStrip` 的 body **逐字相同**
// （同一个 `HStack(alignment: .top, spacing: lg)` + 同一条 `frame(maxWidth:.infinity,.leading)`），
// 是"同一件事两种画法"里最纯粹的一种。三处调用点全部改走 `ReadoutStrip`。

// `DataBandSeparator` 已上提到 `Design/SharedComponents.swift`：
// 它是全站**唯一**的竖线画法，留在某个页面目录里就会被再抄一份。

// MARK: - 表格井（风格契约 3 里内容层唯一允许的实心底）

/// 把「列头 + 数据行」整体嵌进实心井。
///
/// 井是无界面**唯一**保留的面，且只给表格 / 日志 / 代码块这三类「有行列结构、
/// 需要横向对齐扫读」的内容。它给的不是装饰，是**列对齐的版框**：
/// 地面(单一) → 井(`well`) → 行内容，三层里只有井有边。
///
/// `DataTableHeader` 末尾自带一条发丝分隔线，所以井内顶部不需要再补。
struct DataTableWell<Content: View>: View {
    var spacing: CGFloat = DataRowMetrics.rowGap
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: spacing) {
            content
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.vertical, Theme.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(layer: .contentInset, shape: .rounded(Theme.Radius.card))
    }
}

// MARK: - 脚注层（口径说明的归宿）

/// 组脚注：10pt + `.secondary`。口径说明、「另有 N 个未展示」、窗口标注都落这儿。
///
/// 存在理由有两条，都不是审美：
/// 1. **`.tertiary` 不得落在测得值上**。旧五页 21 处 `.tertiary` 里一大半是数字，
///    「没有主次」在文字侧的成因就是把它当成了"次要到可以不读"的颜色。
///    脚注要的是"小"，不是"淡"—— 10pt 已经足够安静，不必再降透明度。
/// 2. 口径说明按 spec §4.1 一律**降排版层级**而不是删掉。信息一个字不少，位置往后挪。
struct DataFootnote: View {
    let text: String
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        // 必须查表：`Text(变量)` 走 verbatim 初始化，目录里翻了也不会变（双语方案 §7.1）。
        // 全仓 8 处 `DataFootnote(text:)` 与 4 处 `DataCaption(text:)` 调用点此前都从这两行直出，
        // 而英文目录里早就有它们的键 —— `DataFootnote` 侧的「点击行在 Finder 中定位源文件…」
        // 与 `DataCaption` 侧的「该清单没有解析出可枚举的依赖项。」：键在、不查，等于没翻。
        Text(localizedCopy(text))
            .font(CodeGitType.prose(Theme.Typo.microLabel))
            .foregroundStyle(.secondary)
            .multilineTextAlignment(alignment == .leading ? .leading : .center)
            .frame(maxWidth: .infinity, alignment: alignment == .leading
                ? .leading : .center)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// 组内说明句：12pt 正文级口径，比脚注高一档。
/// 用在「这句话会改变上面那个数字怎么读」的地方（分母口径、含不含测试代码…）。
struct DataCaption: View {
    let text: String

    var body: some View {
        // 同 `DataFootnote`：查表之后 `text:` 槽里的键才会真的生效。
        Text(localizedCopy(text))
            .font(CodeGitType.prose(Theme.Typo.narrative))
            .lineSpacing(Theme.Typo.narrative.lineSpacing)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - 排版取用

/// 本流页面的取字入口。数值一律不写死，全部从 `Theme.Typo` 取档。
///
/// 本轮收掉了最后一个自造档：旧 `tableIdentifier` 从 `label`(11) 借字号再换成等宽字面，
/// 那是当时「设计系统没有 11pt 等宽档」的临时绕行（已记为契约缺口 #34）。
/// M0 之后 `Theme.Typo.monoLabel` 就是那一档（11pt medium monospaced + 等宽数字），
/// 所以这里改成纯转发 —— 本目录从此不再有裸 `Font.system(size:)`，
/// 全仓仅存的一处落在 `Design/ThemeTokens.swift` 的 `TypeToken.font`（令牌工厂，合法）。
enum CodeGitType {
    /// 表格主标识符（函数名、文件名、依赖名）：11pt 等宽，层级靠颜色与字重区分而非字号。
    static let tableIdentifier = Theme.Typo.monoLabel.font
    /// 路径 / SHA / 邮箱等次要等宽文本。
    static let path = Theme.Typo.monoSmall.font
    /// 表格与读数条里的数字。等宽数字是硬要求：数字列宽度不能随值变化。
    static func number(_ tier: Theme.TypeToken) -> Font { tier.font.monospacedDigit() }
    /// 读数条的标签档。
    static let readoutLabel = prose(Theme.Typo.label)

    /// 说明性文字的取字入口：一律附等宽数字。
    ///
    /// 说明句里常夹着数字（"另有 12 个未展示"、"含 23 次合并"），刷新时这些数字同样会位移；
    /// 与其逐处记得加 `.monospacedDigit()`，不如让页面取"散文档"时自动带上。
    /// 数值档（`metricMid` / `metricNumber` / `heroMetric` / `mono*`）本身已开等宽，无需走这里。
    static func prose(_ tier: Theme.TypeToken) -> Font { tier.font.monospacedDigit() }
    static let metric = number(Theme.Typo.metricMid)
}

// MARK: - 图标取用

/// 本流页面的图标出口。已登记的走 `ThemedIcon` / `IconName`；
/// 登记表尚未收录、但页面确实需要的符号集中在这一处命名，
/// 并沿用 `Image.themeIcon(_:)` 的"尺寸字重跟随文本"规则，不再散写 `.system(size:)`。
/// 已作为契约缺口报总工：`calendar`、`clock`、`flag`、`lightbulb`、`square.grid.3x3`、
/// `arrow.up.forward.app` 建议下沉进 `IconName`。
enum CodeGitSymbol {
    /// 解析登记表符号（带旧系统兜底链）。
    static func resolve(_ name: IconName) -> String { IconAvailability.resolve(name) }

    static let openExternal = "arrow.up.forward.app"
    static let calendar = "calendar"
    static let recency = "clock.arrow.circlepath"
    static let marker = "flag"
    static let suggestion = "lightbulb"
    static let parameters = "tray.full"
    static let longFunction = "arrow.up.left.and.arrow.down.right"
    static let comments = "text.bubble"
    static let outdated = "arrow.down.circle"
    static let expand = "chevron.down"
    static let collapse = "chevron.up"

    /// 装饰性图标：尺寸与字重跟随它所属的文字语境（[HIG-S]）。
    /// 一律 `.secondary` —— 图标属结构，结构去色（风格契约 5）。
    static func decorated(_ symbol: String, role: IconRole = .badge) -> some View {
        Image(systemName: symbol).themeIcon(role)
    }
}

extension MetricTile {
    /// 用图标登记表创建指标 tile。`Design/SharedComponents` 的 `systemImage:` 至今收裸串，
    /// 这个入口把 `IconName`（含旧系统兜底解析）接上，页面里就不再出现字符串字面量。
    ///
    /// ⚠️ **`tint` 的默认值这一层就是本轮的一条病灶**。M0 只把
    /// `Design/SharedComponents.swift` 里 `MetricTile.init` 的默认改成了纯墨，
    /// 而这两个转发入口各自又默认回 `accent` —— **默认值盖不过显式传参，
    /// 更盖不过第二层默认值**。结果是基座已经改绿、页面照旧一片蓝。
    /// 现在转发入口与基座对齐：不传 = 纯墨，传 `role:` = 语义色。
    init(
        label: String,
        value: String?,
        icon: IconName?,
        unit: String? = nil,
        caption: String? = nil,
        tint: Color = Theme.Palette.Surface.ink,
        captionLineLimit: Int? = nil
    ) {
        self.init(label: label, value: value, unit: unit, caption: caption, tint: tint,
                  systemImage: icon.map(CodeGitSymbol.resolve),
                  captionLineLimit: captionLineLimit)
    }

    /// 登记表还没收录、但在 `CodeGitSymbol` 里集中命名过的符号走这个入口。
    /// 参数顺序与 `icon:` 版一致，页面不必记住 memberwise init 的形参次序。
    init(
        label: String,
        value: String?,
        symbol: String?,
        unit: String? = nil,
        caption: String? = nil,
        tint: Color = Theme.Palette.Surface.ink,
        captionLineLimit: Int? = nil
    ) {
        self.init(label: label, value: value, unit: unit, caption: caption, tint: tint,
                  systemImage: symbol, captionLineLimit: captionLineLimit)
    }

    /// 带**语义**结论的 tile（风险等级、CVE 严重度、增/删）。
    /// 刻意只有一个收 `Theme.SemanticRole` 的形状：`info` / `accent` 不在可选范围内，
    /// 因为它们是交互色而不是状态色。`CodeGitBorderlessTests` 另扫一遍调用点。
    init(
        label: String,
        value: String?,
        role: Theme.SemanticRole?,
        icon: IconName? = nil,
        symbol: String? = nil,
        unit: String? = nil,
        caption: String? = nil,
        captionLineLimit: Int? = nil
    ) {
        self.init(label: label, value: value, unit: unit, caption: caption,
                  tint: role?.textColor ?? Theme.Palette.Surface.ink,
                  systemImage: icon.map(CodeGitSymbol.resolve) ?? symbol,
                  captionLineLimit: captionLineLimit)
    }

// 无值时基座强制中性色（`MetricTile.forcesNeutralTint`），有值时用调用方给的**语义**角色，
// 没给角色就是纯墨。本目录不重写这条规则，只转发给 `Design/` 的纯函数。
}

extension EmptyStateView {
    /// 空态图标改走登记表，避免页面里写 `"checkmark.seal"` 这类未登记裸串。
    init(icon: IconName, title: String, message: String) {
        self.init(icon: CodeGitSymbol.resolve(icon), title: title, message: message)
    }
}

// MARK: - 展开/收起（>6 行同类条目的合法归宿）

/// 一行「展开其余 N 项」。风格契约 2 不允许它有底色，所以它是**文字按钮 + chevron**，
/// 是控件而不是面板；`accent` 在这里是合法的（交互语义）。
///
/// 存在理由：自查清单第 4 条要求「一组里 > 6 行同类条目就拆组或收进可展开区」。
/// 旧页里巨大文件榜默认 20 行、贡献者排行 30 行、最近提交 20 行，全部一次摊开，
/// 于是「不规整拥挤」。折叠掉的部分必须由**计数**交代清楚，不能静默截断。
struct DataDisclosureButton: View {
    let expanded: Bool
    let hiddenCount: Int
    let noun: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.Spacing.xxs) {
                // 符号走 `CodeGitSymbol` 的命名常量：页面里出现 `Image(systemName: "…")`
                // 裸串是本流旧守卫的禁令，基座是它唯一的合法落点。
                CodeGitSymbol.decorated(expanded ? CodeGitSymbol.collapse : CodeGitSymbol.expand,
                                        role: .inlineText)
                Text(Self.title(expanded: expanded, hiddenCount: hiddenCount, noun: noun))
                    .font(CodeGitType.prose(Theme.Typo.label))
            }
            // `accent` 在这里合法：整行是一个可点控件，蓝=交互是它自己的语义。
            .foregroundStyle(Theme.Semantic.accent.textColor)
            .frame(minHeight: Theme.Layout.minHitTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Self.title(expanded: expanded, hiddenCount: hiddenCount, noun: noun))
    }

    /// 文案纯函数：折叠时说清「还有多少」，展开后说清「收起」。**不出现"更多"这种无计数说法**。
    static func title(expanded: Bool, hiddenCount: Int, noun: String) -> String {
        if expanded { return "收起 \(NumberFormat.grouped(hiddenCount)) \(noun)" }
        return "展开其余 \(NumberFormat.grouped(hiddenCount)) \(noun)"
    }
}

// MARK: - 分类色

/// 分类色取色：按稳定键取全 App 唯一的一套 `Theme.Chart` 色板。
///
/// 必须稳定：Swift 的 `hashValue` 每进程随机化，拿它取色会让同一语言 / 同一作者
/// **每次启动换一种颜色**（WS-I §2.1① 点名的缺陷）。这里改用 FNV-1a。
///
/// 风格契约 5 的位置：这是「只在需要区分类别时上色」的那半，与「数据涂蓝」不冲突 ——
/// 语言、作者、生态是**类别**，颜色在图上替读者把同一个类别的两处连起来。
enum CodeGitCategoryColor {
    /// 成员序列色从 1 号开始：`Theme.Chart` 的 0 号蓝是"主/自身数据"，
    /// 占比条里的**合计行**就用它。成员若也能取到 0，就会出现"合计行与某一位成员同色"
    /// 这种看着像高亮、其实只是撞色的读错。
    static func index(for key: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in key.lowercased().unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        let memberSlots = max(1, Theme.Chart.count - 1)
        return 1 + Int(hash % UInt64(memberSlots))
    }

    /// 合计/自身数据色，恒定取色板 0 号。
    static let aggregateIndex = 0

    static func color(for key: String) -> Color { Theme.Chart.color(at: index(for: key)) }
}

// MARK: - 缺数据态
//
// 本流原先在这里自带一份三态 `DataAbsence`。#47 把它**上提进 `Design/DataAbsence.swift`**
// 成全仓单点，并补了第四态 ③ `indeterminate`（除零/分母为 0，与 ④「没扫/没查」不是一回事）。
// 页面一律用那一份，不要再在本目录里补第二个枚举。
