import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - WS-O 外壳与总览的「简约无界」守卫
//
// 权威 = `docs/superpowers/specs/2026-09-20-borderless-minimal-ui-redesign-design.md`
// §1 风格契约 1/4/6/7/8、§3 导航、§4.1 总览病灶，与实施计划 Task 6 的四条验收判据。
//
// 与 `BorderlessSurfaceGuardTests`（基座侧）的分工：那套管 `Design/**` 的画法，
// 这套管**外壳与总览这两片页面**。两边的尺子刻意不共用同一套判据形状 ——
// 同一个病灶用两把不同的尺子量，一把瞎了另一把还在（证据见
// `test_tertiaryScannerSeesWhatTheBaseLineScannerMisses`）。
//
// 每条扫描型断言都配元测试：造违规样本确认它会红、造合法样本确认它不误伤。
// 理由见记忆《扫描型测试要配元测试》——本轮病因之一就是「令牌定义了但零引用」，
// 只查「有没有散写魔法数」的守卫查不出「改了但没生效」，也查不出「扫不到东西」。

final class ShellBorderlessTests: XCTestCase {

    // MARK: - 路径与扫描面

    /// 包根。测试文件在 `Tests/TcoderMonitorTests/` 下，回溯三级（与 `ShellDesignTests` 同一套写法）。
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    private static var viewsDir: URL {
        packageRoot.appendingPathComponent("Sources/TcoderMonitor/Views")
    }

    /// 本流名下文件：3 个外壳页面 + `Shell/` 下 5 个分件。
    /// 分母钉死：扫不到文件时，下面所有「没扫到就算通过」的断言会集体假绿。
    static func shellSources() throws -> [(path: String, content: String)] {
        let pages = ["RootView.swift", "ProjectDetailView.swift", "DashboardView.swift"]
        let shellDir = viewsDir.appendingPathComponent("Shell")
        let shell = try FileManager.default.contentsOfDirectory(
            at: shellDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
            .map(\.lastPathComponent)
            .sorted()
        let names = pages + shell
        XCTAssertEqual(names.count, 8, "外壳扫描集分母变了（应为 3 页面 + 5 分件）：\(names)")
        return try names.map { name in
            let url = pages.contains(name)
                ? viewsDir.appendingPathComponent(name)
                : shellDir.appendingPathComponent(name)
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(text.isEmpty, "\(name) 读出来是空的，扫描等于没扫")
            return (path: name, content: text)
        }
    }

    /// 全仓实现文件（相对 `Sources/TcoderMonitor`）。
    static func allSources() throws -> [(path: String, content: String)] {
        let root = packageRoot.appendingPathComponent("Sources/TcoderMonitor")
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let urls = walker?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(urls.isEmpty, "扫不到 \(root.path) —— 路径口径变了，这条守卫会假绿")
        return urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.path.replacingOccurrences(of: root.path + "/", with: ""), text)
        }
    }

    // MARK: - 扫描器（纯函数，喂合成输入即可双向元测试）

    /// 整行注释？扫源码文本的判据都必须先过这一道，否则注释里正当提到的被禁写法会误判。
    static func isComment(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("//")
    }

    /// 行首缩进（空格数）。用来判断一行属于哪一条 modifier 链。
    static func indent(of line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// ① 某个符号在**代码**里被使用的行数（整行注释豁免）。
    static func symbolUses(_ symbol: String,
                           in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    let line = String(raw)
                    guard !isComment(line), line.contains(symbol) else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    /// ③ 落在「承载测得值的 Text 块」上的 `.tertiary`。
    ///
    /// 判据形状比基座那把尺子**更严**：基座要求 marker 与 `.tertiary` 在**同一行**，
    /// 而 SwiftUI 的 modifier 天生一行一条，`Text(NumberFormat.grouped(n))` 换行再
    /// `.foregroundStyle(.tertiary)` 是页面里最常见的写法 —— 那种形状基座扫不到。
    static let measuredMarkers = ["DataAbsence", "NumberFormat", "ByteFormat",
                                  "percentOf100", "value:", "codeLines", "linePercent"]

    static func tertiaryInMeasuredTextBlocks(
        in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var hits: [String] = []
            for (row, line) in lines.enumerated() {
                guard line.contains(".tertiary"), !isComment(line) else { continue }
                guard let block = textBlock(lines, at: row),
                      measuredMarkers.contains(where: { block.contains($0) }) else { continue }
                hits.append("\(file.path):\(row + 1)")
            }
            return hits
        }
    }

    /// 真调用了 `isReachable(reportAvailable:)` 的文件名。整行注释不算 ——
    /// 否则「把测试删了、换一段说明文字」这条最容易走的回头路会一路绿灯。
    static func isReachableCallers(in files: [(path: String, content: String)]) -> [String] {
        files.filter { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .contains { !isComment(String($0)) && String($0).contains("isReachable(reportAvailable:") }
        }.map(\.path)
    }

    /// 取第 `row` 行所属的那一个视图块（含它的整条 modifier 链），已剥注释。
    ///
    /// 块界靠缩进，而不是靠数括号：SwiftUI 里同一条链的 modifier 比宿主行深一档，
    /// 下一块的宿主行与上一块的宿主行**同档** —— 这就是天然的界。
    /// 回溯时跳过以 `.` 开头的行（那是 modifier 续行，不是块首）。
    static func textBlock(_ lines: [String], at row: Int, lookback: Int = 20) -> String? {
        let chainIndent = indent(of: lines[row])
        var start = row
        while start >= 0 && row - start <= lookback {
            let candidate = lines[start]
            if !isComment(candidate), indent(of: candidate) <= chainIndent,
               !candidate.trimmingCharacters(in: .whitespaces).hasPrefix(".") {
                break
            }
            if isBlank(candidate) { return nil }
            start -= 1
        }
        guard start >= 0, !isComment(lines[start]) else { return nil }
        let base = indent(of: lines[start])
        var end = row
        while end + 1 < lines.count {
            let next = lines[end + 1]
            if isBlank(next) { break }
            if !isComment(next), indent(of: next) <= base { break }
            end += 1
        }
        return lines[start...end].filter { !isComment($0) }.joined(separator: "\n")
    }

    static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// `Theme.Spacing.<成员>` 的字面量解算表。不把阈值写死在测试里：
    /// 令牌的真实取值改了，守卫必须跟着变，而不是冻成一个和源码无关的数字。
    static let spacingValues: [String: CGFloat] = [
        "xxs": Theme.Spacing.xxs, "xs": Theme.Spacing.xs, "sm": Theme.Spacing.sm,
        "md": Theme.Spacing.md, "lg": Theme.Spacing.lg, "xl": Theme.Spacing.xl,
        "xxl": Theme.Spacing.xxl, "section": Theme.Spacing.section,
        "gutter": Theme.Spacing.gutter, "chip": Theme.Spacing.chip,
        "cardPadding": Theme.Spacing.cardPadding, "tilePadding": Theme.Spacing.tilePadding,
        "group": Theme.Spacing.group, "pageMargin": Theme.Spacing.pageMargin,
    ]

    /// 从 `marker`（某段声明的开头）到它配平的那个 `}`。
    /// 只量**页面级**容器：组内条目用小间距是合法用法，把它们一起判红，
    /// 下一步一定是有人为了过门去放宽阈值。
    static func region(in text: String, startingAt marker: String) -> String? {
        guard let head = text.range(of: marker) else { return nil }
        var depth = 0
        var scanned = ""
        for char in text[head.lowerBound...] {
            scanned.append(char)
            if char == "{" { depth += 1 }
            if char == "}" {
                depth -= 1
                if depth == 0 { return scanned }
            }
        }
        return nil
    }

    /// ④ 一段页面级布局里小于 `minimum` 的容器间距。
    /// 认两种写法：`spacing: Theme.Spacing.<成员>`（查成员真实取值）与
    /// `spacing: 数字`（裸数字本来就不该出现在页面里）。
    static func tightSpacings(in region: String, minimum: CGFloat) -> [String] {
        region.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            .compactMap { index, raw in
                let line = String(raw)
                guard !isComment(line), let range = line.range(of: "spacing:") else { return nil }
                let tail = line[range.upperBound...]
                if let token = spacingValues.keys.sorted().first(where: { tail.contains($0) }),
                   let value = spacingValues[token] {
                    return value < minimum ? "L\(index + 1) Theme.Spacing.\(token)=\(value)" : nil
                }
                let digits = tail.drop(while: { $0 == " " }).prefix { $0.isNumber || $0 == "." }
                if let literal = Double(digits), !digits.isEmpty {
                    return CGFloat(literal) < minimum ? "L\(index + 1) 裸值 \(literal)" : nil
                }
                return nil
            }
    }

    /// 总览页面级布局的三段：页 body + 两个段落装配器。
    /// 只量 `body` 会让「把拥挤挪进 scaleSegment」也算通过。
    static let overviewLayoutMarkers = [
        "var body: some View {",
        "private var scaleSegment: some View {",
        "private var listSegment: some View {",
    ]

    // MARK: - ① chip 条已删，而取证依赖的那几样东西原样在场

    func test_chipBarSymbolsAreGoneFromEverywhere() throws {
        let files = try Self.allSources()
        XCTAssertGreaterThan(files.count, 100, "只扫到 \(files.count) 个文件，路径口径可疑")
        for symbol in ["SectionNavBar", "SectionNavChip"] {
            let hits = Self.symbolUses(symbol, in: files)
            XCTAssertTrue(hits.isEmpty,
                          "九页导航已搬进侧栏，\(symbol) 还在被引用：\(hits)")
        }
    }

    /// 删的是**呈现层**，不是九页模型。这三样是九页取证的承重墙：
    /// `capture_pages_isolated.sh` 靠 `-selectedDetailSection <中文页名>` 传页，
    /// 键名或页名一改，拍出来的九张图会全是同一页。
    func test_ninePageModelSurvivedTheChipBarRemoval() throws {
        let sources = try Self.shellSources()
        let sectionNav = try XCTUnwrap(
            sources.first { $0.path == "SectionNav.swift" },
            "SectionNav.swift 不能删：README 与 docs 用 `SectionNav.DetailSection` 定位九页")
        XCTAssertTrue(sectionNav.content.contains("enum DetailSection"),
                      "DetailSection 枚举必须还在原文件里")
        XCTAssertTrue(sectionNav.content.contains("func isReachable(reportAvailable: Bool)"),
                      "isReachable 纯函数不许跟着 chip 条一起删掉")

        for name in ["ProjectDetailView.swift", "ProjectSidebar.swift"] {
            let text = try XCTUnwrap(sources.first { $0.path == name }).content
            XCTAssertTrue(text.contains(#""selectedDetailSection""#),
                          "\(name) 丢了 @AppStorage(\"selectedDetailSection\") 键名 → 取证传页失效")
        }

        let expected = ["总览", "代码规模", "复杂度风险", "Git 洞察", "贡献者",
                        "性能监控", "错误日志", "依赖分析", "健康评分"]
        XCTAssertEqual(DetailSection.allCases.map(\.rawValue), expected,
                       "中文页名顺序就是取证脚本的拍图顺序，动一个字九页图就错位")
    }

    /// 两把尺子：源码枚举与取证脚本各自的页名清单必须逐条相等。
    /// 只在源码里自查的话，脚本那一侧改了一页名字我们永远看不见。
    func test_captureScriptPageNamesMatchTheSourceEnum() throws {
        let script = Self.packageRoot.appendingPathComponent("scripts/capture_pages_isolated.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("SECTIONS=(") }),
              let head = line.range(of: "SECTIONS=(")
        else { return XCTFail("取证脚本里找不到 SECTIONS=( ……) 这一行，判据失效") }
        let names = line[head.upperBound...].split(separator: "\"")
            .filter { $0.count >= 2 }.map(String.init)
        XCTAssertEqual(names, DetailSection.allCases.map(\.rawValue),
                       "脚本页名与 DetailSection 不再一一对应")
    }

    // MARK: - ② `isReachable` 仍有测试钉住

    func test_isReachableStillHasTestCoverage() throws {
        let dir = Self.packageRoot.appendingPathComponent("Tests/TcoderMonitorTests")
        let urls = try FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThanOrEqual(urls.count, 50, "只扫到 \(urls.count) 个测试文件")
        let files: [(path: String, content: String)] = urls.compactMap { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            return (url.lastPathComponent, text)
        }
        let callers = Self.isReachableCallers(in: files)
        XCTAssertFalse(callers.isEmpty,
                       "没有任何测试再调 isReachable(reportAvailable:) —— 那条「性能页永远可达、"
                       + "其余页要先扫」的口径失去守卫；chip 条一删，连禁用逻辑都可能被顺手删干净")
    }

    /// 反向自证：判据写错形状（漏参数标签、或把注释也算成调用）时，上一条会假绿。
    func test_isReachableCoverageProbeActuallyDiscriminates() {
        XCTAssertEqual(Self.isReachableCallers(in: [("A.swift",
                         "section.isReachable(reportAvailable: false)")]),
                       ["A.swift"], "探针失灵：真调用没认出来")
        XCTAssertTrue(Self.isReachableCallers(in: [("B.swift",
                        "// section.isReachable(reportAvailable:) 的历史说明")]).isEmpty,
                      "把注释也算成调用 → 删掉测试、只留一段说明文字，守卫照样绿")
        XCTAssertTrue(Self.isReachableCallers(in: [("C.swift",
                        "func isReachable(_ available: Bool) { }")]).isEmpty,
                      "重新签名而不带参数标签，也算失去了这条口径")
    }

    // MARK: - ③ 测得值上不得有 `.tertiary`

    func test_measuredValuesAreNeverTertiaryInShellLayer() throws {
        let hits = Self.tertiaryInMeasuredTextBlocks(in: try Self.shellSources())
        XCTAssertTrue(hits.isEmpty,
                      "总览/外壳里承载测得值的 Text 用了 .tertiary：\(hits)")
    }

    /// 元测试：这条判据真的会红，而且比基座那把尺子多看见一种形状。
    func test_tertiaryScannerSeesWhatTheBaseLineScannerMisses() {
        let chained = [(path: "Views/Fake.swift", content: """
        Text(NumberFormat.grouped(code.codeLines))
            .font(Theme.Typo.metricNumber.font)
            .foregroundStyle(.tertiary)
        """)]
        XCTAssertEqual(Self.tertiaryInMeasuredTextBlocks(in: chained), ["Views/Fake.swift:3"],
                       "跨行的测得值 .tertiary 没抓到 → 守卫是假绿")
        XCTAssertEqual(BorderlessSurfaceGuardTests.tertiaryOnMeasuredValues(in: chained), [],
                       "基座那把尺子现在也看得见这一行了 —— 两把尺子的盲区已经重合，"
                       + "请重新错开判据（本条断言的意义就是钉住「不许共用盲区」）")

        let statLine = [(path: "Views/Fake.swift", content: """
        StatLine(label: "生产码行覆盖",
            value: DataAbsence.optional(percent).display)
            .foregroundStyle(.tertiary)
        """)]
        XCTAssertEqual(Self.tertiaryInMeasuredTextBlocks(in: statLine).count, 1,
                       "value: 里是测得值，跨行的形状也必须抓到")

        let legalPath = [(path: "Views/Fake.swift", content: """
        Text(project.path)
            .font(Theme.Typo.label.font)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
        """)]
        XCTAssertTrue(Self.tertiaryInMeasuredTextBlocks(in: legalPath).isEmpty,
                      "路径是元数据，用 .tertiary 合法 —— 误伤会把守卫逼成豁免")

        let legalTimestamp = [(path: "Views/Fake.swift", content: """
        Text("·")
            .foregroundStyle(.tertiary)
        Text(DataAbsence.optional(value).display)
            .font(Theme.Typo.monoSmall.font)
        """)]
        XCTAssertTrue(Self.tertiaryInMeasuredTextBlocks(in: legalTimestamp).isEmpty,
                      "块界吃过了：间隔点的 .tertiary 被下面那个 DataAbsence 读数误伤")
    }

    // MARK: - ④ 组间必须有呼吸

    func test_overviewPageLayoutHasNoTightGroupSpacing() throws {
        let dashboard = try XCTUnwrap(
            Self.shellSources().first { $0.path == "DashboardView.swift" }).content
        var scanned = 0
        var tight: [String] = []
        for marker in Self.overviewLayoutMarkers {
            let region = try XCTUnwrap(Self.region(in: dashboard, startingAt: marker),
                                       "定位不到 \(marker) —— 布局被改成了别的形状，这条守卫会假绿")
            scanned += region.split(separator: "\n").filter { $0.contains("spacing:") }.count
            tight += Self.tightSpacings(in: region, minimum: Theme.Spacing.group).map {
                "\(marker.dropLast(2)) → \($0)"
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 3,
                                    "页面级布局里只扫到 \(scanned) 处 spacing: —— 判据面太小，等于没量")
        XCTAssertTrue(tight.isEmpty,
                      "总览页面级容器间距 < \(Int(Theme.Spacing.group))pt（风格契约 8「分组间 32」）：\(tight)")
    }

    func test_spacingAndSurfaceTokensAreWiredIntoTheShellLayer() throws {
        let joined = try Self.shellSources().map(\.content).joined(separator: "\n")
        for token in ["Spacing.group", "Spacing.pageMargin",
                      "Palette.Surface.ground", "Palette.Surface.ink"] {
            XCTAssertTrue(joined.contains(token),
                          "\(token) 在外壳/总览里零引用 —— 基座定义了没人用，正是上一轮的病因复发")
        }
        // `Spacing.section`(40) 不再要求页面自己写：它住在**唯一那份页骨架**里。
        // 页面再自己铺一遍顶底段落，就是第五份骨架（见下一条）。
    }

    /// 页骨架只许一份（main `48443d9`）。实测并存过三份同职责骨架
    /// （基座 `Theme.Page.Scaffold`、`CodeGitDesignKit.DataPageScaffold` 逐字复制品、
    /// WS-W 的 `Views/PerfLogs/BorderlessPage.swift`）—— 用户原话「不要东一个系一个」。
    /// 总览原来那份 `ScrollView + VStack + padding + 限宽` 是第四份，本轮改回基座。
    static func handRolledScaffolds(in files: [(path: String, content: String)]) -> [String] {
        files.filter { file in
            file.content.contains("ScrollView {") && !file.content.contains("Page.Scaffold")
        }.map(\.path)
    }

    func test_overviewPageUsesTheSingleBaseScaffold() throws {
        let handRolled = Self.handRolledScaffolds(in: try Self.shellSources())
        XCTAssertTrue(handRolled.isEmpty,
                      "这些文件自己写了一遍页骨架，请改用 `Theme.Page.Scaffold`：\(handRolled)")
        let dashboard = try XCTUnwrap(
            Self.shellSources().first { $0.path == "DashboardView.swift" }).content
        XCTAssertTrue(dashboard.contains("Theme.Page.Scaffold(maxWidth: Theme.Layout.maxWidthOverview"),
                        "总览没接基座页骨架，或限宽档没走 overview（1200）")
    }

    func test_scaffoldScannerCatchesSyntheticDuplication() {
        let handRolled = [(path: "Views/FakeView.swift", content: """
        struct FakeView: View {
            var body: some View {
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.md) { content }
                        .padding(.horizontal, Theme.Spacing.md)
                }
            }
        }
        """)]
        XCTAssertEqual(Self.handRolledScaffolds(in: handRolled), ["Views/FakeView.swift"],
                       "自造页骨架扫不出来 → 第五份骨架悄悄长回来")
        let baseUser = [(path: "Views/FakeView.swift", content: """
        struct FakeView: View {
            var body: some View { Theme.Page.Scaffold { content } }
        }
        struct PageScaffold: View { var body: some View { ScrollView { EmptyView() } } }
        """)]
        XCTAssertTrue(Self.handRolledScaffolds(in: baseUser).isEmpty,
                      "基座自己那份骨架被误伤 —— 那正是唯一允许画 ScrollView 的地方")
    }

    // MARK: - 风格契约 6/7：外壳层零投影、零材质胶囊

    func test_shellLayerCarriesNoShadowAndNoSurfaceFace() throws {
        let files = try Self.shellSources()
        let shadows = BorderlessSurfaceGuardTests.shadowHits(in: files)
        XCTAssertTrue(shadows.isEmpty,
                      "全仓唯一一处投影属于 `.floating`（风格契约 6），外壳页面一处都不许有：\(shadows)")
        let faces = Self.symbolUses(".surface(layer:", in: files)
        XCTAssertTrue(faces.isEmpty,
                      "侧栏行 / 导航行 / 读数都不再是一块面（风格契约 7）：\(faces)")
    }

    /// 元测试：上面两条的尺子量得出东西。
    func test_surfaceAndShadowScannersCatchSyntheticShells() {
        let dirty = [(path: "Fake.swift", content: """
        struct FakeRow: View {
            var body: some View {
                Text("x")
                    .surface(layer: .chrome, shape: .capsule)
                    .shadow(color: .black.opacity(0.2), radius: 6)
            }
        }
        """)]
        XCTAssertEqual(BorderlessSurfaceGuardTests.shadowHits(in: dirty).count, 1,
                       "投影扫描器在合成脏样本上失灵")
        XCTAssertEqual(Self.symbolUses(".surface(layer:", in: dirty).count, 1,
                       "surface 扫描器在合成脏样本上失灵")
        let commented = [(path: "Fake.swift",
                          content: "// 旧写法是 .surface(layer: .chrome) + .shadow(...)\n")]
        XCTAssertTrue(Self.symbolUses(".surface(layer:", in: commented).isEmpty,
                      "注释里的历史说明被误判 → 这段历史一年后就没人敢写")
    }

    // MARK: - 元测试：①④ 两把尺子都不是摆设

    func test_symbolAndSpacingScannersCatchSyntheticViolations() {
        let dirty = """
        struct ProjectDetailView: View {
            var body: some View {
                VStack(spacing: Theme.Spacing.md) {
                    SectionNavBar(selection: .constant(.overview), reportAvailable: true)
                }
            }
        }
        """
        XCTAssertEqual(Self.symbolUses("SectionNavBar",
                                       in: [("Views/Fake.swift", dirty)]).count, 1,
                       "符号扫描器失灵：chip 条回来了也不会红")
        let region = Self.region(in: dirty, startingAt: "var body: some View {") ?? ""
        let tight = Self.tightSpacings(in: region, minimum: Theme.Spacing.group)
        XCTAssertEqual(tight.count, 1, "间距扫描器失灵：组间 md(16) 没抓到")
        XCTAssertTrue(tight[0].contains("md"), "报错没点名是哪个令牌：\(tight)")

        let clean = Self.region(in: """
        struct DashboardView: View {
            var body: some View {
                VStack(spacing: Theme.Spacing.section) {
                    hero
                    LazyVGrid(columns: pairColumns, spacing: Theme.Spacing.group) { a; b }
                }
                .padding(.horizontal, Theme.Spacing.pageMargin)
            }
        }
        """, startingAt: "var body: some View {") ?? ""
        XCTAssertTrue(Self.tightSpacings(in: clean, minimum: Theme.Spacing.group).isEmpty,
                      "合法布局被判红 → 下一步就是有人去放宽阈值")

        XCTAssertEqual(Self.tightSpacings(in: "VStack(spacing: 12) {", minimum: 24).count, 1,
                       "裸数字间距必须抓到")
    }

    /// `region(in:startingAt:)` 只吃第一段：组内小间距合法的证据。
    /// 不钉这一条，下次有人把行内 `xs` 改成 `group`「为了过门」就没人发现。
    func test_regionScannerStopsAtTheDeclaredBlock() {
        let twoBlocks = """
        struct DashboardView: View {
            var body: some View {
                VStack(spacing: Theme.Spacing.group) { row }
            }
            private var row: some View {
                HStack(spacing: Theme.Spacing.xs) { Text("a") }
            }
        }
        """
        let region = Self.region(in: twoBlocks, startingAt: "var body: some View {") ?? ""
        XCTAssertTrue(region.contains("Theme.Spacing.group"))
        XCTAssertFalse(region.contains("Theme.Spacing.xs"),
                       "吃过了页级 body 的界，组内小间距会被误判成拥挤")
        XCTAssertNil(Self.region(in: twoBlocks, startingAt: "private var nope: some View {"),
                     "定位失败时返回了非 nil —— 上面那条断言会因此假绿")
    }

    // MARK: - 排版令牌必须经 `.typed`（字距不许静默丢失）

    func test_groupLabelsInTheShellLayerGoThroughTyped() throws {
        let files = try Self.shellSources()
        let dropped = BorderlessSurfaceGuardTests.trackingDroppingUses(in: files,
                                                                      tokenNamed: "groupLabel")
        XCTAssertTrue(dropped.isEmpty,
                      "绕过 .typed 直接 `.font(groupLabel.font)`，0.6pt 字距已丢失：\(dropped)")
        XCTAssertTrue(files.contains { $0.content.contains(".typed(Theme.Typo.groupLabel)") },
                      "外壳层一处都没经 .typed 套 groupLabel → 分组标题没有唯一落点")
    }

    // MARK: - ⑤ 倾向色不许当数据色用（总工 2026-09-20 补的硬要求）
    //
    // 病灶的**形状**比病灶本身值得记下来：M0 已经把 `MetricTile.tint` 的默认值改成纯墨，
    // 但「改默认值」救不了「调用点显式传参」—— 总工在 main `415f0f0` 实拍上仍然看到
    // CPU `16%`、内存 `28.4 GB`、最近提交 `15 分钟前` 三个蓝数。
    // 所以基座换默认值之后，必须回头把每个显式覆盖点扫一遍，这条守卫就是那一次扫的回执。
    //
    // **只禁「把信息色/交互色涂在读数上」这一件事**。accent 作为**交互语义**是合法的，
    // 不在禁用之列：侧栏选中行的淡底胶囊、拖放落点高亮、`SemanticBadge("示例")` 的 role、
    // 按钮 —— 那些是「可点/可选中」的意思，不是数据。一律砍 accent 会把导航做哑。

    /// 读数被涂信息色/倾向色的两种落地形状。
    static let dataHueNeedles = [
        "tint: Theme.Semantic.info",
        "tint: Theme.Semantic.accent",
        ".foregroundStyle(Theme.Semantic.info",
        ".foregroundStyle(Theme.Semantic.accent",
    ]

    static func dataHueUses(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw in
                    let line = String(raw)
                    guard !isComment(line) else { return nil }
                    guard let needle = dataHueNeedles.first(where: { line.contains($0) })
                    else { return nil }
                    return "\(file.path):\(index + 1) \(needle)"
                }
        }
    }

    func test_readoutsAreNeverTintedWithInfoOrAccent() throws {
        let hits = Self.dataHueUses(in: try Self.shellSources())
        XCTAssertTrue(hits.isEmpty,
                      "读数被涂成信息色/交互色（风格契约 5「颜色只承载语义」）：\(hits)")
    }

    /// 元测试：脏样本必须红，且**合法用法不许误伤** ——
    /// 否则下一次有人拿 accent 做选中态就会被这条判红，然后去把它整个删掉。
    func test_dataHueScannerCatchesSyntheticTilesAndSparesInteraction() {
        let dirty = [(path: "Views/DashboardView.swift", content: """
        MetricTile(label: "CPU", value: cpu, tint: Theme.Semantic.info.textColor)
        Text(NumberFormat.grouped(code.codeLines)).foregroundStyle(Theme.Semantic.info.textColor)
        """)]
        XCTAssertEqual(Self.dataHueUses(in: dirty).count, 2,
                       "蓝数回来了也不会红 → 这条守卫是假绿")

        let legal = [(path: "Views/Shell/ProjectSidebar.swift", content: """
        Capsule().fill(Theme.Semantic.accent.graphicColor.opacity(Theme.Palette.Opacity.badgeFill))
        SemanticBadge("示例", role: Theme.Semantic.accent)
        private var iconTint: Color { isDropTargeted ? Theme.Semantic.accent.textColor : .secondary }
        """)]
        XCTAssertTrue(Self.dataHueUses(in: legal).isEmpty,
                      "选中态 / 落点高亮 / 徽标用 accent 是交互语义，误伤会把守卫逼成豁免")

        let commented = [(path: "Views/DashboardView.swift",
                          content: "// 原来这里传的是 tint: Theme.Semantic.info.textColor\n")]
        XCTAssertTrue(Self.dataHueUses(in: commented).isEmpty,
                      "注释里交代历史就被判红 → 一年后没人记得它为什么错")
    }

    // MARK: - 今日错误的着色（语义色只留给真有危险的那一态）

    /// 判据做成**谓词**而不是返回 `Color`：`Color` 由动态 `NSColor` 包出来，
    /// 两次取值不相等，直接比色会变成一条永真或永假的断言。
    /// （`MetricTile.forcesNeutralTint(for:)` 同一套路子。）
    func test_onlyRealErrorsCarryTheDangerHue() {
        XCTAssertFalse(DashboardView.hasTodayErrors(nil),
                       "没扫过 = 没有证据，不该着色（`MetricTile` 会强制回 neutral）")
        XCTAssertFalse(DashboardView.hasTodayErrors(0),
                       "0 是「查过、没有」这一结论。把 0 涂成红等于对着一句定心丸拉警报")
        XCTAssertTrue(DashboardView.hasTodayErrors(1))
        XCTAssertTrue(DashboardView.hasTodayErrors(42))
    }
}
