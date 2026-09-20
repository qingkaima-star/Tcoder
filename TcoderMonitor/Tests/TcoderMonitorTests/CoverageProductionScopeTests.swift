import XCTest
@testable import TcoderMonitor

/// OWNER: WS-V #37（覆盖率分母口径）。文件名不以 Code/Git/Dependency/Log/Health/Performance
/// 开头，不与 WS-A/B/C 的 glob 相撞；`CoverageAnalyzerTests.swift` 是总工的，不碰。
///
/// 要修的账：覆盖率的**计分分母**原先把项目自己的测试代码一起算了进去。
/// 测试代码几乎必然被自己的测试覆盖到，于是它是一份高分样本——2026-09-20 实测：
/// 全口径 27047/42137 = 64.19%，其中 `Tests/` 占分母 43.83%（自身 86.38%）、
/// `Sources/` 只有 11080/23651 = 46.85%。
/// 决定性证据：`ee8e7b9`→`1e6319d` 只往 `Tests/` 加了 140 行测试、生产码一行没改，
/// 生产码 46.84%→46.85% 几乎不动，全口径却 64.00%→64.19% **自己涨了**。
/// 这个数字直接进健康评分，所以「不改善生产码也能涨分」的增长项必须被切断。
///
/// 口径集中在 `CoverageScope.isProductionSource`，本文件按 #29 的路子做：
/// 口径**可见**（打印每条规则的命中数）、分母**有正向断言**、
/// 规则本身有**双向**元测试（该排除的排除了，不该误伤的一个不许误伤）。
final class CoverageProductionScopeTests: XCTestCase {

    /// 仓库根（与 `SelfScanDogfoodTests` 同一算法）：本文件 → Tests → TcoderMonitor → 工作树根。
    /// 只给「真实证据的健康分对照」那条用例用。
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    // MARK: - 夹具

    func metrics(fromLCov records: [String]) async throws -> CoverageMetrics {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-scope-\(UUID().uuidString)", isDirectory: true)
        let captured = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try records.joined(separator: "\n")
            .write(to: dir.appendingPathComponent("coverage/lcov.info"), atomically: true, encoding: .utf8)
        return try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
    }

    /// 一条 lcov 记录。`found`/`hit` 故意取整数便于手算。
    func record(_ source: String, found: Int, hit: Int) -> String {
        "TN:\nSF:\(source)\nFNF:0\nFNH:0\nBRF:0\nBRH:0\nLF:\(found)\nLH:\(hit)\nend_of_record"
    }

    // MARK: - 输入形状量测（决定一份 lcov 有没有「证明口径差」的能力）

    /// 一份报告能同时给出两个口径，不代表它能**演示**两个口径的差异：
    /// 很多项目只导 target 源码（仓库本地那份 `coverage/lcov.info` 就是这样，
    /// 全部 `SF:` 都在 `Sources/` 下），此时被排除分母是 0、两个口径数值完全相等。
    /// 拿这种输入去断言「两口径不等」会把实现没问题的一件事测成红，
    /// 别人照 README 跑一次取证看到 5 个失败，第一反应会是"#37 坏了"。
    /// 所以先量形状：**没有证明力就 skip，并把数字写进 skip 原因**，不许静默过关。
    struct CaliberEvidence {
        var input: String
        var productionPercent: Double
        var fullPercent: Double
        var productionDenominator: Int
        var fullDenominator: Int
        var excludedLines: Int

        /// true = 这份输入真含被排除的测试/派生记录，才配用来断言口径差。
        var canProveGap: Bool { excludedLines > 0 }

        var skipReason: String {
            "输入 `\(input)` 不含任何被排除的测试/派生记录（排除分母 0 行）："
            + "生产码 \(String(format: "%.2f", productionPercent))% = \(productionDenominator) 行，"
            + "全口径 \(String(format: "%.2f", fullPercent))% = \(fullDenominator) 行，"
            + "两个口径完全相等 ⇒ 这份 lcov 演示不了口径差。"
            + "换一份含 `Tests/`、`PackageTests` 或 `.build` 记录的真实报告再跑。"
        }
    }

    func evidence(from metrics: CoverageMetrics, input: String) throws -> CaliberEvidence {
        let report = try XCTUnwrap(metrics.reports.first, "lcov 没被解析出报告：\(input)")
        let production = try XCTUnwrap(metrics.overallLinePercent,
                                      "生产码口径为 nil，分母被清空了：\(input)")
        let full = try XCTUnwrap(metrics.allSourcesLinePercent, "全口径为 nil：\(input)")
        return CaliberEvidence(
            input: input,
            productionPercent: production,
            fullPercent: full,
            productionDenominator: report.linesTotal,
            fullDenominator: report.allLinesTotal ?? report.linesTotal,
            excludedLines: (report.allLinesTotal ?? report.linesTotal) - report.linesTotal)
    }

    /// 把一份 lcov 落到临时目录交给真分析器读，顺带打印用的是哪份输入。
    func metricsWritingLCov(_ text: String, labeled input: String) async throws -> CoverageMetrics {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tcoder-cov-self-\(UUID().uuidString)", isDirectory: true)
        let captured = dir
        addTeardownBlock { try? FileManager.default.removeItem(at: captured) }
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("coverage"), withIntermediateDirectories: true)
        try text.write(to: dir.appendingPathComponent("coverage/lcov.info"),
                       atomically: true, encoding: .utf8)
        print("【#37 输入】\(input)（\(text.split(separator: "\n").filter { $0.hasPrefix("SF:") }.count) 条 SF: 记录）")
        return try await CoverageAnalyzer().analyze(projectRoot: dir, options: .default)
    }

    // MARK: - 口径本身：双向元测试

    // MARK: - ① 加测试码不得改变生产码覆盖率

    // MARK: - ② 全是测试码时不得当成有数据

    // MARK: - ③ 评分跟着生产码走（阈值一个没改）

    // MARK: - ④ 风险档位跟着生产码走（阈值未动）

    // MARK: - ⑤ 没有文件粒度的格式不许假装区分过

    // MARK: - ⑥ 落盘兼容：新增字段一律 Optional

    // MARK: - ⑦ 分母守卫：扫描确实看到了测试码

    // MARK: - ⑧ 真产物取证：改前 / 改后的覆盖率与健康分

    // MARK: - ⑨ #39：证明力判据本身要在默认轮里被守住

}
