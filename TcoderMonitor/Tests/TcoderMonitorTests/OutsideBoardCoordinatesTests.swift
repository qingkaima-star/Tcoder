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

        guard let first = coordinates.first else { return }
        let occurrences = (metrics.scanLimitations ?? []).reduce(0) { total, line in
            total + line.components(separatedBy: first).count - 1
        }
        XCTAssertEqual(occurrences, 1,
                       "同一串榜外坐标在一份报告里被抄了 \(occurrences) 遍（口径句与边界句各一遍就是这次要修的形）")
        // 去重的可度量后果：**句子里说点几条、实际就列几条，且不超过生产者那把尺子**。
        // 注意为什么不能用「竖线数」或「字符数」当代理：一条榜外坐标是
        // `DuplicatedBlock.id`（ occurrences 的路径用 `|` 连起来 + `:行数`），
        // 一个块有三处克隆就带两个 `|` —— 我第一版拿 `|` 数当条数，实测 3 条坐标数出 5 条，
        // 判了一条不存在的缺陷（本仓记过的那族：语义守卫不许挂长度代理）。
        let longestLine = (metrics.scanLimitations ?? []).max(by: { $0.count < $1.count }) ?? ""
        let disclosed = try XCTUnwrap(Self.disclosedCoordinates(in: longestLine),
                                      "最长那条限制说明里找不到榜外坐标段 ⇒ 生产者的措辞改了，这条判据在空转")
        XCTAssertEqual(disclosed.declared, disclosed.listed,
                       "句子自己说点 \(disclosed.declared) 条、实际列了 \(disclosed.listed) 条 ⇒ 说的数与列的数分了家")
        XCTAssertLessThanOrEqual(disclosed.listed, 3,
                                 "散文里点名了 \(disclosed.listed) 条榜外坐标 ⇒ 条数不再由 `coordinateDisclosure` "
                               + "那一把尺子管（全量在字段里，散文只负责让人看到长什么样）")
        // 再量一次「没被撑成散文」。**必须先归一化再量**（RD-61）：坐标目前是绝对路径，
        // 同一份内容换个 checkout 目录长度就变——2026-09-23 实测主树 1,060 字符（过）
        // 与 `.worktrees/r21-backlog` 那棵树 1,244 字符（判红），一把随盘的路径深度变的尺子
        // 不是判据。真正要钉的是「坐标文本占了多少句」，与仓库放在哪无关。
        let longest = Self.normalizeRoots(longestLine).count
        XCTAssertLessThan(longest, 1_200,
                          "单条限制说明（去掉仓库绝对前缀后）仍有 \(longest) 字符 ⇒ 又有整串坐标被抄进句子了")
    }

    /// 从一句披露文本里读出「说了几条 / 列了几条」。读不出来返回 `nil`（调用方判红，不静默通过）。
    static func disclosedCoordinates(in line: String) -> (declared: Int, listed: Int)? {
        let head = "榜外坐标（点样 "
        guard let headRange = line.range(of: head),
              let declared = Int(line[headRange.upperBound...].prefix { $0.isNumber }) else { return nil }
        guard let colon = line.range(of: "：", range: headRange.upperBound..<line.endIndex) else { return nil }
        var tail = line[colon.upperBound...]
        for stopper in ["；另有", "（全部"] {
            if let cut = tail.range(of: stopper) { tail = tail[..<cut.lowerBound] }
        }
        let listed = tail.split(separator: " ; ", omittingEmptySubsequences: true).count
        return (declared, listed)
    }

    /// 元测试（双向）：生产者自己的输出必须读得通，抄多了必须数得出来。
    /// 不配这一条，上面那个 `disclosedCoordinates` 就是一个"解析不出来就当没事"的橡皮章。
    func test_meta_theCoordinateCounterReadsTheProducersOwnSentence() {
        let eight = (1...8).map { "block-\($0)|pair-\($0):\($0)" }
        let honest = DuplicationResult.coordinateDisclosure(eight, limit: 3)
        let read = Self.disclosedCoordinates(in: "前文。" + honest + "后文。")
        XCTAssertEqual(read?.declared, 3, "生产者说点 3 条：\(read as Any)")
        XCTAssertEqual(read?.listed, 3, "实际也列 3 条：\(read as Any)")
        let inflated = "榜外坐标（点样 3 条）：A|B:1 ; C|D:2 ; E|F:3 ; G|H:4（全部 8 条样本见 x）。"
        XCTAssertEqual(Self.disclosedCoordinates(in: inflated)?.listed, 4,
                       "句子说 3 条却列了 4 条 ⇒ 必须数得出来，否则这条判据是橡皮章")
        XCTAssertNil(Self.disclosedCoordinates(in: "这一句根本没有榜外坐标段"))
    }

    /// 把「被扫根」那段绝对路径折成一个定长记号，使长度判据不随仓库放在哪变。
    /// 只折**本仓自己那棵树的前缀**，别的路径原样留着 —— 否则等于把量纲抹平。
    static func normalizeRoots(_ text: String) -> String {
        let root = Self.repoRootOfCheckout.path + "/"
        return text.replacingOccurrences(of: root, with: "<repo>/")
    }

    /// 这棵 checkout 的仓库根（`Tests/TcoderMonitorTests/<本文件>` 往上三层是包根、再往上是仓库根）。
    static let repoRootOfCheckout: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor
        .deletingLastPathComponent()   // 仓库根

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
