import Darwin
import XCTest
@testable import TcoderMonitor

/// R4 · 应用与构建归属（RD-23）+ 稳定性输入（RD-24）。
///
/// 归属那几条必须走 `TCODER_LIBRARY_LOGS_DIR` 指到的**假目录**：
/// 真机的 `~/Library/Logs/DiagnosticReports` 里是全机所有 App 的报告，
/// 读它既违反 AGENTS §-1 禁区，也会让结果绑到这台机器上。
final class LogEvidenceIdentityAndStabilityTests: XCTestCase {
    private var root: URL!
    private var libraryLogs: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("r4-identity-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("ShopApp", isDirectory: true)
        libraryLogs = base.appendingPathComponent("fake-library-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true),
            withIntermediateDirectories: true)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
    }

    override func tearDownWithError() throws {
        unsetenv("TCODER_LIBRARY_LOGS_DIR")
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    // MARK: 夹具小工具

    private func write(_ name: String, _ text: String) throws {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// 锚点靠 `.git` 认，因此夹具树要在**项目根**放一个 `.git`；
    /// 少了它，扫子目录就解不出同一个锚点（那正是整改前"按目录名猜项目"的形状）。
    private func makeGitAnchor() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"),
                                                withIntermediateDirectories: true)
    }

    private func writePackageManifest(products: [String]) throws {
        try makeGitAnchor()
        let body = products.map { "target(name: \"\($0)\")" }.joined(separator: ", ")
        try "// swift-tools-version:6.0\nlet package = Package(name: \"ShopApp\", targets: [\(body)])\n"
            .write(to: root.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
    }

    private func writeReport(_ procName: String, version: String, incident: String,
                             daysAgo: Double = 0, inProjectTree: Bool = false) throws {
        let header = #"{"app_name":"\#(procName)","app_version":"\#(version)","bug_type":"309","incident_id":"\#(incident)","os_version":"macOS 26.5.1 (25F80)","timestamp":"\#(reportTime(daysAgo: daysAgo))","version":2}"#
        let body = #"{"procName":"\#(procName)","app_version":"\#(version)","incident_id":"\#(incident)","timestamp":"\#(reportTime(daysAgo: daysAgo))","exception":{"Type":"EXC_BAD_ACCESS","Signal":"SIGSEGV","Subtype":"KERN_INVALID_ADDRESS at 0x0"},"threads":[{"id":1,"triggered":true,"frames":[{"imageIndex":0,"symbol":"\#(procName)Store.flush()"}]}],"usedImages":[{"name":"\#(procName)"}]}"#
        let directory = inProjectTree
            ? root.appendingPathComponent("Reports", isDirectory: true)
            : libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(procName)-\(fileNameTime(daysAgo: daysAgo)).ips")
        try (header + "\n" + body).write(to: url, atomically: true, encoding: .utf8)
    }

    private func reportTime(daysAgo: Double) -> String { dateText("yyyy-MM-dd HH:mm:ss ZZZZ", daysAgo) }
    private func fileNameTime(daysAgo: Double) -> String { dateText("yyyy-MM-dd-HHmmss", daysAgo) }
    private func dateText(_ format: String, _ daysAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = format
        return formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private func identity() -> LogProjectIdentity { LogProjectIdentity.resolve(scanRoot: root) }

    private func ledger(days: Int = 30) async throws -> CrashEvidenceLedger {
        try await FileLogAnalyzer().analyzeWithEvidence(projectRoot: root, extraLogURLs: [],
                                                        withinDays: days).evidence
    }

    // MARK: D · 归属显式绑定（RD-23）

    /// 产品名来自 `Package.swift` 的声明，不来自目录名 —— 目录改名也不该改变归属判定。
    func testIdentityUsesDeclaredProductNames() throws {
        try writePackageManifest(products: ["ShopKit"])
        let tokens = identity().attributionTokens
        XCTAssertTrue(tokens.contains("shopkit"), "声明的产品名必须进令牌集：\(tokens)")
        XCTAssertTrue(tokens.contains("shopapp"), "锚点目录名仍然算一个令牌：\(tokens)")
    }

    /// ⑩ **扫仓库根与扫子目录得到同一份自动输入**（这条是 RD-23 的正面判据）。
    func testScanningRootAndSubdirectoryYieldTheSameInput() throws {
        try writePackageManifest(products: ["ShopKit"])
        let sub = root.appendingPathComponent("Sources/App", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertEqual(LogProjectIdentity.resolve(scanRoot: sub), identity(),
                       "同一个项目的子目录必须解出同一个身份（整改前取 lastPathComponent，两者不同）")
    }

    /// 只有自己的报告算自己的：别人的 App、前缀相近的 Helper 都不许进来。
    func testOtherAppsReportsAreNeverAttributed() async throws {
        try writePackageManifest(products: [])
        try writeReport("ShopApp", version: "2.0 (9)", incident: "A1A1A1A1-1111-2222-3333-444444444444")
        try writeReport("SomeOtherApp", version: "9.9 (9)", incident: "B2B2B2B2-1111-2222-3333-444444444444")
        try writeReport("ShopAppHelper", version: "3.3 (3)", incident: "C3C3C3C3-1111-2222-3333-444444444444")
        let summary = try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
        XCTAssertEqual(summary.crashCount, 1, "三份报告里只有一份属于这个项目")
        let evidence = try await ledger()
        XCTAssertEqual(evidence.confirmedCount, 1)
    }

    /// 旧构建的确认崩溃**不算当前版本缺陷**：只在确实出现两个版本时才分桶，
    /// 单版本时明说"无法区分新旧"，不默认成当前。
    func testOldBuildCrashIsNotCountedAsCurrentDefect() async throws {
        try writePackageManifest(products: [])
        try writeReport("ShopApp", version: "1.0 (1)", incident: "D4D4D4D4-1111-2222-3333-444444444444", daysAgo: 2)
        try writeReport("ShopApp", version: "2.0 (9)", incident: "E5E5E5E5-1111-2222-3333-444444444444", daysAgo: 1)
        let evidence = try await ledger()
        XCTAssertEqual(evidence.currentBuildKey, "2.0 (9)", "事件时间更新的那个版本是当前构建")
        XCTAssertEqual(evidence.staleBuildConfirmedCount, 1, "1.0 (1) 那次要单列")
        XCTAssertEqual(evidence.confirmedCount, 2, "两次都是真事件证据")
        XCTAssertEqual(evidence.countedCrashCount, 1, "进扣分的只有当前构建那一次")
    }

    /// 只有一个版本时不许装作"知道它是当前版本"。
    func testSingleVersionSaysItCannotTellOldFromNew() async throws {
        try writePackageManifest(products: [])
        try writeReport("ShopApp", version: "2.0 (9)", incident: "F6F6F6F6-1111-2222-3333-444444444444")
        let evidence = try await ledger()
        XCTAssertNil(evidence.currentBuildKey)
        XCTAssertTrue(evidence.unknownStatement?.contains("新旧无法区分") == true,
                      "要说出为什么不能区分，实得 \(evidence.unknownStatement ?? "nil")")
        XCTAssertEqual(evidence.countedCrashCount, 1, "不能区分不等于不算 —— 那是另一种隐藏")
    }

    /// 报告自报的五个归属维度都要留档；缺哪一维报哪一维。
    func testIdentityDimensionsComeFromTheReportItself() async throws {
        try writePackageManifest(products: [])
        try writeReport("ShopApp", version: "2.0 (9)", incident: "A7A7A7A7-1111-2222-3333-444444444444")
        let record = try await ledger().records.first
        XCTAssertEqual(record?.identity.processName, "ShopApp")
        XCTAssertEqual(record?.identity.appVersion, "2.0 (9)")
        XCTAssertEqual(record?.identity.buildVersion, "9", "括号里的构建号要单独留着")
        XCTAssertEqual(record?.identity.osVersion, "macOS 26.5.1 (25F80)", "采集环境")
        XCTAssertTrue(record?.hasEventTime == true, "有 timestamp 就该有事件时间")
    }

    /// RD-60 的第一条验收：**两把尺子先互相复现**，再谈契约。
    ///
    /// 精细那把是 `CrashEvidenceLedger`（四态逐条），粗的那把是界面现在能读的
    /// `LogSummary` 近似（`scannedFiles` 里 role == .crash 的份数 − `crashCount`）。
    /// 两把分母不同（一份报告可能含多次崩溃、副本各占一个文件），所以不许要求相等，
    /// 但**必须**要求：计入次数两边同一个数；且粗尺的差额 ≥ 细尺里"没算的那几态"之和
    /// —— 差额小于细账就是界面把没算的事说小了（那条红线比"不等"严重）。
    func testCoarseRulerReproducesTheFineLedger() async throws {
        try writePackageManifest(products: [])
        try writeReport("ShopApp", version: "2.0 (9)", incident: "A1A1A1A1-1111-2222-3333-444444444444")
        try writeReport("ShopApp", version: "2.0 (9)", incident: "B2B2B2B2-1111-2222-3333-444444444444",
                        daysAgo: 40)
        try write("Reports/empty.ips", "")
        let (summary, evidence) = try await FileLogAnalyzer()
            .analyzeWithEvidence(projectRoot: root, extraLogURLs: [], withinDays: 7)
        XCTAssertEqual(summary.crashCount, evidence.countedCrashCount,
                       "两把尺子的「计入了几次」必须是同一个数")
        let coarseChannelFiles = summary.scannedFiles.filter { $0.role == .crash }.count
        let uncounted = evidence.suspectedCount + evidence.parseFailedCount
            + evidence.undatedConfirmedCount + evidence.historicalConfirmedCount
            + evidence.staleBuildConfirmedCount + evidence.duplicateCount
        XCTAssertGreaterThanOrEqual(coarseChannelFiles, uncounted + evidence.countedCrashCount,
                                    "粗尺看到的崩溃通道文件数少于一件件数得来的总和 ⇒ 有一把在漏")
        XCTAssertTrue(summary.crashEvidenceFootnote(windowDays: 7).contains("未产出可计数的证据"),
                      "差额要在屏上出声，不能只活在细账里")
    }

    // MARK: E · 稳定性输入（RD-24）

    private func logsFixture(errors: Int, lines: Int) -> LogSummary {
        var logs = LogSummary()
        logs.totalLinesScanned = lines
        logs.errorCount = errors
        logs.warningCount = 0
        logs.exceptionCount = 0
        logs.crashCount = 0
        logs.fatalCount = 0
        logs.scannedFiles = [ScannedLogFile(path: "/tmp/x/app.log", sizeBytes: 1, lineCount: lines,
                                            modifiedAt: Date(), role: .application)]
        return logs
    }

    private func stabilityScore(codeLines: Int, errors: Int = 40, logLines: Int = 20_000) -> Int {
        var code = CodeMetrics()
        code.codeLines = codeLines
        return WeightedHealthScorer().score(HealthInputs(code: code, logs: logsFixture(errors: errors,
                                                                                       lines: logLines)))
            .components.first { $0.name == HealthDimension.stability.rawValue }?.score ?? -1
    }

    /// **反向不变式**：加代码量不得让同样的错误数显得更稳定。
    ///
    /// 这条改前必红：分母是源码行数时，40 个错误在 1 万行代码下是每千行 4 个（约 52 分），
    /// 在 10 万行下是每千行 0.4 个（约 93 分）—— 一行运行期证据都没变，分数白涨 40 分。
    func testAddingCodeDoesNotMakeTheSameErrorsLookStabler() {
        let small = stabilityScore(codeLines: 10_000)
        let large = stabilityScore(codeLines: 100_000)
        XCTAssertNotEqual(small, -1, "稳定维要真的参与计分，否则这条是假绿")
        XCTAssertEqual(small, large, "同一批运行期证据、只把代码行数放大十倍，分数必须一字不动")
    }

    /// 换分母之后密度仍然随证据变化：错误变多要掉分（证明不是把它抹平成常数）。
    func testLogLineDensityStillMovesTheScore() {
        let few = HealthCurves.stability(errorsPerKiloLogLines: 0.5, crashCount: 0, fatalCount: 0,
                                         exceptionCount: 0, totalLinesScanned: 20_000)
        let many = HealthCurves.stability(errorsPerKiloLogLines: 12, crashCount: 0, fatalCount: 0,
                                          exceptionCount: 0, totalLinesScanned: 20_000)
        XCTAssertGreaterThan(few.score, many.score, "每千行日志的错误密度必须还能推动分数")
        XCTAssertTrue(few.detail.contains("每千行日志"), "读数要写清分母是谁：\(few.detail)")
    }

    /// 缺运行时长 / 请求量时，评分卡要出"事实 + 证据不足"，而不是一个光秃秃的分。
    func testMissingRuntimeExposureIsDisclosedAsEvidenceGap() {
        var code = CodeMetrics()
        code.codeLines = 30_000
        let score = WeightedHealthScorer().score(HealthInputs(code: code,
                                                              logs: logsFixture(errors: 40, lines: 20_000)))
        XCTAssertTrue(score.recommendations.contains { $0.contains("证据不足") && $0.contains("运行时长") },
                      "缺的是哪一维证据要点名，实得 \(score.recommendations)")
    }

    /// 崩溃通道里有文件却没产出可计数证据时，脚注要说出这个差额**并且说得出是哪一种原因**。
    ///
    /// RD-60 把这条从「只断言含『未产出可计数的证据』」加强成「必须点出 0 字节这一种原因」：
    /// 旧脚注把那五种原因合成一个数、再补一句「逐条原因待落盘后展示」，
    /// 而细账其实早就分开算好了（`LogSummary` 里那一格是台账的 `suspectedCount`）。
    /// 判据没有放宽 —— 现在要求得多，要求得少的那一版是假话。
    func testUncountedCrashChannelFilesAreNamedInTheDetail() async throws {
        try writePackageManifest(products: [])
        try write("Reports/empty.ips", "")   // 真值：一份 0 字节的崩溃通道文件，零次崩溃
        let outcome = try await FileLogAnalyzer().analyzeWithEvidence(
            projectRoot: root, extraLogURLs: [], withinDays: 30)
        XCTAssertEqual(outcome.summary.crashCount, 0)
        let footnote = outcome.summary.crashEvidenceFootnote(windowDays: 30, evidence: outcome.evidence)
        XCTAssertTrue(footnote.contains("未产出可计数的证据"),
                      "「有 N 份报告但一次都没算」必须说得出原因，实得 \(footnote)")
        XCTAssertTrue(footnote.contains("疑似报告 1 份"),
                      "逐条原因要逐字来自细账，实得 \(footnote)")
        XCTAssertFalse(footnote.contains("待 LogSummary 落盘"),
                       "欠账那句是假话，细账已经算完了：" + footnote)
        // 同一句话在没有细账时不许装作说得出原因（未知态与"没原因"是两件事）。
        // ⚠️ RD-60 第二半之后 `analyzeWithEvidence` 交回的 summary **自带九格快照**，
        //    "没有细账"这一态只能由**旧报告落盘的形状**代表：整键缺席（不是抹成一串 0）。
        var legacy = outcome.summary
        legacy.crashEvidence = nil
        let withoutLedger = legacy.crashEvidenceFootnote(windowDays: 30)
        XCTAssertTrue(withoutLedger.contains("本次未统计"), withoutLedger)
    }
}
