import AppKit
import ApplicationServices

// 无障碍驱动器（**取证夹具，不是产品代码，也不是闸门**）。
//
// 为什么需要它：九页里有几个 ⓘ 只出现在"要点一下才会到的状态"
// （采样已暂停、展开了的折叠区）。这一类状态：
//   - 合成鼠标到不了（`CGWarpMouseCursorPosition` + 合成 `mouseMoved` 唤不出 tooltip，
//     正对照也一样，见 `docs/界面-乱的清单.md` §6 第 2 条）；
//   - 但 AX 的 press 动作到得了 —— 那正是读屏软件驱动 App 的方式，
//     也是"这个按钮真的能按"的正面证据。
//
// 三条硬规矩，都写在代码里：
//   1. **只按标题唯一命中的那一个**。命中 0 个或 >1 个都拒绝并 exit 非 0，
//      绝不"挑第一个看起来像的"——按下不该按的东西，比量不到更坏。
//   2. 只对自己起的、二进制路径核对过的实例用（调用方负责传对 pid；
//      本工具不发任何信号给被监控的进程，只向目标 App 的界面元素发一个 press 动作）。
//   3. 按完必须**回读**一次状态（打印按钮标题与它现在的 AXValue/被按事实），
//      不许"发了动作就当状态已经变了"。
//
// 用法： ax_press <pid> <按钮标题子串>
//   exit 0 = 唯一命中并且 press 返回 success；非 0 = 没按（原因打在 stdout）

guard CommandLine.arguments.count > 2, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: ax_press <pid> <按钮标题子串>"); exit(2)
}
let needle = CommandLine.arguments[2]
guard AXIsProcessTrusted() else {
    print("AX_UNTRUSTED 本进程没有无障碍权限 —— 驱动不了，别当成'按钮坏了'"); exit(3)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

var matches: [AXUIElement] = []
var visited = 0
/// `--list` 模式的账本：每个有标题的元素一行（含它接不接受 press）。
/// 为什么要有这一档：第一次按「暂停」押空了 —— 界面根本没有叫这两个字的元素
/// （按钮上是一枚图标）。**押不中就去列一遍有哪些可按的**，而不是改猜第二个词。
var inventory: [String] = []

func walk(_ element: AXUIElement, _ depth: Int) {
    visited += 1
    if depth >= 60 { return }
    let title = (attribute(element, kAXTitleAttribute) as? String) ?? ""
    // SwiftUI 的按钮**不放标题**：第一次按「暂停」押空、全树 229 个元素里只有 1 个有
    // `AXTitle` —— 标签在 `AXDescription` 上（读屏念的就是那一格）。所以三格都读、三格都配。
    let desc = (attribute(element, kAXDescriptionAttribute) as? String) ?? ""
    let value = (attribute(element, kAXValueAttribute) as? String) ?? ""
    let canPress = listActions(element).contains(kAXPressAction as String)
    if !title.isEmpty || !desc.isEmpty {
        inventory.append("press=\(canPress) title=\(title.prefix(24)) desc=\(desc.prefix(24)) value=\(value.prefix(14))")
    }
    if title.contains(needle) || desc.contains(needle) || value.contains(needle) { matches.append(element) }
    if let kids = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        for kid in kids { walk(kid, depth + 1) }
    }
}

func listActions(_ element: AXUIElement) -> [String] {
    var names: CFArray?
    guard AXUIElementCopyActionNames(element, &names) == .success,
          let array = names as? [String] else { return [] }
    return array
}

let app = AXUIElementCreateApplication(pid)
guard let windows = attribute(app, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty else {
    print("AX_UNREADABLE 取不到目标窗口（pid \(pid) 还活着吗？）—— 没有按任何东西")
    exit(4)
}
for window in windows { walk(window, 0) }

print("翻了 \(visited) 个元素，「\(needle)」命中 \(matches.count) 个")
if needle == "--list" {
    for line in inventory.sorted() { print(line) }
    print("可按的元素 \(inventory.filter { $0.hasPrefix("press=true") }.count) 个 / 有标题的元素 \(inventory.count) 个")
    exit(0)
}
guard matches.count == 1 else {
    print(matches.isEmpty
        ? "❌ 一个都没命中 —— 拒绝按（这个状态这个界面上没有对应入口，换夹具，别硬找）"
        : "❌ 命中 \(matches.count) 个，不知道按哪个 —— 拒绝按")
    exit(1)
}

let target = matches[0]
let before = (attribute(target, kAXValueAttribute) as? String) ?? "(无 value)"
let err = AXUIElementPerformAction(target, kAXPressAction as CFString)
let after = (attribute(target, kAXValueAttribute) as? String) ?? "(无 value)"
print("press 返回 \(err.rawValue)；value 按前=\(before) 按后=\(after)")
guard err == .success else {
    print("❌ 这个元素不接受 press 动作（可能压根不是按钮）—— 状态没变，别把这次当夹具用")
    exit(1)
}
print("✅ 已按：title=\((attribute(target, kAXTitleAttribute) as? String) ?? "") + desc=\((attribute(target, kAXDescriptionAttribute) as? String) ?? "")")
exit(0)
