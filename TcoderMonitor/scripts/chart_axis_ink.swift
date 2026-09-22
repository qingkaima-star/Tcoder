import AppKit

// 图上的**文字团落在哪儿**：把截图按列投影，报出暗团（字形簇）的区间与在绘图区里的百分比。
//
// 报告器（**不是闸门**）：它回答"这张图的轴上到底有几枚标签、分别在哪"，
// 不替人判"够不够"。立它的直接理由 —— §6.19 那两个数字（标签中心在 47% 与 92%）
// 是肉眼在缩略图上看不出来的，而"肉眼看着左边空"这句话必须能被别人复算。
//
// ⚠️ **暗阈必须是 0.62，不是"黑字"的 0.45。** 第一版取 0.45，整行轴标签一个都没扫到，
// 差点据此写下"那行根本没有标签"这条假缺陷 —— 轴标签走 `Color.secondary`，
// 在浅色态实测亮度 0.45~0.60，正好落在 0.45 之上。
// 尺子坏的时候，它报出来的"缺陷"也是误判候选（本仓第 N 次）。
//
// 用法：
//   chart_axis_ink rows <png> <y0> <y1>              逐 4 行报暗列数（用来**找**标签那一横带）
//   chart_axis_ink runs <png> <y0> <y1> [<x0> <x1>]  该带内按列投影，把暗团按 14pt 间隙分簇，
//                                                    每簇报像素区间、宽度、以及在给定横坐标里的百分比
// 坐标一律是**比例**（0~1），因为截图有 @2x 与非 @2x 两种。

let args = CommandLine.arguments
guard args.count >= 5, let image = NSImage(contentsOfFile: args[2]),
      let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    print("用法: chart_axis_ink rows|runs <png> <y0> <y1> [<x0> <x1>]")
    exit(2)
}
let width = rep.pixelsWide, height = rep.pixelsHigh
guard width > 0, height > 0 else { print("图是空的（0 像素）"); exit(1) }

func isInk(_ x: Int, _ y: Int) -> Bool {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
    let luma = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    return luma < 0.62
}

func fraction(_ raw: String, _ name: String) -> Double {
    guard let value = Double(raw), (0...1).contains(value) else {
        print("!! \(name) 要是 0~1 的比例，收到 \(raw)"); exit(2)
    }
    return value
}

let y0 = Int(fraction(args[3], "y0") * Double(height))
let y1 = Int(fraction(args[4], "y1") * Double(height))
guard y1 > y0 else { print("!! y1 必须大于 y0"); exit(2) }

if args[1] == "rows" {
    var y = y0
    while y < y1 {
        var count = 0
        for x in stride(from: 0, to: width, by: 2) where isInk(x, y) { count += 1 }
        print(String(format: "y=%4d (%.3f) 暗列 %d", y, Double(y) / Double(height), count))
        y += 4
    }
    exit(0)
}
guard args.count >= 7 else { print("!! runs 还要 x0 x1"); exit(2) }
let x0 = min(Int(fraction(args[5], "x0") * Double(width)), width - 1)
let x1 = min(max(Int(fraction(args[6], "x1") * Double(width)), x0 + 1), width - 1)

var runs: [(start: Int, end: Int)] = []
var start = -1
for x in x0...min(x1, width - 1) {
    var hit = false
    for y in y0..<y1 where isInk(x, y) { hit = true; break }
    if hit && start < 0 { start = x }
    if !hit && start >= 0 { runs.append((start, x)); start = -1 }
}
if start >= 0 { runs.append((start, min(x1, width - 1))) }

// 单个字形宽 3~8pt、字间隙 ≤2pt、冒号两侧留缝；簇间隙取 14pt 才不把一枚标签劈成两半。
let clusterGapPt = 14
var clusters: [(Int, Int)] = []
for run in runs where run.end - run.0 > 6 {          // <6px 的是抗锯齿碎点，不算字
    let left = run.0 / 2, right = run.1 / 2
    if let last = clusters.last, left - last.1 < clusterGapPt {
        clusters[clusters.count - 1] = (last.0, max(last.1, right))
    } else {
        clusters.append((left, right))
    }
}
print("== \(clusters.count) 枚文字团（带内按 \(clusterGapPt)pt 间隙分簇；坐标单位 pt）")
for cluster in clusters {
    print(String(format: "  %4d–%4d  宽 %3dpt  中心 %dpt", cluster.0, cluster.1,
                 cluster.1 - cluster.0, (cluster.0 + cluster.1) / 2))
}
if clusters.isEmpty {
    print("   ↑ 空集不等于「这行没有字」：先怀疑阈值与 y 带，跑 `rows` 找暗列最多的那一行")
}
