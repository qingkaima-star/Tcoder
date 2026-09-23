import XCTest
@testable import TcoderMonitor

/// RD-60 第二半（R24）：**那一格真的有写者、真的有读者**。
///
/// 三段各钉一条真跑出来的等式。期望值一律取自 `CrashEvidenceFixture.plannedTruth`
/// ——「测试自己按计划放进夹具的东西相加」，不从被测实现读回来当期望。
///
/// 夹具落在仓库内 `.scratch/`（AGENTS §1.6），崩溃报告目录经 `TCODER_LIBRARY_LOGS_DIR`
/// 指到夹具里一个**空**目录 —— 真 `~/Library/Logs/DiagnosticReports` 一个字都不读（§-1 禁区）。
/// 夹具根自带真 `.git`：否则 `LogProjectIdentity` 会向上找到宿主仓库、夹具继承别人家的身份。
final class CrashEvidenceWiringTests: XCTestCase {
    private var scratch: URL!
    private var root: URL!

    private let windowDays = 7

    override func setUpWithError() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        scratch = packageRoot.deletingLastPathComponent()
            .appendingPathComponent(".scratch/r24-wiring-\(UUID().uuidString)", isDirectory: true)
        XCTAssertTrue(scratch.path.contains("/.scratch/"), "夹具不在仓库内 .scratch：\(scratch.path)")
        root = scratch.appendingPathComponent("ShopApp", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("fake-library-logs"
                                             + "/DiagnosticReports"), withIntermediateDirectories: true)
        try CrashEvidenceFixture.install(into: root)
        setenv("TCODER_LIBRARY_LOGS_DIR", scratch.appendingPathComponent("fake-library-logs").path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: scratch)
    }

    private func analyzeAgain() async throws -> (LogSummary, CrashEvidenceLedger) {
        try await FileLogAnalyzer().analyzeWithEvidence(projectRoot: root, extraLogURLs: [],
                                                        withinDays: windowDays)
    }

    // MARK: - 写者

    /// 九格**直传**：每一格都等于计划真值，且 `crashCount` 与 `crashEvidence.countedCrashCount`
    /// 同刻同源（同一次分析、同一个台账，没为凑字段开第二次遍历）。
    func test_writerPassesAllNineSlotsThroughInOnePass() async throws {
        let (summary, ledger) = try await analyzeAgain()
        let snapshot = try XCTUnwrap(summary.crashEvidence, "崩溃这一路跑过了 ⇒ 九格必须在盘上")
        let planned = CrashEvidenceFixture.plannedTruth
        print("【写者】快照 = \(CrashEvidenceFixture.describe(snapshot)) · 台账那句 = \(ledger.statement)")

        XCTAssertEqual(snapshot.countedCrashCount, planned.counted)
        XCTAssertEqual(snapshot.historicalConfirmedCount, planned.historical)
        XCTAssertEqual(snapshot.staleBuildConfirmedCount, planned.staleBuild)
        XCTAssertEqual(snapshot.undatedConfirmedCount, planned.undated)
        XCTAssertEqual(snapshot.suspectedCount, planned.suspected)
        XCTAssertEqual(snapshot.parseFailedCount, planned.parseFailed)
        XCTAssertEqual(snapshot.duplicateCount, planned.duplicates)
        // 这一枚夹具**没造**读不动的 ⇒ 必须是 0（"查过了、真的没有"），不许留 nil 也不许算成 1。
        XCTAssertEqual(snapshot.readFailedCount, planned.readFailed)
        XCTAssertEqual(snapshot.filesWithCountedEvidence, planned.filesWithCountedEvidence)

        XCTAssertEqual(summary.crashCount, snapshot.countedCrashCount,
                       "两枚读数说的不是同一次台账的同一格")
        XCTAssertEqual(snapshot.reasonCounts, ledger.reasonCounts,
                       "落盘的不是本次台账那些数 ⇒ 中途被换过尺子（或者算了两遍）")
    }

    /// 协议那一路（GUI 与 CLI 走的 `analyze`）也带着快照：RD-60 卡住的那座桥正是这里。
    func test_protocolPathCarriesTheSnapshot() async throws {
        let summary = try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: [],
                                                          withinDays: windowDays)
        let snapshot = try XCTUnwrap(summary.crashEvidence)
        XCTAssertEqual(snapshot.reasonCounts, CrashEvidenceFixture.plannedTruth.reasonCounts,
                       "`analyze` 交回的那一份没带上细账 ⇒ 视图与 CLI 还是只能读一把粗尺")
    }

    /// 读不动那一份单独钉（构造前提不成立时明说跳过，不许把"造不出来"报成"没有这种文件"）。
    func test_readFailedIsPassedThrough() async throws {
        let url = try CrashEvidenceFixture.writeLockedReport(into: root)
        guard (try? FileHandle(forReadingFrom: url)) == nil else {
            throw XCTSkip("当前进程仍能读 000 文件 ⇒ 造不出读取失败的前提，不是「没有读不动的报告」")
        }
        let (summary, _) = try await analyzeAgain()
        XCTAssertEqual(summary.crashEvidence?.readFailedCount, 1,
                       "读不动一份就说一份，且不许算成崩溃")
        // 夹具本来就带着计划里那一次确认崩溃 ⇒ 加了这份读不动的之后崩溃数**不许变**，
        // 这一条说的是"没核对的那一份不许冒充任何一态"。
        XCTAssertEqual(summary.crashCount, CrashEvidenceFixture.plannedTruth.counted,
                       "读不动的那一份被算进崩溃数了")
    }

    // MARK: - 读者（按名字接回）

    /// 齐全 ⇒ 逐字接回，措辞与台账那句**一字不差**（唯一生产者 `ReasonCounts.statement`）。
    func test_readerQuotesTheLedgerSentenceFromTheFields() async throws {
        let (summary, ledger) = try await analyzeAgain()
        let reading = try XCTUnwrap(CrashEvidenceReadout.readingFromFields(from: summary,
                                                                           windowDays: windowDays))
        XCTAssertEqual(reading.origin, .persistedFields)
        XCTAssertEqual(reading.separatedReasons, ledger.statement,
                       "从落盘接回的那句与台账那句分叉了 ⇒ 同一件事两把尺子")
        XCTAssertEqual(reading.filesWithCountedEvidence, ledger.countablePaths.count)
    }

    /// 任一格缺席 ⇒ **整枚** `Reading` 为 nil（那一版没统计过）；一格都不许被补成 0。
    func test_readerReturnsNilWhenAnySingleSlotIsAbsent() throws {
        var summary = LogSummary()
        summary.crashEvidence = CrashEvidenceSnapshot(countedCrashCount: 2, historicalConfirmedCount: 1,
                                                      staleBuildConfirmedCount: 3, undatedConfirmedCount: 4,
                                                      suspectedCount: 5, parseFailedCount: 6,
                                                      readFailedCount: 7, duplicateCount: 8,
                                                      filesWithCountedEvidence: 9)
        XCTAssertNotNil(CrashEvidenceReadout.readingFromFields(from: summary, windowDays: 7),
                        "前提：九格齐全时接得回来")
        for slot in CrashEvidenceFixture.nineSlots {
            let broken = try CrashEvidenceFixture.summaryByDeleting(summary, slot: slot)
            XCTAssertNil(CrashEvidenceReadout.readingFromFields(from: broken, windowDays: 7),
                         "删掉 \(slot) 之后仍然接得回来 ⇒ 那一格其实没被读（判据在数别的东西）")
            XCTAssertFalse(broken.crashEvidenceFootnote(windowDays: 7).contains("逐条原因如下"),
                           "缺一格就整枚不出声，不许拿其余八格拼一本残缺的账：" + slot)
        }
    }

    /// 不拿 `crashCount` 顶替：落盘那格说 1、`crashCount` 说 9 时，屏上必须说 1。
    func test_readerNeverSubstitutesCrashCount() throws {
        var summary = LogSummary()
        summary.crashCount = 9
        summary.crashEvidence = CrashEvidenceSnapshot(countedCrashCount: 1, historicalConfirmedCount: 0,
                                                      staleBuildConfirmedCount: 0, undatedConfirmedCount: 0,
                                                      suspectedCount: 0, parseFailedCount: 0,
                                                      readFailedCount: 0, duplicateCount: 0,
                                                      filesWithCountedEvidence: 1)
        let footnote = summary.crashEvidenceFootnote(windowDays: 7)
        XCTAssertTrue(footnote.contains("确认崩溃 1 次计入"), footnote)
        XCTAssertFalse(footnote.contains("9"), "把 crashCount 顶进来就是造一个没量过的数：" + footnote)
    }

    /// 整枚快照缺席（旧报告落盘时还没有这一格）⇒ 仍然说「本次未统计」，这一支不许被撤掉。
    func test_legacyReportStillSaysUnmeasured() throws {
        var summary = LogSummary()
        summary.crashCount = 2
        summary.scannedFiles = [ScannedLogFile(path: "/r/a.ips", sizeBytes: 10, lineCount: 5,
                                               modifiedAt: Date(), role: .crash)]
        XCTAssertNil(CrashEvidenceReadout.readingFromFields(from: summary, windowDays: 7))
        let footnote = summary.crashEvidenceFootnote(windowDays: 7)
        XCTAssertTrue(footnote.contains("本次未统计"), footnote)
        XCTAssertFalse(footnote.contains("逐条原因如下"), "没统计过就不许冒出一本账：" + footnote)
    }

    // MARK: - 屏上与 CLI（同一个装配口的两个出口）

    /// 视图 ⓘ 那一行调用点读到的产物：八种原因**逐条分开**上屏，不再是一个合成数。
    func test_screenReadsEveryReasonSeparated() async throws {
        let (summary, _) = try await analyzeAgain()
        // 这一行与 `Views/Logs/LogsMetricGrid.swift` 里的表达式同形（不传 evidence ⇒ 走落盘九格）。
        let footnote = summary.crashEvidenceFootnote(windowDays: windowDays)
        print("【屏上】\(footnote)")
        for phrase in CrashEvidenceFixture.plannedTruth.screenPhrases {
            XCTAssertTrue(footnote.contains(phrase), "少一格就不叫逐条分开：\(phrase) ∉ " + footnote)
        }
        XCTAssertFalse(footnote.contains("待 LogSummary 落盘"), "RD-60 ③ 那句假话不许长回来：" + footnote)
    }

    /// `score` 的文本读数问得到**同一句**（同一条装配口，两处不许各拼一份中文）。
    func test_cliScoreAsksTheSameSentenceThroughTheSameAssemblyPoint() async throws {
        let (summary, _) = try await analyzeAgain()
        var report = ProjectReport(project: MonitoredProject(name: "ShopApp", path: root.path))
        report.logs = summary
        XCTAssertEqual(CLIScoreText.crashEvidenceLines(report, windowDays: windowDays).first,
                       summary.crashEvidenceFootnote(windowDays: windowDays),
                       "CLI 与界面读的不是同一句 ⇒ 第二把尺子回来了")
        XCTAssertTrue(CLIScoreText.render(report, exit: .ok, windowDays: 30).contains("最近 30 天为窗口"),
                      "窗口天数没传到 CLI ⇒ 会说出一句与本次扫描范围不同的话")
    }

    /// 没有崩溃可说时 CLI **一行都不打**（凭空造一句"没账"就是把 CLI 写成第二个真值来源）。
    func test_cliStaysSilentWithoutCrashEvidence() {
        var report = ProjectReport(project: MonitoredProject(name: "x", path: "/tmp/x"))
        report.logs = LogSummary()
        XCTAssertTrue(CLIScoreText.crashEvidenceLines(report, windowDays: 7).isEmpty,
                      "零崩溃证据的项目不该被塞一行空账")
        report.logs?.crashCount = 3
        XCTAssertEqual(CLIScoreText.crashEvidenceLines(report, windowDays: 7).count, 1)
    }
}

// MARK: - 共用夹具（写者/读者/对表三处都用它，计划真值只这一份）

/// 一份把八种原因里七种各造一份的崩溃证据总体。期望数字**只写在这里一次**，
/// 谁再抄一份数字进自己的用例，就是给同一件事配第二把尺子。
enum CrashEvidenceFixture {
    struct Planned: Equatable {
        var counted: Int
        var historical: Int
        var staleBuild: Int
        var undated: Int
        var suspected: Int
        var parseFailed: Int
        var readFailed: Int
        var duplicates: Int
        var filesWithCountedEvidence: Int

        var reasonCounts: CrashEvidenceReadout.ReasonCounts {
            CrashEvidenceReadout.ReasonCounts(counted: counted, historical: historical,
                                              staleBuild: staleBuild, undated: undated,
                                              suspected: suspected, parseFailed: parseFailed,
                                              readFailed: readFailed, duplicates: duplicates)
        }

        /// 屏上该逐条出现的那几句（真值来自计划，不来自实现）。
        var screenPhrases: [String] {
            ["确认崩溃 \(counted) 次计入", "历史报告 \(historical) 次在窗口外",
             "旧构建 \(staleBuild) 次未算当前版本", "无事件时间 \(undated) 次单列",
             "疑似报告 \(suspected) 份", "解析失败 \(parseFailed) 份",
             "同一事件去重合并 \(duplicates) 份"]
        }
    }

    /// 计划真值：事件时间刻意离窗口边界远（1 天 / 40 天），不因跨分钟而失真。
    static let plannedTruth = Planned(counted: 1, historical: 1, staleBuild: 1, undated: 1,
                                      suspected: 1, parseFailed: 1, readFailed: 0, duplicates: 1,
                                      filesWithCountedEvidence: 1)

    static let nineSlots = ["countedCrashCount", "historicalConfirmedCount", "staleBuildConfirmedCount",
                            "undatedConfirmedCount", "suspectedCount", "parseFailedCount",
                            "readFailedCount", "duplicateCount", "filesWithCountedEvidence"]

    /// 计划真值按格子名摊平（对表那一路比的是**落盘 JSON 的格子**，不是内存里的结构体）。
    static var plannedSlots: [String: Int] {
        let p = plannedTruth
        return ["countedCrashCount": p.counted,
                "historicalConfirmedCount": p.historical,
                "staleBuildConfirmedCount": p.staleBuild,
                "undatedConfirmedCount": p.undated,
                "suspectedCount": p.suspected,
                "parseFailedCount": p.parseFailed,
                "readFailedCount": p.readFailed,
                "duplicateCount": p.duplicates,
                "filesWithCountedEvidence": p.filesWithCountedEvidence]
    }

    /// 建总体：真 `.git` + 两份 Swift 源码 + 七种崩溃证据各一份。
    static func install(into root: URL) throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"),
                                                withIntermediateDirectories: true)
        try "import Foundation\n\nenum Cart { static func total(_ n: Int) -> Int { n * 2 } }\n"
            .write(to: root.appendingPathComponent("Sources/Cart.swift"), atomically: true, encoding: .utf8)
        try "import Foundation\n\nenum Ledger { static func sum(_ n: Int) -> Int { n + 1 } }\n"
            .write(to: root.appendingPathComponent("Sources/Ledger.swift"), atomically: true, encoding: .utf8)
        // 真仓库：`LogProjectIdentity` 的锚点与 `ShellGitAnalyzer` 的读数都要它（空目录的假 .git 会让
        // 对表那一路的 Git 段两边同时失败，量不出东西来）。
        try run(["init", "-q", "."], in: root)
        try run(["config", "user.name", "R24 Fixture"], in: root)
        try run(["config", "user.email", "r24-fixture@tcoder.local"], in: root)
        try run(["add", "-A"], in: root)
        try run(["commit", "-qm", "fixture"], in: root)

        let reports = root.appendingPathComponent("Reports", isDirectory: true)
        try write(reports.appendingPathComponent("ShopApp-\(fileNameStamp())-cur.ips"),
                  ipsText(incident: "AAA1"))                                        // 计入
        try write(reports.appendingPathComponent("ShopApp-\(fileNameStamp())-hist.ips"),
                  ipsText(incident: "BBB2", daysAgo: 40))                            // 窗口外
        try write(reports.appendingPathComponent("ShopApp-\(fileNameStamp())-old.ips"),
                  ipsText(incident: "CCC3", version: "1.9 (8)"))                     // 旧构建
        try write(reports.appendingPathComponent("ShopApp-\(fileNameStamp())-dupe.ips"),
                  ipsText(incident: "AAA1"))                                         // 同一事件另一份
        try write(reports.appendingPathComponent("ShopApp-\(fileNameStamp())-garbage.ips"),
                  "这里没有任何报告字段\nINFO 一切正常\n")                              // 疑似
        let broken = ipsText(incident: "DDD4")
        try write(reports.appendingPathComponent("ShopApp-\(fileNameStamp())-broken.ips"),
                  String(broken.prefix(broken.count / 2)) + "\n<<<TRUNCATED")        // 解析失败
        try write(root.appendingPathComponent("Logs/undated_crash.log"), """
        Incident Identifier: EEE5
        Exception Type:      EXC_CRASH (SIGABRT)
        Termination Reason:  Namespace SIGNAL, Code 6
        Thread 3 Crashed:
        0   ShopApp  0x0000000102040000 ShopAppCache.flush() + 128 (Cache.swift:41)
        """)                                                                          // 无事件时间
    }

    /// 一份读不动的报告（000 权限）。前提能不能构造出来由调用方判（见 `test_readFailedIsPassedThrough`）。
    static func writeLockedReport(into root: URL) throws -> URL {
        let url = root.appendingPathComponent("Reports/ShopApp-\(fileNameStamp())-locked.ips")
        try write(url, ipsText(incident: "FFF6"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        return url
    }

    static func write(_ url: URL, _ text: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 一份结构完整的 .ips ⇒ 真值一次确认崩溃。mtime 留刚刚：发现只看 mtime，窗口只看事件时间。
    static func ipsText(incident: String, version: String = "2.0 (9)", daysAgo: Double = 1) -> String {
        """
        {"app_name":"ShopApp","app_version":"\(version)","bug_type":"309","incident_id":"\(incident)","os_version":"macOS 26.5.1 (25F80)","timestamp":"\(dateString(daysAgo: daysAgo))","version":2}
        {"procName":"ShopApp","bundleID":"com.example.ShopApp","app_version":"\(version)","incident_id":"\(incident)","bug_type":"309","timestamp":"\(dateString(daysAgo: daysAgo))","os_version":"macOS 26.5.1 (25F80)","product":"MacBookPro18,3","exception":{"Type":"EXC_BAD_ACCESS","Signal":"SIGSEGV","Subtype":"KERN_INVALID_ADDRESS at 0x10"},"termination":{"reason":"Segmentation fault: 11","indicator":"SIGSEGV"},"crashedThread":0,"threads":[{"id":1,"triggered":true,"frames":[{"imageIndex":0,"symbol":"ShopAppStore.flush()"}]}],"usedImages":[{"name":"ShopApp"}]}
        """
    }

    static func dateString(daysAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    static func fileNameStamp(daysAgo: Double = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    static func describe(_ snapshot: CrashEvidenceSnapshot) -> String {
        nineSlots.map { slot in "\(slot)=\(String(describing: snapshot[slot]))" }.joined(separator: " ")
    }

    /// 编码 → 删掉快照里的一格 → 再解码（模拟"那一版根本没统计过这一格"的旧报告形状）。
    static func summaryByDeleting(_ summary: LogSummary, slot: String) throws -> LogSummary {
        let data = try JSONEncoder().encode(summary)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var snapshot = try XCTUnwrap(object["crashEvidence"] as? [String: Any])
        _ = try XCTUnwrap(snapshot.removeValue(forKey: slot), "夹具里没有 \(slot) 这一格，删了个空的")
        object["crashEvidence"] = snapshot
        return try JSONDecoder().decode(LogSummary.self,
                                        from: try JSONSerialization.data(withJSONObject: object))
    }

    private static func run(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments.joined(separator: " ")) 失败")
    }
}

extension CrashEvidenceSnapshot {
    /// 九格按名字的读数（只给测试用：删哪一格、还剩哪几格，都要能点名）。
    /// 名单只有 `CrashEvidenceFixture.nineSlots` 一份，这里按它取值。
    subscript(_ slot: String) -> Int? {
        switch slot {
        case "countedCrashCount": return countedCrashCount
        case "historicalConfirmedCount": return historicalConfirmedCount
        case "staleBuildConfirmedCount": return staleBuildConfirmedCount
        case "undatedConfirmedCount": return undatedConfirmedCount
        case "suspectedCount": return suspectedCount
        case "parseFailedCount": return parseFailedCount
        case "readFailedCount": return readFailedCount
        case "duplicateCount": return duplicateCount
        case "filesWithCountedEvidence": return filesWithCountedEvidence
        default: return nil
        }
    }
}
