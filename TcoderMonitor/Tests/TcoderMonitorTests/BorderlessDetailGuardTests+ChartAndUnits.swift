import Foundation
import SwiftUI
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 H8 / H9 的图表与数值守卫（自 BorderlessDetailGuardTests.swift 原样搬出）
//
// 搬的理由与 `+FrameAndStrip` 那份一样是机械的：`X3TestSizeAuditTests` 用与产品
// 「巨大文件」同一口径（400 行）钉着 Tests 目录，而 H8/H9 两批守卫把主文件顶到 427 行。
// 判据、合成样例与数字一字未改，只换了住的地方。

extension BorderlessDetailGuardTests {

    // MARK: 批次 H8：纵轴刻度一律落在左边

    /// SwiftUI 的 `AxisMarks` 默认 `position` 是 `.automatic`，它会随图落位 ——
    /// 实拍总览页的 100/50/0 就跑到了**右边**，而性能/健康/日志/Git 四页的曲线
    /// 都显式写了 `.leading`。同一个 App 里"纵轴一会儿在左一会儿在右"是典型的
    /// 「东一个系一个」，而且只在**漏写**时发生，所以钉成机器断言。
    static func yAxesWithoutLeadingPosition(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = SurfaceScanKit.codeLines(file.content)
            var hits: [String] = []
            for (index, line) in lines.enumerated() where line.contains(".chartYAxis") {
                let window = lines[index..<min(index + 6, lines.count)].joined(separator: "\n")
                if !window.contains("position: .leading") {
                    hits.append("\(file.path):\(index + 1)")
                }
            }
            return hits
        }
    }

    func test_yAxisLabelsAllSitOnTheLeadingSide() throws {
        let offenders = Self.yAxesWithoutLeadingPosition(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "这些图的纵轴刻度没写 `position: .leading`，会自己跑到右边去：\(offenders)")
    }

    func test_yAxisScannerDetectsMissingPosition() {
        let missing = [(path: "Views/FakeChart.swift", content: """
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { _ in
                    AxisValueLabel()
                }
            }
            """)]
        XCTAssertEqual(Self.yAxesWithoutLeadingPosition(in: missing), ["Views/FakeChart.swift:1"],
                       "漏写 position 的图没被抓到")
        let pinned = [(path: "Views/FakeChart.swift", content: """
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { _ in
                    AxisValueLabel()
                }
            }
            """)]
        XCTAssertTrue(Self.yAxesWithoutLeadingPosition(in: pinned).isEmpty, "写了 .leading 的被误判")
    }

    // MARK: 批次 H9：量词不许被焊死在数值里
    /// `value: "\(…) 行"` 把单位与数字同号排，而同一条读数带里别的格子走 `unit:`（小一档）。
    /// H2 定的规则是**纯量词走 `unit:`**，当时只钉了"量词不许当 caption"，
    /// 没钉"量词不许焊进 value"，于是复杂度页「14 行」就这么漏过来了。
    static func unitsBakedIntoValues(in files: [(path: String, content: String)]) -> [String] {
        let quantifiers = ["行", "个", "次", "项", "条", "人", "天", "核", "处", "段"]
        return files.flatMap { file -> [String] in
            // **逐原始行**扫，不能先过 `codeLines`：那道过滤会删掉注释行，
            // 于是 `index + 1` 不再是文件行号 —— 报出来的行号指向无辜的那一行，
            // 这条守卫第一次跑就踩在这里（报到了 `GlassSection("重复与复杂度概览"` 上）。
            file.content.split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated()
                .compactMap { index, raw -> String? in
                    let line = String(raw)
                    guard SurfaceScanKit.isCode(line) else { return nil }
                    guard let start = line.range(of: "value: \"") else { return nil }
                    let body = line[start.upperBound...]
                    guard let end = body.firstIndex(of: "\"") else { return nil }
                    let literal = body[..<end]
                    // 只有"插值 + 空格 + 量词"收尾的才算：`"44.3 GB"`、`"1 分钟前"` 都不在此列。
                    guard let paren = literal.lastIndex(of: ")"),
                          literal[literal.index(after: paren)...].count <= 2
                    else { return nil }
                    let tail = literal[literal.index(after: paren)...]
                        .trimmingCharacters(in: .whitespaces)
                    guard quantifiers.contains(String(tail)) else { return nil }
                    return "\(file.path):\(index + 1)"
                }
        }
    }

    func test_pureUnitsNeverSitInsideTheValue() throws {
        let offenders = Self.unitsBakedIntoValues(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "量词被焊进 value 会与同排走 `unit:` 的格子字号不一致：\(offenders)")
    }

    func test_valueUnitScannerDetectsGluedUnitAndSparesRealStrings() {
        // 前面垫两行注释：报的行号必须是**文件行号**，不是"过滤掉注释后的第几行"。
        let glued = [(path: "Views/Fake.swift", content: """
            // 说明
            // 说明二
            DataReadout(label: "x", value: "\\(NumberFormat.grouped(n)) 行")
            """)]
        XCTAssertEqual(Self.unitsBakedIntoValues(in: glued), ["Views/Fake.swift:3"],
                       "抓到了但行号错位 —— 报出来的行号指不到病灶，等于让人重找一遍")
        let fine = [(path: "Views/Fake.swift", content: """
            DataReadout(label: "a", value: "44.3 GB", unit: nil)
            MetricTile(label: "b", value: "\\(Live.bytes(x))", unit: "行")
            Text("1 分钟前")
            """)]
        XCTAssertTrue(Self.unitsBakedIntoValues(in: fine).isEmpty,
                      "带单位的合法写法被误判：\(Self.unitsBakedIntoValues(in: fine))")
    }

    /// 反向自证：`sourceFiles` 真读到了文件。
    func test_detailScannerActuallyFindsFiles() throws {
        let views = try SurfaceScanKit.sourceFiles(under: "Views")
        XCTAssertGreaterThanOrEqual(views.count, 30, "Views/ 只扫到 \(views.count) 个文件")
        XCTAssertTrue(views.contains { $0.path.hasSuffix("PerformanceSystemTiles.swift") })
    }

    // MARK: 批次 H10：轴刻度不得用层级样式（会连乘）

    /// `AxisValueLabel` 之后 8 行内出现 `.foregroundStyle(.secondary)` / `.tertiary` 即算违规。
    /// 层级样式与宿主环境里的层级**连乘**（0.55×0.55≈0.30）：深色态实测性能页五档纵轴
    /// 刻度只剩 `#464646`（对纯黑约 2.2:1），整条轴读不出，而总览页同类刻度没被连乘 ——
    /// 同一个 App 里两页的轴一深一浅。绝对色出口是 `View.foregroundStyle(Color.secondary)`。
    static func hierarchicalAxisLabels(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file -> [String] in
            let lines = file.content.split(separator: "\n", omittingEmptySubsequences: false)
                                .map(String.init)
            var hits: [String] = []
            for (index, line) in lines.enumerated() {
                guard SurfaceScanKit.isCode(line), line.contains("AxisValueLabel") else { continue }
                let window = lines[index..<min(index + 8, lines.count)]
                if window.contains(where: {
                    $0.contains(".foregroundStyle(.secondary)") || $0.contains(".foregroundStyle(.tertiary)")
                }) {
                    hits.append("\(file.path):\(index + 1)")
                }
            }
            return hits
        }
    }

    func test_chartAxisLabelsNeverUseHierarchicalStyle() throws {
        let offenders = Self.hierarchicalAxisLabels(in: try SurfaceScanKit.sourceFiles(under: "Views"))
        XCTAssertTrue(offenders.isEmpty,
                      "轴刻度又用了层级前景色，会跟宿主环境连乘变暗（深色态实测 2.2:1），"
                          + "请改绝对色 .foregroundStyle(Color.secondary)：\(offenders)")
    }

    func test_hierarchicalAxisScannerCatchesAndSpares() {
        let bad = [(path: "Views/FakeChart.swift", content: """
            AxisValueLabel {
                Text("50%")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(.secondary)
            }
            """)]
        XCTAssertEqual(Self.hierarchicalAxisLabels(in: bad), ["Views/FakeChart.swift:1"])
        let good = [(path: "Views/FakeChart.swift", content: """
            AxisValueLabel {
                Text("50%")
                    .font(Theme.Typo.monoSmall.font)
                    .foregroundStyle(Color.secondary)
            }
            """)]
        XCTAssertTrue(Self.hierarchicalAxisLabels(in: good).isEmpty, "绝对色的轴刻度被误判")
    }
}
