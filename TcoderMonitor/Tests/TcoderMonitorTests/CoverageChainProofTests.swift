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

        // ---- CLI 侧（真子进程）
        let cliJSON = try scanToURL(target)

        // ---- GUI 侧（同一组分析器入口 + ProjectStore 编码器 + 沙箱支持目录）
        let sandbox = base.appendingPathComponent("support", isDirectory: true)
        // `save` 里是 `try?`：目录没建就会**静默不写文件**（实测第一版就是这么"没落出报告"的），
        // 所以这里显式建好再存，并且事后断言文件真的存在。
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("reports"),
                                                withIntermediateDirectories: true)
        let store = ProjectStore()
        store.storageDirectory = sandbox
        let project = store.add(path: target.path, name: "R5 对表夹具")
        var report = ProjectReport(project: project)
        // 五路逐条 try，失败路名与 CLI 用同一份 `sectionLabels` ——
        // 少这一步就会让 `failedSections` 两边走出不同结果（实测第一次就是这样判败的）。
        var failures: [String] = []
        func run<T>(_ label: String, _ body: () async throws -> T) async -> T? {
            do { return try await body() } catch { failures.append(label); return nil }
        }
        let codeValue: CodeMetrics? = await run(CLIScan.sectionLabels[0]) {
            try await FileSystemCodeAnalyzer().analyze(root: target, options: .default)
        }
        let gitValue: GitInsights? = await run(CLIScan.sectionLabels[1]) {
            try await ShellGitAnalyzer().analyze(repositoryURL: target)
        }
        let logsValue: LogSummary? = await run(CLIScan.sectionLabels[2]) {
            try await FileLogAnalyzer().analyze(projectRoot: target, extraLogURLs: [], withinDays: 7)
        }
        let depsValue: DependencyReport? = await run(CLIScan.sectionLabels[3]) {
            try await ManifestDependencyAnalyzer().analyze(projectRoot: target, allowNetwork: false)
        }
        let coverageValue: CoverageMetrics? = await run(CLIScan.sectionLabels[4]) {
            try await CoverageAnalyzer().analyze(projectRoot: target, options: .default)
        }
        report.code = codeValue
        report.git = gitValue
        report.logs = logsValue
        report.dependencies = depsValue
        report.coverage = coverageValue
        report.health = WeightedHealthScorer().score(HealthInputs(
            code: report.code, git: report.git, logs: report.logs,
            dependencies: report.dependencies, coverage: report.coverage, previousScore: nil))
        report.attemptedAt = Date()
        report.failedSections = failures
        store.save(report: report)
        let guiJSON = try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: sandbox.appendingPathComponent("reports"),
                                                    includingPropertiesForKeys: nil).first,
            "GUI 侧没落出报告文件")

        // ---- 覆盖率那一段必须逐字段相同（本轮改的就是它）
        let gui = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: guiJSON)) as? [String: Any])
        let cli = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try Data(contentsOf: cliJSON)) as? [String: Any])
        // 覆盖率段：把"每次运行必然不同"的两个时间字段按同一口径抹平后逐字段比。
        // （`report_parity.py` 的容忍清单里 `*At` 就包含它们；这里先自己做一遍，
        //  免得只能等脚本给出一个不带上下文的不等行。）
        let guiCov = try XCTUnwrap(stripDates(gui["coverage"]))
        let cliCov = try XCTUnwrap(stripDates(cli["coverage"]))
        XCTAssertTrue(guiCov.isEqual(cliCov),
                      "两条路落出来的覆盖率段不一致：GUI=\(guiCov) CLI=\(cliCov)")

        // ---- 全字段对表：真跑仓库里那把尺子
        let scripts = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scripts/report_parity.py")
        XCTAssertTrue(FileManager.default.fileExists(atPath: scripts.path), "对表脚本不在 \(scripts.path)")
        let parity = Process()
        parity.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        parity.arguments = [scripts.path, guiJSON.path, cliJSON.path, target.path]
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
