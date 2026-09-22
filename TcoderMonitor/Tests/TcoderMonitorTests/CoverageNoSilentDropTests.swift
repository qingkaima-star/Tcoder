import XCTest
@testable import TcoderMonitor

/// R5b · 第四件：一条新守卫 —— **「新写进磁盘的合法报告不许被静默丢弃」**（双向元测试）。
///
/// 形状要求（派单原文）：**刚好到上限不许多报、超一份必须报**，
/// 且「另有 N 份未合并」那句单独摘掉就要转红 —— 所以这里正反两个方向各钉一次：
///   · 正向：喂一份超限报告 ⇒ 那句必须在（数字与点名都要有）；
///   · 反向：一份都没超 ⇒ 那句必须**不在**（不许把"没丢"渲染成"丢了"，也不许留个空壳句子）。
///
/// **独立真值**：40 / 41 是测试自己数的；"被丢下的是哪一份"由测试按路径序**自己算**
/// （写 41 个模块目录 `m0…m40`，字典序最大的是 `m40/coverage/lcov.info`，
/// 于是被丢下的必须是它），不是拿实现输出当正确答案。
final class CoverageNoSilentDropTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5b-cap-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeModule(_ index: Int, into base: URL? = nil) throws {
        let directory = (base ?? root).appendingPathComponent("m\(index)/coverage", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "SF:src/m\(index)/a.js\nLF:10\nLH:5\nend_of_record\n"
            .write(to: directory.appendingPathComponent("lcov.info"), atomically: true, encoding: .utf8)
    }

    /// 独立真值：测试自己写出来的那 41 个相对路径，按字典序排完取最后一个。
    /// （上限 40 ⇒ 前 40 个交给合并，最后那一个必须被点名，见 `testOneReportOverTheCap…`）
    private var expectedDroppedPath: String {
        let all = (0...40).map { "m\($0)/coverage/lcov.info" }
        return all.sorted().last ?? ""
    }

    private func metrics(in base: URL? = nil) async throws -> CoverageMetrics {
        try await CoverageAnalyzer().analyze(projectRoot: base ?? root, options: .default)
    }

    /// 带台账的那一份：披露句（`statement`）在台账侧，只比字段比不到它。
    private func analyze() async throws -> CoverageMetrics.AnalysisOutcome {
        try await CoverageAnalyzer().analyzeWithLedger(projectRoot: root, options: .default)
    }

    // MARK: - 双向：刚好到上限不许多报

    /// 40 份（**正好**等于 `maxReportFiles`）⇒ 一份都没丢：`droppedByCap == 0`、
    /// `undisplayedReports == []`、那句「另有 N 份未合并」必须**不出现**。
    func testExactlyAtTheCapReportsNothingAsDropped() async throws {
        for index in 0..<CoverageReportDiscovery.maxReportFiles { try writeModule(index) }
        let metrics = try await metrics()
        XCTAssertEqual(CoverageReportDiscovery.maxReportFiles, 40, "夹具形状依赖这个上限")
        XCTAssertEqual(metrics.scannedFileCount, 40)
        XCTAssertEqual(metrics.displayedCount, 40)
        XCTAssertEqual(metrics.truncationTotalCount, 40)
        XCTAssertEqual(metrics.undisplayedCount, 0)
        XCTAssertEqual(metrics.droppedByCap, 0, "0 是一句真话，不许留 nil 也不许写 1")
        XCTAssertEqual(metrics.undisplayedReports, [])
        XCTAssertNil(metrics.unmeasuredScope, "全都看过了 ⇒ 不造「没看完」那句")
        XCTAssertEqual(metrics.capDisclosureText, "没有报告因命中上限被丢弃")
        XCTAssertFalse(metrics.capDisclosureText.contains("另有"), metrics.capDisclosureText)
    }

    // MARK: - 双向：超一份必须报

    /// 41 份 ⇒ 必须报：`droppedByCap == 1`、逐条点名（坐标 = 相对路径），
    /// 且**被点名的那份**就是按路径排序后落在上限之外的那一份（测试自己算的期望）。
    func testOneReportOverTheCapIsNamedAndCounted() async throws {
        let cap = CoverageReportDiscovery.maxReportFiles
        for index in 0...cap { try writeModule(index) }          // 41 份
        let metrics = try await metrics()

        XCTAssertEqual(metrics.truncationTotalCount, cap + 1)
        XCTAssertEqual(metrics.displayedCount, cap)
        XCTAssertEqual(metrics.undisplayedCount, 1)
        XCTAssertEqual(metrics.droppedByCap, 1)
        // 独立真值（**自己数**，不是从实现里读）：41 个模块目录按**字典序**排，
        // `m9` 排在 `m10…m40` 之后（"9" > "4"），所以第 41 个必须是它 —— 数值序会算错成 m40。
        XCTAssertEqual(metrics.undisplayedReports, [expectedDroppedPath],
                       "超限那一份必须逐条点名（可点名、可 diff），一行摘要不算台账")
        XCTAssertEqual(expectedDroppedPath, "m9/coverage/lcov.info",
                       "这条独立真值本身的来历：41 个相对路径排序后的最后一个")
        XCTAssertTrue(metrics.capDisclosureText.contains("另有 1 份未合并"), metrics.capDisclosureText)
        XCTAssertEqual(metrics.reports.count, 1, "进总数的是并集那一份读数")
        XCTAssertTrue(metrics.reports.allSatisfy { $0.linesTotal > 0 },
                      "被丢下的那份不许混进分母")
    }

    /// **同一棵树扫两次**、以及**内容相同、目录写入顺序相反的两棵树** ⇒
    /// 被丢下的必须是同一批文件（比的是相对路径，两棵树可直接对得上）。
    /// 钉住的病：旧实现"谁被丢"取决于 `contentsOfDirectory` 的未定义顺序 ⇒ 同一棵树两次
    /// 扫出两个总数（RD-39 那条"只在整套跑时红"就是同族：环境形状混进了判定）。
    func testTheDroppedReportDoesNotDependOnWalkOrWriteOrder() async throws {
        let cap = CoverageReportDiscovery.maxReportFiles
        let twin = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5b-cap-twin-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: twin, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: twin) }

        for index in 0...cap { try writeModule(index) }                              // 正序写
        for index in stride(from: cap, through: 0, by: -1) { try writeModule(index, into: twin) }   // 逆序写

        let first = try await metrics()
        let second = try await metrics(in: twin)
        let firstTotal = try XCTUnwrap(first.truncationTotalCount)
        let secondTotal = try XCTUnwrap(second.truncationTotalCount)
        XCTAssertEqual(firstTotal, secondTotal)
        XCTAssertEqual(first.undisplayedReports, second.undisplayedReports,
                       "同样内容的两棵树（写入顺序相反）丢下的必须是同一批")
        XCTAssertEqual(try XCTUnwrap(first.overallLinePercent),
                       try XCTUnwrap(second.overallLinePercent), accuracy: 0.0001)
        XCTAssertEqual(first.undisplayedReports, [expectedDroppedPath],
                       "被丢下的那份只由路径序决定，与枚举/写入顺序无关")

        let again = try await metrics()
        XCTAssertEqual(again.undisplayedReports, first.undisplayedReports, "同一棵树两次扫也要同一批")
    }

    // MARK: - 「新写进磁盘」这一动作本身（删一份 ⇒ 归零；补一份 ⇒ 必须报）

    /// 先把树写到刚好上限（此时读数是"没丢任何东西"），**再往盘上写一份合法报告** ⇒
    /// 下一次扫描必须出声；把那份删掉 ⇒ 又必须回到"没丢"。两个方向都不许靠缓存。
    func testNewlyWrittenReportCannotStaySilentAndDeletionRestoresIt() async throws {
        let cap = CoverageReportDiscovery.maxReportFiles
        for index in 0..<cap { try writeModule(index) }
        let before = try await analyze()
        XCTAssertEqual(before.metrics.droppedByCap, 0)
        XCTAssertFalse(before.merge.statement.contains("份未合并"),
                       "没丢东西时那句不许挂在页上：\(before.merge.statement)")

        try writeModule(cap)                                     // 新写进磁盘的第 41 份
        let after = try await analyze()
        XCTAssertEqual(after.metrics.droppedByCap, 1, "新写的合法报告被静默丢弃 = 本轮要修的病根")
        XCTAssertEqual(after.metrics.undisplayedReports, [expectedDroppedPath])
        XCTAssertEqual(try XCTUnwrap(after.metrics.truncationTotalCount),
                       try XCTUnwrap(before.metrics.truncationTotalCount) + 1)
        // 端到端钉那一句（不是只钉字段）：摘掉 `statementParts` 里那行 ⇒ 这里与
        // `testTheDisclosureSentenceHasTeethInBothDirections` 同时转红（已实测，见 Obsidian `112`）。
        XCTAssertTrue(after.merge.statement.contains("另有 1 份未合并"), after.merge.statement)
        XCTAssertTrue(after.merge.statement.contains("m9"), "点名要点到那份文件：\(after.merge.statement)")

        let newcomer = root.appendingPathComponent("m40/coverage/lcov.info")
        try FileManager.default.removeItem(at: newcomer)
        let restored = try await analyze()
        XCTAssertEqual(restored.metrics.droppedByCap, 0, "摘掉超的那份之后必须回到「没丢」，不许留着旧账")
        XCTAssertEqual(restored.metrics.undisplayedReports, [])
        XCTAssertNil(restored.metrics.unmeasuredScope)
        XCTAssertFalse(restored.merge.statement.contains("份未合并"), restored.merge.statement)
    }

    // MARK: - 那句披露单独摘掉就要转红（元测试，两个方向）

    /// 正向：`droppedByCap > 0` ⇒ `statementParts` 里必须有「另有 N 份未合并」+ 点名的文件名。
    /// 反向：`droppedByCap == 0` ⇒ 那句必须**不在**（不许有空壳句子挂在页上）。
    /// 这条断言的"有牙"是实测过的：把 `CoverageDisplayShape.statementParts` 里那一段单独注释掉，
    /// `testTheDisclosureSentenceHasTeethInBothDirections` 与上面两条用例会同时转红（见 Obsidian `112`）。
    func testTheDisclosureSentenceHasTeethInBothDirections() {
        let over = CoverageDisplayShape.evaluate(
            discovery: CoverageDiscoveryStats(foundCount: 40,
                                              fileCapSkippedDirectories: ["m41/coverage"],
                                              overCapReportPaths: ["m41/coverage/lcov.info"]),
            displayedCount: 40)
        XCTAssertEqual(over.droppedByCap, 1)
        XCTAssertTrue(over.statementParts.contains { $0.contains("另有 1 份未合并")
            && $0.contains("lcov.info") }, "超限要出声、要点名：\(over.statementParts)")
        XCTAssertTrue(over.statementParts.contains { $0.contains("没有下潜") },
                      "「没下潜」与「超限没读」是两处事实，都要说：\(over.statementParts)")

        let within = CoverageDisplayShape.evaluate(discovery: CoverageDiscoveryStats(), displayedCount: 0)
        XCTAssertEqual(within.droppedByCap, 0)
        XCTAssertFalse(within.statementParts.contains { $0.contains("未合并") },
                       "没丢东西还喊「另有 N 份未合并」= 把「没量到」渲染成「出了问题」：\(within.statementParts)")
        XCTAssertTrue(within.statementParts.isEmpty, "扫描面完整 ⇒ 一句披露都不许造：\(within.statementParts)")
    }
}
