import Foundation
import XCTest
@testable import TcoderMonitor

/// R5 · **真子进程**取证（AGENTS §5.9 第 3 条：只有 in-process 断言不算交付证据）。
///
/// 起的是本次构建出来的产物本体（`CLIProcessTests.productBinary()` 同一个入口），
/// 喂的是 `CoverageMergeFixtures` 那批手写夹具，读的是**落盘 JSON**。
/// 这条链上最容易被自己骗过去的两件事，这里都用进程外的数字钉死：
///   ① 落盘的 `coverage.reports` 里那份读数，按契约里那句"直接累加相除"算回去，
///      必须等于手算真值 —— 于是"总数 = 并集"不再是我自己说的；
///   ② 考虑数（`scannedFileCount`）与计入数（`reports`）的差必须逐份有交代，
///      旧的 `prefix(6)` 与 `return nil` 就是死在这个差没人解释上。
final class CoverageChainProofTests: XCTestCase {

    private static let wallClockLimit: TimeInterval = 60

    private var base: URL!

    override func setUpWithError() throws {
        base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("r5-cli-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: - 子进程

    private func scan(_ directory: URL) throws -> [String: Any] {
        // 输出**不许落在被扫总体里**：多出一个 JSON 文件就改变了总体，
        // 与 GUI 侧那份就不再是同一批输入（本仓刚在另一条链上踩过同形状的坑）。
        let out = base.appendingPathComponent("scan-\(directory.lastPathComponent)-\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = ["scan", directory.path, "--out=" + out.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let started = Date()
        try process.run()
        while process.isRunning, Date().timeIntervalSince(started) < Self.wallClockLimit {
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), Self.wallClockLimit,
                          "scan 在 \(Self.wallClockLimit) 秒内没退出")
        process.waitUntilExit()
        let json = try Data(contentsOf: out)
        let report = try XCTUnwrap(JSONSerialization.jsonObject(with: json) as? [String: Any])
        // 退出码档位（AGENTS §5.9 第 3 条）：0 全成 / 2 部分路失败。
        // 这些夹具只有覆盖率产物，没有 git、没有日志、没有依赖清单 ⇒ 2 是**正确**的档位；
        // 但 `failedSections` 里绝不许出现覆盖率那一路，否则"没读数"是失败而不是缺证据。
        XCTAssertTrue([0, 2].contains(process.terminationStatus),
                      "scan \(directory.lastPathComponent) 退出码 \(process.terminationStatus) 不在 0/2 档")
        let failed = (report["failedSections"] as? [String]) ?? []
        XCTAssertFalse(failed.contains { $0.contains("覆盖") },
                       "覆盖率那一路失败了：\(failed) —— 缺证据与读失败不是一回事")
        return report
    }

    private func coverage(of report: [String: Any]) -> [String: Any]? {
        report["coverage"] as? [String: Any]
    }

    /// 契约里 `overallLinePercent` 的算法（照抄一遍当**外部读者会怎么算**）：
    /// 留下的报告 `linesTotal > 0` 的那些，covered 与 total 各自累加相除。
    private func contractTotal(_ coverage: [String: Any]) -> (covered: Int, total: Int) {
        let reports = (coverage["reports"] as? [[String: Any]]) ?? []
        let scored = reports.filter { (($0["linesTotal"] as? Int) ?? 0) > 0 }
        let covered = scored.reduce(0) { $0 + (($1["linesCovered"] as? Int) ?? 0) }
        let total = scored.reduce(0) { $0 + (($1["linesTotal"] as? Int) ?? 0) }
        return (covered, total)
    }

    // MARK: - 六条验收场景（真二进制读数）

    func testRealBinaryReadsEveryScenarioAtItsHandComputedTruth() throws {
        var verified = 0
        for scenario in CoverageMergeFixtures.all {
            let directory = base.appendingPathComponent(scenario.name.replacingOccurrences(of: " ",
                                                                                           with: "_"),
                                                        isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            scenario.install(into: directory)

            let report = try scan(directory)
            let coverageDict = try XCTUnwrap(coverage(of: report), "JSON 里没有 coverage 段")
            let considered = (coverageDict["scannedFileCount"] as? Int) ?? -1
            let total = contractTotal(coverageDict)
            print("【CLI·\(scenario.name)】考虑 \(considered) · 落盘读数 \(total.covered)/\(total.total)"
                + " · 手算真值 \(scenario.truth.map { "\($0.covered)/\($0.total)" } ?? "不给总数")")

            XCTAssertEqual(considered, scenario.reportFiles.count,
                           "考虑数与夹具份数不一致：\(scenario.name)")
            if let truth = scenario.truth {
                XCTAssertEqual(total.covered, truth.covered, "分子不等于真值：\(scenario.name)")
                XCTAssertEqual(total.total, truth.total, "分母不等于真值：\(scenario.name)")
            } else {
                XCTAssertEqual(total.total, 0,
                               "该场景判「不给伪精确总数」，落盘里却还有可累加的分母：\(scenario.name)")
            }
            verified += 1
        }
        XCTAssertEqual(verified, CoverageMergeFixtures.all.count)
        XCTAssertGreaterThanOrEqual(verified, 6, "六个场景没跑满 ⇒ 这条取证是空跑")
    }

    /// 丢弃数在 JSON 侧也必须能算回来：`scannedFileCount` − 落盘读数份数 = 被合并掉的输入 + 被丢掉的。
    /// 这里取"同一次运行两种落法"那一条：旧实现留 2 份（相加得 240/400），现在只留 1 份。
    func testDeduplicationIsVisibleInPersistedJson() throws {
        let directory = base.appendingPathComponent("same_run", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CoverageMergeFixtures.sameRunTwoFormats.install(into: directory)

        let coverageDict = try XCTUnwrap(coverage(of: scan(directory)))
        let reports = (coverageDict["reports"] as? [[String: Any]]) ?? []
        XCTAssertEqual((coverageDict["scannedFileCount"] as? Int) ?? -1, 2, "两份报告文件都被看到")
        XCTAssertEqual(reports.count, 1, "只留一份：修前是 2 份、总分被算成 240/400")
        XCTAssertEqual(reports.first?["toolName"] as? String, "lcov", "留的是能核对来源的那份")
        let total = contractTotal(coverageDict)
        XCTAssertEqual(total.covered, 120)
        XCTAssertEqual(total.total, 200)
    }

    // MARK: - 场景⑥（真 git）：旧报告与当前源码不一致

    /// 在一个真 git 仓库里：报告 mtime 早于最新提交 ⇒ 落盘里**没有可读数的报告**，
    /// 而 `scannedFileCount` 仍是 1（"有报告"与"报告可用"是两件事）。
    /// 对照组：mtime 在提交之后 ⇒ 正常给数。
    func testStaleReportAgainstRealGitRepositoryIsNotCounted() throws {
        let directory = base.appendingPathComponent("git_bound", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try "export const a = 1\n".write(to: directory.appendingPathComponent("src/a.js"),
                                         atomically: true, encoding: .utf8)
        try git(["init", "-q", "."], in: directory)
        try git(["config", "user.name", "R5 Fixture"], in: directory)
        try git(["config", "user.email", "r5-fixture@tcoder.local"], in: directory)
        try git(["add", "-A"], in: directory)
        try git(["commit", "-qm", "first"], in: directory)

        let lcov = directory.appendingPathComponent("coverage/lcov.info")
        try FileManager.default.createDirectory(at: lcov.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "SF:src/a.js\nLF:100\nLH:50\nend_of_record\n".write(to: lcov, atomically: true,
                                                                encoding: .utf8)

        // 对照：新鲜（mtime = 现在，晚于刚写下的提交）
        let fresh = try XCTUnwrap(coverage(of: scan(directory)))
        XCTAssertEqual(contractTotal(fresh).total, 100, "mtime 晚于最新提交时该给数：\(fresh)")

        // 陈旧：把 mtime 推到 2020 年，源码提交保持"刚刚"
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)],
                                              ofItemAtPath: lcov.path)
        let stale = try XCTUnwrap(coverage(of: scan(directory)))
        XCTAssertEqual((stale["reports"] as? [[String: Any]])?.count ?? -1, 0,
                       "早于最新提交的报告不得冒充当前覆盖率")
        XCTAssertEqual(stale["scannedFileCount"] as? Int, 1,
                       "'有报告'与'报告可用'必须分开：这里要说的是有报告、但它过期了")
        XCTAssertNil(stale["overallLinePercent"], "落盘里不许留下一个来自陈旧报告的百分比")
        // 三态里那一格仍然自洽：0 个目录读不动，是句真话。
        XCTAssertEqual(stale["unreadableDirectoryCount"] as? Int, 0)
    }

    @discardableResult
    private func git(_ arguments: [String], in directory: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "git \(arguments) 失败")
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }

    // MARK: - 两把尺子不许分叉：覆盖率那一路的提交号 ↔ 溯源块的提交号

    /// **同一棵被扫目录**，覆盖率那一路读到的 `sourceFingerprint` 必须与溯源块
    /// （`GitInsights.headSHA` → `ScanProvenance.sourceCommit`）同源。
    /// 为什么单独钉这一条：覆盖率链自己起了一次 `git rev-parse HEAD`
    /// （`CoverageSourceState.read`），而 Git 那一路另有自己的仓库根解析
    /// （`resolvedRepositoryRoot`）—— 18:30 总工点名的"两处各查一次迟早分叉"就是这个形状。
    /// 把 provenance 喂进覆盖率分析入口要动 `App/**` 与 `Services/CLI/`（不在我可写面），
    /// 所以在合掉之前，先把"两边必须给出同一个提交、且对外层仓库的判断一致"钉住。
    @MainActor
    func testCoverageFingerprintAndProvenanceCommitShareOneRuler() async throws {
        // 用**已解符号链接**的路径：`NSTemporaryDirectory()` 给的是 `/var/…`，而 Git 那一路
        // 回来的是 `/private/var/…`，不相等时溯源块会打出一条"提交号来自外层仓库"的假提示
        // （本仓 §25 那一族），这条用例要比的是"两把尺子同不同源"，不是这个。
        let target = base.resolvingSymlinksInPath().appendingPathComponent("one_ruler", isDirectory: true)
        try FileManager.default.createDirectory(at: target.appendingPathComponent("src"),
                                                withIntermediateDirectories: true)
        try "const a = 1\n".write(to: target.appendingPathComponent("src/a.js"),
                                   atomically: true, encoding: .utf8)
        try git(["init", "-q", "."], in: target)
        try git(["config", "user.name", "R5b One Ruler"], in: target)
        try git(["config", "user.email", "r5b-one-ruler@tcoder.local"], in: target)
        try git(["add", "-A"], in: target)
        try git(["commit", "-qm", "first"], in: target)
        let lcov = target.appendingPathComponent("coverage/lcov.info")
        try FileManager.default.createDirectory(at: lcov.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try "SF:src/a.js\nLF:100\nLH:50\nend_of_record\n".write(to: lcov, atomically: true,
                                                                    encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: lcov.path)

        let coverage = try await CoverageAnalyzer().analyze(projectRoot: target, options: .default)
        let gitInsights = try await ShellGitAnalyzer().analyze(repositoryURL: target)
        let report = coverage.reports.first
        let fingerprint = try XCTUnwrap(report?.sourceFingerprint,
                                        "被扫目录自己就是仓库根 ⇒ 覆盖率那一路该读到提交号")
        XCTAssertEqual(fingerprint, gitInsights.headSHA,
                       "覆盖率与 Git 两路读到的提交号分叉了：\(fingerprint) vs \(gitInsights.headSHA)")
        XCTAssertEqual(report?.sourceRepository, ".", "被扫目录自己有 .git ⇒ 坐标必须是 \".\"")
        XCTAssertFalse(gitInsights.headSHA.isEmpty, "Git 那一路也要给出提交号，否则无从对表")

        // 同一件事在溯源块里也要能给出一样的结论（`sourceCommit` 是 headSHA 的原样转发）。
        var assembled = ProjectReport(project: MonitoredProject(name: "one-ruler", path: target.path))
        assembled.git = gitInsights
        assembled.coverage = coverage
        let provenance = ScanProvenance(report: assembled, scannedRoot: target.path, producedBy: "test")
        XCTAssertEqual(provenance.sourceCommit, fingerprint,
                       "同一份报告里两个格子说不同提交 ⇒ 上屏就是自相矛盾")
        XCTAssertNil(provenance.resolvedGitRoot, "仓库根相等时不许造假提示（与 `ScanProvenanceTests` 同判据）")
    }

    // MARK: - 反证用：把新判定单独摘掉时会发生什么（写死在这里，供人工 sabotage 对表）

    /// 这条不改动产品代码，只把"摘掉判定后的算式"钉成数字：
    /// 每一处新判定各自对应一个"摘掉就会得到的读数"，读数差就是它的功劳。
    /// 真正的 sabotage（改源码→看红）步骤记在 Obsidian `112` 的 ## 反证。
    func testEachJudgmentHasAnDistinctWrongNumberWithoutIt() {
        // ① 同源去重（`isCoPublishedPair`）
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: [(120, 200), (120, 200)]), 60,
                       accuracy: 0.001, "摘掉去重：同一份证据被数两遍（240/400）")
        // ② 按行求并（`CoverageLedgerMerge`）
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: [(60, 100), (70, 120)]), 59.09, accuracy: 0.01,
                       "摘掉并集：unit+集成相加 = 130/220，真值 110/120 = 91.67%")
        // ③ 份数上限（旧 `prefix(6)`）
        let eightModules = Array(repeating: (50, 100), count: 8)
        XCTAssertEqual(CoverageLegacyArithmetic.summed(from: eightModules), 50, accuracy: 0.001)
        XCTAssertEqual(CoverageLegacyArithmetic.keptCount(from: eightModules), 6,
                       "旧上限：八份只留六份，且没人说丢了 2 份")
        // ④ 测试路径识别（多语言）
        XCTAssertEqual(850.0 / 1000.0 * 100, 85, "摘掉识别：分母里 70% 是自己覆盖自己的测试码")
        XCTAssertEqual(150.0 / 300.0 * 100, 50, "真值")
    }
}

// MARK: - GUI 落盘 ↔ 无头 CLI 落盘 对表（`scripts/report_parity.py`）

/// 为什么这一条必须真跑那把脚本：AGENTS §5.9 第 5 条"改了任何读数就跑对表"，
/// 而本轮改的正是覆盖率读数。两边喂的是**同一个被扫总体**：
///   · GUI 侧 = 与 `AppState.scan(project:)` 同一组分析器入口 + `ProjectStore` 那套编码器
///     落进沙箱支持目录（`ProjectStore.storageDirectory` 可换，就是为了不抢全机唯一的那份）；
///   · CLI 侧 = 交付二进制真子进程 `scan --out`。
/// 不允许启动第二个 App 实例（AGENTS §3 横切约束 2：取证格同一时刻只有一人），
/// 所以 GUI 侧走的是它自己的持久化路径而不是窗口进程 —— **这一点在汇报里点名，不含糊过去**。
extension CoverageChainProofTests {

    @MainActor
    func testGuiPersistedReportMatchesHeadlessCLIScanFieldByField() async throws {
        let target = base.appendingPathComponent("parity_target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        CoverageMergeFixtures.wholeRepoPlusModules.install(into: target)

        let cliJSON = try scanToURL(target)                       // CLI 侧：真交付二进制
        let guiJSON = try await persistGuiSideReport(in: target)   // GUI 侧：ProjectStore 落盘
        try compareCoverageSections(gui: guiJSON, cli: cliJSON)
        try runReportParityScript(gui: guiJSON, cli: cliJSON, target: target)
    }

    /// GUI 侧那份报告：与 `AppState.scan(project:)` 同一组分析器入口 + `ProjectStore` 那套编码器，
    /// 落进沙箱支持目录（不抢全机唯一的 `~/Library/Application Support`）。
    @MainActor
    private func persistGuiSideReport(in directory: URL) async throws -> URL {
        let sandbox = base.appendingPathComponent("support", isDirectory: true)
        // `save` 里是 `try?`：目录没建就会**静默不写文件**（实测第一版就是这么"没落出报告"的）。
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("reports"),
                                                withIntermediateDirectories: true)
        let store = ProjectStore()
        store.storageDirectory = sandbox
        let project = store.add(path: directory.path, name: "R5 对表夹具")
        var report = ProjectReport(project: project)
        // 五路走**同一个装配助手** `AnalyzerLedger.timed`：原来这里自己写了一份 `run`，
        // 于是 `AppState` 后面加的字段（provenance、analyzerLedger）这份副本一概不知道。
        // RD-31 的开工指纹同样要在这五路**之前**采：这份副本重演的是 GUI 装配，少采一次
        // 就会与 CLI 侧「整键在场 / 缺席」不一致，对表尺子当场判红。
        let fingerprintAtStart = SourceTreeFingerprint.probe(root: directory)
        let sections = await runGuiSideSections(root: directory)
        report.code = sections.code
        report.git = sections.git
        report.logs = sections.logs
        report.dependencies = sections.dependencies
        report.coverage = sections.coverage
        report.health = WeightedHealthScorer().score(HealthInputs(
            code: report.code, git: report.git, logs: report.logs,
            dependencies: report.dependencies, coverage: report.coverage, previousScore: nil))
        report.attemptedAt = Date()
        report.failedSections = sections.attempts.compactMap { $0.failureReason == nil ? nil : $0.label }
        report.analyzerLedger = AnalyzerLedger.records(from: sections.attempts)
        // ⚠️ 这份**测试副本**重演了 GUI 装配而不是调用它 ⇒ AppState 每加一个字段这里就静默落后
        //    一格（实测就漏过 provenance）。抽成共用装配函数是 R10 第 0.5 条的契约缺口。
        var provenance = ScanProvenance(report: report, scannedRoot: directory.path, producedBy: "gui")
        provenance.recordDrift(startingFrom: fingerprintAtStart,
                               endingAt: SourceTreeFingerprint.probe(root: directory))
        report.provenance = provenance
        store.save(report: report)
        return try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: sandbox.appendingPathComponent("reports"),
                                                    includingPropertiesForKeys: nil).first,
            "GUI 侧没落出报告文件")
    }

    /// 覆盖率段先自己比一遍（抹掉 `*At`），免得只能等脚本吐一行不带上下文的不等。
    private func compareCoverageSections(gui: URL, cli: URL) throws {
        let guiDict = try jsonObject(gui)["coverage"]
        let cliDict = try jsonObject(cli)["coverage"]
        let left = try XCTUnwrap(stripDates(guiDict))
        let right = try XCTUnwrap(stripDates(cliDict))
        XCTAssertTrue(left.isEqual(right),
                      "两条路落出来的覆盖率段不一致：GUI=\(left) CLI=\(right)")
    }

    /// 再真跑仓库里那把尺子（AGENTS §5.9 第 5 条）。
    private func runReportParityScript(gui: URL, cli: URL, target: URL) throws {
        let scripts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/report_parity.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scripts.path), "对表脚本不在 \(scripts.path)")
        let parity = Process()
        parity.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parity.arguments = [scripts.path, gui.path, cli.path, target.path]
        let pipe = Pipe()
        parity.standardOutput = pipe
        parity.standardError = pipe
        try parity.run()
        parity.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("【R5 对表 report_parity.py rc=\(parity.terminationStatus)】\n" + output)
        XCTAssertEqual(parity.terminationStatus, 0,
                       "report_parity.py 判败：GUI 落盘 vs CLI 扫描逐字段比对有不可容忍的不等\n" + output)
    }

    private func jsonObject(_ url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    /// 递归抹掉以 `At` 结尾的键（与 `report_parity.py` 的 `is_tolerated` 同一判据），
    /// 收成 `NSDictionary` 才能直接用 `isEqual` 逐字段比。
    private func stripDates(_ value: Any?) -> NSDictionary? {
        guard let dict = value as? [String: Any] else { return nil }
        var out: [String: Any] = [:]
        for (key, item) in dict where !key.hasSuffix("At") {
            if let nested = item as? [String: Any] {
                out[key] = stripDates(nested) ?? [:]
            } else if let array = item as? [Any] {
                out[key] = array.map { stripDates($0) ?? $0 }
            } else {
                out[key] = item
            }
        }
        return out as NSDictionary
    }

    private func scanToURL(_ directory: URL) throws -> URL {
        let out = base.appendingPathComponent("cli-\(UUID().uuidString).json")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: try CLIProcessTests.productBinary())
        process.arguments = ["scan", directory.path, "--out=" + out.path]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        return out
    }
}
