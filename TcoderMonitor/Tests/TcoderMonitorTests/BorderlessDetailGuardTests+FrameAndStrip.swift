import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 H5 的三条版面对齐守卫（自 BorderlessDetailGuardTests.swift 原样搬出）
//
// 搬的理由是机械的：本仓的 `X3TestSizeAuditTests` 用与产品「巨大文件」同一口径
// （`FileSystemCodeAnalyzer.mediumFileLines` = 400 行）钉着 Tests 目录，而这个文件是
// main 批次 H5 一次性长到 531 行的。判据、合成样例与数字一字未改，只换了住的地方。
extension BorderlessDetailGuardTests {

    // MARK: 批次 H5：版框宽度只有一个出口

    /// 页骨架**不接受** `maxWidth:`。三档时代（reading 1040 / overview 1200 / dense 1240）
    /// 切一次 tab 内容整体左右跳 100pt，实拍量到左边距三套、右边距五套 —— 用户判词
    /// 「不规整」在版面上指的就是这个。收口方式不是"提醒大家别传"，而是没有参数可传。
    static func pageWidthOverrides(in files: [(path: String, content: String)]) -> [String] {
        files.filter { $0.content.contains("Scaffold(maxWidth:") }.map(\.path)
    }

    func test_noPageChoosesItsOwnFrameWidth() throws {
        let offenders = Self.pageWidthOverrides(in: try SurfaceScanKit.sourceFiles(under: ""))
        XCTAssertTrue(offenders.isEmpty,
                      "又有页面给版框单开一档宽度，九页边距会再次分叉：\(offenders)")
        // 令牌侧同样只许一个出口，否则第二档只是"暂时没人用"，下一轮就有人用。
        // 扫整个 `Design/` 而不是钉 `ThemeTokens.swift` 这个文件名：`Theme.Layout`
        // 现在住在 `Design/ThemeMetrics.swift`（WS-X7 按自扫名册做的分片）。钉文件名的话
        // 它会读成 0 份，而 0 会被当成"没有第二档"通过 —— 方向正好相反，比多一份更坏。
        let tokens = try SurfaceScanKit.sourceFiles(under: "Design")
            .flatMap { SurfaceScanKit.codeLines($0.content) }
            .filter { $0.contains("static let maxWidth") }
        XCTAssertEqual(tokens.count, 1,
                       "版框宽度令牌有 \(tokens.count) 份：\(tokens)")
    }

    func test_pageWidthScannerDetectsInjectedOverride() {
        let injected = [(path: "Views/FakeView.swift",
                         content: "  Theme.Page.Scaffold(maxWidth: 900) {\n")]
        XCTAssertEqual(Self.pageWidthOverrides(in: injected), ["Views/FakeView.swift"])
        let clean = [(path: "Views/FakeView.swift", content: "  Theme.Page.Scaffold {\n")]
        XCTAssertTrue(Self.pageWidthOverrides(in: clean).isEmpty)
    }

    // MARK: 批次 H5：同一页的读数带格数一致

    /// 读数带的格数由 `DataBandSeparator()` 的条数决定（n 格 = n-1 条）。
    /// **同页两带格数不同 = 分隔线竖向错位**：上下两条带摆在一起，格与格对不上，
    /// 就是「对不齐」这一条在版面剩下的最后一点成因（依赖页原来是 4 格带 + 3 格带）。
    static func stripSlotCounts(_ content: String) -> [Int] {
        var counts: [Int] = []
        var open: Int?
        var depth = 0
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            let balance = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
            if open == nil {
                if trimmed.contains("ReadoutStrip") {
                    open = 0
                    depth = max(balance, 0)
                    if depth == 0 { counts.append(1); open = nil }
                }
                continue
            }
            if trimmed.contains("DataBandSeparator()") { open = open.map { $0 + 1 } }
            depth += balance
            if depth <= 0 {
                counts.append((open ?? 0) + 1)
                open = nil
            }
        }
        return counts
    }

    static func mismatchedStripCounts(in files: [(path: String, content: String)]) -> [String] {
        files.compactMap { file in
            let counts = Self.stripSlotCounts(file.content)
            guard counts.count > 1, Set(counts).count > 1 else { return nil }
            return "\(file.path): 读数带格数 \(counts)"
        }
    }

    func test_readoutStripsShareOneSlotCountPerPage() throws {
        let offenders = Self.mismatchedStripCounts(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "同一页里两条读数带格数不同，分隔线会竖向错位：\(offenders)")
    }

    func test_stripCountScannerDetectsMismatchAndIgnoresAgreement() {
        let mixed = [(path: "Views/FakeView.swift", content: """
        Theme.Page.Scaffold {
            ReadoutStrip {
                MetricTile(label: "a", value: "1")
                DataBandSeparator()
                MetricTile(label: "b", value: "2")
            }
            ReadoutStrip {
                MetricTile(label: "c", value: "3")
            }
        }
        """)]
        XCTAssertEqual(Self.stripSlotCounts(mixed[0].content), [2, 1],
                       "扫描器没数出两条带的格数")
        XCTAssertEqual(Self.mismatchedStripCounts(in: mixed), ["Views/FakeView.swift: 读数带格数 [2, 1]"])
        let even = [(path: "Views/FakeView.swift", content: """
        ReadoutStrip {
            MetricTile(label: "a", value: "1")
            DataBandSeparator()
            MetricTile(label: "b", value: "2")
        }
        ReadoutStrip {
            MetricTile(label: "c", value: "3")
            DataBandSeparator()
            MetricTile(label: "d", value: "4")
        }
        """)]
        XCTAssertTrue(Self.mismatchedStripCounts(in: even).isEmpty,
                      "两条带格数相同却被判错位")
    }

    // MARK: 批次 H5：同一句口径一屏只许一处

    /// 逐字符扫一行里的字符串字面量。不用正则是因为 `"` 的转义形态（`\"`、`\(`）
    /// 在正则里要写四层反斜杠，上一批就是被这个炸出 `unterminated string literal` 的。
    private static func stringLiterals(in line: String) -> [String] {
        let chars = Array(line)
        var out: [String] = []
        var i = 0
        while i < chars.count {
            guard chars[i] == "\"" else { i += 1; continue }
            var body = ""
            i += 1
            while i < chars.count {
                if chars[i] == "\\", i + 1 < chars.count {
                    body.append("\\"); body.append(chars[i + 1]); i += 2; continue
                }
                if chars[i] == "\"" { break }
                body.append(chars[i]); i += 1
            }
            i += 1
            out.append(body)
        }
        return out
    }

    /// 把 `\(...)` 插值整段摘掉、把 `\n` / `\"` 还原，得到"这句话本身的形状"。
    /// 不摘插值的话，同一个句式换个数字就不算重复了 —— 而重复的正是句式。
    private static func sentenceShape(_ body: String) -> String {
        let chars = Array(body)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 1 < chars.count {
                let next = chars[i + 1]
                if next == "(" {
                    var depth = 1
                    i += 2
                    while i < chars.count, depth > 0 {
                        if chars[i] == "(" { depth += 1 }
                        if chars[i] == ")" { depth -= 1 }
                        i += 1
                    }
                    continue
                }
                out.append(next == "n" || next == "t" ? " " : next)
                i += 2
                continue
            }
            out.append(chars[i]); i += 1
        }
        return out
    }

    /// 同一份页面文件里**逐字重复的长句**（摘掉插值后仍 ≥14 字、含汉字）。短标签重复是术语复用，
    /// 长句重复就是"一屏说五遍"—— 用户判词「太乱了」在密度这一维的落点。
    /// 收口方式是"每屏一处权威落点，其余引用它"，**不是删掉诚实性信息**（红线）。
    static func repeatedBasisSentences(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            var seen: [String: Int] = [:]
            for raw in file.content.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = String(raw)
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                for body in stringLiterals(in: line) {
                    let shape = sentenceShape(body)
                    let hasHan = shape.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
                    guard hasHan, shape.count >= 14 else { continue }
                    seen[shape, default: 0] += 1
                }
            }
            return seen.filter { $0.value >= 2 }
                .map { "\(file.path): 同一句长文案出现 \($0.value) 次 —— \($0.key)" }
                .sorted()
        }
    }

    func test_noVerbatimLongSentenceTwiceOnOnePage() throws {
        let offenders = Self.repeatedBasisSentences(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "同一页又出现逐字重复的口径长句，请留一处权威落点、其余改为引用："
                          + "\(offenders)")
    }

    func test_repetitionScannerFlagsDupAndIgnoresDistinctSentences() {
        let dup = [(path: "Views/FakeView.swift", content: """
            Text("离线未核对时不得把 0 画成安全")
            Text("离线未核对时不得把 0 画成安全")
            """)]
        XCTAssertEqual(Self.repeatedBasisSentences(in: dup).count, 1, "逐字重复没抓到")
        let digitsOnlyDiffer = [(path: "Views/FakeView.swift", content: """
            Text("窗口内非合并提交 \\(NumberFormat.grouped(a)) 次，作者占比的分母就是这个数")
            Text("窗口内非合并提交 \\(NumberFormat.grouped(b)) 次，作者占比的分母就是这个数")
            Text("另一句完全不同的口径说明文字，说的是联网核对的覆盖范围")
            """)]
        XCTAssertEqual(Self.repeatedBasisSentences(in: digitsOnlyDiffer).count, 1,
                       "只换数字的同句式重复没抓到（插值没摘干净）")
        let short = [(path: "Views/FakeView.swift", content: """
            Text("生态")
            Text("生态")
            """)]
        XCTAssertTrue(Self.repeatedBasisSentences(in: short).isEmpty, "术语复用被误判成口径重复")
    }

    /// `ChartAxisEdge.anchor` 的**垂直分量必须是 0**（标签挂在刻度线下方）。
    ///
    /// P18 修「尾刻度被卡片右边切成 `08:27…`」时，三档写成了 `.leading` / `.center` / `.trailing`——
    /// 这三个 `UnitPoint` 的 `y` 都是 **0.5**，语义是"拿标签的垂直中点对齐刻度线"，
    /// 于是半个标签掉进绘图区；x 轴刻度线就在绘图区底边，0 值那一档
    /// （错误趋势里警告数贴着 `y=0`）便**横穿过日期数字**。
    /// `fb94e88` 那批 36 张·错误日志页尾裁到原始像素确认：`9/21` 被虚线划过去。
    /// 水平那一半必须照旧（尾刻度往内长），所以两个分量分开钉。
    func test_timeAxisAnchorsHangBelowTheAxisLine() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let domain = start...start.addingTimeInterval(4 * 86_400)
        let cases: [(name: String, date: Date, x: CGFloat, y: CGFloat)] = [
            ("首刻度", start, 0, 0),
            ("中间刻度", start.addingTimeInterval(2 * 86_400), 0.5, 0),
            ("尾刻度", start.addingTimeInterval(4 * 86_400), 1, 0),
        ]
        for item in cases {
            let anchor = ChartAxisEdge.anchor(for: item.date, in: domain)
            XCTAssertEqual(anchor.y, item.y, accuracy: 0.001,
                           "\(item.name) 的垂直锚点不是 \(item.y) ⇒ 标签掉进绘图区，会被 0 值线横穿")
            XCTAssertEqual(anchor.x, item.x, accuracy: 0.001,
                           "\(item.name) 的水平锚点变了 ⇒ P18 那条「尾刻度不许被切字」的修复被弄坏")
        }
        // 读不到日期时的兜底档同样落在刻度线上，也不许垂直居中。
        XCTAssertEqual(ChartAxisEdge.anchor(for: nil, in: domain).y, 0,
                       "缺席刻度的兜底又写成垂直居中")
        // 正对照：老写法为什么错，要能被机器复现，不能只写在注释里。
        XCTAssertEqual(UnitPoint.center.y, 0.5, accuracy: 0.001,
                       "UnitPoint.center 的 y 不再是 0.5 ⇒ 上面这条判据的理由变了，要连判据一起重读")
    }

}
