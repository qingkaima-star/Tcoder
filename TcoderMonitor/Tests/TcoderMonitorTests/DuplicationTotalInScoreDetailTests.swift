import XCTest
@testable import TcoderMonitor

// OWNER: WS-R18 DupTotal（工单：健康评分「问题」那一栏里的重复块总数）
//
// ## 病根（修前可复现，原文在 HEAD 之前）
//
// `HealthCodeDimensions.duplicationIssues` 写的是
// `重复代码 %1$@，共 %2$@ 处重复块`，而那个数吃的是 `code.duplicatedBlocks.count` ——
// **榜长**，不是总数（`CodeMetrics.duplicatedBlocks` 被 `DuplicationEngine.maxBlocks` = 20 截过）。
// 2026-09-23 本仓实扫读数（就是下面 ① 那条用例现算的那两个数）：榜内 20 · 榜外未列 96
// ⇒ 评分详情对用户说「共 20 处重复块」，真相是 116 处（**少报 96 处**；工单立案那批读的是
// 榜内 20 · 榜外 85，同一件事）。这正是需求方 §五 点名的形状（"实际 552 显示 20"）
// 在评分解释文本里的那一处残留：展示层那一半已由 R7 收口（`CodeBoardTruth`），评分侧没有。
//
// ## 独立真值怎么来的
//
// `test_independentEngineScanAgreesWithTheReportedFields` 自己走一遍本仓目录树
// （`SourceTreeScanner` + `DuplicationEngine`），**不经过** `FileSystemCodeAnalyzer` 的装配层，
// 拿到榜长与 `blocksDroppedByCap` 两个原始读数；句子里的总数是**本文件自己做加法**算出来的
// （`engine.blocks.count + engine.blocksDroppedByCap`），绝不把实现输出的句子当答案。
// 口径边界就地写明：`DuplicationScan.rankedBlocks` 先按 `DuplicatedBlock.id` 去重、再截断到上限，
// 所以这个和是**去重后**的重复块总数；撞 id 被合并掉的原始命中没有读数
// （`docs/R6-契约字段清单.md` §7 第 2 条点名缺的那枚 `blocksDroppedByIdCollision`），
// 所以句子必须自带「去重后口径」这句限定语。
//
// ## 三态（不许把三态压成两态）
//
// 判据是「榜外那一半**统计过没有**」，不是「榜外是不是零」：榜外 > 0 → 真总数与榜长并排
// （守卫认的披露句式）；榜外 == 0 → 说明细已全部列出；榜外为 `nil`（旧报告没统计过）
// → 只报榜长且**不出现「共」字** —— 最后这一条是反「没统计当没问题」的牙，
// 也是 `CodeMetrics.reportedDuplicatedBlockTotalCount` 故意不写 `?? duplicatedBlocks.count`
// 那种兜底的唯一理由。
//
// ## 棘轮还有牙（点名，不重造）
//
// `BoardLengthReadoutRatchetTests.test_meta_flagsReadoutsBeyondBudget` 就是那把尺子的元测试：
// 新写一处「把榜长当总数」它当场报 3 处。本工单把
// `"Services/Health/HealthCodeDimensions.swift"` 那一格从 1 拧到 0。

final class DuplicationTotalInScoreDetailTests: SelfScanHarnessCase {

    /// 曲线锚点 18% → 45 分（`HealthCurves.duplication`），而评分只在 ≤60 那一档才出「问题」句。
    /// 本仓真实重复率约 2.5%（100 分、不出声），所以**真读数必须配一个能出声的 ratio**
    /// 才拿得到句子：ratio 只进百分号，不参与块数，两块数仍是盘上实测。
    private static let probeRatio = 0.18
    private static let probeRatioText = "18.0%"

    // MARK: - 夹具

    /// 每块两个发生地、路径互不重复 ⇒ `DuplicatedBlock.id` 不会相撞，榜长就等于去重后条数。
    private static func block(_ index: Int) -> DuplicatedBlock {
        DuplicatedBlock(
            occurrences: [
                DuplicatedFragment(path: "/r18-duptotal/A\(index).swift", startLine: 10 + index),
                DuplicatedFragment(path: "/r18-duptotal/B\(index).swift", startLine: 200 + index),
            ],
            lineCount: 12 + index, similarity: 0.9)
    }

    /// `outsideBoard == nil`（没统计过）与 `outsideBoard == 0`（统计过、为零）是两件事，
    /// 夹具必须能分别造出来 —— 这一枚参数就是那条三态边界本身。
    private static func metrics(board: Int, outsideBoard: Int?, ratio: Double = probeRatio) -> CodeMetrics {
        var code = CodeMetrics()
        code.totalFiles = 400
        code.codeLines = 10_000
        code.duplicationRatio = ratio
        // `0..<board` 而不是 `1...board`：榜为空时闭区间会 trap（Range requires
        // lowerBound <= upperBound，本仓 2026-09-22 实测跑死过整轮 xctest）。
        code.duplicatedBlocks = (0..<board).map { block($0 + 1) }
        code.duplicatedBlocksDroppedByCap = outsideBoard
        code.duplicatedBlockLimit = DuplicationEngine.maxBlocks
        return code
    }

    /// 取评分那一栏实际会上屏的那一句（走公开分派口 `duplicationOutcome`，不反射私有函数）。
    private func issue(_ code: CodeMetrics) throws -> String {
        let outcome = WeightedHealthScorer().duplicationOutcome(HealthInputs(code: code))
        XCTAssertEqual(outcome.issues.count, 1, "这一档就该出一句：\(outcome.issues)")
        return try XCTUnwrap(outcome.issues.first)
    }

    // MARK: - ① 独立真值：引擎现算 == 报告字段，加法由本文件自己做

    func test_independentEngineScanAgreesWithTheReportedFields() async throws {
        let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
        XCTAssertGreaterThanOrEqual(files.count, 100,
                                   "本仓走树只拿到 \(files.count) 个文件 ⇒ 分母不对，这条在空转")
        let engine = DuplicationEngine.analyze(files)
        let code = try await selfScan().code

        XCTAssertEqual(code.duplicatedBlocks.count, engine.blocks.count,
                       "报告里的榜长与引擎现算不等 ⇒ 装配层在增减块")
        XCTAssertEqual(code.duplicatedBlocksDroppedByCap, engine.blocksDroppedByCap,
                       "榜外计数没直传到位（这一格错了，句子就会把榜外藏起来）")

        let ownSum = engine.blocks.count + engine.blocksDroppedByCap
        XCTAssertEqual(ownSum, code.reportedDuplicatedBlockTotalCount,
                       "契约里那枚取法与本文件自己相加的数分叉了")
        print("【R18 独立真值】引擎现算：榜内 \(engine.blocks.count) · 榜外 \(engine.blocksDroppedByCap)"
            + " ⇒ 去重后总数 \(ownSum)（这个和是测试自己加的）")
    }

    // MARK: - ② 正例：三态各打一句

    /// 正例·榜外 > 0，**两个数取本仓实测**：句子必须把真总数与榜长并排说出来。
    func test_realScanSaysTotalAndBoardLengthTogether() async throws {
        let reported = try await selfScan().code
        let board = reported.duplicatedBlocks.count
        let outside = try XCTUnwrap(reported.duplicatedBlocksDroppedByCap, "扫的是真仓库，榜外计数不该缺席")
        XCTAssertGreaterThanOrEqual(board, DuplicationEngine.maxBlocks, "榜没满就不会有榜外，这条正例得换成夹具")
        XCTAssertGreaterThan(outside, 0, "本仓这份读数没被截断 ⇒ 三态退化成两态")
        let total = board + outside                       // ← 本文件自己相加，不取实现输出

        var probe = reported
        probe.duplicationRatio = Self.probeRatio          // 只决定百分号与「要不要出声」
        let expected = "重复代码 \(Self.probeRatioText)，共 \(NumberFormat.grouped(total)) 处重复块"
            + "（去重后口径，榜内只列 \(NumberFormat.grouped(board)) 处明细）"
        let sentence = try issue(probe)

        XCTAssertEqual(sentence, expected)
        XCTAssertTrue(sentence.contains("去重后"), "口径没交代：\(sentence)")
        print("【R18 正例·榜外>0】\(sentence)")
    }

    /// 正例·榜外 == 0：量过了、确实没漏 ⇒ 才允许说「明细已全部列出」。
    func test_zeroOutsideBoardSaysEveryBlockIsListed() throws {
        let sentence = try issue(Self.metrics(board: 3, outsideBoard: 0))
        XCTAssertEqual(sentence, "重复代码 \(Self.probeRatioText)，共 3 处重复块（明细已全部列出）")
        XCTAssertFalse(sentence.contains("榜内只列"), "没截断时把「榜内」写进句子是制造读不懂：\(sentence)")
        print("【R18 正例·榜外==0】\(sentence)")
    }

    /// 正例·榜外为 `nil`（旧报告没统计过）：只报榜长，**不许出现「共」字**。
    func test_unmeasuredOutsideBoardReportsBoardLengthWithoutClaimingTotal() throws {
        let sentence = try issue(Self.metrics(board: 20, outsideBoard: nil))
        XCTAssertEqual(sentence, "重复代码 \(Self.probeRatioText)，榜内只列 20 处重复块，总处数本次未统计")
        XCTAssertFalse(sentence.contains("共"), "「共」就是一枚总数，没统计过就不能写：\(sentence)")
        XCTAssertFalse(sentence.contains("全部列出"), "没量过总体就声称列全了：\(sentence)")
        print("【R18 正例·榜外未统计】\(sentence)")
    }

    // MARK: - ③ 反例

    /// 反例·「字段算对但句子用榜长」：榜长同为 20、榜外分别是 85 / 5 ⇒ 两句必须报出两个不同的总数。
    /// 实现若回去拿 `duplicatedBlocks.count` 当总数，两句会一模一样 ⇒ 红。
    func test_sameBoardLengthWithDifferentOutsideBoardCannotShareOneTotal() throws {
        let wide = try issue(Self.metrics(board: 20, outsideBoard: 85))
        let narrow = try issue(Self.metrics(board: 20, outsideBoard: 5))
        XCTAssertTrue(wide.contains("共 105 处"), "105 = 20 + 85，本文件自己加的：\(wide)")
        XCTAssertTrue(narrow.contains("共 25 处"), "25 = 20 + 5：\(narrow)")
        XCTAssertNotEqual(wide, narrow, "两句相等就说明榜外那一半没进句子")
        XCTAssertFalse(wide.contains("共 20 处"), "榜长又被当总数念了：\(wide)")
        XCTAssertFalse(narrow.contains("共 20 处"), "榜长又被当总数念了：\(narrow)")
    }

    /// 反例·榜外明明是 0 却写成「榜内只列」：那是把一件没发生的事渲染出来（与漏说对称的另一头）。
    func test_zeroOutsideBoardNeverClaimsBoardOnlyListing() throws {
        let full = Self.metrics(board: DuplicationEngine.maxBlocks, outsideBoard: 0)
        XCTAssertEqual(full.reportedDuplicatedBlockTotalCount, DuplicationEngine.maxBlocks)
        XCTAssertFalse(try issue(full).contains("榜内只列"), "榜外是 0 还说榜内只列 = 无中生有")
        let capped = Self.metrics(board: DuplicationEngine.maxBlocks, outsideBoard: 1)
        XCTAssertTrue(try issue(capped).contains("榜内只列"), "榜外有 1 块却不点名榜内 ⇒ 那 1 块又消失了")
    }

    /// 反例·字段本体的兜底方向：`nil` 必须还是 `nil`。
    /// 写成 `duplicatedBlocksDroppedByCap.map { … } ?? duplicatedBlocks.count` 就是
    /// 把「没统计」说成「一份没漏」——与 `reportedHugeFileCount` 的旧病同形，这条钉住它。
    func test_propertyRefusesToInventATotalWhenOutsideBoardWasNeverCounted() {
        XCTAssertNil(Self.metrics(board: 20, outsideBoard: nil).reportedDuplicatedBlockTotalCount,
                     "缺席被兜底成一个数 = 把没统计说成没漏")
        XCTAssertNil(Self.metrics(board: 0, outsideBoard: nil).reportedDuplicatedBlockTotalCount)
        XCTAssertEqual(Self.metrics(board: 20, outsideBoard: 0).reportedDuplicatedBlockTotalCount, 20)
        XCTAssertEqual(Self.metrics(board: 20, outsideBoard: 85).reportedDuplicatedBlockTotalCount, 105)
    }

    // MARK: - ③′ RD-87：那枚总数**落盘**（盘上读者拿不到计算属性）

    /// 真扫描：快照 == 唯一取法，而且**不等于榜长**。
    /// 后一半是关键：本仓榜外非零，快照若等于榜长，就说明装配读错了格子（落成了 `duplicatedBlocks.count`
    /// 的复印件 —— 那正是 R18 在 GUI 里消灭过的那个陷阱，只是这次是在 JSON 里重演）。
    func test_snapshotEqualsTheSingleHomeOnARealScan() async throws {
        let code = try await selfScan().code
        let home = try XCTUnwrap(code.reportedDuplicatedBlockTotalCount, "真扫描拿不出唯一取法 ⇒ 榜外那一格没填")
        let snapshot = try XCTUnwrap(code.duplicatedBlockTotalCountAfterDedup,
                                     "落盘快照没被真实扫描填上 ⇒ JSON 读者仍然只能自己加")
        XCTAssertEqual(snapshot, home, "快照与唯一取法分叉 ⇒ 两把尺子")
        XCTAssertGreaterThan(snapshot, code.duplicatedBlocks.count,
                             "快照等于榜长 ⇒ 它落错了东西（应为榜内 + 榜外）")
    }

    /// 三态：没统计过榜外 ⇒ 整键缺席；量到了 ⇒ 原样读回来。
    func test_snapshotRoundTripsAndStaysAbsentForOldReports() throws {
        let json = try String(data: try JSONEncoder().encode(CodeMetrics()), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains("duplicatedBlockTotalCountAfterDedup"),
                       "没量到也要写出这一格 ⇒ 「没统计」与「榜外是零」被压成一态")
        var measured = CodeMetrics()
        measured.duplicatedBlockTotalCountAfterDedup = 105
        let back = try JSONDecoder().decode(CodeMetrics.self,
                                           from: try JSONEncoder().encode(measured))
        XCTAssertEqual(back.duplicatedBlockTotalCountAfterDedup, 105)
    }

    /// 纪律：这一格**只服务盘上读者**，上屏一律走那枚计算属性 ⇒ 整个 `Sources` 里它只许出现两处
    /// （声明那一行 + 装配那一行）。第三处就是有人拿复印件当了第二把尺子。
    func test_snapshotIsNeverReadByADisplaySite() throws {
        let hits = try Self.sourceLinesMatching("duplicatedBlockTotalCountAfterDedup")
        XCTAssertFalse(hits.isEmpty, "扫描面一个都没命中 ⇒ 这条断言在空转")
        XCTAssertNil(Self.snapshotDrift(files: hits.map(\.file)),
                     "命中位置：\(hits.map { "\($0.file):\($0.line)" })")
    }

    /// 元测试：上面那把扫描尺对坏样例必须出声（本仓规矩：扫描型守卫不配元测试迟早永真绿）。
    func test_meta_snapshotDriftMatcherRejectsAThirdSiteAndAWrongHome() {
        XCTAssertNil(Self.snapshotDrift(files: ["CodeMetrics.swift", "FileSystemCodeAnalyzer.swift"]),
                     "合规形状被误报 ⇒ 下一个人会连合规一起删")
        XCTAssertNotNil(Self.snapshotDrift(
            files: ["CodeMetrics.swift", "FileSystemCodeAnalyzer.swift", "HealthCodeDimensions.swift"]),
                        "第三处读者没被抓出来 ⇒ 那把尺子是装饰品")
        XCTAssertNotNil(Self.snapshotDrift(files: ["CodeMetrics.swift", "CodeMetrics.swift"]),
                        "装配搬进了声明所在的冻结文件却没出声")
        XCTAssertNotNil(Self.snapshotDrift(files: ["CodeMetrics.swift"]), "只剩声明（没人写）也算漂移")
    }

    /// 「快照只许住在声明 + 装配两处」这条判据的纯函数那一半（元测试与真扫描共用一把尺）。
    private static func snapshotDrift(files: [String]) -> String? {
        let allowed: Set<String> = ["CodeMetrics.swift", "FileSystemCodeAnalyzer.swift"]
        guard files.count == 2, Set(files) == allowed else {
            return "快照被第三处读走、或从装配口搬走了：\(files)"
        }
        return nil
    }

    /// 扫 `Sources/**` 的**非注释行**，点名每一处提到某个字段名的位置。
    private static func sourceLinesMatching(_ name: String) throws -> [(file: String, line: Int)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor")
        let urls = ((FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL } ?? []).filter { $0.pathExtension == "swift" })
            .sorted { $0.path < $1.path }
        XCTAssertFalse(urls.isEmpty, "扫描面为空 ⇒ 所有『没命中』都不成立")
        var out: [(file: String, line: Int)] = []
        for url in urls {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for (index, raw) in text.split(separator: "\n").enumerated() {
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                if trimmed.contains(name) {
                    out.append((url.lastPathComponent, index + 1))
                }
            }
        }
        return out
    }

    // MARK: - ④ 在场语义：没出声的档位不许替它造句

    /// 高分档（本仓真实重复率就落在这一档）必须一句不出。
    /// 前一条断言同时是「为什么上面的正例要抬 ratio」的自证：真报告今天确实不出声。
    func test_highScoringDuplicationRaisesNoIssueAtAll() async throws {
        let reported = try await selfScan().code
        let quiet = WeightedHealthScorer().duplicationOutcome(HealthInputs(code: reported))
        XCTAssertTrue(quiet.issues.isEmpty,
                      "本仓真实重复率今天就会出声（\(NumberFormat.percent(reported.duplicationRatio, precision: 1))）"
                      + "，正例就不再需要抬 ratio：\(quiet.issues)")
        let probe = Self.metrics(board: 20, outsideBoard: 85, ratio: 0.005)
        XCTAssertEqual(WeightedHealthScorer().duplicationOutcome(HealthInputs(code: probe)).issues.count, 0,
                       "高分档造句 = 把不需要动的东西说成问题")
    }
}
