// 人输入静默探针（**只读、零权限**）：打印距离上一次真实人手事件过了多少秒。
//
// 为什么需要它：`preflight_context` 原来只管"前台是谁 / 有没有在屏窗口 / load1 / 有没有并发编译",
// 这四条挡得住整机噪声，却挡不住**人手**——而 §1.3 那两批作废的基线，坏因恰恰是"测量期间有人在动"
// （run1 期间总工在点窗口、run2b 期间窗口被切到后台）。帧节拍读数一旦掺进人的操作，
// 它回答的就不再是"这套代码卡不卡"，而是"那 20 秒里谁干了什么"。
//
// 用 `CGEventSource.secondsSinceLastEventType(.combinedSessionState, …)`：
// 实测本机**不需要辅助功能权限**就能读（对比之下 `osascript` 查前台 App 会被 -10004 拒），
// 而且它只回答"距离上次事件多久"，不注册事件 tap、不拦截、不注入任何东西——纯只读。
//
// 用法：`input_quiescence` 无参数，输出一行：
//   mouseMoved=12.34 leftDown=12.00 scrollWheel=13.10 keyDown=99.20 静默=12.00s
// 取这四个里的**最小值**当"静默秒数"：任一维度刚动过，就说明有人在操作。
import CoreGraphics
import Foundation

func secondsSince(_ type: CGEventType) -> Double {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: type)
}

let parts: [(String, Double)] = [
    ("mouseMoved", secondsSince(.mouseMoved)),
    ("leftDown", secondsSince(.leftMouseDown)),
    ("scrollWheel", secondsSince(.scrollWheel)),
    ("keyDown", secondsSince(.keyDown)),
]
let quietest = parts.map(\.1).min() ?? -1
let detail = parts.map { String(format: "%@=%.2f", $0.0, $0.1) }.joined(separator: " ")
print("\(detail) 静默=\(String(format: "%.2f", quietest))s")
