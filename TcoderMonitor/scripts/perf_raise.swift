// perf_raise.swift —— 把**被测的那一个 App 实例**带到前台，然后退出。
//
// 为什么要有它：受控读数要求"前台是被测 App"，而这台机器上现在有多条车道在开自己的 GUI，
// 前台会被随时抢走。以前只能"等一个没人在用的空档"，实测一等就是二十几分钟。
//
// 硬约束：
//   ① 只对自己起的那个 pid 生效（参数就是它），绝不遍历、绝不按 bundle-id 广播；
//   ② **一次尝试只 raise 一次**（调用方负责节流）——两条车道互相 raise 就是焦点拉锯战，
//      那会让两边的读数同时变成垃圾；抢不到就如实等，不硬抢。
//   ③ 不发送任何信号、不改系统设置；失败就非零退出，由调用方决定继续等。
import AppKit
import Foundation

let a = CommandLine.arguments
guard a.count >= 2, let pid = Int32(a[1]), pid > 0 else {
    FileHandle.standardError.write("用法: perf_raise <pid>\n".data(using: .utf8)!)
    exit(2)
}
guard let app = NSRunningApplication(processIdentifier: pid) else {
    FileHandle.standardError.write("没有 pid=\(pid) 这个运行中的应用\n".data(using: .utf8)!)
    exit(3)
}
if app.isActive { exit(0) }
// macOS 14 起 `activate(options:)` 的 ignoringOtherApps 已无效（编译器直接告诉你"will have no effect"）
let ok = app.activate()
FileHandle.standardError.write("activate(pid=\(pid)) -> \(ok)\n".data(using: .utf8)!)
exit(ok ? 0 : 4)
