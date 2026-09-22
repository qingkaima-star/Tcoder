import AppKit

// 卡面判据：在给定 x 带里逐行报"这一行是白卡还是灰底"，用来定**卡片自己的上下边界**。
//
// 为什么要有它（另外三把尺子都答不了这个问题）：
//   * `page_brightness` 判整张图的极性（这一张到底是不是那个性态）；
//   * `page_edges` 判跨页的左右边距；
//   * `chart_axis_ink` 只认得**墨**，也就是文字与线 —— 它知道"最后一行字在哪"，
//     但不知道卡片画到哪儿结束，于是量不出"文字下面还剩多少空白"。
// 而"空态撑高""卡片太空"这类**密度**判断要的恰好是这个数：卡高 − 文字止于何处。
// 立它的直接理由见 `docs/界面语言-对齐AiX.md` §6.22（趋势卡空态 290pt → 116pt）。
//
// 报告器，**不是闸门**：它只报带区间，"多高算太挤/太空"由人判。
// 判据是绝对亮度（≥0.99 且过半像素 ⇒ 白卡），所以**只在浅色态成立** ——
// 深色态卡面本来就暗，整幅都会读成"灰底"（同 `pixel_audit` 的深色盲区，见乱清单 §6 第 4 条）。
//
// 用法: card_edges <png> <x0> <x1> <y0> <y1>      坐标一律 0~1 比例（截图有 @2x 与非 @2x 两种）

let a = CommandLine.arguments
guard a.count >= 6, let img = NSImage(contentsOfFile: a[1]),
      let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
    print("用法: card_edges <png> <x0> <x1> <y0> <y1>")
    exit(2)
}
let w = rep.pixelsWide, h = rep.pixelsHigh
guard w > 0, h > 0 else { print("图是空的（0 像素），本判据不出数"); exit(1) }

func fraction(_ raw: String, _ name: String) -> Double {
    guard let value = Double(raw), (0...1).contains(value) else {
        print("!! \(name) 要是 0~1 的比例，收到 \(raw)"); exit(2)
    }
    return value
}
let x0 = Int(fraction(a[2], "x0") * Double(w)), x1 = min(Int(fraction(a[3], "x1") * Double(w)), w - 1)
let y0 = Int(fraction(a[4], "y0") * Double(h)), y1 = min(Int(fraction(a[5], "y1") * Double(h)), h - 1)
guard x1 > x0, y1 > y0 else { print("!! 区间为空（x \(x0)–\(x1) / y \(y0)–\(y1)）"); exit(1) }

func luma(_ x: Int, _ y: Int) -> Double {
    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return 1 }
    return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
}

// 一行里过半像素亮到 0.99 以上 ⇒ 这行落在白卡上；否则是灰画布或卡缝。
func isCardRow(_ y: Int) -> Bool {
    var white = 0, total = 0
    for x in stride(from: x0, through: x1, by: 3) {
        total += 1
        if luma(x, y) >= 0.99 { white += 1 }
    }
    return total > 0 && Double(white) / Double(total) > 0.5
}

var state = isCardRow(y0), start = y0
for y in stride(from: y0, through: y1, by: 1) {
    let now = isCardRow(y)
    if now != state {
        print(String(format: "%@ %4d–%4d  高 %dpx = %dpt", state ? "白卡" : "灰底",
                     start, y, y - start, (y - start) / 2))
        state = now
        start = y
    }
}
print(String(format: "%@ %4d–%4d  高 %dpx = %dpt（到扫描末）", state ? "白卡" : "灰底",
             start, y1, y1 - start, (y1 - start) / 2))
