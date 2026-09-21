import Foundation
import XCTest

/// **真·子进程**退出码测试：把交付的那个二进制真的起来跑一遍。
///
/// 为什么必须有这把（`CLIHeadlessTests` 那 20 条都在同一进程里直接调 `CLIRouter.main`）：
/// 2026-09-21 实测缺陷 —— `TcoderMonitor score <不存在的路径>` 在 release 二进制里
/// 挂死 16 分钟不出声（0.6 秒 CPU、无子进程、fd 上挂着
/// `…/com.tcoder.monitor.savedState/{data.data,windows.plist}`），
/// 连 600 秒的 `CLIConfig.hardTimeout` 都没能把它捞出来；
/// 而同一时刻 in-process 的 `test_unusablePathExitsThreeWithoutTouchingAnalyzers` 是全绿的。
/// 两把尺子的差集就是这类缺陷的藏身处：**AI 调用方拿到的是进程，不是函数返回值** ——
/// 它看到的是"命令挂着不回、退出码永远等不到"，而不是一个可修的失败。
///
/// 三条判据形状：①**退出码**对不对；②**多久**退（有界等待，超时即判败）；
/// ③无头模式**不许留下 GUI 的副作用**（窗口状态文件）。
final class CLIProcessTests: XCTestCase {

    /// 单条命令的墙钟上限。定这么松是为了不把"机器忙"读成缺陷；
    /// 真正的病灶是"永远不回"，16 分钟 vs 15 秒之间不需要更细的刻度。
    static let wallClockLimit: TimeInterval = 15

    /// 被测二进制 = **同一次构建**的产物本体，不猜配置目录名。
    /// 测试跑在 `…/.build/<cfg>/TcoderMonitorPackageTests.xctest/…` 里，
    /// xctest bundle 的上一级就是 `<cfg>`，同级的 `TcoderMonitor` 就是被测产物。
    static func productBinary() throws -> String {
        if let override = ProcessInfo.processInfo.environment["TCODER_CLI_BIN"], !override.isEmpty {
            return override
        }
        let bundleURL = Bundle(for: CLIProcessTests.self).bundleURL
        let cfgDir = bundleURL.deletingLastPathComponent().path
        let candidate = "\(cfgDir)/TcoderMonitor"
        // **不许静默跳过**：拿不到产物就判败，否则这把尺子会变成"没测也算过"。
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: candidate),
                      "找不到被测二进制 \(candidate)（bundleURL=\(bundleURL.path)）——"
                      + "这条测试的存在意义就是盯真进程，跳过等于没有")
        return candidate
    }

    @discardableResult
    private func launch(_ args: [String], limit: TimeInterval = CLIProcessTests.wallClockLimit)
        throws -> (rc: Int32, stdout: String, stderr: String, seconds: TimeInterval) {
        let out = Pipe()
        let err = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: try Self.productBinary())
        proc.arguments = args
        proc.standardOutput = out
        proc.standardError = err
        let started = Date()
        try proc.run()
        while proc.isRunning, Date().timeIntervalSince(started) < limit {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if proc.isRunning {
            // 只终止**本测试自己起的、路径核对过的那一个** pid —— 与本仓 `SCORE_TERM=1`
            // 同一套做法；绝不按 bundle id 广播退出（那会全机生效，杀到别人正在跑的实例）。
            timedOut = true
            proc.terminate()
            proc.waitUntilExit()
        } else {
            proc.waitUntilExit()
        }
        let seconds = Date().timeIntervalSince(started)
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if timedOut {
            XCTFail("argv \(args) 在 \(limit) 秒内没退出（挂死就是要抓的东西）"
                    + " · stdout=\(stdout.prefix(120)) stderr=\(stderr.prefix(120))")
        }
        return (proc.terminationStatus, stdout, stderr, seconds)
    }

    func test_realProcess_versionExitsZeroAndFast() throws {
        let r = try launch(["--version"])
        XCTAssertEqual(r.rc, 0)
        XCTAssertTrue(r.stdout.contains("tcoder"), "stdout=\(r.stdout.prefix(120))")
        XCTAssertLessThan(r.seconds, Self.wallClockLimit, "即时返回的档位不该慢")
    }

    func test_realProcess_usageErrorExits64() throws {
        let r = try launch(["scan"])
        XCTAssertEqual(r.rc, 64, "缺目标路径要用 64（用法错），不能与'跑过了但失败'混档")
        XCTAssertTrue(r.stderr.contains("需要一个目标路径"), "stderr=\(r.stderr.prefix(160))")
    }

    /// 这条就是 2026-09-21 那次挂死的回归测试：**同步**回 3，不借道并发池。
    func test_realProcess_unusablePathExitsThreeFast() throws {
        let missing = "\(NSTemporaryDirectory())tcoder-no-such-dir-\(UUID().uuidString)"
        let r = try launch(["score", missing])
        XCTAssertEqual(r.rc, 3, "stderr=\(r.stderr.prefix(160)) stdout=\(r.stdout.prefix(160))")
        XCTAssertTrue(r.stderr.contains("路径不可用"), "stderr=\(r.stderr.prefix(160))")
        XCTAssertLessThan(r.seconds, 5, "路径校验是纯本地 stat，超过 5 秒就是别的东西在拦")
    }

    func test_realProcess_doctorWithoutPathExitsZero() throws {
        let r = try launch(["doctor"])
        XCTAssertEqual(r.rc, 0)
        XCTAssertTrue(r.stdout.contains("二进制 ="), "stdout=\(r.stdout.prefix(160))")
    }

    /// 真跑一趟有活儿的扫描（自建的临时小仓库），确认"跑完能退"这一整条链没被入口改造弄坏。
    /// 断言只盯**档位与形状**，不盯分数——分数属于产品，写死进测试就变成回归基线。
    func test_realProcess_scoreOfFixtureExitsWithPartialTier() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-cli-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "import Foundation\n\nfunc probe() -> Int { 42 }\n"
            .write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let r = try launch(["score", dir.path], limit: 40)
        XCTAssertEqual(r.rc, 2, "只有代码那一路能成，其余四路必失败 ⇒ 档位必须是 2；"
                     + "stdout=\(r.stdout.prefix(200)) stderr=\(r.stderr.prefix(200))")
        XCTAssertTrue(r.stdout.contains("综合"), "报告读数要在，不能只有退出码")
    }

    /// 第 3 档的第二格：**存在但根本读不了**的目录。
    /// `fileExists` 对 chmod 000 的目录返回 true，所以只查存在性会把它放过去 ——
    /// 实测放过去的后果不是"报错不明显"，是**四路各自交出全零的成功读数**
    /// （`文件 0 · 码行 0 · scannedAt 有值`），界面于是把"没读到"画成"这是个空仓库"。
    /// 这条测试同时是那个缺陷（改进清单 F12）的回归测试。
    func test_realProcess_unreadableDirectoryExitsThree() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-unreadable-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "let x = 1\n".write(to: dir.appendingPathComponent("a.swift"), atomically: true, encoding: .utf8)
        addTeardownBlock {
            // 先恢复权限再删，否则 `removeItem` 会失败并把临时目录留在机器上（AGENTS §1.6 跑完自清）。
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dir.path)

        let r = try launch(["score", dir.path], limit: 15)
        XCTAssertEqual(r.rc, 3, "不可读的目录必须走第 3 档，不能交出零读数；"
                     + "stdout=\(r.stdout.prefix(200)) stderr=\(r.stderr.prefix(200))")
        XCTAssertTrue(r.stderr.contains("不可读"), "stderr=\(r.stderr.prefix(160))")
    }

    /// 无头模式**不许碰 GUI 的状态**：窗口状态目录在调用前后必须一个字节都没动。
    /// 病灶就长这样：挂死那次进程上正开着 `com.tcoder.monitor.savedState/windows.plist`。
    func test_realProcessHeadlessWritesNoWindowState() throws {
        let fm = FileManager.default
        let state = (NSTemporaryDirectory() as NSString).appendingPathComponent("com.tcoder.monitor.savedState")
        let before = (try? fm.attributesOfItem(atPath: state)[.modificationDate] as? Date) ?? nil
        _ = try launch(["--version"])
        let after = (try? fm.attributesOfItem(atPath: state)[.modificationDate] as? Date) ?? nil
        switch (before, after) {
        case (nil, nil):
            break                                     // 从来没被写过 —— 正期望
        case let (b?, a?):
            XCTAssertLessThan(abs(b.timeIntervalSince(a)), 0.5,
                              "无头调用之后窗口状态文件的 mtime 变了 ⇒ AppKit 的恢复流程被惊动")
        case (nil, .some):
            XCTFail("无头调用**新建**了 \(state) —— AI 调用方不该产生 GUI 副作用")
        case (.some, nil):
            XCTFail("窗口状态目录被删掉了，超出本次调用的授权范围")
        }
    }
}
