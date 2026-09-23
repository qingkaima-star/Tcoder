import Darwin
import XCTest
@testable import TcoderMonitor

/// R11 · 分母口径的四态（交付③）：崩溃报告不进分母这件事，在"根本没得算"的三种情况下
/// 不许长成"算过了、结果是零"的样子。
///
/// 全部走 `TCODER_LIBRARY_LOGS_DIR` 指到临时目录里的假 DiagnosticReports：
/// 真目录里有别的工程的报告，规约禁止读取（AGENTS §-1），而且读数会绑到这台机器上。
///
/// 四态与它们各自能观测到什么：
/// 1. **假目录不存在** ⇒ 崩溃通道一份都没扫到：分母仍是真日志行、份数 0、`crashCount` 0，
///    而且**不谎报读取失败**（`readFailedFiles` 为空 —— 那本账是"打不开的文件"，目录不在不是文件打不开）。
/// 2. **目录空** ⇒ 同样分母不变、份数 0。⚠️ 1 与 2 在**已落盘的读数上目前同形**：
///    要说清"没扫到"与"扫了、零份"需要 `LogSummary` 开一格（`crashReportDirectoryReadable: Bool?`），
///    `Models/**` 是冻结区，字段清单已交总工，本流不自建。
/// 3. **全是不属于本项目的报告** ⇒ 0 计入，且**能解释**：解释就是工具自己那条命名规则
///    `LogDiscovery.isOwnDiagnosticReport`，它对盘上那三份逐份返回 false（并有正例对照，
///    免得规则退化成"永远 false"也照样绿）。分母不受它们那 500×3 行影响。
/// 4. **正常** ⇒ 自己的报告计入：份数单独成格、次数单独成账、分母仍然只有真日志行。
final class LogDenominatorStatesTests: XCTestCase {

    private enum Bar {
        static let project = "R11StatesApp"
        static let foreign = "R11ForeignApp"
        static let logLines = 200
        static let reportFiles = 3
        static let reportLines = 500
    }

    private var base: URL!
    private var project: URL!
    private var libraryLogs: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("r11-states-\(UUID().uuidString)", isDirectory: true)
        project = base.appendingPathComponent(Bar.project, isDirectory: true)
        libraryLogs = base.appendingPathComponent("fake-library-logs", isDirectory: true)
        try R11DenominatorFixture.makeProject(at: project)
        try R11DenominatorFixture.writeLog(to: project, lines: Bar.logLines, every: 0)
        // 身份必须停在夹具根：这条是 v1 误立案的根因，每次跑都先量一次。
        XCTAssertEqual(LogProjectIdentity.resolve(scanRoot: project).anchorURL.path, project.path,
                       "锚点跑出夹具根了，归属读数不可信")
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: 1 / 2 · 没得算的两种样子

    /// ① 假目录不存在：不许把"没扫到"演成"扫过、干净"。
    func test_missing_report_directory_yields_nothing_and_no_fake_failure() async throws {
        setenv("TCODER_LIBRARY_LOGS_DIR", base.appendingPathComponent("nowhere").path, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: libraryLogs.path), "前提：目录确实不存在")

        let summary = try await analyze()
        assertDenominatorIsOnlyTheRealLog(summary)
        XCTAssertTrue(summary.scannedFiles.filter { $0.role == .crash }.isEmpty)
        XCTAssertEqual(summary.crashCount, 0)
        XCTAssertTrue((summary.readFailedFiles ?? []).isEmpty,
                      """
                      目录不存在不是「文件打不开」，不该混进读取失败那本账：\
                      \((summary.readFailedFiles ?? []).map(\.path))
                      """)
    }

    /// ② 空目录：0 份、0 行入分母，与①的区别只在盘上（落盘读数同形，见文件头②）。
    func test_empty_report_directory_yields_zero_reports() async throws {
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        XCTAssertEqual(try entriesInReportsDirectory().count, 0, "前提：目录空的")

        let summary = try await analyze()
        assertDenominatorIsOnlyTheRealLog(summary)
        XCTAssertEqual(summary.scannedFiles.filter { $0.role == .crash }.count, 0)
        XCTAssertEqual(summary.crashCount, 0)
    }

    // MARK: 3 / 4 · 归属混合

    /// ③ 目录里三份报告全是别的 App 的：0 计入，并且**说得出为什么**（工具的命名规则逐份返回 false）。
    func test_foreign_reports_contribute_nothing_and_the_rule_explains_why() async throws {
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        let foreign = try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.reportFiles,
                                                            lines: Bar.reportLines, head: Bar.foreign)
        let identity = LogProjectIdentity.resolve(scanRoot: project)
        XCTAssertTrue(foreign.allSatisfy { LogDiscovery.isOwnDiagnosticReport($0, identity: identity) == false },
                      "前提：这三份的主名不在本项目身份令牌里")
        // 正例对照：同一条规则对自己的报告必须返回 true，否则上面的全 false 是规则失效而不是排除生效。
        XCTAssertTrue(LogDiscovery.isOwnDiagnosticReport(
            URL(fileURLWithPath: "/x/\(Bar.project)-2026-09-21-101112.ips"), identity: identity))

        let summary = try await analyze()
        assertDenominatorIsOnlyTheRealLog(summary)
        XCTAssertEqual(summary.crashCount, 0, "别人的崩溃一次都不许算进本项目")
        XCTAssertTrue(summary.scannedFiles.filter { $0.role == .crash }.isEmpty)
        XCTAssertEqual(try entriesInReportsDirectory().count, Bar.reportFiles,
                       "它们仍然在场（静默丢弃是另一种藏法），只是没被计入")
    }

    /// ④ 正常态 + 混合：自己的计入、别人的不计入，两条互不污染。
    func test_own_reports_are_counted_in_their_own_box() async throws {
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.reportFiles,
                                               lines: Bar.reportLines, head: Bar.foreign)
        let own = try R11DenominatorFixture.writeReports(in: libraryLogs, count: 1,
                                                         lines: Bar.reportLines, head: Bar.project)
        XCTAssertEqual(try R11DenominatorFixture.newlineCount(of: try XCTUnwrap(own.first)),
                       Bar.reportLines, "夹具自检：自己那份也是 500 行")

        let summary = try await analyze()
        assertDenominatorIsOnlyTheRealLog(summary)
        let crashFiles = summary.scannedFiles.filter { $0.role == .crash }
        XCTAssertEqual(crashFiles.count, 1, "3 份别人的 + 1 份自己的 ⇒ 计入 1 份")
        XCTAssertEqual(crashFiles.first?.lineCount, Bar.reportLines, "那 500 行逐份留档，没被抹掉")
        XCTAssertEqual(summary.crashCount, 1, "自己的那次确认崩溃要计，别人的不算")
    }

    // MARK: 夹具与读数

    /// 四态共同的底：不管崩溃通道里有什么、没什么，分母恒等于那 200 行真日志。
    private func assertDenominatorIsOnlyTheRealLog(_ summary: LogSummary,
                                                   file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(summary.totalLinesScanned, Bar.logLines,
                       "分母该是 \(Bar.logLines) 行真日志，实得 \(summary.totalLinesScanned)",
                       file: file, line: line)
    }

    private func entriesInReportsDirectory() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true),
            includingPropertiesForKeys: nil)
    }

    private func analyze() async throws -> LogSummary {
        try await FileLogAnalyzer().analyze(projectRoot: project, extraLogURLs: [], withinDays: 30)
    }
}
