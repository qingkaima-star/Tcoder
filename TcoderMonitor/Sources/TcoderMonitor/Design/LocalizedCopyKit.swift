import SwiftUI

// 本文件是 `Design/ReadoutKit.swift` 的分片（WS-X8 实现文件规模闸门）。
// 搬的理由是机械的：本 App 自扫点名宿主文件越过「巨大文件」线
// （`FileSystemCodeAnalyzer.mediumFileLines` = 400 行），而这条口径现在由
// `SourcesSizeAuditTests` 机器把守。**一个取值、一处画法都没改**，搬的只是文件位置。
// 下面自宿主文件逐字搬入，`// MARK:` 小节名照旧。

// MARK: - 文案查表出口（双语方案 §5 P3）

/// **组件渲染点**的查表出口。
///
/// 为什么必须有这一层：`Text(变量)` 天生不查表（双语方案 §7.1）。目录里翻了、
/// 机制也通了，界面一个字都不动 —— 这是双语最容易的空转。2026-09-21 用
/// `-AppleLanguages "(en)"` 实跑证实了这一点：页头「Health Score」和分组标题
/// 「Projects / Analysis」出英文，而侧栏九条页名仍是中文，因为
/// `SidebarRows` 走的是 `Text(section.title)`。
///
/// 组件入参**继续收 `String`**（调用点不 churn，三元表达式与枚举 rawValue 都塞得进来），
/// 只在真正上屏这一行查表。键 = 简体中文原文，所以查不到就原样显示中文 ——
/// 缺一条译文的表现是"退回正确的中文"，不是漏出机器键。
///
/// 为什么走 `Bundle.main`：语言资源不能进 `Package.swift` 的 `resources:`
/// （那只会产出 `TcoderMonitor_TcoderMonitor.bundle`，而 `Text` 查的是 `Bundle.main`），
/// 实际由 `scripts/build_app.sh` 拷进 `Contents/Resources`，一个 `.lproj` 都没拷到就拒绝出包。
///
/// 为什么**不**用 `String(format:)`：裸 `%` 会被静默吃掉（实测「95% 的提交…」→「95 的提交…」，
/// 双语方案 §9）。这里是纯查表，`%` 只是普通字符，与今天 `Text("95% …")` 的行为一致。
/// 带实参的文案要翻时另开显式映射（`var uiLabel`），不要往这里塞占位符。
func localizedCopy(_ text: String) -> String {
    let resolved = NSLocalizedString(text, bundle: .main, comment: "")
    LocalizationLedger.shared.record(key: text, translated: resolved != text)
    return resolved
}

/// **运行时漏翻台账**（报告器，不是闸门）。
///
/// 为什么必须有它：静态扫描只能覆盖"入口白名单里的字面量"，而英文态实拍证明
/// 三类串全在盲区 —— 拼接出来的整句、组件的**位置参数**、变量喂进组件的值。
/// 静态棘轮报 28 条的那一趟，贡献者页面上仍有一整段中文。
/// 只有**渲染的那一刻**才知道某个串有没有真的上屏、有没有查到译文。
///
/// 开关是环境变量：不设时 `record` 第一次判断就返回，渲染路径零成本；
/// 设了就往 `<path>.misses` / `<path>.hits` 写两份清单（退出时落盘）。
/// 记的是**去重后的键**，不是每次渲染的流水 —— 一屏 60fps 会把文件写爆。
final class LocalizationLedger {
    static let shared = LocalizationLedger()

    private let lock = NSLock()
    private var misses = Set<String>()
    private var hits = 0
    private let target: String? = ProcessInfo.processInfo
        .environment["TCODER_I18N_RUNTIME_LEDGER"]

    private var wrote = 0

    func record(key: String, translated: Bool) {
        guard target != nil else { return }
        lock.lock()
        if translated { hits += 1 } else { misses.insert(key) }
        // **不能只在 `atexit` 落盘**：取证脚本发的是 SIGTERM，`atexit` 不跑，
        // 第一版就是这么白跑一趟。改成"每 200 次查表、以及每次出现新漏翻键"时落盘。
        let shouldWrite = !translated ? misses.count != wrote : (hits % 200 == 0 && hits > wrote)
        if shouldWrite { wrote = hits + misses.count }
        lock.unlock()
        if shouldWrite { flush() }
    }

    func flush() {
        guard let target, !target.isEmpty else { return }
        lock.lock()
        let missList = misses.sorted(), hitCount = hits
        lock.unlock()
        let url = URL(fileURLWithPath: target)
        if (try? String(contentsOf: url, encoding: .utf8))?.hasPrefix("hits=\(hitCount)") == true,
           missList.isEmpty { return }   // 内容没变就别重写（每 200 次一次）
        try? "hits=\(hitCount)\nmisses=\(missList.count)\n"
            .appending(missList.map { "\"\($0)\"" }.joined(separator: "\n")).appending("\n")
            .write(to: url, atomically: true, encoding: .utf8)
    }
}

/// 带实参的整句查表 + 格式化。
///
/// **写法是硬约束**：占位符用位置式（`%1$@`、`%@`），而句子里的**字面百分号必须写 `%%`**。
/// `String(format:)` 遇到裸 `%` 后面跟非转换字符会静默吃掉尾巴（实测
/// 「95% 的提交…」→「95 的提交…」，方案 §9）—— 不崩、不报错，
/// 一个诚实性陈述就这么被改义。
///
/// 键查不到时 `String(format: 键, args)` 仍然把占位符填回中文原句，
/// 所以缺一条译文的表现依旧是"退回正确的中文"。
///
/// **实参类型钉死成 `String`，不用 `CVarArg...`。** 2026-09-21 实测：
/// 传一个 `Int` 给 `%@` 直接 `EXC_BAD_ACCESS`（崩在
/// `_NSDescriptionWithStringProxyFunc`，栈顶就是 `localizedFormat`），
/// 而 `CVarArg...` 让这种写法**编译得过**。本仓所有数字都先过
/// `NumberFormat.grouped` / `percentOf100` 变成字符串，收 `String` 不损失表达力，
/// 却把这一类崩溃变成编译错误。
func localizedFormat(_ key: String, _ args: String...) -> String {
    String(format: localizedCopy(key), arguments: args)
}

/// 数量类文案的入口（要过 `stringsdict` 的单复数规则）。
///
/// 实参**只收 `Int`**，键里的占位符**只准 `%lld`**：
/// - `stringsdict` 只有拿到数字才会选 `one` / `other` 分支（英文 1 month ago / 3 months ago），
///   而中文原文里根本没有这个区分 —— 机翻最容易在这里翻错；
/// - `Int` 传给 `%@` 会当场段错误（P3-4 那次启动即崩就是这么来的），
///   所以这里既不收 `CVarArg...`，也不复用收 `String` 的 `localizedFormat`。
///
/// 中文侧不受影响：`String(format: "%lld 秒前", 5)` 就是「5 秒前」，
/// 与原来的 `"\(seconds) 秒前"` 一字不差。
///
/// ⚠ **填完之后补千分位**，否则量词族与全站大读数是两套记法：
/// 交付头实拍「代码规模」语言构成那一列打的是 `46330 行`，
/// 而同页的总行数打的是 `77,515`，同一个量的两种写法在同一屏上并排。
/// 为什么不在键里写分组标志：实测 `String(format:)` **不认** `%'lld`
/// （打出来是字面量 `'lld 行`），而 `stringsdict` 的复数规则又必须拿到数字才能选
/// `one` / `other` ⇒ 分组只能在填完之后做。见 `LocalizedCopyKitTests.testCountsGetTheSameSeparators`。
func localizedCount(_ key: String, _ count: Int) -> String {
    let filled = String(format: localizedCopy(key), count)
    return groupedInto(filled, count: count)
}

/// 把上一步刚填进去那串数字换成千分位。
///
/// 只替换**第一次出现的、正好等于 `count` 字面**的那一串 —— 那正是我们刚插进去的 token；
/// 译文里自带的数字（例如某个单位串里的 "1024"）不会被误伤，因为它不会恰好等于本数的字面
/// 且排在前面。凑不齐两位分隔的（< 1000）原样返回。
func groupedInto(_ text: String, count: Int) -> String {
    guard count >= 1_000 else { return text }
    let digits = String(count)
    guard let range = text.range(of: digits) else { return text }
    var result = text
    result.replaceSubrange(range, with: NumberFormat.grouped(count))
    return result
}

/// 给一句已经组装好的产品散文补句末标点，**标点随语言走**。
///
/// 为什么要有这一枚：`crashEvidenceFootnote` 那一族是"若干整句键 + ` · ` 组装"，
/// 每一句自己不带句号（带上就多分句中间全是句号），句号只能在**最后**补一次。
/// 写死 `"。"` 的话，英文态那一格会长这样：
/// `Crash confirmed 4 times… · 2 more…。` —— 尾巴是一个汉字标点，
/// 而屏上正文台账那把尺子按**码点**判"这段还残留中文"，
/// 于是这一行修完键照样是红的（`。` = U+3002，落在中日韩标点段内）。
///
/// `chinese` 有默认值、调用方一律不传：测试宿主的 `Bundle.main` 里没有 `en.lproj`，
/// 语言探针在那儿**恒判中文**，两个分支只有一个能在进程内测到。
/// 把它做成入参，是为了让元测试能把英文那一支也咬一次（正对照），
/// 英文态真实渲染另有十八趟读数在外process复核。
func endingSentence(_ text: String, chinese: Bool = Theme.Layout.isChineseUI) -> String {
    text + (chinese ? "。" : ".")
}

// MARK: - 展开/收起的量词（批次 P56）
//
// 为什么住在这本里：这一族是**文案词汇**，不是画法 —— 画法在
// `Views/CodeGit/CodeGitDesignKit.swift` 的 `DataDisclosureButton`。
// 它也不能留在原来那个文件里：那份加完 440 行，撞上实现文件 400 行线
// （阈值冻结，拆才是修复）。

/// 展开/收起按钮的**量词**。
///
/// 为什么从"一个中文字符串参数"改成枚举（批次 P56）：
/// 中文不需要复数，英语需要 —— `"展开其余 \(n) " + noun` 这种写法在英文态要么整句中文
/// （`ax_body_audit` 的 B 类里这一族有 7 句 / 14 次），要么退化成
/// "Show 1 more commits" 这种语法错。复数只能由 `Localizable.stringsdict` 管，
/// 而 stringsdict 认的是**整句键**，不是"前缀 + 变量"。
///
/// 键写成 `switch` 里的**字面量**而不是拼串：拼出来的串没有可查的整句键，
/// 那正是 P53 立的守卫 1d【拼了查不中】要判红的那一族。
enum DisclosureNoun {
    case commits, functions, files, processes, contributors
    case duplicateBlocks, cappedBlocks, undisplayed, items

    /// 全站唯一一份成员清单。加一个量词只改这里，
    /// `DisclosureNounCopyTests` 会逐个 case 点名要求两本目录里有它的两条键。
    static let allCases: [DisclosureNoun] = [
        .commits, .functions, .files, .processes, .contributors,
        .duplicateBlocks, .cappedBlocks, .undisplayed, .items,
    ]

    var expandKey: String {
        switch self {
        case .commits: return "展开其余 %lld 条提交"
        case .functions: return "展开其余 %lld 个函数"
        case .files: return "展开其余 %lld 个文件"
        case .processes: return "展开其余 %lld 个进程"
        case .contributors: return "展开其余 %lld 位贡献者"
        case .duplicateBlocks: return "展开其余 %lld 个重复块"
        case .cappedBlocks: return "展开其余 %lld 个榜内重复块"
        case .undisplayed: return "展开其余 %lld 个未展示"
        case .items: return "展开其余 %lld 项"
        }
    }

    var collapseKey: String {
        switch self {
        case .commits: return "收起 %lld 条提交"
        case .functions: return "收起 %lld 个函数"
        case .files: return "收起 %lld 个文件"
        case .processes: return "收起 %lld 个进程"
        case .contributors: return "收起 %lld 位贡献者"
        case .duplicateBlocks: return "收起 %lld 个重复块"
        case .cappedBlocks: return "收起 %lld 个榜内重复块"
        case .undisplayed: return "收起 %lld 个未展示"
        case .items: return "收起 %lld 项"
        }
    }
}
