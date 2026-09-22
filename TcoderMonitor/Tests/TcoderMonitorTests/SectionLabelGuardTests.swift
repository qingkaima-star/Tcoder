import XCTest
@testable import TcoderMonitor

/// 五路路名只许有一份真值 —— 从 `CLIHeadlessTests.swift` 拆出来（那个文件越过 400 行口径，
/// "拆文件才是修复"是本仓自己的规矩），断言与判据一字未改。
/// 立案缘由：`AnalyzerLedger` 一上屏，同一次失败在界面上叫"日志分析"、在报告里叫"错误日志"
/// 这种分叉就成了硬红；而原守卫只扫 `sectionFailures` 那五行，别名在它眼下活了很久。
final class SectionLabelGuardTests: XCTestCase {

    // MARK: - 一路名只许有一份真值

    private static let appStateURL = URL(fileURLWithPath: #filePath)   // …/Tests/TcoderMonitorTests/本文件.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TcoderMonitor/App/AppState.swift")

    /// CLI 与 GUI 各自硬编码一套中文路名，早晚分叉 —— 而 `failedSections` 是要被
    /// 人和机器一起读的字段，分叉之后"新老两条路对表"这句话就是空的。
    ///
    /// 2026-09-22 加严：原来这条只扫 `sectionFailures(...)` 那五行，于是 `AppState` 里
    /// **另一处**手打的路名（`attempt("日志分析")`、`attempt("覆盖率读取")`）在守卫眼下活着，
    /// 而它们与 `错误日志` / `测试覆盖率` 指的是同一一路 —— 台账一上屏就把这个分叉变成硬红。
    /// ⇒ 现在要求 AppState **一个路名字面量都不许有**，五个名字只许住在 `AnalyzerLedger.sectionLabels`。
    func test_sectionLabelsAreTheOnlyOnesAppStateUses() throws {
        let src = try String(contentsOf: Self.appStateURL, encoding: .utf8)
        XCTAssertEqual(Self.sectionNameLiteralsInAppState(src), [],
                       "路名只许引用 AnalyzerLedger.sectionLabels，不许在 AppState 里重打一遍")
        XCTAssertEqual(Self.sectionNamingCallsWithLiteralLabel(src), [],
                       "给路名传参的位置只许传 AnalyzerLedger.sectionLabels[i]，不许传字面量（别名就是从这儿长出来的）")
        XCTAssertEqual(CLIScan.sectionLabels, AnalyzerLedger.sectionLabels,
                       "CLI 必须转发那唯一一份，不许自己抄一遍")
        XCTAssertFalse(AnalyzerLedger.sectionLabels.isEmpty, "名单为空 ⇒ 上面几条是永真绿")
    }

    /// 元测试：上面那两条扫描必须真能抓到分叉，否则它们是永真绿。
    /// 两条各管一种形状：`重打 canonical 名字` 与 `在命名位传别名`。
    func test_sectionLabelScannerCatchesADivergedLabel() {
        let dirtyCanonical = """
        async let logs = AnalyzerLedger.timed("错误日志") { try await logAnalyzer.analyze() }
        let failures = Self.sectionFailures([
            (codeResult.attempt.failureReason, "代码扫描"),
        ])
        // 注释里出现"测试覆盖率"不算重打：扫描器只认代码行。
        """
        XCTAssertEqual(Self.sectionNameLiteralsInAppState(dirtyCanonical).sorted(),
                       ["代码扫描", "错误日志"].sorted(),
                       "扫描器必须抓出被重打的路名、且不被注释骗到")
        XCTAssertTrue(Self.sectionNameLiteralsInAppState("let x = 1").isEmpty)

        // 别名不在 canonical 名单里 ⇒ 靠"命名位不许传字面量"那条兜（旧代码正是这个形状）。
        let aliasLines = Self.sectionNamingCallsWithLiteralLabel(
            "async let c = Self.attempt(\"覆盖率读取\") { x }\n"
            + "async let d = AnalyzerLedger.timed(AnalyzerLedger.sectionLabels[4]) { y }\n")
        XCTAssertEqual(aliasLines, ["async let c = Self.attempt(\"覆盖率读取\") { x }"],
                       "别名形状必须被抓住，而引用名单的那一行必须放过")
    }

    private static func sectionNamingCallsWithLiteralLabel(_ src: String) -> [String] {
        src.split(separator: "\n").map(String.init).filter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("//") else { return false }
            // 两处"给路名传参"的位置：`attempt("` / `timed("` 后面紧跟引号就是传字面量。
            return trimmed.contains("attempt(\"") || trimmed.contains("timed(\"")
        }
    }

    private static func sectionNameLiteralsInAppState(_ src: String) -> [String] {
        src.split(separator: "\n").compactMap { rawLine -> String? in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("//") else { return nil }
            return AnalyzerLedger.sectionLabels.first { line.contains("\"\($0)\"") }
        }
    }
}
