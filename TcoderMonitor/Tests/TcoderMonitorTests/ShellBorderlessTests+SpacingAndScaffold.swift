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

}
