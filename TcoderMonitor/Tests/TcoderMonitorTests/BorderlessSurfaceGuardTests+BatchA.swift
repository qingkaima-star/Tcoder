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
