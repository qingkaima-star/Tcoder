import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - WS-W 三页（性能 / 日志 / 健康）的「简约无界」守卫
//
// 权威 = spec §1 风格契约 + §4.2 逐页自查清单，加上总工 2026-09-20 补的两条
// （`tint:` 不得收 `Theme.Semantic.info/accent`；`MetricTile` 的 `tint:` 不得收图表序列色）。
//
// 三条写文件时就定下的规矩：
//   1. **每条扫描判据都配元测试**（造违规样本确认它会红）。理由见记忆
//      「扫描型测试要配元测试」：本轮的病因之一就是守卫只查「有没有散写魔法数」，
//      查不出「定义了没人用」，于是 `Spacing.section` 零引用烂了一整轮。
//      一条扫不到东西的守卫和一条失灵了的守卫，在输出上长得一模一样。
//   2. 复用总工在 `BorderlessSurfaceGuardTests` 里那份 `sourceFiles(under:)` / `codeLines(_:)`
//      —— 不另起一套路径口径，两把尺子量同一个东西才能互相比对。
//   3. 脏样本里凡是标了「HEAD 原文」的，是从 `415f0f0` 逐字抄下来的**改前代码**，
//      不是编出来的稻草人：守卫必须能抓到历史上真实存在过的那个形状。

final class PerfLogsBorderlessTests: XCTestCase {

    private static let ownedDirectories = ["Performance", "Logs", "Health", "PerfLogs"]

    // MARK: - 扫描器（纯函数，供合成输入元测试）

    /// 一条 `.tertiary` 所在的**修饰链** = 它自己那一行，往上直到（并包含）第一条
    /// 不以 `.` 开头的行；碰到空行、或以 `{` / `}` 结尾的行就停。
    ///
    /// 为什么要成链而不是只看一行：SwiftUI 里读数的写法是
    /// `Text(Live.bytes(x))` ↵ `.font(...)` ↵ `.foregroundStyle(.tertiary)`，
    /// 只看 `.tertiary` 那一行的话，**每一处跨行链都漏**，守卫会稳定假绿。
    /// 为什么必须封顶：往上一个空行/一个 `}` 之外就是**兄弟语句**了，
    /// 把它一起算进来会把邻居的测得值误记到这条链上（《45》里 awk 块越界的同类坑）。
    static func modifierChain(around index: Int, in lines: [String]) -> [String] {
        let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix(".") else { return [lines[index]] }
        var chain = [lines[index]]
        var j = index - 1
        while j >= 0 {
            let up = lines[j].trimmingCharacters(in: .whitespaces)
            if up.isEmpty || up.hasSuffix("{") || up.hasSuffix("}") { break }
            chain.append(lines[j])
            if !up.hasPrefix(".") { break }   // 锚行（`Text(…)`）收进来就停
            j -= 1
        }
        return chain
    }

    /// 读数格式化器的字面。链里出现任意一个 = 这条 `Text` 承载的是**测得值**。
    static let measuredValueMarkers = [
        "Live.", "NumberFormat.", "ByteFormat.", "DataAbsence", "LiveNumber", "value:",
    ]

    /// 落在测得值上的 `.tertiary`。
    static func tertiaryOnMeasuredValues(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = BorderlessSurfaceGuardTests.codeLines(file.content)
            var found: [String] = []
            for index in lines.indices where lines[index].contains(".tertiary") {
                let chain = modifierChain(around: index, in: lines)
                let carriesReading = chain.contains { line in
                    measuredValueMarkers.contains(where: line.contains)
                }
                if carriesReading { found.append("\(file.path):\(index + 1)") }
            }
            return found
        }
    }

    /// `MetricTile(` / 格子调用点上的 `tint:` 收**交互色**（info / accent）的位置。
    /// 只扫 `tint:` 具名实参这一种形状 —— `.tint()` 修饰器服务的是控件（如
    /// `DisclosureGroup`），那里 accent 合法，不是一刀切的对象。
    static func interactiveTintOnTiles(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { line in
            line.contains("tint: Theme.Semantic.info") || line.contains("tint: Theme.Semantic.accent")
        })
    }

    /// `tint:` 收图表**序列色**（`ChartSeries.color(`）的位置 —— 序列色属于图与图例，
    /// 不属于数字。
    static func seriesColoredTiles(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { $0.contains("tint: ChartSeries.color(") })
    }

    /// `areaTopOpacity` 的**定义行**没走 `Opacity.gradientAreaSoft` 令牌的位置。
    /// 只要行里同时有 `areaTopOpacity` 和 `=`，就算定义行
    /// （使用处是 `color.opacity(areaTopOpacity)`，没有 `=`，不会误伤）。
    static func areaOpacityDefinitionsNotUsingToken(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { line in
            line.contains("areaTopOpacity") && line.contains("=")
                && !line.contains("Opacity.gradientAreaSoft")
        })
    }

    /// 图表层里 `Theme.Chart` 分类板的引用位置。三页**每张图只有一条序列**，
    /// 没有需要分辨「哪条是哪条」的场合，于是分类色在这里必然为零。
    static func categoryPaletteUses(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { $0.contains("Theme.Chart") })
    }

    /// 把「相邻分组间距 ≥ 24」量出来的那条判据：
    /// 从 `spacing: Theme.Spacing.<档>` 起按**大括号深度**找到容器闭合，
    /// 途中出现直接子项 `GlassSection(` 就说明这个间距管的是**组间**，
    /// 低于 24 即为拥挤。
    static func containersTighteningGroups(in files: [(path: String, content: String)]) -> [String] {
        var hits: [String] = []
        for file in files {
            let lines = BorderlessSurfaceGuardTests.codeLines(file.content)
            for index in lines.indices {
                guard let tier = spacingTier(in: lines[index]),
                      !sufficientGroupTiers.contains(tier) else { continue }
                var depth = 0
                var j = index
                while j < lines.count {
                    depth += lines[j].filter { $0 == "{" }.count
                    depth -= lines[j].filter { $0 == "}" }.count
                    if j > index {
                        if lines[j].contains("GlassSection(") {
                            hits.append("\(file.path):\(index + 1) [\(tier)] 组间距低于 24")
                            break
                        }
                        if depth <= 0 { break }
                    }
                    j += 1
                }
            }
        }
        return hits
    }

    static let sufficientGroupTiers: Set<String> = ["group", "section", "xxl", "xl"]

    private static func spacingTier(in line: String) -> String? {
        guard let range = line.range(of: "spacing: Theme.Spacing.") else { return nil }
        let tail = line[range.upperBound...]
        return String(tail.prefix { $0.isLetter })
    }

    /// 每个 `struct` 里某符号的出现次数 —— 「一枚 hero 主角」这类判据的作用域单位。
    /// 健康页有两处 `HealthRing(`，但分别在 `HealthHero` 与 `HealthNoInputCard`
    /// 两个互斥分支里，所以「整页 ≤ 2」是假松、「同一 struct 内 ≤ 1」才是真判据。
    static func symbolCountPerStruct(named symbol: String,
                                     in files: [(path: String, content: String)]) -> [String: Int] {
        var counts: [String: Int] = [:]
        for file in files {
            var scope = file.path
            for line in BorderlessSurfaceGuardTests.codeLines(file.content) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                let keyword: String?
                if trimmed.hasPrefix("struct ") { keyword = "struct " }
                else if trimmed.hasPrefix("enum ") { keyword = "enum " }
                else { keyword = nil }
                if let keyword {
                    let name = trimmed.dropFirst(keyword.count)
                        .prefix { $0.isLetter || $0.isNumber || $0 == "_" }
                    if !name.isEmpty { scope = "\(file.path).\(name)" }
                }
                counts[scope, default: 0] += line.contains(symbol) ? 1 : 0
            }
        }
        return counts
    }

    /// 页面目录里自己养的**页头类型**声明。
    /// 「页头」（项目名 / 路径 / 分析时间 / 右侧控件）全仓只许一套画法，
    /// 归 `Views/ProjectDetailView.swift` 与 `Views/Shell/**`（WS-O 名下）。
    static func pageHeaderDeclarations(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, where: { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("struct ") && trimmed.contains(": View")
                && trimmed.contains("PageHeader")
        })
    }

    private static func hits(in files: [(path: String, content: String)],
                             where predicate: (String) -> Bool) -> [String] {
        files.flatMap { file in
            BorderlessSurfaceGuardTests.codeLines(file.content)
                .enumerated()
                .filter { _, line in predicate(line) }
                .map { "\(file.path):\($0.offset + 1)" }
        }
    }

    private func ownedFiles() throws -> [(path: String, content: String)] {
        let all = try BorderlessSurfaceGuardTests.sourceFiles(under: "Views")
        let picked = all.filter { file in
            Self.ownedDirectories.contains { file.path.hasPrefix("Views/\($0)/") }
        }
        XCTAssertEqual(picked.count, 17,
                       "只扫到 \(picked.count) 个文件（应为 17：性能 6 + 日志 5 + 健康 3 + 共用层 3）。"
                       + "目录或文件数变了先改这条，否则下面所有扫描都在空气上判通过。")
        return picked
    }

    // MARK: - ① 测得值上不得有 `.tertiary`

    func test_noTertiaryOnMeasuredValuesInOwnedPages() throws {
        let hits = Self.tertiaryOnMeasuredValues(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty,
                      "读数值被涂成三级灰（风格契约 4「最重的墨给最重要的数」的反面）：\(hits)")
    }

    func test_ownedPagesStillUseTertiarySomewhere() throws {
        // 反向自证：三页仍然在路径 / 时间戳 / 分隔符上用着 `.tertiary`。
        // 没有这条，上面那个「0 命中」既可能是「都改对了」，也可能是「扫描器瞎了」——
        // 而这两种情况在测试输出上长得一模一样。
        let files = try ownedFiles()
        let total = files.reduce(0) { sum, file in
            sum + BorderlessSurfaceGuardTests.codeLines(file.content)
                .filter { $0.contains(".tertiary") }.count
        }
        XCTAssertGreaterThanOrEqual(total, 5,
                                    "全目录只剩 \(total) 处 `.tertiary`：判据①的 0 命中可能来自扫描器失灵")
    }

    // MARK: - ② 健康分 nil 必须仍是 neutral / 空心

    func test_nilScoreIsNeutralAndNeverDanger() {
        let role = Theme.Semantic.role(forScore: nil)
        XCTAssertEqual(role.name, "neutral", "「从没扫过」不得画成「最危险」")
        XCTAssertNotEqual(role.name, "danger")
        XCTAssertNotEqual(role.name, "critical")
    }

    func test_nilScoreReadsAsPlaceholderNotZero() {
        XCTAssertEqual(HealthRing.scoreText(for: nil), DataAbsence.notAnalysed.display,
                       "环心里那份 nil 必须写成缺证据字面，写成 0 就是伪造结论")
    }

    func test_noInputCardStillPassesAnExplicitNilScore() throws {
        let files = try ownedFiles()
        let sites = files.filter { $0.content.contains("HealthRing(score: nil") }
        XCTAssertEqual(sites.count, 1,
                       "「无维度输入」那一态必须以显式 nil 进环；改成 0 会被读成「这个项目很差」")
    }

    func test_scoreNeverReadsThroughADefaultedZero() throws {
        let hits = Self.hits(in: try ownedFiles(), where: { line in
            (line.contains("forScore:") || line.contains("HealthRing(score:")) && line.contains("?? 0")
        })
        XCTAssertTrue(hits.isEmpty, "分数走了 `?? 0` 兜底，缺证据被冒充成 0 分：\(hits)")
    }

    // MARK: - ③ 每页最多一枚 heroMetric

    func test_noHeroMetricInsideOwnedPages() throws {
        // 健康页那枚 56pt 由 `HealthRing`（`Views/Shell/`，归 WS-O）画，
        // 所以三页自己**一处都不许**再出现 heroMetric，否则同页两枚主角。
        let hits = Self.hits(in: try ownedFiles(), where: { $0.contains("heroMetric") })
        XCTAssertTrue(hits.isEmpty, "同页第二枚 heroMetric（56pt 归健康页的分数环）：\(hits)")
    }

    func test_noSecondProtagonistTierInOwnedPages() throws {
        let hits = Self.hits(in: try ownedFiles(), where: { $0.contains("Typo.metricNumber") })
        XCTAssertTrue(hits.isEmpty,
                      "页面自己抬 metricNumber(34) 会跟读数带与分数环抢位：\(hits)")
    }

    func test_healthRingAppearsAtMostOncePerStruct() throws {
        let files = try ownedFiles().filter { $0.path.hasPrefix("Views/Health/") }
        let counts = Self.symbolCountPerStruct(named: "HealthRing(", in: files)
        let doubled = counts.filter { $0.value > 1 }.sorted { $0.key < $1.key }
        XCTAssertTrue(doubled.isEmpty, "同一个视图里两枚分数环 = 两枚主角：\(doubled)")
        XCTAssertEqual(counts.values.reduce(0, +), 2,
                       "健康页应有两处 `HealthRing(`（有分 / 无维度输入），且分属两个互斥分支")
    }

    // MARK: - ④ 相邻分组间距 ≥ 24

    func test_groupSpacingTiersAreAtLeast24() {
        XCTAssertGreaterThanOrEqual(Theme.Spacing.group, 24)
        XCTAssertGreaterThanOrEqual(Theme.Spacing.section, 24)
        XCTAssertGreaterThanOrEqual(Theme.Spacing.pageMargin, 24)
    }

    func test_ownedPagesShareTheOneBaseSkeleton() throws {
        // 本流一度自造过一份 `BorderlessPage`（因为基座 `Theme.Page.Scaffold` 组间距写死 16）。
        // 总工 `48443d9` 把基座换成 pageMargin/group/section 三档，并钉了「全仓只许一份页骨架」，
        // 所以那份已删除、三页改回基座。这里反过来钉住**结果**：
        //   ① 三页都走基座那份；② 本流域里不许再出现第二份骨架声明。
        let files = try ownedFiles()
        let ownScaffold = Self.hits(in: files, where: { line in
            // 与总工那份 `pageScaffoldDeclarations` 同一判据形状（先 trim 再认 `struct …: View`），
            // 否则缩进里的声明会漏 —— 两把尺子必须同形状才比得出差异。
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("struct ") && trimmed.contains(": View")
                && (trimmed.contains("Scaffold") || trimmed.contains("BorderlessPage"))
        })
        XCTAssertTrue(ownScaffold.isEmpty,
                      "本流域里又长出了第二份页骨架（只许用 `Theme.Page.Scaffold`）：\(ownScaffold)")
        for page in ["PerformanceView", "LogsView", "HealthView"] {
            XCTAssertTrue(files.contains { $0.path.hasSuffix("\(page).swift")
                && $0.content.contains("Theme.Page.Scaffold(") },
                          "\(page).swift 没走基座页骨架，组间距就不受 `Spacing.group` 那条断言保护")
        }
    }

    func test_ownedPagesDoNotOwnAPageHeaderType() throws {
        // 「页头」这件事全仓只许一套画法，归 WS-O 的 `ProjectDetailView` / `Views/Shell/**`。
        // 本流域曾养过一份 `PerfLogsPageHeader`（三页共用），已按总工裁定删除：
        // 页面目录里再出现任何 `struct …PageHeader…: View` 就是第二套页头。
        let files = try ownedFiles()
        let headers = Self.pageHeaderDeclarations(in: files)
        XCTAssertTrue(headers.isEmpty,
                      "页面目录里养着第二套页头（归 WS-O）：\(headers)")
        // 反向：三页各自写**页内小标题**（页名 + 本页口径），不依赖任何共用页头件。
        for (page, title) in [("PerformanceView", "性能监控"),
                              ("LogsView", "错误日志分析"),
                              ("HealthView", "健康评分")] {
            let file = try XCTUnwrap(files.first { $0.path.hasSuffix("\(page).swift") })
            XCTAssertTrue(file.content.contains("Text(\"\(title)\")"),
                          "\(page) 的页名不在本页里 → 页内小标题被抽走或改名了")
        }
    }

    func test_noContainerWrapsGlassSectionsInTightSpacing() throws {
        let hits = Self.containersTighteningGroups(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty, "直接包着 `GlassSection` 的容器用了低于 24 的间距：\(hits)")
    }

    // MARK: - ⑤ 曲线面积顶色走令牌，不走字面量

    func test_areaTopOpacityIsDefinedByTheToken() throws {
        let chrome = try XCTUnwrap(
            try ownedFiles().first { $0.path.hasSuffix("ChartChrome.swift") },
            "扫不到 ChartChrome.swift —— 这条判据会在空气上通过")
        let hits = Self.areaOpacityDefinitionsNotUsingToken(in: [chrome])
        XCTAssertTrue(hits.isEmpty,
                      "面积顶色又变回页面自己养的常量（本轮病因「令牌定义了没人用」原样复发）：\(hits)")
    }

    func test_areaTopOpacityEqualsTheSoftTokenAndNotTheHeavyOne() {
        XCTAssertEqual(ChartSeries.areaTopOpacity, Theme.Palette.Opacity.gradientAreaSoft,
                       accuracy: 0.0001, "顶色必须等于 `Opacity.gradientAreaSoft`")
        XCTAssertNotEqual(ChartSeries.areaTopOpacity, Theme.Palette.Opacity.gradientTop,
                          accuracy: 0.0001, "0.30 在密集实时曲线上过浓（总工截图复核问题 1）")
    }

    func test_ownedPagesDrawNoCategoryPaletteSeries() throws {
        let hits = Self.categoryPaletteUses(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty,
                      "三页每张图只有一条序列，分类板在这里没有对手可分辨：\(hits)")
    }

    // MARK: - ⑥⑦（总工补）tile 的 tint 收支

    func test_noInteractiveColorOnTileTints() throws {
        let hits = Self.interactiveTintOnTiles(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty,
                      "读数被涂成交互色（蓝同时是链接与选中色，一色二义）：\(hits)")
    }

    func test_noSeriesColorOnTileTints() throws {
        let hits = Self.seriesColoredTiles(in: try ownedFiles().filter {
            $0.path.hasPrefix("Views/Performance/")
        })
        XCTAssertTrue(hits.isEmpty,
                      "序列色属于图与图例，不属于数字：磁盘/网络那两枚曾经就是 `tint: ChartSeries.color(.disk)`：\(hits)")
    }

    // MARK: - 元测试：证明上面每条尺子都量得动东西

    /// 脏样本里第 1、2 条是 `415f0f0` 上**真实存在过**的代码（改前），不是稻草人。
    func test_scannersCatchSyntheticViolations() {
        let preFixChip = """
            Text(item.sizeBytes.map { Live.bytes($0) } ?? Live.missing)
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
            """
        let preFixCount = """
            Text("已附加 \\(NumberFormat.grouped(attachedItems.count)) 个文件")
                .font(Theme.Typo.microLabel.font)
                .foregroundStyle(.tertiary)
            """
        let singleLine = #"Text(Live.percent(fraction)).foregroundStyle(.tertiary)"#
        let dirtyTertiary = [
            (path: "Views/Fake.swift", content: preFixChip),
            (path: "Views/Fake.swift", content: preFixCount),
            (path: "Views/Fake.swift", content: singleLine),
        ]
        XCTAssertEqual(Self.tertiaryOnMeasuredValues(in: dirtyTertiary).count, 3,
                       "跨行链与同行两种形状必须都抓到，否则三页的 0 命中只是扫描器看不见")

        let cleanTertiary = [
            (path: "Views/Fake.swift", content: #"Text("·").foregroundStyle(.tertiary)"#),
            (path: "Views/Fake.swift", content: """
                Text(DateFormat.full.string(from: health.computedAt))
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.tertiary)
                """),
            (path: "Views/Fake.swift", content: """
                Text("来源文件 \\(cluster.sourceFile)")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                """),
        ]
        XCTAssertTrue(Self.tertiaryOnMeasuredValues(in: cleanTertiary).isEmpty,
                      "路径与时间戳是合法的次要元数据，误伤就等于逼调用点再造一档灰")

        // 链必须**封顶**：兄弟语句里的测得值不该记到这条链上。
        let bounded = """
            Text("机身 \\(Live.text(snapshot))")

            Text("·").foregroundStyle(.tertiary)
            """
        XCTAssertTrue(Self.tertiaryOnMeasuredValues(
            in: [(path: "Views/Fake.swift", content: bounded)]).isEmpty,
                      "修饰链越界吃进了上面的兄弟语句 —— 会把合法用法判成违规")

        XCTAssertEqual(Self.interactiveTintOnTiles(in: [(path: "V/F.swift", content:
            "MetricTile(label: \"CPU\", value: v, tint: Theme.Semantic.accent.textColor)")]).count, 1,
                       "accent 涂在读数上没抓到 → 总工点名的那条病灶会漏")
        XCTAssertEqual(Self.interactiveTintOnTiles(in: [(path: "V/F.swift", content:
            "DisclosureGroup { x }.tint(Theme.Semantic.accent.textColor)")]).isEmpty, true,
                       "控件的 .tint() 用 accent 是合法交互语义，误伤就会被改回灰、丢掉可点性")

        XCTAssertEqual(Self.seriesColoredTiles(in: [(path: "V/F.swift", content:
            "tint: ChartSeries.color(ChartSeries.disk),")]).count, 1,
                       "序列色涂在数字上没抓到（HEAD 第 104/121 行就是这个形状）")
        XCTAssertTrue(Self.seriesColoredTiles(in: [(path: "V/F.swift", content:
            "MiniBarGauge(fraction: f, tint: role.graphicColor)")]).isEmpty,
                       "量表条与曲线用序列/语义色是合法的，不该被这条误伤")

        XCTAssertEqual(Self.areaOpacityDefinitionsNotUsingToken(in: [(path: "V/F.swift", content:
            "static let areaTopOpacity = 0.16")]).count, 1,
                       "字面量又回来了却没红 —— 正是「令牌定义了没人用」的复发形状")
        XCTAssertTrue(Self.areaOpacityDefinitionsNotUsingToken(in: [(path: "V/F.swift", content:
            "static let areaTopOpacity = Theme.Palette.Opacity.gradientAreaSoft")]).isEmpty,
                      "合规写法被误伤")
        XCTAssertTrue(Self.areaOpacityDefinitionsNotUsingToken(in: [(path: "V/F.swift", content:
            ".init(color: color.opacity(areaTopOpacity), location: 0)")]).isEmpty,
                      "使用处（没有 `=`）不该被当成定义行")

        XCTAssertEqual(Self.categoryPaletteUses(in: [(path: "V/F.swift", content:
            "LineMark(...).foregroundStyle(Theme.Chart.color(at: 0))")]).count, 1)

        XCTAssertEqual(Self.symbolCountPerStruct(named: "HealthRing(", in: [(path: "V/H.swift", content: """
            struct HealthHero: View {
                HealthRing(score: nil)
                HealthRing(score: 82)
            }
            """)])["V/H.swift.HealthHero"], 2,
                   "同一 struct 内两枚环没数出来 → 「一页两枚主角」判据失效")

        // 页头扫描器：本流真养过的那份形状必须被抓到，而普通视图不得误伤。
        XCTAssertEqual(Self.pageHeaderDeclarations(in: [(path: "Views/PerfLogs/Fake.swift", content:
            "struct PerfLogsPageHeader<Actions: View>: View {")]).count, 1,
                       "页头声明扫描器失灵 → 页面目录里的第二套页头会漏")
        XCTAssertTrue(Self.pageHeaderDeclarations(in: [(path: "Views/PerfLogs/Fake.swift", content: """
            struct LiveNumber: View {
            struct NoteLine: View {
            """)]).isEmpty, "普通视图被误判成页头 → 三家会被逼着把组件改名绕守卫")
    }

    func test_groupSpacingScannerCatchesTightContainerAndIgnoresLooseOne() {
        let dirty = """
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                GlassSection("系统资源") { tiles }
            }
            """
        let clean = """
            VStack(alignment: .leading, spacing: Theme.Spacing.group) {
                GlassSection("系统资源") { tiles }
            }
            """
        let nested = """
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                GlassSection("进程分组") {
                    Button { doThing() } label: { Text("x") }
                }
            }
            """
        let afterClose = """
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text("只有文字")
            }
            GlassSection("不相干") { x }
            """
        func one(_ text: String) -> [(path: String, content: String)] {
            [(path: "Views/Fake.swift", content: text)]
        }
        XCTAssertEqual(Self.containersTighteningGroups(in: one(dirty)).count, 1,
                       "16pt 包着 GlassSection 没抓到 → 这条判据是假的")
        XCTAssertTrue(Self.containersTighteningGroups(in: one(clean)).isEmpty,
                      "group(32) 被误伤，页面就不肯用 32 了")
        XCTAssertEqual(Self.containersTighteningGroups(in: one(nested)).count, 1,
                       "容器内部还有嵌套大括号时判据必须仍然看得见 GlassSection")
        XCTAssertTrue(Self.containersTighteningGroups(in: one(afterClose)).isEmpty,
                      "容器闭合之后的 GlassSection 不该算在它头上（块越界）")
    }

    func test_sourceScannerActuallySeesOwnedFiles() throws {
        let files = try ownedFiles()
        let paths = Set(files.map(\.path))
        for probe in ["Views/PerfLogs/ChartChrome.swift",
                      "Views/Performance/PerformanceSystemTiles.swift",
                      "Views/Health/HealthView.swift",
                      "Views/Logs/LogsView.swift"] {
            XCTAssertTrue(paths.contains(probe), "扫不到 \(probe)，路径口径变了")
        }
    }
}
