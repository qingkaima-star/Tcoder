import XCTest
@testable import TcoderMonitor

/// WS-R 诚实性 P1 修复：日志页的「时间窗口 N 天」与「已扫描文件」必须是真的。
///
/// 修复前的两处过头宣称（审计 P1 #9 / P1 #11）：
/// - 窗口只对 `~/Library/Logs/DiagnosticReports/*.ips` 生效，工程内日志与
///   `~/Library/Logs/<项目>` 既不按 mtime 过滤、聚合也不按日期筛事件，
///   于是「时间窗口 7 天」下面摆着全部历史；
/// - `LogReader` 打不开的文件带着 `totalLines == 0` 照样进 `scannedFiles`，
///   `hasData` 因此为真、风险被判成「无」——权限不足换来一张 all-clear。
final class HonestyP1LogsTests: XCTestCase {

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ws-r-honesty-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        // 读取失败的夹具是 000 权限，先恢复权限再删，否则清不干净。
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: tempRoot.appendingPathComponent("Logs/locked.log").path)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - 时间窗口真的生效

    func testDiscoveryExpectsProjectLogsModifiedOutsideTheWindowToBeDropped() throws {
        let fresh = try write(text: "ERROR 本周\n", to: "Logs/fresh.log")
        let stale = try write(text: "ERROR 三月前\n", to: "Logs/stale.log")
        try setModificationDate(.days(90), of: stale)

        let found = LogDiscovery.discover(projectRoot: tempRoot, projectName: "ShopApp",
                                           withinDays: 7, maxFiles: 50)
        let names = Set(found.filter { $0.url.path.hasPrefix(tempRoot.path) }.map { $0.url.lastPathComponent })
        XCTAssertEqual(names, ["fresh.log"],
                       "7 天窗口必须把 90 天未改动的日志挡在门外（它不可能含窗口内的新条目）：\(names)")
        XCTAssertTrue(found.contains { $0.url.path == fresh.path })
    }

    func testDiscoveryKeepsEverythingWhenTheWindowIsDisabled() throws {
        let stale = try write(text: "ERROR 很久以前\n", to: "Logs/stale.log")
        try setModificationDate(.days(900), of: stale)

        let found = LogDiscovery.discover(projectRoot: tempRoot, projectName: "ShopApp",
                                          withinDays: 0, maxFiles: 50)
        XCTAssertTrue(found.contains { $0.url.path == stale.path },
                      "withinDays <= 0 是「不限制」，必须仍能全量发现：\(found.map { $0.url.lastPathComponent })")
    }

    func testWideWindowStillReachesBackIntoOldLogs() throws {
        let stale = try write(text: "ERROR 九十天前\n", to: "Logs/stale.log")
        try setModificationDate(.days(90), of: stale)

        let found = LogDiscovery.discover(projectRoot: tempRoot, projectName: "ShopApp",
                                          withinDays: 365, maxFiles: 50)
        XCTAssertTrue(found.contains { $0.url.path == stale.path },
                      "窗口放宽到 365 天就该收回来，过滤必须是按窗口而不是按常量：\(found.map { $0.url.lastPathComponent })")
    }

    /// 用户显式附加的文件不参与窗口裁剪：他刚点的那份文件不该因为日期老就被静默丢掉。
    func testUserAttachedLogsAreNotSilentlyDroppedByTheWindow() async throws {
        let attached = try write(text: "ERROR 附加文件里的旧错误\n", to: "Attached/legacy.log")
        try setModificationDate(.days(400), of: attached)

        let summary = try await FileLogAnalyzer()
            .analyze(projectRoot: tempRoot, extraLogURLs: [attached], withinDays: 7)

        XCTAssertTrue(summary.scannedFiles.contains { $0.path == attached.path },
                      "附加文件必须仍在场：\(summary.scannedFiles.map { $0.path })")
        XCTAssertGreaterThanOrEqual(summary.errorCount, 1)
    }

    // MARK: - 打不开的文件不算「已核对」

    func testLogFileThatCannotBeOpenedIsNotReportedAsScanned() async throws {
        let opened = try write(text: "ERROR 读得到的那条\n", to: "Logs/readable.log")
        let denied = try write(text: "ERROR 读不到的那条\n", to: "Logs/locked.log")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        // 以 root 跑测试时 000 也拦得住读，此时这条用例没有前提，直接跳过而不是假绿。
        if let handle = try? FileHandle(forReadingFrom: denied) {
            try? handle.close()
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: denied.path)
            throw XCTSkip("当前进程仍能读取 000 权限文件，无法构造读取失败前提")
        }

        let summary = try await FileLogAnalyzer()
            .analyze(projectRoot: tempRoot, extraLogURLs: [], withinDays: 30)

        XCTAssertFalse(summary.scannedFiles.contains { $0.path == denied.path },
                       "打不开的文件不得进「已扫描文件」，否则换取一次 all-clear：\(summary.scannedFiles.map { $0.path })")
        XCTAssertTrue(summary.scannedFiles.contains { $0.path == opened.path },
                      "读得到的那份要照常在场：\(summary.scannedFiles.map { $0.path })")
        XCTAssertGreaterThanOrEqual(summary.errorCount, 1, "读取失败不能牵连成功读到的内容")
    }

    /// 只有读不到的文件被剔除；**读到但内容为空**是「已核对零命中」，与「没核对」不同一状态。
    func testReadableButEmptyLogFileStillCountsAsChecked() async throws {
        let empty = try write(text: "", to: "Logs/empty.log")

        let summary = try await FileLogAnalyzer()
            .analyze(projectRoot: tempRoot, extraLogURLs: [], withinDays: 30)

        XCTAssertTrue(summary.scannedFiles.contains { $0.path == empty.path },
                      "0 字节且打开成功的日志是核对过的空文件，不该被冒充成「没扫过」：\(summary.scannedFiles.map { $0.path })")
        XCTAssertEqual(summary.totalLinesScanned, 0)
    }

    /// 只有读不到的文件时，整页必须回到「没有数据」而不是「查过、干净」。
    func testProjectWhoseOnlyLogFileIsUnreadableReportsNoData() async throws {
        let denied = try write(text: "ERROR 看不见的那条\n", to: "Logs/locked.log")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: denied.path)
        if let handle = try? FileHandle(forReadingFrom: denied) {
            try? handle.close()
            try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: denied.path)
            throw XCTSkip("当前进程仍能读取 000 权限文件，无法构造读取失败前提")
        }

        let summary = try await FileLogAnalyzer()
            .analyze(projectRoot: tempRoot, extraLogURLs: [], withinDays: 30)

        XCTAssertFalse(summary.hasData,
                       "唯一的日志文件没读进来时 hasData 必须为假，否则首页与日志页一起亮绿灯")
        XCTAssertEqual(summary.totalLinesScanned, 0)
        XCTAssertTrue(summary.scannedFiles.isEmpty)
    }

    // MARK: - 夹具

    @discardableResult
    private func write(text: String, to relative: String) throws -> URL {
        let url = tempRoot.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func setModificationDate(_ offset: DaysOffset, of url: URL) throws {
        let date = Date(timeIntervalSinceNow: -Double(offset.daysAgo) * 86_400)
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private struct DaysOffset {
        let daysAgo: Int
        static func days(_ value: Int) -> DaysOffset { DaysOffset(daysAgo: value) }
    }
}
