import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 数据块走蓝、数字走纯墨：两条规则都要有牙
//
// 权威 = `docs/界面语言-对齐AiX.md` §3（一个蓝）+ 风格契约 4（最重的墨给最大的数）。
//
// 批次 P6 把占比条从纯墨改成基座的数据块蓝时，很容易一刀切错：
// `MetricTile` / `GroupMetricCell` 的 `tint:` 参数**同名**，但它是**数字的前景色**，
// 那里必须继续是纯墨 —— 把最大的数涂成蓝，等于把"最重的墨给最大的数"这条撤了。
// 所以这条守卫两头都查：条不许是墨，数字不许不是墨。

final class DataMarkColorGuardTests: XCTestCase {

    /// 占比条调用点里传纯墨的位置。
    /// 判据形状：`DataShareBarRow(` 或 `Theme.Share.Row(` 之后 8 行内出现
    /// `tint: Theme.Palette.Surface.ink` / `color: Theme.Palette.Surface.ink`。
    static func inkShareBars(in files: [(path: String, content: String)]) -> [String] {
        // 三类"直接画的数据块"都要盯：占比条组件、行内量条、时段条。
        // 只盯组件名会漏 —— 贡献者页的占比条与时段条原本各自直接画，
        // 第一版守卫就只查到 `DataShareBarRow(`，那两处从守卫眼里过去了。
        let openers = ["DataShareBarRow(", "Theme.Share.Row(", "MiniBarGauge(", "ContributorHourRow("]
        let badTints = ["tint: Theme.Palette.Surface.ink", "color: Theme.Palette.Surface.ink"]
        return files.flatMap { file in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var hits: [String] = []
            for (index, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                guard openers.contains(where: line.contains) else { continue }
                let window = lines[(min(index + 1, lines.count))..<min(index + 9, lines.count)]
                if window.contains(where: { tint in badTints.contains(where: tint.contains) }) {
                    hits.append("\(file.path):\(index + 1)")
                }
            }
            return hits
        }
    }

    func test_shareBarsDoNotDrawInInk() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let hits = Self.inkShareBars(in: views)
        XCTAssertTrue(hits.isEmpty,
                      "这些占比条还在传纯墨，与曲线/柱的数据块取色分家：\(hits)。"
                    + "请走 `ChartSeries.dataMarkColor`。")
        // 反向自证：判据必须真的看得到合法写法，否则"零命中"可能只是没扫到。
        XCTAssertTrue(views.contains { $0.content.contains("tint: ChartSeries.dataMarkColor") },
                      "全仓没有一处 `dataMarkColor` —— 上面那条断言成了永真绿")
    }

    /// 头像圈是**身份装饰**（结构），不是数据块：它必须继续走纯墨，
    /// 否则"给数据块上蓝"会顺手把每个作者的名字前涂成一排蓝圈。
    func test_identityAvatarsStayInk() throws {
        let rows = try SurfaceScanKit.sourceFiles(under: "Views/Git")
            .first { $0.path.hasSuffix("ContributorRows.swift") }
        let body = rows?.content ?? ""
        XCTAssertTrue(body.contains("ContributorAvatar(author: author, tint: tint"),
                      "头像被并进了数据块取色 —— 它不是数据。一个变量服务两个语义时先拆开，别一刀切。")
        XCTAssertTrue(body.contains("tint: dataTint"),
                      "贡献者页的占比条/时段条不再走 dataMarkColor，数据块取色又分家了")
    }

    /// 数字前景必须仍是纯墨（`tint:` 同名参数，语义完全不同）。
    func test_metricNumbersStayInInk() throws {
        let tiles = try SurfaceScanKit.sourceFiles(under: "Views/Performance")
            .first { $0.path.hasSuffix("PerformanceSystemTiles.swift") }
        XCTAssertNotNil(tiles, "找不到性能读数磁贴文件，判据在空转")
        XCTAssertTrue((tiles?.content ?? "").contains("tint: Theme.Palette.Surface.ink"),
                      "内存磁贴的数字被涂成蓝了 —— 「最重的墨给最大的数」这条被撤。"
                    + "数据块蓝只给条/柱/线，不给数字。")
    }

    /// 两向元测试。
    func test_shareBarRulerCatchesSyntheticAndSparesNumbers() {        let dirty = [(path: "Views/Code/Fake.swift", content: """
        DataShareBarRow(
            label: name,
            fraction: 0.4,
            tint: Theme.Palette.Surface.ink
        )
        """)]
        XCTAssertEqual(Self.inkShareBars(in: dirty).count, 1, "占比条传墨没抓到 → 守卫是摆设")

        let legalBar = [(path: "Views/Git/Fake.swift", content: """
        DataShareBarRow(
            label: name,
            fraction: 0.4,
            tint: ChartSeries.dataMarkColor
        )
        """)]
        XCTAssertTrue(Self.inkShareBars(in: legalBar).isEmpty, "合法写法被误伤")

        let numberTile = [(path: "Views/Performance/Fake.swift", content: """
        MetricTile(
            label: "内存",
            value: used,
            tint: Theme.Palette.Surface.ink
        )
        """)]
        XCTAssertTrue(Self.inkShareBars(in: numberTile).isEmpty,
                      "数字的 tint 不是占比条 —— 一刀切会把「最重的墨给最大的数」改掉")

        let commented = [(path: "Views/Code/Fake.swift", content: """
        // 原来是 tint: Theme.Palette.Surface.ink
        DataShareBarRow(
            label: name,
            fraction: 0.4,
            tint: ChartSeries.dataMarkColor
        )
        """)]
        XCTAssertTrue(Self.inkShareBars(in: commented).isEmpty,
                      "注释里交代旧写法就被判红 → 一年后没人记得它为什么错")
    }

    // MARK: - 默认参数是"扫调用点"的盲区（批次 P6-Q：总览页黑条）

    /// `inkShareBars` 只盯**调用点**上写出来的 `tint:`，而 `Theme.Share.Row` 的结构占比
    /// 初始化器根本不要求调用方传色 —— 于是默认值偷偷涂墨时，总览页长出一根 1300pt 的
    /// 实心黑条而守卫全绿（2026-09-21 页尾实拍抓到；同页同一份语言数据在代码规模页是蓝的）。
    /// 判据抽成纯函数 —— 直接对字面量写断言是"自证"，不是元测试。
    /// 空内容按"判据不成立"处理：文件被改名/搬走时这条必须红，不能变成永真绿。
    struct ShareRowDefaultVerdict: Equatable { let blue: Bool; let stillInked: Bool }

    static func shareRowDefault(_ readoutKitSource: String) -> ShareRowDefaultVerdict {
        guard !readoutKitSource.isEmpty else { return .init(blue: false, stillInked: false) }
        return .init(blue: readoutKitSource.contains("color: ChartSeries.dataMarkColor"),
                     stillInked: readoutKitSource.contains("color: Theme.Palette.Surface.ink"))
    }

    func test_shareRowDefaultsDrawDataMarksInBlue() throws {
        let kit = try SurfaceScanKit.sourceFiles(under: "Design")
            .first { $0.path.hasSuffix("ReadoutKit.swift") }?.content ?? ""
        let verdict = Self.shareRowDefault(kit)
        XCTAssertTrue(verdict.blue,
                      "`Theme.Share.Row` 的结构占比默认不再走数据块蓝：不显式传色的页面会长出黑条")
        XCTAssertFalse(verdict.stillInked,
                       "`Theme.Share.Row` 的默认还留着一份纯墨 —— 最重的墨是给最大的数用的，不给条用")
    }

    /// 两向元测试：退回墨色要红，文件读不到也要红（不许把"没扫到"读成"没问题"）。
    func test_shareRowDefaultRulerSeesBothWays() {
        let inked = "init(label: String) { self.init(color: Theme.Palette.Surface.ink) }"
        XCTAssertEqual(Self.shareRowDefault(inked), .init(blue: false, stillInked: true),
                       "判据看不见退回墨色的默认值")
        let blue = "init(label: String) { self.init(color: ChartSeries.dataMarkColor) }"
        XCTAssertEqual(Self.shareRowDefault(blue), .init(blue: true, stillInked: false), "合法写法被误伤")
        XCTAssertEqual(Self.shareRowDefault(""), .init(blue: false, stillInked: false),
                       "文件读不到时这条会成永真绿")
    }

    // MARK: - 零不是动作（批次 P6-Q：提交行那枚红 0）

    /// `NumberFormat.signed(...)` 后面 3 行内**无条件**挂上语义色 = 0 也吃色。
    /// 0 行新增/删除是"没做这件事"，涂绿/涂红会把它说成"做了、量是 0"。
    static func zeroWearsSemanticColor(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var hits: [String] = []
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                guard line.contains("NumberFormat.signed(") else { continue }
                let window = lines[index..<min(index + 4, lines.count)]
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                guard window.contains(where: { $0.contains(".foregroundStyle(Theme.Semantic.") }) else { continue }
                if window.contains(where: { $0.contains("== 0 ?") || $0.contains("!= 0 ?") }) { continue }
                hits.append("\(file.path):\(index + 1)")
            }
            return hits
        }
    }

    func test_zeroChurnDoesNotWearSemanticColor() throws {
        let git = try SurfaceScanKit.sourceFiles(under: "Views/Git")
        XCTAssertTrue(Self.zeroWearsSemanticColor(in: git).isEmpty,
                      "这些带正负号的读数在 0 时也涂着语义色（零不是动作）")
    }

    func test_zeroColorRulerCatchesSyntheticAndSparesGuarded() {
        let dirty = [(path: "Views/Git/Fake.swift", content: """
        Text(NumberFormat.signed(-commit.deletions))
            .font(CodeGitType.number(Theme.Typo.monoSmall))
            .foregroundStyle(Theme.Semantic.danger.textColor)
        """)]
        XCTAssertEqual(Self.zeroWearsSemanticColor(in: dirty).count, 1, "红 0 没抓到 → 守卫是摆设")

        let guarded = [(path: "Views/Git/Fake.swift", content: """
        Text(NumberFormat.signed(-commit.deletions))
            .foregroundStyle(commit.deletions == 0 ? Self.quietNumber : Theme.Semantic.danger.textColor)
        """)]
        XCTAssertTrue(Self.zeroWearsSemanticColor(in: guarded).isEmpty, "已经判 0 的合法写法被误伤")

        let commented = [(path: "Views/Git/Fake.swift", content: """
        // 原来是 .foregroundStyle(Theme.Semantic.danger.textColor)，0 也涂红
        Text(NumberFormat.signed(-commit.deletions))
            .foregroundStyle(commit.deletions == 0 ? Self.quietNumber : Theme.Semantic.danger.textColor)
        """)]
        XCTAssertTrue(Self.zeroWearsSemanticColor(in: commented).isEmpty, "注释里交代旧写法就被判红")
    }

    // MARK: - 一根条只许编码一个量（批次 P6-Q：页尾实拍暴露）

    /// 判据形状：`MiniBarGauge(` 起 5 行内（**跳过注释行**）取 `fraction:` 表达式，
    /// 再看同一窗口里颜色是不是从**另一个量**的判档来的。
    /// 颜色来源有两种写法都要盯：字面量 `role(for: X)` / `ratioRole(X)`，
    /// 以及上一行 `let role = …role(forScore: X)` 再 `tint: role.graphicColor` 的间接写法
    /// ——只盯前者会漏掉健康分表那种合法同源写法，只盯后者会漏掉直接写法。
    static func mixedSourceGauges(in files: [(path: String, content: String)]) -> [String] {
        var hits: [String] = []
        for file in files {
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            for (index, raw) in lines.enumerated() {
                if raw.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                guard raw.contains("MiniBarGauge(") else { continue }
                let window = lines[(index)..<min(index + 5, lines.count)]
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: " ")
                guard let fraction = capture(window, pattern: "fraction:\\s*([^,)]+)") else { continue }
                for source in bandSources(window: window, lines: lines, at: index)
                where !fraction.contains(source) {
                    hits.append("\(file.path):\(index + 1) 柱长是 \(fraction)，颜色却取 \(source) 的判档")
                }
            }
        }
        return hits
    }

    private static let bandPattern =
        "(?:role\\(for:|role\\(forScore:|ratioRole\\()\\s*([A-Za-z0-9_.]+)"

    private static func capture(_ text: String, pattern: String) -> String? {
        let re = try? NSRegularExpression(pattern: pattern)
        guard let re else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = re.firstMatch(in: text, options: [], range: range),
              let inner = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[inner]).trimmingCharacters(in: .whitespaces)
    }

    private static func bandSources(window: String, lines: [String], at index: Int) -> [String] {
        guard let re = try? NSRegularExpression(pattern: bandPattern) else { return [] }
        let range = NSRange(window.startIndex..., in: window)
        var out = re.matches(in: window, options: [], range: range).compactMap { match -> String? in
            guard let inner = Range(match.range(at: 1), in: window) else { return nil }
            return String(window[inner])
        }
        guard out.isEmpty, let tintVar = capture(window, pattern: "tint:\\s*([A-Za-z0-9_]+)\\.graphicColor")
        else { return out }
        // 间接写法：往回找定义这个 tint 变量的那一行，量条同源与否要看它到底由谁算出来。
        for raw in lines[max(0, index - 12)..<index].reversed() where raw.contains("let \(tintVar)") {
            if let source = capture(raw, pattern: bandPattern) { out.append(source) }
            break
        }
        return out
    }

    func test_gaugesEncodeOnlyOneQuantity() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let hits = Self.mixedSourceGauges(in: views)
        XCTAssertTrue(hits.isEmpty,
                      "这些量条一个字形说两件事（长度=一个量、颜色=另一个量的判档色）：\n"
                        + hits.joined(separator: "\n"))
        var openers = 0
        for file in views {
            openers += file.content.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") && $0.contains("MiniBarGauge(")
            }.count
        }
        XCTAssertGreaterThan(openers, 0, "Views 下一个 MiniBarGauge 都没扫到 → 上面那条断言是永真绿")
    }

    /// 两向元测试：坏写法必须抓到，两种合法写法（数据块蓝、同源判档）不许误伤。
    func test_mixedSourceGaugeRulerCatchesSyntheticAndSparesLegal() {
        let dirty = [(path: "Views/Code/Fake.swift", content: """
        MiniBarGauge(fraction: Double(hotspot.lineCount) / Double(largest),
                     tint: Theme.Semantic.role(for: hotspot.risk).graphicColor,
                     height: DataGaugeHeight.inline)
        """)]
        XCTAssertEqual(Self.mixedSourceGauges(in: dirty).count, 1, "长度与颜色不同源没抓到 → 守卫是摆设")

        let indirectDirty = [(path: "Views/Code/Fake2.swift", content: """
        let role = Theme.Semantic.role(for: code.overallRisk)
        MiniBarGauge(fraction: code.duplicationRatio,
                     tint: role.graphicColor,
                     height: DataGaugeHeight.metric)
        """)]
        XCTAssertEqual(Self.mixedSourceGauges(in: indirectDirty).count, 1, "间接写法漏掉了")

        let sameSource = [(path: "Views/Health/Fake3.swift", content: """
        let role = Theme.Semantic.role(forScore: row.score)
        MiniBarGauge(fraction: Double(row.score) / 100,
                     tint: role.graphicColor,
                     height: Theme.Layout.gaugeInline)
        """)]
        XCTAssertTrue(Self.mixedSourceGauges(in: sameSource).isEmpty, "同源判档被误伤")

        let blueBar = [(path: "Views/Code/Fake4.swift", content: """
        // 原来涂 Theme.Semantic.role(for: hotspot.risk).graphicColor
        MiniBarGauge(fraction: fraction,
                     tint: ChartSeries.dataMarkColor,
                     height: DataGaugeHeight.inline)
        """)]
        XCTAssertTrue(Self.mixedSourceGauges(in: blueBar).isEmpty, "注释里交代旧写法就被判红")
    }
}
