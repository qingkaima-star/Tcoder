import Darwin
import XCTest
@testable import TcoderMonitor

/// R11 · 日志分母口径（台账 RD-46b）。
///
/// **一句话**：崩溃报告（`.ips`）的正文既按份数扣分，就又把自己的行数灌进
/// 「每千行日志错误数」的分母 —— 同一份证据起了两个相反的作用。本文件钉的是
/// 「分母回家、崩溃单独成格」，**分子一个字都没动**（崩溃事件仍走 `extraEvents` 那条唯一通道）。
///
/// ## 独立真值（自己数的，不取自实现输出）
/// 三组夹具只差"在不在同一份日志上叠 3 份崩溃报告"：
/// * **A** `Logs/app.log` = **10,000 行**真日志，其中 **50 行 ERROR**（每 200 行一条），0 份崩溃报告。
///   ⇒ 分母 10,000、错误密度 50 ÷ 10,000 × 1,000 = **每千行 5.0 个**。
/// * **B** 与 A **同一份 app.log**（同一构造，逐字相同）+ **3 份** `R11DenomApp-*.ips`，
///   每份 **500 行** ⇒ 崩溃正文合计 **1,500 行**。
///   ⇒ 分母仍然 10,000（**不是 11,500**）、密度仍然 5.0、崩溃**份数**另一格 = **3**、
///   确认崩溃**次数** = **3**，并且 B 的分**不高于** A。
/// * **C** 只有 **3 行**日志 ⇒ 分母 = 3（这一格只管"数对行数"；
///   "3 行撑起一维满分"是 RD-46，要改 `Services/Health/**` 的曲线输入，本流不碰，见汇报）。
///
/// ## 为什么夹具必须落在 `NSTemporaryDirectory()` 而不是本仓库树内
/// `LogProjectIdentity.projectAnchor` 按设计**向上**爬到最近的 `.git`。夹具放进
/// `/Users/one/Documents/Tcoder` 里任何一层，它都会继承宿主项目身份，
/// 于是"无关项目的崩溃报告"会被判成自己的 —— 上一版工单就是这么误立案又收回的。
/// 真目录 `~/Library/Logs/DiagnosticReports` 里有别的工程的报告，规约禁止读取（AGENTS §-1），
/// 所以取证一律走 `TCODER_LIBRARY_LOGS_DIR` 指到临时目录里的假 DiagnosticReports。
final class LogDenominatorTests: XCTestCase {

    private enum Fixture {
        /// 项目主名 = 身份令牌 = `.ips` 报告主名（`isOwnDiagnosticReport` 要整段相等）。
        static let project = "R11DenomApp"
        static let logFileName = "app.log"
        static let logLines = 10_000
        /// 每 200 行一条 ERROR ⇒ 10,000 行里正好 50 条。
        static let errorEvery = 200
        static var errorLines: Int { logLines / errorEvery }
        static let reportFiles = 3
        static let reportLines = 500
        static var crashBodyLines: Int { reportFiles * reportLines }
        static var densityPerKilo: Double { Double(errorLines) / Double(logLines) * 1_000 }
    }

    private var base: URL!
    private var project: URL!
    private var libraryLogs: URL!

    override func setUpWithError() throws {
        let unique = UUID().uuidString
        base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("r11-denominator-\(unique)", isDirectory: true)
        project = base.appendingPathComponent(Fixture.project, isDirectory: true)
        libraryLogs = base.appendingPathComponent("fake-library-logs", isDirectory: true)
        try R11DenominatorFixture.makeProject(at: project)
        try R11DenominatorFixture.makeDiagnosticReportsDirectory(under: libraryLogs)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
        // 身份自证放在 setUp：这一条红过一次 v1 的误立案，所以每条用例开跑前都先量它，
        // 而不是只在某一条里量 —— 夹具一旦被搬进宿主仓库树，所有读数都会是错的。
        try assertFixtureIdentityIsOwn()
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: base)
    }

    /// 夹具自证：项目树在 Tcoder 之外、锚点就是夹具根、令牌就是项目主名。
    /// 这一条红过一次 v1 的误立案，所以每次跑都先量它。
    private func assertFixtureIdentityIsOwn(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(project.path.contains("/Tcoder/"),
                       "夹具树落在宿主仓库内会继承宿主身份：\(project.path)", file: file, line: line)
        let identity = LogProjectIdentity.resolve(scanRoot: project)
        XCTAssertEqual(identity.anchorURL.path, project.path,
                       "锚点必须停在夹具根，实得 \(identity.anchorURL.path)", file: file, line: line)
        XCTAssertEqual(identity.attributionTokens, [Fixture.project.lowercased()],
                       "身份令牌只该有夹具主名一个", file: file, line: line)
    }

    /// 夹具自检：盘上的换行数就是我说的那些数（`wc -l` 口径，与被测实现无关）。
    /// 没有这一步，"10,000 行"只是我嘴里的一个数；实现如果连盘上有多少行都没读对，
    /// 后面所有关于分母的断言都失去意义。
    private func assertFixtureLineCounts(logURL: URL, reports: [URL],
                                         file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try R11DenominatorFixture.newlineCount(of: logURL), Fixture.logLines,
                       "夹具自检：\(R11DenominatorFixture.logFileName) 该有 \(Fixture.logLines) 个换行",
                       file: file, line: line)
        XCTAssertEqual(reports.count, Fixture.reportFiles, "份数是自己写的，不是数出来的", file: file, line: line)
        for report in reports {
            XCTAssertEqual(try R11DenominatorFixture.newlineCount(of: report), Fixture.reportLines,
                           "夹具自检：\(report.lastPathComponent) 该有 \(Fixture.reportLines) 个换行",
                           file: file, line: line)
        }
    }

    // MARK: ① 分母：修前可复现 + 独立真值

    /// 聚合器这一格的本体判据：崩溃报告的行**不进**分母，另立两格。
    func test_aggregator_keeps_crash_report_lines_out_of_the_denominator() throws {
        let log = R11DenominatorFixture.reading(role: .application,
                                                lines: Fixture.logLines, named: Fixture.logFileName)
        let reports = (1...Fixture.reportFiles).map { index in
            R11DenominatorFixture.reading(role: .crash, lines: Fixture.reportLines,
                                          named: "R11DenomApp-2026-09-2\(index)-10111\(index).ips")
        }
        // 读失败的那一份既不进分母也不充份数（它走 readFailedFiles 另一本账）
        var failed = R11DenominatorFixture.reading(role: .crash, lines: 0,
                                                   named: "R11DenomApp-2026-09-22-101119.ips")
        failed.readFailed = true

        let agg = LogAggregator.aggregate(readings: [log] + reports + [failed],
                                          extraEvents: [], topLimit: 5)
        XCTAssertEqual(agg.totalLinesScanned, Fixture.logLines,
                       "分母只数真日志行，该是 \(Fixture.logLines)，实得 \(agg.totalLinesScanned)")
        XCTAssertEqual(agg.crashReportLineCount, Fixture.crashBodyLines,
                       "崩溃正文 \(Fixture.crashBodyLines) 行要单独成格，不许就此消失")
        XCTAssertEqual(agg.crashReportFileCount, Fixture.reportFiles, "份数是另一格")
    }

    /// 端到端：B 的分母仍是 10,000 行，**不是 11,500**。这条是修前必红的复现用例。
    func test_crash_reports_do_not_dilute_the_log_line_denominator() async throws {
        let logURL = try R11DenominatorFixture.writeLog(to: project, lines: Fixture.logLines,
                                                        every: Fixture.errorEvery)
        let reports = try R11DenominatorFixture.writeReports(in: libraryLogs, count: Fixture.reportFiles,
                                                             lines: Fixture.reportLines, head: Fixture.project)
        try assertFixtureLineCounts(logURL: logURL, reports: reports)
        let summary = try await analyze()

        XCTAssertEqual(summary.totalLinesScanned, Fixture.logLines,
                       """
                       分母只数真日志行：该是 \(NumberFormat.grouped(Fixture.logLines))，\
                       实得 \(NumberFormat.grouped(summary.totalLinesScanned))。
                       多出来的 \(NumberFormat.grouped(summary.totalLinesScanned - Fixture.logLines)) 行\
                       是 \(Fixture.reportFiles) 份崩溃报告的正文（每份 \(Fixture.reportLines) 行）——\
                       它已经按份数扣过分，再进分母就是同一份证据起两个相反的作用。
                       """)
        XCTAssertEqual(summary.scannedFiles.filter { $0.role == .crash }.count, Fixture.reportFiles,
                       "份数另有其格，且必须点得出名")
        // 每份报告自己那 500 行仍然逐份留档，没有因为"移出分母"而被静默丢掉
        XCTAssertEqual(summary.scannedFiles.filter { $0.role == .crash }
                       .reduce(0) { $0 + $1.lineCount }, Fixture.crashBodyLines)
        // 移出分母 ≠ 移出分子：3 次确认崩溃一次都不能少。
        // body 里那行 EXC_CRASH 是诱饵 —— 崩溃通道与行解析若各数一遍，这里会变成 6。
        XCTAssertEqual(summary.crashCount, Fixture.reportFiles,
                       "3 份报告该计 3 次确认崩溃，实得 \(summary.crashCount)")
    }

    /// 同一份真日志，多叠 3 份崩溃报告：分母不变 ⇒ 每千行错误密度必须一字不动。
    /// 这条比"分母等于 10,000"更狠：它拿 A 做参照，灌大分母一定让它掉。
    func test_density_is_unchanged_by_crash_reports() async throws {
        try R11DenominatorFixture.writeLog(to: project, lines: Fixture.logLines, every: Fixture.errorEvery)
        let withoutReports = try await analyze()
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Fixture.reportFiles,
                                               lines: Fixture.reportLines, head: Fixture.project)
        let withReports = try await analyze()

        XCTAssertEqual(withReports.errorCount, Fixture.errorLines,
                       "自己数的 \(Fixture.errorLines) 条 ERROR 行，实得 \(withReports.errorCount)")
        XCTAssertEqual(withoutReports.errorCount, Fixture.errorLines)
        XCTAssertEqual(density(withoutReports), Fixture.densityPerKilo, accuracy: 0.001,
                       "A 组独立真值：\(Fixture.errorLines) 个错误 ÷ \(Fixture.logLines) 行 = 每千行 \(Fixture.densityPerKilo)")
        XCTAssertEqual(density(withReports), density(withoutReports), accuracy: 0.001,
                       "同一份日志叠上崩溃报告后密度动了 ⇒ 分母又被灌大了")
        print("=== R11 密度实测 ===  A 每千行 \(density(withoutReports)) 个错误 · "
            + "B 每千行 \(density(withReports)) 个错误（B 多 3 份 / 1,500 行崩溃报告正文）")
    }

    /// B 的分不高于 A：多 3 次确认崩溃只会更差，不能因为灌了分母而变好。
    func test_three_more_crashes_never_raise_the_stability_score() async throws {
        try R11DenominatorFixture.writeLog(to: project, lines: Fixture.logLines, every: Fixture.errorEvery)
        let scoreA = try await stabilityScore()
        try R11DenominatorFixture.writeReports(in: libraryLogs, count: Fixture.reportFiles,
                                               lines: Fixture.reportLines, head: Fixture.project)
        let scoreB = try await stabilityScore()

        XCTAssertNotEqual(scoreA, -1, "稳定维要真的参与两次评分，否则这条是假绿")
        XCTAssertNotEqual(scoreB, -1, "B 组有 10,000 行日志，稳定维不该缺席")
        XCTAssertLessThanOrEqual(Double(scoreB), Double(scoreA),
                                "多 3 次崩溃后 B=\(scoreB) 不得高于 A=\(scoreA)")
        print("=== R11 稳定维实测 ===  A（无崩溃）\(scoreA) 分 · B（同一批日志 + 3 次确认崩溃）\(scoreB) 分")
    }

    /// C 组：3 行日志的分母就是 3 行。RD-46「证据下限」不在本流，见汇报与文件头。
    func test_thin_log_denominator_is_the_three_lines_it_really_has() async throws {
        try R11DenominatorFixture.writeLog(to: project, lines: 3, every: 0)
        let summary = try await analyze()

        XCTAssertEqual(summary.totalLinesScanned, 3, "三行就是三行，不多不少")
        XCTAssertEqual(summary.crashCount, 0)
    }

    // MARK: 消费侧读数（不改 Health，只把自己交出去的那一格钉住）

    private func analyze() async throws -> LogSummary {
        try await FileLogAnalyzer().analyze(projectRoot: project, extraLogURLs: [], withinDays: 30)
    }

    /// 与 `stabilityOutcome` 同一条密度口径（本流不改它，只钉自己交出去的分母）。
    private func density(_ logs: LogSummary) -> Double {
        guard logs.totalLinesScanned > 0 else { return -1 }
        return Double(logs.errorCount + logs.exceptionCount) / Double(logs.totalLinesScanned) * 1_000
    }

    private func stabilityScore() async throws -> Int {
        var code = CodeMetrics()
        code.codeLines = 10_000
        return try await WeightedHealthScorer().score(HealthInputs(code: code, logs: analyze()))
            .components.first { $0.name == HealthDimension.stability.rawValue }?.score ?? -1
    }
}

/// R11 夹具构造器 + **独立真值计数器**。
///
/// 纪律：真值只来自两条与被测实现无关的途径 ——
/// ①「我自己写了多少行」（构造时的行数参数）；②「文件里有几个 0x0A 字节」（`wc -l` 同一口径）。
/// 绝不拿 `LogReader` / `LogAggregator` 的输出反推行数，否则实现把行数算错了，
/// 夹具会跟着一起错，这条测试就成了自己给自己背书。
enum R11DenominatorFixture {
    static let appVersion = "1.0 (1)"
    static let logFileName = "app.log"

    static func makeProject(at url: URL) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: url.appendingPathComponent("Logs", isDirectory: true),
                                    withIntermediateDirectories: true)
        // 锚点靠 `.git` 认。少了它，`projectAnchor` 会一路向上爬出临时目录，
        // 身份令牌就不再是夹具主名 —— 上一版工单把夹具放进仓库树里就是这么读错数的。
        try manager.createDirectory(at: url.appendingPathComponent(".git", isDirectory: true),
                                    withIntermediateDirectories: true)
    }

    static func makeDiagnosticReportsDirectory(under libraryLogs: URL) throws {
        try FileManager.default.createDirectory(
            at: libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true),
            withIntermediateDirectories: true)
    }

    /// 真日志全文：`lines` 行，每 `every` 行一条 ERROR（`every == 0` ⇒ 全 INFO）。
    /// 时间戳逐行往回退一秒，全部落在 30 天窗口内。
    static func logText(lines: Int, every: Int, now: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var rows: [String] = []
        rows.reserveCapacity(lines)
        for index in 0..<lines {
            let stamp = formatter.string(from: now.addingTimeInterval(-Double(index)))
            if every > 0, index % every == every - 1 {
                rows.append("\(stamp) ERROR [order-service] c.e.s.OrderService - 处理订单失败 orderId=\(index)")
            } else {
                rows.append("\(stamp) INFO  [order-service] c.e.s.Health - 心跳序号 \(index)")
            }
        }
        return rows.joined(separator: "\n") + "\n"
    }

    @discardableResult
    static func writeLog(to project: URL, lines: Int, every: Int) throws -> URL {
        let url = project.appendingPathComponent("Logs").appendingPathComponent(logFileName)
        try logText(lines: lines, every: every).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 一份假 `.ips`：整份**恰好** `totalLines` 行（首行 header JSON，其余是 body JSON 的展开）。
    /// 500 行不是随手取的：真机上一份苹果崩溃报告就是几百行机器字段 + 线程表 +
    /// 几百条 usedImages，正是这些行把分母灌大的（工单立案证据：4 份 .ips ≈ 1,063 行）。
    static func ipsText(procName: String, incident: String, eventDate: Date, totalLines: Int) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        let stamp = formatter.string(from: eventDate)
        let header = #"{"app_name":"\#(procName)","app_version":"\#(appVersion)","bug_type":"309","incident_id":"\#(incident)","is_first_party":1,"name":"\#(procName)","os_version":"macOS 26.5.1 (25F80)","roots_installed":0,"slice_uuid":"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE","timestamp":"\#(stamp)","version":2}"#
        var lines = [header, "{",
                     "  \"bug_type\" : \"309\",",
                     "  \"incident_id\" : \"\(incident)\",",
                     "  \"timestamp\" : \"\(stamp)\",",
                     "  \"version\" : 2,",
                     "  \"procName\" : \"\(procName)\",",
                     "  \"parentProc\" : \"launchd\",",
                     "  \"app_version\" : \"\(appVersion)\",",
                     "  \"os_version\" : \"macOS 26.5.1 (25F80)\",",
                     // 这行 `EXC_CRASH` 是故意留的诱饵：崩溃通道一旦没接管住这份文件，
                     // 行解析会把这一个 token 再数一次崩溃 —— 去重坏了这里立刻红。
                     "  \"exception\" : {\"type\":\"EXC_CRASH\",\"signal\":\"SIGABRT\"},",
                     "  \"threads\" : [",
                     "    {\"id\" : 7, \"triggered\" : true, \"frames\" : ["]
        for index in 0..<20 {
            let comma = index == 19 ? "" : ","
            lines.append("      {\"imageIndex\":0,\"symbol\":\"\(procName)Store.flush(index: \(index))\","
                + "\"sourceLineInfo\":{\"file\":\"Store.swift\",\"line\":\(100 + index)}}\(comma)")
        }
        lines.append(contentsOf: ["    ]}", "  ],", "  \"usedImages\" : ["])
        let closing = ["  ]", "}"]
        // 剩下的行数全部由 usedImages 补齐 —— 苹果报告里最长的那一段就是它。
        let images = max(0, totalLines - lines.count - closing.count)
        for index in 0..<images {
            let comma = index == images - 1 ? "" : ","
            lines.append("    {\"index\":\(index),\"name\":\"libR11Filler\(index).dylib\",\"size\":4096}\(comma)")
        }
        lines.append(contentsOf: closing)
        return lines.joined(separator: "\n") + "\n"
    }

    /// 往假 DiagnosticReports 里写 `count` 份报告，`head` 决定报告主名（= 归属令牌要比对的那一段）。
    @discardableResult
    static func writeReports(in libraryLogs: URL, count: Int, lines: Int, head: String,
                             daysAgo: Double = 1) throws -> [URL] {
        let directory = libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true)
        let nameFormatter = DateFormatter()
        nameFormatter.locale = Locale(identifier: "en_US_POSIX")
        nameFormatter.dateFormat = "yyyy-MM-dd-HHmmss"
        var written: [URL] = []
        for index in 0..<count {
            let when = Date().addingTimeInterval(-daysAgo * 86_400 + Double(index) * 60)
            let name = "\(head)-\(nameFormatter.string(from: when)).ips"
            // incident id 每份都不同：同 id 会被台账当成"同一事件的另一份"并掉，
            // 那样"3 份 = 3 次"这条真值从构造那一刻起就不成立了。
            let incident = UUID().uuidString
            let url = directory.appendingPathComponent(name)
            try ipsText(procName: head, incident: incident, eventDate: when, totalLines: lines)
                .write(to: url, atomically: true, encoding: .utf8)
            written.append(url)
        }
        return written
    }

    /// 独立真值：数盘上的 0x0A 个数（`wc -l` 口径），不经过任何被测代码。
    static func newlineCount(of url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        return data.reduce(0) { $0 + ($1 == UInt8(ascii: "\n") ? 1 : 0) }
    }

    /// 合成一份 reading（不经磁盘），供聚合器层的判据使用。
    static func reading(role: LogFileRole, lines: Int, named: String) -> LogFileReading {
        LogFileReading(url: URL(fileURLWithPath: "/fixture/\(named)"), role: role,
                       sizeBytes: Int64(lines * 40), modifiedAt: Date(),
                       totalLines: lines, linesRead: lines, truncated: false,
                       events: [], parseErrors: 0)
    }
}
