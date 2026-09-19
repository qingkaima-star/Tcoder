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

        XCTAssertEqual(inputs.availableDimensions.count, 9, "五类输入齐备时应覆盖 9 个维度")
        XCTAssertEqual(score.components.count, 9, "实得 \(score.components.map(\.name))")
        XCTAssertEqual(score.components.reduce(0.0) { $0 + $1.weight }, 1.0, accuracy: 1e-9,
                       "对外权重必须归一到 1.0")
        let recomputed = score.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(score.overall), recomputed, accuracy: 1.0, "总分 = Σ(分量 × 权重)")
        XCTAssertTrue((0...100).contains(score.overall))
        XCTAssertEqual(score.trendDelta, score.overall - 80)
        XCTAssertFalse(score.narrative.isEmpty)
        XCTAssertTrue(score.components.contains { $0.name == "测试覆盖" },
                      "coverage.hasData 为真时测试覆盖维度必须进入评分")
        XCTAssertTrue(score.components.contains { $0.name == "依赖健康" })
        XCTAssertTrue(score.components.contains { $0.name == "运行稳定性" })
        XCTAssertFalse(score.components.contains { $0.score == 0 && $0.name == "测试覆盖" },
                       "覆盖率 78.5% 不该被打成 0 分")
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
