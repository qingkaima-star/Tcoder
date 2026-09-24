import Darwin
import XCTest
@testable import TcoderMonitor

/// RD-60 验收第一条（台账 §48）：**先让两把尺子互相复现**，再谈接线。
///
/// 两把尺子量的是同一句话 ——「窗口外历史确认崩溃 N 次」：
/// · **细账**：`CrashEvidenceLedger.historicalConfirmedCount` —— 去重后的记录，按**事件时间**裁窗口。
/// · **旧脚注**（本用例复现它）：`trend` 桶按事件时间分日再对 `crashes` 求和。
///
/// 期望值一律由**测试自己按夹具内容相加**得出（`plannedHistoricalTruth`），
/// 不从任何一把尺子读回来当期望。
///
/// 夹具落在**仓库内** `.scratch/`（AGENTS §1.6），崩溃报告经
/// `TCODER_LIBRARY_LOGS_DIR` 指到的假 `DiagnosticReports` 自动发现 ——
/// **不读**真 `~/Library/Logs/DiagnosticReports`（那里面有别的工程的报告，AGENTS §-1 禁区）。
final class CrashEvidenceRulerReproductionTests: XCTestCase {
    private var scratchBase: URL!
    private var root: URL!
    private var libraryLogs: URL!
    private var reports: URL!

    /// 与 `LogsMetricGrid.windowDays` 的默认值同档；事件时间取 40 天前 / 1 天前，
    /// 离窗口边界都很远，不会因为跨分钟级边界而失真。
    private let windowDays = 7
    private let farDays = 40.0
    private let nearDays = 1.0

    override func setUpWithError() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        scratchBase = packageRoot.deletingLastPathComponent()
            .appendingPathComponent(".scratch/r20-crashruler-\(UUID().uuidString)", isDirectory: true)
        // 夹具必须在仓库内、且必须不是真机日志目录（这两个条件错了，整份取证就不可信）。
        XCTAssertTrue(scratchBase.path.contains("/.scratch/"), "夹具不在仓库内 .scratch：\(scratchBase.path)")
        XCTAssertTrue(scratchBase.path.hasPrefix(packageRoot.deletingLastPathComponent().path))
        root = scratchBase.appendingPathComponent("ShopApp", isDirectory: true)
        libraryLogs = scratchBase.appendingPathComponent("fake-library-logs", isDirectory: true)
        reports = libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: reports, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
        // 锚点必须是夹具自己：不建这个 `.git`，`LogProjectIdentity` 会向上找到宿主仓库，
        // 归属令牌就变成宿主目录名 ⇒ 夹具继承别人家的身份（本仓踩过一次）。
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: scratchBase)
    }

    // MARK: 夹具

    private func stamp(daysAgo: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        return f.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private func fileStamp(daysAgo: Double) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    /// 一份结构完整的 .ips：真值 = **一次确认崩溃**，事件时间由 `daysAgo` 决定。
    /// mtime 一律留成刚刚（发现阶段按 mtime 筛候选，事件时间才是窗口判据）。
    /// `tag` 只进文件名：同一事件的多份副本必须各自留名，否则后写的会覆盖前一份，
    /// 夹具就悄悄从「三份」变成「一份」（真值当场失真）。
    private func writeReport(incident: String, version: String = "2.0 (9)", daysAgo: Double,
                             tag: String = "orig") throws {
        let header = #"{"app_name":"ShopApp","app_version":"\#(version)","bug_type":"309","incident_id":"\#(incident)","os_version":"macOS 26.5.1 (25F80)","timestamp":"\#(stamp(daysAgo: daysAgo))","version":2}"#
        let body = #"{"procName":"ShopApp","app_version":"\#(version)","incident_id":"\#(incident)","timestamp":"\#(stamp(daysAgo: daysAgo))","exception":{"Type":"EXC_BAD_ACCESS","Signal":"SIGSEGV","Subtype":"KERN_INVALID_ADDRESS at 0x0"},"threads":[{"id":1,"triggered":true,"frames":[{"imageIndex":0,"symbol":"ShopAppStore.flush()"}]}],"usedImages":[{"name":"ShopApp"}]}"#
        let url = reports.appendingPathComponent(
            "ShopApp-\(fileStamp(daysAgo: daysAgo))-\(incident.prefix(8))-\(tag).ips")
        try (header + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    }

    private func writeAppLog(_ body: String, name: String = "app.log") throws {
        let url = root.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
    }

    private func analyze() async throws -> (LogSummary, CrashEvidenceLedger) {
        try await FileLogAnalyzer().analyzeWithEvidence(projectRoot: root, extraLogURLs: [],
                                                       withinDays: windowDays)
    }

    // MARK: 独立真值与旧尺子的复现

    /// 独立真值：由**测试自己的事件时间表**相加 ——「计划放进夹具的确认崩溃事件时间」中
    /// 落在窗口外的那几份。跟被测实现没有任何关系。
    private func plannedHistoricalTruth(eventDaysAgo: [Double]) -> Int {
        eventDaysAgo.filter { $0 > Double(windowDays) }.count
    }

    /// 复现已删除的那把尺子：从**已落盘的趋势桶**按事件时间求和。
    /// 这就是 `crashEvidenceFootnote` 以前用来喊「另有 N 次确认崩溃…属历史报告」的算法。
    private func retiredTrendRuler(_ summary: LogSummary) -> Int {
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        return summary.trend.filter { $0.date < cutoff }.reduce(0) { $0 + $1.crashes }
    }

    private func report(_ scenario: String, truth: Int, fine: Int, retired: Int) -> String {
        "【\(scenario)】独立真值 \(truth) · 细账 historicalConfirmedCount \(fine) · 旧趋势桶尺子 \(retired)"
    }

    // MARK: ① 形状 A：窗口外一份真崩溃报告 ⇒ 旧尺子**漏报**

    func testShapeAHistoricalCrashReportIsMissedByTheTrendRuler() async throws {
        try writeReport(incident: "A1A1A1A1-1111-2222-3333-444444444444", daysAgo: farDays)
        try writeReport(incident: "A2A2A2A2-1111-2222-3333-444444444444", daysAgo: nearDays)
        let (summary, ledger) = try await analyze()

        let truth = plannedHistoricalTruth(eventDaysAgo: [farDays, nearDays])
        let fine = ledger.historicalConfirmedCount
        let retired = retiredTrendRuler(summary)
        let line = report("A 窗口外真崩溃报告", truth: truth, fine: fine, retired: retired)
        print(line)
        print("   细账原话：\(ledger.statement)")
        print("   趋势桶：\(summary.trend.map { "\($0.date)=crashes\($0.crashes)" }.sorted().joined(separator: " "))")

        XCTAssertFalse(ledger.records.isEmpty, "一份记录都没扫到 = 扫描面坏了，不是没有崩溃")
        XCTAssertFalse(summary.trend.isEmpty, "趋势桶全空 = 分母坏了，本用例失效")
        XCTAssertEqual(truth, 1, "真值由夹具自述：两份里恰好一份在 7 天窗口之外")
        XCTAssertEqual(ledger.confirmedCount, 2, "两次都是真事件证据")
        XCTAssertEqual(fine, truth, "细账与真值相符")
        XCTAssertNotEqual(retired, truth,
                          "两把尺子在这个总体上**不等**：旧尺子读 \(retired)，真值 \(truth)。" + line)
        XCTAssertTrue(retired < fine, "旧尺子这一边是漏报（窗口外的崩溃事件根本进不了趋势桶）：" + line)
    }

    /// 为什么漏：窗口外的崩溃事件既被 `crashHandledPaths` 挡掉了行解析，
    /// 又因为不在 `countablePaths` 里而被 `extraEvents` 挡在聚合器之外 ⇒ 趋势桶里根本没有它。
    /// 这条把机制钉死（哪天通道改法让事件进了桶，这条会先红，届时该改的是脚注而不是这条）。
    func testShapeAMechanismHistoricalEventNeverReachesTrendBuckets() async throws {
        try writeReport(incident: "A3A3A3A3-1111-2222-3333-444444444444", daysAgo: farDays)
        let (summary, ledger) = try await analyze()
        XCTAssertEqual(ledger.historicalConfirmedCount, 1, "细账看得见那一份历史报告")
        XCTAssertEqual(summary.crashCount, 0, "它确实不该进窗口内计数")
        XCTAssertEqual(retiredTrendRuler(summary), 0,
                       "趋势桶对它一字未记 ⇒ 旧脚注那句「另有 N 次属历史报告」永远不会出声")
    }

    // MARK: ② 形状 B：窗口外一条普通 FATAL 行 ⇒ 旧尺子**虚报**

    func testShapeBHistoricalFatalLineIsCountedAsACrashByTheTrendRuler() async throws {
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        func iso(_ daysAgo: Double) -> String {
            day.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
        }
        try writeAppLog("""
        \(iso(farDays)) FATAL db connection pool leaked beyond hard limit
        \(iso(nearDays)) ERROR payments socket timeout while calling upstream
        """)
        let (summary, ledger) = try await analyze()

        // 真值：崩溃通道里一份报告都没有 ⇒ 窗口外的「历史确认崩溃」真值是 0。
        // 普通日志里的 FATAL 行不是崩溃事件证据（`CrashEvidenceState.confirmed` 才是，
        // 而这个文件连崩溃通道候选都不是）。
        let truth = 0
        let fine = ledger.historicalConfirmedCount
        let retired = retiredTrendRuler(summary)
        let line = report("B 窗口外 FATAL 行", truth: truth, fine: fine, retired: retired)
        print(line)
        print("   趋势桶：\(summary.trend.map { "\($0.date)=crashes\($0.crashes)" }.sorted().joined(separator: " "))")

        XCTAssertFalse(summary.trend.isEmpty, "分母闸：一个桶都没扫到 ⇒ 本用例失效")
        XCTAssertGreaterThan(retiredTrendRuler(summary), 0, "分母闸：这条 FATAL 行得真的进过桶，否则比了个空")
        XCTAssertEqual(fine, truth, "细账不把 FATAL 行说成崩溃")
        XCTAssertNotEqual(retired, truth,
                          "两把尺子在这个总体上**不等**，而且方向与形状 A 相反：旧尺子把一条普通日志的 "
                          + "FATAL 行喊成「确认崩溃属历史报告」。因为 `LogClustering.buckets` 把 "
                          + ".crash 与 .fatal 折进同一个 `crashes` 格：" + line)
    }

    // MARK: ③ 形状 C：全都落在窗口内 ⇒ 两把尺子**恰好相等**（证明上面两条不是永真不等）

    func testShapeCInWindowDuplicatesMakeTheTwoRulersAgree() async throws {
        let incident = "A7A7A7A7-1111-2222-3333-444444444444"
        try writeReport(incident: incident, daysAgo: nearDays, tag: "one")
        try writeReport(incident: incident, daysAgo: nearDays, tag: "two")
        try writeReport(incident: incident, daysAgo: nearDays, tag: "three")
        let (summary, ledger) = try await analyze()

        let truth = plannedHistoricalTruth(eventDaysAgo: [nearDays, nearDays, nearDays])
        let fine = ledger.historicalConfirmedCount
        let retired = retiredTrendRuler(summary)
        let line = report("C 窗口内三份重复", truth: truth, fine: fine, retired: retired)
        print(line)
        print("   细账原话：\(ledger.statement)")

        XCTAssertEqual(truth, 0)
        XCTAssertEqual(fine, truth)
        XCTAssertEqual(retired, truth,
                       "相等**只在这样的夹具下成立**：窗口外一份事件都没有。"
                       + "换形状 A（窗口外放真崩溃报告）它就漏报、换形状 B（窗口外放 FATAL 行）它就虚报：" + line)
        XCTAssertEqual(ledger.duplicateCount, 2, "去重合并这件事本身要仍然数得出来")
        XCTAssertEqual(ledger.confirmedCount, 1, "三份报告是一份事件的三份报告，不是三次崩溃")
        XCTAssertEqual(summary.crashReportCount, 3, "分母闸：三份报告得真被发现，否则相等是空的")
    }

    // MARK: ④ 形状 D：旧构建 ⇒ 细账点名原因，旧脚注只能并成一个「未产出证据」的数

    func testShapeDStaleBuildIsNamedByTheLedgerOnly() async throws {
        try writeReport(incident: "D1D1D1D1-1111-2222-3333-444444444444",
                        version: "1.0 (1)", daysAgo: nearDays)
        try writeReport(incident: "D2D2D2D2-1111-2222-3333-444444444444",
                        version: "2.0 (9)", daysAgo: 0)
        let (summary, ledger) = try await analyze()
        print("   细账原话：\(ledger.statement)")
        print("   未测准：\(ledger.unknownStatement ?? "nil")")

        XCTAssertEqual(ledger.currentBuildKey, "2.0 (9)", "事件时间最新的那个版本算当前构建")
        XCTAssertEqual(ledger.staleBuildConfirmedCount, 1, "1.0 (1) 那次要单列成旧构建")
        XCTAssertEqual(ledger.countedCrashCount, 1)
        XCTAssertEqual(ledger.historicalConfirmedCount, 0, "两份都在窗口内 ⇒ 与历史无关")
        XCTAssertTrue(ledger.statement.contains("旧构建 1 次未算当前版本"),
                      "这一条原因只有细账说得出，旧脚注会把它并进一个合起来的份数：" + ledger.statement)

        let withLedger = summary.crashEvidenceFootnote(windowDays: windowDays, evidence: ledger)
        print("   接上细账的脚注：\(withLedger)")
        XCTAssertTrue(withLedger.contains("旧构建 1 次未算当前版本"),
                      "屏上那句必须逐字来自细账：" + withLedger)
        XCTAssertFalse(withLedger.contains("待 LogSummary 落盘"),
                       "RD-60 ③：账早算完了，不许再留一句欠账还没算的假话：" + withLedger)
    }
}
