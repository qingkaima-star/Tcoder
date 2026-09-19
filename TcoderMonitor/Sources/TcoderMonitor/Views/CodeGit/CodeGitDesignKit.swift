import SwiftUI

// MARK: - 代码 / Git 类页面的重样基座（WS-L）
//
// 服务对象：`Views/Code/**`、`Views/Git/**`、`Views/Dependencies/**` 五个页面。
// 为什么不放进 `Design/`：`Design/**` 与 `App/Theme.swift` 归 WS-G，本流只被授权改自己
// 那三个视图目录，所以按 AGENTS.md §4「需要新组件写在自己的目录里」落在这里。
// 令牌一律引用既成的 `Theme.Radius / Spacing / Typo / Semantic / Chart / Layout`，
// 本文件不新造任何颜色、字号、圆角或间距数值。

// MARK: - 页面骨架

/// 数据密集型页面的统一骨架：页面左右 16、顶部 24，卡与卡 16，正文列在超宽屏上居中限宽。
///
/// 限宽是规范要求的（WS-H §3.2）：阅读/列表型页面上限 1040，否则在 5K 屏上一行拉到
/// 两千多像素，表格数字与名称之间的关系就断了。
struct DataPageScaffold<Content: View>: View {
    var maxWidth: CGFloat = Theme.Layout.maxWidthReading
    @ViewBuilder var content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.top, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xl)
        }
        .scrollContentBackground(.hidden)
    }
}

// MARK: - 排版取用

/// 本流页面的取字入口。除 `tableIdentifier` 之外全部直接取 `Theme.Typo` 档位；
/// 唯一需要"跨档组合"的地方是表格里的代码标识符——设计系统没有 11pt 等宽档，
/// 这里从 `label`(11pt) 借字号、换成等宽字面，仍然不写死数字。
enum CodeGitType {
    /// 表格主标识符（函数名、文件名、依赖名）：11pt 等宽，层级靠颜色与字重区分而非字号。
    static let tableIdentifier = Font.system(
        size: Theme.Typo.label.size, weight: .medium, design: .monospaced).monospacedDigit()
    /// 路径 / SHA / 邮箱等次要等宽文本。
    static let path = Theme.Typo.monoSmall.font
    /// 表格与读数条里的数字。等宽数字是硬要求：数字列宽度不能随值变化。
    static func number(_ tier: Theme.TypeToken) -> Font { tier.font.monospacedDigit() }
    /// 读数条的标签档。
    static let readoutLabel = Theme.Typo.label.font
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

    /// 装饰性图标：尺寸与字重跟随它所属的文字语境（[HIG-S]）。
    static func decorated(_ symbol: String, role: IconRole = .badge) -> some View {
        Image(systemName: symbol).themeIcon(role)
    }
}

extension MetricTile {
    /// 用图标登记表创建指标 tile。`Design/SharedComponents` 的 `systemImage:` 至今收裸串，
    /// 这个入口把 `IconName`（含旧系统兜底解析）接上，页面里就不再出现字符串字面量。
    init(
        label: String,
        value: String?,
        icon: IconName?,
        unit: String? = nil,
        caption: String? = nil,
        tint: Color = Theme.Semantic.accent.textColor
    ) {
        self.init(label: label, value: value, unit: unit, caption: caption, tint: tint,
                  systemImage: icon.map(CodeGitSymbol.resolve))
    }

    /// 登记表还没收录、但在 `CodeGitSymbol` 里集中命名过的符号走这个入口。
    /// 参数顺序与 `icon:` 版一致，页面不必记住 memberwise init 的形参次序。
    init(
        label: String,
        value: String?,
        symbol: String?,
        unit: String? = nil,
        caption: String? = nil,
        tint: Color = Theme.Semantic.accent.textColor
    ) {
        self.init(label: label, value: value, unit: unit, caption: caption, tint: tint,
                  systemImage: symbol)
    }
}

extension EmptyStateView {
    /// 空态图标改走登记表，避免页面里写 `"checkmark.seal"` 这类未登记裸串。
    init(icon: IconName, title: String, message: String) {
        self.init(icon: CodeGitSymbol.resolve(icon), title: title, message: message)
    }
}

// MARK: - 分类色

/// 分类色取色：按稳定键取全 App 唯一的一套 `Theme.Chart` 色板。
///
/// 必须稳定：Swift 的 `hashValue` 每进程随机化，拿它取色会让同一语言 / 同一作者
/// **每次启动换一种颜色**（WS-I §2.1① 点名的缺陷）。这里改用 FNV-1a。
enum CodeGitCategoryColor {
    static func index(for key: String) -> Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for scalar in key.lowercased().unicodeScalars {
            hash ^= UInt64(scalar.value)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return Int(hash % UInt64(max(1, Theme.Chart.count)))
    }

    static func color(for key: String) -> Color { Theme.Chart.color(at: index(for: key)) }
}

// MARK: - 缺数据三态

/// 数字的三种状态。**把 ③ 渲染成 0 或绿色结论，就是把"没有证据"说成"没有问题"**，
/// 这是监控类 App 最贵的一类错（AGENTS.md §4 / WS-H §7.3）。
enum DataAbsence: Equatable {
    /// ① 有数据：真值字符串，含测得的 0。
    case value(String)
    /// ② 扫过了、确实为空：给 0 并写明「未发现」。
    case measuredEmpty
    /// ③ 没扫 / 不适用 / 扫失败：一律 `--`，不给倾向色、不给对勾。
    case notAnalysed

    /// 数字位显示值。
    var display: String {
        switch self {
        case .value(let text): return text
        case .measuredEmpty: return NumberFormat.grouped(0)
        case .notAnalysed: return Theme.Placeholder.missingValue
        }
    }

    /// 没证据时强制退回中性角色，不接受调用方给的倾向色——「没查」本身不该带倾向。
    /// 返回角色而不是 `Color`：动态色无法在单测里比较，角色名可以。
    func effectiveRole(_ role: Theme.SemanticRole) -> Theme.SemanticRole {
        self == .notAnalysed ? Theme.Semantic.neutral : role
    }

    func tint(_ role: Theme.SemanticRole) -> Color { effectiveRole(role).textColor }

    /// 是否允许给出结论性措辞（绿色对勾、「无风险」之类）。
    var permitsConclusion: Bool { self != .notAnalysed }
}
