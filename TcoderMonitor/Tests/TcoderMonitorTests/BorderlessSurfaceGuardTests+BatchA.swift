import XCTest
@testable import TcoderMonitor

// MARK: - 第三轮·批次 A：绘图溢出与上屏字面量（自 BorderlessSurfaceGuardTests.swift 原样搬出）
//
// 搬的理由是机械的：本 App 自扫点名原文件越过 400 行「巨大文件」线，
// 而 `X3TestSizeAuditTests` 用同一口径钉着它。判据、合成样例与数字一字未改；
// 内容取 main 的最新版本（含批次 A 之后补的注释与用例）。
// `isCode` 原是 private：跨文件复用就放宽到模块内可见（本仓先例见 ComplexityCounting.swift 顶部）。
extension BorderlessSurfaceGuardTests {

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
            let code = Self.codeLines(file.content)
            guard code.contains(where: { $0.contains("AreaMark(") }) else { return nil }
            guard !code.contains(where: { $0.contains("chartPlotStyle") && $0.contains("clipped") })
            else { return nil }
            let line = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .firstIndex(where: { Self.isCode($0) && $0.contains("AreaMark(") })
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
                    guard Self.isCode(raw), raw.contains("\""), raw.contains("**") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    /// 与 `codeLines` 同一个「整行注释」判据 —— 两个扫描器必须共用，否则会出现
    /// 一个豁免注释、另一个不豁免的分歧。
    static func isCode(_ line: some StringProtocol) -> Bool {
        !line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    func test_areaChartsClipTheirPlotArea() throws {
        let views = try Self.sourceFiles(under: "Views")
        let offenders = Self.unclippedAreaCharts(in: views)
        XCTAssertTrue(offenders.isEmpty,
                      "这些文件画了 AreaMark 却没裁绘图区，轴一收窄就会盖住下面的区块：\(offenders)")
        XCTAssertGreaterThanOrEqual(views.filter { $0.content.contains("AreaMark(") }.count, 2,
                                    "分母必须 > 0：全仓至少两张面积图，扫到 0 张说明扫描器瞎了")
    }

    func test_noMarkdownStarsReachTheScreen() throws {
        let offenders = Self.markdownStarsInUIStrings(in: try Self.sourceFiles(under: "Views"))
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
                    guard isCode(raw), raw.contains("Theme.Page.Header(") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_everyPageDeclaresExactlyOnePageHeader() throws {
        let hits = Self.pageHeaderDeclarations(in: try Self.sourceFiles(under: "Views"))
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
                    guard isCode(raw), raw.contains(".pickerStyle(.segmented)") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_noBoxedSegmentedPickersRemain() throws {
        let offenders = Self.boxedSegmentedPickers(in: try Self.sourceFiles(under: "Views"))
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
                    guard isCode(raw), raw.contains("Divider()") else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    /// 允许 `Divider()` 的文件 + 理由。**没有理由的条目不许加进来。**
    private static let dividerAllowlist: Set<String> = [
        "Views/Shell/ProjectSidebar.swift",   // 右键菜单里的分组线，由 AppKit 绘制
    ]

    func test_dividerIsConfinedToSystemMenus() throws {
        let offenders = Self.strayDividers(in: try Self.sourceFiles(under: "Views"),
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
                    guard isCode(line), let start = line.range(of: "caption: \"") else { return nil }
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
        let offenders = Self.pureUnitCaptions(in: try Self.sourceFiles(under: "Views"))
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
        let offenders = Self.pathGlueOutsideHelp(in: try Self.sourceFiles(under: "Views"))
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

    /// 反向自证：`sourceFiles` 真读到了文件。否则上面所有「扫不到就算通过」的断言
    /// 会集体假绿 —— 这是扫描型守卫最经典的死法。
    func test_sourceScannerActuallyFindsFiles() throws {
        let design = try Self.sourceFiles(under: "Design")
        XCTAssertGreaterThanOrEqual(design.count, 9, "Design/ 只扫到 \(design.count) 个文件")
        XCTAssertTrue(design.contains { $0.path.hasSuffix("Glass.swift") })
        XCTAssertEqual(Self.shadowHits(in: design).count, 1,
                       "元测试：真源码里的投影数必须与契约断言一致")
    }
}
