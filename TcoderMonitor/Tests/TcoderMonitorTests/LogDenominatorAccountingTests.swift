import Foundation
import XCTest
@testable import TcoderMonitor

/// 总工（RD-46b 收口）· 「移出分母」不等于「消失」这件事必须**落在盘上**。
///
/// R11 把崩溃正文从 `totalLinesScanned` 摘出去之后，那几行只活在 `LogAggregate`（内部类型）里 ——
/// 落盘侧唯一的替代读者是 `scannedFiles` 里逐份的行数。那样的对账要靠人自己去加，
/// 而"加一遍"正是本仓反复出事的地方（`docs/口径与已知限制.md` 那本账就是为它开的）。
/// 现在两格进契约：`crashReportCount`（份数）与 `crashReportLineCount`（正文行数），
/// 本文件钉三条：**值等于夹具真值**、**对账等式成立**、**旧 JSON 缺键仍然解得开**。
///
/// ⚠️ 本文件**不管**这两格在界面上怎么说 —— 那是 RD-49（工单 R9b §0）的活：
/// 只有崩溃报告、零真日志行的项目，稳定维整维缺席、崩溃也不再扣分。这里只保证
/// "崩溃证据在报告里数得出来"，把 RD-49 的输入先备好。
///
/// 全部走 `TCODER_LIBRARY_LOGS_DIR` 指到临时目录里的假 DiagnosticReports：
/// 真目录含别的工程的报告，规约禁止读取（AGENTS §-1）。
final class LogDenominatorAccountingTests: XCTestCase {

    private enum Bar {
        static let project = "R11AccountingApp"
        static let logLines = 200
        static let reportFiles = 2
        static let reportLines = 500
    }

    private var base: URL!
    private var project: URL!
    private var libraryLogs: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("chief-rd46b-\(UUID().uuidString)", isDirectory: true)
        project = base.appendingPathComponent(Bar.project, isDirectory: true)
        libraryLogs = base.appendingPathComponent("fake-library-logs", isDirectory: true)
        try R11DenominatorFixture.makeProject(at: project)
        // 身份必须停在夹具根，否则"自己的报告"这个判据在这台机器上不可信。
        XCTAssertEqual(LogProjectIdentity.resolve(scanRoot: project).anchorURL.path, project.path,
                       "锚点跑出夹具根了，归属读数不可信")
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: 正例 + 独立真值 + 对账

    func test_crashBoxesCarryTheFixtureTruthAndBalanceAgainstDisk() async throws {
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        let logURL = try R11DenominatorFixture.writeLog(to: project, lines: Bar.logLines, every: 0)
        let reports = try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.reportFiles,
                                                            lines: Bar.reportLines, head: Bar.project)
        // 真值来自盘上的 0x0A 计数，不经过任何被测代码。
        let realLogLines = try R11DenominatorFixture.newlineCount(of: logURL)
        var crashLines = 0
        for url in reports { crashLines += try R11DenominatorFixture.newlineCount(of: url) }

        let summary = try await analyze()
        XCTAssertEqual(summary.totalLinesScanned, realLogLines, "分母只数真日志行")
        XCTAssertEqual(summary.crashReportCount, Bar.reportFiles, "份数：读到几份崩溃报告")
        XCTAssertEqual(summary.crashReportLineCount, crashLines, "正文行数：搬出去的那些行必须数得出来")
        XCTAssertEqual(summary.totalLinesScanned + (summary.crashReportLineCount ?? 0),
                       realLogLines + crashLines, "对账：两格相加 == 盘上实际读到的总行数")
    }

    /// 只有崩溃报告、一行真日志都没有 ⇒ 分母是 0，但崩溃证据**不许跟着消失**。
    /// 这一格就是 RD-49 的输入：报告里数得出「2 份 / 1,000 行」，措辞那一侧才有东西可点名。
    func test_crashOnlyProject_keepsCrashEvidenceVisibleEvenThoughTheDenominatorIsZero() async throws {
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        let reports = try R11DenominatorFixture.writeReports(in: libraryLogs, count: Bar.reportFiles,
                                                            lines: Bar.reportLines, head: Bar.project)
        let onDisk = try reports.map { try R11DenominatorFixture.newlineCount(of: $0) }.reduce(0, +)

        let summary = try await analyze()
        XCTAssertEqual(summary.totalLinesScanned, 0, "一行真日志都没有 ⇒ 分母必须是 0")
        XCTAssertEqual(summary.crashReportLineCount, onDisk, "而崩溃正文仍然要单独数得出来")
        XCTAssertTrue(summary.hasData, "读到过文件 ⇒ 不许长成「根本没扫到」的样子")
    }

    // MARK: 缺席态（Optional 是落盘兼容要求）

    func test_legacyJSONWithoutTheTwoKeysStillDecodesAsNil() throws {
        // 旧报告里根本没有这两个键；非 Optional 带默认值会让整份解码失败（`try?` 之后伪装成"没数据"）。
        let legacy = """
        {"analyzedAt":"2026-09-22T10:00:00Z","scannedFiles":[],"errorCount":0,"exceptionCount":0,
         "warningCount":0,"crashCount":0,"fatalCount":0,"infoLineCount":0,"totalLinesScanned":123,
         "topErrors":[],"trend":[],"affectedFiles":{}}
        """
        let decoder = JSONDecoder()
        // 与 `ProjectStore` / CLI 落盘同一把日期尺子（`.iso8601`）：默认策略要的是
        // `secondsSinceReferenceDate`，那样这条用例会红在解码器上、而不是红在"缺键"上。
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(LogSummary.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.totalLinesScanned, 123)
        XCTAssertNil(decoded.crashReportCount, "缺键 ⇒ nil（没量到），不是 0（量到了、没有）")
        XCTAssertNil(decoded.crashReportLineCount, "同上")
    }

    // MARK: 一把尺子：写者只许有一个

    /// 两格的写者必须**恰好**是 `FileLogAnalyzer` 一处 —— 出现第二个写者就是第二把尺子
    /// （RD-43/RD-45 同族）。这条与下面那条元测试成对出现，否则它是永真绿。
    func test_crashBoxesHaveExactlyOneWriter() throws {
        XCTAssertEqual(try writersOfCrashBoxesInSources(), ["FileLogAnalyzer.swift"])
    }

    func test_writerScannerCatchesASecondWriter() throws {
        let dirty = """
        summary.crashReportLineCount = aggregate.crashReportLineCount
        """
        let clean = "let metrics = Metrics()\n// 这里只提到 crashReportCount 这个名字，没有赋值\n"
        XCTAssertEqual(writerNames(in: dirty, named: "AnotherFile.swift"), ["AnotherFile.swift"],
                       "多出一个写者必须被抓到，否则这条守卫永不红")
        XCTAssertTrue(writerNames(in: clean, named: "AnotherFile.swift").isEmpty,
                      "只有名字没有赋值不该算写者（否则真改动一来它就钝了）")
    }

    // MARK: 夹具与扫描

    private func analyze() async throws -> LogSummary {
        try await FileLogAnalyzer().analyze(projectRoot: project, extraLogURLs: [], withinDays: 30)
    }

    /// 赋值形状：`.crashReportCount =` / `.crashReportLineCount =`（声明式 `var … = nil` 前面没有点，不算）。
    private static let writerPattern = "\\.crashReport(Count|LineCount)\\s*="

    private func writerNames(in text: String, named name: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: Self.writerPattern)
        return regex.matches(in: text, options: [], range: NSRange(text.startIndex..., in: text)).isEmpty
            ? [] : [name]
    }

    private func writersOfCrashBoxesInSources() throws -> [String] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        var out: [String] = []
        while case let url as URL = enumerator?.nextObject() {
            guard url.pathExtension == "swift" else { continue }
            if writerNames(in: try String(contentsOf: url, encoding: .utf8),
                           named: url.lastPathComponent).isEmpty == false {
                out.append(url.lastPathComponent)
            }
        }
        return out.sorted()
    }
}
