import XCTest
@testable import TcoderMonitor

/// RD-85：撞 id 被合并掉的重复命中，从「无处计数」变成一格读数。
///
/// 立案事实（总工实读）：`DuplicationScan.rankedBlocks` 先去重再截断，而
/// `DuplicatedBlock.id` 只由「出现文件集合排序拼接 + 行数」拼成 ⇒ 同一组文件上的两处
/// 等长克隆会撞同一个 id。撞掉的那几块既不在榜内、也不在 `blocksDroppedByCap` 里，
/// 所以 `docs/R6-契约字段清单.md` §7 第 2 条写下那句「榜内 + 榜外 == 总数」天然不平，
/// 并点名要修的形状是 `blocksDroppedByIdCollision: Int?`（只加不改）。
///
/// 独立真值 = **我自己构造的输入条数**（`input.count`），不是被测量算出来的数。
/// 守恒式在纯函数那头才成立：契约里不落"原始命中数"这一格，所以不假装能在
/// `CodeMetrics` 上复算它 —— 那是另一件要另立案的事。
final class DuplicateIdCollisionConservationTests: XCTestCase {

    // MARK: - 夹具

    /// 同一组文件、同一个长度、不同起始行 ⇒ 三个 `DuplicatedBlock` 里只有两个 id 相同。
    private func cloneGroup(named tag: String, startLines: [Int], lineCount: Int) -> [DuplicatedBlock] {
        startLines.map { start in
            DuplicatedBlock(occurrences: [
                DuplicatedFragment(path: "/repo/\(tag)A.swift", startLine: start),
                DuplicatedFragment(path: "/repo/\(tag)B.swift", startLine: start + 100),
            ], lineCount: lineCount, similarity: 1)
        }
    }

    // MARK: - 正例：两块等长克隆 ⇒ 这一格为 1 且总数守恒

    func testTwoEqualLengthClonesShareOneIdAndAreCountedAsMerged() {
        let input = cloneGroup(named: "pair", startLines: [10, 40], lineCount: 12)
        XCTAssertEqual(input.count, 2, "夹具本身就得是两条命中，否则下面的断言在空转")
        XCTAssertEqual(input[0].id, input[1].id, "夹具没造出撞 id 的形状：这条用例从此永真绿")

        let ranked = DuplicationScan.rankedBlocks(input)
        XCTAssertEqual(ranked.droppedByIdCollision, 1, "两条命中合并成一条 ⇒ 被合并掉的是一条，不是两条")
        XCTAssertEqual(ranked.blocks.count, 1)
        XCTAssertEqual(ranked.droppedByCap, 0, "榜没满：撞 id 与封顶是两格读数，不许互相顶")
        XCTAssertEqual(ranked.blocks.count + ranked.droppedByCap + ranked.droppedByIdCollision, input.count,
                       "三项相加必须等于原始命中数")
    }

    /// 反例：id 各不相同 ⇒ 这一格读 0。0 是**量出来的**，不是缺席兜底出来的。
    func testDistinctIdsReadZeroCollisionSoTheRulerCanSayZero() {
        let input = (0..<5).flatMap { index in
            self.cloneGroup(named: "solo\(index)", startLines: [3], lineCount: 8)
        }
        XCTAssertEqual(Set(input.map(\.id)).count, input.count, "夹具没造出互不相同的 id")
        let ranked = DuplicationScan.rankedBlocks(input)
        XCTAssertEqual(ranked.droppedByIdCollision, 0)
        XCTAssertEqual(ranked.blocks.count + ranked.droppedByCap + ranked.droppedByIdCollision, input.count)
    }

    /// 两格同时开火：榜满 + 撞 id。各归各的账，不许把撞 id 算进封顶那格。
    func testConservationSurvivesCapAndCollisionFiringTogether() {
        var input: [DuplicatedBlock] = (0..<22).map { index in
            DuplicatedBlock(occurrences: [
                DuplicatedFragment(path: "/repo/many\(index).swift", startLine: 1),
                DuplicatedFragment(path: "/repo/other\(index).swift", startLine: 1),
            ], lineCount: 60 - index, similarity: 1)
        }
        input += cloneGroup(named: "triple", startLines: [5, 90, 180], lineCount: 30)
        let ranked = DuplicationScan.rankedBlocks(input)
        XCTAssertEqual(ranked.droppedByIdCollision, 2, "三条等长同组命中留下 1 条 ⇒ 合并掉 2 条")
        XCTAssertEqual(ranked.blocks.count, DuplicationEngine.maxBlocks, "这批夹具必须真的把榜压满")
        XCTAssertGreaterThan(ranked.droppedByCap, 0)
        XCTAssertEqual(ranked.blocks.count + ranked.droppedByCap + ranked.droppedByIdCollision, input.count,
                       "同时开火时守恒式仍然要平（分母 \(input.count)）")
    }

    // MARK: - 三态：缺席 ≠ 零

    /// 旧报告没有这一格 ⇒ 整键缺席，不许被兜底成 0（0 会被读成「一条都没合并」）。
    func testOldReportLeavesTheKeyAbsent() throws {
        let data = try JSONEncoder().encode(CodeMetrics())
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(json.contains("duplicatedBlocksDroppedByIdCollision"),
                       "没量到也要写出这一格 ⇒ 三态被压成两态")

        var measured = CodeMetrics()
        measured.duplicatedBlocksDroppedByIdCollision = 3
        let back = try JSONDecoder().decode(CodeMetrics.self, from: try JSONEncoder().encode(measured))
        XCTAssertEqual(back.duplicatedBlocksDroppedByIdCollision, 3, "落盘再读回来必须还是 3")
    }

    // MARK: - 真读者：页尾那句

    /// 有合并才出声；没有合并时**旧话术一字不动**（第 21 类盲区：加新维度不许改旧句）。
    func testFooterNamesTheMergedCountOnlyWhenThereIsOne() {
        var code = CodeMetrics()
        code.duplicatedBlocks = [DuplicatedBlock(occurrences: [
            DuplicatedFragment(path: "/repo/A.swift", startLine: 1),
            DuplicatedFragment(path: "/repo/B.swift", startLine: 1),
        ], lineCount: 14, similarity: 1)]
        code.duplicatedBlocksDroppedByCap = 7
        code.duplicatedLinesOutsideReportedBlocks = 91

        let withoutMerging = try? XCTUnwrap(CodeBoardTruth.outsideBoardNoteFromFields(code))
        XCTAssertNotNil(withoutMerging)
        XCTAssertFalse((withoutMerging ?? "").contains("合并为一条"),
                       "没量到合并就该不说这句：\(withoutMerging ?? "nil")")

        code.duplicatedBlocksDroppedByIdCollision = 2
        let mergedNote = CodeBoardTruth.outsideBoardNoteFromFields(code) ?? ""
        XCTAssertTrue(mergedNote.contains("另有 2 处重复命中与别处合并为一条"),
                      "点了数却不进页尾 ⇒ 这格没有读者：\(mergedNote)")
        XCTAssertTrue(mergedNote.contains("另有 7 个块 / 91 行未列入榜内。"),
                      "旧那句被新句挤掉了：\(mergedNote)")
    }

    /// 榜没满、榜外为 0，但撞了 id ⇒ 这一格必须**自己**能把页尾顶起来。
    /// 这正是 R6 §7 点名的形状：如果判据仍写「榜外有数才开口」，小仓库上这条账永远看不见。
    func testCollisionAloneIsEnoughToMakeTheFooterSpeak() {
        var code = CodeMetrics()
        code.duplicatedBlocksDroppedByCap = 0
        code.duplicatedLinesOutsideReportedBlocks = 0
        code.duplicatedBlocksDroppedByIdCollision = 1
        let note = CodeBoardTruth.outsideBoardNoteFromFields(code)
        XCTAssertNotNil(note, "撞 id 自己撑不起一句 ⇒ 这一格落了地却没有读者")
        XCTAssertTrue(note?.contains("合并为一条") ?? false, "\(note ?? "nil")")

        code.duplicatedBlocksDroppedByIdCollision = 0
        XCTAssertNil(CodeBoardTruth.outsideBoardNoteFromFields(code),
                     "三格全零还说有账 ⇒ 这句在编造")
    }

    // MARK: - RD-86：数之外还要**点名坐标**（RD-17 老账：只给总数 = 无法反驳）

    /// 被合并掉的那一处必须给出**可核对的坐标**，而且这条坐标与计数同源（一次扫出来的两半）。
    func testMergedAwayCoordinatesNameACheckablePlaceNotJustACount() {
        let input = cloneGroup(named: "pair", startLines: [10, 40], lineCount: 12)
        let ranked = DuplicationScan.rankedBlocks(input)
        XCTAssertEqual(ranked.mergedAwayCoordinates.count, ranked.droppedByIdCollision,
                       "坐标清单与计数不是同一次扫描的两半 ⇒ 会各自漂移")
        let spot = ranked.mergedAwayCoordinates.first ?? ""
        XCTAssertFalse(spot.isEmpty, "有合并却没点名 ⇒ 这条账仍然无法反驳")
        // 留下的那一处与被合并的那一处只有一份坐标进清单——**不许两处都写**（那等于没删重复）。
        let namedStartLines = [10, 40].filter { spot.contains(":\($0)") }
        XCTAssertEqual(namedStartLines.count, 1, "要么两处都点了、要么一处都没点：\(spot)")
        XCTAssertTrue(spot.contains("/repo/pairA.swift"), "坐标要点到文件：\(spot)")
    }

    /// 取样上限只削**清单**，不削**数**（第 20 类盲区：朝好看方向截断就是假绿）。
    func testSamplingCapTrimsTheListButNeverTheCount() {
        let input = cloneGroup(named: "many", startLines: Array(stride(from: 1, through: 81, by: 10)),
                               lineCount: 25)
        let ranked = DuplicationScan.rankedBlocks(input)
        XCTAssertEqual(ranked.droppedByIdCollision, input.count - 1, "同组同长 ⇒ 只留一条")
        XCTAssertEqual(ranked.mergedAwayCoordinates.count, DuplicationScan.outsideBoardSampleLimit,
                       "清单要封顶，数不许跟着被削小")
    }

    /// 上屏那一句：有坐标就点名，没坐标时**旧那句一字不动**。
    func testFooterNamesTheMergedPlacesWhenTheyAreThere() {
        var code = CodeMetrics()
        code.duplicatedBlocksDroppedByCap = 0
        code.duplicatedLinesOutsideReportedBlocks = 0
        code.duplicatedBlocksDroppedByIdCollision = 2
        let withoutSpots = CodeBoardTruth.outsideBoardNoteFromFields(code) ?? ""
        XCTAssertFalse(withoutSpots.contains("被合并的那几处在"), "没坐标却编了一句：\(withoutSpots)")
        code.duplicateBlockCoordinatesMergedById = ["pairA.swift:40 + pairB.swift:140",
                                                    "pairA.swift:70 + pairB.swift:170"]
        let withSpots = CodeBoardTruth.outsideBoardNoteFromFields(code) ?? ""
        XCTAssertTrue(withSpots.contains("pairA.swift:40"), "坐标没进页尾 ⇒ 这一格落了地没读者：\(withSpots)")
        XCTAssertTrue(withSpots.contains("另有 2 处重复命中与别处合并为一条"),
                      "新句挤掉了旧句：\(withSpots)")
    }
}
