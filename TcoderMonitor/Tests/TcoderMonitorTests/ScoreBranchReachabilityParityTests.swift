import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R37 评分支路可达性（分支 `ws/rd27-reach`）—— 工单交付 ④「三出口对表」+ 元测试。
///
/// 同一份**真夹具**，三个出口各说一句话，这里逐字对一遍：
///   1. CLI 的 `score` 文本（**交付二进制的真子进程**，`CLIProcessTests.productBinary()` 那把
///      不静默跳过的尺子）；
///   2. 落盘 JSON（CLI `scan --out`，与 GUI 同一套 coder 配置）；
///   3. 界面那一格的装配口 —— GUI 侧一律走 `GuiSideReportReplay` **唯一入口**（RD-31×RD-60
///      的教训就是「测试里两份 GUI 装配副本」），再把落盘报告解回来读
///      `MissingDimensionReason.text` 与 `HealthBreakdown.rows`，也就是
///      `Views/Health/HealthComponentTable.swift` 读的那两格。**本文件不抄任何 GUI 装配**。
///
/// 另附三条元测试：夹具与盘上真值的对账闸门必须**有牙**（喂假输入就判败、
/// 孤儿夹具与宿主仓库树都要拒）。
final class ScoreBranchReachabilityParityTests: XCTestCase {

    private var sandbox: URL!
    private var libraryLogs: URL!
    private var originalLogsDirectory: String?

    override func setUpWithError() throws {
        originalLogsDirectory = ProcessInfo.processInfo.environment["TCODER_LIBRARY_LOGS_DIR"]
        sandbox = try R37ReachFixture.makeSandbox()
        libraryLogs = sandbox.appendingPathComponent("fake-library-logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true),
            withIntermediateDirectories: true)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
    }

    override func tearDownWithError() throws {
        if let original = originalLogsDirectory { setenv("TCODER_LIBRARY_LOGS_DIR", original, 1) }
        else { unsetenv("TCODER_LIBRARY_LOGS_DIR") }
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - 形状①：三出口同一句真话（崩溃报告有、真日志行零）

    @MainActor
    func test_crashOnlyShapeSaysTheSameWordsOnAllThreeOutputs() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37ParityCrashApp", under: sandbox)
        try R37ReachFixture.makeRepository(at: root, count: 9)
        _ = try R37ReachFixture.writeCrashReport(in: root, product: "R37ParityCrashApp", lines: 400)

        let scoreText = try runDeliveredBinary(["score", root.path, "--window-days=7"])
        let cliJSON = try runDeliveredBinaryWrite(["scan", root.path, "--compact"])
        let guiJSON = try await GuiSideReportReplay.persist(projectDirectory: root,
                                                            sandbox: sandbox.appendingPathComponent("support"),
                                                            projectName: "R37 对表夹具")
        let gui = try decode(guiJSON)
        let cli = try decode(cliJSON)

        // 出口 3：界面那一格（`HealthComponentTable` 读的就是这一枚函数）。
        let screenCell = MissingDimensionReason.text(for: .stability, report: gui)
        XCTAssertEqual(screenCell, StabilityZeroDenominatorShape.absenceReason(logs: try XCTUnwrap(gui.logs)),
                       "屏上那一格与判据本体分叉 ⇒ 有人另抄了一份缺席原因")
        XCTAssertTrue(screenCell.contains("错误密度没有分母"), screenCell)
        // 出口 1：CLI 文本里必须是**同一句**，不是又拼了一遍。
        XCTAssertTrue(scoreText.contains(screenCell),
                      "CLI 那句与屏上那句不同源：\n\(scoreText)")
        XCTAssertTrue(scoreText.contains("运行稳定性 —"), "缺席维度要点名维度名：\(scoreText)")
        // 出口 2：落盘 JSON 两边逐字段对表（AGENTS §5.9 第 5 条那把尺子）。
        try runReportParity(gui: guiJSON, cli: cliJSON, target: root)
        let recommendation = try XCTUnwrap((cli.health?.recommendations ?? [])
            .first { $0.contains("错误密度算不出分母") }, "CLI 落盘 JSON 没这句话：\(cli.health?.recommendations ?? [])")
        XCTAssertEqual(recommendation, "读到 1 次确认崩溃（1 份崩溃报告），但零真日志行 ⇒ 错误密度算不出分母，"
                       + "本维度不参与本次评分；崩溃明细见「错误日志」页。")
        XCTAssertEqual(gui.health?.recommendations, cli.health?.recommendations,
                       "两条装配路对同一份夹具给出不同建议")
        XCTAssertFalse(scoreText.contains("没有可扫描的日志"), "CLI 侧也不许再说那句假话")
        print("【R37 三出口·形状①】屏上=\(screenCell)")
    }

    // MARK: - 形状②：降档那句在三个出口上是同一枚分量

    @MainActor
    func test_thinEvidenceShapeSharesOneComponentAcrossTheThreeOutputs() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37ParityThinApp", under: sandbox)
        try R37ReachFixture.makeRepository(at: root, count: 9)
        _ = try R37ReachFixture.writeLog(under: root, lines: 3, every: 0)

        let scoreText = try runDeliveredBinary(["score", root.path, "--window-days=7"])
        let cliJSON = try runDeliveredBinaryWrite(["scan", root.path, "--compact"])
        let guiJSON = try await GuiSideReportReplay.persist(projectDirectory: root,
                                                            sandbox: sandbox.appendingPathComponent("support"),
                                                            projectName: "R37 薄证据对表")
        let gui = try decode(guiJSON)
        let cli = try decode(cliJSON)

        guard let guiRow = HealthBreakdown.rows(for: try XCTUnwrap(gui.health))
            .first(where: { $0.component.name == HealthDimension.stability.rawValue }) else {
            return XCTFail("薄证据这一维必须进分量表（它不是缺席，是封顶）")
        }
        let cliComponent = try XCTUnwrap(cli.health?.components
            .first { $0.name == HealthDimension.stability.rawValue })
        XCTAssertEqual(guiRow.score, cliComponent.score, "同一份夹具，两路给出两个分")
        XCTAssertEqual(guiRow.component.detail, cliComponent.detail, "依据句也必须是同一句")
        XCTAssertTrue(scoreText.contains(guiRow.component.detail),
                      "CLI 文本要带上屏那行依据：\(scoreText)")
        XCTAssertEqual(guiRow.score, Int(StabilityEvidence.thinEvidenceScoreCeiling))
        XCTAssertTrue(scoreText.contains("证据太薄·未判定"), scoreText)
        XCTAssertFalse(HealthBreakdown.missingDimensions(of: try XCTUnwrap(gui.health))
            .contains(.stability), "封顶 ≠ 缺席：这一维要真的参加了加权")
        print("【R37 三出口·形状②】分=\(guiRow.score) 依据=\(guiRow.component.detail)")
    }

    // MARK: - 元测试：对账闸门必须有牙

    /// 喂一份「根本没读夹具」的假读数，盘上真值闸门必须报出来（否则前面的正例是永真绿）。
    func test_meta_diskTruthGuardBitesOnAFabricatedReading() throws {
        let url = sandbox.appendingPathComponent("app.log")
        try R11DenominatorFixture.logText(lines: 3, every: 0).write(to: url, atomically: true, encoding: .utf8)
        let onDisk = [(url: url, lines: 3)]
        let fake = LogSummary(scannedFiles: [], totalLinesScanned: 9_999)
        let problems = R37ReachFixture.discrepancies(logs: fake, onDisk: onDisk)
        XCTAssertFalse(problems.isEmpty, "假输入没被抓出来 ⇒ 这条对账闸门是摆设：\(problems)")
        XCTAssertTrue(problems.contains { $0.contains("没读到") }, "要说清是哪一档：\(problems)")

        let lying = LogSummary(scannedFiles: [ScannedLogFile(path: url.path, sizeBytes: 120, lineCount: 900,
                                                            modifiedAt: Date(), role: .application)],
                               totalLinesScanned: 900)
        let mismatch = R37ReachFixture.discrepancies(logs: lying, onDisk: onDisk)
        XCTAssertTrue(mismatch.contains { $0.contains("盘上 3 行") }, "行数分叉也要报：\(mismatch)")

        let honest = LogSummary(scannedFiles: [ScannedLogFile(path: url.path, sizeBytes: 120, lineCount: 3,
                                                             modifiedAt: Date(), role: .application)],
                                totalLinesScanned: 3)
        XCTAssertTrue(R37ReachFixture.discrepancies(logs: honest, onDisk: onDisk).isEmpty, "正例必须为空")
    }

    /// 在形状①的夹具里**多埋一份 2,500 行日志** ⇒ 那一格就不成立了。
    /// 这条钉的是「结论来自夹具形状」而不是「分析器反正会读到空」。
    func test_meta_plantedDecoyFlipsTheZeroDenominatorShape() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37DecoyApp", under: sandbox)
        _ = try R37ReachFixture.writeCrashReport(in: root, product: "R37DecoyApp", lines: 400)
        let clean = await CLIScan().outcome(path: root.path, allowNetwork: false)
        let cleanLogs = try XCTUnwrap(clean.report?.logs)
        XCTAssertEqual(cleanLogs.totalLinesScanned, 0, "前提：没有埋料时分母真的是 0")
        XCTAssertEqual(StabilityZeroDenominatorShape.assess(cleanLogs),
                       .crashesWithoutLogLines(confirmedCrashes: 1, readableReports: 1))

        _ = try R37ReachFixture.writeLog(under: root, lines: 2_500, every: 0)
        let dirty = await CLIScan().outcome(path: root.path, allowNetwork: false)
        let polluted = try XCTUnwrap(dirty.report)
        let dirtyLogs = try XCTUnwrap(polluted.logs)
        XCTAssertEqual(dirtyLogs.totalLinesScanned, 2_500, "埋了料就必须不再是零分母")
        XCTAssertNil(recommendation(polluted, containing: "错误密度算不出分母"),
                     "形状①的句子不许在有了真日志行之后还说出口")
    }

    /// 夹具卫生两条：沙箱必须每趟唯一（拒孤儿夹具）、祖先链上有仓库时必须报得出来。
    func test_meta_sandboxIsUniqueAndSeesAHostRepository() throws {
        let first = try R37ReachFixture.makeSandbox()
        let second = try R37ReachFixture.makeSandbox()
        XCTAssertNotEqual(first.path, second.path, "两趟拿到同一个夹具根 ⇒ 会读到别人的遗留物")
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)

        let insideRepo = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertNotNil(R37ReachFixture.firstGitAncestor(of: insideRepo),
                       "认不出宿主仓库 ⇒「不是仓库」那一格可以随便被假夹具蒙过去")
    }

    // MARK: - 帮手

    private func decode(_ url: URL) throws -> ProjectReport {
        try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: Data(contentsOf: url))
    }

    private func recommendation(_ report: ProjectReport, containing needle: String) -> String? {
        report.health?.recommendations.first { $0.contains(needle) }
    }

    /// CLI 文本出口：真子进程跑**交付二进制**，环境里把崩溃报告目录指到夹具内的空目录。
    private func runDeliveredBinary(_ arguments: [String]) throws -> String {
        let (status, output) = try launch(arguments)
        XCTAssertEqual(status, 0, "无头 score 没跑成：\(output.prefix(400))")
        return output
    }

    private func runDeliveredBinaryWrite(_ arguments: [String]) throws -> URL {
        let out = sandbox.appendingPathComponent("cli-\(UUID().uuidString.prefix(6)).json")
        let (status, output) = try launch(arguments + ["--out=" + out.path])
        XCTAssertEqual(status, 0, "无头 scan 没跑成：\(output.prefix(400))")
        XCTAssertTrue(FileManager.default.fileExists(atPath: out.path), "CLI 没落出 JSON")
        return out
    }

    private func launch(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["TCODER_LIBRARY_LOGS_DIR"] = libraryLogs.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
    }

    /// 仓库里那把现成的尺子（AGENTS §5.9 第 5 条），不在测试里另写一份字段比对。
    private func runReportParity(gui: URL, cli: URL, target: URL) throws {
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
        XCTAssertEqual(parity.terminationStatus, 0, "GUI ↔ CLI 逐字段有不可容忍的不等：\n" + output)
    }
}
