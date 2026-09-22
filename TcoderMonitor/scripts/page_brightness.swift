import AppKit
import Foundation

// 逐张亮度判据：一张界面截图到底是浅色态还是深色态，用**每张图自己的像素**说话。
//
// 为什么单独有一把尺子、不复用 `pixel_audit.swift`：pixel_audit 是**报告器**
// （退出码恒 0，标定两次失败后已定性，见其文件头），它回答"这张图的地面是什么"，
// 不回答"这趟取证到底拍成了没"。而配对取证最常见的两种事故恰好是后者：
//   ① 拍图锁不保护**全机外观** —— 另一条流（或人）把系统外观一翻，
//      "深色那趟"就整批拍成浅色，图数量一张不少、看起来完全正常；
//   ② 空图 / 0 字节图 —— 窗口 id 取错时 `screencapture` 照样落盘。
// 两种都会让"深浅两态九页全部实拍复核通过"这句话变成假绿，所以这里
// **读不到图、没有像素、亮度落在两可区间，一律判败**。
//
// 用法：
//   page_brightness measure <png...>              只出数，不判（用于标定阈值）
//   page_brightness check light|dark <png...>     出数 + 判极性，任何一张不合格 exit 1
//   page_brightness selfcheck                     正对照：内存里造一张近白 + 一张近黑，
//                                                 必须各自过自己那侧、且**过不了对面那侧**
//
// 采样：整张 2560×1898 ≈ 485 万像素逐点取色太慢，按步长采到 ~30 万点。
// 判"亮/暗占比"用的是**全局像素**，不是某个区域 —— 一处的颜色（比如状态条）
// 不该决定整张图的极性，能决定的只有整版底色。

func srgbLuma(_ r: Double, _ g: Double, _ b: Double) -> Double {
    func f(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
    return 0.2126 * f(r) + 0.7152 * f(g) + 0.0722 * f(b)
}

struct Reading {
    var name: String
    var mean: Double
    var darkShare: Double
    var lightShare: Double
    var samples: Int
}

/// 阈值标定（2026-09-22，`measure` 跑 `f33f06c` 那 36 张交付图的实测区间）：
/// 浅色 18 张里均亮最低 **0.9207**、暗像素占比最高 **0.014**；
/// 深色 18 张里均亮最高 **0.0355**、亮像素占比最高 **0.008**。
/// 两侧相隔 0.88，所以 0.60 / 0.45 离实测带沿都还有**一整档以上**的余量 ——
/// 不是为了框住现量凑出来的数（那在本仓叫"为了刷分动阈值"）。
/// `oppositeShareCeiling = 0.20` 管的是另一件事：均值能被少量高亮区拉偏，
/// 对面那一侧的像素占比不会，两个量一起看才不被"半深半浅"糊过去。
let lightMeanFloor = 0.60
let darkMeanCeiling = 0.45
let oppositeShareCeiling = 0.20

func read(_ path: String) -> Reading? {
    guard let img = NSImage(contentsOfFile: path), let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    let W = rep.pixelsWide, H = rep.pixelsHigh
    guard W > 0, H > 0 else { return nil }
    let stepX = max(1, W / 640), stepY = max(1, H / 470)
    var sum = 0.0, dark = 0, light = 0, samples = 0
    var y = 0
    while y < H {
        var x = 0
        while x < W {
            // 走 bitmapData 之外的公共取色口：整张图只采 30 万点，慢一点换的是
            // 不用自己假设每行字节数与通道序（那是另一类"空值伪装成 0"的坑）。
            if let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
                let luma = srgbLuma(Double(c.redComponent), Double(c.greenComponent),
                                    Double(c.blueComponent))
                sum += luma
                if luma < 0.25 { dark += 1 }
                if luma > 0.85 { light += 1 }
                samples += 1
            }
            x += stepX
        }
        y += stepY
    }
    guard samples > 0 else { return nil }
    return Reading(name: (path as NSString).lastPathComponent,
                   mean: sum / Double(samples),
                   darkShare: Double(dark) / Double(samples),
                   lightShare: Double(light) / Double(samples),
                   samples: samples)
}

func report(_ r: Reading?) {
    guard let r else { print("(读不到图 / 无有效像素)"); return }
    print(String(format: "%-34@ mean=%.4f  darkShare=%.3f  lightShare=%.3f  (%d 点)",
                 r.name as NSString, r.mean, r.darkShare, r.lightShare, r.samples))
}

/// 极性判据。返回 nil 表示合格。空值一律判败 —— 一个数不出东西的扫描器比没有更危险。
func verdict(_ r: Reading?, polarity: String) -> String? {
    guard let r else { return "读不到图 / 无有效像素" }
    switch polarity {
    case "light":
        if r.mean < lightMeanFloor { return "均亮 \(String(format: "%.4f", r.mean)) < \(lightMeanFloor)" }
        if r.darkShare > oppositeShareCeiling { return "暗像素占比 \(String(format: "%.3f", r.darkShare)) > \(oppositeShareCeiling)" }
    case "dark":
        if r.mean > darkMeanCeiling { return "均亮 \(String(format: "%.4f", r.mean)) > \(darkMeanCeiling)" }
        if r.lightShare > oppositeShareCeiling { return "亮像素占比 \(String(format: "%.3f", r.lightShare)) > \(oppositeShareCeiling)" }
    default:
        return "未知极性 \(polarity)（只认 light / dark）"
    }
    return nil
}

/// 正对照用的合成画布：**直接写 bitmapData 字节**。
/// 早先试过 `setColor(atX:y:)` 逐点填 —— 不但什么都没写进去，还刷出 1.7 GB 色彩空间报错。
func syntheticCanvas(gray: UInt8, width: Int = 640, height: Int = 470) -> URL? {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 4 * width, bitsPerPixel: 32)
    guard let bitmap = rep, let data = bitmap.bitmapData else { return nil }
    for index in 0..<(width * height) {
        data[index * 4] = gray
        data[index * 4 + 1] = gray
        data[index * 4 + 2] = gray
        data[index * 4 + 3] = 255
    }
    guard let png = bitmap.representation(using: .png, properties: [:]) else { return nil }
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tcoder-brightness-selfcheck-\(gray).png")
    do { try png.write(to: url) } catch { return nil }
    return url
}

func selfcheck() -> Int {
    var failures = 0
    guard let white = syntheticCanvas(gray: 247), let black = syntheticCanvas(gray: 26) else {
        print("!! 合成画布都没造出来 —— 本 selfcheck 不出数，别把它的「绿」当成尺子没问题")
        return 1
    }
    defer { try? FileManager.default.removeItem(at: white); try? FileManager.default.removeItem(at: black) }

    func expectPass(_ url: URL, _ polarity: String, _ label: String) {
        let r = read(url.path)
        report(r)
        if let bad = verdict(r, polarity: polarity) {
            print("  ❌ 正对照失败：\(label) 应判通过（\(bad)）"); failures += 1
        } else {
            print("  ✅ \(label) 判通过")
        }
    }
    func expectFail(_ url: URL, _ polarity: String, _ label: String) {
        if verdict(read(url.path), polarity: polarity) == nil {
            print("  ❌ 正对照失败：\(label) 竟然判通过 —— 这把尺子永真"); failures += 1
        } else {
            print("  ✅ \(label) 判败（正是想要的）")
        }
    }
    expectPass(white, "light", "近白画布 / light")
    expectPass(black, "dark", "近黑画布 / dark")
    expectFail(white, "dark", "近白画布 / dark")
    expectFail(black, "light", "近黑画布 / light")
    print(failures == 0 ? "✅ selfcheck 通过：两极性各自认得，且互不放过对面"
                        : "!! selfcheck 失败 \(failures) 条")
    return failures == 0 ? 0 : 1
}

let args = Array(CommandLine.arguments.dropFirst())
if args.first == "selfcheck" { exit(Int32(selfcheck())) }
if args.first == "measure" {
    var bad = 0
    for path in args.dropFirst() {
        guard let r = read(path) else { print("\(path): 读不到图"); bad += 1; continue }
        report(r)
    }
    exit(bad == 0 ? 0 : 1)
}
guard args.count >= 2, args.first == "check" else {
    print("用法: page_brightness measure <png...> | check light|dark <png...> | selfcheck")
    exit(2)
}
let polarity = args[1]
var failed = 0, counted = 0
for path in args.dropFirst(2) {
    let r = read(path)
    report(r)
    counted += 1
    if let bad = verdict(r, polarity: polarity) {
        print("  ❌ \((path as NSString).lastPathComponent)：\(bad)")
        failed += 1
    }
}
if counted == 0 {
    print("!! 一张图都没传进来 —— 本判据不出数（不是通过）")
    exit(1)
}
print("== 极性 \(polarity)：\(counted - failed)/\(counted) 张合格")
exit(failed == 0 ? 0 : 1)
