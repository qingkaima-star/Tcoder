import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R6（RD-17 的重复解释那一半）—— 重复率那一格必须**自己**说清两个口径。
///
/// 数据本来就不缺：`DuplicationScan.rankedBlocks` 早就返回 `droppedByCap` 与
/// `linesOutsideReportedBlocks`，`scanLimitations` 也会说"未列出 N 个块 / M 行"。
/// 缺的是两件事，本文件钉的就是这两件：
/// ① 读重复率那一格的人不必先翻边界列表才知道它是"按全量命中算"还是"榜内 20 块算"；
/// ② 榜外那些块要有**稳定坐标**（可点名、可复现），不许只剩一个总数。
///
/// ⚠️ `maxBlocks = 20` 属冻结口径，本文件把它当常量钉住而不是当阈值调。
final class DuplicationBoardCaliberTests: XCTestCase {

    private var fm: FileManager { FileManager.default }

    private func makeFixtureRoot() throws -> URL {
        let base = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: false)
        let canonical = try? base.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath
        guard let path = canonical, path.isEmpty == false else { return base }
        return URL(fileURLWithPath: path)
    }

    private func write(_ text: String, to relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// 一对逐字拷贝的文件：中间那段 10 行函数体在两个文件里一模一样。
    private func pair(_ index: Int) -> String {
        """
        func probe\(index)(input: Int) -> Int {
            var total = 0
            var step = input + \(index)
            while step > 0 {
                total = total + step * 3
                step = step - 7
            }
            if total > 997 { total = total - 997 }
            let scaled = total * \(index + 2)
            return scaled + probeSeed
        }
        """
    }

    private let probeSeed = "0"

    /// 造 `blockCount` 对拷贝（每对贡献一个块）。行数与指纹长度都刻意撑过 `windowSize`。
    private func makeDuplicationFixture(blocks: Int, in root: URL) throws {
        for index in 0..<blocks {
            let body = pair(index) + "\nlet probeSeed = 0\n"
            try write(body, to: "pairs/pair_\(String(format: "%02d", index))_a.swift", in: root)
            try write(body, to: "pairs/pair_\(String(format: "%02d", index))_b.swift", in: root)
        }
    }

    private func analyze(blocks: Int) async throws -> DuplicationResult {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try makeDuplicationFixture(blocks: blocks, in: root)
        let scan = await SourceTreeScanner(options: .default).scan(root: root)
        XCTAssertEqual(scan.files.count, blocks * 2, "夹具没按预期落盘，后面的数字都无意义")
        return DuplicationEngine.analyze(scan.files)
    }

    // MARK: - 正例：榜外块有名字、口径自己说

    func testBlocksBeyondTheBoardGetNamedCoordinates() async throws {
        let result = try await analyze(blocks: 26)
        XCTAssertEqual(DuplicationEngine.maxBlocks, 20, "榜单长度是冻结口径，动了就是改判据")
        XCTAssertEqual(result.blocks.count, 20, "明细榜单必须正好 20 块")
        // 26 对逐字拷贝在归一化后仍会互相成族，块数由算法决定；这里钉的是**关系**而不是猜的数：
        // 榜外 > 0（确实截断了）、坐标点数 = min(榜外块数, 取样上限)、行数守恒。
        // 精确的加减法在 `testCoordinateSampleLimitDoesNotShrinkTheCount`（纯函数、手搓输入）里钉。
        XCTAssertGreaterThan(result.blocksDroppedByCap, 0, "夹具没造成截断，这条用例就是永真绿")
        XCTAssertEqual(result.blocksOutsideBoard.count,
                       min(result.blocksDroppedByCap, DuplicationScan.outsideBoardSampleLimit))
        XCTAssertTrue(result.blocksOutsideBoard.allSatisfy { $0.contains(".swift") && $0.contains(":") },
                      "坐标要能被点名去找：\(result.blocksOutsideBoard)")
        XCTAssertGreaterThan(result.linesOutsideReportedBlocks, 0)
        // 榜单总行数 < 全量命中行数：这两个数本来就是两把尺，不许混着报
        let listed = result.blocks.map(\.lineCount).reduce(0, +)
        XCTAssertLessThanOrEqual(listed, result.duplicatedCodeLines,
                                 "榜内行数是各块相加，全量命中是并集，方向不许反")
    }

    func testBoardCaliberNoteSaysWhichRulerTheRatioUsed() async throws {
        let result = try await analyze(blocks: 26)
        let note = result.boardCaliberNote
        XCTAssertTrue(note.contains("全量命中"), note)
        XCTAssertTrue(note.contains("榜外坐标"), "榜外块必须点名，不许只留总数：\(note)")
        XCTAssertTrue(note.contains("20 块") || note.contains("前 20"), note)
        XCTAssertTrue(note.contains(NumberFormat.grouped(result.duplicatedCodeLines)),
                      "分子那个数要出现在句子里：\(note)")
        XCTAssertTrue(note.contains("不参与明细"), note)
    }

    /// 坐标稳定 = 同一批输入换到达顺序也得到同一串（榜单尾部可复现是 F11 那笔账）。
    func testCoordinatesAreStableAcrossArrivalOrder() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try makeDuplicationFixture(blocks: 24, in: root)
        let first = DuplicationEngine.analyze(await SourceTreeScanner(options: .default).scan(root: root).files)
        let second = DuplicationEngine.analyze(
            await SourceTreeScanner(options: .default).scan(root: root).files.reversed())
        XCTAssertEqual(first.blocksOutsideBoard, second.blocksOutsideBoard, "榜外坐标随到达顺序变了")
        XCTAssertEqual(first.blocks.map(\.id), second.blocks.map(\.id), "榜单本身也要可复现")
    }

    // MARK: - 反例：没截断时不许造出"榜外"这句话

    func testBoardUnderCapProducesNoCoordinatesAndNoCaliberNote() async throws {
        let result = try await analyze(blocks: 4)
        XCTAssertEqual(result.blocksDroppedByCap, 0)
        XCTAssertTrue(result.blocksOutsideBoard.isEmpty, "\(result.blocksOutsideBoard)")
        XCTAssertEqual(result.linesOutsideReportedBlocks, 0)
        // 未截断时不该有「榜外 / 未列出」那两类句子（零命中不出声）
        let outcome = try await analyzeFixture(blocks: 4)
        XCTAssertTrue(outcome.coverage.surfaceNotes.contains { $0.contains("榜外") } == false,
                      "没截断却报榜外 = 谎报：\(outcome.coverage.surfaceNotes)")
        XCTAssertTrue(outcome.coverage.limitationSummary.contains { $0.contains("未列出") } == false,
                      "\(outcome.coverage.limitationSummary)")
        XCTAssertTrue(result.ratio > 0, "4 对拷贝本身要有重复率，否则这条反例是永真绿")
    }

    /// 造夹具 + 走产品路径（`analyzeWithCoverage`），拿到能上屏的那两份账。
    private func analyzeFixture(blocks: Int) async throws
        -> FileSystemCodeAnalyzer.AnalysisOutcome {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try makeDuplicationFixture(blocks: blocks, in: root)
        return try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
    }

    // MARK: - 未知与失败态

    /// 只有一个文件时整体不参评（冻结口径）：重复率 0 要读作"没参加比较"，不是"没有拷贝"。
    func testSingleFileProjectReportsZeroBecauseItDidNotParticipate() async throws {
        let root = try makeFixtureRoot()
        defer { try? fm.removeItem(at: root) }
        try write(pair(1) + "\n", to: "only.swift", in: root)
        let scan = await SourceTreeScanner(options: .default).scan(root: root)
        let result = DuplicationEngine.analyze(scan.files)
        XCTAssertEqual(result.ratio, 0)
        XCTAssertEqual(result.blocks.count, 0)
        XCTAssertTrue(result.blocksOutsideBoard.isEmpty)
        let outcome = try await FileSystemCodeAnalyzer().analyzeWithCoverage(root: root, options: .default)
        XCTAssertEqual(outcome.metrics.duplicationRatio, 0)
        XCTAssertFalse(outcome.coverage.surfaceNotes.joined(separator: " ").contains("榜外"),
                       "一个都没比过，就不该有口径句子：\(outcome.coverage.surfaceNotes)")
    }

    /// 失败态：`rankedBlocks` 拿到空输入时四个读数都得是"没有"，不能是 nil/负数。
    func testRankedBlocksOnEmptyInputKeepsAllFourReadings() {
        let empty = DuplicationScan.rankedBlocks([])
        XCTAssertEqual(empty.blocks.count, 0)
        XCTAssertEqual(empty.droppedByCap, 0)
        XCTAssertEqual(empty.linesOutsideReportedBlocks, 0)
        XCTAssertTrue(empty.outsideBoardCoordinates.isEmpty)
    }

    /// 纯函数级：榜外样本上限与"总数不因取样而变小"同时成立。
    func testCoordinateSampleLimitDoesNotShrinkTheCount() {
        let blocks = (0..<40).map { index in
            DuplicatedBlock(occurrences: [DuplicatedFragment(path: "/a/\(index).swift", startLine: 1),
                                          DuplicatedFragment(path: "/b/\(index).swift", startLine: 1)],
                            lineCount: 40 - index, similarity: 1)
        }
        let ranked = DuplicationScan.rankedBlocks(blocks)
        XCTAssertEqual(ranked.blocks.count, 20)
        XCTAssertEqual(ranked.droppedByCap, 20, "取样上限不许把总数也削小")
        XCTAssertEqual(ranked.outsideBoardCoordinates.count, DuplicationScan.outsideBoardSampleLimit)
        XCTAssertEqual(ranked.linesOutsideReportedBlocks,
                       blocks.map(\.lineCount).reduce(0, +) - ranked.blocks.map(\.lineCount).reduce(0, +),
                       "榜外行数必须等于全量减榜内")
        XCTAssertEqual(ranked.blocks.count + ranked.droppedByCap, blocks.count, "块数守恒（无重复 id）")
    }
}
