import XCTest
@testable import TcoderMonitor

// OWNER: R7 建议与榜长真修（RD-17「重复代码的解释」+ 榜长读数那一族）
//
// ## 病根（修前可复现，原文在 HEAD 之前）
//
// `CodeDuplicationSection.truncationNote` 写的是：
//
//     let total = code.duplicatedBlocks.count
//     guard total > shown else { return "共 \(total) 个重复块，已全部列出。" }
//
// 而 `CodeMetrics.duplicatedBlocks` 是 `DuplicationEngine.maxBlocks = 20` 截过的**封顶榜**。
// ⇒ 一个真有 51 处重复块的仓库，只要榜满了 20，页尾就会指着 20 说"共 20 个，已全部列出"。
// 这句不是"少显示了一点"，是**把没列出来的说成没有**。引擎那边一直算着
// `blocksDroppedByCap` 与 `linesOutsideReportedBlocks`，只是从没上过屏。
//
// ## 独立真值
//
// 榜长 20、榜外 7 块 / 91 行 —— 这些数字是**本文件自己写进夹具**的
// （`coverage(blocksDropped: 7, linesOutside: 91)`），再断言引擎渲染出的句子里含这三个数，
// 而不是把实现输出抄回来当期望。上限 20 另立一枚测试侧探针 `capProbe`，配两条**常量对账**
// （`DuplicationEngine.maxBlocks` 与它必须相等）：将来谁改了上限，先红在"常量分叉"上。
//
// ## 四态
//
// 正例（榜外确有 → 说榜内并报出账）、反例（榜没满 → 才允许说"已全部列出"）、
// 未知（旧报告 `scanLimitations == nil` → 按契约读作"未截断"，且理由必须写在句子里）、
// 失败（`shown > listed`、空榜、以及元测试：判据对坏样例必须报）。

final class AdviceWordingBoardTests: XCTestCase {

    /// 测试侧的上限探针。**不读实现常量**，是为了让"实现改了上限没改文案"红在对账上。
    static let capProbe = 20

    /// 引擎自己那句里的标记（`CodeBoardTruth.outsideBoardMarker`）——两处必须同源。
    static let markerProbe = "明细榜单截断"

    // MARK: 夹具

    static func block(_ index: Int, lines: Int) -> DuplicatedBlock {
        DuplicatedBlock(
            occurrences: [
                DuplicatedFragment(path: "/r7-board/A\(index).swift", startLine: 10 + index),
                DuplicatedFragment(path: "/r7-board/B\(index).swift", startLine: 200 + index),
            ],
            lineCount: lines, similarity: 0.9)
    }

    /// 造一份榜单：`listed` 块，全仓重复率按 0.1 摆。
    static func metrics(listed: Int, limitations: [String]?) -> CodeMetrics {
        var code = CodeMetrics()
        code.totalFiles = 300
        code.codeLines = 10_000
        code.duplicationRatio = 0.1
        // `0..<listed` 而不是 `1...listed`：空榜那一态传 0 时闭区间会 trap
        // （Range requires lowerBound <= upperBound，2026-09-22 实测跑死过整轮 xctest）。
        code.duplicatedBlocks = (0..<listed).map { block($0 + 1, lines: 13 + $0) }
        code.scanLimitations = limitations
        return code
    }

    /// 由**引擎自己**产出那句"榜外还有多少"，本函数只负责把数字摆进被测量。
    static func engineNote(blocksDropped: Int, linesOutside: Int, fragments: Int = 0) -> String? {
        let coverage = FileSystemCodeAnalyzer.CodeScanCoverage(
            visitedEntryCount: 300, includedFileCount: 300, skippedFileCount: 0,
            truncatedByMaxFiles: false, maxFiles: 5_000, maxFileBytes: 2_000_000,
            lineTruncatedFileCount: 0, filesHittingDuplicateLineCap: 0,
            duplicateFragmentsDroppedByBudget: fragments,
            duplicateBlocksDroppedByCap: blocksDropped,
            duplicateLinesOutsideReportedBlocks: linesOutside)
        return coverage.limitationSummary.first { $0.contains(markerProbe) }
    }

    // MARK: - ① 上限与标记的对账（两把名字相似的尺子，坑 ②）

    func test_capAndMarkerProbeMatchTheEngine() {
        XCTAssertEqual(DuplicationEngine.maxBlocks, Self.capProbe,
                       "常量分叉：引擎的明细榜上限已不是测试探针里的 \(Self.capProbe)")
        XCTAssertEqual(CodeBoardTruth.duplicationBlockCap, DuplicationEngine.maxBlocks,
                       "界面自己另立了一枚上限 —— 取法必须只有引擎那一处")
        XCTAssertEqual(CodeBoardTruth.outsideBoardMarker, Self.markerProbe,
                       "认领引擎那句话的标记与探针分叉了，`outsideBoardNote` 会静默取不到")
    }

    /// 标记失效是**静默**的（取不到就当没截断），所以每次都要证明引擎那句话真的还在。
    func test_engineStillWritesTheSentenceWeClaimToForward() throws {
        let note = try XCTUnwrap(Self.engineNote(blocksDropped: 7, linesOutside: 91))
        XCTAssertTrue(note.contains("未列出 7 个块"), "榜外块数没进句子：\(note)")
        XCTAssertTrue(note.contains("91 行"), "榜外行数没进句子：\(note)")
        XCTAssertTrue(note.contains("截断到 \(Self.capProbe) 块"), "上限没进句子：\(note)")
    }

    // MARK: - ② 三态

    /// 正例：榜外确有 7 块 / 91 行 ⇒ 页尾必须说"榜内"、点名上限、并把引擎那笔账原样带出来。
    func test_cappedBoardDisclosesWhatSitsOutsideIt() throws {
        let note = try XCTUnwrap(Self.engineNote(blocksDropped: 7, linesOutside: 91))
        let code = Self.metrics(listed: Self.capProbe, limitations: [note])
        let text = CodeBoardTruth.duplicationTruncationNote(code, shown: 8)
        XCTAssertTrue(text.contains("榜内只列 20 个"), text)
        XCTAssertTrue(text.contains("明细榜上限 20 块"), text)
        XCTAssertTrue(text.contains("本页当前列出 8 个"), text)
        XCTAssertTrue(text.contains("未列出 7 个块 / 91 行"), "榜外那笔账没上屏：\(text)")
        XCTAssertFalse(text.contains("已全部列出"), "榜外还有 7 块时不许说「全部列出」：\(text)")
    }

    /// 反例：榜没满 ⇒ 榜长**就是**总数，这时"已全部列出"是真话，也不该硬塞"榜内"。
    func test_uncappedBoardMayClaimFullList() {
        let code = Self.metrics(listed: 3, limitations: nil)
        let text = CodeBoardTruth.duplicationTruncationNote(code, shown: 3)
        XCTAssertTrue(text.contains("共 3 个重复块，已全部列出"), text)
        XCTAssertFalse(text.contains("榜内"), "没截断时把「榜内」写进句子是制造新的读不懂：\(text)")
    }

    /// 未知态：`scanLimitations == nil` 按契约读作"一条上限都没生效"（Models 注释写死了这个语义）。
    /// 这里把它钉下来：谁改契约语义，这条会红，而不是让页面悄悄换含义。
    func test_absentLedgerReadsAsUntruncatedByContract() {
        let code = Self.metrics(listed: Self.capProbe, limitations: nil)
        let text = CodeBoardTruth.duplicationTruncationNote(code, shown: 8)
        XCTAssertTrue(text.contains("当前列出 8 / 20 个"), text)
        let full = CodeBoardTruth.duplicationTruncationNote(code, shown: Self.capProbe)
        XCTAssertTrue(full.contains("榜没被截断，这一串就是总数"),
                      "说「全部列出」时必须同时交代凭什么（台账缺席=未截断）：\(full)")
    }

    /// 失败态：`shown > listed`（展开态与行数不同步时会出现）只能读成"已全部列出"，不许报负数。
    func test_shownExceedingListedNeverSubtracts() {
        let code = Self.metrics(listed: 2, limitations: nil)
        let text = CodeBoardTruth.duplicationTruncationNote(code, shown: 8)
        XCTAssertTrue(text.contains("共 2 个重复块"), text)
        XCTAssertFalse(text.contains("8"), "页尾句把展示条数当成了总数在减：\(text)")
    }

    /// 空榜：引擎在"只有一个文件 / 代码行不足"时返回空明细，这时页尾不许被画成"扫出了问题"。
    func test_emptyBoardSaysZeroAndNothingElse() {
        let code = Self.metrics(listed: 0, limitations: nil)
        XCTAssertTrue(CodeBoardTruth.duplicationTruncationNote(code, shown: 0).contains("共 0 个"))
        XCTAssertNil(CodeBoardTruth.outsideBoardNote(code))
    }

    // MARK: - ③ 标签与量词：读 `count` 的那几格必须自带「榜内」

    func test_slotLabelCarriesBoardQualifier() {
        XCTAssertEqual(CodeBoardTruth.duplicationSlotLabel(), "重复块（榜内）")
        XCTAssertTrue(CodeBoardTruth.duplicationHiddenRowsNoun().contains("榜内"),
                      "展开按钮的量词没限定，读起来像「仓库里还剩这么多块」")
        XCTAssertEqual(CodeBoardTruth.duplicationBoardCount(Self.metrics(listed: 5, limitations: nil)), 5,
                       "取法本身读错了对象")
    }

    /// 重复率的分母是全仓、块数只是榜内 —— 同一句里这两件事必须被区分开（RD-17 的原话）。
    func test_duplicationCaptionSeparatesWholeRepoRatioFromBoardCount() {
        let text = CodeRiskAnalysis.duplicationCaption(Self.metrics(listed: 20, limitations: nil))
        XCTAssertTrue(text.contains("榜内重复块 20 个"), text)
        XCTAssertTrue(text.contains("10,000 行"), "全仓分母丢了：\(text)")
    }

    // MARK: - ④ §十 措辞：不许把目标长在榜上

    /// 「压到上榜函数的最低水位以下」是一枚从**封顶榜**里长出来的目标：
    /// 第 20 名在大仓库上可能仍是 CC 40，照它做完既没出榜也没修掉东西 ⇒ 换成引擎判档线。
    func test_criticalComplexityAdviceTargetsTheEngineLineNotTheBoard() throws {
        var code = Self.metrics(listed: 3, limitations: nil)
        code.topComplexFunctions = (1...Self.capProbe).map { index in
            FunctionHotspot(name: "fn\(index)", filePath: "/r7-board/Sample.swift", startLine: index * 7,
                            lineCount: 60, cyclomaticComplexity: 60 - index, parameterCount: 1, risk: .critical)
        }
        let items = CodeRiskAnalysis.complexityAdvice(code)
        let text = try XCTUnwrap(items.first { $0.id == "complexity-critical" }?.text)
        XCTAssertFalse(text.contains("水位"), "榜里长出来的目标又回来了：\(text)")
        XCTAssertTrue(text.contains("CC 21"), "该指向引擎的判档线：\(text)")
        XCTAssertTrue(text.contains("与榜位无关"), "必须说清这条线不是榜位：\(text)")
    }

    /// 两把相似的尺子（坑 ②）：判 high 的线 ≠ 自扫"上榜参考线"。建议用的是前者。
    func test_theTwoComplexityRulersAreNotTheSameNumber() {
        XCTAssertEqual(FileSystemCodeAnalyzer.highFunctionComplexity, 21,
                       "判高档那条线变了 —— 建议文案里的 CC 数字要跟着改，别只改这里")
        XCTAssertEqual(SelfScanHarnessCase.complexFunctionBar, 16,
                       "自扫的「上榜参考线」变了：它是另一把尺子，不得被当成分档线用")
        XCTAssertNotEqual(FileSystemCodeAnalyzer.highFunctionComplexity,
                          SelfScanHarnessCase.complexFunctionBar,
                          "两把尺子并成一把了 —— 那正是上一轮把 8 报成 6 的成因")
    }

    // MARK: - ⑤ 元测试：判据对坏样例必须报（证明上面几条不是永真绿）

    func test_meta_outsideBoardMatcherRejectsForeignSentences() {
        // 坏样例：句子里没有那个标记 ⇒ 不能被认领成"榜外的账"。
        let code = Self.metrics(listed: Self.capProbe, limitations: ["达到单次扫描文件上限 5000。"])
        XCTAssertNil(CodeBoardTruth.outsideBoardNote(code), "认领器见句就认，会把别的账当成重复榜的账")
        // 好样例必须认得到，否则②那一整组断言都是假的。
        let good = Self.metrics(listed: Self.capProbe,
                                limitations: ["达到单次扫描文件上限 5000。",
                                              Self.engineNote(blocksDropped: 7, linesOutside: 91) ?? ""])
        XCTAssertNotNil(CodeBoardTruth.outsideBoardNote(good), "认领器失灵：引擎那句话认不出来了")
    }

    func test_meta_truncationNoteReportsTheNumbersItIsGiven() {
        // 换一组数字走同一条路：读数必须跟着变（钉住「数字是从参数来的」，不是写死的）。
        let note = Self.engineNote(blocksDropped: 3, linesOutside: 44) ?? ""
        let text = CodeBoardTruth.duplicationTruncationNote(
            Self.metrics(listed: Self.capProbe, limitations: [note]), shown: 8)
        XCTAssertTrue(text.contains("未列出 3 个块 / 44 行"), "换数字不跟着变 = 句子是写死的：\(text)")
    }
}
