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
/// ⚠️ 这里**故意不断言**"榜内 + 榜外 == 总块数"：`rankedBlocks` 在撞 id 时还会削掉若干块而无处计数
/// （R6b 交回时点名的那格），等式天然不平。落四枚直传数、不造一枚看似精确的总数，是这次的选择。
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

    /// 任何地方都不许把榜内条数与榜外条数加起来当"总数"用（那个等式不平，见类注释）。
    func testNobodySumsBoardPlusDroppedIntoATotal() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sources = packageRoot.appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? [])
        XCTAssertFalse(files.isEmpty, "扫描面为空 ⇒ 这条断言不作数")
        var offenders: [String] = []
        for url in files {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for line in text.split(separator: "\n") {
                let l = line.trimmingCharacters(in: .whitespaces)
                if l.hasPrefix("//") { continue }
                if l.contains("duplicatedBlocks.count +") || l.contains("duplicatedBlocksDroppedByCap +")
                    || l.contains("+ duplicatedBlocksDroppedByCap") {
                    offenders.append("\(url.lastPathComponent): \(l)")
                }
            }
        }
        XCTAssertEqual(offenders, [], "出现把榜内与榜外相加当总数的写法（等式天然不平）：\n"
            + offenders.joined(separator: "\n"))
    }
}
