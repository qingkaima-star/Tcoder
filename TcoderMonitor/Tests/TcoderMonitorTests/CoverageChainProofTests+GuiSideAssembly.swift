import Foundation
import XCTest
@testable import TcoderMonitor

// GUI 侧那五路分析的**装配段**，从 `CoverageChainProofTests.persistGuiSideReport` 里整块搬来。
//
// 为什么搬、为什么搬进这个文件而不是留在原文件里：这条对表用例重演的是**整段 GUI 装配**
// （那正是它要钉的东西），搬动之后 `persistGuiSideReport` 从 54 行回到 38 行，落在
// `FileSystemCodeAnalyzer.longFunctionThreshold`（50 行）口径之内；而原文件已在 400 行闸门
// （`X3TestSizeAuditTests` 与产品侧「巨大文件」同一口径）只剩 1 行余量，就地抽助手必然把它推过去。
// 判据、路名（`AnalyzerLedger.sectionLabels[i]`）、调用顺序、注释与搬前逐字一致 —— 搬动就只是搬动。
//
// ⚠️ 助手与结构体是 module 内可见而不是 `private`：`private` 出不了自己那个文件，而调用方
//    `persistGuiSideReport` 必须留在原文件里读 XCTestCase 那个 `private var base`（沙箱支持目录）。
extension CoverageChainProofTests {

    /// 五路各跑一次交回的六样东西：五枚读数 + 台账要吃的 `attempt` 列表。
    struct GuiSideSections {
        var code: CodeMetrics?
        var git: GitInsights?
        var logs: LogSummary?
        var dependencies: DependencyReport?
        var coverage: CoverageMetrics?
        var attempts: [AnalyzerAttempt]
    }

    /// 五路依次跑一遍，顺序即 `AnalyzerLedger.sectionLabels` 的下标序（0…4）。
    /// `attempts[0].limitsHit` 只有代码那一路有上限读数，所以在交回前单独补那一格。
    @MainActor
    func runGuiSideSections(root directory: URL) async -> GuiSideSections {
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
        return GuiSideSections(code: code.value, git: git.value, logs: logs.value,
                               dependencies: deps.value, coverage: coverage.value,
                               attempts: attempts)
    }
}
