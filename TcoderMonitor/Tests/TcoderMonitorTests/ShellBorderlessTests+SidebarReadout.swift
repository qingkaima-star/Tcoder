/// OWNER: WS-X3 TestSplit —— 自 ShellBorderlessTests.swift 拆出，数据色不许染主读数、侧栏实时列宽预算。用例本体未改，只是搬了家。
import AppKit
import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

extension ShellBorderlessTests {

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

    /// 侧栏底栏那格实时读数。`liveReadoutColumnWidth` 一直是 40，而 `30.6 GB` 在
    /// 10pt 等宽下就要 41pt，于是它**折成两行**把底栏撑歪 —— 实拍才看得见，
    /// 因为这一格从来没被量过（`ShellDesignTests` 只量了项目行的两格）。
    /// 用系统排版真实量宽，不启动 App。
    func test_sidebarLiveReadoutColumnFitsTheWorstCase() {
        let widest = "180.5 GB"          // 192GB 机器上用满时的真实形状
        let needed = Self.width(of: widest)
        XCTAssertGreaterThanOrEqual(ShellLayout.liveReadoutColumnWidth, needed,
                                    "「\(widest)」会被折成两行；定宽格必须容得下最坏读数")
        XCTAssertLessThan(ShellLayout.liveReadoutColumnWidth, needed * 2,
                          "定宽格不许比最坏情况宽出一整倍（白占侧栏横向空间）")
    }

    /// 元测试：这把尺子量得出「装不下」。
    func test_textMeasuringRulerIsNotVestigial() {
        XCTAssertGreaterThan(Self.width(of: "180.5 GB"), Self.width(of: "9 GB"),
                             "量宽函数失灵：长串不比短串宽")
        XCTAssertGreaterThanOrEqual(Self.width(of: "180.5 GB"), 41,
                                    "10pt 等宽下 8 个字符不可能小于 41pt —— 字体取错了")
    }

    /// 底栏那一行读数的**同行预算**。上一处修正只量了单个格子（够宽），
    /// 却漏了「同一行还塞着别的」—— 过约束时 `.frame(width:)` 会被压缩、
    /// 文字在格内折行（18:29 实拍：`36.9 GB` 折成三行）。所以格子够宽之外，
    /// 整行自然宽度也必须装得下侧栏最小宽度扣掉左右内边距。
    func test_liveReadoutRowFitsInsideTheSidebarBudget() {
        let iconAndSeparator: CGFloat = 30        // 图标 + 间隔点「·」的保守估计
        let gaps = 3 * Theme.Spacing.xxs          // 三处 4pt 间隙
        let rowWidth = ShellLayout.liveReadoutColumnWidth   // CPU 格
            + Self.width(of: "180.5 GB")                     // 内存读数实际要宽（不受定宽约束的那半）
            + ShellLayout.liveReadoutColumnWidth
            + iconAndSeparator + gaps
        let usable = ShellLayout.sidebarMinWidth - 2 * Theme.Spacing.sm
        XCTAssertLessThanOrEqual(rowWidth, usable,
                                 "底栏读数行要 \(rowWidth)pt，侧栏最小宽度只给 \(usable)pt —— 会被过约束折行")
    }

    /// 用 `monoSmall` 那一档（10pt 等宽字族）真实量一段文字的宽度。
    private static func width(of text: String) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: Theme.Typo.monoSmall.size, weight: .regular),
        ]
        return ceil((text as NSString).size(withAttributes: attributes).width)
    }

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
