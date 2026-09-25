import Foundation

/// 进程入口：**先分派无头模式，再让 SwiftUI / AppKit 上场**。
///
/// 为什么不能把分派写在 `App.init()` 里（这是实测出来的缺陷，不是洁癖）：
/// `@main` 生成的入口会先进入 `NSApplicationMain` 一类的启动流程，
/// `App.init()` 是在 AppKit **正在做窗口状态恢复**的时候被调到的。
/// 那一刻调 `exit()`，退出路径要和没跑完的启动流程收尾一起抢 ——
/// 2026-09-21 实测：`TcoderMonitor score <不存在的路径>` 挂死 11 分钟不出声，
/// 连 `CLIConfig.hardTimeout`（600 秒）那句"超时未回"都没打出来，
/// 进程上挂着 `…/com.tcoder.monitor.savedState/data.data` 与 `windows.plist` 两个 fd。
/// 同一时刻 in-process 的 20 条 CLI 单测全绿 —— 因为它们不走这条启动路径。
///
/// 换到这里之后：命中子命令词就**在任何 AppKit 之前**跑完并退出，
/// 于是无头模式①不会有窗口状态可写（也不该有 —— AI 调用方不需要 GUI 的副作用）、
/// ②不依赖 `NSApplication` 的启动进度、③`--version` 这类即时返回的档位不再和恢复流程抢 teardown。
/// 没命中就把控制权**原样**交给 `TcoderMonitorApp.main()` —— 那正是 `@main` 本来会生成的那一行。
///
/// ⚠️ 2026-09-23 补一条判据（台账 RD-59）：**带参数却认不出子命令词，不再静默起 GUI**。
/// 原缺陷现场：调用方（含 AI 调用方）把路径直接放在 argv[1]、漏写了 `scan`，
/// 结果不报用法错、不退出，而是起一个 GUI 实例 —— 一占就是十分钟**全机唯一那格取证窗口**
/// （AGENTS 横切约束 2），界面上还看不出它是谁起的。危害不是不方便，是**误写一次就多占一格窗口**。
/// 现在这种误用打用法错、退 64（沿用 `CLIExit.usage`，不新增档位）。
@main
enum TcoderEntry {
    static func main() {
        let argv = CommandLine.arguments
        if CLIRouter.isHeadlessInvocation(argv: argv) {
            exit(CLIRouter.main(argv: argv))
        }
        if let problem = misuseProblem(argv: argv) {
            CLIOutput.fail(problem)
            // 用法串只有 CLIRouter 那一份：它逐条列着 scan / score / doctor 与各自的关键参数。
            // 这里**不复述中文**，否则两个入口会各自漂移（本仓 RD-38 那一族病）。
            CLIOutput.line(CLIRouter.usageText)
            exit(CLIExit.usage.rawValue)
        }
        TcoderMonitorApp.main()
    }

    /// 判据：这次调用**显然带了参数**，argv[1] 既不是已知子命令词、也不是 GUI 的启动参数
    /// ⇒ 是一次写错的 CLI 调用，返回给调用方看的那句话；不该拦时返回 nil。
    ///
    /// 三格不拦的理由（都是**产品路径**，不许顺手一起关掉）：
    /// 1. `argv.count <= 1` —— 零参数就是双击图标，产品启动路径。
    ///    **为什么没有真子进程用例钉它**：测它 = 起一次 GUI = 占掉全机唯一那格取证窗口，
    ///    违反 AGENTS 横切约束 2（同一时刻只允许一个人启动 App，此刻 `pgrep -x TcoderMonitor` 就不是 0）。
    ///    所以这一格只由 `misuseProblem` 的纯函数断言守着，不去真起进程。
    /// 2. argv[1] 命中 `CLIRouter.headlessWords` —— 那是**已知子命令词**，无头那一路在 `main` 里
    ///    已经分派完并 `exit()`。这张表里还有 `--help` / `-h` / `help` / `--version` 四个双横线词，
    ///    所以「先查词表、再判双横线」的次序不能颠倒（颠倒了会把 `--version` 判成用法错 ——
    ///    被 `CLIEntryArgsGuardTests.test_everyHeadlessWordIsNotMisuse` 当场抓到过一次）。
    /// 3. argv[1] 以**单个** `-` 开头 —— 那是 AppKit / LaunchServices 的参数形状：
    ///    取证链一律传 `-ApplePersistenceIgnoreState YES`、有时再跟 `-selectedDetailSection <页>`，
    ///    LaunchServices 起 App 传 `-psn_…`（见 `CLIRouter.headlessWords` 那段注释）。
    ///    这些**不是误用**，是把 GUI 拉起来的标准写法，`capture_pages_isolated.sh` /
    ///    `ax_truncation_sweep.sh` / `perf_switch.sh` 等脚本都靠它，一律照旧交给 AppKit。
    ///    `--` 开头不在这一格：本 App 的 GUI 启动参数从不写双横线，而 CLI 的长参数一律 `--`，
    ///    于是 `--out=…` 单独出现在 argv[1] 只可能是漏写了子命令词。
    static func misuseProblem(argv: [String]) -> String? {
        guard argv.count > 1 else { return nil }
        let word = argv[1]
        guard !CLIRouter.headlessWords.contains(word) else { return nil }
        if word.hasPrefix("--") {
            return "argv[1] 是参数不是子命令词：\(word)。子命令要写在最前面。"
        }
        guard !word.hasPrefix("-") else { return nil }
        return "argv[1] 不是子命令词：\(word)。子命令要写在最前面。"
    }
}
