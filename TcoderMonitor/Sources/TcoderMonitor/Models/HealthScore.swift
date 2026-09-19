import Foundation

// MARK: - Engineering health score

struct HealthScore: Codable, Equatable, Sendable {
    var computedAt: Date = Date()
    var overall: Int = 0
    var previousOverall: Int?
    var components: [ScoreComponent] = []
    var strengths: [String] = []
    var issues: [String] = []
    var recommendations: [String] = []
    var narrative: String = ""
    var generatedByAI: Bool = false

    var grade: HealthGrade { HealthGrade(score: overall) }
    var trendDelta: Int? {
        guard let previous = previousOverall else { return nil }
        return overall - previous
    }

    static let empty = HealthScore()
}

struct ScoreComponent: Codable, Equatable, Identifiable, Sendable {
    var name: String
    /// 0...100 before weighting.
    var score: Int
    /// Relative weight; the set should sum to ~1.0.
    var weight: Double
    var detail: String
    var risk: RiskLevel

    var id: String { name }
    var weightedContribution: Double { Double(score) * weight }
}

enum HealthDimension: String, CaseIterable, Sendable {
    case codeQuality = "代码质量"
    case complexity = "复杂度"
    case duplication = "重复度"
    case documentation = "注释与可维护性"
    case activity = "提交活跃度"
    case busFactor = "协作分布"
    case stability = "运行稳定性"
    case dependencies = "依赖健康"
    case testing = "测试覆盖"

    var defaultWeight: Double {
        switch self {
        case .codeQuality: return 0.14
        case .complexity: return 0.18
        case .duplication: return 0.13
        case .documentation: return 0.08
        case .activity: return 0.12
        case .busFactor: return 0.09
        case .stability: return 0.16
        case .dependencies: return 0.10
        case .testing: return 0.10
        }
    }
}

/// Everything the scorer may look at — passed by value so scorers stay pure.
struct HealthInputs: Sendable {
    var code: CodeMetrics?
    var git: GitInsights?
    var logs: LogSummary?
    var dependencies: DependencyReport?
    var coverage: CoverageMetrics?
    var previousScore: Int?

    init(
        code: CodeMetrics? = nil,
        git: GitInsights? = nil,
        logs: LogSummary? = nil,
        dependencies: DependencyReport? = nil,
        coverage: CoverageMetrics? = nil,
        previousScore: Int? = nil
    ) {
        self.code = code
        self.git = git
        self.logs = logs
        self.dependencies = dependencies
        self.coverage = coverage
        self.previousScore = previousScore
    }

    var availableDimensions: [HealthDimension] {
        var dims: [HealthDimension] = []
        if code != nil { dims += [.codeQuality, .complexity, .duplication, .documentation] }
        if git != nil { dims += [.activity, .busFactor] }
        if logs != nil { dims.append(.stability) }
        if dependencies != nil { dims.append(.dependencies) }
        if coverage?.hasData == true { dims.append(.testing) }
        return dims
    }
}
