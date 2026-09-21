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
func localizedCount(_ key: String, _ count: Int) -> String {
    String(format: localizedCopy(key), count)
}
