import XCTest
@testable import TcoderMonitor

/// 分析器台账（整改意见 §十一「每个分析器的状态 / 耗时 / 上限 / 失败原因」）的守卫。
///
/// 台账要解决的是一件事：**"这一路没出声"曾经只有一种表达**。
/// 原来 `ProjectReport` 只有 `failedSections`（挂掉的路名）与 `code.durationMs`（唯一一路耗时），
/// 于是"跑通了没发现问题"与"跑挂了"与"撞到上限只量到一半"与"压根没排进去"四件事在报告里长一个样。
final class AnalyzerLedgerTests: XCTestCase {

    private func attempt(_ label: String,
                         didRun: Bool = true,
                         durationMs: Int? = 7,
                         failureReason: String? = nil,
                         limitsHit: [String] = []) -> AnalyzerAttempt {
        AnalyzerAttempt(label: label, didRun: didRun, durationMs: durationMs,
                        failureReason: failureReason, limitsHit: limitsHit)
    }

    // MARK: - 四态各自成立

    func testFourStatesAreFourDifferentThings() {
        let records = AnalyzerLedger.records(from: [
            attempt("代码扫描"),
            attempt("Git 分析", limitsHit: ["明细榜单截断到 20 块"]),
            attempt("错误日志", failureReason: "读取目录被拒绝"),
            attempt("依赖分析", didRun: false),
        ])
        XCTAssertEqual(records.map(\.state), [.ok, .partial, .failed, .notRun])
        XCTAssertEqual(records.map(\.name), ["代码扫描", "Git 分析", "错误日志", "依赖分析"])
    }

    /// `notRun` 不许带着"看起来像量过"的东西出场 —— 否则它会被读成"这一维没问题"。
    func testNotRunCarriesNoEvidence() {
        let record = attempt("依赖分析", didRun: false, durationMs: 9_999,
                             failureReason: "不该出现的原话", limitsHit: ["不该出现"]).record
        XCTAssertEqual(record.state, .notRun)
        XCTAssertNil(record.durationMs, "没跑就没有耗时")
        XCTAssertNil(record.failureReason, "没跑不是跑挂")
        XCTAssertNil(record.limitsHit)
    }

    func testFailedKeepsTheRawReasonAndPartialNamesTheLimit() {
        let failed = attempt("错误日志", failureReason: "The folder doesn’t exist.").record
        XCTAssertEqual(failed.state, .failed)
        XCTAssertEqual(failed.failureReason, "The folder doesn’t exist.", "原因原文要能追溯")

        let partial = attempt("测试覆盖率", limitsHit: ["未读完全部目录（1 个读不了）"]).record
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.limitsHit, ["未读完全部目录（1 个读不了）"])
        XCTAssertNil(partial.failureReason, "撞到上限不是失败")
    }

    // MARK: - 装配口：CLI 与 GUI 共用一份

    func testTimedMeasuresSuccessAndKeepsRawError() async {
        let ok = await AnalyzerLedger.timed("代码扫描") { 42 }
        XCTAssertEqual(ok.value, 42)
        XCTAssertEqual(ok.attempt.label, "代码扫描")
        XCTAssertGreaterThanOrEqual(ok.attempt.durationMs ?? 0, 1)
        XCTAssertNil(ok.attempt.failureReason)

        struct Boom: Error {}
        let bad = await AnalyzerLedger.timed("Git 分析") { throw Boom() }
        XCTAssertNil(bad.value)
        XCTAssertNotNil(bad.attempt.failureReason, "失败路必须留下原因，而不是只留一个路名")
    }

    /// 两条装配路各写一次台账；少一处就会产出一半"没有台账"的报告（RD-30 那一族）。
    func testBothAssemblyPointsWriteTheLedger() throws {
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var hits: [String: Int] = [:]
        for name in ["CLIScan.swift", "AppState.swift"] {
            let url = packageRoot.appendingPathComponent(
                name == "CLIScan.swift"
                    ? "Sources/TcoderMonitor/Services/CLI/CLIScan.swift"
                    : "Sources/TcoderMonitor/App/AppState.swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            // 数**函数名**而不是整行：`records(from:` 被折成两行时按行匹配会得到 0，
            // 那条假红比假绿更难查（本仓踩过"图案从未生效"的永真绿，反过来同理）。
            let count = text.split(separator: "\n").filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
                    && $0.contains("AnalyzerLedger.records")
            }.count
            XCTAssertEqual(count, 1, "\(name) 必须恰好写一次台账")
            hits[name] = count
        }
        XCTAssertEqual(hits.values.reduce(0, +), 2, "两个写者都要在：\(hits)")
    }

    /// 真跑一次 CLI 装配：五路都得有台账、都得给出耗时（空目录也跑得动，别拿夹具当证据）。
    @MainActor
    func testHeadlessOutcomeFillsFiveLedgerRows() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let outcome = await CLIScan().outcome(path: dir.path, allowNetwork: false)
        let ledger = try XCTUnwrap(outcome.report?.analyzerLedger, "无头装配没写台账")
        XCTAssertEqual(ledger.map(\.name), AnalyzerLedger.sectionLabels)
        XCTAssertFalse(ledger.contains { $0.durationMs == nil && $0.state != .notRun },
                       "跑了却没耗时 ⇒ 计时没装在唯一的装配口上：\(ledger)")
        XCTAssertEqual(ledger.filter { $0.state == .failed }.count, outcome.report?.failedSections.count ?? -1,
                       "台账里的失败数与 failedSections 必须是同一批事实数出来的")
    }

    // MARK: - 落盘规矩

    /// 旧报告没有这一格 ⇒ 整键缺席、解码不许整份失败，也不许被兜成"五路都没跑"。
    func testReportWithoutLedgerKeyStillDecodesAsNil() throws {
        var report = ProjectReport(project: MonitoredProject(name: "n", path: "/tmp/n"))
        report.analyzerLedger = nil
        // 编解码必须成对（`.iso8601`）：上一版用默认 encoder 配 `tcoderReportDecoder`，
        // 得到的是 `project.addedAt` 的 typeMismatch —— 那是我测试写错，不是契约坏。
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(report)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("analyzerLedger"),
                       "没量到就该整键缺席，而不是写出空数组（空数组会被读成「五路都没跑」）")
        XCTAssertNil(try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: data)
                        .analyzerLedger)
    }

    func testLedgerRoundTripKeepsEveryField() throws {
        var report = ProjectReport(project: MonitoredProject(name: "n", path: "/tmp/n"))
        report.analyzerLedger = AnalyzerLedger.records(from: [
            attempt("代码扫描", limitsHit: ["块注释未闭合 ⇒ 只能当部分测量读"]),
        ])
        let data = try JSONEncoder().encode(report)
        let back = try JSONDecoder().decode(ProjectReport.self, from: data)
        XCTAssertEqual(back.analyzerLedger, report.analyzerLedger)
    }
}
