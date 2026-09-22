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
        // 没有结论就没有趋势：`overall` 是占位 0 时，`0 - 上次分` 会画出一个
        // 看起来很确定的"暴跌"箭头。它与 `verdict` 必须同进同退。
        guard !components.isEmpty, let previous = previousOverall else { return nil }
        return overall - previous
    }

    /// 综合分的**唯一合法读口**。`nil` = 本次没有任何维度拿到可计分的证据。
    ///
    /// 为什么要有它：`WeightedHealthScorer.noEvidenceScore` 在全部维度缺席时仍然要返回
    /// 一份 `HealthScore`（缺证据的原因必须写在 `narrative` 里交给用户看），
    /// 而它的 `overall` 只能是 `0` —— 那个 0 是**占位**，不是测量结果。
    /// 直接读 `overall` 的消费端会把"没测到"渲染成"0 分 E 级"：
    /// 实拍口径下这两句是完全相反的结论。批次 P7-B 起，视图与落盘只许走 `verdict`，
    /// `HealthScoreVerdictGuardTests` 机器守住这条。
    ///
    /// 与 `codeScope` 同源：那个字段的注释早就写明"nil = 没有代码维度参与计分，
    /// 界面上不许出现一个 0 分冒充代码很差"。这一版把同一条规矩还给综合分。
    var verdict: Int? { components.isEmpty ? nil : overall }
    /// 与 `verdict` 同进同退的等级。分开两个口子是为了让"0 分 + E 级"这对照没法各走各的。
    var verdictGrade: HealthGrade? { components.isEmpty ? nil : grade }

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

    /// **输入按"仓库归属"定位**的维度：这一维读的不是"所选目录里有什么"，
    /// 而是"这个目录属于哪个仓库、那个仓库叫什么"。
    ///
    /// 两条生产者各自都会向上找 `.git`：
    /// - `activity` / `busFactor`：`ShellGitAnalyzer` 的仓库定位（结果记在
    ///   `ScanProvenance.resolvedGitRoot`，与所选目录不同时**必须上屏**）；
    /// - `stability`：`LogProjectIdentity.resolve(scanRoot:)` 先取"最近的带 `.git` 祖先"
    ///   当锚点，再按锚点名与清单里的产品名去 `~/Library/Logs` 认领崩溃报告。
    ///
    /// 刻意**不含 `dependencies`**：`ManifestDependencyAnalyzer` 只吃 `projectRoot` 下面
    /// 真实存在的清单，跟着所选目录走。
    /// 也刻意**不是 `belongsToCodeScope` 的补集**——那个判据问的是"改代码能不能把它抬起来"，
    /// 它把 `dependencies` 踢出、把 `testing` 留在内，两份名单只是长得像。
    static let repositoryScoped: [HealthDimension] = [.activity, .busFactor, .stability]
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
