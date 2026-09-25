import XCTest
@testable import TcoderMonitor

/// RD-48：重复明细榜"榜外那一半"落成字段之后的对账守卫。
///
/// 立案事实（总工实读，不是推测）：`DuplicationEngine` 早就算清
/// `blocksDroppedByCap` / `linesOutsideReportedBlocks` / `fragmentsDroppedByBudget` / `filesHittingLineCap`，
/// 但契约里没有承接格 ⇒ 这四个数**只活在 `scanLimitations` 那句中文里**，
/// 界面要显示"明细榜上限 20 块"只能按句式去认领那句话
/// （`CodeBoardTruth.outsideBoardNote`；引擎改文案而标记没改，披露就静默消失）。
///
/// ⚠️ 这里**不断言**"榜内 + 榜外 == 原始命中数"：撞 id 削掉的那几块在契约里没有承接格
/// （原始命中数根本没落盘，只有 `CodeMetrics` 这三格）。守恒式由
/// `DuplicateIdCollisionConservationTests` 在纯函数 `rankedBlocks` 那头量（RD-85 落了第三格）。
///
/// 继承 `SelfScanHarnessCase` 只为复用那台"一次扫描六个分析器"的缓存 —— 每个用例各扫一遍本仓太贵。
final class DuplicateBoardAccountingTests: SelfScanHarnessCase {

    // MARK: - 字段 ↔ 引擎台账句：同一批数，两种呈现必须同源

    func testFieldsAndLedgerSentenceSayTheSameNumbers() async throws {
        let metrics = try await selfScan().code

        XCTAssertEqual(metrics.duplicatedBlockLimit, DuplicationEngine.maxBlocks,
                       "上限必须直传引擎那一份，不在界面侧另抄一个 20")
        XCTAssertLessThanOrEqual(metrics.duplicatedBlocks.count, DuplicationEngine.maxBlocks)

        let dropped = try XCTUnwrap(metrics.duplicatedBlocksDroppedByCap, "扫的是真仓库，榜外计数不该缺席")
        let outsideLines = try XCTUnwrap(metrics.duplicatedLinesOutsideReportedBlocks)
        let fragments = try XCTUnwrap(metrics.duplicateFragmentsNotExpandedCount)
        XCTAssertGreaterThanOrEqual(dropped, 0)
        XCTAssertGreaterThanOrEqual(outsideLines, 0)
        XCTAssertGreaterThanOrEqual(fragments, 0)

        // 截断的定义：榜外有块 ⇒ 榜一定满了。反向不成立（榜满也可能恰好没有第 21 块）。
        if dropped > 0 {
            XCTAssertEqual(metrics.duplicatedBlocks.count, DuplicationEngine.maxBlocks,
                           "榜外还有 \(dropped) 块没列、榜内却不满上限 ⇒ 两个来源有一个在说谎")
        }

        let sentence = metrics.scanLimitations?.first { $0.contains(CodeBoardTruth.outsideBoardMarker) }
        if dropped > 0 || outsideLines > 0 {
            let note = try XCTUnwrap(sentence, "榜外有数却没产出台账句 ⇒ 有一边漏了")
            XCTAssertTrue(note.contains(String(dropped)), "台账句要含榜外块数 \(dropped)：\(note)")
            XCTAssertTrue(note.contains(String(outsideLines)), "台账句要含榜外行数 \(outsideLines)：\(note)")
        } else {
            XCTAssertNil(sentence, "榜外是 0 就不该渲染一句被截断（那是把没发生的事画出来）")
        }
        print("【RD-48 对账】榜内 \(metrics.duplicatedBlocks.count) · 榜外 \(dropped) 块 / \(outsideLines) 行"
            + " · 未展开拷贝 \(fragments) 处 · 触线文件 \(metrics.duplicateFilesHittingLineCap ?? -1)")
    }

    // MARK: - 页尾那句改由字段装配

    /// RD-85 的另一半：这一格必须被**真实扫描**填上，而不是只被我的夹具填上。
    /// 立案理由（不配这条用例就是假绿）：守恒那三条量的是纯函数 `rankedBlocks`，
    /// 把 `FileSystemCodeAnalyzer.applyDuplicationBoardTruth` 里那行直传**整行删掉**，
    /// 三条照样全绿 —— 而屏上那一格永远读不到数。这正是「入口少一个参数 = 造出一个假无」那族。
    /// 读数同时落一份仓库内台账并读回来比对（§6.1：判据读数不许只有 `print` 一个出口）。
    func testRealScanFillsTheCollisionFieldAndTheLedgerAgrees() async throws {
        let metrics = try await selfScan().code
        let merged = try XCTUnwrap(metrics.duplicatedBlocksDroppedByIdCollision,
                                   "真扫一份仓库却不填这一格 ⇒ 引擎到契约那行直传没接上")
        XCTAssertGreaterThanOrEqual(merged, 0)
        // RD-86 的另一半：坐标那一格也要被真实扫描填上，并且它与数**同源**（清单封顶、数不跟着缩）。
        let spots = try XCTUnwrap(metrics.duplicateBlockCoordinatesMergedById,
                                  "真扫描不填坐标那一格 ⇒ 数是一条无法反驳的孤账")
        XCTAssertEqual(spots.count, min(merged, DuplicationScan.outsideBoardSampleLimit),
                       "坐标清单与被合并掉的数不同源：数 \(merged)、清单 \(spots) 条")
        let line = "RD-85 本仓自扫：合并掉 \(merged) 处等长同组命中"
            + "（点名 \(spots.count) 处，上限 \(DuplicationScan.outsideBoardSampleLimit)）"
        let ledger = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".scratch/tcoder-idcollision.txt")
        try FileManager.default.createDirectory(at: ledger.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try line.write(to: ledger, atomically: true, encoding: .utf8)
        XCTAssertEqual(try String(contentsOf: ledger, encoding: .utf8), line, "台账读回来不等于写进去的数")
        print(line)
    }

    private func metrics(dropped: Int?, lines: Int?, fragments: Int?) -> CodeMetrics {
        var metrics = CodeMetrics()
        metrics.duplicatedBlockLimit = DuplicationEngine.maxBlocks
        metrics.duplicatedBlocksDroppedByCap = dropped
        metrics.duplicatedLinesOutsideReportedBlocks = lines
        metrics.duplicateFragmentsNotExpandedCount = fragments
        return metrics
    }

    func testPageTailUsesFieldsAndNamesEveryNumber() {
        let note = CodeBoardTruth.outsideBoardNoteFromFields(
            metrics(dropped: 78, lines: 474, fragments: 198)) ?? ""
        XCTAssertTrue(note.contains("78"), note)
        XCTAssertTrue(note.contains("474"), note)
        XCTAssertTrue(note.contains("198"), note)
    }

    /// 没有预算损失时不许出现"未展开"那半句 —— 与"漏说"对称的另一头是多说一件没发生的事。
    func testPageTailStaysSilentAboutFragmentsWhenThereAreNone() {
        let note = CodeBoardTruth.outsideBoardNoteFromFields(
            metrics(dropped: 3, lines: 12, fragments: 0)) ?? ""
        XCTAssertTrue(note.contains("3") && note.contains("12"), note)
        XCTAssertFalse(note.contains("未展开"), note)
    }

    /// 旧报告没有这些格 ⇒ `nil`，调用方才能退回认领句子那条路（两种来源都不许让榜外那一半看不见）。
    func testAbsentFieldsYieldNoFieldComposedNote() {
        XCTAssertNil(CodeBoardTruth.outsideBoardNoteFromFields(metrics(dropped: nil, lines: nil, fragments: nil)))
        XCTAssertNil(CodeBoardTruth.outsideBoardNoteFromFields(metrics(dropped: 0, lines: 0, fragments: 5)),
                     "榜外是 0 就不该多出一句另有 0 个块")
    }

    // MARK: - 落盘规矩与"不造第二把尺子"

    func testMissingKeysDecodeAsNilNotZero() throws {
        var metrics = CodeMetrics()
        metrics.duplicatedBlocksDroppedByCap = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(metrics)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("duplicatedBlocksDroppedByCap"),
                       "没量到就该整键缺席，而不是写出 0（0 会被读成「一条都没被切掉」）")
        let back = try JSONDecoder.tcoderReportDecoder().decode(CodeMetrics.self, from: data)
        XCTAssertNil(back.duplicatedBlocksDroppedByCap)
    }

    /// RD-48 当年**故意不给总数**的理由：`rankedBlocks` 在撞 id 时先默默削掉若干块。
    /// "默默"这一半自 RD-85 起不成立了（那一格有读数），但**结论不变**：
    /// 「榜内 + 榜外」仍然不等于"引擎见过的原始命中数"，它等于一个定义良好的量——
    /// **去重后的重复块总数**（先去重、再截断，见 `rankedBlocks`）。
    /// 因此判据从"哪都不许加"改成两条更准的（R18 由总工裁，理由在台账卷三 §49）：
    /// ① 这枚加法**只有一个家**（`CodeMetrics.reportedDuplicatedBlockTotalCount`），别处再算就是第二把尺子；
    /// ② 任何把"共 N 处重复块"说出去的句子，**必须同时点名口径**（「去重后」或「明细已全部列出」），
    ///    否则那个数会被读成"引擎一共见到这么多处"。
    func testTheSumHasExactlyOneHomeAndEveryTotalNamesItsCaliber() throws {
        let lines = try Self.sourceLines()
        let sums = lines.filter { $0.text.contains("duplicatedBlocks.count +")
            || $0.text.contains("duplicatedBlocksDroppedByCap +")
            || $0.text.contains("+ duplicatedBlocksDroppedByCap") }
        XCTAssertEqual(sums.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["CodeMetrics.swift"],
                       "榜内 + 榜外这枚加法只许住在唯一取法里，实得：\(sums.map { "\($0.path):\($0.line)" })")
        XCTAssertEqual(sums.count, 1, "同一个家也只许一处相加（两处就是两把尺子）：\(sums.map(\.text))")

        let claims = lines.filter { $0.text.contains("处重复块") }
        XCTAssertFalse(claims.isEmpty, "扫不到任何说『处重复块』的句子 ⇒ 这条断言在空转")
        // 三种"口径已出口"的写法：报了限定的总数、明细已列全、或明说总数拿不出来。
        let qualified = ["去重后", "明细已全部列出", "总处数本次未统计"]
        let unqualified = claims.filter { line in !qualified.contains { line.text.contains($0) } }
        XCTAssertEqual(unqualified.map { "\(URL(fileURLWithPath: $0.path).lastPathComponent):\($0.line)" }, [],
                       "报总数却不点名口径（那个数会被读成引擎见过的原始命中数）：\n"
                         + unqualified.map(\.text).joined(separator: "\n"))
    }

    /// 元测试：上面那条扫描判据两个方向都要红过一次（本仓规矩：扫描型守卫不配元测试迟早永真绿）。
    func testMetaCaliberScannerCatchesBothBrokenShapes() throws {
        let brokenTotal = "        let total = metrics.duplicatedBlocks.count + metrics.duplicatedBlocksDroppedByCap ?? 0"
        let nakedClaim = "        return localizedFormat(\"重复代码 %1$@，共 %2$@ 处重复块\", r, n)"
        let compliant = "        return localizedFormat(\"重复代码 %1$@，共 %2$@ 处重复块（去重后口径，榜内只列 %3$@ 处明细）\", r, n, b)"
        XCTAssertTrue(Self.sumHits([brokenTotal]).count == 1, "该抓的第二处相加没抓到 ⇒ 尺子失效")
        XCTAssertTrue(Self.nakedClaimHits([nakedClaim]).count == 1, "该抓的裸总数句子没抓到 ⇒ 尺子失效")
        XCTAssertTrue(Self.nakedClaimHits([compliant]).isEmpty, "合规句子被误伤 ⇒ 判据过宽，下一个人会连合规一起删")
        XCTAssertTrue(Self.sumHits([compliant]).isEmpty, "合规句子不该被算成第二处相加")
        // 我第一版把判据写窄了（漏了"总处数本次未统计"那一档），当场误伤了合规句子——
        // 这条样本就是把那次误伤钉住，下次再收判据要先过它。
        let unmeasuredTotal = "        return localizedFormat(\"重复代码 %1$@，榜内只列 %2$@ 处重复块，总处数本次未统计\", r, b)"
        XCTAssertTrue(Self.nakedClaimHits([unmeasuredTotal]).isEmpty,
                      "拿不出总数、并明说了这一点，是三种合规写法之一：\(unmeasuredTotal)")
    }

    private static func sumHits(_ lines: [String]) -> [String] {
        lines.filter { $0.contains("duplicatedBlocks.count +") || $0.contains("duplicatedBlocksDroppedByCap +")
            || $0.contains("+ duplicatedBlocksDroppedByCap") }
    }

    private static func nakedClaimHits(_ lines: [String]) -> [String] {
        let qualified = ["去重后", "明细已全部列出", "总处数本次未统计"]
        return lines.filter { $0.contains("处重复块") }
            .filter { line in !qualified.contains { line.contains($0) } }
    }

    private static func sourceLines() throws -> [(path: String, line: Int, text: String)] {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let files = (FileManager.default.enumerator(
            at: packageRoot.appendingPathComponent("Sources"), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? [])
        XCTAssertFalse(files.isEmpty, "扫描面为空 ⇒ 这条断言不作数")
        var out: [(path: String, line: Int, text: String)] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, raw) in text.split(separator: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                out.append((url.path, index + 1, trimmed))
            }
        }
        return out
    }
}
