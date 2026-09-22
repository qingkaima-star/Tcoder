import XCTest
@testable import TcoderMonitor

/// R13 · RD-50 —— **覆盖率那本账上屏**（字段早就落盘、装配口早就有，缺的是最后那个读者）。
///
/// # 真值从哪来（不是拿实现输出当答案）
/// 夹具是本文件自己写的 40/43 份 lcov（落仓库内 `.scratch/`，teardown 删干净）。
/// 「被丢下的是哪三份」由测试把自己写出的 43 个相对路径**自己排序**算出来；
/// 上限那个 40 读产品侧常量 `CoverageReportDiscovery.maxReportFiles`，不在这里抄一个数。
///
/// # 四态各自成一条
/// * **正例**：同一趟扫描里，「界面上那句里的数」与「字段里的数」互相对账
///   （从中文句里正则抠出 N，必须 == `droppedByCap`；点名坐标必须逐条 == `undisplayedReports`）。
/// * **0**：`0` 是一句真话 ⇒ 那一行**一个字都不许多**（`boardAccountingNote == nil`）。
/// * **缺席**：旧报告缺键 ⇒ 既不许渲染成 0，也不许说成「没有报告被丢弃」，
///   只许说「未统计」（三态不许混是工单硬线 3）。
/// * **分叉（反例）**：装配口被绕过 / 句子被手写进视图 / 数从榜内长度而非总数来
///   —— 三种分叉各有一条断言钉，不是只钉「句子没写」。
///
/// # 为什么 `reports.count`（榜内长度）在这里当反证用
/// 43 份合并完只产出 **1** 份读数，而真被摘掉的是 **3** 份 ⇒ 谁拿榜内长度当"丢了几份"，
/// 那句会写成「另有 1 份未合并」，与字段 `droppedByCap == 3` 当场分叉。
final class CoverageAccountingReadoutTests: SelfScanHarnessCase {

    private var root: URL!
    private var cap: Int { CoverageReportDiscovery.maxReportFiles }

    override func setUpWithError() throws {
        // 一次性产物落仓库内 `.scratch/`（已 gitignore，且被自扫剪枝、被覆盖率发现阶段
        // 的 `.skipsHiddenFiles` 挡在外面 ⇒ 不会污染任何别的守卫的总体）。
        root = Self.repoRoot.appendingPathComponent(".scratch/r13-accounting-\(UUID().uuidString)",
                                                   isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - 夹具

    /// 一个模块目录一份 lcov（内容与 R5b 那批同形状，独立于实现：数字是这里自己写的）。
    private func writeModule(_ index: Int) throws {
        let directory = root.appendingPathComponent("m\(index)/coverage", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try "SF:src/m\(index)/a.js\nLF:10\nLH:5\nend_of_record\n"
            .write(to: directory.appendingPathComponent("lcov.info"), atomically: true, encoding: .utf8)
    }

    /// 独立真值：测试自己写出来的那批相对路径，按字典序排完取**落在上限之外**的那几个。
    /// （`m9` 按字典序排在 `m10…m40` 之后 ⇒ 数值序会算错，这里刻意用字典序。）
    private func droppedTruth(count: Int) -> [String] {
        ((0..<count).map { "m\($0)/coverage/lcov.info" }).sorted().suffix(3).map { $0 }
    }

    private func scanned() async throws -> CoverageMetrics {
        try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
    }

    /// 从中文句里把「另有 N 份未合并」那个 N 抠出来（句子与字段分叉就靠它现形）。
    private func numberInSentence(_ text: String) -> Int? {
        guard let match = text.range(of: "另有 ([0-9]+) 份未合并", options: .regularExpression) else { return nil }
        let digits = text[match].filter { $0.isNumber }
        return Int(digits)
    }

    // MARK: - 正例：界面那句里的数 == 字段里的数（同一次扫描，两个来源对账）

    func testSentenceNumbersEqualFieldNumbersOnOneScan() async throws {
        for index in 0..<(cap + 3) { try writeModule(index) }        // 43 份，故意超上限 3 份
        let metrics = try await scanned()
        let note = try XCTUnwrap(metrics.boardAccountingNote, "超限 3 份 ⇒ 那句必须上屏")

        // ① 独立真值先自证（不是从实现里读的）：43 - 40 = 3，被丢下的是路径序最后三个。
        XCTAssertEqual(metrics.truncationTotalCount, cap + 3)
        XCTAssertEqual(metrics.displayedCount, cap)
        XCTAssertEqual(metrics.droppedByCap, 3)
        XCTAssertEqual(metrics.undisplayedReports, droppedTruth(count: cap + 3))

        // ② 句子里的数 == 字段里的数（分叉守卫：改字段不改句子，这里就红）。
        XCTAssertEqual(numberInSentence(note), metrics.droppedByCap, note)
        XCTAssertEqual(numberInSentence(note), 3, note)

        // ③ 点名要点到**坐标**，只报 basename 等于没点名（一棵树里 43 份都叫 lcov.info）。
        for coordinate in metrics.undisplayedReports ?? [] {
            XCTAssertTrue(note.contains(coordinate), "那句必须把已有坐标带出来：\(coordinate) / \(note)")
        }

        // ④ 数字**不是**从榜内长度来的：43 份合并完只有 1 份读数，真丢的是 3 份。
        XCTAssertNotEqual(metrics.reports.count, metrics.droppedByCap,
                          "夹具失去判别力（榜内长度恰好等于丢弃份数），这条反证就白写了")
        XCTAssertFalse(note.contains("另有 \(metrics.reports.count) 份"), note)

        // ⑤ 装配口没被绕过：那句逐字等于 `statementParts`（本仓唯一的披露生产者）。
        let shape = try XCTUnwrap(metrics.displayShapeFromFields)
        XCTAssertEqual(note, shape.statementParts.joined(separator: "；") + "。")
        XCTAssertEqual(shape.truncationTotalCount - shape.displayedCount, shape.undisplayedCount,
                       "恒等式①：总数 = 榜内 + 榜外")
    }

    // MARK: - 0 态：量过了、真的没切 ⇒ 一个字都不许多

    func testExactlyAtTheCapAddsNotASingleCharacter() async throws {
        for index in 0..<cap { try writeModule(index) }              // 正好 40 份
        let metrics = try await scanned()
        XCTAssertNotNil(metrics.displayShapeFromFields, "六格齐全 ⇒ 这是一本量过的账，不是没统计")
        XCTAssertEqual(metrics.droppedByCap, 0)
        XCTAssertEqual(metrics.undisplayedReports, [])
        XCTAssertNil(metrics.unmeasuredScope)
        XCTAssertNil(metrics.boardAccountingNote,
                     "没切掉任何东西还挂一句披露 = 把「没量到」渲染成「出了问题」那一族的镜像")
    }

    // MARK: - 缺席态：旧报告缺键 ⇒ 不许渲染成 0，也不许说成「没被切掉」

    func testAbsentLedgerNeverRendersAsZeroOrAsClean() async throws {
        for index in 0..<(cap + 3) { try writeModule(index) }
        let metrics = try await scanned()

        // 把这本账的六格从 JSON 里整键删掉 = 旧版报告的样子。
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(metrics)) as! [String: Any]
        for key in ["truncationTotalCount", "displayedCount", "undisplayedCount",
                    "droppedByCap", "undisplayedReports", "unexaminedDirectories",
                    "unmeasuredScope"] {
            json.removeValue(forKey: key)
        }
        let legacy = try JSONDecoder().decode(CoverageMetrics.self, from: JSONSerialization.data(withJSONObject: json))

        XCTAssertNil(legacy.droppedByCap, "删键之后必须真是 nil（不许被默认值补成 0）")
        XCTAssertNil(legacy.displayShapeFromFields, "缺格不许被还原成一本全 0 的账")
        let note = try XCTUnwrap(legacy.boardAccountingNote, "没统计过也要出声，沉默会被读成「没问题」")
        XCTAssertTrue(note.contains("未统计"), note)
        XCTAssertFalse(note.contains("没有报告因命中上限被丢弃"), "把「没统计」说成「查过、没事」：\(note)")
        XCTAssertFalse(note.contains("未合并"), "没这本账就不许报任何份数：\(note)")
    }

    /// 只缺一格坐标也不许还原成形状 —— 否则「没记坐标」会被读成「一份都没丢」。
    func testPartialLedgerIsNotReconstructedIntoAZeroLedger() async throws {
        for index in 0..<(cap + 3) { try writeModule(index) }
        let metrics = try await scanned()
        var json = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(metrics)) as! [String: Any]
        json.removeValue(forKey: "undisplayedReports")
        let broken = try JSONDecoder().decode(CoverageMetrics.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(broken.displayShapeFromFields)
        XCTAssertEqual(numberInSentence(broken.boardAccountingNote ?? ""), broken.droppedByCap,
                       "只剩部分格子时，那句里的数仍得与剩下的那枚字段一致")
    }

    // MARK: - 反例守卫 ①：句子被手写进视图 ⇒ 当场红（扫描型守卫，下面配元测试）

    /// 中文披露句只许住在 `Services/Coverage/CoverageDisplayShape.swift` 那一处。
    /// 视图里再拼一遍中文就是第二把尺子（工单硬线 2）。
    func testViewsNeverRewriteTheDisclosureSentence() throws {
        let views = try swiftFiles(under: "Sources/TcoderMonitor/Views")
        XCTAssertGreaterThan(views.count, 20, "扫不到 Views ⇒ 这条守卫在空跑（永真绿）")
        for file in views {
            let hits = Self.disclosureHits(in: try String(contentsOf: file, encoding: .utf8))
            XCTAssertTrue(hits.isEmpty, "\(file.lastPathComponent) 里手写了披露句：\(hits)")
        }
        // 同一把尺子必须**看得见**这些词，否则上一条是永真绿：拿真生产者量一次。
        let producers = try swiftFiles(under: "Sources/TcoderMonitor/Services/Coverage")
        let producerHits = producers.flatMap {
            Self.disclosureHits(in: (try? String(contentsOf: $0, encoding: .utf8)) ?? "")
        }
        XCTAssertGreaterThanOrEqual(producerHits.count, 3,
                                    "尺子在 Services/Coverage 都数不到那几句 ⇒ 判据本身失效")
    }

    /// 三句披露的**字面量**特征（不含标点，避免被别的句子误撞）。
    private static let disclosureMarkers = ["份未合并", "没有下潜", "扫描面不完整"]

    /// 剥掉整行注释再找（注释里**讲**这句话不算第二把尺子，代码里写出来才算）。
    static func disclosureHits(in text: String) -> [String] {
        var hits: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.drop(while: { $0 == " " || $0 == "\t" })
            if line.starts(with: "//") { continue }
            for marker in disclosureMarkers where line.contains(Substring(marker)) {
                hits.append(marker)
            }
        }
        return hits
    }

    /// 元测试（本仓规矩：扫描守卫不配元测试迟早永真绿）：
    /// 手写进代码的要抓到、只在注释里提的不算、干净文件不报。
    func testTheViewsRulerCatchesAnInjectedHandWrittenSentence() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("r13-views-ruler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try "enum Bad { static let s = \"另有 7 份未合并\" }\n".write(
            to: dir.appendingPathComponent("Bad.swift"), atomically: true, encoding: .utf8)
        try "// 这句只是解释什么叫「另有 7 份未合并」，不该被抓\nenum Clean { let x = 1 }\n".write(
            to: dir.appendingPathComponent("Clean.swift"), atomically: true, encoding: .utf8)

        let files = try FileManager.default.contentsOfDirectory(at: dir,
                                                               includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        XCTAssertEqual(files.count, 2, "两份夹具没都落到盘上，元测试自身失效")
        let hits = files.flatMap { Self.disclosureHits(in: (try? String(contentsOf: $0, encoding: .utf8)) ?? "") }
        XCTAssertEqual(hits, ["份未合并"], "写进代码的那份必须抓到、只写在注释里的那份不许算")
    }

    // MARK: - 反例守卫 ②：两个读者**行为上**必须带上那句（文本断言会被死代码骗过去）
    //
    // 这条是写着写着发现的：只断言"文件里含有 `boardAccountingNote` 字样"，
    // 那么把读者改成 `return caliber` 之后原来那行留在死代码里，守卫照样绿。
    // 所以这里直接**调**那两个纯函数（`DashboardCoverageHelp.text` 与 `CLIScoreText.render`），
    // 让"界面/CLI 上那句"和"字段里那本账"在同一次调用里对账。

    /// 超上限那棵树（43 份）：`boardAccountingNote` / ⓘ / CLI 三个出口都从这**同一次扫描**取数，
    /// 于是"界面上那句里的数 == 字段里的数"是同一趟读数的对账，而不是我抄三份常量。
    /// 独立真值：43 = 我写的份数，40 = 产品侧上限，3 = 两者之差；`reports.count` 只有 1，
    /// 所以"榜内长度"与"丢弃份数"在这里天然是两个数 —— 谁拿榜长冒充总数当场分叉。
    private func overCapMetrics() async throws -> CoverageMetrics {
        for index in 0..<(cap + 3) { try writeModule(index) }
        let metrics = try await scanned()
        XCTAssertEqual(metrics.droppedByCap, 3)
        XCTAssertEqual(metrics.truncationTotalCount, cap + 3)
        XCTAssertEqual(metrics.reports.count, 1)
        return metrics
    }

    func testGUIReadoutCarriesExactlyTheProducerSentence() async throws {
        let metrics = try await overCapMetrics()
        let note = try XCTUnwrap(metrics.boardAccountingNote)
        let readout = DashboardCoverageHelp.text(metrics)
        // ⓘ 的内容 = 口径句 + 装配口那句，逐字（多写一个字、或绕过装配口自己拼，都当场红）
        XCTAssertEqual(readout, DashboardView.coverageCaliberLine(metrics) + "\n" + note)
        // 界面上那句里的数 == 字段里的数（同一次扫描，两个来源）
        XCTAssertEqual(numberInSentence(readout), metrics.droppedByCap)
        XCTAssertEqual(numberInSentence(readout), 3, "夹具里我写的是 43 - 40 = 3 份")
        XCTAssertTrue(readout.contains("m9/coverage/lcov.info"), "坐标要点名：\(readout)")
        // 榜内长度（`reports.count == 1`）绝不许冒充"丢了几份"
        XCTAssertFalse(readout.contains("另有 1 份"), "数从榜内长度来的分叉：\(readout)")
    }

    func testGUIReadoutStaysByteIdenticalWhenNothingWasCut() async throws {
        for index in 0..<cap { try writeModule(index) }              // 正好 40 份
        let clean = try await scanned()
        XCTAssertNil(clean.boardAccountingNote)
        XCTAssertEqual(DashboardCoverageHelp.text(clean), DashboardView.coverageCaliberLine(clean),
                       "量过了、真的没切 ⇒ ⓘ 里一个字都不许多")
    }

    /// 同一棵树、两个方向：**先**扫干净的 40 份（那句必须不出现在 CLI 里），
    /// **再**往盘上补 3 份合法报告（下一次扫描必须出声）。
    /// （第一版把顺序写反了 —— 同一个夹具根里补写 40 份并不会把先前那 43 份抹掉，
    ///  门禁当场把它判红一条。这是本文件自己踩到的坑，留在这里当注释。）
    func testScoreTextAndGUIReadoutPrintTheSameAccount() async throws {
        var cleanReport = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/r13-clean"))
        for index in 0..<cap { try writeModule(index) }              // 正好到上限：一份都没丢
        cleanReport.coverage = try await scanned()
        XCTAssertNil(cleanReport.coverage?.boardAccountingNote)
        XCTAssertFalse(CLIScoreText.render(cleanReport, exit: .ok).contains("未合并"),
                       "没丢东西时 CLI 不许凭空多出这一行")

        for index in cap..<(cap + 3) { try writeModule(index) }      // 补三份合法报告
        let metrics = try await scanned()
        let note = try XCTUnwrap(metrics.boardAccountingNote)
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/r13-accounting"))
        report.coverage = metrics
        let scoreText = CLIScoreText.render(report, exit: .ok)
        XCTAssertTrue(scoreText.contains(note),
                      "CLI 没原样打装配口那句（另写一份、或干脆不打）：\n\(scoreText)")
        XCTAssertEqual(numberInSentence(scoreText), metrics.droppedByCap,
                       "CLI 上那句里的数与字段分叉")
        XCTAssertFalse(scoreText.contains("另有 1 份"), "CLI 那侧也不许拿榜内长度当丢弃份数")
        // 界面与 CLI 同一条尺子：两处那句逐字相同
        XCTAssertEqual(numberInSentence(DashboardCoverageHelp.text(metrics)),
                       numberInSentence(scoreText))
    }

    // MARK: - 反例守卫 ③：调用点还在（结构断言，作为行为断言的第二层网）

    func testBothReadoutsGoThroughTheOneProducer() throws {
        // GUI：页尾 ⓘ 的内容由 `DashboardCoverageHelp` 串，而它只许调既有生产者。
        let readouts = try source("Sources/TcoderMonitor/Views/Shell/DashboardReadouts.swift")
        XCTAssertTrue(readouts.contains("coverage.boardAccountingNote"),
                      "界面没再读那本账 ⇒ RD-50 原地复活")
        let shell = try source("Sources/TcoderMonitor/Views/DashboardView.swift")
        let section = try XCTUnwrap(shell.range(of: "GlassSection(\"测试覆盖率\")"),
                                    "覆盖率那一格不见了，下面那条接点断言就没意义")
        let hooked = try XCTUnwrap(shell.range(of: "CopyHelpBadge(DashboardCoverageHelp.text(coverage))"),
                                   "覆盖率那一格的 ⓘ 没接上装配口")
        let offset = shell.distance(from: section.lowerBound, to: hooked.lowerBound)
        XCTAssertGreaterThan(offset, 0, "ⓘ 接在覆盖率那一格之前了，等于接在别的格上")
        XCTAssertLessThan(offset, 2_000, "接得太远（离开那一格了）：那句必须挂在测试覆盖率那一格里")

        // CLI：同一枚调用，且**没**另写一份中文。
        let cli = try source("Sources/TcoderMonitor/Services/CLI/CLIScoreText.swift")
        XCTAssertTrue(cli.contains("coverage.boardAccountingNote"), "CLI 没读同一把尺子")
        XCTAssertTrue(Self.disclosureHits(in: cli).isEmpty,
                      "CLI 里手写了披露句 = 第二把尺子：\(Self.disclosureHits(in: cli))")
    }

    // MARK: - 小工具

    private func swiftFiles(under relative: String) throws -> [URL] {
        let base = Self.repoRoot.appendingPathComponent("TcoderMonitor/" + relative, isDirectory: true)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            XCTFail("扫不到 \(relative) —— 这条扫描守卫会在空跑")
            return []
        }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent("TcoderMonitor/" + relative),
                   encoding: .utf8)
    }
}
