import XCTest
@testable import TcoderMonitor

// OWNER: 总工（检测正确性整改轮 · RD-18）
//
// 钉住「巨大文件」这一族的三个读数一律走真总数 `CodeMetrics.reportedHugeFileCount`。
// 由来：分析器把榜截在 `prefix(20)`，而屏上那格与页尾那句直接读 `code.hugeFiles.count`，
// 于是"实际 552 个"在界面上长成"20 个"，页尾还会写"已全部展示"。
// 真总数一直存在（`hugeFileCount`），评分侧也早就会用 —— 缺的是展示层没用它。

final class HugeFileReadoutGuardTests: XCTestCase {

    private static let needle = "hugeFiles.count"

    // MARK: - 纯函数口径（真值手写，不取自实现输出）

    func test_reportedTotalPrefersRealCountOverBoardLength() {
        var code = CodeMetrics()
        code.hugeFiles = []
        code.hugeFileCount = 552
        XCTAssertEqual(code.reportedHugeFileCount, 552, "真总数存在时不许退回榜长")
    }

    func test_reportedTotalFallsBackToBoardLengthWhenRealCountMissing() {
        // 旧报告没有 hugeFileCount 这一格 ⇒ 只能退回榜长，这是**偏松**方向，必须写明。
        var code = CodeMetrics()
        code.hugeFileCount = nil
        XCTAssertEqual(code.reportedHugeFileCount, code.hugeFiles.count)
    }

    func test_truncationNoteStatesRealTotalWhenBoardIsCapped() {
        var code = CodeMetrics()
        code.hugeFileCount = 552
        XCTAssertEqual(CodeHotspotSection.truncationNote(code, shown: 8),
                       "当前列出 8 / 552 个。")
    }

    func test_truncationNoteOnlyClaimsFullDisplayWhenNothingIsHidden() {
        var code = CodeMetrics()
        code.hugeFileCount = 8
        XCTAssertEqual(CodeHotspotSection.truncationNote(code, shown: 8),
                       "共 8 个，已全部展示。")
    }

    // MARK: - 展示层扫描守卫（扫的是目录，不是文件名）

    func test_hugeFileReadoutsNeverUseBoardLength() throws {
        let files = try SurfaceScanKit.sourceFiles(under: "Views/Code")
        XCTAssertFalse(files.isEmpty, "扫不到 Views/Code ⇒ 这条守卫一声不吭地通过")
        // 分母闸：判据至少要管到一格，否则"0 违例"只是扫法失效。
        let found = anchors(in: files)
        print("巨大文件读数守卫：现量 计数格 \(found.countReadoutSites) · 页尾句 \(found.noteBodies)")
        XCTAssertGreaterThanOrEqual(found.countReadoutSites, 1,
                                    "没有任何一格在读巨大文件的个数 —— 被搬走就要同批把这条守卫搬过去")
        XCTAssertGreaterThanOrEqual(found.noteBodies, 1,
                                    "truncationNote 不在场 —— 页尾那句没人管了")
        let hits = violations(in: files)
        XCTAssertTrue(hits.isEmpty, "巨大文件读数还在用榜长：\n" + hits.joined(separator: "\n"))
    }

    // MARK: - 元测试：守卫必须抓得住坏样例、且不误伤合法写法

    func test_meta_catchesSyntheticBoardLengthReadout() {
        let bad = """
                    DataReadout(label: "巨大文件", value: NumberFormat.grouped(code.hugeFiles.count),
                                unit: "个")
        """
        XCTAssertEqual(violations(in: bad, path: "Synthetic.swift").count, 1,
                       "坏样例没被抓到 = 这条守卫是永真绿")
    }

    func test_meta_sparesReportedTotalReadout() {
        let good = """
                    DataReadout(label: "巨大文件", value: NumberFormat.grouped(code.reportedHugeFileCount),
                                unit: "个")
        """
        XCTAssertTrue(violations(in: good, path: "Synthetic.swift").isEmpty)
    }

    func test_meta_ignoresNeedleAppearingOnlyInComments() {
        // 讲代码的话不算代码：这条注释里就写着 needle，守卫不许被它绊倒。
        let commented = """
            // 别再写 code.hugeFiles.count，那是榜长
                        DataReadout(label: "巨大文件", value: NumberFormat.grouped(code.reportedHugeFileCount),
                                    unit: "个")
        """
        XCTAssertTrue(violations(in: commented, path: "Synthetic.swift").isEmpty,
                      "剥注释没生效 —— 以后谁在注释里解释这条判据就被判红")
    }

    func test_meta_catchesSyntheticTruncationNoteTotal() {
        let bad = """
            static func truncationNote(_ code: CodeMetrics, shown: Int) -> String {
                let total = code.hugeFiles.count
                return "共 \\(NumberFormat.grouped(total)) 个，已全部展示。"
            }
        """
        XCTAssertEqual(violations(in: bad, path: "Synthetic.swift").count, 1)
    }

    func test_meta_adviceLabelIsNotCountedAsReadoutSite() {
        // 反向样本：建议行里也写着 `label: "巨大文件"`，它不是读数格，不许进分母
        // （否则"把那一格删掉"还能靠建议行把守卫喂成"锚点还在"的假安心）。
        let adviceOnly = """
                        id: "huge-file", label: "巨大文件", icon: .duplicate,
                        role: Theme.Semantic.role(for: largest.risk),
                        text: localizedFormat("最大文件 %1$@ 共 %2$@ 行", a, b, c)
        """
        XCTAssertEqual(anchors(in: [(path: "Advice.swift", content: adviceOnly)]).countReadoutSites, 0)
    }

    // MARK: - 判据本体

    private struct Anchors { var countReadoutSites = 0; var noteBodies = 0 }

    /// 只有带 `value:` 的那一格才是"读数"；建议行里 `label: "巨大文件"` 是卡名，不当分母。
    private func anchors(in files: [(path: String, content: String)]) -> Anchors {
        var result = Anchors()
        for file in files {
            let lines = visibleCodeLines(file.content)
            for (offset, line) in lines.enumerated() {
                if line.text.contains("label: \"巨大文件\""),
                   readoutWindow(lines, at: offset).contains("value:") {
                    result.countReadoutSites += 1
                }
                if line.text.contains("static func truncationNote") { result.noteBodies += 1 }
            }
        }
        return result
    }

    private func readoutWindow(_ lines: [(number: Int, text: String)], at offset: Int) -> String {
        lines[offset..<min(offset + 3, lines.count)].map(\.text).joined(separator: "\n")
    }

    private func violations(in files: [(path: String, content: String)]) -> [String] {
        files.flatMap { violations(in: $0.content, path: $0.path) }
    }

    private func violations(in content: String, path: String) -> [String] {
        let lines = visibleCodeLines(content)
        var hits: [String] = []

        // ① 「巨大文件」那一格：本行 + 之后两行算一个调用区。
        for (offset, line) in lines.enumerated() where line.text.contains("label: \"巨大文件\"") {
            let end = min(offset + 3, lines.count)
            let window = lines[offset..<end].map(\.text).joined(separator: "\n")
            if window.contains(Self.needle) {
                hits.append("\(path):\(line.number) 巨大文件那格读的是榜长 \(Self.needle)")
            }
        }

        // ② 页尾那句：函数体之内不许出现 needle。
        var insideNote = false
        for line in lines {
            if line.text.contains("static func truncationNote") { insideNote = true }
            guard insideNote else { continue }
            if line.text.contains(Self.needle) {
                hits.append("\(path):\(line.number) 页尾「共 N 个」的分母读的是榜长")
            }
            if line.text.trimmingCharacters(in: .whitespaces) == "}" { insideNote = false }
        }
        return hits
    }

    /// 只剥整行注释（`//` 开头），不动行内代码；行数按原始行号报，避免命中信息指错地方。
    private func visibleCodeLines(_ content: String) -> [(number: Int, text: String)] {
        var out: [(number: Int, text: String)] = []
        for (index, raw) in content.components(separatedBy: "\n").enumerated() {
            if raw.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
            out.append((index + 1, raw))
        }
        return out
    }
}
