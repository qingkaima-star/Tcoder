/// OWNER: WS-X3 TestSplit —— 自 ShellBorderlessTests.swift 拆出，无投影无面板面、符号/间距/区块三类扫描器的反例。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension ShellBorderlessTests {

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

    func test_groupLabelsInTheShellLayerGoThroughTyped() throws {
        let files = try Self.shellSources()
        let dropped = BorderlessSurfaceGuardTests.trackingDroppingUses(in: files,
                                                                      tokenNamed: "groupLabel")
        XCTAssertTrue(dropped.isEmpty,
                      "绕过 .typed 直接 `.font(groupLabel.font)`，0.6pt 字距已丢失：\(dropped)")
        XCTAssertTrue(files.contains { $0.content.contains(".typed(Theme.Typo.groupLabel)") },
                      "外壳层一处都没经 .typed 套 groupLabel → 分组标题没有唯一落点")
    }

}
