import XCTest
@testable import TcoderMonitor

/// RD-60 交回件第 ① 条：**同期**对表。
///
/// 两边喂的是**同一个总体**、同一个崩溃夹具，而且都在这一趟里跑：
///   · GUI 侧 = 与 `AppState.scan(project:)` 同一组分析器入口 + `ProjectStore` 那套编码器落盘
///     （`producedBy: "gui"`）。**不是**真起窗口拍到的 GUI 落盘 —— 本仓同一时刻只允许一个人起 App，
///     而本轮需求方已叫停一切点击/滚动类取证，所以走的是 `CoverageChainProofTests` 那一条既有形状；
///   · CLI 侧 = 交付二进制真子进程 `scan --out`。
/// 然后真跑仓库里那把尺子 `scripts/report_parity.py`（AGENTS §5.9 第 5 条），
/// 并把 `logs.crashEvidence` 九格逐格比一次 —— 这一格是 RD-60 新落的读数，
/// 它对不上的话"三个出口同一句真话"就当场不成立。
///
/// 崩溃报告目录经 `TCODER_LIBRARY_LOGS_DIR` 指到夹具里的目录，夹具落在仓库内 `.scratch/`，
/// 夹具根自带 `.git`（不建就会向上找到宿主仓库、继承宿主身份）。
final class CrashEvidenceParityTests: XCTestCase {

    private var scratch: URL!
    private var target: URL!

    override func setUpWithError() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        scratch = packageRoot.deletingLastPathComponent()
            .appendingPathComponent(".scratch/r24-parity-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(scratch.path.contains("/.scratch/"), "夹具不在仓库内 .scratch：\(scratch.path)")
        target = scratch.appendingPathComponent("ShopApp", isDirectory: true)
        // 崩溃报告目录指到夹具里一个**空**目录：真 `~/Library/Logs/DiagnosticReports` 一个字都不读。
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("fake-library-logs"
                                             + "/DiagnosticReports"), withIntermediateDirectories: true)
        try CrashEvidenceFixture.install(into: target)
        setenv("TCODER_LIBRARY_LOGS_DIR", scratch.appendingPathComponent("fake-library-logs").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: scratch)
    }

    @MainActor
    func test_guiAndCliReportTheSameCrashEvidence() async throws {
        let cliJSON = try scanWithDeliveredBinary()
        let guiJSON = try await persistGuiSideReport()

        let guiSlots = try XCTUnwrap(Self.section(guiJSON, "logs")["crashEvidence"] as? [String: Any],
                                    "GUI 侧没落出九格 ⇒ 写者只在协议那一路之外生效")
        let cliSlots = try XCTUnwrap(Self.section(cliJSON, "logs")["crashEvidence"] as? [String: Any],
                                     "CLI 侧没落出九格 ⇒ 两条路的写者不同源")
        let guiNumbers = Self.intSlots(guiSlots)
        let cliNumbers = Self.intSlots(cliSlots)
        XCTAssertEqual(guiNumbers.count, 9, "九格就该有九格：\(guiSlots.keys.sorted())")
        XCTAssertEqual(guiNumbers, cliNumbers, "同一本细账落出两份不同的数 ⇒ 两条路各有尺子")
        // 两边还必须都**量对**：只比"两边一样"不够，一起错就悄悄过了。
        let planned = CrashEvidenceFixture.plannedSlots
        for (tag, numbers) in [("GUI", guiNumbers), ("CLI", cliNumbers)] {
            XCTAssertEqual(numbers, planned, "\(tag) 侧九格与夹具计划真值不符")
            let logs = try Self.section(tag == "GUI" ? guiJSON : cliJSON, "logs")
            XCTAssertEqual(logs["crashCount"] as? Int, planned["countedCrashCount"],
                           "\(tag) 侧 crashCount 与 countedCrashCount 不同刻同源")
        }
        print("【RD-60 九格对表】GUI=\(guiNumbers) CLI=\(cliNumbers)")

        try runReportParity(gui: guiJSON, cli: cliJSON)
    }

    // MARK: - 两侧

    /// CLI 侧：真子进程跑**交付二进制**（`CLIProcessTests.productBinary()` 那把不静默跳过的尺子）。
    private func scanWithDeliveredBinary() throws -> URL {
        let out = scratch.appendingPathComponent("cli.json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = ["scan", target.path, "--out=" + out.path]
        var environment = ProcessInfo.processInfo.environment
        environment["TCODER_LIBRARY_LOGS_DIR"] = scratch.appendingPathComponent("fake-library-logs").path
        process.environment = environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "无头扫描没跑成（退出码 \(process.terminationStatus)）")
        return out
    }

    /// GUI 侧：五路走**同一个装配助手** `AnalyzerLedger.timed`，`ProjectStore` 那套编码器
    /// 落进沙箱支持目录。⚠️ 这份测试副本重演的是 GUI 装配而不是调用它（不许起 App）——
    /// 所以它与 `CoverageChainProofTests.persistGuiSideReport` 同形：**同一条装配助手**，
    /// 否则 `analyzerLedger` / `failedSections` 两格会凭空多出来一处不等（那是尺子不齐，不是读数不齐）。
    @MainActor
    private func persistGuiSideReport() async throws -> URL {
        let sandbox = scratch.appendingPathComponent("support", isDirectory: true)
        // `save` 里是 `try?`：目录没建就会**静默不写文件**。
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("reports"),
                                                withIntermediateDirectories: true)
        let store = ProjectStore()
        store.storageDirectory = sandbox
        let project = store.add(path: target.path, name: "R24 对表夹具")
        var report = ProjectReport(project: project)
        let labels = AnalyzerLedger.sectionLabels
        let code = await AnalyzerLedger.timed(labels[0]) {
            try await FileSystemCodeAnalyzer().analyze(root: target, options: .default)
        }
        let git = await AnalyzerLedger.timed(labels[1]) {
            try await ShellGitAnalyzer().analyze(repositoryURL: target)
        }
        let logs = await AnalyzerLedger.timed(labels[2]) {
            try await FileLogAnalyzer().analyze(projectRoot: target, extraLogURLs: [], withinDays: 7)
        }
        let deps = await AnalyzerLedger.timed(labels[3]) {
            try await ManifestDependencyAnalyzer().analyze(projectRoot: target, allowNetwork: false)
        }
        let coverage = await AnalyzerLedger.timed(labels[4]) {
            try await CoverageAnalyzer().analyze(projectRoot: target, options: .default)
        }
        var attempts = [code.attempt, git.attempt, logs.attempt, deps.attempt, coverage.attempt]
        attempts[0].limitsHit = code.value?.scanLimitations ?? []
        report.code = code.value
        report.git = git.value
        report.logs = logs.value
        report.dependencies = deps.value
        report.coverage = coverage.value
        report.health = WeightedHealthScorer().score(HealthInputs(code: report.code, git: report.git,
                                                                  logs: report.logs,
                                                                  dependencies: report.dependencies,
                                                                  coverage: report.coverage,
                                                                  previousScore: nil))
        report.generatedAt = Date()
        report.attemptedAt = Date()
        report.failedSections = attempts.compactMap { $0.failureReason == nil ? nil : $0.label }
        report.analyzerLedger = AnalyzerLedger.records(from: attempts)
        report.provenance = ScanProvenance(report: report, scannedRoot: target.path, producedBy: "gui")
        store.save(report: report)
        return try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: sandbox.appendingPathComponent("reports"),
                                                    includingPropertiesForKeys: nil).first,
            "GUI 侧没落出报告文件（目录没建就会静默不写）")
    }

    // MARK: - 尺子

    private func runReportParity(gui: URL, cli: URL) throws {
        let script = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/report_parity.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: script.path), "对表脚本不在 \(script.path)")
        let parity = Process()
        parity.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parity.arguments = [script.path, gui.path, cli.path, target.path]
        let pipe = Pipe()
        parity.standardOutput = pipe
        parity.standardError = pipe
        try parity.run()
        parity.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("【report_parity.py rc=\(parity.terminationStatus)】\n" + output)
        XCTAssertEqual(parity.terminationStatus, 0,
                       "GUI ↔ CLI 逐字段有不可容忍的不等：\n" + output)
    }

    private static func section(_ url: URL, _ name: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(object?[name] as? [String: Any], "\(name) 段不在报告里")
    }

    /// 落盘 JSON 的九格收成 `[String: Int]`（`Any` 不能直接比：`XCTAssertEqual` 要 Equatable）。
    private static func intSlots(_ slots: [String: Any]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: slots.compactMap { key, value in
            (value as? Int).map { (key, $0) }
        })
    }
}
