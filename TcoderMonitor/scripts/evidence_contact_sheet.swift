import AppKit

// 交付复核用的**拼版图**：把九页各自"最近一次实拍"的那张图拼成一张，
// 每格标上页名与**它是在哪个提交上拍的**。
//
// 为什么要它（而不是让人去 `.scratch/` 里翻九个目录）：
// 验收这句话（"深浅两态九页全部实拍复核通过"）要能被两分钟看完，
// 而逐页账 `docs/界面-乱的清单.md` 那张表已经写清了每页对应哪一批 ——
// 本脚本**读的就是那张表**（同一把解析：`git log <头>..HEAD -- <路径>`），
// 所以拼版图不会自己漂成"某天的旧图"：表更新了，图才更新。
//
// 用法：
//   evidence_contact_sheet <模式 light|dark> <输出 png> [表路径] [取证根目录]
//
// 缺任何一页 ⇒ **直接报错退出**，不许少拼一格还自称"九页"。
//   （少一格而输出成功，是这类报告器最危险的死法：它看起来在工作。）

let args = CommandLine.arguments
guard args.count >= 3, ["light", "dark"].contains(args[1]) else {
    FileHandle.standardError.write("用法: evidence_contact_sheet <light|dark> <输出.png> [表] [取证根]\n".data(using: .utf8)!)
    exit(2)
}
let mode = args[1]
let output = args[2]
let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let tablePath = args.count > 3 ? args[3] : cwd.appendingPathComponent("docs/界面-乱的清单.md").path
let evidenceRoot = args.count > 4
    ? URL(fileURLWithPath: args[4])
    : cwd.appendingPathComponent(".scratch")

// MARK: - 读那张逐页账

struct Tile { var page: String; var batch: String; var head: String; var url: URL }

let batchPattern = try! NSRegularExpression(pattern: #"^\| ([^|]+) \| `(evidence-[^/`]+)/` \|"#)
let tableText = try String(contentsOfFile: tablePath, encoding: .utf8)

var tiles: [Tile] = []
var missing: [String] = []
for raw in tableText.split(separator: "\n") {
    var line = String(raw)
    while line.hasPrefix(">") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
    guard line.hasPrefix("| ") else { continue }
    let cells = line.split(separator: "|", omittingEmptySubsequences: false).dropFirst().map {
        $0.trimmingCharacters(in: .whitespaces)
    }
    guard cells.count >= 2 else { continue }
    let range = NSRange(line.startIndex..., in: line)
    guard let match = batchPattern.firstMatch(in: line, range: range),
          let pageRange = Range(match.range(at: 1), in: line),
          let batchRange = Range(match.range(at: 2), in: line) else { continue }
    let batch = String(line[batchRange])
    let head = String(batch.dropFirst("evidence-".count).prefix(7))
    for page in String(line[pageRange]).split(whereSeparator: { $0 == "/" || $0 == "·" || $0 == "、" })
        .map({ $0.trimmingCharacters(in: .whitespaces) }).filter({ !$0.isEmpty }) {
        if page.contains("全九页") || page.contains("外壳") { continue }   // 那一行管的是公共基座
        let url = evidenceRoot.appendingPathComponent(batch)
            .appendingPathComponent("\(mode)-top")
            .appendingPathComponent("\(page).png")
        if FileManager.default.fileExists(atPath: url.path) {
            tiles.append(Tile(page: page, batch: batch, head: head, url: url))
        } else {
            missing.append("\(page)（\(batch)/\(mode)-top/）")
        }
    }
}

guard !tiles.isEmpty else {
    FileHandle.standardError.write("表里一格都没解析出来 ⇒ 表格式变了，这张图不该存在\n".data(using: .utf8)!)
    exit(1)
}
guard missing.isEmpty else {
    FileHandle.standardError.write(("缺页，不出图（少一格还自称九页是最危险的死法）：\n  "
        + missing.joined(separator: "\n  ") + "\n").data(using: .utf8)!)
    exit(1)
}

// MARK: - 拼图

let columns = 3
let tileWidth = 720.0
let labelHeight = 26.0
let gap = 12.0
let rows = Int(ceil(Double(tiles.count) / Double(columns)))
let tileHeight = tileWidth * 2000.0 / 2560.0          // 实拍是 2560×2000 @2x
let canvas = NSSize(width: CGFloat(columns) * tileWidth + CGFloat(columns + 1) * gap,
                    height: CGFloat(rows) * (tileHeight + labelHeight) + CGFloat(rows + 1) * gap)
let background: NSColor = mode == "dark" ? NSColor(white: 0.08, alpha: 1) : NSColor(white: 0.93, alpha: 1)

guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                                 pixelsWide: Int(canvas.width), pixelsHigh: Int(canvas.height),
                                 bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                 isPlanar: false, colorSpaceName: .deviceRGB,
                                 bytesPerRow: 0, bitsPerPixel: 0) else { exit(1) }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
background.setFill()
NSBezierPath(rect: NSRect(origin: .zero, size: canvas)).fill()

let labelFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
let labelColor: NSColor = mode == "dark" ? .white : NSColor(white: 0.15, alpha: 1)

for (index, tile) in tiles.enumerated() {
    let row = index / columns
    let column = index % columns
    // AppKit 的 y 轴向上：第一行画在画布顶部。
    let x = gap + Double(column) * (tileWidth + gap)
    let y = canvas.height - (gap + Double(row + 1) * (tileHeight + labelHeight) + Double(row) * gap)
    let imageRect = NSRect(x: x, y: y, width: tileWidth, height: tileHeight)
    if let image = NSImage(contentsOf: tile.url) {
        image.draw(in: imageRect, from: .zero, operation: .sourceOver, fraction: 1.0)
    }
    let label = "\(tile.page)  @ \(tile.head)"
    (label as NSString).draw(at: NSPoint(x: x + 2, y: y + tileHeight + 4),
                             withAttributes: [.font: labelFont, .foregroundColor: labelColor])
}
NSGraphicsContext.restoreGraphicsState()

guard let data = rep.representation(using: .png, properties: [:]) else { exit(1) }
try data.write(to: URL(fileURLWithPath: output))
print("拼好的格数 \(tiles.count)（模式 \(mode)）→ \(output)")
print("每格标的头来自逐页账 \(tablePath)，不是脚本自己猜的")
