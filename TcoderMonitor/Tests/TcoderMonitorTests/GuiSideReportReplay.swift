import Foundation
import XCTest
@testable import TcoderMonitor

/// GUI 侧那份报告的**唯一重演入口**（两条 GUI↔CLI 对表用例共用）。
///
/// 为什么只许有一个入口：这两条对表都在**测试里重演 GUI 装配**而不是调用它
/// （本仓同一时刻只允许一个人起 App，且一切点击/滚动类取证已被叫停），
/// 而装配的形状跟着 `AppState.scan(project:)` 走。副本各自现算时，契约每加一格
/// 就只有被点名的那份会补上、另一份静默落后 —— 这不是推测，是实测：
///   · R10 先漏过 `provenance` / `analyzerLedger`（于是 RD-31 把五路段抽出来共用）；
///   · RD-31 × RD-60 再撞一次：漂移那两枚指纹只补进了覆盖率那条对表，
///     崩溃证据那条的副本没补 ⇒ GUI 侧 `sourceDriftDuringScan` **整键缺席**、
///     CLI 侧在场（真子进程实测 CLI 落的是 `false`），`report_parity.py` 当场判红。
/// 并进来之后，`AppState` 再加字段时这里只有一个地方会落后。
///
/// 判据、路名（`AnalyzerLedger.sectionLabels[i]`）、调用顺序与搬前逐字一致 —— 搬动就只是搬动。
/// ⚠️ 这个入口重演的仍是**测试侧装配**：它不是 `AppState` 的替身，屏上那一路的守卫
///    （`ScanSourceDriftTests.testBothAssemblyPointsRecordDrift`）照旧单独点名 Sources 两个写者。
enum GuiSideReportReplay {

    /// 五路各跑一次交回的六样东西：五枚读数 + 台账要吃的 `attempt` 列表。
    struct Sections {
        var code: CodeMetrics?
        var git: GitInsights?
        var logs: LogSummary?
        var dependencies: DependencyReport?
        var coverage: CoverageMetrics?
        var attempts: [AnalyzerAttempt]
    }

    /// 重演一次 GUI 装配并落盘，交回那份报告在盘上的地址。
    ///
    /// `sandbox` 必须是这一趟自己造的目录（`ProjectStore.storageDirectory` 可换，
    /// 就是为了不抢全机唯一的那份支持目录）；`projectName` 落进 `project.*`，
    /// 那是对表口径里点名容忍的身份格，两条对表各叫各的名。
    @MainActor
    static func persist(projectDirectory: URL, sandbox: URL, projectName: String) async throws -> URL {
        // `save` 里是 `try?`：reports 目录没建就会**静默不写文件**（实测第一版就这么"没落出报告"过）。
        try FileManager.default.createDirectory(at: sandbox.appendingPathComponent("reports"),
                                                withIntermediateDirectories: true)
        let store = ProjectStore()
        store.storageDirectory = sandbox
        let project = store.add(path: projectDirectory.path, name: projectName)
        // RD-31 的开工指纹必须在五路**之前**采：这份入口重演的是 GUI 装配，
        // 少采一枚 ⇒ 收工侧无从比对 ⇒ `nil` ⇒ `encodeIfPresent` 整键缺席，对表尺子判红。
        let fingerprintAtStart = SourceTreeFingerprint.probe(root: projectDirectory)
        let sections = await fiveSections(root: projectDirectory)
        var report = ProjectReport(project: project)
        report.code = sections.code
        report.git = sections.git
        report.logs = sections.logs
        report.dependencies = sections.dependencies
        report.coverage = sections.coverage
        report.health = WeightedHealthScorer().score(HealthInputs(code: report.code, git: report.git,
                                                                  logs: report.logs,
                                                                  dependencies: report.dependencies,
                                                                  coverage: report.coverage,
                                                                  previousScore: nil))
        report.generatedAt = Date()
        report.attemptedAt = Date()
        report.failedSections = sections.attempts.compactMap { $0.failureReason == nil ? nil : $0.label }
        report.analyzerLedger = AnalyzerLedger.records(from: sections.attempts)
        // 溯源块最后装配：它只**读** Git 那一路已经拿到的提交号与工作区状态，不另起第二个 git 进程。
        var provenance = ScanProvenance(report: report, scannedRoot: projectDirectory.path,
                                        producedBy: "gui")
        provenance.recordDrift(startingFrom: fingerprintAtStart,
                               endingAt: SourceTreeFingerprint.probe(root: projectDirectory))
        report.provenance = provenance
        store.save(report: report)
        return try XCTUnwrap(
            FileManager.default.contentsOfDirectory(at: sandbox.appendingPathComponent("reports"),
                                                    includingPropertiesForKeys: nil).first,
            "GUI 侧没落出报告文件（reports 目录没建就会静默不写）")
    }

    /// 五路依次跑一遍，顺序即 `AnalyzerLedger.sectionLabels` 的下标序（0…4）。
    /// `attempts[0].limitsHit` 只有代码那一路有上限读数，所以在交回前单独补那一格。
    @MainActor
    static func fiveSections(root directory: URL) async -> Sections {
        let code = await AnalyzerLedger.timed(AnalyzerLedger.sectionLabels[0]) {
            try await FileSystemCodeAnalyzer().analyze(root: directory, options: .default)
        }
        let git = await AnalyzerLedger.timed(AnalyzerLedger.sectionLabels[1]) {
            try await ShellGitAnalyzer().analyze(repositoryURL: directory)
        }
        let logs = await AnalyzerLedger.timed(AnalyzerLedger.sectionLabels[2]) {
            try await FileLogAnalyzer().analyze(projectRoot: directory, extraLogURLs: [], withinDays: 7)
        }
        let deps = await AnalyzerLedger.timed(AnalyzerLedger.sectionLabels[3]) {
            try await ManifestDependencyAnalyzer().analyze(projectRoot: directory, allowNetwork: false)
        }
        let coverage = await AnalyzerLedger.timed(AnalyzerLedger.sectionLabels[4]) {
            try await CoverageAnalyzer().analyze(projectRoot: directory, options: .default)
        }
        var attempts = [code.attempt, git.attempt, logs.attempt, deps.attempt, coverage.attempt]
        attempts[0].limitsHit = code.value?.scanLimitations ?? []
        return Sections(code: code.value, git: git.value, logs: logs.value,
                        dependencies: deps.value, coverage: coverage.value,
                        attempts: attempts)
    }
}
