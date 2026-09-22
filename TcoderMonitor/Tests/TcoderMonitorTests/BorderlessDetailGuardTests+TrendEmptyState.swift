import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 批次 P23：趋势卡的空态不许用「整页那一档」
//
// `EmptyStateView` 自带 `emptyMinHeight`（140pt）最小高，那一档的判据是
// 「这一整块只有空态」；而趋势卡的卡头已经把"这块渲染了"说完了，
// 再垫 140 就只剩空洞（健康评分页尾实拍：卡 290pt 高、最后一行字停在 0.800 处）。
// 卡内那一档全站早有现成画法 = `SectionEmptyNote`（错误趋势卡一直在用它）。
// 这条守卫钉的是：**承载定高趋势图的文件不许再出现 `EmptyStateView`**。

extension BorderlessDetailGuardTests {

    /// 判据：文件里既引用 `trendChartHeight`（= 它承载一张定高趋势图），
    /// 又出现 `EmptyStateView(` ⇒ 记名。
    ///
    /// 只看代码行：注释里提到 `EmptyStateView` 不算用了它（本轮的说明注释就有）。
    static func trendFilesUsingPageLevelEmptyState(in files: [(path: String, content: String)]) -> [String] {
        files.compactMap { file in
            let code = SurfaceScanKit.codeLines(file.content).joined(separator: "\n")
            guard code.contains("trendChartHeight") else { return nil }
            return code.contains("EmptyStateView(") ? file.path : nil
        }
    }

    func test_trendChartCardsUseTheInCardEmptyState() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views")
        // 总体必须非空且就是这三家 —— 否则"0 处违规"是假零（尺子没扫到东西的通过）。
        let carriers = files.filter { $0.content.contains("trendChartHeight") }.map { $0.path }.sorted()
        XCTAssertEqual(carriers, [
            "Views/Git/GitInsightsView.swift",
            "Views/Health/HealthAdviceCards.swift",
            "Views/Logs/LogsTrendCard.swift",
        ], "承载定高趋势图的文件名单变了：先分清是搬家还是新增，再回来改这条总体口径")

        let offenders = Self.trendFilesUsingPageLevelEmptyState(in: files)
        XCTAssertTrue(offenders.isEmpty,
                      "这些趋势卡的空态用了整页那一档（140pt 最小高会撑出一段没有字的白）：\(offenders)")
    }

    /// 元测试：这条尺子喂得出东西。三个方向各一个样例 —— 该抓的抓到、
    /// 用对画法的别误伤、没有趋势图的整页空态更别误伤。
    func test_trendEmptyStateScannerCatchesPageLevelEmptyState() {
        let bad = [(path: "Views/FakeTrend.swift", content: """
            LogTrendChart(buckets: buckets).frame(height: Theme.Layout.trendChartHeight)
            EmptyStateView(icon: .chartLine, title: "点不足", message: "这里不画线。")
            """)]
        XCTAssertEqual(Self.trendFilesUsingPageLevelEmptyState(in: bad), ["Views/FakeTrend.swift"],
                       "整页那一档的空态没被抓到 ⇒ 这条守卫数不出东西")

        let pinned = [(path: "Views/FakeTrend.swift", content: """
            LogTrendChart(buckets: buckets).frame(height: Theme.Layout.trendChartHeight)
            SectionEmptyNote(text: "暂无趋势数据。", icon: .chartLine)
            """)]
        XCTAssertTrue(Self.trendFilesUsingPageLevelEmptyState(in: pinned).isEmpty, "用对画法的被误判")

        let pageLevel = [(path: "Views/FakePage.swift", content: """
            // 这里没有趋势图，整页空态本来就该用 EmptyStateView(
            EmptyStateView(icon: .people, title: "尚未分析", message: "点「重新分析」。")
            """)]
        XCTAssertTrue(Self.trendFilesUsingPageLevelEmptyState(in: pageLevel).isEmpty,
                      "没有趋势图的整页空态被误伤")
    }
}
