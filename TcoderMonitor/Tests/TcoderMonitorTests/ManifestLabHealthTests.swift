import Foundation
import XCTest
@testable import TcoderMonitor

/// WS-F 夹具实验室 · 健康评分与持久夹具：六类输入全部到位时的评分契约，
/// 以及把夹具留在固定路径供 App 现场取证的开关。
/// 拆自 ManifestLabFixtureTests.swift，断言与用例一字未改（WS-V）。
final class ManifestLabHealthTests: ManifestLabTestCase {
    // MARK: - 6. 健康评分：六类输入全部到位

    func testHealthScoreConsumesEveryLabDimension() async throws {
        let code = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
        let git = try await ShellGitAnalyzer().analyze(repositoryURL: root)
        let logs = try await FileLogAnalyzer().analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
        let deps = try await ManifestDependencyAnalyzer().analyze(projectRoot: root, allowNetwork: false)
        let coverage = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
        let inputs = HealthInputs(code: code, git: git, logs: logs,
                                  dependencies: deps, coverage: coverage, previousScore: 80)

        let score = WeightedHealthScorer().score(inputs)
        print("=== WS-F 夹具 · 健康评分实测 ===")
        print("总分 \(score.overall) 等级 \(score.grade.rawValue) 趋势 \(score.trendDelta.map(String.init) ?? "无")")
        for component in score.components {
            print("  \(component.name) \(component.score) ×\(String(format: "%.3f", component.weight))"
                + " = \(String(format: "%.1f", component.weightedContribution)) [\(component.risk.rawValue)] \(component.detail)")
        }
        print("优点 \(score.strengths)")
        print("问题 \(score.issues)")
        print("建议 \(score.recommendations)")
        print("总评 \(score.narrative)")

        // R5b 更正一处**把旧行为当契约**的期望（不是放宽判据，理由逐条写在下面）：
        // 这棵 WS-F 夹具的 5 份报告跨格式、跨模块、彼此无法核对重叠，而唯一带文件粒度的那份
        // lcov 又与自己正文对不上账（`DA:` 只列 2 行却报 `LF:100`）⇒ 按 RD-25 的判据
        // **不给伪精确总数**（修前那句 840/1070 = 78.5% 正是本轮要消灭的形状；
        // `ManifestLabCoverageTests` 在 `b7ff42d` 已按新判据更新，本文件当时漏改，红在整套跑里）。
        // 后果：覆盖率这一维**按缺证据缺席**（不是按 0 分计分）⇒ 可评维度从 9 变 8。
        XCTAssertFalse(coverage.hasData, "互相核对不上的五份报告不许合成一个总数")
        XCTAssertNil(coverage.overallLinePercent, "拿不出可信总数时不许留一个百分比")
        XCTAssertEqual(inputs.availableDimensions.count, 8, "覆盖率缺席 ⇒ 8 个维度（修前 9）")
        XCTAssertEqual(score.components.count, 8, "实得 \(score.components.map(\.name))")
        XCTAssertEqual(score.components.reduce(0.0) { $0 + $1.weight }, 1.0, accuracy: 1e-9,
                       "对外权重必须归一到 1.0")
        let recomputed = score.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(score.overall), recomputed, accuracy: 1.0, "总分 = Σ(分量 × 权重)")
        XCTAssertTrue((0...100).contains(score.overall))
        XCTAssertEqual(score.trendDelta, score.overall - 80)
        XCTAssertFalse(score.narrative.isEmpty)
        XCTAssertFalse(score.components.contains { $0.name == "测试覆盖" },
                       "拿不出可信总数 ⇒ 这一维必须缺席，不许拿 78.5% 那种双计出来的数进分")
        // 缺席必须可解释（RD-34 钉的是"有写无读"，这里钉的是"少了维度却不说为什么"）。
        let absence = MissingDimensionReason.testingAbsence(coverage: coverage)
        XCTAssertNotNil(absence, "覆盖率缺席时必须给出一句原因，不许静默少一维")
        XCTAssertTrue(absence?.contains("覆盖率报告") == true || absence?.contains("行覆盖") == true,
                      "原因要说清是哪一路：\(absence ?? "nil")")
        XCTAssertTrue(score.components.contains { $0.name == "依赖健康" })
        XCTAssertTrue(score.components.contains { $0.name == "运行稳定性" })
        XCTAssertFalse(score.components.contains { $0.score == 0 && $0.name == "测试覆盖" },
                       "缺证据不许被打成 0 分（修前那句说的是 78.5% 不该变 0 分，判据不变）")
        // 排序契约：升序
        XCTAssertEqual(score.components.map(\.score), score.components.map(\.score).sorted())
    }

    // MARK: - 7. 把夹具落到固定路径，供 App 现场取证

    /// `TCODER_F_PERSIST_FIXTURE=1` 时把同一棵夹具（含 git 历史）写到
    /// `/tmp/tcoder-fixtures/acme-orders-lab`，总工可以直接把它加进 App 看九页渲染。
    func testPersistFixtureForAppInspection() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TCODER_F_PERSIST_FIXTURE"] == "1",
                          "默认跳过；TCODER_F_PERSIST_FIXTURE=1 才留下持久夹具")
        let destination = URL(fileURLWithPath: "/tmp/tcoder-fixtures/acme-orders-lab", isDirectory: true)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        let built = try LabTree.build(at: destination)
        try LabTree.makeGitRepository(at: destination, files: built.files)
        print("持久夹具 = \(destination.path)（\(built.files.count) 个文件）")
    }

}
