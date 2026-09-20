import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-P「简约无界」五页守卫（代码规模 / 复杂度风险 / Git 洞察 / 贡献者 / 依赖分析）。
///
/// **作用域**只限 `Views/Code`、`Views/Git`、`Views/Dependencies`、`Views/CodeGit`
/// 四个目录 = 本轮派发给 WS-P 的五页加它们的公共基座。`Design/**` 与 `App/Theme.swift`
/// 归总工，由既成的 `BorderlessSurfaceGuardTests` / `DesignTokenTests` 守，这里不重复。
///
/// ## 为什么断言长成这个样子
///
/// 四条主诉（不规整拥挤 / 滥用投影 / 整页发黑脏 / 没有主次）没有一条是「某页写错了」，
/// 全都是**同一套写法在五页各复制了一遍**。所以本文件没有一条"数量阈值"式断言
/// （那种只会逼人把违规挪到别处），每条都是「这种写法在本流目录里不该再有写法可以表达」：
///
/// - 主角只能有一枚，且 56pt 与纯墨只从一个原语 `DataHeroReadout` 出来。
/// - 分组节奏只能从命名容器 `DataPageScaffold` / `PageParagraph` / `GroupStack` 出来。
/// - 井只能包表格，且只能通过 `DataTableWell`；读数不得有面。
/// - 交互色只能待在交互件里。
///
/// ## 元测试是硬要求，不是仪式
///
/// 扫描型断言最经典的死法是「分母为空」：目录改名、界符写错、文件被移动，
/// 于是全部零命中、绿灯、债原样留着。本项目已经真栽过一次（这正是
/// `CodeGitRestyleTests.testRatchetPatternsActuallyDetectTheirOwnViolations` 存在的理由）。
/// 所以每个扫描器都配**双向**样本：脏样本必须被抓到，干净样本不得被误判；
/// 外加 `test_sourceScannerActuallyFindsFiles` 反向自证真读到了 13 个文件。
final class CodeGitBorderlessTests: XCTestCase {

    // MARK: - 页面归属表

    /// 五个页面各自包含哪些文件。`Code/CodeViewSupport.swift` 按主归属记在「代码规模」，
    /// `Git/GitInsightsCharts.swift` 记在「Git 洞察」。
    /// 若将来有人把第二枚主角塞进共用文件，这里会让该页变红 —— 那是 fail-safe，
    /// 正确反应是把主角挪回它自己的页面文件，不是给共用文件开豁免。
    static let pageFiles: [String: [String]] = [
        "代码规模": ["Code/CodeMetricsView.swift"],
        "复杂度风险": ["Code/CodeRiskView.swift", "Code/CodeRiskRows.swift"],
        "Git 洞察": ["Git/GitInsightsView.swift", "Git/GitInsightsSections.swift",
                     "Git/GitInsightsCharts.swift"],
        "贡献者": ["Git/ContributorsView.swift", "Git/ContributorRows.swift"],
        "依赖分析": ["Dependencies/DependenciesView.swift",
                     "Dependencies/DependencyVerdictRows.swift"],
    ]

    /// 本守卫的扫描目录。少扫一个就等于给那一页开后门。
    static let scannedDirs = ["Code", "Git", "Dependencies", "CodeGit"]

    /// 页面目录（不含公共基座 `CodeGit`）。`CodeGitRestyleTests.forbiddenRawValues`
    /// 里那几条 `pagesOnly` 禁令豁免基座，因为「不许页面写」的写法正是基座对外提供
    /// 实现的地方。本守卫沿用同一口径。
    static let pageDirs = ["Code", "Git", "Dependencies"]

    // MARK: - 扫描器（全是纯函数：喂 [(path, content)]，吐命中）

    /// 去掉整行注释，但**保留原始行号与缩进**。
    ///
    /// 行号必须一路带着走：先前有一版把注释行 `filter` 掉后再报 `index + 1`，
    /// 于是命中消息里的行号系统性偏小（报 121 实际 135）。报错误导人去找行，比不报错更糟。
    /// 缩进留给 `handRolledGroupContainers` 判父子关系用。
    static func numberedCodeLines(_ content: String) -> [(n: Int, text: String, indent: Int)] {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { index, raw in
                let text = String(raw)
                return (index + 1,
                        text.trimmingCharacters(in: .whitespaces),
                        text.prefix { $0 == " " || $0 == "\t" }.count)
            }
            .filter { !$0.text.hasPrefix("//") }
    }

    static func codeLines(_ content: String) -> [String] {
        numberedCodeLines(content).map(\.text)
    }

    /// 某段字面在哪些文件的哪些行出现。
    ///
    /// ⚠️ **needle 一律不带左括号**。SwiftUI 的容器视图绝大多数用尾随闭包调用
    /// （`DataReadoutBar { … }`、`DataTableWell { … }`），带 `(` 的 needle 对它们恒零命中，
    /// 于是断言「应该为零」的那几条会**永远绿**——本文件第一版就真的假绿在这一条上。
    static func hits(in files: [(path: String, content: String)],
                     containing needle: String) -> [String] {
        files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                entry.text.contains(needle) ? "\(file.path):\(entry.n)" : nil
            }
        }
    }

    /// `.tertiary` 的任何用法。
    ///
    /// 判据比验收口径**更严**：口径只要求「承载测得值的 `.tertiary` 归零」，
    /// 但「这一行是不是测得值」在多行插值的 `Text("共 \\(NumberFormat…) 次")` 上
    /// 靠逐行扫判不可靠（基座那份 `tertiaryOnMeasuredValues` 就是按行扫的，
    /// 且它至今只在合成样本上跑过、没接真源码）。与其留一条会漏的判据，
    /// 不如本流目录整体归零：在 `ground` 上 secondary 与 tertiary 相差不过几个 RGB 阶，
    /// 路径与时间戳改 `.secondary` 没有任何可读性损失。
    static func tertiaryUses(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: ".tertiary")
    }

    /// 裸字号。两种拼法都要抓：`Font.system(size:)` 与 `.font(.system(size:))`。
    /// 两者都在同一行内成形，逐行扫足够，不需要跨行拼接（拼反倒会吞掉行号）。
    static func bareSystemFonts(in files: [(path: String, content: String)]) -> [String] {
        let needles = ["Font.system(", ".system(size:"]
        return files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                needles.contains(where: entry.text.contains)
                    ? "\(file.path):\(entry.n): \(entry.text.prefix(60))" : nil
            }
        }
    }

    /// 大字档被页面直接取用的位置（`Typo.heroMetric` / `Typo.metricNumber`）。
    static func directBigTierUses(in files: [(path: String, content: String)],
                                  tokenNamed name: String) -> [String] {
        hits(in: files, containing: "Typo.\(name)")
    }

    /// `DataHeroReadout(` 的调用点。每页最多一枚 —— 56pt 出现两枚就是「两个主角」，
    /// 放不下就降 `metricMid`(22)，不许回头改令牌。
    static func heroCallSites(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: "DataHeroReadout")
    }

    /// `tint:` 传交互色或 info 色 —— 总工 2026-09-20 15:10 点名的那条：
    /// **M0 只改了 `MetricTile` 的默认值，而默认值盖不过显式传参**，
    /// 于是基座改绿了、页面照旧一片蓝。
    /// 合法的状态色（risk / severity / 增删）走 `role:` 形参，不在禁令里。
    static func dataTintedWithAccentOrInfo(in files: [(path: String,
                                                       content: String)]) -> [String] {
        let needles = ["tint: Theme.Semantic.accent", "tint: Theme.Semantic.info",
                       "tint: Theme.accent", "tint: Theme.info"]
        return files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                needles.contains(where: entry.text.contains)
                    ? "\(file.path):\(entry.n): \(entry.text.prefix(60))" : nil
            }
        }
    }

    /// 交互色落在**非交互件**上。
    ///
    /// 判据形状：`Theme.Semantic.accent` 只允许出现在名字以 `Button` / `Action` 结尾的
    /// 视图里 —— `CodeOpenFileButton` 合法，`GitCommitRow` 里给 SHA 涂蓝非法（那是一行文本，
    /// 不可点）。按 `struct` 声明切块，块名不在白名单即违规。
    /// 这条刻意按**名字**判而不是按目录判，所以基座里的 `DataDisclosureButton` 一样合法。
    static func accentOutsideInteractiveViews(in files: [(path: String,
                                                          content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            var found: [String] = []
            var current = "<文件头>"
            for (offset, line) in file.content.split(separator: "\n",
                                                      omittingEmptySubsequences: false)
                .enumerated() {
                let text = String(line).trimmingCharacters(in: .whitespaces)
                if text.hasPrefix("//") { continue }
                if text.contains("struct "), let name = declaredStructName(in: text) {
                    current = name
                }
                if text.contains("Theme.Semantic.accent"), !isInteractive(current),
                    !isBadgeRoleArgument(text) {
                    found.append("\(file.path):\(offset + 1): 在 \(current) 里用了 accent（\(text.prefix(52))）")
                }
            }
            return found
        }
    }

    static func declaredStructName(in line: String) -> String? {
        guard let start = line.range(of: "struct ") else { return nil }
        let name = line[start.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    static func isInteractive(_ structName: String) -> Bool {
        structName.hasSuffix("Button") || structName.hasSuffix("Action")
    }

    /// 徽标是「色 + 文字 + 图标」三通道的**状态**载体，`role:` 传 accent 表达的是
    /// 「选中 / 当前对象」（契约 5 明确保留的那侧），与给数字涂蓝不是一回事。
    /// 所以只放行这一个形状：同一行若改成 `.foregroundStyle(Theme.Semantic.accent…)`
    /// 仍然算违规 —— 放宽的是「徽标 role 形参」，不是「这行允许出现蓝」。
    static func isBadgeRoleArgument(_ line: String) -> Bool {
        line.contains("SemanticBadge(") && line.contains("role: Theme.Semantic.accent")
    }

    /// 井的用法只许在基座里（`DataTableWell` 是 `.contentInset` 在本流唯一合法出口）。
    /// 页面自己写一遍 = 面由页面各自决定，正是要消灭的「每页各摆一次」。
    static func wellsOutsideKit(in files: [(path: String, content: String)]) -> [String] {
        files.filter { !$0.path.hasPrefix("CodeGit/") }.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                entry.text.contains("contentInset") ? "\(file.path):\(entry.n)" : nil
            }
        }
    }

    /// 有列头的表必须待在井里 ——「表格要嵌进去」是本轮对表格的唯一观感要求。
    static func tablesWithoutWell(in files: [(path: String, content: String)]) -> [String] {
        files.filter { $0.content.contains("DataTableHeader(") }
            .filter { !$0.content.contains("DataTableWell") }
            .map(\.path)
    }

    /// 读数用了井 = 给聚合数字画了一层面（契约 3 把井限定给表格/日志/代码块）。
    static func readoutBarsUsed(in files: [(path: String, content: String)]) -> [String] {
        hits(in: files, containing: "DataReadoutBar")
    }

    /// 页面手写容器来排 `GlassSection` → 组间距不受任何命名档位管辖。
    ///
    /// 判据：`VStack(` / `LazyVGrid(` / `ScrollView` 之后 8 行内出现**缩进更深**的
    /// `GlassSection(` 即违规。缩进这一维不是可有可无 —— 少了它就分不清
    /// 「VStack 里排着 section」（要管）与「某个 section 的内容里有个 VStack，
    /// 它的兄弟节点恰好是下一个 section」（不该管）。第一版没判缩进，
    /// 真在 `CodeMetricsView.swift` 的 `CodeScaleSection` 上误报了一处。
    /// 合法写法只有 `DataPageScaffold` / `PageParagraph` / `GroupStack`，
    /// 它们的档位全在基座，改一处五页同时生效。
    static func handRolledGroupContainers(in files: [(path: String,
                                                      content: String)]) -> [String] {
        let openers = ["VStack(", "LazyVGrid(", "ScrollView"]
        let lookAhead = 8
        return files
            .filter { pageDirs.contains(String($0.path.prefix { $0 != "/" })) }
            .flatMap { file -> [String] in
                let lines = numberedCodeLines(file.content)
                guard lines.contains(where: { $0.text.contains("GlassSection(") }) else { return [] }
                var found: [String] = []
                for (index, entry) in lines.enumerated() {
                    guard openers.contains(where: entry.text.contains) else { continue }
                    let end = min(lines.count, index + 1 + lookAhead)
                    guard index + 1 < end else { continue }
                    let nests = lines[(index + 1)..<end].contains {
                        $0.text.contains("GlassSection(") && $0.indent > entry.indent
                    }
                    if nests {
                        found.append("\(file.path):\(entry.n): \(entry.text.prefix(56))")
                    }
                }
                return found
            }
    }

    // MARK: - 真源码定位

    private static let packageRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
    }()

    static func pageSourceFiles(dirs: [String] = CodeGitBorderlessTests.scannedDirs) throws
        -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
        var out: [(path: String, content: String)] = []
        for dir in dirs {
            let url = root.appendingPathComponent(dir)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []
            for name in names.sorted() where name.hasSuffix(".swift") {
                let file = url.appendingPathComponent(name)
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                out.append(("\(dir)/\(name)", text))
            }
        }
        return out
    }

    private static func files(forPage page: String,
                              in all: [(path: String, content: String)])
        -> [(path: String, content: String)] {
        let owned = Set(pageFiles[page] ?? [])
        return all.filter { owned.contains($0.path) }
    }

    /// 只留页面目录（去掉公共基座 `CodeGit/`）。
    /// 「某原语是否真被接线」这类判据必须在页面目录上算：基座自己含那些名字，
    /// 拿四目录全集判会得到一个永真的分母。
    static func pageOnly(_ all: [(path: String, content: String)])
        -> [(path: String, content: String)] {
        all.filter { pageDirs.contains(String($0.path.prefix { $0 != "/" })) }
    }

    // MARK: - ① 测得值上不得有 `.tertiary`

    func test_noTertiaryAnywhereOnTheFivePages() throws {
        let hits = Self.tertiaryUses(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "本流五页不得出现 .tertiary（\(hits.count) 处）：\n\(hits.joined(separator: "\n"))")
    }

    // MARK: - ② 无裸字号

    func test_noBareSystemFontsAnywhere() throws {
        let hits = Self.bareSystemFonts(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "出现裸字号，排版令牌的唯一消费入口被绕过：\(hits)")
        // 反向：收编之后必须真取到 11pt 等宽档，而不是"删掉了事"留个空洞。
        XCTAssertTrue(try Self.pageSourceFiles(dirs: ["CodeGit"])
                          .contains { $0.content.contains("Theme.Typo.monoLabel.font") },
                      "tableIdentifier 没收进 Theme.Typo.monoLabel，上面那条就成了死断言")
    }

    // MARK: - ③ 每页只有一枚主角

    func test_everyPageHasAtMostOneHeroReadout() throws {
        let all = try Self.pageSourceFiles()
        for page in Self.pageFiles.keys {
            let owned = Self.files(forPage: page, in: all)
            XCTAssertFalse(owned.isEmpty, "页面「\(page)」一个文件都没匹配上 —— 归属表过期了")
            let heroes = Self.heroCallSites(in: owned)
            XCTAssertLessThanOrEqual(heroes.count, 1,
                                     "页面「\(page)」有 \(heroes.count) 枚主角读数：\(heroes)")
        }
    }

    /// 56 与 34 只能从原语出来。页面自己写 = 绕过「纯墨」与「每页一枚」两条。
    func test_bigTiersAreNotUsedDirectlyInPages() throws {
        let pages = try Self.pageSourceFiles(dirs: Self.pageDirs)
        let hero = Self.directBigTierUses(in: pages, tokenNamed: "heroMetric")
        let number = Self.directBigTierUses(in: pages, tokenNamed: "metricNumber")
        XCTAssertTrue(hero.isEmpty, "页面自己写了 56pt，请改用 DataHeroReadout：\(hero)")
        XCTAssertTrue(number.isEmpty,
                      "页面自己写了 34pt。34pt 的唯一合法来源是读数带里的 MetricTile，"
                          + "否则第二主角会盖过本页主角：\(number)")
    }

    /// 主角原语本身不许被掏空：字号与纯墨两条都挂在它身上。
    func test_heroReadoutPrimitiveCarriesTheContract() throws {
        let kit = try Self.pageSourceFiles(dirs: ["CodeGit"])
        let hero = try XCTUnwrap(kit.first { $0.content.contains("struct DataHeroReadout") },
                                 "DataHeroReadout 没了 —— 主角约束失去了唯一落点")
        XCTAssertTrue(hero.content.contains("typed(Theme.Typo.heroMetric)"),
                      "主角没走 .typed(heroMetric)：56pt 档或行高已丢")
        XCTAssertTrue(hero.content.contains("Surface.ink"),
                      "主角不是纯墨。.primary 只有 85% 黑，全页最暗像素会落到小号正文上")
    }

    // MARK: - ④ 相邻分组间距 ≥ 24

    func test_groupGapsComeFromNamedBandsAndAreAtLeast24() throws {
        XCTAssertGreaterThanOrEqual(Theme.Spacing.group, 24, "主分组档必须 ≥ 24")
        XCTAssertGreaterThanOrEqual(Theme.Spacing.section, 24, "段落档必须 ≥ 24")
        XCTAssertGreaterThanOrEqual(Theme.Spacing.pageMargin, 24, "页边距必须 ≥ 24")

        let kit = try Self.pageSourceFiles(dirs: ["CodeGit"])
        let group = try XCTUnwrap(kit.first { $0.content.contains("struct GroupStack") },
                                  "GroupStack 没了 —— 页面就会各自写 VStack 来排分组")
        XCTAssertTrue(group.content.contains("Spacing.group"), "分组容器必须吃 group(32)")

        // 三档真的被五页用起来：只定义不接线 = spec §0 根因⑤ 原样复发
        let pages = try Self.pageSourceFiles(dirs: Self.pageDirs)
        let joined = pages.map(\.content).joined(separator: "\n")
        XCTAssertTrue(joined.contains("GroupStack"),
                      "没有页面用 GroupStack → 分组档仍是零引用死令牌")
        XCTAssertTrue(joined.contains("Theme.Page.Scaffold"),
                      "没有页面走基座骨架 → 24/32/40 三档对这一页完全不生效")
    }

    /// 页骨架只许一份，且必须住在 `Design/`（总工 `48443d9` 的裁定）。
    /// 本流原来那份 `DataPageScaffold` 是基座的逐字复制品，已由 WS-P 自删。
    /// 这条防的是"顺手又造一份"：`BorderlessSurfaceGuardTests` 那份要等 M2 闸门才生效，
    /// 在那之前本流目录里再长出第二份骨架是没人拦的。
    func test_thisStreamDeclinesNoSecondPageScaffold() throws {
        let hits = Self.pageScaffoldDeclarations(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "本流四目录里又出现了页骨架声明（只许 Design/ 那一份）：\(hits)")
    }

    /// 扫描器本身形状对不对 —— 基座那份必须能被它认出来，否则上面那条是永真绿。
    static func pageScaffoldDeclarations(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                guard entry.text.hasPrefix("struct "), entry.text.contains(": View") else { return nil }
                return (entry.text.contains("Scaffold") || entry.text.contains("BorderlessPage"))
                    ? "\(file.path):\(entry.n)" : nil
            }
        }
    }

    func test_pagesDoNotHandRollTheirGroupContainers() throws {
        let hits = Self.handRolledGroupContainers(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "页面自己摆了个容器来排 GlassSection，组间距不受档位管辖：\n"
                          + hits.joined(separator: "\n"))
    }

    /// 每页必须真走骨架，否则上面几条对那一页全是空跑。
    func test_everyPageUsesTheScaffold() throws {
        let all = try Self.pageSourceFiles()
        for (page, owned) in Self.pageFiles {
            let entries = Self.files(forPage: page, in: all).filter {
                $0.path.hasSuffix("View.swift")
            }
            XCTAssertFalse(entries.isEmpty, "页面「\(page)」找不到入口文件：\(owned)")
            for entry in entries {
                XCTAssertTrue(entry.content.contains("Theme.Page.Scaffold"),
                              "页面「\(page)」的 \(entry.path) 没走基座唯一骨架 Theme.Page.Scaffold")
            }
        }
    }

    // MARK: - ⑤ 倾向色只承载语义（总工 15:10 追加）

    func test_tilesAreNotTintedWithAccentOrInfo() throws {
        let hits = Self.dataTintedWithAccentOrInfo(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "读数被涂成交互色/信息色。显式传参会盖掉基座新默认，于是照旧一片蓝：\n"
                          + hits.joined(separator: "\n"))
    }

    func test_accentOnlySitsOnInteractiveViews() throws {
        let hits = Self.accentOutsideInteractiveViews(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "交互色出现在非交互件上。契约 5 是「结构去色、语义留色」，"
                          + "而 accent 的语义是「可点」：\n" + hits.joined(separator: "\n"))
    }

    // MARK: - ⑥ 面只剩井，且井只包表格

    func test_noWellOutsideTheKit() throws {
        let hits = Self.wellsOutsideKit(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "页面自己画井。本流唯一合法出口是基座的 DataTableWell：\(hits)")
    }

    func test_everyTableSitsInAWell() throws {
        let hits = Self.tablesWithoutWell(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty, "有列头却没嵌进井：\(hits)")
    }

    func test_readoutsHaveNoSurface() throws {
        let hits = Self.readoutBarsUsed(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "读数条仍走 DataReadoutBar（它给数字画了一层井）。改 DataReadoutBand：\(hits)")
    }

    /// 我引进的原语必须真有人用，否则本守卫的若干「零命中即通过」会变成空跑。
    func test_newPrimitivesAreActuallyWired() throws {
        let pages = try Self.pageSourceFiles(dirs: Self.pageDirs)
        for needle in ["DataReadoutBand", "DataTableWell", "DataFootnote", "GroupStack"] {
            XCTAssertTrue(pages.contains { $0.content.contains(needle) },
                          "基座原语 \(needle) 没有任何页面在用 —— 它要么该删，要么五页还没改完")
        }
    }

    // MARK: - 元测试：确认每个扫描器都不是假绿

    func test_scannersCatchSyntheticViolations() {
        // ① .tertiary
        XCTAssertEqual(Self.tertiaryUses(in: [("Code/A.swift",
                                               "Text(x).foregroundStyle(.tertiary)")]),
                       ["Code/A.swift:1"], "测得值上的 tertiary 没抓到")
        XCTAssertTrue(Self.tertiaryUses(in: [("Code/A.swift", "// .tertiary 是旧写法")]).isEmpty,
                      "注释被误判 —— 文档将无法解释自己禁了什么")

        // ② 裸字号
        XCTAssertEqual(Self.bareSystemFonts(in: [("Code/A.swift",
                                                  "let f = Font.system(size: 11)")]).count, 1,
                       "裸字号没抓到")
        XCTAssertEqual(Self.bareSystemFonts(in: [("Code/A.swift",
                                                  "Text(x).font(.system(size: 9))")]).count, 1,
                       "语义字面写法没抓到")
        XCTAssertTrue(Self.bareSystemFonts(in: [("Code/A.swift",
                                                 "// 旧写法 Font.system(size: 11)")]).isEmpty,
                      "注释里的裸字号被误判")
        XCTAssertTrue(Self.bareSystemFonts(in: [("Code/A.swift",
                                                 "let f = Theme.Typo.monoLabel.font")]).isEmpty,
                      "收编之后的合法写法被判违规")

        // ③ 主角
        let twoHeroes = [("Code/A.swift",
                          "DataHeroReadout(value: a)\nDataHeroReadout(value: b)")]
        XCTAssertEqual(Self.heroCallSites(in: twoHeroes).count, 2,
                       "两枚主角没数出来 —— 「每页一枚」会变成空断言")
        XCTAssertEqual(Self.directBigTierUses(in: [("Code/A.swift",
                                                    ".font(Theme.Typo.heroMetric.font)")],
                                              tokenNamed: "heroMetric").count, 1,
                       "绕过原语的 56pt 没抓到")

        // ④ 手写容器
        let dirtyStack = "VStack(spacing: 16) {\n"
            + "    GlassSection(\"甲\") { EmptyView() }\n"
            + "    GlassSection(\"乙\") { EmptyView() }\n}"
        XCTAssertEqual(Self.handRolledGroupContainers(in: [("Code/A.swift", dirtyStack)]).count, 1,
                       "页面自己排 GlassSection 没抓到 → 间距档位形同虚设")
        let namedStack = "Theme.Page.Scaffold {\n"
            + "    GroupStack {\n"
            + "        GlassSection(\"甲\") { EmptyView() }\n"
            + "    }\n}"
        XCTAssertTrue(Self.handRolledGroupContainers(in: [("Code/A.swift", namedStack)]).isEmpty,
                      "命名容器被误判 —— 合法写法将无法表达")
        // 缩进这一维的真样本：section **内部**的 VStack，它的兄弟节点恰好是下一个 section。
        // 不判缩进就会误报（本文件第一版就真的误报了 CodeMetricsView.swift:151）。
        let innerStack = "GlassSection(\"代码规模\") {\n"
            + "    VStack(alignment: .leading, spacing: Theme.Spacing.md) {\n"
            + "        DataHeroReadout(value: \"1\")\n"
            + "    }\n"
            + "}\n"
            + "GlassSection(\"语言构成\") {\n    EmptyView()\n}"
        XCTAssertTrue(Self.handRolledGroupContainers(in: [("Code/A.swift", innerStack)]).isEmpty,
                      "section 内部的 VStack 被误判成手排容器 —— 缩进这一维丢了")
        XCTAssertTrue(Self.handRolledGroupContainers(in: [("CodeGit/Kit.swift", dirtyStack)]).isEmpty,
                      "基座被误判 —— 容器实现本来就只许写在基座里")

        // ④b 页骨架重复：脏样本必须认得出来，否则「本流不得有第二份」是永真绿
        XCTAssertEqual(Self.pageScaffoldDeclarations(in: [("CodeGit/Kit.swift",
            "struct DataPageScaffold<Content: View>: View {\n    var body: some View { EmptyView() }\n}")]),
                       ["CodeGit/Kit.swift:1"], "第二份页骨架没认出来 —— 那条断言是假的")
        XCTAssertTrue(Self.pageScaffoldDeclarations(in: [("CodeGit/Kit.swift",
            "struct GroupStack<Content: View>: View {\n    var body: some View { EmptyView() }\n}")]).isEmpty,
                      "普通容器被判成页骨架 —— 五页会因此写不出分组")
        XCTAssertTrue(Self.pageScaffoldDeclarations(in: [("CodeGit/Kit.swift",
            "Theme.Page.Scaffold {\n}  // 用法不是声明，不该算一份")]).isEmpty,
                      "骨架的**调用点**被当成声明 —— 那五页必然全红")

        // ⑤ 倾向色
        let accentTint = [("Code/A.swift", "tint: Theme.Semantic.accent.textColor)")]
        XCTAssertEqual(Self.dataTintedWithAccentOrInfo(in: accentTint).count, 1,
                       "tile 显式传 accent 没抓到 —— 本轮蓝数字的直接成因")
        let infoTint = [("Code/A.swift", "MetricTile(label: x, tint: Theme.Semantic.info.textColor)")]
        XCTAssertEqual(Self.dataTintedWithAccentOrInfo(in: infoTint).count, 1,
                       "tile 显式传 info 没抓到")
        let roleTint = [("Code/A.swift", "role: Theme.Semantic.danger")]
        XCTAssertTrue(Self.dataTintedWithAccentOrInfo(in: roleTint).isEmpty,
                      "状态语义色被误判 —— 风险与增删必须留色")

        let shaRow = "struct GitCommitRow: View {\n"
            + "    var body: some View {\n"
            + "        Text(sha).foregroundStyle(Theme.Semantic.accent.textColor)\n"
            + "    }\n}"
        XCTAssertEqual(Self.accentOutsideInteractiveViews(in: [("Git/A.swift", shaRow)]).count, 1,
                       "非交互件涂 accent 没抓到")
        let openButton = "struct CodeOpenFileButton: View {\n"
            + "    var body: some View {\n"
            + "        Button {} label: { icon.foregroundStyle(Theme.Semantic.accent.textColor) }\n"
            + "    }\n}"
        XCTAssertTrue(Self.accentOutsideInteractiveViews(in: [("Code/A.swift", openButton)]).isEmpty,
                      "按钮上的 accent 被判违规 —— 交互本身就是语义，蓝就是它的意思")
        XCTAssertTrue(Self.accentOutsideInteractiveViews(in: [("Code/A.swift",
                                                               "// 见 Theme.Semantic.accent 的讨论")]).isEmpty,
                      "注释被误判")
        XCTAssertEqual(Self.declaredStructName(in: "struct GitCommitRow: View {"), "GitCommitRow",
                       "块名解析失灵，上面两条 accent 判据会一起失真")
        XCTAssertTrue(Self.isInteractive("CodeOpenFileButton"))
        XCTAssertFalse(Self.isInteractive("GitCommitRow"))

        // ⑤b 徽标 role: accent 是「选中态」，放行的是这个形状，不是整行
        let badgeRow = "struct GitNestedCandidateRow: View {\n"
            + "    SemanticBadge(\"当前分析对象\", role: Theme.Semantic.accent, icon: .info)\n}"
        XCTAssertTrue(Self.accentOutsideInteractiveViews(in: [("Git/A.swift", badgeRow)]).isEmpty,
                      "徽标的 role: accent 被判违规 —— 它标的是选中态，属契约 5 保留侧")
        let textRow = "struct GitNestedCandidateRow: View {\n"
            + "    Text(x).foregroundStyle(Theme.Semantic.accent.textColor)\n}"
        XCTAssertEqual(Self.accentOutsideInteractiveViews(in: [("Git/A.swift", textRow)]).count, 1,
                      "同一非交互视图里的文本涂蓝没抓到 —— 说明放行做宽了，整行都放过了")
        XCTAssertFalse(Self.isBadgeRoleArgument("Text(x).role(Theme.Semantic.accent)"),
                       "没有 SemanticBadge 也算徽标，会放过任意一行")

        // ⑥ 面
        XCTAssertEqual(Self.wellsOutsideKit(in: [("Git/A.swift",
                                                  ".surface(layer: .contentInset)")]).count, 1,
                       "页面自己画井没抓到")
        XCTAssertTrue(Self.wellsOutsideKit(in: [("CodeGit/Kit.swift",
                                                 ".surface(layer: .contentInset)")]).isEmpty,
                      "基座里的井被判违规 —— DataTableWell 就没法写了")
        XCTAssertEqual(Self.tablesWithoutWell(in: [("Code/A.swift",
                                                    "DataTableHeader(columns: c)")]),
                       ["Code/A.swift"], "有列头没进井没抓到")
        XCTAssertTrue(Self.tablesWithoutWell(in: [("Code/A.swift",
                                                   "DataTableWell { DataTableHeader(columns: c) }")]).isEmpty,
                      "进了井的表被判违规")
        XCTAssertEqual(Self.readoutBarsUsed(in: [("Code/A.swift", "DataReadoutBar { }")]).count, 1,
                       "读数条画井没抓到")
    }

    /// 反向自证：扫描器真读到了文件。否则本文件所有「空 = 通过」的断言集体假绿。
    func test_sourceScannerActuallyFindsFiles() throws {
        let all = try Self.pageSourceFiles()
        XCTAssertEqual(all.count, 13,
                       "本流应有 13 个视图文件（Code 4 / Git 5 / Dependencies 2 / CodeGit 2）；"
                          + "数量变了说明有文件被新增或删除（CodeGitRestyleTests 钉着同一个数）")
        for dir in Self.scannedDirs {
            XCTAssertTrue(all.contains { $0.path.hasPrefix("\(dir)/") },
                          "扫不到 \(dir)/ —— 该目录的全部断言会变成空跑")
        }
        for (page, owned) in Self.pageFiles {
            for name in owned {
                XCTAssertTrue(all.contains { $0.path == name },
                              "页面「\(page)」的 \(name) 不在扫描结果里，该页的主角数会被静默少算")
            }
        }
        XCTAssertFalse(Self.heroCallSites(in: Self.pageOnly(all)).isEmpty,
                       "五页里没有一枚 DataHeroReadout —— 主角约束根本没接线。\n"
                          + "（必须在**页面目录**上判，不是四目录全集：基座里 `struct DataHeroReadout` "
                          + "本身含这个名字，拿全集判会永远为真。）")
        // 真源码里必须仍能扫到至少一处「合法」的井（基座的 DataTableWell），
        // 否则「井只包表格」这一族判据是在跟空集合说话。
        XCTAssertTrue(try Self.pageSourceFiles(dirs: ["CodeGit"])
                          .contains { $0.content.contains("contentInset") },
                      "基座里已经没有井了 —— wellsOutsideKit 变成永真")
    }
}
