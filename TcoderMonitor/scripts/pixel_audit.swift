// 截图读数器：把每张界面截图的「大面积底色分布」和「最暗像素落点」打成一行报告。
//
// **它是报告器，不是闸门** —— 这个定性是标定失败换来的，别再改回去：
// 第一版想做机械判据，试过两条：
//   ① 「版心两两对比 > 1.10:1 即判存在卡面填充」→ 拿重构前的旧图跑**判通过**。
//      因为"脏"本身就是 1.05:1 的微差（#F8F8F8 底 / #E9EBED 卡 / #E3E5E7 tile），
//      任何"两点差异 > 阈值"的写法要么抓不到它，要么把正常设计一起误杀。
//   ② 「大面积明度众数 ≥3 即判地面不唯一」→ 旧图只剩 2 个众数（差得太近被并进同一档），
//      而对照用的参考图判 3 个失败 —— 那张图是**手持平板的照片**，含黑边框与手指。
// 结论：1.05:1 级别的分层丢失，靠像素采样不可靠判定，只能靠人眼 + 源码事实。
// 机械判定全部交给 `Tests/TcoderMonitorTests/BorderlessSurfaceGuardTests.swift`
// （它数的是源码里的 `.shadow(`、材质、零引用令牌 —— 那些是离散事实，可精确断言）。
//
// 用法: swift scripts/pixel_audit.swift <图1.png> [图2.png ...]
// 退出码恒为 0（报告器不判失败）。
import AppKit

func srgbLuma(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func f(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
}

print(String(format: "%-46@ %-30@ %@", "截图", "大面积明度众数(面积占比)", "最暗像素落点"))
for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else {
        print("\(path): 读不到图"); continue
    }
    let W = rep.pixelsWide, H = rep.pixelsHigh
    func px(_ x: Int, _ y: Int) -> (Double, Double, Double)? {
        guard x >= 0, y >= 0, x < W, y < H,
              let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return nil }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }
    let name = (path as NSString).lastPathComponent

    // 版心区域（避开左侧栏与窗口边）；排除彩色像素与纯墨文字，只统计「面」。
    let stepX = max(1, W / 500), stepY = max(1, H / 500)
    var buckets: [Int: Int] = [:]
    var total = 0
    for y in stride(from: Int(Double(H) * 0.16), to: Int(Double(H) * 0.96), by: stepY) {
        for x in stride(from: Int(Double(W) * 0.26), to: W - 2, by: stepX) {
            guard let p = px(x, y) else { continue }
            if max(p.0, max(p.1, p.2)) - min(p.0, min(p.1, p.2)) > 0.18 { continue }
            let l = Int(srgbLuma(p.0, p.1, p.2) * 255)
            if l < 120 || l > 252 { continue }
            buckets[l / 3, default: 0] += 1
            total += 1
        }
    }
    let modes = buckets.sorted { $0.value > $1.value }
        .prefix(4)
        .map { String(format: "%d@%.0f%%", $0.key * 3, total == 0 ? 0 : 100 * Double($0.value) / Double(total)) }
        .joined(separator: " ")

    var minLuma = 2.0, minXY = (0, 0)
    for y in stride(from: Int(Double(H) * 0.18), to: Int(Double(H) * 0.95), by: max(1, H / 600)) {
        for x in stride(from: Int(Double(W) * 0.28), to: W - 2, by: max(1, W / 600)) {
            guard let p = px(x, y) else { continue }
            let l = srgbLuma(p.0, p.1, p.2)
            if l < minLuma { minLuma = l; minXY = (x, y) }
        }
    }
    print(String(format: "%-46@ %-30@ y=%.2f 亮度 %.3f  (n=%d)",
                 String(name.prefix(44)) as NSString, modes as NSString,
                 Double(minXY.1) / Double(H), minLuma, total))
}
