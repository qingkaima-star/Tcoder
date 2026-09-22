import XCTest
@testable import TcoderMonitor

/// R10 第 0 条：`doctor` 必须报出"我在用哪一版判据"。
///
/// 为什么单独立一条：`doctor` 这个子命令的存在理由就是
/// "AI 在相信任何读数之前，先知道自己用的是哪个二进制"（`CLIOutput.swift` 文件头那句话）。
/// 而这一轮把规则戳落进报告与 `score` 之后，**唯独 `doctor` 还停在"构建口径 + bundle"**——
/// 最该出声的那一格缺席。本文件把它钉住。
final class CLIDoctorProvenanceTests: XCTestCase {

    private var joined: String { CLIRouter.doctorIdentityLines().joined(separator: "\n") }

    func testDoctorAnnouncesRulesStampAndSchemaVersion() {
        let text = joined
        XCTAssertTrue(text.contains("检测规则戳 = \(ScanProvenance.rulesVersionStamp)"),
                      "doctor 没打规则戳：\n\(text)")
        XCTAssertTrue(text.contains("报告结构版本 = v\(ScanProvenance.currentSchemaVersion)"),
                      "doctor 没打报告结构版本：\n\(text)")
    }

    /// 反例方向：只打 bundle 版本号**不够**——bundle 版本不随判据变化，
    /// 换一版阈值/正则它仍是同一个串。所以规则戳必须是独立的一行，不能由 bundle 顶替。
    func testRulesStampIsItsOwnLineNotPartOfBundleIdentity() {
        let lines = CLIRouter.doctorIdentityLines()
        let bundleLine = try? XCTUnwrap(lines.first { $0.hasPrefix("  bundle = ") })
        XCTAssertNotNil(bundleLine)
        XCTAssertFalse(bundleLine?.contains(ScanProvenance.rulesVersionStamp) == true,
                       "规则戳混进 bundle 那行就没法单独比对，必须自己一行")
        XCTAssertTrue(lines.contains { $0.hasPrefix("  检测规则戳 = ") })
    }

    /// 一把尺子：`doctor` 与 `--version`、与报告里的 `toolVersion` 必须同源。
    func testDoctorSharesTheSameRulerAsVersionAndReport() {
        XCTAssertTrue(CLIConfig.versionLine.contains(CLIConfig.buildConfiguration))
        XCTAssertTrue(joined.contains(CLIConfig.buildConfiguration))
        XCTAssertTrue(joined.contains(CLIConfig.bundleIdentity))
        // 报告里那一格与 doctor 用的是同一个串（不是各拼一遍）
        let reportSide = ScanProvenance(report: ProjectReport(
            project: MonitoredProject(name: "夹具", path: "/tmp/doctor-prov")),
            scannedRoot: "/tmp/doctor-prov", producedBy: "cli")
        XCTAssertEqual(reportSide.rulesVersion, ScanProvenance.rulesVersionStamp)
        XCTAssertTrue(reportSide.toolVersion?.contains(CLIConfig.bundleIdentity) == true)
    }

    /// 分母自证：这一段不许哪天被删空还全绿。
    func testIdentityBlockIsNotEmpty() {
        XCTAssertGreaterThanOrEqual(CLIRouter.doctorIdentityLines().count, 5,
                                    "doctor 的自我口径少于 5 行 ⇒ 有格子被删了")
    }
}
