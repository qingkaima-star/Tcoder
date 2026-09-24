import XCTest
@testable import TcoderMonitor

/// RD-31「扫描期间源码变化」的机制测试（R29）。
///
/// 立案依据（台账卷二 §16 那行判据原文）：要在收尾时比一次「开工时的指纹 vs 收工时的指纹」，
/// 不一致就标注「本报告不是同一源码快照的一致结果」，**不许包装成精确结论**。
///
/// 三态各自都要有一条真夹具用例（正例 / 反例 / 未知态），加上"这句话有没有被包装成精确结论"
/// 的反向钉。判据全部喂**临时目录里的自建树**，不依赖本仓此刻脏不脏 ——
/// 债还上了它不会红，机制坏了它一定红（与 `ScanProvenanceTests` 同一条立法的理由）。
final class ScanSourceDriftTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        // 夹具只住 NSTemporaryDirectory() 下唯一的 UUID 目录：
        // /tmp 里别人留下的树喂过假绿，仓库内的沙箱喂过假红（AGENTS §1.6）。
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-rd31-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try write("A.swift", "let a = 1\n", to: root)
        try write("B.swift", "let b = 2\n", to: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sub"),
                                                withIntermediateDirectories: true)
        try write("C.swift", "let c = 3\n", to: root.appendingPathComponent("sub"))
    }

    override func tearDown() {
        // 未知态那两例会 chmod 000：权限不归还就会留一个"别人也读不动"的残迹，
        // 目录不删干净就会留下喂假绿的树。
        if let root {
            chmod(path: root.path, to: 0o755)
            chmod(path: root.appendingPathComponent("sub").path, to: 0o755)
            chmod(path: root.appendingPathComponent("secret").path, to: 0o755)
            chmod(path: root.appendingPathComponent("locked.swift").path, to: 0o644)
            try? FileManager.default.removeItem(at: root)
        }
        root = nil
    }

    // MARK: - 正例 / 反例：两枚指纹比的是什么

    /// 正向：扫到一半往盘上改一个文件 ⇒ 必须判 `true`。
    func testModificationDuringScanIsReportedAsDrift() throws {
        let start = SourceTreeFingerprint.probe(root: root)
        try write("A.swift", "let a = 1\nlet injected = true\n", to: root)   // 改写
        let end = SourceTreeFingerprint.probe(root: root)
        var p = ScanProvenance()
        p.recordDrift(startingFrom: start, endingAt: end)
        XCTAssertEqual(p.sourceDriftDuringScan, true, "盘上真的多了一行，漂移必须判 true")
        XCTAssertNotNil(p.driftNote, "判了 true 就要说清变了哪一量")
        XCTAssertTrue(p.driftReading.contains("不是同一源码快照的一致结果"), p.driftReading)
    }

    /// 正向的另一半：**新增**文件也要抓到（只测改写的话，"条数"那一维坏了没人知道）。
    func testFileAddedDuringScanIsReportedAsDrift() throws {
        let start = SourceTreeFingerprint.probe(root: root)
        try write("D.swift", "let d = 4\n", to: root)
        var p = ScanProvenance()
        p.recordDrift(startingFrom: start, endingAt: SourceTreeFingerprint.probe(root: root))
        XCTAssertEqual(p.sourceDriftDuringScan, true)
        XCTAssertTrue(p.driftNote?.contains("条数 3 → 4") == true, p.driftNote ?? "无摘要")
    }

    /// 反向：同一棵树不改 ⇒ 必须判 `false`，而且**不留一句假摘要**。
    func testUntouchedTreeIsReportedAsConsistent() throws {
        let start = SourceTreeFingerprint.probe(root: root)
        var p = ScanProvenance()
        p.recordDrift(startingFrom: start, endingAt: SourceTreeFingerprint.probe(root: root))
        XCTAssertEqual(p.sourceDriftDuringScan, false, "什么都没动却判未量到 = 把能力缺口报成测量")
        XCTAssertNil(p.driftNote, "量到了就不该留原因（与 dirtyProbeNote 同规矩）")
    }

    /// 第三态（根读不动）：必须 `nil` **且** `driftNote` 非空。
    func testUnreadableRootIsNotMeasuredWithAReason() throws {
        let start = SourceTreeFingerprint.probe(root: root)
        chmod(path: root.path, to: 0o000)
        let end = SourceTreeFingerprint.probe(root: root)
        chmod(path: root.path, to: 0o755)
        var p = ScanProvenance()
        p.recordDrift(startingFrom: start, endingAt: end)
        XCTAssertNil(p.sourceDriftDuringScan, "收工侧没量到 ⇒ 整枚判未量到，不许退回猜「一致」")
        XCTAssertFalse(p.driftNote?.isEmpty == true, "缺证据必须自带原因")
        XCTAssertTrue(p.driftReading.contains("未量到"), p.driftReading)
        XCTAssertTrue(p.driftReading.contains("收工侧"), p.driftReading)
    }

    /// 第三态的第二条来路：树里有目录读不动 ⇒ 指纹**不完整**，不完整性不许冒充"看完了"。
    func testIncompleteWalkIsNotMeasured() throws {
        let start = SourceTreeFingerprint.probe(root: root)
        let blocked = root.appendingPathComponent("secret")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        try write("inside.swift", "let x = 1\n", to: blocked)
        chmod(path: blocked.path, to: 0o000)
        let end = SourceTreeFingerprint.probe(root: root)
        chmod(path: blocked.path, to: 0o755)
        var p = ScanProvenance()
        p.recordDrift(startingFrom: start, endingAt: end)
        guard case .notMeasured = end else {
            return XCTFail("枚举器报出错时不许照样交出一枚看起来完整的指纹：\(end)")
        }
        XCTAssertNil(p.sourceDriftDuringScan)
        XCTAssertFalse(p.driftNote?.isEmpty == true)
    }

    /// 指纹**只问元数据**：树里躺着一个内容读不动的文件，指纹照样量得出来（它一次都不读内容）。
    /// 反向钉住"把 O(扫描) 变成 2× 读盘"那种实现 —— 那种写法在这里会直接量不到。
    func testFingerprintNeedsNoContentRead() throws {
        let unreadable = root.appendingPathComponent("locked.swift")
        try write("locked.swift", "let secret = 1\n", to: root)
        chmod(path: unreadable.path, to: 0o000)
        guard case .measured(let fingerprint) = SourceTreeFingerprint.probe(root: root) else {
            return XCTFail("只是元数据指纹，为什么要读文件内容？")
        }
        XCTAssertEqual(fingerprint.fileCount, 4, "A/B/C + 这个读不动内容的 locked.swift")
        XCTAssertFalse(fingerprint.pathDigest.isEmpty)
    }

    // MARK: - 顺序不许参与判定（RD-39 家族病）

    /// 枚举器交条目的顺序未定义 ⇒ 摘要只能由**升序路径**算出来。
    func testDigestIgnoresEnumerationOrder() {
        let forward = SourceTreeFingerprint(paths: ["a.swift", "sub/c.swift", "b.swift"], totalBytes: 9)
        let backward = SourceTreeFingerprint(paths: ["sub/c.swift", "b.swift", "a.swift"], totalBytes: 9)
        XCTAssertEqual(forward, backward, "枚举顺序混进判定后，同一棵树两次采样会自相矛盾")
        let renamed = SourceTreeFingerprint(paths: ["a.swift", "sub/x.swift", "b.swift"], totalBytes: 9)
        XCTAssertNotEqual(forward, renamed, "路径集合变了却说得出同一枚摘要 = 摘要根本没在判路径")
    }

    /// 盲区必须说在嘴上：等长改写测不出来，所以 `false` 那句**不许**长成"源码没变"。
    func testConsistentWordingNeverClaimsSourceUnchanged() throws {
        let start = SourceTreeFingerprint.probe(root: root)
        try write("A.swift", "let a = 9\n", to: root)           // 与原来等长，测不出
        var p = ScanProvenance()
        p.recordDrift(startingFrom: start, endingAt: SourceTreeFingerprint.probe(root: root))
        XCTAssertEqual(p.sourceDriftDuringScan, false, "等长改写是这把尺子的已知盲区，不许藏")
        for forbidden in ["没变", "未变化", "没有变化", "干净"] {
            XCTAssertFalse(p.driftReading.contains(forbidden), "措辞越界了：\(p.driftReading)")
        }
    }

    // MARK: - 三个出口同一句真话

    func testCLITextCarriesEveryDriftState() throws {
        for (drift, note, expect) in [
            (Bool?.some(true), "条数 3 → 4", "扫描期间源码有变化"),
            (Bool?.some(false), nil, "两枚源码指纹一致"),
            (Bool?.none, "根目录读不动", "未量到（根目录读不动）"),
        ] {
            var p = ScanProvenance()
            p.sourceDriftDuringScan = drift
            p.driftNote = note
            XCTAssertTrue(p.oneLineSummary.contains(expect), "\(String(describing: drift)) → \(p.oneLineSummary)")
            let report = makeReport(provenance: p)
            XCTAssertTrue(CLIScoreText.render(report, exit: .ok).contains(p.driftReading),
                          "CLI 文本与 `driftReading` 不同话，就是第二个装配口")
        }
    }

    /// `nil` 绝不能被省略成"看起来没问题"：连原因都没有时也要打出「未量到（原因未记录）」。
    func testMissingDriftStillSpeaksInTheOneLiner() {
        let text = ScanProvenance().oneLineSummary
        XCTAssertTrue(text.contains("未量到（原因未记录）"), text)
    }

    func testDriftKeysLandInTheJSONAndDisappearWhenUnmeasured() throws {
        var measured = ScanProvenance()
        measured.sourceDriftDuringScan = true
        measured.driftNote = "条数 3 → 4"
        let present = try provenanceJSON(makeReport(provenance: measured))
        XCTAssertEqual(present["sourceDriftDuringScan"] as? Bool, true)
        XCTAssertEqual(present["driftNote"] as? String, "条数 3 → 4")

        let absent = try provenanceJSON(makeReport(provenance: ScanProvenance()))
        XCTAssertFalse(absent.keys.contains("sourceDriftDuringScan"),
                       "缺数据要靠**整键缺席**表达，不是写一个 null 更不是补 false")
        XCTAssertFalse(absent.keys.contains("driftNote"))
    }

    func testReportWithoutDriftKeysStillDecodes() throws {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: root.path))
        var provenance = ScanProvenance()
        provenance.sourceCommit = "cafe123"
        provenance.sourceDriftDuringScan = false
        provenance.driftNote = "条数 3 → 4"
        report.provenance = provenance
        var json = try jsonObject(report)
        var block = try XCTUnwrap(json["provenance"] as? [String: Any])
        block.removeValue(forKey: "sourceDriftDuringScan")
        block.removeValue(forKey: "driftNote")
        json["provenance"] = block
        let data = try JSONSerialization.data(withJSONObject: json)
        let restored = try JSONDecoder().decode(ProjectReport.self, from: data)
        XCTAssertNil(try XCTUnwrap(restored.provenance).sourceDriftDuringScan, "旧 JSON 缺键 ⇒ nil")
        XCTAssertNil(restored.provenance?.driftNote)
        XCTAssertEqual(restored.provenance?.sourceCommit, "cafe123", "其余字段不许被带坏")
    }

    /// GUI 那一头必须读**同一句**：读者点名 + 不许在页面里再比一次三态。
    func testGUIReadsTheSameSentenceFromTheContract() throws {
        let health = try codeOnly(in: sourceFile("Views/Health/HealthView.swift"))
        XCTAssertTrue(health.contains("provenance?.driftNotice"),
                      "健康页不再读 driftNotice ⇒ 这一格只有 CLI 会说话")
        XCTAssertTrue(health.contains("BannerRow(text: drift.reading"),
                      "横幅必须直接打契约装配好的那一句，不许在页面里重拼一遍")
        XCTAssertFalse(health.contains("sourceDriftDuringScan"),
                       "页面自己比三态 = 同一个事实的第二把尺子")
        var measured = ScanProvenance()
        measured.sourceDriftDuringScan = true
        XCTAssertEqual(measured.driftNotice?.reading, measured.driftReading)
        XCTAssertTrue(measured.driftNotice?.isWarning == true)
        var unmeasured = ScanProvenance()
        unmeasured.driftNote = "根目录读不动"
        XCTAssertEqual(unmeasured.driftNotice?.isWarning, false, "没量到不是缺陷，别涂警告色")
        var consistent = ScanProvenance()
        consistent.sourceDriftDuringScan = false
        XCTAssertNil(consistent.driftNotice, "没问题要说的时候就不许凑一行废话")
    }

    /// 元测试：上面那条"页面不许自己比三态"的判据必须剥注释，否则注释里交代
    /// 为什么不这么写的那一句会把它自己判红（本仓为这件事红过不止一次）。
    func test_meta_commentStrippingKeepsTheRulerOnCode() throws {
        let commented = "// 不在这里比 sourceDriftDuringScan\n  BannerRow(text: drift.reading)\n"
        XCTAssertTrue(Self.dropCommentLines(from: commented).contains("BannerRow(text: drift.reading)"))
        XCTAssertFalse(Self.dropCommentLines(from: "/// 提到 sourceDriftDuringScan 只是解释\n")
            .contains("sourceDriftDuringScan"), "注释被当成了代码")
    }

    // MARK: - 装配点：两个写者都要采两次、比一次

    func testBothAssemblyPointsRecordDrift() throws {
        let cli = (path: "Sources/TcoderMonitor/Services/CLI/CLIScan.swift",
                   content: try sourceFile("Services/CLI/CLIScan.swift"))
        let gui = (path: "Sources/TcoderMonitor/App/AppState.swift",
                   content: try sourceFile("App/AppState.swift"))
        let writers = Self.assemblyFiles(in: [cli, gui])
        XCTAssertEqual(writers, ["Sources/TcoderMonitor/App/AppState.swift",
                                 "Sources/TcoderMonitor/Services/CLI/CLIScan.swift"],
                       "装配溯源块却没记漂移 ⇒ 这条路产出的报告永远读成「未量到」")
    }

    /// 元测试：上面那条扫描判据必须真咬得住坏样例，也不误伤正确写法。
    func test_meta_assemblyRulerBitesBothWays() {
        let silent = [(path: "Sources/X.swift",
                       content: "report.provenance = ScanProvenance(report: r, scannedRoot: p, producedBy: \"cli\")")]
        XCTAssertEqual(Self.assemblyFiles(in: silent), [], "只写溯源不记漂移的写法没被抓到")
        let wired = [(path: "Sources/Y.swift",
                      content: "var provenance = ScanProvenance(report: r, scannedRoot: p, producedBy: \"cli\")\n"
                             + "provenance.recordDrift(startingFrom: s, endingAt: e)")]
        XCTAssertEqual(Self.assemblyFiles(in: wired), ["Sources/Y.swift"], "正确写法判不出来")
    }
    // MARK: - 耗时读数（报告器，不设阈值：拿计时当闸门就是把机器负载报成缺陷）

    /// 在**本仓这棵树**上量第二次枚举要多久（AGENTS §1.6：只用本仓库自己的目录树）。
    func test_secondWalkPrintsItsCostOnThisRepository() throws {
        let tree = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()      // .../Tcoder（仓库根）
        guard case .measured(let first) = SourceTreeFingerprint.probe(root: tree) else {
            return XCTFail("本仓根目录读不动 ⇒ 这条读数没有意义：\(tree.path)")
        }
        let began = Date()
        let again = SourceTreeFingerprint.probe(root: tree)
        let ms = Int(Date().timeIntervalSince(began) * 1000)
        guard case .measured(let second) = again else {
            return XCTFail("同一棵树第二次采样却量不到 ⇒ 并发构建期间踩到了读不动的目录")
        }
        print("【RD-31 第二次枚举】树 \(tree.path) · 文件 \(first.fileCount) 条 · 字节 \(first.totalBytes)"
            + " · 第二枚指纹耗时 \(ms) ms · 两枚一致 = \(first == second)")
        // 大树一档：`/opt/homebrew` 是 AGENTS §-1 点名的公共开源语料，只读、量完不删。
        // 这条**只出读数不设阈值**：拿计时当闸门就是把机器负载报成缺陷（`PerfMainThreadBudgetTests` 同判）。
        let brew = URL(fileURLWithPath: "/opt/homebrew", isDirectory: true)
        let brewBegan = Date()
        switch SourceTreeFingerprint.probe(root: brew) {
        case .measured(let big):
            print("【RD-31 大树读数】/opt/homebrew · 文件 \(big.fileCount) 条 · 字节 \(big.totalBytes)"
                + " · 单枚指纹耗时 \(Int(Date().timeIntervalSince(brewBegan) * 1000)) ms")
        case .notMeasured(let reason):
            print("【RD-31 大树读数】/opt/homebrew 判未量到：\(reason)")
        }
    }

    // MARK: - 夹具与工具

    private static func assemblyFiles(in files: [(path: String, content: String)]) -> [String] {
        files.filter { $0.content.contains("ScanProvenance(report:") && $0.content.contains("recordDrift") }
            .map(\.path).sorted()
    }

    /// 判据只看代码：注释里"交代为什么不这么写"的那一句不得把自己判红。
    static func dropCommentLines(from text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func codeOnly(in text: String) -> String { Self.dropCommentLines(from: text) }

    private func makeReport(provenance: ScanProvenance) -> ProjectReport {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: root.path))
        report.provenance = provenance
        return report
    }

    private func jsonObject(_ report: ProjectReport) throws -> [String: Any] {
        let data = try JSONEncoder().encode(report)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func provenanceJSON(_ report: ProjectReport) throws -> [String: Any] {
        try XCTUnwrap(jsonObject(report)["provenance"] as? [String: Any])
    }

    private func sourceFile(_ relative: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor/" + relative)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private func write(_ name: String, _ text: String, to directory: URL) throws {
        try text.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// 归还/收走权限。抛错就地吞掉：`tearDown` 里一次失败不该把整棵夹具留在盘上，
    /// 后面那几次 chmod + removeItem 必须继续跑完。
    private func chmod(path: String, to mode: Int) {
        try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }
}
