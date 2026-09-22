import XCTest
@testable import TcoderMonitor

/// `CodeMetrics.highRiskHotspotCount`（§五"总数 vs 榜单截断"在复杂度这一格的收尾）。
///
/// 病根（总工实读原文才确认，两次改判都记在下面）：
/// `CodeRiskRows.highRiskFunctionCount` 原先写的是
/// `code.topComplexFunctions.filter { $0.risk.rank >= high.rank }.count`
/// —— 在**榜**上数，而榜被 `prefix(20)` 截过 ⇒ 仓库越大，"高复杂度函数 N 个"越报不满。
///
/// ⚠️ 顺带记一条我自己差点犯的错（写进契约注释，免得下一位再踩）：
/// 本来准备同时加一枚"热点总数"，读实现才发现
/// `FileSystemCodeAnalyzer.hotspots(…)` **根本不做筛选**，
/// 它把每个被识别函数都映射成 `FunctionHotspot` ⇒ 它的 `count` 就是函数总数。
/// 把那样一个数标成"热点总数"上屏就是一句谎话，所以这一格**没有加**。
/// 继承 `SelfScanHarnessCase` 只为了复用那台"一次扫描六个分析器"的缓存，
/// 不必在每个用例里重扫一遍本仓。
/// 测试自己那一侧的常量副本：故意与实现分开写，谁改了实现而没改这里，
/// 上面那两条"常量对账"就会先红，而不是留下一个看不懂的计数差。
enum ComplexityBarProbe {
    static let highRiskComplexity = 21
    static let longFunctionBar = 100
}

final class HighRiskHotspotCountTests: SelfScanHarnessCase {

    private func metrics(board: [FunctionHotspot], total: Int?) -> CodeMetrics {
        var metrics = CodeMetrics()
        metrics.topComplexFunctions = board
        metrics.highRiskHotspotCount = total
        return metrics
    }

    private func hotspot(_ complexity: Int, _ name: String) -> FunctionHotspot {
        FunctionHotspot(name: name, filePath: "/tmp/\(name).swift", startLine: 1,
                        lineCount: 40, cyclomaticComplexity: complexity, parameterCount: 1,
                        risk: .high)
    }

    // MARK: - 契约本身：有真总数时绝不再用榜长

    func testTotalWinsOverBoardLength() {
        let board = (1...20).map { hotspot(30 + $0, "f\($0)") }
        XCTAssertEqual(metrics(board: board, total: 57).reportedHighRiskHotspotCount, 57,
                       "落盘有真总数却回退到榜长 ⇒ 大项目永远显健康")
    }

    func testFallsBackToBoardWhenFieldAbsent() {
        let board = (1...20).map { hotspot(30 + $0, "f\($0)") }
        XCTAssertEqual(metrics(board: board, total: nil).reportedHighRiskHotspotCount, 20,
                       "旧报告缺这一格时退回榜内算法（偏小，但可用）")
    }

    func testBoardWithNoHighRiskReadsZeroNotNil() {
        var metrics = CodeMetrics()
        metrics.topComplexFunctions = []
        XCTAssertEqual(metrics.reportedHighRiskHotspotCount, 0)
    }

    // MARK: - 消费方走的是哪一格（防回潮）

    func testCodeRiskRowsUsesTheContractAccessor() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/TcoderMonitor/Views/Code/CodeRiskRows.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let codeLines = text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("//") == false }
        XCTAssertTrue(codeLines.contains { $0.contains("reportedHighRiskHotspotCount") },
                      "界面又回到榜上 filter 了")
        XCTAssertFalse(codeLines.contains { $0.contains("topComplexFunctions.filter") },
                       "第二处口径回来了：应该只有契约里那一个取法")
    }

    // MARK: - 真仓库上的**独立 recount**（两把尺子必须量到同一个数）

    /// 独立口径不抄实现：这里把判档规则按**字面常量**重写一遍
    /// （`复杂度 ≥ 21` 或 `长度 > 100 行` 至少算 high），
    /// 函数集合走 `ComplexityEngine.functions(in:)` 自己扫，
    /// 再和分析器落下来的那一格对账。两边任一改动口径都会当场对不上 ——
    /// 那正是"榜报不满"这种错最需要的第二把尺子。
    func testRealRepositoryTotalMatchesAnIndependentRecount() async throws {
        let scan = try await selfScan()
        let boardHigh = scan.code.topComplexFunctions
            .filter { $0.risk.rank >= RiskLevel.high.rank }.count
        guard let total = scan.code.highRiskHotspotCount else {
            return XCTFail("真总数没落盘 ⇒ 这一格又变回榜长了")
        }
        XCTAssertGreaterThanOrEqual(total, boardHigh,
                                    "全体高档数不可能小于榜内高档数：total=\(total) board=\(boardHigh)")

        let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
        let all = files.map { ComplexityEngine.functions(in: $0) }.flatMap { $0 }
        // 第一版这里我写成 `>= 16`，被真实值当场纠正：**16 是另一把尺子**
        // （`SelfScanHarness.complexFunctionBar`，那是"复杂度**上榜**参考线"），
        // 判 high 用的是 `highFunctionComplexity = 21`。两把尺子名字像、用途不同。
        XCTAssertEqual(ComplexityBarProbe.highRiskComplexity, FileSystemCodeAnalyzer.highFunctionComplexity,
                       "测试里硬编码的判档常量与实现分叉了（先改注释里的数字，再改这里）")
        XCTAssertEqual(ComplexityBarProbe.longFunctionBar, 100,
                       "长度升档线（> 100 行至少算 high）与实现分叉了")
        let independent = all.filter { $0.complexity >= ComplexityBarProbe.highRiskComplexity
            || $0.lineCount > ComplexityBarProbe.longFunctionBar }.count
        print("实读数：榜长 \(scan.code.topComplexFunctions.count) · 榜内高档 \(boardHigh) · "
              + "分析器全体高档 \(total) · 独立 recount \(independent)")
        XCTAssertEqual(total, independent,
                       "两把尺子对不上：分析器 \(total) vs 独立 recount \(independent) ⇒ 判档常量分叉了")
        XCTAssertGreaterThan(independent, 0, "独立口径数为 0 ⇒ 这条对账不作数")
    }

    // MARK: - 落盘兼容（旧报告没这两格）

    func testOldReportWithoutFieldStillDecodes() throws {
        var report = ProjectReport(project: MonitoredProject(name: "夹具", path: "/tmp/hr"))
        var metrics = CodeMetrics()
        metrics.topComplexFunctions = [hotspot(41, "old")]
        report.code = metrics
        let data = try JSONEncoder().encode(report)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var code = try XCTUnwrap(json["code"] as? [String: Any])
        code.removeValue(forKey: "highRiskHotspotCount")
        json["code"] = code
        let restored = try JSONDecoder().decode(ProjectReport.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.code?.highRiskHotspotCount)
        XCTAssertEqual(restored.code?.reportedHighRiskHotspotCount, 1, "缺格时仍能按榜内算，不许整份解码失败")
    }
}
