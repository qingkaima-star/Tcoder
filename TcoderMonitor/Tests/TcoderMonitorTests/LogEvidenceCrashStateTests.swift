import XCTest
@testable import TcoderMonitor

/// R4 · 崩溃证据四态与时间窗口（RD-21 / RD-22，台账 §6.2）。
///
/// 夹具全部在本用例自己造的临时目录里，**不读真机的 `~/Library/Logs/DiagnosticReports`**
/// （那是全机所有 App 的报告，含别的工程 —— AGENTS §-1 禁区）。
/// 每条用例的期望值都写在注释里当**独立真值**，不拿被测实现的输出当真值。
final class LogEvidenceCrashStateTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("r4-crash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: root.appendingPathComponent("Logs/locked.log").path)
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: 夹具

    @discardableResult
    private func write(_ name: String, _ text: String, daysAgo: Double = 0) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let date = Date().addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        return url
    }

    /// Apple 风格的报告时刻字符串（窗口类用例不能写常量日期，否则随日历失真）。
    private func reportTime(daysAgo: Double = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private func fileNameTime(daysAgo: Double = 0) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    /// 一份结构完整的 .ips（真值：**一次确认崩溃**）。incident / 版本 / 事件时间都可换。
    private func ipsText(incident: String, version: String = "2.0 (9)", daysAgo: Double = 0) -> String {
        """
        {"app_name":"R4App","app_version":"\(version)","bug_type":"309","incident_id":"\(incident)","os_version":"macOS 26.5.1 (25F80)","timestamp":"\(reportTime(daysAgo: daysAgo))","version":2}
        {"procName":"R4App","bundleID":"com.example.R4App","app_version":"\(version)","incident_id":"\(incident)","bug_type":"309","timestamp":"\(reportTime(daysAgo: daysAgo))","os_version":"macOS 26.5.1 (25F80)","product":"MacBookPro18,3","exception":{"Type":"EXC_BAD_ACCESS","Signal":"SIGSEGV","Subtype":"KERN_INVALID_ADDRESS at 0x0000000000000010","Codes":"0x000000000000000d 0x0000000000000000"},"termination":{"reason":"Segmentation fault: 11","indicator":"SIGSEGV"},"crashedThread":0,"threads":[{"id":1,"triggered":true,"queue":"com.apple.main-thread","backtrace":{"frames":[{"imageIndex":0,"symbol":"R4AppStore.flush()","symbolLocation":64,"sourceLineInfo":{"file":"R4App/Store.swift","line":77}}]}},{"id":2,"triggered":false,"frames":[]}],"usedImages":[{"name":"R4App","base":4399955968,"size":49152}]}
        """
    }

    private func analyze(withinDays days: Int = 30, extra: [URL] = []) async throws -> LogSummary {
        try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: extra, withinDays: days)
    }

    /// `XCTAssertEqual` 的参数是不支持 async 的 autoclosure，所以这里先落一个本地值。
    private func analyzedCrashCount(withinDays days: Int = 30) async throws -> Int {
        try await analyze(withinDays: days).crashCount
    }

    private func ledger(withinDays days: Int = 30) async throws -> CrashEvidenceLedger {
        try await FileLogAnalyzer().analyzeWithEvidence(projectRoot: root, extraLogURLs: [],
                                                        withinDays: days).evidence
    }

    // MARK: 四态（RD-21）

    /// ① 真实崩溃：一次事件、有事件时间、进计数。
    func testRealReportIsConfirmedAndCounted() async throws {
        try write("Reports/R4App-\(fileNameTime()).ips", ipsText(incident: "A1A1A1A1-1111-2222-3333-444444444444"))
        let summary = try await analyze()
        XCTAssertEqual(summary.crashCount, 1, "一份完整的 EXC_BAD_ACCESS 报告 = 真值 1 次")
        let evidence = try await ledger()
        XCTAssertEqual(evidence.confirmedCount, 1)
    }

    /// ② 空文件：不是崩溃。它读成功了，只是没有任何事件证据 ⇒ 疑似（0 字节要说得出原因）。
    func testEmptyReportIsSuspectedNotACrash() async throws {
        try write("Reports/empty.ips", "")
        let evidence = try await ledger()
        XCTAssertEqual(evidence.suspectedCount, 1, "0 字节的 .ips 只能判疑似")
        XCTAssertEqual(evidence.confirmedCount, 0)
        XCTAssertEqual(evidence.records.first?.reason, "文件为空（0 字节），没有任何事件证据")
        let counted = try await analyzedCrashCount()
        XCTAssertEqual(counted, 0, "空文件一条崩溃都不许算")
    }

    /// ③ 内容损坏：形状是报告（有 incident_id 等机器字段）却取不出证据 ⇒ 解析失败。
    func testTruncatedReportIsParseFailedNotACrash() async throws {
        let text = ipsText(incident: "B2B2B2B2-1111-2222-3333-444444444444")
        try write("Reports/R4App-\(fileNameTime())-broken.ips", String(text.prefix(text.count / 2)) + "\n<<<TRUNCATED")
        let evidence = try await ledger()
        XCTAssertEqual(evidence.parseFailedCount, 1, "有报告字段但 JSON 断了 = 解析失败")
        XCTAssertEqual(evidence.confirmedCount, 0)
        XCTAssertTrue(evidence.records.first?.reason?.contains("取不出可用的崩溃事实") == true,
                      "解析失败必须带原因：\(evidence.records.first?.reason ?? "nil")")
        let counted = try await analyzedCrashCount()
        XCTAssertEqual(counted, 0)
    }

    /// ④ 只是名字像：内容是一句正常话 ⇒ 疑似，且要说得出为什么。
    func testGarbageIpsIsSuspectedWithReason() async throws {
        try write("Reports/R4App-\(fileNameTime())-garbage.ips", "这里没有任何报告字段\nINFO 一切正常\n")
        let evidence = try await ledger()
        XCTAssertEqual(evidence.suspectedCount, 1)
        XCTAssertEqual(evidence.parseFailedCount, 0, "内容连报告形状都没有，不该说成解析失败")
        XCTAssertTrue(evidence.records.first?.reason?.contains("既没有报告字段也没有崩溃特征") == true)
    }

    /// ⑤ 读不动：读取失败单独一态，带系统给的原因。
    func testUnreadableReportIsReadFailedNotACrash() async throws {
        let url = try write("Reports/R4App-\(fileNameTime())-locked.ips",
                            ipsText(incident: "C3C3C3C3-1111-2222-3333-444444444444"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        guard (try? FileHandle(forReadingFrom: url)) == nil else {
            throw XCTSkip("当前进程仍能读 000 文件，构造不出读取失败前提")
        }
        let evidence = try await ledger()
        XCTAssertEqual(evidence.readFailedCount, 1, "读不动就是没核对，不许算成崩溃也不许算成零命中")
        XCTAssertEqual(evidence.confirmedCount, 0)
        XCTAssertFalse(evidence.records.filter { $0.state == .readFailed }.hasAnyMissing(\.reason),
                       "读取失败必须带原因")
        let counted = try await analyzedCrashCount()
        XCTAssertEqual(counted, 0)
    }

    /// ⑥ **少报那一半**：名字里带 diag 的普通日志不再被劫持进崩溃通道，它真实的错误行回到账上。
    ///
    /// 修前实测：`diagnostic.log` 进通道 → 合成 1 条假崩溃 + 它自己的 3 条 ERROR 全丢
    /// （`errorCount` 0，界面同时写"每千行 0 个错误"）。
    func testDiagnosticNamedLogKeepsItsOwnErrorLines() async throws {
        try write("diagnostic.log", """
        \(stamp(-1)) ERROR db pool exhausted while serving /orders
        \(stamp(-1)) INFO health probe ok
        \(stamp(-2)) ERROR socket timeout while calling payments
        \(stamp(-2)) WARN retry 1 of 3
        \(stamp(-20)) ERROR old failure outside the window
        """)
        let summary = try await analyze(withinDays: 7)
        XCTAssertEqual(summary.errorCount, 2, "窗口内 2 条 ERROR 必须在账上（第三条在窗口外）")
        XCTAssertEqual(summary.warningCount, 1)
        XCTAssertEqual(summary.infoLineCount, 1)
        XCTAssertEqual(summary.crashCount, 0, "普通日志一个字节的崩溃证据都没有，不许合成")
    }

    // MARK: 时间窗口（RD-22）

    /// ⑦ 新旧混合：窗口只按**事件时间**裁剪；mtime 不参与结论。
    func testWindowFiltersByEventTimeNotFileMtime() async throws {
        // mtime 全是刚刚（留在候选里），事件时间分别是一天前与四十天前
        try write("Reports/R4App-\(fileNameTime(daysAgo: 0)).ips",
                  ipsText(incident: "D4D4D4D4-1111-2222-3333-444444444444", daysAgo: 0))
        try write("Reports/R4App-\(fileNameTime(daysAgo: 0))-old.ips",
                  ipsText(incident: "E5E5E5E5-1111-2222-3333-444444444444", daysAgo: 40))
        let summary = try await analyze(withinDays: 7)
        XCTAssertEqual(summary.crashCount, 1, "7 天窗口只认事件时间：40 天前那次属历史报告")
        let evidence = try await ledger(withinDays: 7)
        XCTAssertEqual(evidence.historicalConfirmedCount, 1, "窗口外那份必须单列，不能静默丢")
        XCTAssertEqual(evidence.confirmedCount, 2, "两次都是真事件证据，只是不在同一个窗口")
    }

    /// ⑧ 无事件时间：确认崩溃但报告里没时间 ⇒ 单列，绝不拿 mtime 冒充。
    func testCrashWithoutEventTimeIsListedApartNotFaked() async throws {
        let undated = """
        Incident Identifier: F6F6F6F6-1111-2222-3333-444444444444
        Exception Type:      EXC_CRASH (SIGABRT)
        Termination Reason:  Namespace SIGNAL, Code 6
        Thread 3 Crashed:
        0   R4App  0x0000000102040000 R4AppCache.flush() + 128 (Cache.swift:41)
        """
        try write("Logs/undated_crash.log", undated)
        let evidence = try await ledger()
        XCTAssertEqual(evidence.confirmedCount, 1, "有崩溃类型与崩溃线程 = 确认崩溃")
        XCTAssertEqual(evidence.undatedConfirmedCount, 1, "但它没有事件时间，必须单列")
        let counted = try await analyzedCrashCount()
        XCTAssertEqual(counted, 0, "没有事件时间就不许算进任何窗口")
    }

    // MARK: 去重（C）

    /// ⑨ 同一事件的多份报告（逐字节副本 + 跨目录改名副本）只算一次。
    func testCopiesOfTheSameIncidentCountOnce() async throws {
        let text = ipsText(incident: "A7A7A7A7-1111-2222-3333-444444444444")
        try write("Reports/R4App-\(fileNameTime()).ips", text)
        try write("Reports/copies/a/R4App-\(fileNameTime()).ips", text)
        try write("Reports/copies/b/copy-of-same-event.ips", text)
        let evidence = try await ledger()
        XCTAssertEqual(evidence.confirmedCount, 1, "同 incident id 的三份是一份事件的三份报告")
        XCTAssertEqual(evidence.duplicateCount, 2)
        let counted = try await analyzedCrashCount()
        XCTAssertEqual(counted, 1, "真值 1 次，不是 3 次")
        XCTAssertTrue(evidence.duplicates.allSatisfy { $0.duplicateOf != nil },
                      "被并掉的每一份都要说得出并进了谁")
    }

    // MARK: 元测试（证明这些判定有牙，不是永真绿）

    /// 把证据字段摘干净后，同一份 .ips 必须**掉出**确认崩溃；
    /// 否则"只有确认崩溃才计数"这条判据其实没有判据。
    func testMetaStrippingEvidenceDowngradesTheState() async throws {
        let withEvidence = CrashReportParser.crashChannel(
            reading: try readingFor(text: ipsText(incident: "B8B8B8B8-1111-2222-3333-444444444444")))
        XCTAssertEqual(withEvidence.confirmedCount, 1, "夹具本身要先立住")

        let hollowed = """
        {"app_name":"R4App","app_version":"2.0 (9)","incident_id":"C9C9C9C9-1111-2222-3333-444444444444","version":2}
        {"procName":"R4App","incident_id":"C9C9C9C9-1111-2222-3333-444444444444","threads":[],"usedImages":[]}
        """
        let withoutEvidence = CrashReportParser.crashChannel(reading: try readingFor(text: hollowed))
        XCTAssertEqual(withoutEvidence.confirmedCount, 0,
                       "没有任何崩溃字段却仍判 confirmed ⇒ 判据是空的")
        XCTAssertEqual(withoutEvidence.records.first?.state, .parseFailed,
                       "有报告字段但取不出证据，应当降级成解析失败")
    }

    /// 分母闸：四态扫描必须真扫到东西。全 0 就是扫描面坏了，不许当"没有崩溃"通过。
    func testDenominatorIsNonZeroAcrossAllFourStates() async throws {
        try write("Reports/R4App-\(fileNameTime()).ips", ipsText(incident: "D0D0D0D0-1111-2222-3333-444444444444"))
        try write("Reports/empty.ips", "")
        let evidence = try await ledger()
        XCTAssertFalse(evidence.records.isEmpty, "一条记录都没扫到 = 扫描面坏了，不是没有崩溃")
        XCTAssertEqual(evidence.records.count, 2, "确认 1 + 疑似 1")
    }

    // MARK: 小工具

    private func stamp(_ days: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date().addingTimeInterval(days * 86_400))
    }

    private func readingFor(text: String) throws -> LogFileReading {
        let url = try write("tmp/\(UUID().uuidString).ips", text)
        let reading = LogReader.read(DiscoveredLog(url: url, role: .crash, sizeBytes: 1,
                                                  modifiedAt: Date()),
                                     maxBytes: 1_000_000, maxLines: 1_000)
        return reading
    }
}

private extension Array where Element == CrashEvidenceRecord {
    /// 有没有哪一条在这个字段上是 nil（缺原因 = 说不出为什么没算它）。
    func hasAnyMissing(_ keyPath: KeyPath<CrashEvidenceRecord, String?>) -> Bool {
        contains { $0[keyPath: keyPath] == nil }
    }
}

private extension CrashChannelOutcome {
    var confirmedCount: Int { records.filter { $0.state == .confirmed }.count }
}
