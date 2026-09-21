import XCTest
@testable import TcoderMonitor

/// OWNER: WS-S7 外壳二 —— 总览页剩下三处的落点自检。
///
/// 工单是《2026-09-21 九页碎文案盘点表》A 组里 S1 交回时说"槽位还没开所以没做"的那三处：
/// `DashboardLiveReadout.cadenceSubtitle`（ⓘ 走 `GlassSection.subtitleHelp:`）、
/// 同页读数带的 `MetricTile.captionHelp:`、以及 `BannerRow` 新开的 `help:` 槽。
///
/// **本文件不复制那三条成对守卫**（A 常驻长句 / B 总量守恒 / C 承诺句常驻住在
/// `TooltipMigrationGuardTests`，两处各写一遍 = 两把尺子）。本文件只管 S7 自己写下的四件事：
///   ① `BannerRow.help:` 挂的是全站唯一的 `CopyHelpBadge`，且默认 `nil` 时零版面成本；
///   ② 横幅的长下文**只许**走 `help:` 槽，不许再挂在整条横幅外面的裸 `.help`（匿名 tooltip）；
///   ③ 三处搬字一条字都没少：搬走的整句仍能在源码里找到，且走的是**既有真值生产者/常量**
///      （`SystemReadings.memoryCaliber`、`GitHistoryScope.headline`、`PerformanceLiveCharts.cpuBasis`），
///      而不是在本片再抄一遍中文；
///   ④ 读数带四枚 tile 的 `caption:` 一格都没空掉 —— `caption == nil` 会照
///      `TileCaptionLayout` 留白，去掉脚注等于挪动整条读数带（S4 为这条写过基线自检）。
/// 外加本片那处"第二落点"的防分叉自检（⑥）：总览 ⓘ 里那句与性能页页头那句必须逐字同一句。
final class ShellReadoutTooltipTests: XCTestCase {

    static let readoutsPath = "Views/Shell/DashboardReadouts.swift"

    static func source(_ path: String) throws -> String {
        let files = try SurfaceScanKit.sourceFiles(under: "")
        return try XCTUnwrap(files.first { $0.path == path },
                             "扫不到 \(path) —— 文件被搬走而这条自检还绿着").content
    }

    /// 剥掉整行注释后的代码行（本文件所有判据共用；注释里引用旧写法不算命中）。
    static func codeLines(of content: String) -> [String] {
        content.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("//") }
    }

    // MARK: - ① BannerRow 的 help 槽

    func test_bannerRowHelpSlotMountsTheOneComponent() throws {
        let body = try Self.source(Self.readoutsPath)
        let banner = body[body.range(of: "struct BannerRow")!.lowerBound...]
        let slice = String(banner[..<banner.range(of: "\nextension View")!.lowerBound])
        XCTAssertTrue(slice.contains("var help: String? = nil"),
                      "help 槽不再默认 nil ⇒ 现有调用点会被迫改签名（工单要求形状照 SectionEmptyNote.help:）")
        XCTAssertTrue(slice.contains("if let help { CopyHelpBadge(help) }"),
                      "help 槽不再走全站唯一那份画法 `CopyHelpBadge` —— 会出现第二种问号")
        XCTAssertTrue(slice.contains("Text(text)"), "横幅正文被搬走了（本槽是加法，不是替换）")
    }

    /// 元测试：①的三条判据各自都要抓得住坏样例。
    func test_meta_bannerSlotJudgesCatchInjectedShapes() {
        let noDefault = "struct BannerRow: View {\n    var help: String\n}\n"
        XCTAssertFalse(noDefault.contains("var help: String? = nil"), "默认 nil 被改掉却没被抓到")
        let handDrawn = """
        struct BannerRow: View {
            var help: String? = nil
            var body: some View {
                ThemedIcon(.unverified, role: .badge).help(help ?? "")
            }
        }
        """
        XCTAssertFalse(handDrawn.contains("CopyHelpBadge(help)"), "页面自己画问号没被抓到")
    }

    // MARK: - ② 横幅不许再挂匿名 .help

    /// `BannerRow(...)` 之后 ≤2 行里出现 `.help(` ⇒ 就是"整条横幅当 tooltip 宿主"的匿名形状。
    static func anonymousBannerTooltips(in files: [(path: String, content: String)])
        -> (bannerSites: Int, helpSlots: Int, offenders: [String]) {
        var bannerSites = 0
        var helpSlots = 0
        var offenders: [String] = []
        for file in files {
            let lines = file.content.components(separatedBy: "\n")
            for (index, raw) in lines.enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") { continue }
                if line.contains("BannerRow(") { bannerSites += 1 }
                if line.contains("help:") { helpSlots += 1 }
                guard line.contains("BannerRow(") else { continue }
                let window = lines.dropFirst(index + 1).prefix(2)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                if window.contains(where: { !$0.hasPrefix("//") && $0.contains(".help(") }) {
                    offenders.append("\(file.path):\(index + 1): \(line.prefix(56))")
                }
            }
        }
        return (bannerSites, helpSlots, offenders)
    }

    func test_bannerCalibersRideTheHelpSlotNotAnAnonymousHelp() throws {
        let hit = Self.anonymousBannerTooltips(in: try TooltipMigrationGuardTests.viewFiles())
        print("【ⓘ·S7 横幅】BannerRow 调用点 \(hit.bannerSites) 处 / 其中 help: 槽 \(hit.helpSlots) 处"
              + " / 匿名 .help 形状 \(hit.offenders.count) 处")
        XCTAssertGreaterThanOrEqual(hit.bannerSites, 6,
                                    "只扫到 \(hit.bannerSites) 个横幅调用点，判据面已经缩了")
        XCTAssertGreaterThanOrEqual(hit.helpSlots, 3,
                                    "help: 槽只用了一次，说明「用起来」这件事没做完（实扫 \(hit.helpSlots) 处）")
        XCTAssertTrue(hit.offenders.isEmpty,
                      "这些横幅把长下文挂在整条横幅的裸 .help 上，问号看不见、鼠标得猜："
                        + "\n" + hit.offenders.joined(separator: "\n"))
    }

    /// 元测试：②的判据必须抓得住坏样例，也不误伤走槽的正常形状。
    func test_meta_anonymousBannerScannerFiresOnBadSampleAndSparesGood() {
        let bad = [(path: "Views/Fake.swift", content: """
        BannerRow(text: "该项目还没有日志分析结果", style: .neutral)
            .help("该项目还没有日志分析结果。选择项目目录后点「重新分析」，或手动附加本地日志文件。")
        """)]
        let hit = Self.anonymousBannerTooltips(in: bad)
        XCTAssertEqual(hit.bannerSites, 1, "调用点没进分母，这条判据会假绿")
        XCTAssertEqual(hit.offenders.count, 1, "匿名形状没被抓到")
        let good = [(path: "Views/Fake.swift", content: """
        BannerRow(text: "该项目还没有日志分析结果", style: .neutral,
                  help: "该项目还没有日志分析结果。选择项目目录后点「重新分析」，或手动附加本地日志文件。")
        """)]
        XCTAssertTrue(Self.anonymousBannerTooltips(in: good).offenders.isEmpty, "走槽的正常形状被误伤")
    }

    // MARK: - ③ 三处搬字：整句仍在，且走的是既有真值

    /// 读数带三枚 tile 的 ⓘ 各指向哪一份真值生产者。**指生产者而不是抄中文**：
    /// 同一条口径在两页各写一份，早晚量出两个结论（依赖页那两条逐字重复就是前车之鉴）。
    static let captionHelpSources: [(tile: String, producer: String)] = [
        ("cpuTile", "captionHelp: PerformanceLiveCharts.cpuBasis(context: SampleContext.from(state.monitor))"),
        ("memoryTile", "captionHelp: SystemReadings.memoryCaliber"),
        ("commitTile", "captionHelp: report?.git.map { GitHistoryScope($0).headline }"),
    ]

    func test_tileCaptionHelpsPointAtExistingProducers() throws {
        let body = try Self.source(Self.readoutsPath)
        XCTAssertFalse(Self.captionHelpSources.isEmpty, "对照表空了 = 这条判据在空转")
        for item in Self.captionHelpSources {
            XCTAssertTrue(body.contains(item.producer),
                          "\(item.tile) 的 ⓘ 不再走那份唯一真值（或被搬走）：\(item.producer)")
        }
        // 搬过来的整句都还在原地活着（B 守恒的本片自查：搬字不是删字）。
        let calibers = [try Self.source("Views/PerfLogs/LiveReadings.swift"),
                        try Self.source("Views/CodeGit/GitHistoryScope.swift")]
            .reduce("", +)
        XCTAssertTrue(calibers.contains("口径 = 总量 −（空闲 + 推测 + 可清除）"),
                      "内存口径那句整句没了 —— 总览的 ⓘ 会指到一个不存在的真值")
        XCTAssertTrue(calibers.contains("作者与代码行统计基于 %3$@ 次非合并提交"),
                      "Git 那条分母句没了：读数带的 ⓘ 会指到一个不存在的真值")
    }

    /// 「今日错误」那枚**故意不挂** ⓘ：它的 caption 在缺数据那一支就是 `ShellCopy` 三态句，
    /// 而三态句（没查 / 查了是空的 / 查不了）是"这个 0 该怎么读"本身，只许常驻
    /// （与 `ShellTooltipTests.test_honestyPhrasesAreNeverHiddenBehindATooltip` 同一条红线）。
    func test_errorTileCarriesNoTooltipAndNoHonestyPhraseIsHidden() throws {
        let lines = Self.codeLines(of: try Self.source(Self.readoutsPath))
        let errorTile = lines.enumerated().filter { $0.element.contains("label: \"今日错误\"") }
        XCTAssertFalse(errorTile.isEmpty, "读数带里找不到今日错误那一格，判据面缩了")
        let helpLinesWithShellCopy = lines.filter { $0.contains("captionHelp:") && $0.contains("ShellCopy.") }
        XCTAssertTrue(helpLinesWithShellCopy.isEmpty,
                      "三态句被塞进脚注的 ⓘ 了：\n" + helpLinesWithShellCopy.joined(separator: "\n"))
        let helpLines = lines.filter { $0.contains("captionHelp:") }
        XCTAssertEqual(helpLines.count, Self.captionHelpSources.count,
                       "脚注 ⓘ 的数量与本表点名的不等（多出来的那一条要在这里点名再放行）：\(helpLines)")
    }

    // MARK: - ④ 读数带的四格脚注不许空掉

    func test_readoutStripKeepsEveryCaptionSoTheBandDoesNotMove() throws {
        let lines = Self.codeLines(of: try Self.source(Self.readoutsPath))
        let captions = lines.filter { $0.hasPrefix("caption:") }
        XCTAssertEqual(captions.count, 4,
                       "读数带四格的 caption 只剩 \(captions.count) 条 —— caption 为 nil 时"
                       + "布局照 TileCaptionLayout 留白，整条带会往上挪（S4 为这条写过基线自检）")
    }

    // MARK: - ⑤⑥ 节奏那处：屏上短句 + ⓘ 长句成对，且第二落点不许分叉

    func test_cadenceShortStaysOnScreenAndCaliberIsTheSameSentenceAsThePerfHeader() throws {
        let lines = Self.codeLines(of: try Self.source(Self.readoutsPath))
        XCTAssertTrue(lines.contains("subtitleHelp: cadenceCaliber,"),
                      "「实时性能」分组不再挂 ⓘ 长口径 —— 节奏这句回到只上屏的状态了")
        XCTAssertTrue(lines.contains { $0.contains("\"本机 · 采样已暂停\"") },
                      "暂停态屏上那半句被搬走了：改口这件事得留在屏上")
        // 第二落点防分叉：总览 ⓘ 里那句必须与性能页页头**逐字同一句**，否则两页各说一套。
        // 页头那句在文件里只许有一处 `subtitle: "`，多一处就不比对、直接喊 —— 静默挑一条是最贵的假绿。
        let perf = try Self.source("Views/Performance/PerformanceView.swift")
        let markers = perf.components(separatedBy: "subtitle: \"").dropFirst()
        XCTAssertEqual(markers.count, 1,
                       "性能页有 \(markers.count) 处 `subtitle: \"`，本判据不知道该比哪一条")
        let tail = markers.first!
        let headerCopy = String(tail[..<tail.range(of: "\"")!.lowerBound])
        XCTAssertEqual(DashboardLiveReadout.liveReadingsCaliber, headerCopy,
                       "同一条只读承诺在两页写成了两句话（本流无权改 Views/Performance，故报总工收常量）")
    }
}
