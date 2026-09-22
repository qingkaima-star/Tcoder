import XCTest
@testable import TcoderMonitor

// MARK: - 尺子的元测试：`subtitleHelp:` / `captionHelp:` 这类新标签必须进账
//
// 从 `TooltipMigrationGuardTests.swift` 拆出来住（那个文件加完这条就 423 行，
// 撞上 `X3TestSizeAuditTests` 与产品同源的 400 行口径）。判据本体一字未改。

extension TooltipMigrationGuardTests {

    /// 同一条判据要沿到**新开的两个标签**上。S7 交回时点名：`subtitleHelp:` / `captionHelp:`
    /// 大小写与 `\\bhelp:` 不匹配 ⇒ 按「一个参数一行」排版的整句被判成 `.skipped`，
    /// **A 与 B 同时看不见它**（搬进去 A 降、总量也降，守恒线撞不出红）——
    /// 而 B 存在的全部理由就是"别让搬字变成删字"。这条元测试钉的就是那个形状。
    func test_meta_newHelpLabelsAreCountedAsHiddenNotSkipped() {
        let hoverted = [(path: "Views/Fake.swift", content: """
        GlassSection("健康评分",
                     subtitle: "综合 76 分",
                     subtitleHelp: "综合分 = Σ（得分 × 归一化权重），缺席维度不参与计分也不按 0 计入") {
            EmptyView()
        }
        """)]
        let (visible, tooltip) = Self.scan(hoverted)
        XCTAssertEqual(tooltip.count, 1, "单独一行的 `subtitleHelp:` 没被算成已藏 —— 尺子在漏计")
        XCTAssertTrue(visible.isEmpty, "同一句既算常驻又算已藏，A/B 会互相圆场：\(visible)")
        let captioned = [(path: "Views/Fake.swift", content: """
        MetricTile(title: "内存",
                   captionHelp: "口径 = 总量 −（空闲 + 推测 + 可清除），这是「在用」不是「剩余可用」")
        """)]
        XCTAssertEqual(Self.scan(captioned).tooltip.count, 1)
        // 反向：这句要是被整行删掉，必须让总量掉下来（不是"看不见"）。
        let deleted = [(path: "Views/Fake.swift", content: """
        GlassSection("健康评分",
                     subtitle: "综合 76 分") {
            EmptyView()
        }
        """)]
        let after = Self.scan(deleted)
        XCTAssertTrue(after.tooltip.isEmpty && after.visible.count <= 1,
                      "删掉整句却什么都没少 ⇒ 这条线抓不住删除：" + "\(after)")
    }

}
