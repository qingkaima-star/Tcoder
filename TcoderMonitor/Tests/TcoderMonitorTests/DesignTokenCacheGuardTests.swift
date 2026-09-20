import AppKit
import Foundation
import SwiftUI
import XCTest

@testable import TcoderMonitor

// MARK: - Design 令牌缓存守卫（性能 spec §5 的 C 包）
//
// 病因（xctrace 实测，不是推断）：主线程 684/807 样本里 64.3% 在 SwiftUI 视图图更新；
// 1.5 s 一次心跳把 app-update 相位撑到 10.8~24.8ms，而预算是 8.33ms。`render` 相位健康
// （p95 4.05ms），**所以战场在 CPU 侧的对象构造，不在 GPU**。令牌层三条靶子改前都是
// "每次访问现造"：
//
//   1. `ColorToken.swift` 的 `DualColor.color` / `ColorTokenPair.color` —— 每次访问
//      new 一个 `NSColor(name: nil) {}` 再包一层 `Color(nsColor:)`。取色点大量落在
//      `ForEach` / 图表 Mark 闭包里：每 tick 约 90×2（实时曲线）+ 90（总览）
//      + 168（Git 热力图）≈ 500 个动态色对象。
//   2. `ThemeTokens.swift` 的 `TypeToken.font` 是计算属性，而 `.font(` 全仓 183 处。
//   3. `ChartTokens.swift` 的 `Theme.Chart.areaGradient(at:intensity:)` 每次调用现造
//      `LinearGradient`（含 `Gradient` 与两个 `GradientStop`）。
//
// 本文件两件事：① **命中数**（主指标）——同一令牌连续访问 1000 次，新构造出来的包装对象
// 必须 ≤1；② **形状**（次指标）——`Design/**` 的计算属性体内不许再出现这些构造式。
// 两把尺子各补对方的盲区：把 `NSColor(name:)` 挪进私有 `static func` 再逐次调用，形状守卫
// 看不见，但 `DesignTokenMeter` 数得出来；反之若有人把计数也绕过（另起一处裸构造），
// 形状守卫与"出口必须查表"那两条会红。
//
// 关于第 ① 件事的可行性：三条结论都由本机编译探针实测（`/tmp` 下独立 swiftc 产物，
// 非猜测），故守卫里明写了探针结论：
//   · `Color(nsColor: 动态NSColor)` 经 `NSColor(color).usingColorSpace(.sRGB)` 在
//     `performAsCurrentDrawingAppearance` 里能解析出**精确**分量：浅 #0A0A0A / 深 #F2F2F5；
//   · 同一个 NSColor 实例包出的两个 `Color` 相等，两个**独立**动态 NSColor 包出的**不**相等
//     —— 于是"两次取色是否相等"能直接反证缓存有没有生效；
//   · `LinearGradient` **不是** `Equatable`（编译期事实），但它的 `String(reflecting:)`
//     会露出 stop 色是 `AppKitPlatformColorProvider`（动态）还是 `#0A0A0AFF`（已钉死）。
//
// 阈值口径：形状守卫与命中数都收 **0 / ≤1**，不做"只减不增棘轮"。理由是这三条靶子的
// 合法值就是 0 次现造（构造点已全部挪进 `init` / 一次性表），留一个"允许 N 次"的口子
// 等于允许 N 个复发位。

final class DesignTokenCacheGuardTests: XCTestCase {

    // MARK: - 扫描器（纯函数，可在合成输入上跑；见下方元测试）
    // ==== SCANNER-BEGIN ====（这一段不依赖 XCTest，可整段搬到 /tmp 单跑自证）

    /// "每次访问现造"的构造点写法。出现在 `Design/**` 的**计算属性体**里即判红。
    static let perAccessConstructorNeedles: [String] = [
        "NSColor(name:",       // 动态色包装器
        "NSColor(srgbRed:",    // 分量色
        "Color(nsColor:",      // AppKit → SwiftUI 包装
        "LinearGradient(",     // 渐变（含 Gradient + GradientStop 数组）
        "Font.system(",        // 字面 Font
    ]

    /// 一个计算属性：声明行号（1-based）与剥掉注释后的花括号内原文。
    struct ComputedBody {
        var path: String
        var name: String
        var line: Int
        var code: String
    }

    /// 剥掉注释：整行 `//` 直接丢弃，行尾 `//` 截断。
    /// 必须能提到被禁写法（`ColorToken` 的类型头注释就在解释"为什么禁"），
    /// 但也不能把代码一起剥掉 —— 两个方向都有元测试钉着。
    static func stripComments(_ line: String) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("//") { return "" }
        guard let slash = line.range(of: "//") else { return line }
        // 只处理最简单的行尾注释形态：本仓 Design 层没有 `url://` 这类字面量
        // （由 test_scannersCatchThePreChangeShapes 的正例保证不误剥）。
        return String(line[..<slash.lowerBound])
    }

    /// 该代码行是否是一个计算属性的声明行；是则返回属性名。
    /// 判据：行首（剥注释后）是 `<修饰符>* var <name> : <类型> {`，且 `{` 前没有 `=`
    /// —— 有 `=` 的是带默认值的存储属性（`var tracking: CGFloat = 0`），
    /// 没有 `{` 的是纯存储属性（`var color: Color`），两者都不算。
    static func computedVarName(in code: String) -> String? {
        let trimmed = code.trimmingCharacters(in: .whitespaces)
        guard let varRange = trimmed.range(of: #"var\s+"#, options: .regularExpression) else { return nil }
        let head = trimmed[..<varRange.lowerBound]
        guard head.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == " " }) else { return nil }
        let afterVar = trimmed[varRange.upperBound...]
        guard let colon = afterVar.firstIndex(of: ":") else { return nil }
        let name = afterVar[..<colon].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
        let rest = afterVar[afterVar.index(after: colon)...]
        guard let brace = rest.firstIndex(of: "{") else { return nil }
        if let equals = rest.firstIndex(of: "="), equals < brace { return nil }   // 带默认值的存储属性
        return name
    }

    /// 从 `startLine` 声明行的第一个 `{` 起做花括号配平，返回体内文本与结束行。
    /// 前置条件：`codes[startLine]` 在 `braceAt` 处是 `{`（调用方保证）。
    static func blockText(from codes: [String], startLine: Int, braceAt: String.Index) -> (text: String, endLine: Int) {
        var depth = 1
        var text = ""
        var line = startLine
        while line < codes.count {
            let segment = line == startLine ? String(codes[line][codes[line].index(after: braceAt)...]) : codes[line]
            var closedInside = false
            for ch in segment {
                if ch == "{" { depth += 1 }
                else if ch == "}" {
                    depth -= 1
                    if depth == 0 { closedInside = true; break }
                }
            }
            text += segment + "\n"
            if closedInside { return (text, line) }
            line += 1
        }
        return (text, min(line, codes.count - 1))   // 未配平（文件被截断）时不越界
    }

    static func computedBodies(path: String, content: String) -> [ComputedBody] {
        let codes = content.split(separator: "\n", omittingEmptySubsequences: false)
            .map { stripComments(String($0)) }
        var out: [ComputedBody] = []
        var index = 0
        while index < codes.count {
            guard computedVarName(in: codes[index]) != nil,
                  let braceAt = codes[index].firstIndex(of: "{") else { index += 1; continue }
            let name = computedVarName(in: codes[index]) ?? "?"
            let block = blockText(from: codes, startLine: index, braceAt: braceAt)
            out.append(ComputedBody(path: path, name: name, line: index + 1, code: block.text))
            index = block.endLine + 1
        }
        return out
    }

    static func computedBodies(in files: [(path: String, content: String)]) -> [ComputedBody] {
        files.flatMap { computedBodies(path: $0.path, content: $0.content) }
    }

    /// 计算属性体里的构造点命中，形状 `路径:行号:属性名 → 写法`。
    static func perAccessConstructorHits(in files: [(path: String, content: String)]) -> [String] {
        computedBodies(in: files).flatMap { body in
            perAccessConstructorNeedles
                .filter { body.code.contains($0) }
                .map { "\(body.path):\(body.line):\(body.name) → \($0)" }
        }
    }

    /// 取包含 `declaration` 那段声明的花括号块文本（用于钉"出口必须查表"）。
    static func block(containing declaration: String, in content: String) -> String? {
        let raw = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let codes = raw.map { stripComments($0) }
        guard let line = codes.firstIndex(where: { $0.contains(declaration) }),
              codes[line].contains("{") || (line + 1 < codes.count && codes[line + 1].contains("{"))
        else { return nil }
        let start = codes[line].contains("{") ? line : line + 1
        guard let braceAt = codes[start].firstIndex(of: "{") else { return nil }
        return blockText(from: codes, startLine: start, braceAt: braceAt).text
    }

    // ==== SCANNER-END ====

    // MARK: - 真源码定位

    /// 仓库根走 `#filePath` 回溯（与 `BorderlessSurfaceGuardTests` 同一套写法）：
    /// 测试进程 CWD 不是包根，按相对路径扫会"静默扫不到东西、然后判通过"。
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    /// 与 `BorderlessSurfaceGuardTests.sourceFiles(under:)` 刻意各留一份：
    /// 那一份归总工名下的无界守卫，本份归性能轮，谁改路径口径都会在**自己**的分母断言上炸。
    static func sourceFiles(under subpath: String) throws -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let dir = root.appendingPathComponent(subpath)
        guard let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        else {
            XCTFail("扫不到 \(dir.path) —— 路径口径变了，这条守卫会假绿")
            return []
        }
        let urls = walker.compactMap { $0 as? URL }
        guard !urls.isEmpty else {
            XCTFail("\(dir.path) 下一个文件都没有 —— 路径口径变了，这条守卫会假绿")
            return []
        }
        return urls.filter { $0.pathExtension == "swift" }.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.path.replacingOccurrences(of: root.path + "/", with: ""), text)
        }.sorted { $0.path < $1.path }
    }

    private func designFiles() throws -> [(path: String, content: String)] {
        try Self.sourceFiles(under: "Design")
    }

    // MARK: - ① 主指标：连续访问 1000 次，新构造的包装对象 ≤ 1

    /// 把全站令牌摸一遍，让所有 lazy `static let` 都完成初始化。
    /// 没有这一步，"命中数"窗口里会混进首次构造（那是缓存本来的样子，不是 bug）。
    private func warmUpAllTokens() {
        for role in Theme.Semantic.all {
            _ = role.textColor
            _ = role.graphicColor
            _ = role.onFillColor
            _ = role.badgeFill()
            _ = role.badgeFill(in: .dark)
        }
        for tier in Theme.Typo.all { _ = tier.font }
        for index in 0..<Theme.Chart.count {
            _ = Theme.Chart.color(at: index)
            _ = Theme.Chart.pair(at: index).color
        }
        _ = Theme.Palette.Surface.ground
        _ = Theme.Palette.Surface.well
        _ = Theme.Palette.Surface.control
        _ = Theme.Palette.Surface.ink
        for role in IconRole.allCases { _ = role.font }
    }

    /// 靶子 1：动态色包装对象。1000 次访问 = 0 次新构造（阈值 ≤1，容 lazy 落进窗口）。
    func test_dynamicColorHitsCacheOver1000Accesses() {
        warmUpAllTokens()
        let before = DesignTokenMeter.count(.dynamicColor)
        var consumed = 0
        for _ in 0..<1000 {
            // 读一次不产生构造；`String(reflecting:)` 是防止 -O 把整段循环折叠掉。
            consumed += String(reflecting: Theme.Semantic.danger.textColor).count
        }
        XCTAssertGreaterThan(consumed, 0)
        let built = DesignTokenMeter.count(.dynamicColor) - before
        XCTAssertLessThanOrEqual(built, 1,
                                 "同一枚语义色访问 1000 次新构造了 \(built) 个动态包装对象 —— 又回到每次访问现造")
        // 全站的缓存规模也必须是常数级：改前仅取色点每 tick 就 ~500 个。
        XCTAssertLessThanOrEqual(DesignTokenMeter.count(.dynamicColor), 64,
                                 "全 App 的动态色包装对象已超过 64 枚，说明有令牌没进缓存")
    }

    /// 靶子 1 的遍历口径：模拟"一个 tick 里把所有语义色各取一遍"，命中必须是 100%。
    func test_fullTokenSweepOver100RoundsBuildsNothing() {
        warmUpAllTokens()
        let beforeColor = DesignTokenMeter.count(.dynamicColor)
        let beforeSRGB = DesignTokenMeter.count(.sRGBColor)
        let beforeFont = DesignTokenMeter.count(.font)
        for round in 0..<100 {
            for role in Theme.Semantic.all {
                _ = String(reflecting: role.textColor).count
                _ = String(reflecting: role.graphicColor).count
                _ = String(reflecting: role.badgeFill(in: round % 2 == 0 ? .light : .dark)).count
            }
            for tier in Theme.Typo.all { _ = String(reflecting: tier.font).count }
            for index in 0..<Theme.Chart.count { _ = String(reflecting: Theme.Chart.color(at: index)).count }
            _ = String(reflecting: Theme.Chart.areaGradient(at: round % Theme.Chart.count,
                                                            intensity: .soft)).count
        }
        XCTAssertEqual(DesignTokenMeter.count(.dynamicColor) - beforeColor, 0, "100 轮遍历里又造了动态色包装器")
        XCTAssertEqual(DesignTokenMeter.count(.sRGBColor) - beforeSRGB, 0, "100 轮遍历里又造了分量色")
        XCTAssertEqual(DesignTokenMeter.count(.font) - beforeFont, 0, "100 轮遍历里又造了 Font")
    }

    /// 靶子 2：`TypeToken.font`。183 处 `.font(` 共用这 13 枚缓存。
    func test_typeTokenFontHitsCacheOver1000Accesses() {
        warmUpAllTokens()
        let before = DesignTokenMeter.count(.font)
        var consumed = ""
        for _ in 0..<1000 { consumed += String(reflecting: Theme.Typo.metricNumber.font) }
        XCTAssertFalse(consumed.isEmpty)
        let built = DesignTokenMeter.count(.font) - before
        XCTAssertLessThanOrEqual(built, 1,
                                 "访问 1000 次 metricNumber.font 新构造了 \(built) 个 Font —— 排版令牌又每次访问现造")
        // 图标那一侧同理：五档 `IconRole.font` 也只该有那五枚。
        let beforeIcons = DesignTokenMeter.count(.font)
        for _ in 0..<1000 { _ = String(reflecting: IconRole.badge.font).count }
        XCTAssertEqual(DesignTokenMeter.count(.font) - beforeIcons, 0, "IconRole.font 没吃到缓存")
    }

    /// 靶子 3：`areaGradient`。改前每次调用现造，Mark 逐点调用 = 每 tick 上百个。
    func test_areaGradientHitsCacheOver1000Lookups() {
        _ = Theme.Chart.areaGradient(at: 0)          // lazy 建表
        let builtForTable = DesignTokenMeter.count(.gradient)
        let expected = Theme.Chart.count * Theme.Chart.Intensity.allCases.count
        XCTAssertEqual(builtForTable, expected,
                       "渐变表构造了 \(builtForTable) 个对象，与「号位 × 强度档 = \(expected)」不符 —— 要么表没生效，要么有出口在现造")
        var consumed = 0
        for round in 0..<1000 {
            let gradient = Theme.Chart.areaGradient(at: round % Theme.Chart.count,
                                                    intensity: round % 2 == 0 ? .specTop : .soft)
            consumed += String(reflecting: gradient).count
        }
        XCTAssertGreaterThan(consumed, 0)
        XCTAssertEqual(DesignTokenMeter.count(.gradient) - builtForTable, 0,
                       "1000 次查表期间又构造了渐变 —— areaGradient 没在查表")
    }

    // MARK: - ② 次指标：形状守卫（Design 计算属性体内构造式 == 0）

    func test_designLayerNeverConstructsTokensPerAccess() throws {
        let files = try designFiles()
        let bodies = Self.computedBodies(in: files)

        // 分母三件套：真读到文件、真解析出计算属性、真扫到内容。
        // 空扫描器得零分也算绿，是本仓已知假绿模式。
        XCTAssertGreaterThanOrEqual(files.count, 10, "Design/ 只扫到 \(files.count) 个文件")
        XCTAssertGreaterThanOrEqual(bodies.count, 40,
                                   "只解析出 \(bodies.count) 个计算属性体，解析口径可疑（地板见注释）")
        let scannedLines = files.reduce(0) { $0 + $1.content.split(separator: "\n").count }
        XCTAssertGreaterThan(scannedLines, 1500, "只读到 \(scannedLines) 行，路径口径可疑")

        // 反向自证：这些名字必须仍以"计算属性"形态被解析到，说明解析器真在认体。
        let names = Set(bodies.map(\.name))
        for canary in ["textColor", "graphicColor", "onFillColor", "topOpacity",
                       "shadowColor", "referenceSurface", "isLiquid", "body"] {
            XCTAssertTrue(names.contains(canary),
                          "解析器没认到计算属性「\(canary)」—— 它可能已退化成空扫描器，上面那条 0 容忍就是假的")
        }

        let hits = Self.perAccessConstructorHits(in: files)
        XCTAssertTrue(hits.isEmpty,
                      "Design 层的计算属性体内出现了「每次访问现造」的写法（C 包靶子复发）：\n" + hits.joined(separator: "\n"))
    }

    /// 靶子 1 的复发检测：`color` 这个名字在 `Design/**` 里不得再是计算属性。
    /// （`IconRole.font` 仍**是**计算属性，只是它的体只 return 缓存，所以名字检查只收 `color`；
    /// `font` 由上面那条 `Font.system(` 的构造点判据守。）
    func test_colorTokenPropertyIsStoredNotComputed() throws {
        let bodies = Self.computedBodies(in: try designFiles())
        let recomputed = bodies.filter { $0.name == "color" }
        XCTAssertTrue(recomputed.isEmpty,
                      "`color` 又变回计算属性了，每次访问都会 new 动态色包装器：\(recomputed.map { "\($0.path):\($0.line)" })")
    }

    /// 靶子 3 的复发检测：`areaGradient` 出口必须**查表**，不得自己 `LinearGradient(...)`。
    /// 它改前是 `static func`，所以只扫计算属性的那条形状守卫抓不到它 —— 这条补上。
    func test_areaGradientAccessorReadsTheTableInsteadOfBuilding() throws {
        let file = try XCTUnwrap(try designFiles().first { $0.path.hasSuffix("ChartTokens.swift") },
                                 "扫不到 Design/ChartTokens.swift")
        let body = try XCTUnwrap(Self.block(containing: "static func areaGradient", in: file.content),
                                 "找不到 areaGradient 的函数体，出口被改名或删除了")
        XCTAssertFalse(body.contains("LinearGradient("),
                       "areaGradient 又在现造 LinearGradient —— 它被图表 Mark 逐点调用，就是每 tick 上百个对象")
        XCTAssertTrue(body.contains("areaGradientTable"),
                      "areaGradient 没有走 (强度档, 号位) 缓存表")
        let maker = try XCTUnwrap(Self.block(containing: "static func makeAreaGradient", in: file.content),
                                  "构造点 makeAreaGradient 不见了：表拿什么预计算？")
        XCTAssertTrue(maker.contains("LinearGradient("),
                      "构造点里已没有 LinearGradient —— 全表是空的，缓存就是假的")
    }

    /// 靶子 2 的复发检测：`TypeToken.font` 必须与档位一起在 init 里算一次。
    func test_typeTokenFontIsBuiltInInitAndCachedPerTier() throws {
        let file = try XCTUnwrap(try designFiles().first { $0.path.hasSuffix("ThemeTokens.swift") })
        XCTAssertTrue(file.content.contains("let font: Font"),
                      "TypeToken.font 不再是存储属性（改回计算属性 = 183 处 `.font(` 每次访问重造 Font）")
        let initBlock = try XCTUnwrap(Self.block(containing: "init(name: String, size: CGFloat", in: file.content))
        XCTAssertTrue(initBlock.contains("self.font ="),
                      "TypeToken.init 里没有构造 font，那 `let font: Font` 从哪来？")
        XCTAssertTrue(initBlock.contains("monospacedDigits ?"),
                      "init 里必须保留「数值档开等宽数字」这条判断，缓存不能把它弄丢")
    }

    // MARK: - ③ 行为守卫：缓存之后深色仍然解析出深色（本机探针实测可行，见文件头）

    /// 把 `Color` 在指定外观下解析成 6 位十六进制。解析不出来就返回空串——
    /// 空串会让下面的断言**变红**而不是被跳过，这是刻意的：永真绿比红更贵。
    static func resolveHex(_ color: Color, under name: NSAppearance.Name) -> String {
        guard let appearance = NSAppearance(named: name) else { return "" }
        var hex = ""
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return }
            let byte: (CGFloat) -> Int = { Int(($0 * 255).rounded()) }
            hex = String(format: "%02X%02X%02X", byte(rgb.redComponent), byte(rgb.greenComponent), byte(rgb.blueComponent))
        }
        return hex
    }

    /// 双层令牌在两套外观下各自解析出**自己那一套**值。
    /// 这就是"缓存的是包装对象、不是 RGB"的直接证据；写反了（缓存解析结果）这条必红。
    func test_cachedColorsStillResolveToTheirOwnAppearance() {
        // Surface.ink：浅 #0A0A0A / 深 #F2F2F5（无界 spec §2.1 的两个新地面令牌）
        XCTAssertEqual(Self.resolveHex(Theme.Palette.Surface.ink, under: .aqua), "0A0A0A")
        XCTAssertEqual(Self.resolveHex(Theme.Palette.Surface.ink, under: .darkAqua), "F2F2F5")
        // 语义色文字层（双层色的存在理由就是浅深各自达标）
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.danger.textColor, under: .aqua), "C2251C")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.danger.textColor, under: .darkAqua), "FF6B63")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.success.textColor, under: .aqua), "157A32")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.success.textColor, under: .darkAqua), "5BE28A")
        // critical 是唯一 onFill 随外观翻转的角色
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.critical.onFillColor, under: .aqua), "FFFFFF")
        XCTAssertEqual(Self.resolveHex(Theme.Semantic.critical.onFillColor, under: .darkAqua), "111111")
        // 图表色板按号位取色
        XCTAssertEqual(Self.resolveHex(Theme.Chart.color(at: 0), under: .aqua), "0A82FF")
        XCTAssertEqual(Self.resolveHex(Theme.Chart.color(at: 0), under: .darkAqua), "0A84FF")
        // 越界回绕后仍是同一枚动态色
        XCTAssertEqual(Self.resolveHex(Theme.Chart.color(at: 8), under: .darkAqua), "0A84FF")
    }

    /// 上面那条的**对照组**（行为守卫自己的元测试）：
    /// 刻意钉死成固定 RGB 的颜色，两套外观必须解析成同一个值。
    /// 若本机 `performAsCurrentDrawingAppearance` 对动态色根本不生效，那么"深浅不同"这条会红，
    /// 而不是悄悄变绿；若它对固定色也"深浅不同"，这条会红 —— 两把方向相反的锁。
    func test_resolutionHelperDistinguishesDynamicFromPinnedColors() {
        let pinned = Color(.sRGB, red: 10.0 / 255.0, green: 10.0 / 255.0, blue: 10.0 / 255.0, opacity: 1)
        let light = Self.resolveHex(pinned, under: .aqua)
        let dark = Self.resolveHex(pinned, under: .darkAqua)
        XCTAssertEqual(light, "0A0A0A", "解析器连固定色都读不出来：环境不支持，别信上面的行为守卫")
        XCTAssertEqual(light, dark, "固定色在两套外观下解析出了不同值 —— 解析器不可信")
        XCTAssertNotEqual(Self.resolveHex(Theme.Palette.Surface.ink, under: .aqua),
                          Self.resolveHex(Theme.Palette.Surface.ink, under: .darkAqua),
                          "动态色在两套外观下解析成了同一个值 = 深色模式已被钉死")
    }

    /// 缓存生效的直接证据：同一个角色的两次取色必须是**同一个包装对象**。
    /// 探针结论：两个独立 `NSColor(name: nil){}` 实例包出来的 `Color` **不**相等，
    /// 同一个实例包出来的才相等 —— 所以这条断言改前必红、改后必绿。
    func test_repeatedTokenAccessHandsBackTheSameColorWrapper() {
        XCTAssertEqual(Theme.Semantic.success.textColor, Theme.Semantic.success.textColor,
                       "两次取色不相等 = 每次访问又在现造动态色包装器")
        XCTAssertEqual(Theme.Semantic.danger.graphicColor, Theme.Semantic.danger.graphicColor,
                       "两次取色不相等 = 每次访问又在现造动态色包装器")
        XCTAssertEqual(Theme.Chart.color(at: 2), Theme.Chart.color(at: 2),
                       "图表号位色每次访问又 new 了一个包装器")
        XCTAssertEqual(Theme.Palette.Surface.ground, Theme.Palette.Surface.ground)
    }

    /// 渐变缓存里装的 stop 色**仍然是动态**的（不是被解析后钉死的 RGB）。
    /// 这条正面回击本次改造最容易犯的错：把动态色 resolve 成固定值再缓存。
    func test_areaGradientStopsAreStillAppearanceResolvingNotBaked() {
        let reflected = String(reflecting: Theme.Chart.areaGradient(at: 0))
        XCTAssertTrue(reflected.contains("AppKitPlatformColorProvider"),
                      "渐变 stop 上的色已被解析成固定 RGB 并缓存 —— 深色模式会被钉死：\(reflected.prefix(200))")
        // 对照组：固定 RGB 造的渐变不得含这个标记，否则上面那条就是永真绿
        let baked = LinearGradient(stops: [
            .init(color: Color(.sRGB, red: 0.04, green: 0.04, blue: 0.04, opacity: 1), location: 0),
        ], startPoint: .top, endPoint: .bottom)
        XCTAssertFalse(String(reflecting: baked).contains("AppKitPlatformColorProvider"),
                       "对照组失灵：固定色也带 AppKitPlatformColorProvider，那条断言证明不了任何事")
    }

    // MARK: - ④ 调用形状一字未动（三家页面流原样消费）

    /// 编译期即成立的契约：这三类令牌的**名字、类型、参数标签**没变。
    /// 任何一处被改名或改形状，这个函数就编译不过 —— 比读 diff 可靠。
    /// 顺带核一遍缓存出来的 `Font` 与规范构造式**同值**（缓存不能把值顺手改掉）。
    func test_tokenCallShapesAreUnchangedForPageFlows() {
        let text: Color = Theme.Semantic.accent.textColor
        let graphic: Color = Theme.Semantic.accent.graphicColor
        let onFill: Color = Theme.Semantic.accent.onFillColor
        let badge: Color = Theme.Semantic.warning.badgeFill()
        let badgeDark: Color = Theme.Semantic.warning.badgeFill(in: .dark)
        let font: Font = Theme.Typo.metricNumber.font
        let iconFont: Font = IconRole.cardHeader.font
        let seriesColor: Color = Theme.Chart.color(at: 3)
        let labelColor: Color = Theme.Chart.color(forLabel: "Swift")
        let pairColor: Color = Theme.Chart.pair(at: 3).color
        let tokenColor: Color = Theme.Chart.token(forLabel: "Swift").color
        let dualColor: Color = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F2F5).color
        let gradient: LinearGradient = Theme.Chart.areaGradient(at: 2, intensity: .soft)
        let gradientDefault: LinearGradient = Theme.Chart.areaGradient(at: 2)
        // 令牌仍可被页面按同样的标签构造（新增档位不需要改 Design）
        let tier = Theme.TypeToken(name: "probe", size: 12, weight: .regular, design: .default,
                                   monospacedDigits: false, lineSpacing: 2)
        let tierWithTracking = Theme.TypeToken(name: "probeTracking", size: 12, weight: .medium,
                                               design: .default, monospacedDigits: true,
                                               lineSpacing: 2, tracking: 0.6)

        for value in [text, graphic, onFill, badge, badgeDark, seriesColor, labelColor,
                      pairColor, tokenColor, dualColor] {
            XCTAssertEqual(Self.resolveHex(value, under: .aqua).count, 6, "有令牌解析不出值")
        }
        // 缓存出来的 Font 必须仍等于规范里的构造式（探针实测：同构建的 `Font` 可判等）。
        XCTAssertEqual(font, Font.system(size: 34, weight: .semibold, design: .default).monospacedDigit(),
                       "metricNumber 的缓存 Font 与规范构造式不同值，缓存改变了排版")
        XCTAssertEqual(Theme.Typo.monoSmall.font,
                       Font.system(size: 10, weight: .regular, design: .monospaced).monospacedDigit(),
                       "monoSmall 的缓存 Font 与规范构造式不同值")
        XCTAssertEqual(Theme.Typo.groupLabel.font,
                       Font.system(size: 10, weight: .medium, design: .default),
                       "groupLabel 的缓存 Font 与规范构造式不同值（这一档不开等宽数字）")
        XCTAssertEqual(iconFont, Font.system(.headline, weight: nil),
                       "IconRole.cardHeader 的缓存 Font 与规范构造式不同值")
        XCTAssertEqual(tier.font, Theme.Typo.narrative.font, "同为 12pt regular 的两档应同值")
        XCTAssertEqual(tierWithTracking.tracking, 0.6, accuracy: 0.0001)
        XCTAssertEqual(tierWithTracking.font, tier.font.monospacedDigit(),
                       "monospacedDigits 这条判断在缓存后仍要生效")
        _ = gradient
        _ = gradientDefault
    }

    /// badge 底色改成缓存后仍与"图形色 × `Opacity.badgeFill`"同一口径（红线：渐变/底色
    /// 强度档必须对齐 `Theme.Palette.Opacity.*`）。这里用外观维度逐档核。
    func test_badgeFillStillMatchesItsOpacityTierInBothAppearances() {
        for role in Theme.Semantic.measurable {
            for appearance: DesignAppearance in [.light, .dark] {
                let expected = role.graphic.token(in: appearance).sRGBHex
                let fill = Self.resolveHex(role.badgeFill(in: appearance), under: appearance == .light ? .aqua : .darkAqua)
                XCTAssertEqual(fill, expected,
                               "「\(role.name)」的 \(appearance) badge 底色不再等于该外观的图形色（透明度是叠在 alpha 上，不改 RGB）")
            }
        }
        XCTAssertEqual(Theme.Palette.Opacity.badgeFill, 0.15, accuracy: 0.0001)
    }

    // MARK: - ⑤ 元测试：三把尺子都不是假绿

    /// **计数尺子自己的元测试**（最重要的一条）：如果 `DesignTokenMeter` 数不到
    /// "每次访问现造"，上面那三条"命中数 ≤1"就是永真绿。
    /// 这里不造假货 —— 直接按定义构造 1000 个**新**令牌对象（新对象 = 新包装，
    /// 那是缓存的本意），要求计数器精确报出 1000。数不出来就是尺子坏了。
    func test_meterCountsConstructionsSoHitRateIsNotVacuous() {
        let beforeColor = DesignTokenMeter.count(.dynamicColor)
        for index in 0..<1000 {
            _ = DualColor(lightHex: 0x0A0A0A, darkHex: 0xF2F200 + UInt32(index % 250)).color
        }
        XCTAssertEqual(DesignTokenMeter.count(.dynamicColor) - beforeColor, 1000,
                       "构造 1000 枚新令牌，计数器没数到 1000 —— 计数通道是死的，命中数守卫全是假的")

        let beforeFont = DesignTokenMeter.count(.font)
        for index in 0..<1000 {
            _ = Theme.TypeToken(name: "probe\(index)", size: CGFloat(10 + index % 20), weight: .regular,
                                design: .default, monospacedDigits: index % 2 == 0, lineSpacing: 2).font
        }
        XCTAssertEqual(DesignTokenMeter.count(.font) - beforeFont, 1000,
                       "构造 1000 档新 Font，计数器没数到 —— Font 那条命中数断言是假的")

        // 渐变通道：能数到"表的规模"就说明它确实在数构造（见 ① 里那条 == 号位×档数 的断言）。
        XCTAssertGreaterThan(DesignTokenMeter.count(.gradient), 0, "渐变计数通道是死的")
        XCTAssertGreaterThan(DesignTokenMeter.count(.sRGBColor), 0, "分量色计数通道是死的")
    }

    /// 坏样例用的是**改造前的原样代码**（不是编出来的形状），扫描器必须逐段判红。
    func test_scannersCatchThePreChangeShapes() throws {
        // 靶子 1：改前 DualColor.color + dynamicNSColor（原样抄自 git 前的 ColorToken.swift）
        let oldColor = """
        struct DualColor {
            var color: Color { Color(nsColor: dynamicNSColor) }

            private var dynamicNSColor: NSColor {
                NSColor(name: nil) { appearance in
                    let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    return (isDark ? dark : light).nsColor
                }
            }
        }
        """
        let colorHits = Self.perAccessConstructorHits(in: [("Design/Old.swift", oldColor)])
        XCTAssertTrue(colorHits.contains { $0.contains("Color(nsColor:") }, "没抓到包装 Color：\(colorHits)")
        XCTAssertTrue(colorHits.contains { $0.contains("NSColor(name:") }, "没抓到动态 NSColor：\(colorHits)")
        XCTAssertEqual(colorHits.count, 2, "命中数与坏样例不符（应为两枚：包装器 + 动态 NSColor）：\(colorHits)")

        // 靶子 2：改前 TypeToken.font
        let oldFont = """
        struct TypeToken {
            var font: Font {
                let base = Font.system(size: size, weight: weight, design: design)
                return monospacedDigits ? base.monospacedDigit() : base
            }
        }
        """
        let fontHits = Self.perAccessConstructorHits(in: [("Design/Old.swift", oldFont)])
        XCTAssertEqual(fontHits, ["Design/Old.swift:2:font → Font.system("], "没抓到每次访问重造 Font：\(fontHits)")

        // 靶子 1 的另一处：改前 ColorTokenPair.color（多行体里的 Color(nsColor: + NSColor(name:）
        let oldPair = """
        struct ColorTokenPair {
            var color: Color {
                Color(nsColor: NSColor(name: nil) { appearance in
                    return (isDark ? dark : light).nsColor
                })
            }
        }
        """
        XCTAssertEqual(Set(Self.perAccessConstructorHits(in: [("Design/Old.swift", oldPair)])),
                       Set(["Design/Old.swift:2:color → Color(nsColor:", "Design/Old.swift:2:color → NSColor(name:"]),
                       "多行计算属性体没扫全（花括号配平失效？）")

        // 靶子 3 是 `static func`，计算属性扫描器天生看不见 —— 所以 block(containing:) 必须看得见
        let oldGradient = """
        enum Chart {
            static func areaGradient(at index: Int, intensity: Intensity = .specTop) -> LinearGradient {
                let color = self.color(at: index)
                return LinearGradient(
                    stops: [.init(color: color.opacity(intensity.topOpacity), location: 0)],
                    startPoint: .top, endPoint: .bottom)
            }
        }
        """
        let oldBody = try? XCTUnwrap(Self.block(containing: "static func areaGradient", in: oldGradient))
        XCTAssertTrue(oldBody?.contains("LinearGradient(") == true, "block 提取没抓到旧渐变体")

        // 注释豁免：文档里必须能提到被禁写法（本文件与 ColorToken 的头注释就是这种提法）
        let commented = "// var color: Color { Color(nsColor: NSColor(name: nil) { _ in .black }) }\n"
        XCTAssertTrue(Self.perAccessConstructorHits(in: [("Design/Doc.swift", commented)]).isEmpty,
                      "注释被当成代码判红了 —— 守卫会拦住所有解释「为什么禁」的注释")
        // 反对照组：同一行注释后面跟着真代码时，代码仍要被抓到（不许过度剥）
        let codeAfterComment = "var color: Color { Color(nsColor: x) }  // 旧写法\n"
        XCTAssertEqual(Self.perAccessConstructorHits(in: [("Design/Mix.swift", codeAfterComment)]).count, 2,
                      "行尾注释把真代码一起剥掉了 → 守卫会假绿")

        // 误报控制：存储属性不得被认成计算属性
        let stored = """
        struct T {
            var color: Color
            var tracking: CGFloat = 0
            var sizes: [String: Int] = [:]
        }
        """
        XCTAssertTrue(Self.computedBodies(path: "Design/T.swift", content: stored).isEmpty,
                      "把存储属性认成了计算属性 → 真页面会被误判")
    }

    /// 元测试的另一半：分母必须 > 0。扫描器读不到东西时，所有"isEmpty 即通过"的断言
    /// 会集体假绿 —— 这是本仓已知死法，单独钉一条。
    func test_scannerDenominatorsAreNonZeroOnRealSource() throws {
        let files = try designFiles()
        let bodies = Self.computedBodies(in: files)
        XCTAssertGreaterThan(files.count, 0)
        XCTAssertGreaterThan(bodies.count, 0)
        XCTAssertTrue(bodies.contains { !$0.code.isEmpty }, "解析出的体全是空的 —— 花括号配平坏了")
        // 已知仍在计算属性里的构造点必须被解析到（例如 ThemedIcon 的 symbol 读字符串），
        // 同时确认扫描面覆盖到了这几个具体文件，而不是只读到某个大文件。
        let paths = Set(files.map(\.path))
        for name in ["ColorToken.swift", "ThemeTokens.swift", "ChartTokens.swift",
                     "Glass.swift", "DataTable.swift", "IconTokens.swift"] {
            XCTAssertTrue(paths.contains { $0.hasSuffix(name) }, "扫描面漏了 \(name)")
        }
    }
}
