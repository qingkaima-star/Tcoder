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
    static let packageRoot: URL = URL(fileURLWithPath: #filePath)
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

    func designFiles() throws -> [(path: String, content: String)] {
        try Self.sourceFiles(under: "Design")
    }

    // MARK: - ① 主指标：连续访问 1000 次，新构造的包装对象 ≤ 1

    /// 把全站令牌摸一遍，让所有 lazy `static let` 都完成初始化。
    /// 没有这一步，"命中数"窗口里会混进首次构造（那是缓存本来的样子，不是 bug）。
    func warmUpAllTokens() {
        for role in Theme.Semantic.all {
            _ = role.textColor
            _ = role.graphicColor
            _ = role.onFillColor
            _ = role.badgeFill(in: .light)
            _ = role.badgeFill(in: .dark)
            _ = role.adaptiveBadgeFill
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

    // MARK: - ② 次指标：形状守卫（Design 计算属性体内构造式 == 0）

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

    // MARK: - ④ 调用形状一字未动（三家页面流原样消费）

    // MARK: - ⑤ 元测试：三把尺子都不是假绿

}
