import AppKit
import ApplicationServices

// 屏上文本的**几何**读数器（报告器）：每个文本元素一行
//   FRAME<TAB>实宽<TAB>实高<TAB>需要宽<TAB>需要几行<TAB>放得下几行<TAB>是否被裁<TAB>值
//
// **为什么必须带高度这一列**：只比"一行装不装得下"会把**换行的段落**全报成溢出——
// 第一次跑 11 处里 8 处是这种假阳（「缺失 3 个维度不参与计分…」实宽 900pt、需要 1076pt，
// 但它折成两行画得好好的）。判"被裁"要问的是：**这串字要 N 行，这个格子给得起 N 行吗**。
// 行高按字号 × 1.4 估（本 App 正文 11pt + 行距 2 ≈ 17pt），是猜的，所以这条尺子
// 报的是"差多少"，最终定性仍要人看一眼截图。
//
// 为什么不用 `ax_body_text` 那把：它只给值，而值**看不出截断**——
// 已用已知答案的夹具证死（`scripts/ax_truncation_sweep.sh` 的正对照）：
// 侧栏那条 51 字的长项目名在像素上画成 `Tcoder（截断正…出来的夹具项目名`，
// 而树里的 `AXValue` 是**完整的 51 字**。⇒ 无障碍的值通道对视觉截断是盲的。
// 于是改问一个能被回答的问题：**这串字画进这个格子里，装得下吗？**
//   需要的宽度用 CoreText 按本 App 的正文字号量；实宽度取元素的 AXSize。
//
// 已知局限（读数时必须注明，否则会被当成判据）：
//   * 字号只能**猜**（AX 不给字体）——默认 11pt（`Theme.Typo.label`），可用第二个参数改；
//     所以这条尺子量的是"差多少"，不是"一定被裁了"：多行文本、更小的字号都会虚报。
//   * 因此**正对照必须自带**：夹具那条长名字一定要被报出来，报不出来就是尺子坏了。
//
// 用法: ax_frames <pid> [正文字号pt]

guard CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) else {
    FileHandle.standardError.write("用法: ax_frames <pid> [字号pt]\n".data(using: .utf8)!)
    exit(2)
}
let fontSize = CommandLine.arguments.count > 2 ? (Double(CommandLine.arguments[2]) ?? 11) : 11
let font = NSFont.systemFont(ofSize: CGFloat(fontSize))

func attr(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
    var value: CFTypeRef?
    return AXUIElementCopyAttributeValue(element, key as CFString, &value) == .success ? value : nil
}

func textWidth(_ s: String) -> Double {
    Double((s as NSString).size(withAttributes: [.font: font]).width)
}

var rows: [String] = []
var visited = 0

func walk(_ element: AXUIElement, depth: Int) {
    if depth > 60 { return }
    visited += 1
    let role = (attr(element, kAXRoleAttribute) as? String) ?? ""
    // **只量屏上真身**：`AXStaticText` 的可见文本在 `AXValue` 上。
    // 第一版把 `AXDescription` 也当候选，于是错误日志页那条 banner 被量成 716pt——
    // 可它屏上只有「没找到可解析的日志文件」，长的那半在 ⓘ 里（`AXDescription` 装的就是它）。
    // 拿 tooltip 的字数去比可见格子的宽度，报出来的"溢出"是判据自己造的。
    var value = (attr(element, kAXValueAttribute) as? String) ?? ""
    // **SwiftUI 会把可见文本与 ⓘ 的 help 拼成同一个 `AXValue`**（中间用「、」连）——
    // 错误日志页那条 banner 就被量成 716pt：屏上只有「没找到可解析的日志文件」，
    // 后半截是 ⓘ 里的「项目目录与 ~/Library/Logs 里都没有找到…」。
    // 判据：元素带 `AXHelp`，且它的值里含这段 help ⇒ 把 help 剥掉再量剩下的。
    if let help = attr(element, kAXHelpAttribute) as? String, !help.isEmpty,
       let cut = value.range(of: help) {
        let stripped = (String(value[..<cut.lowerBound]) + String(value[cut.upperBound...]))
            .trimmingCharacters(in: CharacterSet(charactersIn: "、, ，"))
        // **剥空了就不剥**：侧栏那一格的 help 常常就是名字本身（悬停要看全名），
        // 这时 help 不是"藏起来的另一半"而是"同一句话的副本"。
        // 上一版没查这一条，直接把正对照的那格剥成空串 ⇒ 夹具不报 ⇒ 整把尺子自判不成立。
        if !stripped.isEmpty { value = stripped }
    }
    if ["AXStaticText", "AXTextField"].contains(role), value.count >= 4,
       !value.contains("\n") {
        var sizeValue = CGSize.zero
        if let raw = attr(element, kAXSizeAttribute) {
            AXValueGetValue(raw as! AXValue, .cgSize, &sizeValue)
        }
        let needed = textWidth(value)
        if sizeValue.width > 4, sizeValue.height > 4 {
            // 行高取**实测**而不是字号 × 1.4：这一页上"风险：高"这类单行元素的高是 13pt，
            // 而 11 × 1.4 = 15.4 会把 26pt 的两行盒算成"只给得起 1 行"——
            // 第一次跑 11 处里有 3 处就是这么误报的。用 rounded() 而不是截断同理。
            let lineHeight = fontSize * 1.2
            let linesAvailable = max(1, Int((sizeValue.height / lineHeight).rounded()))
            let linesNeeded = max(1, Int((needed / Double(sizeValue.width)).rounded(.up)))
            // 最后一列是**超出多少 pt**（不是布尔）：判定留给分析器，
            // 因为"差 3pt"在小徽标上几乎总是字号猜错造成的误报。
            let slack = needed - Double(sizeValue.width) * Double(linesAvailable)
            rows.append("FRAME\t\(Int(sizeValue.width))\t\(Int(sizeValue.height))"
                + "\t\(Int(needed))\t\(linesNeeded)\t\(linesAvailable)"
                + "\t\(Int(slack))"
                + "\t" + value.replacingOccurrences(of: "\n", with: " ⏎ "))
        }
    }
    if let kids = attr(element, kAXChildrenAttribute) as? [AXUIElement] {
        for kid in kids { walk(kid, depth: depth + 1) }
    }
}

let app = AXUIElementCreateApplication(pid)
var windows: CFTypeRef?
AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
guard let list = windows as? [AXUIElement], !list.isEmpty else {
    print("SUMMARY windows=0 visited=0 rows=0")
    FileHandle.standardError.write("!! 取不到窗口：这台机器没给无障碍权限，或 App 还没起完\n".data(using: .utf8)!)
    exit(4)
}
for window in list { walk(window, depth: 0) }
let tooWide = rows.filter { row -> Bool in
    let parts = row.split(separator: "\t", omittingEmptySubsequences: false)
    guard parts.count > 6, let slack = Int(parts[6]) else { return false }
    let width = Int(parts[1]) ?? 0
    return slack > max(6, Int(Double(width) * 0.08))
}.count
print("SUMMARY windows=\(list.count) visited=\(visited) rows=\(rows.count) tooWide=\(tooWide)")
for row in rows { print(row) }
