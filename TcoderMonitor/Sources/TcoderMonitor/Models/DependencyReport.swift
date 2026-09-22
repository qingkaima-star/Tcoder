import Foundation

// MARK: - Dependency & vulnerability analysis

struct DependencyReport: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var ecosystems: [EcosystemReport] = []
    var advisories: [SecurityAdvisory] = []
    var offlineVulnerabilities: [DependencyVulnerability] = []
    var networkLookupPerformed: Bool = false
    var networkLookupNote: String = ""

    /// **版本核对**这一路的账本（内置快照 + 在线 registry）。nil = 这一路没记过账
    /// （旧报告 / 别的调用方产出的报告），此时消费端一律按"没核对"处理，不做文案猜测。
    var versionLookup: DependencyLookupEvidence?
    /// **漏洞核对**这一路的账本（内置规则 + OSV）。与上面那格分开存，
    /// 因为"版本查成功"与"漏洞查成功"是两件事 —— 合成一格就会重演 RD-11 的冒充。
    var vulnerabilityLookup: DependencyLookupEvidence?
    /// 分 scope 的依赖统计（runtime / dev / test / build / platform / 未标注）。
    /// nil = 没统计过；存在则各桶相加 == `totalDependencies`（守卫用例钉住）。
    var scopeBreakdown: [DependencyScopeCount]?

    var totalDependencies: Int { ecosystems.reduce(0) { $0 + $1.dependencies.count } }
    var productionCount: Int {
        ecosystems.reduce(0) { $0 + $1.dependencies.filter { !$0.isDevDependency }.count }
    }
    var devCount: Int { ecosystems.reduce(0) { $0 + $1.dependencies.filter { $0.isDevDependency }.count } }
    var outdatedCount: Int {
        ecosystems.reduce(0) { total, eco in
            total + eco.dependencies.filter { $0.isProbablyOutdated }.count
        }
    }
    var vulnerableCount: Int {
        let offline = offlineVulnerabilities.reduce(0) { $0 + $1.affectedDependencies.count }
        return offline + advisories.reduce(0) { $0 + $1.affectedPackages.count }
    }
    var riskLevel: RiskLevel {
        let vulns = vulnerableCount
        switch vulns {
        case 0: return outdatedCount > totalDependencies / 3 ? .low : .none
        case 1...2: return .medium
        case 3...9: return .high
        default: return .critical
        }
    }
    var distinctEcosystemNames: [String] { ecosystems.map { $0.ecosystem.displayName } }

    /// Whether "zero vulnerabilities" is an actual finding rather than an absence of checking.
    ///
    /// `riskLevel` reads only `vulnerableCount`, so in the default offline state every project
    /// would otherwise earn a green "无风险" badge, a per-row "正常" marker, and a
    /// "未发现已知漏洞依赖" line in the paid health score's strengths. Those all assert
    /// safety on evidence we never gathered.
    ///
    /// Consumers that would render an all-clear must branch on this and downgrade to a
    /// neutral "未核对" state when it is `false`.
    var hasVulnerabilityCoverage: Bool {
        networkLookupPerformed || !advisories.isEmpty
    }

    /// Offline built-in rules only cover npm / Maven / Python, so an unchecking run on any
    /// other ecosystem is not a clean bill of health — say which ones went unexamined.
    var uncoveredEcosystemNames: [String] {
        guard !networkLookupPerformed else { return [] }
        let covered: Set<String> = ["npm", "maven", "python"]
        return ecosystems.map { $0.ecosystem.displayName }
            .filter { !covered.contains($0.lowercased()) }
    }

}

struct EcosystemReport: Codable, Equatable, Identifiable, Sendable {
    var ecosystem: DependencyEcosystem
    var manifestPath: String
    var lockfileName: String?
    var dependencies: [DependencyRecord]
    var frameworkMarkers: [String]

    var id: String { "\(ecosystem.rawValue):\(manifestPath)" }
    var riskLevel: RiskLevel {
        if dependencies.contains(where: { !$0.knownVulnerabilities.isEmpty }) { return .high }
        let outdatedRatio = dependencies.isEmpty ? 0
            : Double(dependencies.filter(\.isProbablyOutdated).count) / Double(dependencies.count)
        if outdatedRatio > 0.4 { return .medium }
        if outdatedRatio > 0.15 { return .low }
        return .none
    }
}

enum DependencyEcosystem: String, Codable, CaseIterable, Sendable {
    case npm
    case maven
    case gradle
    case swiftPM
    case python
    case go
    case cargo
    case cocoapods
    case ruby
    case nuget
    case unknown

    var displayName: String {
        switch self {
        case .npm: return "npm / Node.js"
        case .maven: return "Maven"
        case .gradle: return "Gradle"
        case .swiftPM: return "Swift Package"
        case .python: return "Python"
        case .go: return "Go"
        case .cargo: return "Cargo"
        case .cocoapods: return "CocoaPods"
        case .ruby: return "RubyGems"
        case .nuget: return ".NET"
        case .unknown: return "其他"
        }
    }

    var manifestNames: [String] {
        switch self {
        case .npm: return ["package.json"]
        case .maven: return ["pom.xml"]
        case .gradle: return ["build.gradle", "build.gradle.kts", "settings.gradle", "settings.gradle.kts"]
        case .swiftPM: return ["Package.swift"]
        case .python: return ["requirements.txt", "pyproject.toml", "setup.py", "Pipfile"]
        case .go: return ["go.mod"]
        case .cargo: return ["Cargo.toml"]
        case .cocoapods: return ["Podfile"]
        case .ruby: return ["Gemfile"]
        case .nuget: return ["packages.config"]
        case .unknown: return []
        }
    }
}

struct DependencyRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var version: String
    var ecosystem: DependencyEcosystem
    var scope: DependencyScope
    var manifestPath: String
    /// Highest version this package is known to have, from the bundled snapshot.
    var latestKnownVersion: String?
    var versionCheckSource: VersionCheckSource
    var knownVulnerabilities: [String]

    /// 锁文件 / 依赖树 / SBOM 里解析出的**实际**版本（`18.2.0`），与 `version`（清单原文 `^18.2.0`）
    /// 是两件事，必须分开存 —— RD-10 的根因就是把声明范围当安装版本。
    ///
    /// 谁写：`DependencyLockResolution`（package-lock.json / yarn.lock / Cargo.lock /
    /// Maven effective-POM 与依赖树 / CycloneDX·SPDX SBOM）。
    /// 谁读：`DependencyVersionIdentity`（比较与查询身份）、依赖行状态、漏洞核对回执。
    /// 为什么必须 Optional：`encodeIfPresent` 语义下"没有锁文件解析值"与"解析出 0.0.0"
    ///   是两种状态，非 Optional 会让旧报告整份解码失败（AGENTS §5.9 第 2 条）。
    /// 为什么不能放别处：它参与 `isProbablyOutdated` 这个契约派生态，而派生态只能长在契约上。
    var resolvedVersion: String?

    /// 上面那个解析值是**从哪份文件**读到的（相对项目根的锁文件 / 依赖树 / SBOM 路径）。
    /// 为什么不能省：台账 §4 第 1 条要求"每条重要结论都能追溯"——"这条依赖装的是 1.2.3"
    /// 这句话的证据就是那个文件，没有它用户无法复核，也无法判断锁是不是过期。
    /// 与 `resolvedVersion` 同生同灭：只有真读出解析值时才写，否则两个都是 nil。
    var resolvedVersionSource: String?

    /// 逐条依赖的**版本核对**状态（有没有拿到可用的"最新已知版本"）。
    /// 谁写：`ManifestDependencyAnalyzer`（内置快照 + registry 两条路各记一次结局）。
    /// 谁读：依赖行、总览、健康评分、无头出口 —— 四方同一份，禁止各自再推一遍。
    var versionCheckState: DependencyCheckState?
    /// 逐条依赖的**漏洞核对**状态。与上面那格**必须分开**：
    /// "npm 版本查成功"不等于"OSV 查过这条"（RD-11 点名的冒充关系）。
    var vulnerabilityCheckState: DependencyCheckState?

    /// 这一栏**为什么没有确切版本**（RD-13b 三态：未显式声明 / 由父级管理但未解析 / 确实无法确定）。
    /// 谁写：Maven 与 Gradle 解析器（只有它们看得见 `<parent>`、`<scope>import</scope>`、
    /// `platform(...)` 与代不出来的 `${...}` 占位）。
    /// 谁读：依赖行的 tooltip、离线说明里"版本没读出来"那一段、无头出口。
    /// 为什么不能放别处：这是**读清单那一刻**的事实，放不进视图派生类型（视图只拿到字符串），
    /// 而"由父级管理"与"没写"在界面上必须是一句话之差而不是同一句话。
    /// 为什么 Optional：其余生态（npm 的范围、Python 的裸包名）语义不同，本轮不下结论 ⇒ 整键缺席。
    var declaredVersionState: DependencyDeclaredVersionState?

    var id: String { "\(ecosystem.rawValue):\(manifestPath):\(name)" }

    var isDevDependency: Bool { scope == .dev }

    /// 版本过旧 = **实际安装版本**低于最新已知版本。
    ///
    /// 走 `DependencyVersionIdentity` 而不是直接 `DependencyVersion.isOlder(version, latest)`：
    /// 后者会把 `^1.2.3` 的声明范围按下界参与比较（RD-10 明令禁止的"去掉 ^ 就当安装版本"），
    /// 而 `*` / `latest` / `workspace:*` / "未声明" 在旧口径里被折成 0 一律判过旧。
    /// 现在这些形态一律返回 false，并由 `DependencyRecordEvidence` 落成"未定 · 具体原因"。
    var isProbablyOutdated: Bool {
        DependencyVersionIdentity.of(self).outdatedness == .older
    }
}

enum DependencyScope: String, Codable, Sendable {
    case runtime = "运行时"
    case dev = "开发"
    case test = "测试"
    case platform = "平台"
    case build = "构建"
    case unknown = "未标注"
}

/// 一个 scope 的统计格（RD-13c：runtime / dev / test / build 分别汇总，不许混成一个数）。
///
/// `scope` 用 `DependencyScope.rawValue`（中文）原样存，是为了让 JSON 出口自解释；
/// 三个计数分别回答三个不同的问题，缺一个就会有人拿"总数"当"核对数"用。
struct DependencyScopeCount: Codable, Equatable, Sendable {
    var scope: String = DependencyScope.unknown.rawValue
    /// 该 scope 下声明的依赖条数。
    var declared: Int = 0
    /// 其中**漏洞核对确实成功**的条数（`.checked`）—— "未发现漏洞"只能按这个数说。
    var vulnerabilityChecked: Int = 0
    /// 其中版本核对拿到可用结果的条数。
    var versionChecked: Int = 0
    /// 其中带已知漏洞命中的条数。
    var vulnerable: Int = 0
}

enum VersionCheckSource: String, Codable, Sendable {
    case none = "无数据"
    case bundledSnapshot = "内置快照"
    case onlineRegistry = "在线源"
}

// MARK: - 版本声明三态（RD-13b：父 POM / 导入 BOM 未解析 ≠ 项目没管理版本）

/// 清单里那一栏**为什么没有确切版本**——三种含义完全不同的事，旧实现一律写成"未声明"。
///
/// 为什么必须分开（台账 RD-13b）：Maven 子模块里一条 `<dependency>` 不写 `<version>`
/// 通常**不是**"项目没管理版本"，而是版本由父 POM 的 `dependencyManagement`
/// 或导入的 BOM 决定 —— 那是"这个项目把版本集中管理了"，是**好**的形状。
/// 把它说成"未声明"会有两个坏结局：① 用户被暗示去手工补版本号来消提示（正是整改意见点名的
/// 那种"为消提示改被扫对象"），② 真忘了管的清单和集中管理的清单在界面上分不开。
///
/// 为什么住在契约里而不是视图的派生类型：这个事实由**解析清单那一刻**才知道
/// （只有 `PomDocumentModel` 看得见 `<parent>` 与 `<scope>import</scope>`），
/// 而消费者是依赖行、总览、评分、无头出口四方 —— 与 `DependencyCheckState` 同一条理由。
/// 为什么 Optional：旧报告没有这一格，非 Optional 会让整份解码失败（AGENTS §5.9 第 2 条）。
enum DependencyDeclaredVersionState: String, Codable, CaseIterable, Sendable {
    /// 这一栏写得出确切版本（或已解析产物把它补上了）—— 三态之外的正常态。
    case explicit = "已显式声明"
    /// 没写版本，且这份清单**没有**父级 / 导入 BOM 可指望 ⇒ 项目确实没给它定版本。
    case notDeclared = "未显式声明"
    /// 没写版本，但同份清单里有 `<parent>` 或 `<scope>import</scope>` 的 BOM ⇒ 版本由父级管理，
    /// 我们没把它解析出来（要读 effective-POM / 依赖树 / SBOM 才知道是哪个版本）。
    case managedByParent = "由父级管理但未解析"
    /// 写了版本，但那是一个我们代不出来的占位（`${unknown.property}`、`{env:VAR}` 之类）
    /// ⇒ 确实无法确定。**不许**把它当"没写"，也不许拿占位原文去比较。
    case undeterminable = "确实无法确定"

    /// 这个状态算不算"清单自己给出了可比对的版本"。
    var hasConcreteVersion: Bool { self == .explicit }
}

// MARK: - 核对状态（RD-11：版本核对与漏洞核对是两件事，逐条各记一份）

/// 一条依赖在**某一个核对维度**上到底走到哪一步了。六态是用户点名的最小集：
/// 「未查 / 查失败 / 版本没解析出来 / 生态不支持 / 预算没覆盖到 / 成功」
/// 必须先能互相区分，"未发现漏洞"这句话才谈得上诚实。
///
/// 为什么是 `String` 原始值 + 住在契约里：这三处消费者（依赖行、总览、健康评分）
/// 读的是**同一份落盘证据**，而 CLI 与 GUI 共用 `ProjectReport` 这一个 schema
/// （AGENTS §5.9 第 2 条）—— 状态只能长在契约上，放不进视图的派生类型里，
/// 否则无头出口与界面就会各算一套（那正是本轮要消灭的 X6 证据链断裂）。
enum DependencyCheckState: String, Codable, CaseIterable, Sendable {
    /// 这一路根本没发起（默认离线、或该记录没进批次）。
    case notAttempted = "未查"
    /// 发起了且拿到了可用结果（查成功，命中与否另说）。
    case checked = "已核对"
    /// 发起了但请求失败 / 超时 / 响应解不出来。
    case failed = "核对失败"
    /// 声明的是范围且没有任何锁文件把它解析成确切版本 ⇒ 没资格进查询。
    case versionUnresolved = "版本未解析"
    /// 该生态不在数据源覆盖范围内（OSV 不查 SwiftPM / CocoaPods；快照没收录该包）。
    case ecosystemUnsupported = "生态不支持"
    /// 生态支持、版本也可解析，但被单次上限 / 时间预算挡在门外，没进批次。
    case budgetExcluded = "预算未覆盖"

    /// 这个状态算不算"确实核对过"。**只有 `.checked` 算**——
    /// 任何把 `attempted`、`networkLookupPerformed` 当"核对过"用的写法都是 RD-11 的靶子。
    var isCovered: Bool { self == .checked }
}

/// 一条核对路径的账本（报告级）。
///
/// 字段全部非 Optional 且随父字段整体缺席：**键不存在 = 这一路没测过**；
/// 存在则每个数都是数出来的（0 就是真的 0）。这是 AGENTS §5.9 第 2 条
/// "缺数据靠整键缺席表达"的形状，`failed = 0` 与"没记 failed"不能混。
struct DependencyLookupEvidence: Codable, Equatable, Sendable {
    /// 数据源标签："OSV" / "npm registry" / "内置快照"。
    var source: String = ""
    /// 本次纳入统计的记录总数（逐条状态相加应等于它，由守卫用例钉住）。
    var totalRecords: Int = 0
    var attempted: Int = 0
    var checked: Int = 0
    var failed: Int = 0
    var versionUnresolved: Int = 0
    var ecosystemUnsupported: Int = 0
    var budgetExcluded: Int = 0
    /// 查询用的规范化身份说明（例如"按声明下界查询"占了多少条），供出口原文引用。
    var lowerBoundQueries: Int = 0

    /// 这一路有没有**真的**核对过（不是"尝试过"）。
    var hasCoverage: Bool { checked > 0 }
    /// 是否留了尾巴：失败 / 未覆盖 / 预算没到，任意一项都要出声。
    var isPartial: Bool { failed > 0 || budgetExcluded > 0 || versionUnresolved > 0 || ecosystemUnsupported > 0 }
}

struct SecurityAdvisory: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var aliases: [String]
    var summary: String
    var details: String
    var severity: RiskLevel
    var cvssScore: Double?
    var affectedPackages: [String]
    var ecosystem: DependencyEcosystem
    var publishedAt: Date?
    var source: String
}

struct DependencyVulnerability: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var package: String
    var ecosystem: DependencyEcosystem
    var vulnerableRange: String
    var fixedVersion: String?
    var summary: String
    var severity: RiskLevel
    var cveIdentifiers: [String]
    var affectedDependencies: [String]
}
