import AppKit
import SwiftUI

// MARK: - SF Symbols 规则（对齐《40 WS-H 设计语言规范》§6）
//
// 四条硬规则，页面不要自己挑字号：
//   1. **尺寸跟随文本**：图标只声明"它旁边/替代的是哪一档文字"（`IconRole`），
//      由本层换成对应的 `Font.system(textStyle)`。全仓禁止 `.font(.system(size: N))` 画图标。
//   2. **字重跟随文本**：卡头图标随 `.headline`（semibold），行内随正文（regular）。
//   3. **变体表意**：`fill` = 选中/强调（侧栏当前项、结论确认），`slash` = 不可用，
//      默认非 fill = 未选中/普通。同一个动作在全 App 用同一个符号。
//   4. **无障碍**：纯图标必须给 `label:`（同时写 `.help`）；紧邻已有文字的装饰图标
//      才允许省略 label 转为装饰性隐藏——否则读屏会把"刷新 重新分析"念两遍。

/// 图标所处的文字语境。尺寸与字重都从这里推导，不再有独立的图标字号刻度。
enum IconRole: CaseIterable {
    /// 侧栏条目 / 页面入口（跟 `.title2`，semibold）
    case navigation
    /// 卡片标题左侧（跟 `.headline`，semibold）
    case cardHeader
    /// 与正文同行的装饰（跟 `.body`，regular）
    case inlineText
    /// 徽标、表格行内（跟 `.caption`，medium）
    case badge
    /// 空态大图（跟 `.largeTitle`）
    case hero

    /// 它替代的是哪一档正文样式。单测靠这个字段断言五档互不重复
    /// （`Font` 本身不可比较：`String(describing:)` 五档全打印成同一个 box）。
    var textStyle: Font.TextStyle {
        switch self {
        case .navigation: return .title2
        case .cardHeader: return .headline
        case .inlineText: return .body
        case .badge: return .caption
        case .hero: return .largeTitle
        }
    }

    /// 跟随文本的字重；nil = 用该语义样式自带的字重。
    var weight: Font.Weight? {
        switch self {
        case .navigation: return .semibold
        case .cardHeader: return nil        // .headline 本身就是 semibold
        case .inlineText: return nil        // .body = regular
        case .badge: return .medium
        case .hero: return nil              // .largeTitle 默认。规范允许图标用 light，
                                            // 但文字一律不得用细字重表达次要（WS-H §4.2）
        }
    }

    var font: Font { .system(textStyle, weight: weight) }
}

/// 符号在本机解析不到时的兜底链。
///
/// 必要性：部署下限是 macOS 14，而 WS-H 选型表里有若干 macOS 15/26 才收进 SF Symbols 的
/// 新符号（`gauge.with.dots.needle.*`、`heart.text.square`、`function`、`exclamationmark.octagon`…）。
/// `Image(systemName:)` 遇到不存在的符号会画成空白，旧系统上就是"图标整片消失"，
/// 所以这一层非空校验 + 兜底必须在设计系统内做掉（WS-H §6.1 亦要求）。
enum IconAvailability {
    /// 只在本表登记过的候选符号里做一次求值；static let 保证线程安全且只跑一次。
    private static let missing: Set<String> = {
        var absent: Set<String> = []
        for name in IconName.allCases {
            if NSImage(systemSymbolName: name.rawValue, accessibilityDescription: nil) == nil {
                absent.insert(name.rawValue)
            }
        }
        return absent
    }()

    static func isAvailable(_ symbol: String) -> Bool { !missing.contains(symbol) }

    static func resolve(_ name: IconName) -> String {
        isAvailable(name.rawValue) ? name.rawValue : name.fallbackSymbol
    }
}

/// 全仓图标登记表。`rawValue` 是首选符号，`fallbackSymbol` 是旧系统兜底，
/// `selectedSymbol` 是选中/强调态。新增图标必须先进这张表。
enum IconName: String, CaseIterable {
    // — 九页导航（WS-H §6.2；选中态一律 .fill，未选中非 fill）
    case dashboard = "square.grid.2x2"
    case code = "curlybraces"
    case complexity = "function"
    case git = "arrow.triangle.branch"
    case people = "person.2"
    case performance = "gauge.with.dots.needle.67percent"
    case logs = "doc.text.magnifyingglass"
    case package = "shippingbox"
    case health = "heart.text.square"

    // — 指标 / 资源（WS-H §6.3）
    case cpu = "cpu"
    case memory = "memorychip"
    case disk = "internaldrive"
    case network = "network"
    case processes = "list.bullet"
    case handles = "folder.badge.gearshape"
    case pressure = "gauge.with.dots.needle.bottom.50percent"
    case temperature = "thermometer.medium"

    // — 风险 / 严重度徽标（WS-H §6.4）
    case noRisk = "checkmark.circle"
    case riskWarning = "exclamationmark.triangle"
    case riskSevere = "exclamationmark.octagon"
    case crash = "ladybug.fill"
    case vulnerable = "xmark.shield"
    case clean = "checkmark.shield"
    case duplicate = "doc.on.doc"
    case info = "info.circle"

    // — 趋势 / 行动（WS-H §6.5）
    case trendUp = "arrow.up.right"
    case trendDown = "arrow.down.right"
    case trendFlat = "arrow.right"
    case reanalyze = "arrow.clockwise"
    case refresh = "arrow.triangle.2.circlepath"
    case add = "plus.circle"
    case remove = "xmark.circle"
    case pause = "pause.circle"
    case play = "play.circle"
    case topContributor = "crown.fill"
    case chartLine = "chart.line.uptrend.xyaxis"
    case disclose = "chevron.right"
    case attach = "paperclip"
    case emptyTray = "tray"
    case emptyUnknown = "doc.questionmark"

    /// 「根本没查所以没有命中」——WS-D 诚实线专用，绝不可与 `noRisk`（真核对过的无风险）混用
    case unverified = "questionmark.circle"

    // — 从 WS-L `CodeGitSymbol` 收编：他们当时只能在页面侧集中命名，因为登记表没这些
    case openInApp = "arrow.up.forward.app"
    case calendar = "calendar"
    case history = "clock.arrow.circlepath"
    case marker = "flag"
    case suggestion = "lightbulb"
    case parameters = "tray.full"
    case expand = "arrow.up.left.and.arrow.down.right"
    case comments = "text.bubble"
    case outdated = "arrow.down.circle"
    case refactor = "scissors"
    case verdictClean = "checkmark.seal"
    case gridDense = "square.grid.3x3"

    // — 表格排序指示（三枚都得有，页面才不会各挑各的箭头）
    case sortNeutral = "chevron.up.chevron.down"
    case sortAscending = "arrow.up"
    case sortDescending = "arrow.down"

    // — 既有条目的兼容别名：rawValue 曾直接是 .fill 形态，导航层现改由 selected 驱动
    case pulse = "waveform.path.ecg"

    /// 默认档位。页面只在需要偏离时显式传 `role`。
    var role: IconRole {
        switch self {
        case .dashboard, .code, .complexity, .git, .people, .performance,
             .logs, .package, .health, .pulse:
            return .navigation
        case .riskSevere, .riskWarning, .crash, .noRisk, .vulnerable, .clean,
             .topContributor, .info, .duplicate:
            return .badge
        case .emptyTray, .emptyUnknown:
            return .hero
        case .unverified, .sortNeutral, .sortAscending, .sortDescending,
             .marker, .outdated, .verdictClean:
            return .badge
        case .openInApp, .calendar, .history, .suggestion, .parameters, .expand,
             .comments, .refactor, .gridDense:
            return .inlineText
        default:
            return .inlineText
        }
    }

    /// 选中/强调态符号（侧栏当前项、结论确认）。nil = 该符号没有 fill 语义。
    var selectedSymbol: String? {
        switch self {
        case .dashboard: return "square.grid.2x2.fill"
        case .people: return "person.2.fill"
        case .package: return "shippingbox.fill"
        case .health: return "heart.text.square.fill"
        case .code: return "curlybraces"          // 无 fill 变体，强调靠前景色
        case .git: return "arrow.triangle.branch"
        case .logs: return "doc.text.magnifyingglass"
        case .noRisk: return "checkmark.circle.fill"
        case .riskWarning: return "exclamationmark.triangle.fill"
        case .riskSevere: return "exclamationmark.octagon.fill"
        case .clean: return "checkmark.shield.fill"
        case .vulnerable: return "xmark.shield.fill"
        case .pause: return "pause.circle.fill"
        case .play: return "play.circle.fill"
        case .add: return "plus.circle.fill"
        case .remove: return "xmark.circle.fill"
        case .refresh: return "arrow.triangle.2.circlepath"
        case .reanalyze: return "arrow.clockwise"
        default: return nil
        }
    }

    /// 旧系统兜底符号（WS-H §6.1 要求逐个校验存在性）。
    var fallbackSymbol: String {
        switch self {
        case .performance, .pressure: return "waveform.path.ecg"
        case .health: return "checkmark.shield"
        case .complexity: return "sum"
        case .memory: return "square.stack.3d.up"
        case .temperature: return "thermometer"
        case .riskSevere: return "exclamationmark.triangle.fill"
        case .crash: return "exclamationmark.triangle.fill"
        case .vulnerable: return "xmark.circle"
        case .topContributor: return "star.fill"
        case .emptyUnknown: return "tray"
        case .duplicate, .handles: return "doc.on.doc"
        case .processes: return "list.bullet"
        default: return rawValue
        }
    }
}

/// 图标的唯一渲染入口：符号存在性、选中态、跟随文本的尺寸与字重、无障碍一次装配。
struct ThemedIcon: View {
    var name: IconName
    var role: IconRole
    /// 选中/强调态：true 时换 `selectedSymbol`（WS-H §6.1 规则 3）。
    var selected: Bool
    /// 无障碍标签。传 nil = 装饰性图标（紧邻已有文字），对读屏隐藏。
    var label: String?

    init(_ name: IconName, role: IconRole? = nil, selected: Bool = false, label: String? = nil) {
        self.name = name
        self.role = role ?? name.role
        self.selected = selected
        self.label = label
    }

    private var symbol: String {
        let base = IconAvailability.resolve(name)
        guard selected, let fill = name.selectedSymbol,
              IconAvailability.isAvailable(fill) else { return base }
        return fill
    }

    var body: some View {
        let image = Image(systemName: symbol)
            .font(role.font)
            .symbolRenderingMode(.hierarchical)
        if let label {
            image.accessibilityLabel(label).help(label)
        } else {
            image.accessibilityHidden(true)
        }
    }
}
