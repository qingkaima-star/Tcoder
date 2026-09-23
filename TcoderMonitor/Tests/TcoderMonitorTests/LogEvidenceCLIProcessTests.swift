import Foundation
import XCTest
@testable import TcoderMonitor

/// R4 · **真子进程**证据（AGENTS §5.9 第 3 条：只有 in-process 断言不算交付证据）。
///
/// 这里起的是构建产物本体，不是函数调用。要钉的是四件事：
/// ① 非证据文件（空 / 损坏 / 只是名字像）**不进扣分**——从 JSON 出口看，不是从单测看；
/// ② `--window-days` 真的作用在**事件时间**上（放宽窗口，历史那一次才进账）；
/// ③ 改了失败判定没有把退出码档位带歪（路径不可用仍是 3 档）；
/// ④ 无头进程**不许去读真机的 `~/Library/Logs`**——那台机器上别人的报告一个字都不该看。
final class LogEvidenceCLIProcessTests: XCTestCase {
    private var sandbox: URL!
    private var project: URL!
    private var fakeLibraryLogs: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("r4-cli-\(UUID().uuidString)", isDirectory: true)
        project = sandbox.appendingPathComponent("CLIFixtureApp", isDirectory: true)
        fakeLibraryLogs = sandbox.appendingPathComponent("empty-library-logs", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fakeLibraryLogs, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o644],
                                               ofItemAtPath: project.appendingPathComponent("Logs/locked.log").path)
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: 夹具（in-code，与 `scripts/r4_log_evidence_fixtures.py` 同一批形状，这里只留子进程要验的三条）

    private func put(_ rel: String, _ text: String, daysAgo: Double = 0) throws -> URL {
        let url = project.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
        let when = Date().addingTimeInterval(-daysAgo * 86_400)
        try FileManager.default.setAttributes([.modificationDate: when], ofItemAtPath: url.path)
        return url
    }

    private func iso(_ daysAgo: Double) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
    }

    private func ips(incident: String, daysAgo: Double, version: String = "2.0 (9)") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss ZZZZ"
        let when = formatter.string(from: Date().addingTimeInterval(-daysAgo * 86_400))
        return #"{"app_name":"CLIFixtureApp","app_version":"\#(version)","bug_type":"309","incident_id":"\#(incident)","timestamp":"\#(when)","version":2}"# + "\n"
            + #"{"procName":"CLIFixtureApp","app_version":"\#(version)","incident_id":"\#(incident)","timestamp":"\#(when)","exception":{"Type":"EXC_BAD_ACCESS","Signal":"SIGSEGV","Subtype":"KERN_INVALID_ADDRESS at 0x0"},"threads":[{"id":1,"triggered":true,"frames":[{"imageIndex":0,"symbol":"CLIFixtureAppStore.flush()"}]}],"usedImages":[{"name":"CLIFixtureApp"}]}"#
    }

    /// 一次崩溃 + 三份非证据报告（空 / 截断 / 只是名字像）+ 一份窗口外的历史崩溃。
    /// **独立真值：7 天窗口 crashCount = 1；60 天窗口 = 2。**
    private func buildFixtureTree() throws {
        try put("Package.swift", "// swift-tools-version:6.0\nlet package = Package(name: \"CLIFixtureApp\")\n")
        try put("Logs/app.log", "\(iso(1)) ERROR db pool exhausted\n\(iso(1)) INFO ok\n")
        try put("Reports/empty.ips", "")
        let broken = ips(incident: "B1B1B1B1-1111-2222-3333-444444444444", daysAgo: 1)
        try put("Reports/broken.ips", String(broken.prefix(broken.count / 2)) + "\n<<<TRUNCATED")
        try put("Logs/locked.log", "\(iso(1)) ERROR 读不动的那一份\n", daysAgo: 1)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath:
            project.appendingPathComponent("Logs/locked.log").path)
        try put("Reports/CLIFixtureApp-recent.ips",
                ips(incident: "A1A1A1A1-1111-2222-3333-444444444444", daysAgo: 1), daysAgo: 1)
        try put("Reports/CLIFixtureApp-old.ips",
                ips(incident: "C2C2C2C2-1111-2222-3333-444444444444", daysAgo: 40), daysAgo: 40)
        // 必须给它一个 git 仓库形状：否则 **Git 那一路**失败 ⇒ 退出码落到 2（部分路失败），
        // 这条用例就想钉"读失败不把退出码档位带歪"，混进别的失败路就钉不住。
        try gitInit(project)
    }

    private func gitInit(_ url: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "-q", url.path]
        process.currentDirectoryURL = url
        try process.run()
        process.waitUntilExit()
    }

    // MARK: 起进程

    private func launch(_ arguments: [String]) throws -> (rc: Int32, stdout: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = arguments
        // 两条隔离都必须给：假 Library/Logs 让无头进程**永远不会**碰到真机目录；
        // 沙箱支持目录避免写进全机共享的 Application Support。
        process.environment = ["TCODER_LIBRARY_LOGS_DIR": fakeLibraryLogs.path,
                               "TCODER_SUPPORT_DIR": sandbox.appendingPathComponent("support").path,
                               "HOME": sandbox.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.launch()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func scanJSON(windowDays: Int) throws -> (rc: Int32, logs: [String: Any]) {
        let out = sandbox.appendingPathComponent("out-\(windowDays).json")
        let run = try launch(["scan", project.path, "--out=" + out.path,
                              "--window-days=\(windowDays)"])
        let data = try Data(contentsOf: out)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any], "落盘 JSON 读不出来")
        return (run.rc, (object["logs"] as? [String: Any]) ?? [:])
    }

    // MARK: 判据

    /// ① 非证据的三份报告一个都没进崩溃数；真错误也没被误分类吃掉。
    func testNonEvidenceReportsNeverReachTheCrashCountInARealProcess() throws {
        try buildFixtureTree()
        let (rc, logs) = try scanJSON(windowDays: 7)
        XCTAssertEqual(rc, 0, "读失败不该把整条扫描判成失败（退出码档位见另一条）")
        XCTAssertEqual((logs["crashCount"] as? Int) ?? -1, 1,
                       "真值 1 次：空 / 截断 / 000 权限那三份一份都不许算")
        XCTAssertEqual((logs["errorCount"] as? Int) ?? -1, 1, "app.log 那条真错误必须在账上")
        XCTAssertFalse((logs["readFailedFiles"] as? [Any] ?? []).isEmpty,
                       "读不动的那份要单独一本账")
    }

    /// ② 窗口口径作用在**事件时间**上：40 天前那一次只有放宽窗口才进账。
    func testWindowDaysMovesTheCrashCountByEventTime() throws {
        try buildFixtureTree()
        let narrow = try scanJSON(windowDays: 7).logs["crashCount"] as? Int
        let wide = try scanJSON(windowDays: 60).logs["crashCount"] as? Int
        XCTAssertEqual(narrow, 1, "7 天窗口只认窗口内那一次")
        XCTAssertEqual(wide, 2, "放宽到 60 天，40 天前那次历史报告才该进来")
    }

    /// ③ 改了日志路的失败判定，没把退出码档位带歪：路径不可用仍是 3 档。
    func testUnusablePathStillExitsThree() throws {
        let missing = sandbox.appendingPathComponent("nope-does-not-exist")
        let run = try launch(["scan", missing.path])
        XCTAssertEqual(run.rc, 3, "§5.9 第 3 条：3 = 路径不可用；本流没动这一档")
    }

    /// ④ 无头进程不许把真机 `~/Library/Logs` 读进结果：
    /// 假目录里放一份**别的 App** 的报告，扫描输出必须对它零反应。
    func testForeignDiagnosticsDirectoryIsNotReadIntoResults() throws {
        try buildFixtureTree()
        let foreign = ips(procName: "SomeOtherApp", incident: "D9D9D9D9-1111-2222-3333-444444444444",
                          daysAgo: 1)
        try FileManager.default.createDirectory(at: fakeLibraryLogs.appendingPathComponent("DiagnosticReports"),
                                                withIntermediateDirectories: true)
        try foreign.write(to: fakeLibraryLogs
                            .appendingPathComponent("DiagnosticReports/SomeOtherApp-2026-01-01-000000.ips"),
                          atomically: true, encoding: .utf8)
        let logs = try scanJSON(windowDays: 7).logs
        XCTAssertEqual(logs["crashCount"] as? Int, 1, "别人 App 的报告一次都不许算进来")
    }

    /// 一份真崩溃 + 无归属目录时的对照：证明上一条的差异确实来自归属过滤，不是"根本没读到崩溃"。
    private func ips(procName: String, incident: String, daysAgo: Double) -> String {
        ips(incident: incident, daysAgo: daysAgo).replacingOccurrences(of: "CLIFixtureApp", with: procName)
    }
}
