import AppKit
import ApplicationServices

// 屏上**正文**（非 ⓘ）的活界面读数器（**报告器，不是闸门**，退出码不判产品成败）。
//
// 为什么要有第二把仪器：`scripts/ax_dump.swift` 只收 `kAXHelpAttribute`，
// 也就是"收进 ⓘ 的那一类长句"。而 F13 报的是**另一类**：
// Services 里拼好、经 `Text(变量)` 直接铺在页面上的整句（健康评分页「缺席维度」那句、
// 代码规模页「部分测量」那三行都是）。这类句子**没有 help 属性**，
// 于是双语尺子（按 UI 入口前缀识别）与 ⓘ 读数器（只读 help）**同时看不见它**。
// 改进清单里那句"python 粗筛 32 文件 / 327 处"就是因为没有仪器才只能粗筛。
//
// 与 `ax_dump` 的**互相复现**（两把尺子不先对上，数不许进台账）：
// 同一个 pid 同一时刻各跑一次，`SUMMARY` 里的 `windows=` / `visited=` / `withHelp=`
// 三项必须一字不差 —— 前两项证明走的是同一棵树，第三项证明我对 help 的读法没有偏。
//
// 用法： ax_body_text <pid>
//   先按 `ax_dump` 的**完全相同格式**输出每条 help（`HELP<TAB>值`），
//   再输出 `SUMMARY windows= visited= withText= withHelp=`，
//   最后才是本仪器独有的正文块：每行 `TEXT<TAB>role<TAB>属性<TAB>值`（值里的换行折成 " ⏎ "）。
//   属性只收这三个：`AXValue` / `AXTitle` / `AXDescription`（SwiftUI 的按钮标签在
//   `AXDescription` 上而不是 `AXTitle` —— 这条已由 `ax_press.swift` 实测过）。
//   **顺序是有意的**：`ax_tooltip_coverage.py:read_help_entries` 把"非 HELP 非 SUMMARY 的行"
//   当成上一条 help 的续行。所以 TEXT 块必须排在 SUMMARY **之后** —— 那样它会被旧读者整段跳过，
//   一把仪器喂两把尺子而不用跑两趟。反过来放就会污染 help 台账。
// 退出码：0 读到树（哪怕 withText=0，那是要人看的信号，不是仪器坏了）；
//         3 本进程没有无障碍权限；4 取不到目标窗口 —— 后两种是**仪器失效**，
//         必须和非零码一起写进日志，绝不让"读不到"被当成"界面上没有"。

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    print("usage: ax_body_text <pid>"); exit(2)
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
var rows: [(role: String, attr: String, text: String)] = []
var helpTexts: [String] = []
var depthTruncated = false

let textAttributes: [(String, String)] = [
    (kAXValueAttribute as String, "AXValue"),
    (kAXTitleAttribute as String, "AXTitle"),
    (kAXDescriptionAttribute as String, "AXDescription"),
]

func fold(_ s: String) -> String { s.replacingOccurrences(of: "\n", with: " ⏎ ") }

// 深度上限与 `ax_dump` 保持一致（60）：两边不同，visited 就没有可比性。
func walk(_ element: AXUIElement, _ depth: Int) {
    visited += 1
    if depth >= 60 { depthTruncated = true; return }
    let role = (attribute(element, kAXRoleAttribute) as? String) ?? "?"
    if let help = attribute(element, kAXHelpAttribute) as? String, !help.isEmpty {
        helpTexts.append(help)
    }
    for (name, label) in textAttributes {
        guard let raw = attribute(element, name) else { continue }
        // AXValue 可能是 String / Number / AXValue 包装，只收字符串载荷。
        guard let s = raw as? String, !s.isEmpty else { continue }
        rows.append((role: role, attr: label, text: fold(s)))
    }
    if let kids = attribute(element, kAXChildrenAttribute) as? [AXUIElement] {
        for kid in kids { walk(kid, depth + 1) }
    }
}

for window in windows { walk(window, 0) }

for text in helpTexts { print("HELP\t" + fold(text)) }
var summary = "SUMMARY windows=\(windows.count) visited=\(visited) withText=\(rows.count) withHelp=\(helpTexts.count)"
if depthTruncated { summary += " DEPTH_TRUNCATED=1" }
print(summary)
for row in rows {
    print("TEXT\t\(row.role)\t\(row.attr)\t\(row.text)")
}
