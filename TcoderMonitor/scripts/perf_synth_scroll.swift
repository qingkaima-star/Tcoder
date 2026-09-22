// perf_synth_scroll.swift —— 往**被测 App 的窗口**投合成滚动事件，做可复现的交互期采样。
//
// 为什么需要它：交互期那一维（T1）此前只能靠真人滚，
// 于是它既是唯一还欠着的判据、又是唯一没法重跑的判据。
//
// 为什么必须**瞄准被测窗口**（第一版没做，是个真 bug）：
// hid tap 投递是"按指针所在处生效"的。录制档要求被测 App 在前台，
// 但**前台 ≠ 指针在它上面** —— 指针停在终端/IDE 上时，投出去的滚动会去滚别人的窗口：
// 静默探针照样看到"有滚动事件"（开录闸门会放行），而被测 App 一帧都没重绘
// ⇒ 那就是一份"看起来有人交互"的空转样本，比没有样本更坏。
// 现在：按 pid 找到被测窗口 → 指针挪到窗口中心 → 事件坐标也带上中心 → 收尾把指针放回原处。
//
// 诚实性硬要求：用它录的样本必须标 `input_source=synth`，
// 报表写"合成输入（CGEvent 投递，非真人手感）"，**不得冒充真人**。
// 它答"连续滚动下渲染路径有没有 hitch"，不答"人拿鼠标时顺不顺"。
//
// 用法：perf_synth_scroll <秒数> <被测pid> [每次像素=14] [间隔毫秒=40]
// 退出码：0 = 真投过事件；非 0 = 环境不允许（取不到窗口/事件源/零投递）⇒ 调用方必须当失败。
import CoreGraphics
import Foundation

let args = CommandLine.arguments
guard args.count >= 3, let secs = Double(args[1]), secs > 0, let pid = Int(args[2]) else {
    FileHandle.standardError.write("用法: perf_synth_scroll <秒数> <pid> [像素] [毫秒]\n".data(using: .utf8)!)
    exit(2)
}
let dy = args.count > 3 ? (Double(args[3]) ?? 14) : 14
// 投递节奏默认 **8 ms ≈ 125 Hz**，与被测档的标称刷新率同量级。
// 第一版用 40 ms（25 Hz）：那会让"实测出帧只有 41~53/s"这件事**没法归因**——
// 到底是 App 画不动，还是我的输入器每秒只推 25 下、画面本来就没必要重画？
// ⇒ 输入器的频率必须 ≥ 想证明的帧率，否则这个变量就是我自己造的假象。
let gapMs = args.count > 4 ? (Double(args[4]) ?? 8) : 8

/// 在屏窗口里属于该 pid、层号为 0（普通窗口）、面积最大的那个的中心点。
func targetWindowCenter(for owner: Int) -> CGPoint? {
    guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                kCGNullWindowID) as? [[String: Any]] else { return nil }
    var best: CGRect?
    for info in list {
        guard let wpid = info[kCGWindowOwnerPID as String] as? Int, wpid == owner,
              let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
              let b = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }
        let rect = CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0,
                          width: b["Width"] ?? 0, height: b["Height"] ?? 0)
        if rect.width < 100 || rect.height < 100 { continue }
        if let cur = best { if rect.width * rect.height > cur.width * cur.height { best = rect } }
        else { best = rect }
    }
    guard let r = best else { return nil }
    return CGPoint(x: r.midX, y: r.midY)
}

guard let src = CGEventSource(stateID: .hidSystemState) else { exit(3) }
guard let center = targetWindowCenter(for: pid) else {
    FileHandle.standardError.write("取不到 pid=\(pid) 的在屏窗口 ⇒ 一个事件都不投（宁可失败也不空转）\n".data(using: .utf8)!)
    exit(6)
}
let original = CGEvent(source: nil)?.location      // 拿不到也照投，但收尾要说明没放回
CGWarpMouseCursorPosition(center)

let deadline = Date().addingTimeInterval(secs)
let step = Int32(dy)
var posted = 0
var tick = 0
while Date() < deadline {
    // 每 20 拍换向：一路往下会在列表底部停住，那就等于"投了但没滚动"
    let dir: Int32 = (tick / 20) % 2 == 0 ? -step : step
    tick += 1
    // 目标进程不在了就立刻收手。投事件器原先只认"到点为止"：今晚实测过一次——
    // 被测实例 15 s 时被 TERM，而投事件器按默认 95 s 继续往屏幕上投，
    // 那 80 秒里光标底下是谁都可能被我的合成滚动打到。liveness 检查每 20 拍一次就够。
    if tick % 20 == 0, kill(pid_t(pid), 0) != 0 { break }   // pid 是 Int，kill 要 pid_t
    if let ev = CGEvent(scrollWheelEvent2Source: src, units: .pixel, wheelCount: 1,
                        wheel1: dir, wheel2: 0, wheel3: 0) {
        ev.location = center
        ev.post(tap: .cghidEventTap)
        posted += 1
    }
    usleep(UInt32(max(1.0, gapMs) * 1_000.0))
}

if let original {
    CGWarpMouseCursorPosition(original)
    note("朝 pid=\(pid) 的窗口中心投 \(posted) 拍 / \(secs)s；指针已放回原位")
} else {
    note("朝 pid=\(pid) 投了 \(posted) 拍，但取不到指针原位置 ⇒ **没放回**，请自己动一下鼠标")
}
func note(_ s: String) {
    FileHandle.standardError.write(("合成滚动：" + s + "\n").data(using: .utf8)!)
}
exit(posted > 0 ? 0 : 5)
