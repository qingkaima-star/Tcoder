import Foundation

/// 工程健康评分落盘字段。**新增字段一律带默认值且为 Optional**，
/// 否则旧报告 JSON 整份解码失败（本仓踩过：非 Optional 字段让老数据全部读不出来）。
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

    /// 「工程质量（代码口径）」。**nil = 本次没有任何代码维度参与计分**，
    /// 此时界面上不许出现一个 0 分冒充"代码很差"。
    var codeScope: HealthSubScore? = nil

    var grade: HealthGrade { HealthGrade(score: overall) }
    var trendDelta: Int? {
        guard let previous = previousOverall else { return nil }
        return overall - previous
    }

    static let empty = HealthScore()
}

/// 同一批分量、换一组成员、按同一套权重重新归一化得到的副读数。
///
/// 为什么要有它：`overall` 里「提交活跃度」与「协作分布」两项量的是 **Git 历史的既成事实**
/// （仓库历史不足 7 天时活跃度被 `GitCadenceEvidence.shortHistoryScoreCeiling` 封顶 60；
/// 单一署名身份占 93% 时协作分布只剩 6 分）。这两项改代码改不动，却占 21% 权重，
/// 于是"代码好坏"与"仓库多人多老"混在一个数里，用户无法判断该修什么。
/// 这里把只属于代码的那几维单独出一个数，**成员名单与排除原因必须跟着落盘**，
/// 免得第二个数变成"挑对自己有利的口径"。
struct HealthSubScore: Codable, Equatable, Sendable {
    var label: String
    var overall: Int
    var includedDimensions: [String]
    var excludedDimensions: [String]
    var note: String

    var grade: HealthGrade { HealthGrade(score: overall) }
}

struct ScoreComponent: Codable, Equatable, Identifiable, Sendable {
    var name: String
    /// 0...100 before weighting.
    var score: Int
    /// Relative weight, normalized by `WeightedHealthScorer` against the sum of the
    /// weights actually present. After scoring, the emitted components' weights sum to
    /// 1.0 even though `HealthDimension.defaultWeight` totals 1.10.
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
        // These are *relative* weights expressed as parts of 110, not percentages:
        // the nine values below sum to 1.10 by construction. `WeightedHealthScorer`
        // divides by the sum of the weights actually present, so `overall` is
        // unaffected by the 1.10 total and only the ratios carry meaning.
        //
        // Do not "fix" the total to 1.0 by rounding individual values — that would
        // silently change the calibration the user set. Rescaling proportionally is
        // safe but pointless given the normalization above.
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

    /// 是否属于「工程质量（代码口径）」的成员。
    ///
    /// 判据只有一条：**这项分数能不能靠改本仓库的代码/测试抬起来。**
    /// - 排除 `activity`：量的是提交历史的时间跨度与节奏，新仓库不足 7 天时按封顶计；
    /// - 排除 `busFactor`：量的是署名分布，历史里谁写的不改代码能变；
    /// - 排除 `dependencies`：量的是第三方清单的漏洞与版本，不是这份代码写得好不好；
    /// - 保留 `testing`：覆盖率由本仓库测试自己决定。
    var belongsToCodeScope: Bool {
        switch self {
        case .codeQuality, .complexity, .duplication, .documentation, .testing: return true
        case .activity, .busFactor, .stability, .dependencies: return false
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
