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
//   page_edges selfcheck    正对照：内存里造四张"已知边距"的合成画布（浅/深两态各 304 与 320），
//                           量出来必须分别对上；**另有一张单色负对照**，整幅同亮度时必须拒绝出数。
//                           差一点就 exit 1 并说明为什么主门的读数不可信。
//                           **没有正对照的视觉尺子等于没有尺子。**
//
// 判"是不是卡面"**以画布为锚**（`luma ≥ 画布 + 5`），深浅两态共用一把尺子 ——
// 实测浅色画布 247/卡面 254（差 7 阶）、深色画布 19/卡面 37（差 18 阶），两态都是卡面更亮。
// 旧版用绝对值 ≥252，深色九页"一个白卡带都不认"，于是那半边验收没有像素判据（乱清单 §6 第 4 条）。
// 一行的卡面带会把字形造成的 <30px 缝隙并回去（不并缝的话"第一段白"往往是某个字
// 右边的空白，左边缘就会每行都不一样 —— 第一版就是这么错的）。
// 贴窗口左缘 5% 以内的带子一律不算内容列：深色侧的**侧栏比画布亮**，
// 旧版"逐行取众数"那次就是量出 8–280（那是侧栏，不是卡片）。
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

/// 一行里的卡面带（已并缝、已换算成 pt），由调用方取最宽的那一段。
///
/// **判"是不是卡面"以画布为锚，不用绝对值** —— 这样深浅两态共用一把尺子。
/// 实测（交付头 `53f9b1c` 总览页，@2x 原始像素）：浅色画布 247 阶 / 卡面 254 阶（差 7），
/// 深色画布 19 阶 / 卡面 37 阶（差 18）。两态**都是卡面比画布亮**，所以
/// `luma ≥ 画布 + 5` 一条就够：浅色侧等价于旧的那条 ≥252，深色侧把 19 与 37 分开。
///
/// 为什么旧版"比**该行**众数亮 4 阶"两条都坏了（不是阈值没调对，是基准选错）：
/// ① 行内大多数像素本身就是卡面 ⇒ 基准一换，浅色整行被并成一条 0–1280 的带；
/// ② 深色侧量出 8–280 —— 那是**侧栏**，它比画布亮，逐行判时它就是一个"卡面"。
/// 所以基准必须是**整幅一个数**（`canvasLuma`），并且带子必须排除贴窗口左缘的那一段。
func cardBands(_ rep: NSBitmapImageRep, y: Int, canvas: Int, minWidthPt: Int) -> [(start: Int, end: Int)] {
    // 贴左缘 5% 以内的带子是窗口边与侧栏，不是内容列（内容列左边距实测 272–304pt = 21–24%）。
    let contentStartPx = Int(Double(rep.pixelsWide) * 0.05)
    var raw: [(start: Int, end: Int)] = []
    var start = -1
    for x in contentStartPx..<rep.pixelsWide {
        var isCard = false
        if let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) {
            // ×255：`colorAt` 给的是 0…1，而 `canvas` 是 0…255 的阶数（`canvasLuma` 里已换算）。
            // 这两套单位混过一次：漏掉换算时整幅都"不是卡面"，四张夹具全量不出边。
            let luma = (0.2126 * color.redComponent + 0.7152 * color.greenComponent
                + 0.0722 * color.blueComponent) * 255
            isCard = luma >= Double(canvas) + 5
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
    // 起点正好落在扫描下界上的带子，是**被裁出来的**、不是自然边缘 ——
    // 深色侧的侧栏比画布亮（实测 30 阶 vs 19），不排掉它，卡缝那一行的"最宽带"就是侧栏，
    // p10 会被拉到 64pt（旧版"逐行取众数"量出 8–280 正是这个形状）。
    return merged.filter { $0.start > contentStartPx && ($0.end - $0.start) / 2 >= minWidthPt }
        .map { ($0.start / 2, $0.end / 2) }
}

/// **画布亮度**：直接量"侧栏与内容列之间那道缝"（实测 x 21.8%–23.2% 恒为画布，
/// 九页两态都成立），取它的众数；缝里若混进了别的东西（众数占比 < 80%）就返回 nil，
/// 让调用方**拒绝出数**，而不是拿一个猜出来的基准去量九页。
///
/// 为什么不用"内容列里两个主峰中较暗的那个"：那是猜的，而且真的会猜空 ——
/// 健康评分顶拍那张大环形卡几乎铺满内容列，采样带里剩不下 3% 的画布像素，
/// 于是**一把能量了 18 张浅色图的尺子，被这一改动判成读不出数**。
/// （"分不清'没有'和'没查'"是本仓反复踩过的那类坑：尺子坏的时候，它报出来的数也是误判候选。）
func canvasLuma(_ rep: NSBitmapImageRep) -> Int? {
    let x0 = Int(Double(rep.pixelsWide) * 0.218), x1 = Int(Double(rep.pixelsWide) * 0.232)
    let y0 = Int(Double(rep.pixelsHigh) * 0.30), y1 = Int(Double(rep.pixelsHigh) * 0.90)
    guard x1 > x0, y1 > y0 else { return nil }
    var hist: [Int: Int] = [:]
    var samples = 0
    for y in stride(from: y0, through: y1, by: 3) {
        for x in stride(from: x0, through: x1, by: 2) {
            guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let luma = Int((0.2126 * c.redComponent + 0.7152 * c.greenComponent
                + 0.0722 * c.blueComponent) * 255)
            hist[luma, default: 0] += 1
            samples += 1
        }
    }
    guard samples > 0, let top = hist.max(by: { $0.value < $1.value }) else { return nil }
    // 按**单值**占比要 80% 会误杀浅色：实测那条缝是 247±3 阶的抖动
    // （247 只占 62%，加上 244/245/246 才到 97%）。所以要按邻域合起来看，
    // 而不是把阈值调低 —— 调低会让"半条缝是侧栏"这种真的混采也放行。
    let near = hist.reduce(0) { $0 + (abs($1.key - top.key) <= 3 ? $1.value : 0) }
    return Double(near) / Double(samples) >= 0.85 ? top.key : nil
}

/// 只量内容区：上 22% 是页头与工具条，下 5% 留滚动条与阴影余量。
func measure(_ rep: NSBitmapImageRep) -> (left: Span?, right: Span?, rows: Int, canvas: Int?) {
    guard let canvas = canvasLuma(rep) else { return (nil, nil, 0, nil) }
    var lefts: [Int] = [], rights: [Int] = []
    let from = Int(Double(rep.pixelsHigh) * 0.22), to = Int(Double(rep.pixelsHigh) * 0.95)
    var y = from
    while y < to {
        if let widest = cardBands(rep, y: y, canvas: canvas, minWidthPt: 40)
            .max(by: { ($0.end - $0.start) < ($1.end - $1.start) }) {
            lefts.append(widest.start)
            rights.append(widest.end)
        }
        y += 8   // 每 4pt 取一行
    }
    return (Span.of(lefts), Span.of(rights), lefts.count, canvas)
}

/// 正对照夹具：画布 + 一块已知左右边的卡，全部在内存里画。
/// 深色夹具还带一条**贴左缘、比画布亮的侧栏** —— 那是旧版"逐行取众数"翻车的地方，
/// 新判据必须对它无感（带子起点被 `contentStartPx` 挡在内容列之外）。
///
/// 为什么不用 `NSBitmapImageRep.setColor(atX:y:)`：对自建位图它只会对着
/// `Unrecognized colorspace number -1` 刷 1.7 GB stderr，**而且一个像素都没画进去**
/// （实测两版都中招）。直接写 `bitmapData` 才是确定的。
func syntheticCanvas(cardLeft: Int, cardRight: Int, canvasValue: UInt8 = 247,
                     cardValue: UInt8 = 255, sidebarPt: Int = 0, sidebarValue: UInt8 = 0,
                     widthPt: Int = 1280, heightPt: Int = 949, scale: Int = 2) -> NSBitmapImageRep? {
    let w = widthPt * scale, h = heightPt * scale
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 4 * w, bitsPerPixel: 32),
          let base = rep.bitmapData else { return nil }
    let rowBytes = rep.bytesPerRow
    // 画**两块等高、左右边相同的卡 + 中间一道画布缝**：真实页面就是这个形状。
    // 只画一块满高卡的话，取基准用的那条采样带里全是卡面、没有第二个峰，
    // `canvasLuma` 会正确地拒绝出数 —— 夹具得像现场，否则它测的是夹具的脾气。
    let cardRows: [(Int, Int)] = [(h / 5, h * 60 / 100), (h * 68 / 100, h * 95 / 100)]
    for y in 0..<h {
        let rowIsCardBand = cardRows.contains { y >= $0.0 && y < $0.1 }
        for x in 0..<w {
            let inCard = rowIsCardBand && x >= cardLeft * scale && x < cardRight * scale
            let inSidebar = x < sidebarPt * scale
            var value = inCard ? cardValue : canvasValue
            if inSidebar && rowIsCardBand { value = sidebarValue }
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
    // 两态各一组已知边距的夹具。深色那组带贴左缘、比画布亮的侧栏（旧版就是在这里量出"8–280"）。
    // 夹具的卡左边取 304 / 320：画布基准是从"侧栏与内容列之间那道缝"（x 21.8%–23.2%
    // = 279–297pt）读的，左边距再小就会把缝盖掉，基准就读成卡面了。
    let cases: [(name: String, left: Int, right: Int, canvas: UInt8, card: UInt8,
                 sidebarPt: Int, sidebarValue: UInt8)] = [
        ("浅色", 304, 1255, 247, 255, 0, 0),
        ("浅色", 320, 1240, 247, 255, 0, 0),
        ("深色", 304, 1255, 19, 37, 256, 30),
        ("深色", 320, 1240, 19, 37, 256, 30),
    ]
    for item in cases {
        guard let rep = syntheticCanvas(cardLeft: item.left, cardRight: item.right,
                                        canvasValue: item.canvas, cardValue: item.card,
                                        sidebarPt: item.sidebarPt, sidebarValue: item.sidebarValue) else {
            failures.append("\(item.name)夹具 \(item.left)–\(item.right) 造不出位图（连夹具都造不出来，主门自然是空转）")
            continue
        }
        let got = measure(rep)
        guard let lo = got.left, let hi = got.right else {
            failures.append("\(item.name)夹具 \(item.left)–\(item.right) 量不出边：尺子对已知答案都瞎")
            continue
        }
        let line = "\(item.name)夹具 期望 \(item.left)–\(item.right) → 量到 \(lo.median)–\(hi.median)"
            + "（画布读到 \(got.canvas ?? -1) 阶，\(lo.rows) 行）"
        print("[selfcheck] " + line)
        if lo.median != item.left || hi.median != item.right {
            failures.append("\(line) —— 对不上，主门的读数一律不可信")
        }
    }
    // 反例：两张夹具只差 16pt 边距，主门若报出同一个数，说明它根本没在分辨。
    if let a = syntheticCanvas(cardLeft: 304, cardRight: 1255),
       let b = syntheticCanvas(cardLeft: 320, cardRight: 1240) {
        let la = measure(a).left?.median ?? -1, lb = measure(b).left?.median ?? -1
        print("[selfcheck] 分辨力：304 与 320 两张夹具分别量到 \(la) / \(lb)")
        if la == lb { failures.append("两张边距不同的夹具量出同一个左边缘 ⇒ 尺子没有分辨力") }
    }
    // 负对照：单色画布（没有第二个峰）必须**拒绝出数**，不能猜一个基准继续量。
    if let flat = syntheticCanvas(cardLeft: 304, cardRight: 1255, canvasValue: 247, cardValue: 247),
       measure(flat).left != nil {
        failures.append("整幅同亮度的画布仍然报出了边距 ⇒ 基准是猜出来的，读数不可信")
    } else {
        print("[selfcheck] 负对照：单色画布拒绝出数 ✅")
    }
    for reason in failures { print("❌ \(reason)") }
    if failures.isEmpty {
        print("✅ 正对照通过：深浅两态都量得出已知边距、分得出 16pt 的差别，且拿不到基准时不出数")
    }
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
        print("\(name): 认不出画布与卡面的两档（或一个卡带都没认出来）—— 不出数（取不到数不算通过）")
        continue
    }
    print("\(name)\t画布=\(got.canvas ?? -1)阶\t左边缘 中位=\(lo.median) p10-p90=\(lo.low)-\(lo.high)\t"
        + "右边缘 中位=\(hi.median) p10-p90=\(hi.low)-\(hi.high)\t(\(lo.rows) 行)")
}
exit(0)
