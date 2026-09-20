import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - 「简约无界」风格契约守卫（批次 A / G / H / H5）
//
// 从 `BorderlessSurfaceGuardTests` 拆出来：那份写满 900 行撞上了自扫闸门
// （超 800 行的文件上限 0，阈值冻结，拆文件才是修复）。
// 尺子（`sourceFiles` / `codeLines` / `isCode`）不在这里重复实现，
// 两份守卫都走 `SurfaceScanKit`；`SurfaceScanKit` 自己的反向自证在
// `BorderlessSurfaceGuardTests.test_sourceScannerActuallyFindsFiles`。

final class BorderlessDetailGuardTests: XCTestCase {

    // MARK: - 第三轮·批次 A：绘图溢出与上屏字面量

    /// 画了 `AreaMark`（面积填充）却**没有裁绘图区**的位置。
    ///
    /// 为什么这一类必须由机器守着：Swift Charts 在 `chartYScale(domain:)` 被收窄之后，
    /// 落在域外的点仍按数据坐标换算，面积填充会画到绘图区**外面**，一路盖住下面的
    /// 脚注与下一个分组。它在源码审查里完全看不出来（没有任何"越界"字样），
    /// 只在真实数据触发收窄时才现形 —— 用户 23:05 的「太乱了」就是 CPU 掉到 20%
    /// 而轴收在 75…100 的那一片灰。
    static func unclippedAreaCharts(in files: [(path: String, content: String)]) -> [String] {
        files.compactMap { file in
            let code = SurfaceScanKit.codeLines(file.content)
            guard code.contains(where: { $0.contains("AreaMark(") }) else { return nil }
            guard !code.contains(where: { $0.contains("chartPlotStyle") && $0.contains("clipped") })
            else { return nil }
            let line = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .firstIndex(where: { SurfaceScanKit.isCode($0) && $0.contains("AreaMark(") })
            return "\(file.path):\(line.map { $0 + 1 } ?? 0)"
        }
    }

    /// 会**原样上屏**的 markdown 强调星号。`Text(String)` 是逐字初始化、不解析 markdown，
    /// 所以 `"**为看清走势而收窄的**"` 这种写法会把两颗星投到用户脸上。
    /// 要强调就用「」或字号/字重，不要往 UI 串里塞 markdown。
    static func markdownStarsInUIStrings(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content
                .split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    guard SurfaceScanKit.isCode(raw), raw.contains("\""), raw.contains("**") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_areaChartsClipTheirPlotArea() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let offenders = Self.unclippedAreaCharts(in: views)
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件画了 AreaMark 却没裁绘图区，轴一收窄就会盖住下面的区块：\(offenders)")
        XCTAssertGreaterThanOrEqual(views.filter { $0.content.contains("AreaMark(") }.count, 2,
                                    "分母必须 > 0：全仓至少两张面积图，扫到 0 张说明扫描器瞎了")
    }

    func test_noMarkdownStarsReachTheScreen() throws {
        let offenders = Self.markdownStarsInUIStrings(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty, "UI 串里出现 markdown 星号，会原样显示给用户：\(offenders)")
    }

    /// 批次 A 两条扫描器的元测试：注入坏样例必须红、注释与已修好的样例必须不报。
    /// 没有这一条，上面两条断言在扫描器失灵时会一起假绿。
    func test_batchA_scannersActuallyDetectInjectedViolations() {
        let dirtyArea = [(path: "Views/Fake.swift",
                          content: "Chart(p) { AreaMark(x: .value(\"t\", 1), y: .value(\"v\", 2)) }\n")]
        XCTAssertEqual(Self.unclippedAreaCharts(in: dirtyArea).count, 1, "面积图未裁剪的坏样例没抓到")
        let cleanArea = [(path: "Views/Fake.swift",
                          content: "Chart(p) { AreaMark(x: .value(\"t\", 1)) }\n"
                              + "    .chartPlotStyle { $0.clipped() }\n")]
        XCTAssertTrue(Self.unclippedAreaCharts(in: cleanArea).isEmpty, "已裁剪的样例被误报")

        let dirtyStars = [(path: "Views/Fake.swift",
                           content: "Text(\"带下限的轴是**收窄**的\")\n")]
        XCTAssertEqual(Self.markdownStarsInUIStrings(in: dirtyStars).count, 1, "上屏星号的坏样例没抓到")
        let starsInComment = [(path: "Views/Fake.swift",
                               content: "// 原来写的是 **星号强调**，会原样上屏\n")]
        XCTAssertTrue(Self.markdownStarsInUIStrings(in: starsInComment).isEmpty,
                      "扫描器把注释里的星号误判成违规")
    }

    /// 九页是否**每页都有一个页级 H1**。
    ///
    /// 上一版只有性能/日志/评分三页手写了标题行，另外六页直接从节标题起 ——
    /// 于是"页面层"有三种状态（有 H1 / 没有 H1 / 项目名的 20pt 冒充 H1），
    /// 而那三页又叠在项目名 20pt 之下，一屏两个同级大标题。
    /// 现在标题行收进 `Theme.Page.Header`，这条断言数的是**调用点**：
    /// 少一页就是那一页又偷偷没有 H1，多于一页要人工确认不是同一页写了两份。
    static func pageHeaderDeclarations(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    guard SurfaceScanKit.isCode(raw), raw.contains("Theme.Page.Header(") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_everyPageDeclaresExactlyOnePageHeader() throws {
        let hits = Self.pageHeaderDeclarations(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        let paths = Set(hits.map { String($0.prefix(while: { $0 != ":" })) })
        XCTAssertEqual(paths.count, 9,
                       "声明页级 H1 的页面数不是 9（九页各一处）：\(paths.sorted())")
        XCTAssertEqual(hits.count, 9,
                       "有页面写了一份以上的 H1，一屏两个大标题就是这里：\(hits)")
    }

    /// 元测试：注入"缺一页"与"同一页两份"两种坏样例，必须都报。
    func test_pageHeaderScannerDetectsMissingAndDuplicated() {
        var nine: [(path: String, content: String)] = []
        for i in 1...9 {
            nine.append((path: "Views/P\(i).swift", content: "  Theme.Page.Header(title: \"页\")\n"))
        }
        XCTAssertEqual(Self.pageHeaderDeclarations(in: nine).count, 9)
        var duplicated = nine
        duplicated.append((path: "Views/P1.swift",
                           content: "  Theme.Page.Header(title: \"再来一个\")\n"))
        XCTAssertEqual(Self.pageHeaderDeclarations(in: duplicated).count, 10,
                       "同一页写两份 H1 没被抓到")
        let commented: [(path: String, content: String)] =
            [(path: "Views/P1.swift", content: "// 这里原来是 Theme.Page.Header(title: \"x\")\n")]
        XCTAssertTrue(Self.pageHeaderDeclarations(in: commented).isEmpty, "注释被误判成声明")
    }

    // MARK: 批次 G：不许再有"盒式选择器"

    /// `.pickerStyle(.segmented)` 的命中位置。系统分段控件给选中项画一枚**灰底胶囊**，
    /// 那是地面改白之后仅剩的"灰底选中"语言，且与侧栏实心绿选中态、与参考图的
    /// `Week / Month / Quarter / Year` 文字档位都对不齐。全站统一走 `TextSegmentedPicker`。
    static func boxedSegmentedPickers(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    guard SurfaceScanKit.isCode(raw), raw.contains(".pickerStyle(.segmented)") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_noBoxedSegmentedPickersRemain() throws {
        let offenders = Self.boxedSegmentedPickers(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "又出现盒式分段选择器（灰底选中），改走 TextSegmentedPicker：\(offenders)")
    }

    func test_boxedPickerScannerDetectsInjectedUse() {
        let dirty = [(path: "Views/Fake.swift",
                      content: "  Picker(\"x\", selection: $s) {}\n    .pickerStyle(.segmented)\n")]
        XCTAssertEqual(Self.boxedSegmentedPickers(in: dirty).count, 1, "盒式选择器坏样例没抓到")
        let clean = [(path: "Views/Fake.swift",
                      content: "// 原来写 .pickerStyle(.segmented)，已换掉\n")]
        XCTAssertTrue(Self.boxedSegmentedPickers(in: clean).isEmpty, "注释里的写法被误判")
    }

    // MARK: 批次 H：分隔线只许两种画法

    /// `Divider()` 的命中位置。竖线归 `DataBandSeparator`、横线归 `DataRowSeparator`，
    /// `Divider()` 只许留在**系统菜单**里（菜单分隔线由 AppKit 画，不是内容层规则）。
    static func strayDividers(in files: [(path: String, content: String)],
                              allowed: Set<String>) -> [String] {
        files.flatMap { file in
            guard !allowed.contains(file.path) else { return [String]() }
            return file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    guard SurfaceScanKit.isCode(raw), raw.contains("Divider()") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    /// 允许 `Divider()` 的文件 + 理由。**没有理由的条目不许加进来。**
    private static let dividerAllowlist: Set<String> = [
        "Views/Shell/ProjectSidebar.swift",   // 右键菜单里的分组线，由 AppKit 绘制
    ]

    func test_dividerIsConfinedToSystemMenus() throws {
        let offenders = Self.strayDividers(in: try SurfaceScanKit.sourceFiles(under: "Views"),
                                           allowed: Self.dividerAllowlist)
        XCTAssertTrue(offenders.isEmpty,
                      "内容层又出现第三种分隔线画法，竖线用 DataBandSeparator、横线用 DataRowSeparator：\(offenders)")
    }

    func test_strayDividerScannerDetectsInjectedUse() {
        let dirty = [(path: "Views/Fake.swift", content: "  VStack { Divider() }\n")]
        XCTAssertEqual(Self.strayDividers(in: dirty, allowed: []).count, 1, "坏样例没抓到")
        let allowed = [(path: "Shell/Menu.swift", content: "  Divider()\n")]
        XCTAssertTrue(Self.strayDividers(in: allowed, allowed: ["Shell/Menu.swift"]).isEmpty,
                      "白名单没生效")
        let commented = [(path: "Views/Fake.swift", content: "// 原来这里写 Divider()\n")]
        XCTAssertTrue(Self.strayDividers(in: commented, allowed: []).isEmpty, "注释被误判")
    }

    // MARK: 批次 H：量词不许被当成口径

    /// `caption: "个"` 这类**纯量词**写法。量词属于数字（走 `unit:`，同行小一档），
    /// 口径属于这一格在量什么（走 `caption`，落下一行）。混用的后果是同一屏
    /// 出现两种单位尺度：代码规模页「110k 行」同行、依赖页「4 项」换行。
    static func pureUnitCaptions(in files: [(path: String, content: String)]) -> [String] {
        let units: Set<Character> = ["个", "项", "行", "次", "天", "条", "台", "组"]
        return files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    let line = String(raw)
                    guard SurfaceScanKit.isCode(line), let start = line.range(of: "caption: \"") else { return nil }
                    let rest = line[start.upperBound...]
                    guard let end = rest.firstIndex(of: "\"") else { return nil }
                    let text = rest[..<end]
                    guard text.count >= 1, text.count <= 2,
                          let first = text.first, units.contains(first) else { return nil }
                    return "\(file.path):\(index + 1) caption: \"\(text)\""
                }
        }
    }

    func test_pureUnitsGoToUnitNotCaption() throws {
        let offenders = Self.pureUnitCaptions(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "这些格把量词写成了口径（应改用 unit:）：\(offenders)")
    }

    func test_pureUnitScannerDetectsInjectedUse() {
        // 用 `##"…"##` raw string 写样例：内容以引号结尾，单 `#` 的定界符会被
        // 结尾那个 `"` 吃掉（上一版就是这么炸的：unterminated string literal）。
        let dirty = [(path: "Views/Fake.swift",
                      content: ##"  DataReadout(label: "x", value: "4", caption: "项")"## + "\n")]
        XCTAssertEqual(Self.pureUnitCaptions(in: dirty).count, 1, "纯量词 caption 没抓到")
        let fine = [(path: "Views/Fake.swift",
                     content: ##"  DataReadout(label: "x", value: "4", caption: "单文件行数峰值", unit: "行")"##
                         + "\n"
                         + ##"  DataReadout(label: "y", value: "1", caption: "注释率 12%")"## + "\n")]
        XCTAssertTrue(Self.pureUnitCaptions(in: fine).isEmpty,
                      "真口径串被误判成量词（长度/首字判据太松）")
    }

    // MARK: 批次 H：一格之内不许用空格粘多段路径

    /// `occurrenceTitles(...)` 是"把多条路径用三个空格粘成一个长串"的写法。
    /// 它**只允许**出现在 tooltip 一侧：要么直接挂在 `help:` / `.themeHelp(` 上，
    /// 要么被名为 `hint`/`help`/`tooltip` 的 tooltip 构造器收着（这类函数的返回值只喂 `.help`）。
    /// 一旦回到表格单元格，就是实拍里那个样子：两条长路径挤成一团、第二行顶到
    /// 隔壁数字列跟前，列与列之间只剩空格当分隔，表就没有表了。
    static func pathGlueOutsideHelp(in files: [(path: String, content: String)]) -> [String] {
        // 按"行"匹配是错的：`help:` 与它的实参经常跨行写，合法的 tooltip 调用会被误判，
        // 而这条守卫第一次跑就踩在这里。改成在整份文本上找调用点，回看上下文。
        // 也不动用正则 —— 只需要子串与最近的 `func 名字(`，这个匹配不需要正则。
        let needle = "occurrenceTitles("
        let tooltipWords = ["help", "hint", "tooltip"]
        var out: [String] = []
        for file in files {
            var search = file.content.startIndex
            while let hit = file.content.range(of: needle, range: search..<file.content.endIndex) {
                let head = file.content[file.content.startIndex..<hit.lowerBound]
                // 直接 tooltip 入口：回看 160 个字符（够覆盖跨行的 `help:`），
                // 并且必须大小写无关 —— `.themeHelp(` 里是大写 H，第二次跑就漏在这里。
                let window = head.suffix(160).lowercased()
                let atTooltipEntry = tooltipWords.contains { window.contains($0) }
                let owner = Self.enclosingFuncName(in: head)
                let ownedByTooltip = owner.map { name in
                    tooltipWords.contains { name.contains($0) }
                } ?? false
                if !atTooltipEntry, !ownedByTooltip, owner != "occurrenceTitles" {
                    let line = head.split(separator: "\n", omittingEmptySubsequences: false).count
                    out.append("\(file.path):\(line)")
                }
                search = hit.upperBound
            }
        }
        return out
    }

    /// 离调用点最近的那个 `func 名字(`。nil 表示调用点在函数体外（顶层属性、body 之外的静态成员）。
    private static func enclosingFuncName(in head: Substring) -> String? {
        guard let marker = head.range(of: "func ", options: .backwards) else { return nil }
        var cursor = marker.upperBound
        var name = ""
        while cursor < head.endIndex {
            let ch = head[cursor]
            guard ch.isLetter || ch.isNumber || ch == "_" else { break }
            name.append(ch)
            head.formIndex(after: &cursor)
        }
        return name.isEmpty ? nil : name
    }

    func test_multiPathGlueIsConfinedToTooltips() throws {
        let offenders = Self.pathGlueOutsideHelp(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "多路径粘连串又被放回单元格，应改用 CodeDuplicationBlockRow.occurrenceLines：\(offenders)")
    }

    func test_pathGlueScannerAllowsTooltipButFlagsCells() {
        let cell = [(path: "Views/Fake.swift",
                     content: "  Text(Self.occurrenceTitles(block, root: root))\n")]
        XCTAssertEqual(Self.pathGlueOutsideHelp(in: cell).count, 1, "单元格里的粘连串没抓到")
        let help = [(path: "Views/Fake.swift",
                     content: "  .themeHelp(Self.occurrenceTitles(block, root: root))\n"
                         + "  static func occurrenceTitles(_ b: Int) -> String { \"\" }\n")]
        XCTAssertTrue(Self.pathGlueOutsideHelp(in: help).isEmpty,
                      "help: 与定义本身被误判")
        let builder = [(path: "Views/Fake.swift",
                        content: "  static func hint(_ b: Int) -> String {\n"
                            + "    \"相似度 1 · \"\n        + occurrenceTitles(b, root: \"\")\n  }\n")]
        XCTAssertTrue(Self.pathGlueOutsideHelp(in: builder).isEmpty,
                      "名为 hint 的 tooltip 构造器被误判")
        let notTooltip = [(path: "Views/Fake.swift",
                           content: "  static func label(_ b: Int) -> String {\n"
                               + "    occurrenceTitles(b, root: \"\")\n  }\n")]
        XCTAssertEqual(Self.pathGlueOutsideHelp(in: notTooltip).count, 1,
                       "粘连串换了个非 tooltip 函数名就溜过去了")
    }

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
        let tokens = try SurfaceScanKit.sourceFiles(under: "Design")
            .filter { $0.path.hasSuffix("ThemeTokens.swift") }
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
}
