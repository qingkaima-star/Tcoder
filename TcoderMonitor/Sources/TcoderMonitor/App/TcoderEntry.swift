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
@main
enum TcoderEntry {
    static func main() {
        let argv = CommandLine.arguments
        if CLIRouter.isHeadlessInvocation(argv: argv) {
            exit(CLIRouter.main(argv: argv))
        }
        TcoderMonitorApp.main()
    }
}
