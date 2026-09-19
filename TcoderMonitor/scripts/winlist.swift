// 列出某进程当前在屏窗口的 id，供 scripts/verify_pages.sh 与 e2e_check.sh
// 用 `screencapture -l<id>` 只抓本 App 的窗口。
//
// 不用全屏截图：那会把用户桌面上其他窗口一起拍进取证图里。
// 也不用 System Events 点击：它会触发辅助功能授权等待，且 SwiftUI Picker
// 不暴露 AXPopUpButton，点不动。
import CoreGraphics
import Foundation

let target = Int32(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0") ?? 0
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
    print("no window info")
    exit(0)
}

// 只报有标题且够宽的窗口：SwiftUI 会挂若干 0 宽的辅助窗口，抓它们是废图。
for entry in info {
    guard let ownerValue = entry[kCGWindowOwnerPID as String] as? Int else { continue }
    guard Int32(ownerValue) == target else { continue }
    let number = (entry[kCGWindowNumber as String] as? Int) ?? 0
    let name = (entry[kCGWindowName as String] as? String) ?? ""
    let width = ((entry[kCGWindowBounds as String] as? [String: Any])?["Width"] as? Double) ?? 0
    if name.isEmpty || width < 200 { continue }
    print("\(number)|\(name)|\(Int(width))")
}
