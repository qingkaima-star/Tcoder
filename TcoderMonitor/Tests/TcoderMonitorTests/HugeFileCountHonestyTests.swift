import XCTest
@testable import TcoderMonitor

/// 「巨大文件占比」的分子必须是**真个数**，不是被截断到 20 的榜单长度。
///
/// 这是收官轮真机自扫扫自己时扫出来的一条自我矛盾：界面写「巨大文件占比 10.5%」（20/190），
/// 而 `find` 实测本仓有 38 个文件越过 400 行线（20%）。榜截断是给界面的，
/// 一旦它顺手变成评分的分子，**仓库越大反而越显干净**——这与 #44（两个总体相除）、
/// #46（零证据默认 85 分）是同一类病：读数把问题报小了。
final class HugeFileCountHonestyTests: HealthScoreTestCase {

    /// 造一份「榜单被截断到 20、真值 38」的仓库。
    private func truncatedCode(totalFiles: Int = 190, trueCount: Int? = 38) -> CodeMetrics {
        var code = healthyCode()
        code.totalFiles = totalFiles
        code.hugeFiles = (1...20).map { index in
            FileHotspot(path: "Sources/Module\(index).swift", lineCount: 400 + index,
                        risk: .medium, suggestion: "拆分")
        }
        code.hugeFileCount = trueCount
        return code
    }

    private func codeQuality(of code: CodeMetrics) throws -> ScoreComponent {
        let result = WeightedHealthScorer().score(HealthInputs(code: code))
        return try XCTUnwrap(result.components.first { $0.name == HealthDimension.codeQuality.rawValue },
                             "代码质量维度必须参与计分，实际分量：\(result.components.map(\.name))")
    }

    // MARK: - ① 分子换成真个数之后，分数必须**变差**（这条测试有牙）

    func testTrueCountScoresLowerThanTheCappedList() throws {
        let honest = try codeQuality(of: truncatedCode())
        let legacy = try codeQuality(of: truncatedCode(trueCount: nil))
        XCTAssertLessThan(honest.score, legacy.score,
                          "同样 20 项的榜，真值 38 必须比「按榜内计数」打得更低，实际 \(honest.score) vs \(legacy.score)")
        XCTAssertGreaterThanOrEqual(legacy.score, honest.score + 5,
                                    "差值太小说明这条判据其实没在管占比")
    }

    // MARK: - ② 口径必须写在脸上，不能只换个数字

    func testDetailDisclosesWhenTheListIsTruncated() throws {
        let truncated = try codeQuality(of: truncatedCode())
        XCTAssertTrue(truncated.detail.contains("实际 38 个"),
                      "榜被截断时 detail 必须承认真数，实际：\(truncated.detail)")
        XCTAssertTrue(truncated.detail.contains("榜内只列 20 个"))

        let exact = try codeQuality(of: truncatedCode(trueCount: 20))
        XCTAssertFalse(exact.detail.contains("榜内只列"),
                       "榜没被截断却写截断，是把正确读数说成为口径打折：\(exact.detail)")
    }

    // MARK: - ③ 旧报告缺字段时的退回口径必须是**可判读**的，且不假装知道真值

    func testLegacyMetricsFallBackToTheListWithoutInventingACount() throws {
        let legacy = truncatedCode(trueCount: nil)
        XCTAssertEqual(legacy.reportedHugeFileCount, legacy.hugeFiles.count,
                       "缺 hugeFileCount 时退回榜内计数（偏松），并在 detail 里不写「实际 N 个」")
        XCTAssertTrue(try codeQuality(of: legacy).detail.contains("巨大文件占比"), "退回口径也要给出占比读数")
    }

    // MARK: - ④ 落盘兼容：新增字段必须是 Optional，老 JSON 还得解码得动

    func testLegacyReportJSONWithoutHugeFileCountStillDecodes() throws {
        let code = truncatedCode()
        var dictionary = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(code)) as? [String: Any],
            "CodeMetrics 编码后必须是 JSON 对象")
        XCTAssertTrue(dictionary.keys.contains("hugeFileCount"), "前置条件：新字段确实被编码出去了")
        dictionary.removeValue(forKey: "hugeFileCount")
        let decoded = try JSONDecoder().decode(CodeMetrics.self,
                                              from: try JSONSerialization.data(withJSONObject: dictionary))
        XCTAssertNil(decoded.hugeFileCount)
        XCTAssertEqual(decoded.reportedHugeFileCount, 20)
    }

    // MARK: - ⑤ 不变量：真个数不得小于榜内条数（少了就是扫描器自己算错）

    func testTrueCountNeverUnderstatesTheList() {
        let code = truncatedCode(trueCount: 7)   // 故意喂一个自相矛盾的输入
        XCTAssertLessThanOrEqual(code.reportedHugeFileCount, code.hugeFiles.count,
                                 "字段本身不裁剪输入：报告里说什么就用什么，别静默「取个更好看的」")
    }
}
