import XCTest
@testable import TcoderMonitor

/// Chief-engineer baseline test: the contract types must stay Codable round-trippable,
/// because every workstream persists them through ProjectStore.
final class ContractRoundTripTests: XCTestCase {
    func testProjectReportRoundTrip() throws {
        var report = ProjectReport(project: MonitoredProject(name: "T", path: "/tmp/t"))
        report.code = CodeMetrics(totalFiles: 3, codeLines: 10)
        report.git = GitInsights(totalCommits: 2)
        report.logs = LogSummary(errorCount: 1)
        report.dependencies = DependencyReport()
        report.health = HealthScore(overall: 87)

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(ProjectReport.self, from: data)
        XCTAssertEqual(decoded.code?.totalFiles, 3)
        XCTAssertEqual(decoded.git?.totalCommits, 2)
        XCTAssertEqual(decoded.health?.overall, 87)
    }

    func testVersionComparison() {
        XCTAssertTrue(DependencyVersion.isOlder(current: "4.17.15", than: "4.17.21"))
        XCTAssertFalse(DependencyVersion.isOlder(current: "18.3.1", than: "18.3.1"))
        XCTAssertTrue(DependencyVersion.isOlder(current: "1.2.68", than: "2.0.52"))
        XCTAssertFalse(DependencyVersion.isOlder(current: "3.3.4", than: "3.3.1"))
        XCTAssertTrue(DependencyVersion.isOlder(current: "0.9.1", than: "0.12.6"))
    }

    func testByteFormatting() {
        XCTAssertEqual(ByteFormat.string(1_204 * 1024 * 1024, precision: 1), "1.2 GB")
        XCTAssertEqual(ByteFormat.rate(120 * 1024 * 1024), "120 MB/s")
    }
}
