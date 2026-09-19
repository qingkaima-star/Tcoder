import Foundation

// MARK: - Test coverage

/// Parsed from coverage reports the repository already produces
/// (lcov, istanbul summary, JaCoCo, clover/pytest). Absence is reported as
/// `hasData == false` rather than 0%, so the UI never shows a fake score.
struct CoverageMetrics: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var reports: [CoverageReport] = []
    var scannedFileCount: Int = 0

    var hasData: Bool { !reports.isEmpty }

    var unit: CoverageReport? { reports.first { $0.kind == .unit } }
    var integration: CoverageReport? { reports.first { $0.kind == .integration } }

    /// Line coverage aggregated across every discovered report.
    var overallLinePercent: Double? {
        let total = reports.reduce(0) { $0 + $1.linesTotal }
        guard total > 0 else { return nil }
        let covered = reports.reduce(0) { $0 + $1.linesCovered }
        return Double(covered) / Double(total) * 100
    }

    var overallBranchPercent: Double? {
        let scored = reports.filter { $0.branchesTotal != nil && ($0.branchesTotal ?? 0) > 0 }
        guard !scored.isEmpty else { return nil }
        let total = scored.reduce(0) { $0 + ($1.branchesTotal ?? 0) }
        let covered = scored.reduce(0) { $0 + $1.branchesCovered }
        guard total > 0 else { return nil }
        return Double(covered) / Double(total) * 100
    }

    var riskLevel: RiskLevel {
        guard let line = overallLinePercent else { return .none }
        switch line {
        case 80...: return .none
        case 60..<80: return .low
        case 40..<60: return .medium
        default: return .high
        }
    }
}

struct CoverageReport: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case unit = "单元测试"
        case integration = "集成测试"
        case combined = "整体"
        case unknown = "未区分"
    }

    var path: String
    var kind: Kind
    var toolName: String
    var linesCovered: Int
    var linesTotal: Int
    var branchesCovered: Int
    var branchesTotal: Int?
    var methodsCovered: Int
    var methodsTotal: Int

    var id: String { path }

    var linePercent: Double {
        linesTotal == 0 ? 0 : Double(linesCovered) / Double(linesTotal) * 100
    }
    var branchPercent: Double? {
        guard let total = branchesTotal, total > 0 else { return nil }
        return Double(branchesCovered) / Double(total) * 100
    }
}
