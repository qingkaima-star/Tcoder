// perf_synth_scroll.swift —— 录制窗口内往会话投**合成滚动事件**，用来做"可复现版"的交互期采样。
//
// 为什么需要它：交互期那一维（T1）此前只能靠真人滚，
// 于是它既是唯一的判据、又是唯一没法重跑的判据 —— 机器每晚只能等到人愿意配合的那几十秒。
// 实测确认过 CGEvent 投递的滚动**会被同一条静默探针看见**（`secondsSinceLastEventType`），
// 所以"开录时机"与"窗口内确有输入"两关都不用为它开后门。
//
// 诚实性硬要求：用它录出来的样本必须标 `input_source=synthetic`，
// 报表要写"合成输入（CGEvent 投递，非手感）"，**不得冒充真人手感**。
// 它答的是"连续滚动下渲染路径有没有 hitch"，不答"人拿着鼠标时的主观顺不顺"。
//
// 用法：perf_synth_scroll <秒数> [每次像素=14] [间隔毫秒=40]
// 约定：不移动光标（用当前指针位置）、不点按、不按键、不给任何进程发信号。
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 2, let secs = Double(args[1]), secs > 0 else {
    FileHandle.standardError.write("用法: perf_synth_scroll <秒数> [像素] [毫秒]\n".data(using: .utf8)!)
    exit(2)
}
let dy = args.count > 2 ? (Double(args[2]) ?? 14) : 14
let gapMs = args.count > 3 ? (Double(args[3]) ?? 40) : 40

// 取不到事件源/光标位置就**直接失败退出**：静默退化成"什么都没投"会让样本被当成投过了。
guard let src = CGEventSource(stateID: .hidSystemState) else { exit(3) }
guard let cursor = CGEvent(source: nil)?.location else { exit(4) }

let deadline = Date().addingTimeInterval(secs)
let step: Int32 = Int32(dy)
var posted = 0
var tick = 0
while Date() < deadline {
    // 每 20 拍换一次方向：一路往下会在列表底部停住，那就等于"投了但没滚动"。
    let dir: Int32 = (tick / 20) % 2 == 0 ? -step : step
    tick += 1
    if let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                        wheel1: dir, wheel2: 0, wheel3: 0) {
        ev.location = cursor
        ev.post(tap: .cghidEventTap)
        posted += 1
    }
    usleep(UInt32(max(1.0, gapMs) * 1_000.0))
}
// 投了多少次要**说出来**：投递失败（权限/无光标）时这里会报 0，而不是让调用方以为在滚。
FileHandle.standardError.write("合成滚动：投递 \(posted) 拍 / \(secs)s\n".data(using: .utf8)!)
exit(posted > 0 ? 0 : 5)
