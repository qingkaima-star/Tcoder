import AppKit
import Foundation

// 跨页并排量同一个量：**内容列的左边缘与右边缘**（单位 pt，截图 @2x 已除 2）。
// 报告器（**不是闸门**）。
//
// 为什么要"并排"量：九页是一张一张看的，"这页卡片的左边距和那页不一样"这类问题
// 只有把同一个量的九个数摆在一起才现形。本仓已经吃过四次这个亏（跨页对同一个量
// 一次挖出四条缺陷），所以这一把读数从入库第一天就带正对照。
//
// 用法：
//   page_edges <png...>     每张图一行
//   page_edges selfcheck    正对照：内存里造两张"已知边距"的合成画布（304 与 272），
//                           量出来必须分别是 304 / 272；差一点就 exit 1 并说明为什么
//                           主门的读数不可信。**没有正对照的视觉尺子等于没有尺子。**
//
// 判"是不是卡面"用绝对值（三通道 ≥252）⇒ **这把尺子只量浅色态**。
// 深色九页实测"一个白卡带都不认"（那侧画布与卡面都压在暗部），尺子于是正确地不出数；
// 试过把判据换成"比该行众数亮 4 阶"以求深浅通用，两条都坏了（见 `cardBands` 上方注释）。
// 一行的白卡带会把字形造成的 <30px 缝隙并回去（不并缝的话"第一段白"往往是某个字
// 右边的空白，左边缘就会每行都不一样 —— 第一版就是这么错的）。
// 逐行取边会因抗锯齿/阴影抖 ±2px，所以报**中位数 + p10–p90**，不报众数。

struct Span {
    var median: Int
    var low: Int
    var high: Int
    var rows: Int

    static func of(_ values: [Int]) -> Span? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        func at(_ fraction: Double) -> Int {
            sorted[min(sorted.count - 1, max(0, Int(Double(sorted.count) * fraction)))]
        }
        return Span(median: at(0.5), low: at(0.1), high: at(0.9), rows: sorted.count)
    }
}

/// 一行里的白卡带（已并缝、已换算成 pt），由调用方取最宽的那一段。
///
/// ⚠ 只量**浅色态**。判"是不是卡面"用绝对值（三通道都 ≥252）：浅色画布 #F7F7F7 = 247
/// 与卡面 255 差 8 阶，落在同一档噪声之外。
/// 试过改成"比该行众数亮 4 阶"以求深浅通用，**结果两条都坏了**：
/// 浅色侧整行被并成一条 0–1280 的带（卡面本身占了行内大多数像素，众数一换基准就飘），
/// 深色侧只量出 8–280（那是侧栏）。⇒ 绝对阈值这一版是正对照验过的，换判据等于换掉那把尺子。
func cardBands(_ rep: NSBitmapImageRep, y: Int, minWidthPt: Int) -> [(start: Int, end: Int)] {
    var raw: [(start: Int, end: Int)] = []
    var start = -1
    for x in 0..<rep.pixelsWide {
        var isCard = false
        if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
            isCard = color.redComponent * 255 >= 252
                && color.greenComponent * 255 >= 252
                && color.blueComponent * 255 >= 252
        }
        if isCard, start < 0 { start = x }
        if !isCard, start >= 0 { raw.append((start, x)); start = -1 }
    }
    if start >= 0 { raw.append((start, rep.pixelsWide)) }

    var merged: [(start: Int, end: Int)] = []
    for piece in raw {
        if let last = merged.last, piece.start - last.end < 30 {
            merged[merged.count - 1] = (last.start, piece.end)
        } else {
            merged.append(piece)
        }
    }
    return merged.filter { ($0.end - $0.start) / 2 >= minWidthPt }
        .map { ($0.start / 2, $0.end / 2) }
}

/// 只量内容区：上 22% 是页头与工具条，下 5% 留滚动条与阴影余量。
func measure(_ rep: NSBitmapImageRep) -> (left: Span?, right: Span?, rows: Int) {
    var lefts: [Int] = [], rights: [Int] = []
    let from = Int(Double(rep.pixelsHigh) * 0.22), to = Int(Double(rep.pixelsHigh) * 0.95)
    var y = from
    while y < to {
        if let widest = cardBands(rep, y: y, minWidthPt: 40)
            .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            lefts.append(widest.start)
            rights.append(widest.end)
        }
        y += 8   // 每 4pt 取一行
    }
    return (Span.of(lefts), Span.of(rights), lefts.count)
}

/// 正对照夹具：灰画布 + 一块已知左右边的白卡，全部在内存里画。
///
/// 为什么不用 `NSBitmapImageRep.setColor(atX:y:)`：对自建位图它只会对着
/// `Unrecognized colorspace number -1` 刷 1.7 GB stderr，**而且一个像素都没画进去**
/// （实测两版都中招）。直接写 `bitmapData` 才是确定的。
func syntheticCanvas(cardLeft: Int, cardRight: Int, widthPt: Int = 1280,
                     heightPt: Int = 949, scale: Int = 2) -> NSBitmapImageRep? {
    let w = widthPt * scale, h = heightPt * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 4 * w, bitsPerPixel: 32),
          let base = rep.bitmapData else { return nil }
    let rowBytes = rep.bytesPerRow
    for y in 0..<h {
        for x in 0..<w {
            let inCard = x >= cardLeft * scale && x < cardRight * scale && y >= h / 5
            let value: UInt8 = inCard ? 255 : 247
            let offset = y * rowBytes + x * 4
            base[offset] = value
            base[offset + 1] = value
            base[offset + 2] = value
            base[offset + 3] = 255
        }
    }
    return rep
}

func runSelfCheck() -> Int32 {
    var failures: [String] = []
    for (left, right) in [(304, 1255), (272, 1240)] {
        guard let rep = syntheticCanvas(cardLeft: left, cardRight: right) else {
            failures.append("造不出 \(left)–\(right) 的夹具位图（连夹具都造不出来，主门自然是空转）")
            continue
        }
        let got = measure(rep)
        guard let lo = got.left, let hi = got.right else {
            failures.append("夹具 \(left)–\(right) 量不出边：尺子对已知答案都瞎")
            continue
        }
        let line = "夹具 期望 \(left)–\(right) → 量到 \(lo.median)–\(hi.median)（\(lo.rows) 行）"
        print("[selfcheck] " + line)
        if lo.median != left || hi.median != right {
            failures.append("\(line) —— 对不上，主门的读数一律不可信")
        }
    }
    // 反例：两张夹具只差 32pt 边距，主门若报出同一个数，说明它根本没在分辨。
    if let a = syntheticCanvas(cardLeft: 304, cardRight: 1255),
       let b = syntheticCanvas(cardLeft: 272, cardRight: 1240) {
        let la = measure(a).left?.median ?? -1, lb = measure(b).left?.median ?? -1
        print("[selfcheck] 分辨力：304 与 272 两张夹具分别量到 \(la) / \(lb)")
        if la == lb { failures.append("两张边距不同的夹具量出同一个左边缘 ⇒ 尺子没有分辨力") }
    }
    for reason in failures { print("❌ \(reason)") }
    if failures.isEmpty { print("✅ 正对照通过：这把尺子量得出已知边距，也分得出 32pt 的差别") }
    return failures.isEmpty ? 0 : 1
}

let arguments = Array(CommandLine.arguments.dropFirst())
if arguments.first == "selfcheck" {
    exit(runSelfCheck())
}
guard !arguments.isEmpty else {
    print("usage: page_edges <png...> | page_edges selfcheck")
    exit(2)
}
for path in arguments {
    let name = (path as NSString).lastPathComponent
    guard let data = FileManager.default.contents(atPath: path),
          let rep = NSBitmapImageRep(data: data) else {
        print("\(name): 读不到位图 —— 不出数")
        continue
    }
    let got = measure(rep)
    guard let lo = got.left, let hi = got.right else {
        print("\(name): 一个白卡带都没认出来 —— 不出数（取不到数不算通过）")
        continue
    }
    print("\(name)\t左边缘 中位=\(lo.median) p10-p90=\(lo.low)-\(lo.high)\t"
        + "右边缘 中位=\(hi.median) p10-p90=\(hi.low)-\(hi.high)\t(\(lo.rows) 行)")
}
exit(0)
