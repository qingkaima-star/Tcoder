/// OWNER: WS-X3 TestSplit —— 自 PerfLogsBorderlessTests.swift 拆出，分组间距档位、单一骨架、面积图顶透明度与分类色板的用法。用例本体未改，只是搬了家。
import Foundation
import XCTest
@testable import TcoderMonitor

extension PerfLogsBorderlessTests {

    func test_groupSpacingTiersAreAtLeast24() {
        XCTAssertGreaterThanOrEqual(Theme.Spacing.group, 24)
        XCTAssertGreaterThanOrEqual(Theme.Spacing.section, 24)
        XCTAssertGreaterThanOrEqual(Theme.Spacing.pageMargin, 24)
    }

    func test_ownedPagesShareTheOneBaseSkeleton() throws {
        // 本流一度自造过一份 `BorderlessPage`（因为基座 `Theme.Page.Scaffold` 组间距写死 16）。
        // 总工 `48443d9` 把基座换成 pageMargin/group/section 三档，并钉了「全仓只许一份页骨架」，
        // 所以那份已删除、三页改回基座。这里反过来钉住**结果**：
        //   ① 三页都走基座那份；② 本流域里不许再出现第二份骨架声明。
        let files = try ownedFiles()
        let ownScaffold = Self.hits(in: files, where: { line in
            // 与总工那份 `pageScaffoldDeclarations` 同一判据形状（先 trim 再认 `struct …: View`），
            // 否则缩进里的声明会漏 —— 两把尺子必须同形状才比得出差异。
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("struct ") && trimmed.contains(": View")
                && (trimmed.contains("Scaffold") || trimmed.contains("BorderlessPage"))
        })
        XCTAssertTrue(ownScaffold.isEmpty,
                      "本流域里又长出了第二份页骨架（只许用 `Theme.Page.Scaffold`）：\(ownScaffold)")
        for page in ["PerformanceView", "LogsView", "HealthView"] {
            XCTAssertTrue(files.contains { $0.path.hasSuffix("\(page).swift")
                && $0.content.contains("Theme.Page.Scaffold(") },
                          "\(page).swift 没走基座页骨架，组间距就不受 `Spacing.group` 那条断言保护")
        }
    }

    func test_ownedPagesDoNotOwnAPageHeaderType() throws {
        // 「页头」这件事全仓只许一套画法，归 WS-O 的 `ProjectDetailView` / `Views/Shell/**`。
        // 本流域曾养过一份 `PerfLogsPageHeader`（三页共用），已按总工裁定删除：
        // 页面目录里再出现任何 `struct …PageHeader…: View` 就是第二套页头。
        let files = try ownedFiles()
        let headers = Self.pageHeaderDeclarations(in: files)
        XCTAssertTrue(headers.isEmpty,
                      "页面目录里养着第二套页头（归 WS-O）：\(headers)")
        // 反向：三页各自写**页内小标题**（页名 + 本页口径），不依赖任何共用页头件。
        for (page, title) in [("PerformanceView", "性能监控"),
                              ("LogsView", "错误日志分析"),
                              ("HealthView", "健康评分")] {
            let file = try XCTUnwrap(files.first { $0.path.hasSuffix("\(page).swift") })
            XCTAssertTrue(file.content.contains("Text(\"\(title)\")"),
                          "\(page) 的页名不在本页里 → 页内小标题被抽走或改名了")
        }
    }

    func test_noContainerWrapsGlassSectionsInTightSpacing() throws {
        let hits = Self.containersTighteningGroups(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty, "直接包着 `GlassSection` 的容器用了低于 24 的间距：\(hits)")
    }

    func test_areaTopOpacityIsDefinedByTheToken() throws {
        let chrome = try XCTUnwrap(
            try ownedFiles().first { $0.path.hasSuffix("ChartChrome.swift") },
            "扫不到 ChartChrome.swift —— 这条判据会在空气上通过")
        let hits = Self.areaOpacityDefinitionsNotUsingToken(in: [chrome])
        XCTAssertTrue(hits.isEmpty,
                      "面积顶色又变回页面自己养的常量（本轮病因「令牌定义了没人用」原样复发）：\(hits)")
    }

    func test_areaTopOpacityEqualsTheSoftTokenAndNotTheHeavyOne() {
        XCTAssertEqual(ChartSeries.areaTopOpacity, Theme.Palette.Opacity.gradientAreaSoft,
                       accuracy: 0.0001, "顶色必须等于 `Opacity.gradientAreaSoft`")
        XCTAssertNotEqual(ChartSeries.areaTopOpacity, Theme.Palette.Opacity.gradientTop,
                          accuracy: 0.0001, "0.30 在密集实时曲线上过浓（总工截图复核问题 1）")
    }

    func test_ownedPagesDrawNoCategoryPaletteSeries() throws {
        let hits = Self.categoryPaletteUses(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty,
                      "三页每张图只有一条序列，分类板在这里没有对手可分辨：\(hits)")
    }

    func test_noInteractiveColorOnTileTints() throws {
        let hits = Self.interactiveTintOnTiles(in: try ownedFiles())
        XCTAssertTrue(hits.isEmpty,
                      "读数被涂成交互色（蓝同时是链接与选中色，一色二义）：\(hits)")
    }

    func test_noSeriesColorOnTileTints() throws {
        let hits = Self.seriesColoredTiles(in: try ownedFiles().filter {
            $0.path.hasPrefix("Views/Performance/")
        })
        XCTAssertTrue(hits.isEmpty,
                      "序列色属于图与图例，不属于数字：磁盘/网络那两枚曾经就是 `tint: ChartSeries.color(.disk)`：\(hits)")
    }

}
