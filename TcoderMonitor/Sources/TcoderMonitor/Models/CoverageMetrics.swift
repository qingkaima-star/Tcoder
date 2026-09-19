import Foundation

// MARK: - 覆盖率口径（#37）

/// 「覆盖率分母里算不算项目自己的测试代码」这件事的**唯一**判定处。
///
/// 为什么要单独拎出来：测试代码几乎必然被自己的测试覆盖到（本机实测 86.38%），
/// 把它算进分母会让总分母里约 44% 是高分样本，于是**一行生产码都不改善、
/// 只往 `Tests/` 加测试，全口径覆盖率也会自己涨**（`ee8e7b9`→`1e6319d` 实测
/// 生产码 46.84%→46.85% 几乎没动，全口径 64.00%→64.19%）。
/// 这个数字直接进健康评分，所以它必须是「生产码被覆盖多少」，不是「代码里有多少被跑过」。
///
/// 全量口径并没有丢：它作为次要字段仍然存在
/// （`CoverageReport.allLinesCovered` / `CoverageMetrics.allSourcesLinePercent`），
/// 界面与取证都能读到，只是不再参与评分。
enum CoverageScope {
    /// SwiftPM 的测试目录段。真实 lcov 给的是绝对路径，所以带斜杠匹配。
    static let testDirectoryMarker = "/Tests/"
    /// SwiftPM 测试产物里那条 `TcoderMonitorPackageTests.xctest/…` 路径。
    static let packageTestsMarker = "PackageTests"
    /// 构建中间产物里的副本，不是源码。
    static let buildDirectoryMarker = "/.build/"
    /// 约定俗成的测试文件名后缀。
    static let swiftTestFileSuffix = "Tests.swift"

    /// true = 计入评分分母。四条排除条件任一命中即算测试/派生产物。
    /// 空路径按「不确定的不算进生产码」处理：宁可少给分，也不把未知来源当生产码。
    static func isProductionSource(path: String) -> Bool {
        guard !path.isEmpty else { return false }
        if path.contains(testDirectoryMarker) { return false }
        if path.contains(packageTestsMarker) { return false }
        if path.contains(buildDirectoryMarker) { return false }
        if (path as NSString).lastPathComponent.hasSuffix(swiftTestFileSuffix) { return false }
        return true
    }
}

// MARK: - Test coverage

/// Parsed from coverage reports the repository already produces
/// (lcov, istanbul summary, JaCoCo, clover/pytest). Absence is reported as
/// `hasData == false` rather than 0%, so the UI never shows a fake score.
struct CoverageMetrics: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var reports: [CoverageReport] = []
    var scannedFileCount: Int = 0

    /// 「有可用于评分的覆盖率数据」。
    /// 一份只统计到测试代码的报告**不算有数据**——否则全测试码的报告会以
    /// 一个没有生产码含义的百分比混进评分。
    var hasData: Bool { reports.contains { $0.linesTotal > 0 } }

    var unit: CoverageReport? { reports.first { $0.kind == .unit } }
    var integration: CoverageReport? { reports.first { $0.kind == .integration } }

    /// **计分口径**：跨报告加权的生产码行覆盖率（`linesTotal == 0` 的报告不进分母）。
    /// 名字保留 `overall` 是为了不牵动 WS-C 名下的 `WeightedHealthScorer`——
    /// 它读的就是这个属性，于是评分自动跟着口径走，而不需要那边配合改代码。
    /// 全口径请看 `allSourcesLinePercent`。
    var overallLinePercent: Double? {
        let scored = reports.filter { $0.linesTotal > 0 }
        guard !scored.isEmpty else { return nil }
        let total = scored.reduce(0) { $0 + $1.linesTotal }
        guard total > 0 else { return nil }
        let covered = scored.reduce(0) { $0 + $1.linesCovered }
        return Double(covered) / Double(total) * 100
    }

    /// **全口径**（含测试代码等一切被统计到的文件），只作次要读数与取证，不参与评分。
    /// 报告没有文件粒度时它等于 `overallLinePercent`。
    var allSourcesLinePercent: Double? {
        let withAll = reports.filter { ($0.allLinesTotal ?? 0) > 0 }
        guard !withAll.isEmpty else { return overallLinePercent }
        let total = withAll.reduce(0) { $0 + ($1.allLinesTotal ?? 0) }
        let covered = withAll.reduce(0) { $0 + ($1.allLinesCovered ?? 0) }
        guard total > 0 else { return nil }
        return Double(covered) / Double(total) * 100
    }

    /// 至少有一份报告能按源文件区分口径。假 = 生产码数字其实等同全量，界面必须说明。
    var scopeIsSeparated: Bool { reports.contains { $0.isScopeSeparated } }

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

    /// 这份报告能不能按源文件区分口径。
    enum ScopeGranularity: String, Codable, Sendable {
        case perSourceFile = "按源文件区分"
        case aggregateOnly = "只有汇总粒度"
    }

    var path: String
    var kind: Kind
    var toolName: String
    /// **计分口径**：生产码。`scopeGranularity == .aggregateOnly` 时它等同全量。
    var linesCovered: Int
    var linesTotal: Int
    var branchesCovered: Int
    var branchesTotal: Int?
    var methodsCovered: Int
    var methodsTotal: Int

    /// 次要字段：全口径（含测试代码）。
    /// **一律 Optional**——`ProjectReport` 会经 `ProjectStore` 落盘，
    /// 给旧 JSON 加非 Optional 键会让整份报告解码失败（`ProjectStoreRoundTripTests` 钉着这条）。
    var allLinesCovered: Int?
    var allLinesTotal: Int?
    var allBranchesCovered: Int?
    var allBranchesTotal: Int?
    var scopeGranularity: ScopeGranularity?

    var id: String { path }

    var isScopeSeparated: Bool { scopeGranularity == .perSourceFile }

    var linePercent: Double {
        linesTotal == 0 ? 0 : Double(linesCovered) / Double(linesTotal) * 100
    }
    var branchPercent: Double? {
        guard let total = branchesTotal, total > 0 else { return nil }
        return Double(branchesCovered) / Double(total) * 100
    }
    /// 全口径行覆盖率，仅用于展示与取证。分母为 0 时返回 nil 而不是 0%。
    var allLinePercent: Double? {
        guard let total = allLinesTotal, total > 0 else { return nil }
        return Double(allLinesCovered ?? 0) / Double(total) * 100
    }
}
