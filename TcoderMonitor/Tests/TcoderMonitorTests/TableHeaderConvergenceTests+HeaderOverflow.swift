import Foundation
import XCTest
@testable import TcoderMonitor

// MARK: - 表头不许被裁（溢出/截断轴的第一条静态判据）
//
// 来历：`scripts/ax_truncation_sweep.sh` 第一次跑英文态九页，抓到重复块表头渲染成
// 「Occurren…」（`DataGridColumn("出现", 56)` 中文够、"Occurrences" 要 67pt），
// 以及热点榜「圈复杂度」62pt 对 "Cyclomatic Complexity" 119pt。
// 修法是**表头允许折两行**（`tableHeaderCell`），数据行仍"宁可截不可撑"
// （数字折行会把整行抬高、五列基线全断——那条理由只管数据行）。
//
// 这条守卫钉的是**别改回去**：表头一旦重新走 `tableCell`，英文态就会再裁一次列名，
// 而那件事在中文态**完全看不出来**（中文列名都短）。扫描器要起 GUI、要无障碍权限，
// 进不了门禁；所以这里钉形状，扫描器当周期复核。

extension TableHeaderConvergenceTests {

    /// 在 `Design/DataTable.swift` 里找 `DataTableHeader` 的表体那一段。
    static func headerBody(of content: String) -> String? {
        let lines = SurfaceScanKit.codeLines(content)
        guard let start = lines.firstIndex(where: { $0.contains("struct DataTableHeader") }) else { return nil }
        return lines[start...].prefix(while: {
            !$0.trimmingCharacters(in: .whitespaces).hasPrefix("}")
        }).joined(separator: "\n")
    }

    func test_tableHeadersWrapInsteadOfClipping() throws {
        let path = "Design/DataTable.swift"
        let content = try String(contentsOfFile:
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Sources/TcoderMonitor/\(path)").path, encoding: .utf8)
        let header = try XCTUnwrap(Self.headerBody(of: content),
                                   "找不到 struct DataTableHeader —— 表头搬家了，这条守卫要跟着搬")
        XCTAssertTrue(header.contains(".tableHeaderCell("),
                      "表头没走 tableHeaderCell ⇒ 英文列名会被 lineLimit(1) 裁成「Occurren…」")
        XCTAssertFalse(header.contains(".tableCell("),
                       "表头又搭回数据行那一格（宁可截不可撑）——英文态列名重新被裁")

        // 数据行那条规矩必须原样还在：两半各守自己的理由，不能被"统一一下"抹平。
        let cells = content.components(separatedBy: "func tableCell(_ column: DataGridColumn)")
        XCTAssertGreaterThanOrEqual(cells.count, 2, "tableCell 不见了？数据行的定宽规矩无处安放")
        XCTAssertTrue(cells[1].contains(".lineLimit(1)"),
                      "数据行的 lineLimit(1) 被摘掉了 ⇒ 一个 +1,234,567 就会把整行抬高、五列基线全断")
    }

    /// 元测试：把两种坏形状喂进去，必须各红一次。
    func test_headerOverflowRulerCatchesBothRegressions() {
        let clipped = """
            struct DataTableHeader: View {
                var body: some View {
                    Text("x").tableCell(column)
                }
            }
            """
        XCTAssertFalse(Self.headerBody(of: clipped)!.contains(".tableHeaderCell("),
                       "被裁的表头形状没被抓到 ⇒ 这条守卫数不出东西")
        let good = """
            struct DataTableHeader: View {
                var body: some View {
                    Text("x").tableHeaderCell(column)
                }
            }
            """
        XCTAssertTrue(Self.headerBody(of: good)!.contains(".tableHeaderCell("))
        XCTAssertNil(Self.headerBody(of: "struct Other {}"), "表体找不到时要返回 nil，不能返回空串装活")
    }
}
