import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X1 CodeServices（本包 = `Services/Code/**` + `Services/Performance/ProcessInspector.swift`）。
///
/// **本包「真修」的测量仪与守卫。** 2026-09-20 夜用户裁定：用 Tcoder 自己扫 Tcoder，
/// 按它报出来的扣分项真修，不许为了变绿放宽任何阈值。这条守卫就是那件事的机器形状：
///
/// 1. **CC 用工具自己的口径**：直接调 `ComplexityEngine.functions(in:)`，与自扫报告
///    （`TCODER_SELF_SCAN=1` 取证落盘的「高圈复杂度函数 Top 榜」）同一个函数、同一把尺子，
///    不是我另写一份「看起来像 McCabe」的计数器。尺子分叉过一次已经够糟了。
/// 2. **三个上限全部引用冻结区的既有阈值，不新造数字**：
///    - 复杂度 16 = `SelfScanHarnessCase.complexFunctionBar`（自扫报告点名的门槛）
///    - 函数 50 行 = `FileSystemCodeAnalyzer.longFunctionThreshold`（工具「超长函数」口径）
///    - 文件 400 行 = `FileSystemCodeAnalyzer.mediumFileLines`（工具「巨大文件」口径）
///    这里只是**把它们当自己的验收线**，一个字都没改；`mediumFileLines = 400` 仍是
///    产品侧的「巨大文件」判据，`highFileLines = 800` 那条棘轮也不受本文件影响。
/// 3. **分母守卫**：三条主断言之前先确认「真的扫到了文件、真的认出了函数」。
///    扫到 0 个就报 0 个热点是永真绿，AGENTS.md 里已经栽过一次。
///
/// 失败信息会逐个点名 `文件:行 函数名 CC=N`，是派工单不是谜语。
final class CodeComplexityDebtTests: XCTestCase {

    /// 仓库根：本文件 → TcoderMonitorTests → Tests → TcoderMonitor（包根）。
    /// 与 `SourceFileReachabilityTests` / `SelfScanHarnessCase` 同一套 `#filePath` 回溯写法，
    /// 这样主树和各个 worktree 都能跑（测试进程的 CWD 不是包根）。
    private static let packageRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // TcoderMonitorTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // TcoderMonitor

    private static let codeDirectory = packageRoot
        .appendingPathComponent("Sources/TcoderMonitor/Services/Code", isDirectory: true)
    private static let performanceDirectory = packageRoot
        .appendingPathComponent("Sources/TcoderMonitor/Services/Performance", isDirectory: true)

    /// 本包外的性能文件（WS-C/性能总工名下，正在别处处理），这里必须排除。
    private static let excludedPerformanceFiles: Set<String> = [
        "MachSystemMonitor.swift", "SystemSampler.swift", "FramePulse.swift",
    ]

    // MARK: - 验收线（逐条抄自冻结区，改动需先报总工）

    static let complexityCeiling = SelfScanHarnessCase.complexFunctionBar
    static let functionLineCeiling = FileSystemCodeAnalyzer.longFunctionThreshold
    static let fileLineCeiling = FileSystemCodeAnalyzer.mediumFileLines

    // MARK: - 取数

    struct FileReport {
        var name: String
        var lines: Int
        var functions: [FunctionCandidate]
    }

    /// 用产品侧同一个 `SourceTreeScanner` + `ComplexityEngine` 扫本包的每个文件；
    /// 行数直接借 `SelfScanHarnessCase.wcStyleLineCount` —— 那把尺子在本仓**只允许有一份**
    /// （它自己的注释就写着「内联副本会在下一次改动里悄悄分叉」），所以这里不抄第二份。
    private func reports() async throws -> [FileReport] {
        let scanned = await SourceTreeScanner(options: .default).scan(root: Self.codeDirectory).files
        let perf = await SourceTreeScanner(options: .default).scan(root: Self.performanceDirectory).files
        let owned = perf.filter {
            Self.excludedPerformanceFiles.contains($0.url.lastPathComponent) == false
        }
        var result: [FileReport] = []
        for file in scanned + owned {
            let text = try String(contentsOf: file.url, encoding: .utf8)
            result.append(FileReport(
                name: file.url.lastPathComponent,
                lines: SelfScanHarnessCase.wcStyleLineCount(text),
                functions: ComplexityEngine.functions(in: file)
            ))
        }
        return result.sorted { $0.name < $1.name }
    }


    private func roster(_ reports: [FileReport]) -> String {
        reports.map { report in
            let hottest = report.functions.max { $0.complexity < $1.complexity }
            return "  \(report.name) \(report.lines) 行 / \(report.functions.count) 个函数 /"
                + " 最高 CC=\(hottest?.complexity ?? 0)（\(hottest?.name ?? "-")）"
        }.joined(separator: "\n")
    }

    // MARK: - 分母守卫（先证明尺子在跑，再谈结论）

    func testScannerActuallySeesThisPackage() async throws {
        let reports = try await self.reports()
        XCTAssertGreaterThanOrEqual(reports.count, 13,
                                    "本包只扫到 \(reports.count) 个文件，路径口径八成失效：\n\(roster(reports))")
        let functions = reports.flatMap(\.functions)
        // 分母下限取 120 而不是「当前实测 229」：拆分本身会让认出的函数变多，
        // 把这条写成当前值就变成一条谁都不敢碰的假基线。它的唯一职责是排除
        // 「扫到 0 个函数 → 三条主断言永真绿」，那个失败模式在 120 这里同样跑不掉。
        XCTAssertGreaterThanOrEqual(functions.count, 120,
                                    "本包只认出 \(functions.count) 个函数，复杂度断言就成了永真绿")
        XCTAssertTrue(reports.contains { $0.name == "ProcessInspector.swift" },
                      "ProcessInspector.swift 没进入本包清单，性能侧的债就没人管了")
        XCTAssertTrue(reports.contains { $0.name == "DuplicationEngine.swift" })
        print("【X1 分母】本包 \(reports.count) 个文件、认出 \(functions.count) 个函数，"
            + "上限口径：CC<\(Self.complexityCeiling) 函数≤\(Self.functionLineCeiling) 行 文件≤\(Self.fileLineCeiling) 行")
    }

    // MARK: - 主门 1：文件长度

    func testEveryOwnedFileStaysWithinTheHugeFileBar() async throws {
        let reports = try await self.reports()
        let over = reports.filter { $0.lines > Self.fileLineCeiling }
        XCTAssertTrue(over.isEmpty, """
        本包有 \(over.count) 个文件超过工具「巨大文件」口径 \(Self.fileLineCeiling) 行：
        \(over.map { "  \($0.name) \($0.lines) 行" }.joined(separator: "\n"))
        阈值不动，把文件按职责拆开才是修复。
        """)
    }

    // MARK: - 主门 2：圈复杂度

    func testNoOwnedFunctionReachesTheComplexityBar() async throws {
        let reports = try await self.reports()
        let hot = reports.flatMap { report in
            report.functions
                .filter { $0.complexity >= Self.complexityCeiling }
                .map { "\(report.name):\($0.startLine) \($0.name) CC=\($0.complexity)（\($0.lineCount) 行）" }
        }.sorted()
        XCTAssertTrue(hot.isEmpty, """
        本包仍有 \(hot.count) 个函数 CC ≥ \(Self.complexityCeiling)（工具判[高]风险那条线）：
        \(hot.joined(separator: "\n"))
        """)
        let worst = reports.flatMap(\.functions).max { $0.complexity < $1.complexity }
        print("【X1 复杂度】本包最高 CC=\(worst?.complexity ?? 0)"
            + "（\(worst?.name ?? "-") @ \(worst.map { "\($0.lineCount) 行" } ?? "无" )）")
    }

    // MARK: - 主门 3：函数长度

    func testNoOwnedFunctionExceedsTheLongFunctionBar() async throws {
        let reports = try await self.reports()
        let long = reports.flatMap { report in
            report.functions
                .filter { $0.lineCount > Self.functionLineCeiling }
                .map { "\(report.name):\($0.startLine) \($0.name) \($0.lineCount) 行 CC=\($0.complexity)" }
        }.sorted()
        XCTAssertTrue(long.isEmpty, """
        本包仍有 \(long.count) 个函数超过工具「超长函数」口径 \(Self.functionLineCeiling) 行：
        \(long.joined(separator: "\n"))
        """)
    }
}
