/// OWNER: WS-R9b 证据下限与死支清理（分支 `ws/r9-wording`）—— 工单 §0（RD-49）的守卫。
///
/// **一句话**：RD-46b 把崩溃正文从密度分母里摘出去之后，「只有崩溃报告、零真日志行」的项目
/// 也落进了 `guard logs.totalLinesScanned > 0` 这一支，于是报告对它说
/// 「没有可扫描的日志」—— 而崩溃报告就在日志目录里、已经被读到并且认了归属；
/// 那 N 次确认崩溃还随整维缺席一起不再扣分（一层假话 + 一次漏报）。
///
/// 修后这一支拆成三态，**三态都不给分、都不按 0 计入**，但各说各的话：
/// ① 真的什么都没有 ⇒ 保留原来那句「没有可扫描的日志」（此时它才是真话）；
/// ② 有崩溃证据（确认次数或已读到的份数）⇒ 点名次数与份数 + 「错误密度算不出分母」；
/// ③ 只有读不动的崩溃报告 ⇒ 说"证据不确定"，既不许冒充有崩溃、也不许冒充没有日志。
///
/// 崩溃证据的份数与次数是**独立真值**：夹具里我自己写了几份 `.ips`、每份几次事件，
/// 断言就钉那几个数（构造参数写在 `Bar` 里，不取自 `FileLogAnalyzer` 的输出）。
/// 全部走 `TCODER_LIBRARY_LOGS_DIR` 指到临时目录里的假 DiagnosticReports：
/// 真目录里有别的工程的报告，规约禁止读取（AGENTS §-1），而且读数会绑到这台机器上。
/// 夹具树必须落在宿主仓库**之外**并自证锚点（见 `LogDenominatorStatesTests` 的样板：
/// 夹具进了 `/Users/one/Documents/Tcoder` 任何一层，`LogProjectIdentity` 都会向上继承宿主身份）。
import Darwin
import XCTest
@testable import TcoderMonitor

final class ScoreEvidenceFloorCrashStatesTests: XCTestCase {

    private enum Bar {
        /// 项目主名 = 身份令牌 = `.ips` 报告主名（归属要比对的那一段）。
        static let project = "R9bCrashStatesApp"
        static let foreign = "R9bForeignApp"
        /// 每份崩溃报告的正文行数。它们**一律不进分母**（RD-46b），所以本文件的分母恒为 0。
        static let reportLines = 400
        static let ownReports = 2
        static let foreignReports = 3
    }

    private var base: URL!
    private var project: URL!
    private var libraryLogs: URL!
    private var originalLogsDirectory: String?

    override func setUpWithError() throws {
        originalLogsDirectory = ProcessInfo.processInfo.environment["TCODER_LIBRARY_LOGS_DIR"]
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("r9b-crash-states-\(UUID().uuidString)", isDirectory: true)
        project = base.appendingPathComponent(Bar.project, isDirectory: true)
        libraryLogs = base.appendingPathComponent("fake-library-logs", isDirectory: true)
        try R11DenominatorFixture.makeProject(at: project)
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        // 锚点必须停在夹具根：这条是上一轮误立案的根因，每条用例开跑前先量一次。
        XCTAssertFalse(project.path.contains("/Tcoder/"), "夹具不许落在宿主仓库内：\(project.path)")
        XCTAssertEqual(LogProjectIdentity.resolve(scanRoot: project).anchorURL.path, project.path,
                       "锚点跑出夹具根 ⇒ 归属读数不可信")
    }

    override func tearDownWithError() throws {
        if let original = originalLogsDirectory {
            setenv("TCODER_LIBRARY_LOGS_DIR", original, 1)
        } else {
            unsetenv("TCODER_LIBRARY_LOGS_DIR")
        }
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - ② 正例：有崩溃证据、零真日志行（RD-49 的现场）

    /// 夹具树里只放自己的 `.ips`、一个真日志文件都不放 ⇒ 这就是本仓自扫的形状。
    /// 修前：`recommendations` 里出现「没有可扫描的日志」（假话）；修后：点名崩溃、整维缺席。
    func test_crashReportsWithZeroLogLinesNameTheCrashesInsteadOfDenyingThem() async throws {
        let written = try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.ownReports,
                                                            lines: Bar.reportLines, head: Bar.project)
        XCTAssertEqual(written.count, Bar.ownReports, "前提：份数是我自己写的")
        let logs = try await analyze()

        // 独立真值：份数与次数一一对上夹具构造，不实现自身的输出。
        XCTAssertEqual(logs.totalLinesScanned, 0, "一个真日志文件都没有 ⇒ 分母必须是 0")
        XCTAssertEqual(logs.crashReportCount, Bar.ownReports, "读到的崩溃报告份数要数得出来")
        XCTAssertEqual(logs.crashCount, Bar.ownReports, "每份报告各一次确认崩溃")
        XCTAssertTrue(logs.hasData, "hasData 仍然为 true —— 这正是那句假话的来源（工单 §0）")

        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: logs))
        XCTAssertFalse(score.components.contains { $0.name == HealthDimension.stability.rawValue },
                       "有崩溃证据也不给分：整维必须缺席")
        XCTAssertTrue(HealthBreakdown.missingDimensions(of: score).contains(.stability))
        let naming = try XCTUnwrap(score.recommendations.first { $0.contains("错误密度算不出分母") },
                                   "建议必须点名崩溃并承认分母无定义，实得 \(score.recommendations)")
        XCTAssertTrue(naming.contains("\(Bar.ownReports) 次确认崩溃"), "次数要写出来：\(naming)")
        XCTAssertTrue(naming.contains("\(Bar.ownReports) 份崩溃报告"), "份数要写出来：\(naming)")
        XCTAssertFalse(score.recommendations.contains { $0.contains("没有可扫描的日志") },
                       "明明扫到了崩溃报告，这句就是假话，不许再出现：\(score.recommendations)")
        XCTAssertFalse(score.strengths.contains { $0.contains("未见确认崩溃") },
                       "崩溃都在脸上了还写「未见确认崩溃」= 自己打自己脸：\(score.strengths)")
    }

    /// 缺席原因那一格（界面与 CLI 共用）也要点名，不许落到「一行都没读出来」那句。
    func test_absenceReasonForCrashEvidenceStateIsItsOwnSentence() async throws {
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.ownReports,
                                              lines: Bar.reportLines, head: Bar.project)
        var report = ProjectReport(project: MonitoredProject(name: Bar.project, path: project.path))
        report.logs = try await analyze()
        let reason = MissingDimensionReason.text(for: .stability, report: report)
        XCTAssertTrue(reason.contains("崩溃") && reason.contains("\(Bar.ownReports) 份"),
                      "缺席原因要把崩溃证据说出来，实得 \(reason)")
        XCTAssertFalse(reason.contains("一行都没读出来"),
                       "崩溃报告是读出来的（只是不该进分母），这句对它是假话：\(reason)")
    }

    // MARK: - ① 反例：零崩溃、零日志 ⇒ 旧文案一句不许动

    func test_nothingAtAllStillSaysThereIsNothingToScan() async throws {
        let logs = try await analyze()   // 崩溃目录空的、也没有真日志文件
        XCTAssertEqual(logs.crashReportCount ?? 0, 0, "前提：崩溃通道一份都没有")
        XCTAssertEqual(logs.crashCount, 0)
        XCTAssertEqual(logs.totalLinesScanned, 0)

        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: logs))
        XCTAssertTrue(score.recommendations.contains { $0.contains("没有可扫描的日志") },
                      "旧文案不许因为加了新态就消失，实得 \(score.recommendations)")
        XCTAssertFalse(score.recommendations.contains { $0.contains("错误密度算不出分母") },
                       "什么都没有的时候不许凭空报一份崩溃证据")
        XCTAssertFalse(HealthBreakdown.missingDimensions(of: score).isEmpty, "这一维仍然缺席")
    }

    /// 别人的崩溃报告不算本项目证据（归属漏报的同族反例）。
    func test_foreignReportsAreNotOwnCrashEvidence() async throws {
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.foreignReports,
                                              lines: Bar.reportLines, head: Bar.foreign)
        let logs = try await analyze()
        XCTAssertEqual(logs.crashCount, 0, "别人的报告一次都不许算进本项目")
        XCTAssertEqual(logs.crashReportCount ?? 0, 0)
        let shape = StabilityZeroDenominatorShape.assess(logs)
        XCTAssertEqual(shape, .nothingAtAll, "三份别人的报告不许把形状推成「有崩溃证据」")
        XCTAssertTrue(WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: logs))
            .recommendations.contains { $0.contains("没有可扫描的日志") })
    }

    // MARK: - ③ 未知态：崩溃报告读不动，不许冒充「有崩溃证据」

    /// 把自己的 `.ips` chmod 成读不动 ⇒ 它进 `readFailedFiles` 那本账，
    /// 既不能算「确认崩溃」（那是②），也不能被说成「没有可扫描的日志」（那是①）。
    func test_unreadableCrashReportsSayTheEvidenceIsUncertain() async throws {
        let written = try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.ownReports,
                                                            lines: Bar.reportLines, head: Bar.project)
        for url in written { try FileManager.default.setAttributes([.posixPermissions: 0o000],
                                                                  ofItemAtPath: url.path) }
        let logs = try await analyze()
        let unreadable = (logs.readFailedFiles ?? []).filter { $0.role == .crash }
        XCTAssertEqual(unreadable.count, Bar.ownReports, "两份都该落在读取失败那本账里，实得 \(logs.readFailedFiles?.count ?? -1)")
        XCTAssertEqual(logs.crashCount, 0, "读不动的报告不许产出确认崩溃")
        XCTAssertEqual(logs.crashReportCount ?? 0, 0, "读不动的报告不算读到的份数")
        XCTAssertEqual(StabilityZeroDenominatorShape.assess(logs), .unreadableCrashReports(Bar.ownReports))

        let score = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: logs))
        let advice = try? XCTUnwrap(score.recommendations.first { $0.contains("没能读出来") },
                                    "第三态要说得出「读不动」，实得 \(score.recommendations)")
        XCTAssertFalse(score.recommendations.contains { $0.contains("没有可扫描的日志") },
                       "读不动与根本没有是两件事，不许共用一句")
        XCTAssertFalse(score.recommendations.contains { $0.contains("错误密度算不出分母") },
                       "没有确认崩溃就不许报「读到 N 次崩溃」那句")
        XCTAssertFalse(score.components.contains { $0.name == HealthDimension.stability.rawValue },
                       "第三态同样不给分：\(advice ?? "无")")
    }

    // MARK: - ④ 一把尺子：新旧报告形状与两处读者同源

    /// 旧报告没有 `crashReportCount`（nil）时退回同一集合的计数，判据不许因此退化成「没证据」。
    func test_oldReportWithoutTheCountFieldStillReadsAsCrashEvidence() {
        let legacy = LogSummary(scannedFiles: [ScannedLogFile(path: "/fixture/Legacy-1.ips", sizeBytes: 4_000,
                                                             lineCount: 300, modifiedAt: Date(), role: .crash)],
                                crashCount: 1, totalLinesScanned: 0)
        XCTAssertNil(legacy.crashReportCount, "前提：这一份是 RD-46b 之前的形状")
        XCTAssertEqual(StabilityZeroDenominatorShape.assess(legacy),
                       .crashesWithoutLogLines(confirmedCrashes: 1, readableReports: 1))
    }

    /// 两把尺子的对账：`crashReportCount`（直传格）与 `scannedFiles` 里 role == .crash 的份数
    /// 必须数到同一批文件 —— 这是"退回旧算法不是第二把尺子"这件事的机器记录。
    func test_countFieldAndScannedFilesAreTheSameSet() async throws {
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.ownReports,
                                              lines: Bar.reportLines, head: Bar.project)
        let logs = try await analyze()
        XCTAssertEqual(logs.crashReportCount, logs.scannedFiles.filter { $0.role == .crash }.count,
                       "同一批文件被数成两个数 ⇒ 判据开始有两把尺子")
    }

    /// CLI 与 GUI 同一条句子（工单交付④：`score` 那一路要真跑到新句子）。
    func test_cliScoreTextCarriesTheSameCrashNamingSentence() async throws {
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.ownReports,
                                              lines: Bar.reportLines, head: Bar.project)
        let logs = try await analyze()
        var report = ProjectReport(project: MonitoredProject(name: Bar.project, path: project.path))
        report.logs = logs
        report.attemptedAt = Date()
        report.health = WeightedHealthScorer().score(HealthInputs(code: healthyCode(), logs: logs))
        let text = CLIScoreText.render(report, exit: .ok)
        XCTAssertTrue(text.contains("错误密度算不出分母"),
                      "无头出口的 recommendations 必须与界面同源，实得\n\(text)")
        XCTAssertTrue(text.contains("运行稳定性 —"), "缺席维度要点名维度名：\(text)")
        XCTAssertTrue(text.contains("崩溃"), "缺席原因那一格也要说得出崩溃证据：\(text)")
        XCTAssertFalse(text.contains("没有可扫描的日志"), "CLI 侧也不许再说那句假话")
    }

    // MARK: - 帮手

    private func healthyCode() -> CodeMetrics {
        var code = CodeMetrics()
        code.codeLines = 40_000
        return code
    }

    private func analyze() async throws -> LogSummary {
        try await FileLogAnalyzer().analyze(projectRoot: project, extraLogURLs: [], withinDays: 30)
    }
}
