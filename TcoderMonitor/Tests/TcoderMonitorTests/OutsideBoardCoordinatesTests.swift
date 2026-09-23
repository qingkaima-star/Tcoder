import XCTest
@testable import TcoderMonitor

/// RD-52：榜外坐标的**机器可读者**与**只披露一次**。
///
/// 立案事实（总工实读 main）：榜外块的 id 原先只活在 `scanLimitations` 的中文句里，
/// 而且**同一串在一份报告里出现两次**——
/// 一次在口径句 `DuplicationResult.boardCaliberNote`，一次在扫描边界句
/// `CodeScanCoverage.surfaceNotes` 的「榜外未列重复块坐标：…」。
/// 本仓自扫实测单条 **2,407 个字符**（六个 id，每个都是「绝对路径 ; 绝对路径:行数」拼起来的）。
///
/// ⚠️ 我最初把这条记成「全量坐标被静默截断」，复核后不对：
/// 引擎本来就只点 `DuplicationScan.outsideBoardSampleLimit` 条，未点名的数量在
/// `blocksDroppedByCap` 里 —— 那不是截断。真正的缺陷是"没有承接格 + 印两遍"，
/// 所以修法一条数都不减：**同样多的样本，一次披露，一处落盘**。
///
/// 继承 `SelfScanHarnessCase` 复用那台"一次扫描六个分析器"的缓存（每例各扫一遍本仓太贵）。
final class OutsideBoardCoordinatesTests: SelfScanHarnessCase {

    // MARK: - 正例 + 真仓库对账：字段与句子同源、只出现一次

    func test_coordinatesHaveAContractFieldAndAreNamedExactlyOnce() async throws {
        let metrics = try await selfScan().code
        let coordinates = try XCTUnwrap(metrics.duplicateBlockCoordinatesOutsideBoard,
                                        "扫的是真仓库，榜外坐标这一读数不该缺席（缺席 ≠ 没有榜外块）")
        let dropped = try XCTUnwrap(metrics.duplicatedBlocksDroppedByCap)

        // 定义关系：榜外有块 ⇒ 一定有点名样本；样本数不超过引擎那把封顶尺子。
        if dropped > 0 {
            XCTAssertFalse(coordinates.isEmpty, "榜外有 \(dropped) 块却一个名字都没点 ⇒ 等于没披露")
        }
        XCTAssertLessThanOrEqual(coordinates.count, DuplicationScan.outsideBoardSampleLimit,
                                 "点名的条数由引擎那一把尺子管，界面与句子都不许自己加")
        // 坐标必须是**相对被扫根**的路径。这条不是风格问题：绝对路径会把"仓库被检到哪里"
        // 混进本文件下面那条 ≤1200 字符的判据里（2026-09-23 实测同一条门在 main 树 1,060、
        // 在 .worktrees/perf-base 树 1,740 ⇒ `premerge_check` 只在 worktree 里跑，
        // 于是它会拦下每一条并行流）。判据本身一个字没动，动的是披露串的取数口径。
        XCTAssertTrue(coordinates.allSatisfy { !$0.hasPrefix("/") },
                      "榜外坐标里出现绝对路径 ⇒ 披露长度随检出位置变：\(coordinates.first ?? "")")

        guard let first = coordinates.first else { return }
        let occurrences = (metrics.scanLimitations ?? []).reduce(0) { total, line in
            total + line.components(separatedBy: first).count - 1
        }
        XCTAssertEqual(occurrences, 1,
                       "同一串榜外坐标在一份报告里被抄了 \(occurrences) 遍（口径句与边界句各一遍就是这次要修的形）")
        // 去重的可度量后果：没有任何一条上限说明再被撑成一段散文（修前实测最长 2,407 字符）。
        let longest = (metrics.scanLimitations ?? []).map(\.count).max() ?? 0
        XCTAssertLessThan(longest, 1_200, "单条限制说明被撑到 \(longest) 字符 ⇒ 又有整串坐标被抄进句子了")
    }

    // MARK: - 装配口本身：点名数不缩水，且必须指回落盘字段

    func test_disclosureNamesEverySampleAndPointsAtTheField() {
        let ids = (1...8).map { "block-\($0)" }
        let text = DuplicationResult.coordinateDisclosure(ids, limit: 3)
        XCTAssertTrue(text.contains("点样 3 条"), "散文点了几条要在句子里说清：\(text)")
        for id in ids.prefix(3) {
            XCTAssertTrue(text.contains(id), "样本 \(id) 没被点出来：\(text)")
        }
        XCTAssertTrue(text.contains("另有 5 条样本未写进这句"),
                      "没写进句子的条数必须留在句子里，不许让人以为只有 3 条：\(text)")
        // 两条指路都要在：全量样本在字段里、未点名的块数在计数里。
        XCTAssertTrue(text.contains("duplicateBlockCoordinatesOutsideBoard"),
                      "必须指回落盘字段，读 JSON 的人才不用解析散文：\(text)")
        XCTAssertTrue(text.contains("duplicatedBlocksDroppedByCap"),
                      "榜外块数也要一并指路：\(text)")

        // 恰好点完时不许出现「另有 N 条」这种凭空造出来的余数。
        let exactly = DuplicationResult.coordinateDisclosure(Array(ids.prefix(3)), limit: 3)
        XCTAssertFalse(exactly.contains("另有"), "样本刚好点完却写「另有」：\(exactly)")
        // 空 = 真的没有榜外块，这句要说出来而不是不出声。
        XCTAssertEqual(DuplicationResult.coordinateDisclosure([], limit: 3), "榜外没有剩余块。")
    }

    // MARK: - 反例：把同一串再抄一遍必须被抓到

    /// 元测试性质：上面那条 `occurrences == 1` 的判据必须真能红。
    /// 这里不碰生产代码，直接验"同一条被抄两遍"这个形状会被数出来。
    func test_theDeduplicationRulerActuallyCounts() {
        let sample = "a.swift:1|b.swift:1"
        let lines = ["榜外坐标：\(sample)", "边界：\(sample)"]
        let occurrences = lines.reduce(0) { $0 + ($1.components(separatedBy: sample).count - 1) }
        XCTAssertEqual(occurrences, 2, "数不出两遍 ⇒ 上面那条对账守卫是摆设")
    }

    // MARK: - 缺席态：旧报告缺这个键必须解得开、且读成 nil

    func test_legacyReportWithoutTheCoordinateKeyStillDecodesAsNil() async throws {
        let metrics = try await selfScan().code
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var shape = try JSONSerialization.jsonObject(with: encoder.encode(metrics)) as? [String: Any]
        let hadKey = (shape ?? [:])["duplicateBlockCoordinatesOutsideBoard"] != nil
        shape?["duplicateBlockCoordinatesOutsideBoard"] = nil
        XCTAssertNotEqual(hadKey, false, "前提：新报告本来带着这个键（没键就没有『缺键』这回事）")

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(CodeMetrics.self, from: JSONSerialization.data(withJSONObject: shape ?? [:]))
        XCTAssertNil(back.duplicateBlockCoordinatesOutsideBoard,
                     "缺键 = 这份报告没有这个读数，不许补成空数组（那会被读成「榜外确实没有块」）")
    }
}
