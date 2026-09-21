import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 数据块走蓝、数字走纯墨：两条规则都要有牙
//
// 权威 = `docs/界面语言-对齐AiX.md` §3（一个蓝）+ 风格契约 4（最重的墨给最大的数）。
//
// 批次 P6 把占比条从纯墨改成基座的数据块蓝时，很容易一刀切错：
// `MetricTile` / `GroupMetricCell` 的 `tint:` 参数**同名**，但它是**数字的前景色**，
// 那里必须继续是纯墨 —— 把最大的数涂成蓝，等于把"最重的墨给最大的数"这条撤了。
// 所以这条守卫两头都查：条不许是墨，数字不许不是墨。

final class DataMarkColorGuardTests: XCTestCase {

    /// 占比条调用点里传纯墨的位置。
    /// 判据形状：`DataShareBarRow(` 或 `Theme.Share.Row(` 之后 8 行内出现
    /// `tint: Theme.Palette.Surface.ink` / `color: Theme.Palette.Surface.ink`。
    static func inkShareBars(in files: [(path: String, content: String)]) -> [String] {
        let openers = ["DataShareBarRow(", "Theme.Share.Row("]
        let badTints = ["tint: Theme.Palette.Surface.ink", "color: Theme.Palette.Surface.ink"]
        return files.flatMap { file in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            var hits: [String] = []
            for (index, line) in lines.enumerated() {
                guard !line.trimmingCharacters(in: .whitespaces).hasPrefix("//") else { continue }
                guard openers.contains(where: line.contains) else { continue }
                let window = lines[(min(index + 1, lines.count))..<min(index + 9, lines.count)]
                if window.contains(where: { tint in badTints.contains(where: tint.contains) }) {
                    hits.append("\(file.path):\(index + 1)")
                }
            }
            return hits
        }
    }

    func test_shareBarsDoNotDrawInInk() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        let hits = Self.inkShareBars(in: views)
        XCTAssertTrue(hits.isEmpty,
                      "这些占比条还在传纯墨，与曲线/柱的数据块取色分家：\(hits)。"
                    + "请走 `ChartSeries.dataMarkColor`。")
        // 反向自证：判据必须真的看得到合法写法，否则"零命中"可能只是没扫到。
        XCTAssertTrue(views.contains { $0.content.contains("tint: ChartSeries.dataMarkColor") },
                      "全仓没有一处 `dataMarkColor` —— 上面那条断言成了永真绿")
    }

    /// 数字前景必须仍是纯墨（`tint:` 同名参数，语义完全不同）。
    func test_metricNumbersStayInInk() throws {
        let tiles = try SurfaceScanKit.sourceFiles(under: "Views/Performance")
            .first { $0.path.hasSuffix("PerformanceSystemTiles.swift") }
        XCTAssertNotNil(tiles, "找不到性能读数磁贴文件，判据在空转")
        XCTAssertTrue((tiles?.content ?? "").contains("tint: Theme.Palette.Surface.ink"),
                      "内存磁贴的数字被涂成蓝了 —— 「最重的墨给最大的数」这条被撤。"
                    + "数据块蓝只给条/柱/线，不给数字。")
    }

    /// 两向元测试。
    func test_shareBarRulerCatchesSyntheticAndSparesNumbers() {
        let dirty = [(path: "Views/Code/Fake.swift", content: """
        DataShareBarRow(
            label: name,
            fraction: 0.4,
            tint: Theme.Palette.Surface.ink
        )
        """)]
        XCTAssertEqual(Self.inkShareBars(in: dirty).count, 1, "占比条传墨没抓到 → 守卫是摆设")

        let legalBar = [(path: "Views/Git/Fake.swift", content: """
        DataShareBarRow(
            label: name,
            fraction: 0.4,
            tint: ChartSeries.dataMarkColor
        )
        """)]
        XCTAssertTrue(Self.inkShareBars(in: legalBar).isEmpty, "合法写法被误伤")

        let numberTile = [(path: "Views/Performance/Fake.swift", content: """
        MetricTile(
            label: "内存",
            value: used,
            tint: Theme.Palette.Surface.ink
        )
        """)]
        XCTAssertTrue(Self.inkShareBars(in: numberTile).isEmpty,
                      "数字的 tint 不是占比条 —— 一刀切会把「最重的墨给最大的数」改掉")

        let commented = [(path: "Views/Code/Fake.swift", content: """
        // 原来是 tint: Theme.Palette.Surface.ink
        DataShareBarRow(
            label: name,
            fraction: 0.4,
            tint: ChartSeries.dataMarkColor
        )
        """)]
        XCTAssertTrue(Self.inkShareBars(in: commented).isEmpty,
                      "注释里交代旧写法就被判红 → 一年后没人记得它为什么错")
    }
}
