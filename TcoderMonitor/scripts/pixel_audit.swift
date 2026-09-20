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
// 输出第二列是前 4 名明度桶，末尾的「地面=…」是占比最高的那一桶（它才是地面）。
// 退出码恒为 0（报告器不判失败）。
import AppKit

func srgbLuma(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func f(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
}

print(String(format: "%-46@ %-30@ %@  %@",
             "截图", "大面积明度众数(面积占比)", "最暗像素落点", "灰阶分带 白/灰带235-249/暗灰带215-234"))
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

    // 版心区域（避开左侧栏与窗口边）；先只排除彩色像素，统计**全部**明度桶。
    //
    // **为什么没有明度窗**：旧版写死 `if l < 120 || l > 252 { continue }`，本意是排除纯墨文字。
    // 实测它把两个主题的**地面**都排掉了——
    //   亮主题地面是 `#FFFFFF`（sRGB 亮度 255，被 `> 252` 上限排掉）；
    //   暗主题地面是 `#1C1C1E`（亮度 ≈ 30，被 `< 120` 下限排掉）。
    // 于是「大面积明度众数」报的**从来不是地面**，而是把地面扔掉之后剩下的东西，
    // 且暗主题那批几乎全在窗外、`total` 只剩几百个采样点 —— 读数看着专业，内容是错的。
    // （这跟《无界 spec》§6.2 记的那两次标定失败是同一类病：判据写死，就只会对某一个主题成立。）
    // 正确做法：先无窗统计，**占比最高的那个桶就是地面**，再把前几名如实报出来；
    // 文字像素占比小，进不了前几名，不必为它造一个会误伤地面的窗。
    let stepX = max(1, W / 500), stepY = max(1, H / 500)
    var buckets: [Int: Int] = [:]
    var total = 0
    // 灰阶分带：**这是"显脏"唯一可证伪的读数**。
    // 用户判词「不要用灰色底，显脏」如果只能靠眼睛，下一轮一定再犯——所以这里把
    // "白" 与 "灰" 拆成三个带计数：纯白（三通道都 ≥250）、灰带（235–249，旧地面
    // `#F1F1F3` 正落在这里）、暗灰带（215–234，旧井 `#EAEAEC` 落在这里）。
    // 参考图实测是「白面板 + 灰桌」两级，上一版把内容层的面全去掉后只剩灰带一级：
    // 实拍灰带 81.3% / 纯白 5.1%。地面回白之后这两个数应当反过来。
    var pureWhite = 0, grayBand = 0, darkGrayBand = 0
    for y in stride(from: Int(Double(H) * 0.16), to: Int(Double(H) * 0.96), by: stepY) {
        for x in stride(from: Int(Double(W) * 0.26), to: W - 2, by: stepX) {
            guard let p = px(x, y) else { continue }
            if max(p.0, max(p.1, p.2)) - min(p.0, min(p.1, p.2)) > 0.18 { continue }
            let mn = Int(min(p.0, min(p.1, p.2)) * 255)
            if mn >= 250 { pureWhite += 1 }
            else if mn >= 235 { grayBand += 1 }
            else if mn >= 215 { darkGrayBand += 1 }
            let l = Int(srgbLuma(p.0, p.1, p.2) * 255)
            buckets[l / 3, default: 0] += 1
            total += 1
        }
    }
    let pct: (Int) -> String = { total == 0 ? "—" : String(format: "%.1f%%", 100 * Double($0) / Double(total)) }
    let bands = "白\(pct(pureWhite))/灰带\(pct(grayBand))/暗灰带\(pct(darkGrayBand))"
    let sorted = buckets.sorted { $0.value > $1.value }
    let groundBucket = sorted.first
    let groundText = groundBucket.map {
        String(format: "地面=%d@%.0f%%（RGB 亮度）", $0.key * 3, total == 0 ? 0 : 100 * Double($0.value) / Double(total))
    } ?? "地面=未统计到"
    let modes = sorted.prefix(4)
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
    print(String(format: "%-46@ %@  y=%.2f 最暗亮度 %.3f  (n=%d)  %@  %@",
                 String(name.prefix(44)) as NSString, modes as NSString,
                 Double(minXY.1) / Double(H), minLuma, total, bands as NSString, groundText as NSString))
}
