import AppKit
import ApplicationServices

// ⓘ「长口径」活界面读数器（**报告器，不是闸门**，退出码不判产品成败）。
//
// 它回答一个静态守卫答不了的问题：**句子有没有挂在活界面上**。
// 批次 P6 把几十条长口径从屏上搬进 ⓘ，之后「hover 出去那一格到底有没有字」只剩
// 源码扫描在管（`TooltipMigrationGuardTests` 数槽位）。守卫全绿不等于功能存在：
// `.help()` 收的是成品 String，SwiftUI 哪天不吃它，源码一行都不报错。
//
// 三条已经踩死的弯路（都不要再来一遍）：
//   1. 合成鼠标：`CGWarpMouseCursorPosition` + 合成 `mouseMoved` 等 5 秒唤不出 tooltip，
//      **正对照**（系统自己的窗口关闭按钮提示）也唤不出 ⇒ 尺子不灵（`docs/界面-乱的清单.md` §6）。
//   2. 进程内 `NSView.toolTip`：整棵 SwiftUI 树只翻出 1 个 NSView（宿主自己），
//      `CopyHelpBadge` / `Text(…).help(…)` / `Button(…).help(…)` 都没有落成子视图。
//   3. 进程内读 `accessibilityChildren`：五种装配姿势 `kids` 全是 0；
//      曾经出现过一次"读到了"的输出，逐字复刻后复现不出来 ——
//      那是**别的宿主留在进程里的 AX 元素**串进来的假信号，别信。
//
// 这一版走**进程外**：从另一个受信任的进程读目标 App 的无障碍树。
// `kAXHelpAttribute` 正是 `.help()` 落地的地方，也是 VoiceOver 念的「帮助」那一格。
//
// 用法： ax_dump <pid>
//   每条帮助文案一行 `HELP<TAB>文案`，末行 `SUMMARY windows= visited= withHelp=`。
// 退出码：0 读到树（哪怕 withHelp=0，那是要人看的产品信号）；
//         3 本进程没有无障碍权限 / 4 取不到目标窗口 —— 这两种是**仪器失效**，
//         必须和非零码一起写进日志，绝不让"读不到"被当成"界面上没有"。

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: ax_dump <pid>"); exit(2)
}
guard AXIsProcessTrusted() else {
    print("AX_UNTRUSTED 本进程没有无障碍读权限，读不了别人的界面树（这不是产品缺陷）"); exit(3)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

let app = AXUIElementCreateApplication(pid)
var windowsValue: CFTypeRef?
let windowError = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsValue)
guard windowError == .success, let windows = windowsValue as? [AXUIElement] else {
    print("AX_UNREADABLE err=\(windowError.rawValue) —— 取不到窗口，读数作废（不算通过）")
    exit(4)
}

var visited = 0
var helpTexts: [String] = []
var depthTruncated = false

// 深度上限 60：SwiftUI 的 AX 树是懒加载的，不设上限时一次误挂到整页就能把读数拖没影。
func walk(_ element: AXUIElement, _ depth: Int) {
    visited += 1
    if depth >= 60 { depthTruncated = true; return }
    if let help = attribute(element, kAXHelpAttribute) as? String, !help.isEmpty {
        helpTexts.append(help)
    }
    if let kids = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        for kid in kids { walk(kid, depth + 1) }
    }
}

for window in windows { walk(window, 0) }

// ⚠ 输出格式：一条 help **占一行**，值里的换行折成 " ⏎ "。
// 早先按原样打印，多行 tooltip（`.help(limits.joined("\\n"))` 这类）会拆成好几行，
// 而下游按 `^HELP` 逐行读 —— 于是**只有第一行被算进覆盖率**，
// "扫描边界"那整本台账一度被读成不存在。行式解析吃多行载荷，又是一次 awk 列位那族。
for text in helpTexts { print("HELP\t" + text.replacingOccurrences(of: "\n", with: " ⏎ ")) }
var summary = "SUMMARY windows=\(windows.count) visited=\(visited) withHelp=\(helpTexts.count)"
if depthTruncated { summary += " DEPTH_TRUNCATED=1" }
print(summary)
