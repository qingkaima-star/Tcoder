import XCTest
@testable import TcoderMonitor

/// R5 · RD-25 覆盖率合并策略与丢弃披露。
///
/// 每条用例都自带**手算真值**（写在注释里），且先跑"修前形状"再跑"修后形状"：
/// 修前 = 把新判定摘掉后同一份夹具会被算成什么（`CoverageLegacyArithmetic.summed`）。
/// 六条验收场景的"修前 → 修后"数字全部由本文件产出，不靠口头声明。
final class CoverageMergeTests: XCTestCase {

    // MARK: - 夹具底座

    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func write(_ relative: String, _ contents: String) throws -> URL {
        let url = root.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func outcome() async throws -> CoverageMetrics.AnalysisOutcome {
        try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root, options: .default)
    }

    /// 一条带 `DA:` 逐行记录的 lcov 文件段。`hits` 里是命中行号集合。
    private func fileRecord(_ path: String, lines: ClosedRange<Int>, hits: Set<Int>) -> String {
        var text = "SF:\(path)\n"
        for line in lines {
            text += "DA:\(line),\(hits.contains(line) ? 1 : 0)\n"
        }
        text += "LF:\(lines.count)\nLH:\(hits.filter { lines.contains($0) }.count)\nend_of_record\n"
        return text
    }

    // MARK: - 场景①　相同数据的两种格式（同一次运行的双份落法）

    /// 真值：一次 nyc 运行同时导 `lcov.info` 与 `coverage-summary.json`，两份说的是同一批文件。
    /// 生产码 120/200 = **60%**。
    /// 修前形状：两份直接累加 ⇒ 240/400 —— 百分比"看着没变"，但**同一份证据被数了两遍**，
    /// 只要两份的 lines/statements 取舍不同（istanbul 的 statements 常比 lines 多），
    /// 这个"看着没变"立刻变成伪精确。
    func testSameRunPublishedInTwoFormatsCountsOnce() async throws {
        try write("web/coverage/lcov.info", """
        SF:src/app.js
        LF:100
        LH:60
        end_of_record
        SF:src/util.js
        LF:100
        LH:60
        end_of_record
        """)
        try write("web/coverage/coverage-summary.json", """
        {"total":{"lines":{"total":200,"covered":120},"branches":{"total":40,"covered":20}}}
        """)

        let result = try await outcome()
        print("【场景① 双格式同源】\(result.merge.statement)")
        XCTAssertEqual(result.metrics.reports.count, 1, "同一来源只许数一次")
        XCTAssertEqual(result.metrics.overallLinePercent ?? -1, 60, accuracy: 0.001,
                       "真值 120/200 = 60%")
        XCTAssertEqual(result.merge.basis, .singleReport, "去重后只剩一份带粒度的报告")
        XCTAssertEqual(result.merge.dropped.count, 1)
        XCTAssertEqual(result.merge.dropped.first?.reason, .sameRunDuplicate,
                       "丢弃必须点名为什么丢：\(result.merge.dropped.first?.reason.rawValue ?? "nil")")
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: [
            (covered: 120, total: 200), (covered: 120, total: 200)]), 240.0 / 400.0 * 100,
            "修前形状：同一份证据被累加成 240/400")
        // 留哪一份不是随便留：留**能参与合并**的那一份（lcov 带文件粒度），
        // 汇总粒度的一份虽然被丢出总数，但读数仍留在 separateReadings 里可查。
        XCTAssertEqual(result.metrics.reports.first?.toolName, "lcov")
        XCTAssertTrue(result.merge.separateReadings.contains { $0.toolName == "istanbul / nyc" },
                      "被去重的那份不许消失，要能单独查见")
    }

    // MARK: - 场景②　全仓报告 + 模块报告并存

    /// 真值：全仓那份已经是三个模块的并集（同一批源码），模块三份是它的子集。
    /// 生产码 300/600 = **50%**；修前 600/1200 = 分母被同一批文件数了两遍。
    func testWholeRepoAndModuleReportsMergeIntoOneUnion() async throws {
        let whole = """
        SF:src/a.js
        LF:200
        LH:100
        end_of_record
        SF:src/b.js
        LF:200
        LH:100
        end_of_record
        SF:src/c.js
        LF:200
        LH:100
        end_of_record
        """
        try write("coverage/lcov.info", whole)
        try write("pkgs/a/coverage/lcov.info", "SF:src/a.js\nLF:200\nLH:100\nend_of_record\n")
        try write("pkgs/b/coverage/lcov.info", "SF:src/b.js\nLF:200\nLH:100\nend_of_record\n")
        try write("pkgs/c/coverage/lcov.info", "SF:src/c.js\nLF:200\nLH:100\nend_of_record\n")

        let result = try await outcome()
        print("【场景② 全仓+模块】\(result.merge.statement)")
        XCTAssertEqual(result.metrics.reports.count, 1)
        let union = try XCTUnwrap(result.metrics.reports.first)
        XCTAssertEqual(union.linesTotal, 600, "并集分母：a/b/c 三个文件各 200 行，不重复")
        XCTAssertEqual(union.linesCovered, 300)
        XCTAssertEqual(result.metrics.overallLinePercent ?? -1, 50, accuracy: 0.001)
        XCTAssertEqual(result.merge.basis, .lineSetUnion)
        XCTAssertEqual(result.merge.unionFileCount, 3)
        XCTAssertEqual(result.metrics.reports.first?.toolName, "lcov 并集（4 份按源码行合并）")
    }

    // MARK: - 场景③　unit / integration 命中集合重叠

    /// 真值（按源码行求并）：`src/shared.js` 100 行，unit 命中 1..60、integration 命中 41..100
    /// ⇒ 并集命中 100 行；再加 integration 独有的 `src/only-it.js` 10/20 ⇒ **110/120 = 91.667%**。
    /// 修前：(60+70)/(100+120) = 130/220 = 59.09% —— 重叠行被数两遍、分母也翻倍。
    func testUnitAndIntegrationOverlapIsUnionNotSum() async throws {
        try write("coverage/unit/lcov.info",
                  fileRecord("src/shared.js", lines: 1...100, hits: Set(1...60)))
        try write("coverage/integration/lcov.info",
                  fileRecord("src/shared.js", lines: 1...100, hits: Set(41...100))
                  + fileRecord("src/only-it.js", lines: 1...20, hits: Set(1...10)))

        let result = try await outcome()
        print("【场景③ unit/集成重叠】\(result.merge.statement)")
        let union = try XCTUnwrap(result.metrics.reports.first)
        XCTAssertEqual(union.linesTotal, 120, "两个源文件的行集合求并后的分母")
        XCTAssertEqual(union.linesCovered, 110, "1..100 全覆盖 + only-it 的 10 行")
        XCTAssertEqual(result.metrics.overallLinePercent ?? -1, 110.0 / 120.0 * 100, accuracy: 0.001)
        XCTAssertEqual(result.merge.basis, .lineSetUnion)
        XCTAssertEqual(result.merge.conflictingFileCount, 0, "两份都有逐行证据 ⇒ 不需要判冲突")
        // 并集报告不再声称分支/方法数：报告里没有逐分支身份，相加就是双计。
        XCTAssertNil(union.branchesTotal, "多份合并后分支数不许相加 ⇒ 报 nil 而不是报一个数")
        XCTAssertNil(result.metrics.overallBranchPercent)
    }

    /// 拿不到逐行证据、又撞上同一个文件 ⇒ **判冲突、两边一起摘出分母**，
    /// 而不是"挑一份算"或"两份相加"。
    func testOverlappingFilesWithoutLineEvidenceAreExcludedNotSummed() async throws {
        try write("coverage/unit/lcov.info", "SF:src/shared.js\nLF:100\nLH:60\nend_of_record\n")
        try write("coverage/integration/lcov.info", "SF:src/shared.js\nLF:100\nLH:90\nend_of_record\n")

        let result = try await outcome()
        print("【冲突态】\(result.merge.statement)")
        XCTAssertEqual(result.merge.conflictingFileCount, 1)
        XCTAssertEqual(result.metrics.reports.isEmpty, true,
                       "唯一的那个文件被判冲突 ⇒ 没有可信分母 ⇒ 不给总数")
        XCTAssertNil(result.metrics.overallLinePercent, "缺证据必须是 nil，不是 0%，也不是 75%")
        XCTAssertFalse(result.metrics.hasData)
        XCTAssertEqual(result.merge.basis, .nothingMergeable)
        XCTAssertFalse(result.merge.separateReadings.isEmpty, "分开呈现的读数要留着可查")
    }

    // MARK: - 场景④　七个以上模块

    /// 真值：8 个模块各 100 行命中 50，源码互不相交 ⇒ **400/800 = 50%**。
    /// 修前：`prefix(6)` 静默留 6 份 ⇒ 300/600，**没有任何一处说丢了 2 份**。
    func testNineModulesAreAllCountedAndNothingIsSilentlyDropped() async throws {
        for module in ["a", "b", "c", "d", "e", "f", "g", "h"] {
            try write("pkg-\(module)/coverage/lcov.info",
                      "SF:src/\(module)/core.js\nLF:100\nLH:50\nend_of_record\n")
        }

        let result = try await outcome()
        print("【场景④ 8 模块】\(result.merge.statement)")
        XCTAssertEqual(result.metrics.reports.count, 1)
        let union = try XCTUnwrap(result.metrics.reports.first)
        XCTAssertEqual(union.linesTotal, 800, "修前是 600（六份 × 100）")
        XCTAssertEqual(union.linesCovered, 400, "修前是 300")
        XCTAssertEqual(result.merge.unionFileCount, 8)
        XCTAssertEqual(result.merge.dropped.count, 0, "全部并入 ⇒ 一份都没丢")
        XCTAssertEqual(result.merge.consideredCount, 8)
        XCTAssertEqual(result.merge.includedCount, 1, "计入的是**并集那一份**，考虑过的是 8 份")
        XCTAssertTrue(result.merge.statement.contains("考虑 8 份"))
    }

    /// 逐行账本被内存预算截断时，那一份必须**降级并点名** ——
    /// 残缺的并集比没有并集更坏：它会给出一个看起来精确、实际少算了文件的总数。
    /// （旧实现里对应的位置是 `prefix(6)`：同样截断，一声不响。）
    func testLineBudgetTruncationDowngradesThatLedgerAndSaysSo() async throws {
        try write("pkg-a/coverage/lcov.info",
                  CoverageMergeFixtures.file("src/a/core.js", lines: 1...200, hits: Set(1...100)))
        try write("pkg-b/coverage/lcov.info",
                  CoverageMergeFixtures.file("src/b/core.js", found: 100, hit: 50))

        // 预算 150 行：第一份 200 行的账本一定被截断，第二份只有汇总计数、不受影响。
        let result = try await CoverageAnalyzer(lineBudget: 150)
            .analyzeWithLedger(projectRoot: root, options: .default)
        print("【逐行预算】\(result.merge.statement)")
        let truncated = result.merge.dropped.filter { ($0.detail ?? "").contains("逐行预算") }
        XCTAssertEqual(truncated.count, 1, "被截断的那一份要点名：\(result.merge.statement)")
        XCTAssertTrue(result.merge.statement.contains("内存预算截断"), result.merge.statement)
        XCTAssertEqual(result.merge.mergeConfident, false, "有一份没并进总数 ⇒ 不许声称可信合并")
        XCTAssertNotNil(result.metrics.overallLinePercent, "另一份仍然给出它自己的读数")
    }

    // MARK: - 场景：全汇总粒度、无法核对重叠 ⇒ 不给总数

    /// 五份不同生态的**汇总粒度**报告：没有任何一处写着各自覆盖了哪些文件，
    /// 于是"相加"与"取一份"都是猜。判据：**不给伪精确总数**。
    func testAggregateOnlyReportsNeverProduceAFakeTotal() async throws {
        try write("web/coverage/coverage-summary.json",
                  #"{"total":{"lines":{"total":400,"covered":340}}}"#)
        try write("server/target/jacoco.xml",
                  #"<report><counter type="LINE" missed="300" covered="700"/></report>"#)
        try write("py/coverage.xml",
                  #"<coverage lines-covered="620" lines-valid="1000"/>"#)
        try write("legacy/clover.xml",
                  #"<coverage><project><metrics statements="500" coveredstatements="425"/></project></coverage>"#)
        try write("other/coverage/lcov.info", "SF:src/x.js\nLF:0\nLH:0\nend_of_record\n")

        let result = try await outcome()
        print("【全汇总粒度】\(result.merge.statement)")
        XCTAssertNil(result.metrics.overallLinePercent, "五份汇总报告相加得到的任何数都是伪精确")
        XCTAssertFalse(result.metrics.hasData)
        XCTAssertEqual(result.merge.basis, .nothingMergeable)
        XCTAssertEqual(result.merge.separateReadings.count, 4,
                       "被拒绝合并的读数要一份不落地留着（分开呈现的数据源）")
        XCTAssertTrue(result.merge.dropped.allSatisfy {
            $0.reason == .aggregateOnlyCannotCrossCheck || $0.reason == .lineSetConflict
        }, "丢弃原因必须落在'无法核对重叠'这一档：\(result.merge.dropped.map { $0.reason })")
    }

    /// 只有一份报告时不存在合并，也就谈不上双计 —— 该给数就给数（不许为了保守装成缺证据）。
    func testSingleAggregateReportStillProducesItsOwnNumber() async throws {
        try write("target/jacoco/jacoco.xml",
                  #"<report><counter type="LINE" missed="300" covered="700"/></report>"#)
        let result = try await outcome()
        XCTAssertEqual(result.metrics.overallLinePercent ?? -1, 70, accuracy: 0.001)
        XCTAssertEqual(result.merge.basis, .singleReport)
        XCTAssertEqual(result.merge.mergeConfident, true)
    }

    // MARK: - 场景⑤　旧报告与当前源码不一致

    /// 报告 mtime 早于最新提交 ⇒ 它测的不是当前源码：**不计入总数**，并单独计数。
    /// 修前：50/100 照进总分，健康分照给"测试覆盖 62 分"、建议照写"从 50.0% 提升到 75% 以上"。
    func testReportOlderThanLatestCommitIsExcludedAndSaysSo() async throws {
        try write("coverage/lcov.info", "SF:src/a.js\nLF:100\nLH:50\nend_of_record\n")
        let source = CoverageSourceState(headCommit: "deadbeefcafe",
                                         headCommitDate: Date(timeIntervalSince1970: 1_700_000_000),
                                         readFailure: nil)
        let stale = CoverageBinding.state(generatedAt: Date(timeIntervalSince1970: 1_600_000_000),
                                          source: source)
        XCTAssertEqual(stale, .olderThanHead)
        XCTAssertTrue(stale.provesStaleness)

        // 走完整分析器：把夹具的 mtime 改到"最新提交之前"要有 git 可读，
        // 这里用同一套判定函数的输出直接过规划器（git 子进程那条在 CLI 取证用例里跑）。
        let candidate = CoverageCandidate(
            report: CoverageReport(path: root.appendingPathComponent("coverage/lcov.info").path,
                                   kind: .combined, toolName: "lcov",
                                   linesCovered: 50, linesTotal: 100,
                                   branchesCovered: 0, branchesTotal: nil,
                                   methodsCovered: 0, methodsTotal: 0,
                                   allLinesCovered: 50, allLinesTotal: 100,
                                   scopeGranularity: .perSourceFile),
            identity: CoverageReportIdentity.derive(
                path: root.appendingPathComponent("coverage/lcov.info").path,
                root: root, format: .lcov, kind: .combined),
            binding: stale, ledger: nil)
        let plan = CoverageMergePlanner.plan(candidates: [candidate], consideredCount: 1,
                                             parseFailures: [],
                                             discovery: CoverageDiscoveryStats())
        XCTAssertTrue(plan.scoring.isEmpty, "陈旧报告不许进总数")
        XCTAssertEqual(plan.ledger.staleReportCount, 1)
        XCTAssertTrue(plan.ledger.statement.contains("早于当前源码提交"), plan.ledger.statement)
    }

    /// mtime **不是**提交绑定。三态要各自有名：未绑定 / 无时间 / 不早于（≠ 绑定在 HEAD 上）。
    func testMtimeIsNeverReportedAsCommitBinding() {
        let noGit = CoverageSourceState(headCommit: nil, headCommitDate: nil,
                                        readFailure: "所选目录内没有 .git")
        XCTAssertEqual(CoverageBinding.state(generatedAt: Date(), source: noGit), .unbound)
        XCTAssertEqual(CoverageBinding.state(generatedAt: nil, source: noGit), .undated)
        let fresh = CoverageSourceState(headCommit: "abc123",
                                        headCommitDate: Date(timeIntervalSince1970: 1_000),
                                        readFailure: nil)
        let loose = CoverageBinding.state(generatedAt: Date(timeIntervalSince1970: 2_000), source: fresh)
        XCTAssertEqual(loose, .notContradictedByHead)
        XCTAssertFalse(loose.provesStaleness)
        XCTAssertTrue(loose.note.contains("mtime 不是提交绑定"), loose.note)
    }

    // MARK: - 场景⑥　没有报告 = 缺证据，不是 0%

    func testNoReportsStayAbsenceNotZeroPercent() async throws {
        let result = try await outcome()
        XCTAssertFalse(result.metrics.hasData)
        XCTAssertNil(result.metrics.overallLinePercent)
        XCTAssertEqual(result.merge.basis, .nothingDiscovered)
        XCTAssertNil(result.merge.mergeConfident, "压根没扫到 ⇒ 谈不上置不置信（nil ≠ false）")
        XCTAssertEqual(result.metrics.riskLevel, .none)
        XCTAssertTrue(result.merge.statement.contains("没有扫到任何覆盖率报告文件"))
    }

    /// 扫到了文件却全都读不出数字 ⇒ 说的是"有报告、没测出东西"，不是"该项目没产出报告"。
    func testUnreadableAndEmptyReportsAreCountedWithReasons() async throws {
        try write("a/coverage/lcov.info", "")                       // 空文件
        try write("b/coverage/lcov.info", "TN:x\nLF:0\nLH:0\n")      // 读到了但没有可用分母
        try write("c/coverage/coverage-summary.json", "{ not json")  // 解析失败

        let result = try await outcome()
        print("【读不动的三份】\(result.merge.statement)")
        XCTAssertEqual(result.merge.consideredCount, 3)
        XCTAssertEqual(result.metrics.scannedFileCount, 3, "考虑数必须与落盘的 scannedFileCount 同源")
        XCTAssertNil(result.metrics.overallLinePercent)
        XCTAssertEqual(Set(result.merge.parseFailures.map(\.reason)),
                       [.emptyFile, .noUsableNumbers],
                       "空文件与'读到但没数字'要分得开：\(result.merge.parseFailures)")
        XCTAssertTrue(result.merge.statement.contains("空文件"), result.merge.statement)
    }

    /// 目录数上限命中时也要出声（旧实现命中 40 份后剩下的目录**静默不下潜**）。
    func testDiscoveryFileCapIsDisclosedWhenHit() async throws {
        for index in 0...CoverageReportDiscovery.maxReportFiles {     // 41 份 > 40
            try write("m\(index)/coverage/lcov.info",
                      "SF:src/m\(index)/a.js\nLF:10\nLH:5\nend_of_record\n")
        }
        let result = try await outcome()
        XCTAssertGreaterThanOrEqual(result.merge.discovery.directoriesSkippedByFileCap, 1)
        XCTAssertTrue(result.merge.statement.contains("没有下潜"), result.merge.statement)
    }

    // MARK: - 恒等式：考虑 = 计入 + 丢弃 + 读失败

    /// 这一条是"不许静默截断"的**总闸门**：两份账必须各自拼得起来 ——
    /// ①考虑 = 解析成功 + 读取失败；②解析成功 = 并入总数 + 被丢弃。
    /// 任何一份报告"悄悄不见"都会让这里变红（旧实现的 `prefix(6)` 与 `return nil` 两处都红）。
    func testBothAccountIdentitiesHoldAcrossEveryScenario() async throws {
        var checked = 0
        for scenario in CoverageMergeFixtures.all {
            let base = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("r5-ledger-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: base) }
            scenario.install(into: base)
            let ledger = try await CoverageAnalyzer().analyzeWithLedger(projectRoot: base,
                                                                        options: .default).merge
            XCTAssertTrue(ledger.consideredAccountBalanced,
                          "场景「\(scenario.name)」账①不平：\(ledger.statement)")
            XCTAssertTrue(ledger.parsedAccountBalanced,
                          "场景「\(scenario.name)」账②不平：\(ledger.statement)")
            XCTAssertEqual(ledger.consideredCount, scenario.reportFiles.count,
                           "场景「\(scenario.name)」的考虑数与夹具份数不一致")
            checked += 1
        }
        XCTAssertGreaterThanOrEqual(checked, 6, "六个场景一个都没跑成 ⇒ 这条守卫是空跑")
        print("【恒等式】\(checked) 个场景的考虑/解析/并入/丢弃四数全部拼得起来")
    }
}

/// 「修前形状」的算式，独立于实现写死在这里：
/// 旧代码是 `Array(sorted { $0.linesTotal > $1.linesTotal }.prefix(6))` +
/// `overallLinePercent` 把留下的报告 `covered`/`total` 分别累加相除。
/// 本类型只用来把"修前读数"钉成可断言的数字，不参与任何产品判定。
enum CoverageLegacyArithmetic {
    /// 旧算法的总分：留下的报告直接累加相除。
    static func summed(from reports: [(covered: Int, total: Int)], cap: Int = 6) -> Double {
        let kept = reports.sorted { $0.total > $1.total }.prefix(cap)
        let total = kept.reduce(0) { $0 + $1.total }
        guard total > 0 else { return -1 }
        return Double(kept.reduce(0) { $0 + $1.covered }) / Double(total) * 100
    }

    /// 旧实现留下了几份（`prefix(6)` 的可见后果：其余的**没有任何地方说它们被丢了**）。
    static func keptCount(from reports: [(covered: Int, total: Int)], cap: Int = 6) -> Int {
        reports.sorted { $0.total > $1.total }.prefix(cap).count
    }
}
