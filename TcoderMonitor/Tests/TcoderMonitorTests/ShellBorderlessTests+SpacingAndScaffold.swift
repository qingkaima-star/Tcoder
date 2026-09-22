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
        // 页面级布局现在住在**两个文件**里：`listSegment` 的间距决定随 `pairSegment`
        // 搬进了 `Views/Shell/DashboardReadouts.swift`。判据面必须跟着代码走——
        // 代码没坏而尺子先瞎，正是下面那句分母断言要拦的事（本轮它就是那么响的）。
        // **没有把 3 改成 2**：改成把 `pairSegment` 整段纳进判据面（它两处 `spacing:`）。
        //
        // 轴要分清楚：契约 8 那句管的是**纵向**"分组之间留 32"，而 `pairSegment` 的
        // `HStack` 那一档是**横向列间距** `pageMargin`(24)——与页边距同一个数、与旧
        // `pairColumns` 里 `GridItem` 的 spacing 同一个值。整段扫进来时它会被判成"太紧"
        // （第一版就是这么误报的，报错原文：`L6 Theme.Spacing.pageMargin=24.0`），
        // 所以判"太紧"之前先只留**纵向容器**那一行。分母照旧数全部 `spacing:`。
        let readouts = try XCTUnwrap(SurfaceScanKit.sourceFiles(under: "Views/Shell")
            .first { $0.path.hasSuffix("DashboardReadouts.swift") }?.content)
        let regions: [(marker: String, source: String)] =
            Self.overviewLayoutMarkers.map { (marker: $0, source: dashboard) }
            + [(marker: "func pairSegment<Left: View, Right: View>(", source: readouts)]
        var scanned = 0
        var tight: [String] = []
        for region in regions {
            let body = try XCTUnwrap(Self.region(in: region.source, startingAt: region.marker),
                                     "定位不到 \(region.marker) —— 布局被改成了别的形状，这条守卫会假绿")
            scanned += body.split(separator: "\n").filter { $0.contains("spacing:") }.count
            let vertical = Self.verticalContainerLines(in: body)
            tight += Self.tightSpacings(in: vertical, minimum: Theme.Spacing.group).map {
                "\(region.marker.dropLast(2)) → \($0)"
            }
        }
        XCTAssertGreaterThanOrEqual(scanned, 3,
                                    "页面级布局里只扫到 \(scanned) 处 spacing: —— 判据面太小，等于没量")
        XCTAssertTrue(tight.isEmpty,
                      "总览页面级容器间距 < \(Int(Theme.Spacing.group))pt（风格契约 8「分组间 32」）：\(tight)")
    }

    /// 只留**纵向容器**那一行（`VStack` / `LazyVStack` / `LazyVGrid`）。
    /// 这条筛选本身要有反例撑着，否则"分不清轴"只是换了一种瞎法。
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

    func test_dashboardPairsHaveNoLazyGridAndShareTheirTopLine() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertFalse(views.isEmpty, "扫不到 Views 面 ⇒ 分母坏了，下面的绿是假零")
        // 判的是"**两张不相关的卡并排**"这个形状，作用面 = 总览自己 + 它的分块文件。
        let pairSurface = views.filter {
            $0.path.hasPrefix("Views/Shell/") || $0.path == "Views/DashboardView.swift"
        }
        XCTAssertFalse(pairSurface.isEmpty, "作用面扫空了 ⇒ 下面的绿是假零")
        let grids = Self.cardPairGrids(in: pairSurface)
        XCTAssertTrue(grids.isEmpty,
                      "总览这一面又用 `LazyVGrid` 摆卡片对了；两列一段走 `DashboardView.pairSegment`：\(grids)")
        // 全仓剩下的卡片对栅格**逐条留名**。它同时管两个方向：
        // 别人新加一处 ⇒ 红；这一处被改造掉了 ⇒ 也红（逼着来改这张清单，而不是让它静默漂）。
        XCTAssertEqual(Self.cardPairGrids(in: views), ["Views/Performance/PerformanceProcessGroups.swift"],
                       "`LazyVGrid` 卡片对的去向变了：那条是进程展开行里的 4 枚等宽 KPI 格"
                       + "（cpu/mem/threads/fd），不是两张不相关的卡并排，不归这条判据管")

        let dashboard = try XCTUnwrap(
            Self.shellSources().first { $0.path == "DashboardView.swift" }).content
        let wired = SurfaceScanKit.codeLines(dashboard)
            .filter { $0.contains("pairSegment {") }.count
        XCTAssertEqual(wired, 2,
                       "总览的两段（代码规模下的 文件构成/覆盖率、底部的 最近提交/高频错误）"
                       + "必须都走 pairSegment，现量 \(wired) 处")
        let helper = try XCTUnwrap(SurfaceScanKit.sourceFiles(under: "Views/Shell")
            .first { $0.path.hasSuffix("DashboardReadouts.swift") }?.content)
        XCTAssertTrue(SurfaceScanKit.codeLines(helper).contains { $0.contains("HStack(alignment: .top") },
                      "pairSegment 的顶线保证没了 ⇒ 两列又会各走各的")
        // 「覆盖率这一格有没有内容」只许一个出口：栅格洞的第二半就是「两处各判一次」造出来的。
        // 只数**同一行既出现 coverage 又出现 hasData** 的那些——日志那一格的 hasData 是另一个输入，
        // 拿它来判"重复"是我第一版写错的口径（当场被自己的守卫拦下一次，注释留在这里防再犯）。
        let coverageProbes = SurfaceScanKit.codeLines(dashboard)
            .filter { $0.contains("coverage") && $0.contains(".hasData") }
        XCTAssertEqual(coverageProbes.count, 1,
                       "覆盖率的 `hasData` 被判了 \(coverageProbes.count) 次：\(coverageProbes)"
                       + "；只许 `hasCoverageStrip` 一处，渲染与排版两处都读它")
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
