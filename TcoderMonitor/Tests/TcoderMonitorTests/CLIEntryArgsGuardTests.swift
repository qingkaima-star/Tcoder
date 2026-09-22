import Foundation
import XCTest
@testable import TcoderMonitor

/// 台账 RD-59：无头入口的参数守卫。
///
/// 缺陷形状（总工本人撞出来的）：`TcoderEntry.main()` 原来只有两格出口 ——
/// argv[1] 命中 `CLIRouter.headlessWords` 就走无头，**没命中就静默交给 AppKit 起 GUI**。
/// 于是把路径直接放在 argv[1]（漏写 `scan`）的调用不会报用法错、不会退出，
/// 而是起一个 GUI 实例占住**全机唯一那格取证窗口**（AGENTS 横切约束 2），
/// 界面上还看不出它是谁起的。修法：这种误用打用法错、退 64（沿用 `CLIExit.usage`，不新增档位）。
///
/// 本文件两个类，例数对照（`--filter` 只按类名点时另一类不会跑，故列清楚）：
/// - `CLIEntryArgsGuardTests` 7 例 —— 判据矩阵，纯函数，**不起进程**
/// - `CLIEntryArgsProcessGuardTests` 4 例 —— **真子进程**：退出码 + 「不许起 GUI」
final class CLIEntryArgsGuardTests: XCTestCase {

    /// 零参数 = 产品启动路径（双击图标），必须继续落回 AppKit。
    ///
    /// ⚠️ 这一格**故意没有真子进程用例**：测它就得真的起一次 GUI，
    /// 那就是占用全机唯一那格取证窗口（横切约束 2：同一时刻只允许一个人启动 App，
    /// 开工时 `pgrep -x TcoderMonitor` 就已经不是 0）。
    /// 所以它只由这条纯函数断言守着 —— 断言的是「守卫不拦它」，不是「GUI 真能起」。
    func test_zeroArgsStillFallThroughToAppKit() {
        XCTAssertNil(TcoderEntry.misuseProblem(argv: ["TcoderMonitor"]))
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor"]))
    }

    /// 守卫不能把已命中无头分派的词读成误用：两张判据必须互斥，
    /// 否则同一个 argv 会先被 `isHeadlessInvocation` 放过去、又被这里判死。
    func test_everyHeadlessWordIsNotMisuse() {
        for word in CLIRouter.headlessWords {
            XCTAssertNil(TcoderEntry.misuseProblem(argv: ["TcoderMonitor", word]),
                         "已知子命令词 \(word) 被误判成用法错")
            XCTAssertTrue(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", word]))
        }
    }

    /// 总工撞出来的那一格：只给路径、漏写子命令。
    func test_barePathIsUsageError() {
        let problem = TcoderEntry.misuseProblem(argv: ["/bin/TcoderMonitor", "/tmp/某个仓库"])
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("不是子命令词") == true, "problem=\(problem ?? "nil")")
    }

    func test_unknownWordIsUsageError() {
        let problem = TcoderEntry.misuseProblem(argv: ["TcoderMonitor", "scanx"])
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("scanx") == true, "要点名是哪个词写错了：\(problem ?? "nil")")
    }

    /// 漏写子命令、但把长参数留在了 argv[1]：本 App 的 GUI 启动参数从不写双横线，
    /// CLI 的长参数一律 `--`，所以这一格也是误用。
    func test_leadingDoubleDashFlagWithoutSubcommandIsUsageError() {
        for word in ["--out=/tmp/a.json", "--compact", "--window-days=7"] {
            XCTAssertNotNil(TcoderEntry.misuseProblem(argv: ["TcoderMonitor", word]),
                            "\(word) 单独出现在 argv[1] 只可能是漏写了子命令词")
        }
    }

    /// 反例：**GUI 的启动参数形状一律不许拦**。
    /// 取证链（`capture_pages_isolated.sh` / `ax_truncation_sweep.sh` / `perf_switch.sh` 等）
    /// 一律用 `-ApplePersistenceIgnoreState YES` 起 GUI，LaunchServices 传 `-psn_…`；
    /// 把这一族判死会让别的流的取证链当场断掉 —— 那不是本次工单要的「误用」。
    func test_guiLaunchFlagsStillPassThrough() {
        for word in ["-ApplePersistenceIgnoreState", "-psn_0_123456", "-selectedDetailSection",
                     "-AppleLanguages"] {
            XCTAssertNil(TcoderEntry.misuseProblem(argv: ["TcoderMonitor", word]),
                         "GUI 启动参数 \(word) 被误判成用法错")
            XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", word]))
        }
    }

    /// 用法提示必须**逐条点名三个子命令与它们的关键参数**（读 `CLIRouter.usageText` 那一份，
    /// 入口里没有第二份中文）。这一条钉住「守卫复用的就是那份唯一的用法串」。
    func test_usageTextNamesTheThreeSubcommandsAndTheirKeyArgs() {
        let text = CLIRouter.usageText
        for command in ["tcoder scan", "tcoder score", "tcoder doctor"] {
            XCTAssertTrue(text.contains(command), "用法串没点名 \(command)：\n\(text)")
        }
        for keyArg in ["--out=", "--compact", "--allow-network", "--log=", "--window-days="] {
            XCTAssertTrue(text.contains(keyArg), "用法串缺关键参数 \(keyArg)")
        }
        XCTAssertTrue(text.contains("64"), "用法串要写清 64 这一档")
    }
}

/// 真子进程那一把尺子：CLI 的退出码只有真子进程算交付证据（AGENTS §5.9 第 3 条）。
/// 被测二进制沿用 `CLIProcessTests.productBinary()` 的定位方式（同一把尺子，含 `TCODER_CLI_BIN` 覆盖），
/// 不硬编码绝对路径。
final class CLIEntryArgsProcessGuardTests: XCTestCase {

    /// 误用调用应当**立刻**回：给 6 秒。真起 GUI 时那一格会一直挂着，
    /// 6 秒足够判败，也把「万一判败时那个实例占窗口」的时间压到最短。
    static let misuseLimit: TimeInterval = 6

    /// 一趟调用的读数：退出码 + 两个流 + 期间**多出来的 TcoderMonitor 进程数峰值**。
    private struct Run {
        let rc: Int32
        let stdout: String
        let stderr: String
        let seconds: TimeInterval
        /// 到时限**还没自己退**＝起了 GUI。这个读数必须在收尾之前取，
        /// 否则「我们把它收掉了」会把证据一起收掉（RD-40 那一族假绿）。
        let stillRunningAtLimit: Bool
        /// 调用期间「除自己那一个之外」多出来的 `TcoderMonitor` 进程数峰值。
        let extraProcessPeak: Int
    }

    /// 全机 `TcoderMonitor` 进程数，**减去本次自己 spawn 的那一个 pid**。
    ///
    /// 为什么必须减：交付二进制的进程名就叫 `TcoderMonitor`，无头那一路（`scan <路径>`）
    /// 自己也叫这个名字。不减掉自己，正例会把「正在跑的那次合法扫描」数成"新起一个 GUI"
    /// —— 那是假红（实测第一版就栽在这里：scan 正例报 extraProcessPeak == 1）。
    /// 减掉之后剩下的那一格仍然是有牙的：**除了我自己起的那一个，任何别的 `TcoderMonitor`
    /// 出现都算占窗口**。而「误用调用被静默交给 AppKit」这一条由
    /// `stillRunningAtLimit` 钉死：GUI 不会自己退，无头误用必须在时限内回。
    ///
    /// 只读（AGENTS §-1 第 3 条：不得向任何进程发信号），读不到就 XCTFail 并回一个
    /// 刺眼的负数 —— **不许静默放行**，静默放行的判据等于没有判据。
    private func otherProcessCount(excluding ownPID: Int) -> Int {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        proc.arguments = ["-x", "TcoderMonitor"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do { try proc.run() } catch {
            XCTFail("起不了 /usr/bin/pgrep：\(error.localizedDescription) —— 数进程这一步没有证据")
            return .min
        }
        proc.waitUntilExit()                      // pgrep 自己会退，这里只是收读数，不动别人的 pid
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let pids = text.split(separator: "\n").compactMap { Int($0) }
        return pids.filter { $0 != ownPID }.count
    }

    private func launch(_ args: [String], limit: TimeInterval) throws -> Run {
        let bin = try CLIProcessTests.productBinary()
        let out = Pipe()
        let err = Pipe()
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = args
        proc.standardOutput = out
        proc.standardError = err
        let started = Date()
        try proc.run()
        let own = Int(proc.processIdentifier)
        let baseline = otherProcessCount(excluding: own)

        var peak = 0
        var settledSamples = 0
        while Date().timeIntervalSince(started) < limit {
            peak = max(peak, max(0, otherProcessCount(excluding: own) - baseline))
            if proc.isRunning {
                settledSamples = 0
            } else {
                // 退出后再补几拍：万一它其实又拉起了一个不会退的实例，这里也数得着。
                settledSamples += 1
                if settledSamples >= 4 { break }
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let stuckAtLimit = proc.isRunning
        if stuckAtLimit {
            // 只收**本测试自己 spawn 的那一个** pid：它的路径就是上面核对过的 `bin`，
            // 绝不按 bundle id 或进程名广播退出（那会杀到别人正在跑的实例）。
            proc.terminate()
            proc.waitUntilExit()
        } else {
            proc.waitUntilExit()
        }
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return Run(rc: proc.terminationStatus, stdout: stdout, stderr: stderr,
                   seconds: Date().timeIntervalSince(started),
                   stillRunningAtLimit: stuckAtLimit, extraProcessPeak: peak)
    }

    /// 自建极小夹具：一个只有一枚 swift 文件的目录。
    /// 一次全仓扫描要几分钟，判据只需要「scan 那一路照样跑完照样出报告」。
    private func tinyFixture() throws -> URL {
        let fm = FileManager.default
        let dir = r19Scratch().appendingPathComponent("fixture-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try "import Foundation\n\nfunc probe() -> Int { 42 }\n"
            .write(to: dir.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        return dir
    }

    /// 本树 `.scratch/`（已 gitignore，AGENTS §1.6 第 2 条）；
    /// 打包搬走了源码找不到仓库根就退回 `$TMPDIR`，两条路都在 teardown 里自清。
    private func r19Scratch() -> URL {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) {
                let scratch = dir.appendingPathComponent(".scratch/tcoder-r19-cliargs", isDirectory: true)
                try? fm.createDirectory(at: scratch, withIntermediateDirectories: true)
                if fm.isWritableFile(atPath: scratch.path) { return scratch }
                break
            }
            dir = dir.deletingLastPathComponent()
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-r19-cliargs", isDirectory: true)
    }

    /// 正例：`scan <路径> --out=<文件>` 那一路**不受影响** —— 照常跑完、照常写盘、
    /// 退出码是产品档位而不是 64，并且全程没多出任何 `TcoderMonitor` 进程。
    func test_realProcess_scanPathStillProducesReport() throws {
        let target = try tinyFixture()
        let out = r19Scratch().appendingPathComponent("scan-\(UUID().uuidString).json")
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }

        let r = try launch(["scan", target.path, "--out=\(out.path)"], limit: 90)
        XCTAssertFalse(r.stillRunningAtLimit, "scan 那一路必须自己退干净")
        XCTAssertTrue(r.rc == CLIExit.ok.rawValue || r.rc == CLIExit.partial.rawValue,
                      "scan 必须回到产品档位（0 全成 / 2 部分路失败），实得 rc=\(r.rc) "
                      + "stderr=\(r.stderr.prefix(200))")
        XCTAssertTrue(r.stdout.contains("已写出"), "stdout=\(r.stdout.prefix(200))")
        let data = try XCTUnwrap(FileManager.default.contents(atPath: out.path))
        XCTAssertGreaterThan(data.count, 200, "报告文件几乎是空的，说明 scan 被入口改造弄坏了")
        XCTAssertEqual(r.extraProcessPeak, 0,
                       "无头 scan 期间多出了 TcoderMonitor 进程 —— 起了 GUI 就是占窗口")
    }

    /// 误用一：漏写子命令（只给路径）⇒ rc=64，且用法串逐条点名三个子命令。
    func test_realProcess_missingSubcommandExits64AndNamesThreeCommands() throws {
        let target = try tinyFixture()
        let r = try launch([target.path], limit: Self.misuseLimit)
        XCTAssertEqual(r.rc, 64, "漏写子命令必须是 64（用法错），不能静默起 GUI；"
                     + "stdout=\(r.stdout.prefix(200)) stderr=\(r.stderr.prefix(200))")
        XCTAssertTrue(r.stderr.contains("不是子命令词"), "stderr=\(r.stderr.prefix(200))")
        for command in ["tcoder scan", "tcoder score", "tcoder doctor"] {
            XCTAssertTrue(r.stdout.contains(command), "用法串没点名 \(command)：\n\(r.stdout.prefix(600))")
        }
    }

    /// 误用二：乱写一个不认识的词 ⇒ 同样是 64 那一档。
    func test_realProcess_unknownWordExits64() throws {
        let r = try launch(["scanx", "/tmp"], limit: Self.misuseLimit)
        XCTAssertEqual(r.rc, 64, "stderr=\(r.stderr.prefix(200))")
        XCTAssertTrue(r.stderr.contains("scanx"), "要回话里点名是哪个词不认识")
    }

    /// 反例钉「不许起 GUI」：两次误用调用**必须不产生新进程**，而且必须自己就退了。
    ///
    /// 判据形状是「调用前后各数一次 `TcoderMonitor` 进程数 + 期间逐拍取样」，
    /// 断言峰值增量为 0 —— 这样正常路径下根本不需要杀任何进程（AGENTS §-1 第 3 条）。
    /// 万一守卫被摘掉，那次调用会真的起一个 GUI：`stillRunningAtLimit` 与
    /// `extraProcessPeak` 两条同时红，此时才由 `launch` 收掉**它自己 spawn 的那一个 pid**。
    func test_realProcess_misuseStartsNoGuiProcess() throws {
        let barePath = try tinyFixture().path
        let misuses: [[String]] = [[barePath], ["scanx", "/tmp"], ["--out=/tmp/x.json"]]
        for args in misuses {
            let r = try launch(args, limit: Self.misuseLimit)
            XCTAssertFalse(r.stillRunningAtLimit,
                           "误用调用 \(args) 在 \(Self.misuseLimit) 秒内没退出 ⇒ 它起了 GUI")
            XCTAssertEqual(r.extraProcessPeak, 0,
                           "误用调用 \(args) 期间全机多出了 TcoderMonitor 进程（占窗口）")
            XCTAssertEqual(r.rc, 64, "误用调用 \(args) 的退出码不是 64，实得 \(r.rc)")
            XCTAssertLessThan(r.seconds, Self.misuseLimit, "用法错应当即时返回，实测 \(r.seconds) 秒")
        }
    }
}
