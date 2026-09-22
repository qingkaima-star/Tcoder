/// OWNER: WS-X3 TestSplit —— 自 ShellBorderlessTests.swift 拆出，实测读数不用 tertiary、总览栅格与单一脚手架。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension ShellBorderlessTests {

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

    func test_overviewPageLayoutHasNoTightGroupSpacing() throws {
        let dashboard = try XCTUnwrap(
            Self.shellSources().first { $0.path == "DashboardView.swift" }).content
        // 现量 **2**，不是 3 —— 这是一次真实的形状变化，不是把尺子锯短。
        // P31 之前是 3：`scaleSegment` 里一个 `VStack` + 两张 `LazyVGrid` 各带一处 `spacing:`。
        // 那两张栅格被收成单列删掉（病灶与量数见 `test_dashboardIsSingleColumnWithNoCardPairGrid`
        // 与 `docs/界面语言-批次台账.md` §6.32），页面级纵向容器就只剩下面两段。
        // 判据因此从"数够三个数"换成"**每一段恰好自己声明一处组间距**"：
        // 少一段（漏声明）与多一处（又偷偷开一层栅格/容器）都会红，两边都钉得住。
        let segments = Self.overviewPageSegments
        var scanned = 0
        var tight: [String] = []
        for marker in segments {
            let body = try XCTUnwrap(Self.region(in: dashboard, startingAt: marker),
                                     "定位不到 \(marker) —— 布局被改成了别的形状，这条守卫会假绿")
            scanned += body.split(separator: "\n").filter { $0.contains("spacing:") }.count
            let vertical = Self.verticalContainerLines(in: body)
            tight += Self.tightSpacings(in: vertical, minimum: Theme.Spacing.group).map {
                "\(marker.dropLast(2)) → \($0)"
            }
        }
        XCTAssertEqual(scanned, segments.count,
                       "页面级分段每段应当恰好声明一处组间距：\(segments.count) 段现量 \(scanned) 处"
                       + "（少了=漏声明，多了=又开了一层栅格/容器）")
        XCTAssertTrue(tight.isEmpty,
                      "总览页面级容器间距 < \(Int(Theme.Spacing.group))pt（风格契约 8「分组间 32」）：\(tight)")
    }

    /// 只留**纵向容器**那一行（`VStack` / `LazyVStack` / `LazyVGrid`）。
    /// 契约 8 那句管的是**纵向**"分组之间留 32"，横向列间距是另一个数（`pageMargin` 24）；
    /// 混起来量会误报（P31 第一版就是这么红的：`L6 Theme.Spacing.pageMargin=24.0`）。
    /// 这条筛选自己也要有反例撑着，否则"分不清轴"只是换了一种瞎法。
    static func verticalContainerLines(in region: String) -> String {
        region.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { line in
                ["VStack(", "LazyVStack(", "LazyVGrid("].contains(where: line.contains)
            }.joined(separator: "\n")
    }

    func test_verticalContainerLineFilterSeparatesTheTwoAxes() {
        let mixed = """
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
        HStack(alignment: .top, spacing: Theme.Spacing.pageMargin) {
        LazyVGrid(columns: cols, spacing: Theme.Spacing.xs) {
        """
        let kept = Self.verticalContainerLines(in: mixed)
        XCTAssertEqual(kept.split(separator: "\n").count, 2, "纵向那一档没留住 / 横向那一档没滤掉")
        XCTAssertTrue(kept.contains("Theme.Spacing.md") && kept.contains("Theme.Spacing.xs"))
        XCTAssertFalse(kept.contains("pageMargin"), "横向列间距漏进来了——它会把合法版判成破契约")
        XCTAssertTrue(Self.verticalContainerLines(in: "Text(\"x\")").isEmpty,
                      "没有纵向容器时不该原样吐出整段")
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
        XCTAssertTrue(dashboard.contains("Theme.Page.Scaffold {"),
                        "总览没接基座页骨架。版框宽度现在只有基座一个出口，"
                        + "页面不再传 `maxWidth:`（三档会让切 tab 时内容整体左右跳）")
        XCTAssertFalse(dashboard.contains("Theme.Page.Scaffold(maxWidth:"),
                       "页面自己挑版框宽度 = 又想单开一档，九页边距会再次分叉")
    }

    /// 总览 CPU 曲线的时间轴：短窗口必须降到秒级。
    /// 实拍上出现过 `03:57` 与 `03:57` 并排 —— 三个自动刻度落进同一分钟，
    /// 轴看起来像坏了，其实只是分辨率不够；而小时级窗口里再印秒就是噪声。
    func test_cpuChartAxisDropsToSecondsForShortWindows() {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let later = base.addingTimeInterval(30)
        XCTAssertNotEqual(base.formatted(CPUHistoryChart.axisTimeFormat(span: 45)),
                          later.formatted(CPUHistoryChart.axisTimeFormat(span: 45)),
                          "45 秒的窗口里两个刻度印成了同一个数")
        XCTAssertEqual(base.formatted(CPUHistoryChart.axisTimeFormat(span: 3 * 3600)),
                       later.formatted(CPUHistoryChart.axisTimeFormat(span: 3 * 3600)),
                       "小时级窗口不该把秒印出来")
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

    /// 总览的"两列一段"必须走 `pairSegment`，**全仓不许再有 `LazyVGrid` 卡片对**。
    ///
    /// 立它的两条实测病灶（`7b4ec25` 那批 36 张页尾实拍，`card_edges` 量出来的，不是看着像）：
    /// ① 同一行两张卡不共顶线：「最近提交」顶在 1065px、「高频错误」顶在 1593px，差 264pt；
    /// ② 不渲染的那一格照样占槽位 ⇒「文件构成」右边约 297pt 的画布洞。
    /// 其余八页早就离开这个形状了（各自的注释里写着理由），总览是最后一处。
    static func cardPairGrids(in files: [(path: String, content: String)]) -> [String] {
        files.filter { file in
            SurfaceScanKit.codeLines(file.content).contains { $0.contains("LazyVGrid(") }
        }.map(\.path)
    }

    func test_dashboardIsSingleColumnWithNoCardPairGrid() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertFalse(views.isEmpty, "扫不到 Views 面 ⇒ 分母坏了，下面的绿是假零")
        // 作用面 = 总览自己 + 它的分块文件。
        let surface = views.filter {
            $0.path.hasPrefix("Views/Shell/") || $0.path == "Views/DashboardView.swift"
        }
        XCTAssertFalse(surface.isEmpty, "作用面扫空了 ⇒ 下面的绿是假零")
        let grids = Self.cardPairGrids(in: surface)
        XCTAssertTrue(grids.isEmpty,
                      "总览这一面又出现了 `LazyVGrid` 卡片对，页面级请单列：\(grids)")
        // 全仓剩下的这一处**逐条留名**。它同时管两个方向：
        // 别处新加一处 ⇒ 红；这一处被改造掉了 ⇒ 也红（逼着来改这张清单，而不是让它静默漂）。
        XCTAssertEqual(Self.cardPairGrids(in: views), ["Views/Performance/PerformanceProcessGroups.swift"],
                       "`LazyVGrid` 的去向变了：那条是进程展开行里的 4 枚「等宽 KPI 格」"
                       + "（cpu/内存/线程/fd），不是两张内容无关的卡并排，不归这条判据管")

        let dashboard = try XCTUnwrap(
            Self.shellSources().first { $0.path == "DashboardView.swift" }).content
        // `pairSegment` 是为「两列但要对齐」造的中间方案，实测两列本身就不该要
        // （见上面注释③：两列是把卡压到内容最小宽之下才挤出来的），所以它必须整体缺席。
        XCTAssertEqual(SurfaceScanKit.codeLines(dashboard).filter { $0.contains("pairSegment") }.count, 0,
                       "`pairSegment` 又长回来了——它保的是两列的顶线，而这两列不该存在")
        for segment in Self.overviewPageSegments {
            let region = try XCTUnwrap(Self.region(in: dashboard, startingAt: segment),
                                       "定位不到 \(segment) ⇒ 这条判据在空转")
            XCTAssertTrue(region.contains("VStack(alignment: .leading, spacing: Theme.Spacing.group)"),
                          "\(segment) 不再是「一个纵向容器装几段卡」的形状，页面级单列这条被绕开了")
            XCTAssertFalse(region.contains("HStack("),
                           "\(segment) 里又出现横向并排：两列会把卡压到内容最小宽之下")
        }
    }

    func test_cardPairGridScannerCatchesSyntheticAndSparesComments() {
        let grid = [(path: "Views/Fake/Fake.swift", content: """
        struct Fake: View {
            var body: some View { LazyVGrid(columns: cols) { a; b } }
        }
        """)]
        XCTAssertEqual(Self.cardPairGrids(in: grid), ["Views/Fake/Fake.swift"],
                       "卡片对栅格没抓到 ⇒ 这条守卫是摆设")
        let commented = [(path: "Views/Fake/Fake2.swift",
                          content: "/// 旧写法是 LazyVGrid(columns:)，已换成 pairSegment\n")]
        XCTAssertTrue(Self.cardPairGrids(in: commented).isEmpty,
                      "注释里交代旧写法就被判红（讲代码的话第三次绊倒守卫）")
    }
}
