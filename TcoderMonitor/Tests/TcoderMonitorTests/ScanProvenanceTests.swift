import XCTest
@testable import TcoderMonitor

/// 溯源块（`Models/ScanProvenance.swift`）的机制测试。
///
/// 立这条的理由是整改意见第十节：报告里每条结论要能落到「哪个提交、哪个工具版本、
/// 哪一版判据、当时工作区干不干净」。这一族断言全部喂**合成报告**，不依赖真实仓库，
/// 因此与「本仓此刻有没有未提交改动」无关 —— 债还上了它不会红，机制坏了它一定红。
final class ScanProvenanceTests: XCTestCase {

    private func makeReport(git: GitInsights?) -> ProjectReport {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/provenance-fixture"))
        report.git = git
        return report
    }

    private func makeGit(headSHA: String = "abc1234", branch: String = "main",
                         dirty: Bool? = nil, entries: Int? = nil, note: String = "") -> GitInsights {
        var git = GitInsights()
        git.isRepository = true
        git.headSHA = headSHA
        git.branch = branch
        git.workingTreeDirty = dirty
        git.dirtyEntryCount = entries
        git.dirtyProbeNote = note
        return git
    }

    // MARK: - 装配

    func testProvenanceCarriesCommitBranchAndVersions() {
        let report = makeReport(git: makeGit(dirty: false, entries: 0))
        let p = ScanProvenance(report: report, scannedRoot: "/tmp/provenance-fixture", producedBy: "cli")
        XCTAssertEqual(p.sourceCommit, "abc1234")
        XCTAssertEqual(p.sourceBranch, "main")
        XCTAssertEqual(p.workingTreeDirty, false)
        XCTAssertEqual(p.dirtyEntryCount, 0)
        XCTAssertNil(p.dirtyProbeNote, "量到了就不该留原因")
        XCTAssertEqual(p.schemaVersion, ScanProvenance.currentSchemaVersion)
        XCTAssertEqual(p.rulesVersion, ScanProvenance.rulesVersionStamp)
        XCTAssertEqual(p.producedBy, "cli")
        XCTAssertTrue(p.toolVersion?.contains("debug") == true || p.toolVersion?.contains("release") == true)
    }

    func testAbsentGitSectionIsStatedAndNotInvented() {
        let p = ScanProvenance(report: makeReport(git: nil), scannedRoot: "/x", producedBy: "cli")
        XCTAssertNil(p.sourceCommit, "没有 Git 那一路就不能有提交号 —— 空串会被读成「提交号为空」")
        XCTAssertNil(p.sourceBranch)
        XCTAssertNil(p.workingTreeDirty, "没量到 ≠ 干净")
        XCTAssertFalse(p.dirtyProbeNote?.isEmpty == true, "缺证据必须自带原因")
    }

    func testEmptyHeadSHAIsTreatedAsUnmeasured() {
        let p = ScanProvenance(report: makeReport(git: makeGit(headSHA: "", branch: "")),
                               scannedRoot: "/x", producedBy: "gui")
        XCTAssertNil(p.sourceCommit)
        XCTAssertNil(p.sourceBranch)
    }

    // MARK: - 三态判据（`git status --porcelain`）

    func testStatusProbeDistinguishesCleanDirtyAndUnmeasured() {
        switch ShellGitAnalyzer.workingTree(from: .init(stdout: "", stderr: "", succeeded: true, timedOut: false)) {
        case .clean: break
        default: XCTFail("空输出必须判「干净」")
        }
        switch ShellGitAnalyzer.workingTree(from: .init(stdout: " M a.swift\n?? b.swift\n",
                                                       stderr: "", succeeded: true, timedOut: false)) {
        case .dirty(let entries): XCTAssertEqual(entries, 2)
        default: XCTFail("两行输出必须判「有未提交改动 2 条」")
        }
        switch ShellGitAnalyzer.workingTree(from: .init(stdout: "", stderr: "fatal: not a git repository",
                                                       succeeded: false, timedOut: false)) {
        case .notMeasured(let reason): XCTAssertEqual(reason, "fatal: not a git repository")
        default: XCTFail("非零退出必须判「没量到」，不许退回猜干净")
        }
        switch ShellGitAnalyzer.workingTree(from: .init(stdout: "", stderr: "", succeeded: false, timedOut: true)) {
        case .notMeasured(let reason): XCTAssertEqual(reason, "工作区探测超时")
        default: XCTFail("超时必须判「没量到」")
        }
    }

    func testSuccessfulButSilentFailureKeepsGitReason() {
        // 反例：git 退出码非零、stderr 也是空的。这时不许给一个空原因，
        // 否则上屏会读成「没量到 ·（空白）」，排查的人拿不到任何线索。
        let outcome = ShellGitAnalyzer.GitCommandOutcome(stdout: "", stderr: "\n", succeeded: false, timedOut: false)
        guard case .notMeasured(let reason) = ShellGitAnalyzer.workingTree(from: outcome) else {
            return XCTFail("必须判没量到")
        }
        XCTAssertFalse(reason.isEmpty)
    }

    // MARK: - 上屏读数

    func testUnmeasuredWorkingTreeNeverRendersAsClean() {
        var p = ScanProvenance()
        p.workingTreeDirty = nil
        p.dirtyProbeNote = "工作区探测超时"
        let text = p.oneLineSummary
        XCTAssertTrue(text.contains("未量到"), text)
        XCTAssertFalse(text.contains("干净"), "「未量到」绝不允许渲染成「干净」")
    }

    func testCleanWorkingTreeRendersAsClean() {
        let p = ScanProvenance(report: makeReport(git: makeGit(dirty: false, entries: 0)),
                               scannedRoot: "/x", producedBy: "cli")
        XCTAssertTrue(p.oneLineSummary.contains("干净"))
    }

    func testMissingValuesRenderAsUnrecordedInsteadOfBlank() {
        let text = ScanProvenance().oneLineSummary
        XCTAssertTrue(text.contains("未记录"), text)
        XCTAssertFalse(text.contains("提交 （"), "提交号缺席时不许打成一个空格糊过去")
    }

    func testCLITextPrintsProvenanceBeforeAnyScore() {
        var report = makeReport(git: makeGit(headSHA: "deadbee", dirty: true, entries: 3))
        report.provenance = ScanProvenance(report: report, scannedRoot: "/tmp/provenance-fixture", producedBy: "cli")
        let text = CLIScoreText.render(report, exit: .partial)
        let lines = text.components(separatedBy: "\n")
        XCTAssertGreaterThan(lines.count, 1, text)
        XCTAssertTrue(lines[1].hasPrefix("溯源："), "溯源必须紧跟首行、在任何读数之前：\n" + text)
        XCTAssertTrue(text.contains("deadbee"))
        XCTAssertTrue(text.contains("有未提交改动 3 条"))
    }

    func testCLITextStillPrintsLineWhenProvenanceAbsent() {
        // 旧报告（没有溯源块）必须打「未记录」而不是整行消失 —— 静默缺席会被读成「无需溯源」。
        let text = CLIScoreText.render(makeReport(git: makeGit()), exit: .ok)
        XCTAssertTrue(text.contains("溯源：未记录"), text)
    }

    func testCommitFromAnOuterRepositoryIsFlagged() {
        // 扫的是子目录、`.git` 在上一层：提交号是真的，但**归属**必须说清楚，
        // 否则会被读成「这个子目录自己就是那个提交」。真子进程实测撞过（台账 §25）。
        var git = makeGit(headSHA: "outer01")
        git.resolvedRepositoryRoot = "/tmp/outer"
        let p = ScanProvenance(report: makeReport(git: git), scannedRoot: "/tmp/outer/sub", producedBy: "cli")
        // 两格自 #60 起都是**物理写法**（`ScannedPath.canonical`）：传进来的别名短写会被归一，
        // 于是同一份报告里 `scannedRoot` 与 `resolvedGitRoot` 不会一个带 `/private` 一个不带。
        // 断言的语义没改（「提交号来自外层那个仓库，要说清是哪一层」），只是形状换了。
        XCTAssertEqual(p.resolvedGitRoot, "/private/tmp/outer")
        XCTAssertTrue(p.oneLineSummary.contains("提交号来自外层仓库 /private/tmp/outer"), p.oneLineSummary)
    }

    func testSameRootDoesNotPrintRelocationNote() {
        var git = makeGit(headSHA: "same001")
        git.resolvedRepositoryRoot = "/tmp/provenance-fixture"
        let p = ScanProvenance(report: makeReport(git: git), scannedRoot: "/tmp/provenance-fixture", producedBy: "cli")
        XCTAssertNil(p.resolvedGitRoot, "相等时不该造出一条「外层仓库」的假提示")
        XCTAssertFalse(p.oneLineSummary.contains("外层仓库"))
    }

    // MARK: - 一把尺子

    func testCLIIdentityAndProvenanceShareOneRuler() {
        XCTAssertEqual(CLIConfig.buildConfiguration, ScanProvenance.buildConfiguration)
        XCTAssertEqual(CLIConfig.bundleIdentity, ScanProvenance.bundleIdentity)
        XCTAssertTrue(CLIConfig.versionLine.contains(ScanProvenance.bundleIdentity))
    }

    // MARK: - 落盘兼容（「落盘字段必须 Optional」那条规矩）

    func testReportWithoutProvenanceKeyStillDecodes() throws {
        let data = try JSONEncoder().encode(makeReport(git: makeGit()))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json.removeValue(forKey: "provenance")
        let restored = try JSONDecoder().decode(ProjectReport.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.provenance)
        XCTAssertEqual(restored.project.path, "/tmp/provenance-fixture")
    }

    func testProvenanceRoundTripKeepsEveryField() throws {
        var git = makeGit(headSHA: "cafe123", branch: "ws/x", dirty: true, entries: 7)
        git.resolvedRepositoryRoot = "/tmp/elsewhere"
        var report = makeReport(git: git)
        report.provenance = ScanProvenance(report: report, scannedRoot: "/tmp/provenance-fixture", producedBy: "gui")
        let restored = try JSONDecoder().decode(ProjectReport.self, from: try JSONEncoder().encode(report))
        let p = try XCTUnwrap(restored.provenance)
        XCTAssertEqual(p.sourceCommit, "cafe123")
        XCTAssertEqual(p.sourceBranch, "ws/x")
        XCTAssertEqual(p.resolvedGitRoot, "/private/tmp/elsewhere")
        XCTAssertEqual(p.workingTreeDirty, true)
        XCTAssertEqual(p.dirtyEntryCount, 7)
        XCTAssertEqual(p.producedBy, "gui")
        XCTAssertEqual(p.scannedRoot, "/private/tmp/provenance-fixture",
                       "进报告的被扫根统一成物理写法（#60），旧报告缺这一格照旧解得开")
        XCTAssertEqual(p.schemaVersion, ScanProvenance.currentSchemaVersion)
        XCTAssertNotNil(p.toolVersion)
        XCTAssertNotNil(p.rulesVersion)
    }

    // MARK: - 戳本身

    func testRulesStampIsWellFormed() {
        // 判据版本戳给人读，也给人**比对**：格式漂了就说明有人随手填了个日期。
        let stamp = ScanProvenance.rulesVersionStamp
        XCTAssertNotNil(stamp.range(of: #"^\d{4}\.\d{2}-r\d+$"#, options: .regularExpression),
                        "规则戳 \(stamp) 不符合 2026.09-r1 形状")
        XCTAssertGreaterThan(ScanProvenance.currentSchemaVersion, 0)
    }

    // MARK: - 写者必须有读者（结构性钉）

    func testProvenanceHasBothWritersAndReaders() throws {
        let root = Self.repositoryRoot()
        let sources = try Self.swiftFiles(under: root, directory: "Sources/TcoderMonitor")
        XCTAssertFalse(sources.isEmpty, "扫描面为空 —— 这条断言不作数")
        let writes = sources.filter { Self.text(of: $0).contains("ScanProvenance(report:") }
            .map { $0.lastPathComponent }
        XCTAssertEqual(Set(writes), ["CLIScan.swift", "AppState.swift"],
                       "两条产出路都要装配溯源块，少一条就会产出「无溯源」的报告")
        let reads = sources.filter { Self.text(of: $0).contains("report.provenance") || Self.text(of: $0).contains(".provenance?") }
            .map { $0.lastPathComponent }
        XCTAssertFalse(reads.isEmpty, "只有写点没有读者的标记等于没落盘")
    }

    // MARK: - 夹具

    private static func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)      // .../TcoderMonitor/Tests/TcoderMonitorTests/本文件
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func swiftFiles(under root: URL, directory: String) -> [URL] {
        let dir = root.appendingPathComponent(directory)
        let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)
        return (enumerator?.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []).sorted { $0.path < $1.path }
    }

    private static func text(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}
