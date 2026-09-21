/// OWNER: WS-X3 TestSplit —— 自 CodeGitBorderlessTests.swift 拆出，颜色只承载语义：数据色不撞 accent、井只来自 kit、表格必坐井。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension CodeGitBorderlessTests {

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

    /// 色板 0 号位（"主/自身数据"）在本流**一处都不许用**：本轮 ChartSeries 收口后，
    /// "自身/合计"的画法就是 `ChartSeries.lineColor` 纯墨，索引色只留给**按 key 分辨类别**
    /// （语言占比条、作者占比条的成员行）。
    /// 本流历史上是 3 处：趋势柱、24×7 矩阵（都属单序列），以及贡献者集中度表的
    /// "前 3 名合计"——最后这处与总览那两处「182,430 涂成 info 蓝」同形状，一并收墨。
    func test_aggregatePaletteIndexIsReservedForTotalRows() throws {
        let hits = Self.aggregateIndexUses(in: try Self.pageSourceFiles())
        XCTAssertTrue(hits.isEmpty,
                      "色板 0 号位在本流应为 0 处：单序列与合计都改 ChartSeries.lineColor。实测：\(hits)")
    }

    /// 我引进的原语必须真有人用，否则本守卫的若干「零命中即通过」会变成空跑。
    func test_newPrimitivesAreActuallyWired() throws {
        let pages = try Self.pageSourceFiles(dirs: Self.pageDirs)
        for needle in ["DataReadoutBand", "DataTableWell", "DataFootnote", "GroupStack"] {
            XCTAssertTrue(pages.contains { $0.content.contains(needle) },
                          "基座原语 \(needle) 没有任何页面在用 —— 它要么该删，要么五页还没改完")
        }
    }

    func test_pagesDoNotDrawMaterialsOrRawCorners() throws {
        let files = try Self.pageSourceFiles()
        let materials = Self.materialUses(in: files)
        XCTAssertTrue(materials.isEmpty,
                      "页面散写材质填充。`.regularMaterial` 是 M0 刚从内容层砍掉的东西"
                          + "（背后无内容时退化成平涂半透明灰，比页面底暗 6~13 阶）：\(materials)")
        let corners = Self.rawCornerRadius(in: files)
        XCTAssertTrue(corners.isEmpty,
                      "页面写死圆角数字。要走 `.surface(shape: .rounded(Theme.Radius.*))`："
                          + "\(corners)")
    }

    /// SwiftUI **形状构造**里的裸圆角：`RoundedRectangle(cornerRadius: 4)`。
    ///
    /// 判据刻意只认这个形状，不认 `Path(roundedRect:cornerRadius:)` —— 后者是
    /// Core Graphics 的图表几何（WS-I §9 豁免，`GitActivityHeatmap` 的柱子与
    /// `ContributorHourRow` 的 Canvas 都在用），旧守卫的「数字尺寸」那条也只禁
    /// `width/height:` 而不禁 `cornerRadius`。判据越界就会把合法写法逼成绕路写法。
    static func rawCornerRadius(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { file in
            numberedCodeLines(file.content).compactMap { entry in
                guard let r = entry.text.range(of: "RoundedRectangle(cornerRadius:") else { return nil }
                let tail = entry.text[r.upperBound...].drop(while: { $0 == " " })
                return tail.first?.isNumber == true
                    ? "\(file.path):\(entry.n): \(entry.text.prefix(56))" : nil
            }
        }
    }

}
