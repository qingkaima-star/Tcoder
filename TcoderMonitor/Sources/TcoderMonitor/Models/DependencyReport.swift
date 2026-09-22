import Foundation

// MARK: - Dependency & vulnerability analysis

struct DependencyReport: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var ecosystems: [EcosystemReport] = []
    var advisories: [SecurityAdvisory] = []
    var offlineVulnerabilities: [DependencyVulnerability] = []
    var networkLookupPerformed: Bool = false
    var networkLookupNote: String = ""

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

enum VersionCheckSource: String, Codable, Sendable {
    case none = "无数据"
    case bundledSnapshot = "内置快照"
    case onlineRegistry = "在线源"
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

/// Minimal dotted-version compare that tolerates suffixes like `-SNAPSHOT`, `+build`, `^1.2.3`.
///
/// ## RD-10 的根因修正（2026-09-22，R3 依 AGENTS §8.1 豁免动本类型）
///
/// 旧实现在自己内部有**两套**口径，且其中一套是错的：
///   · 这里用 `prefix(while:)` 取"数字芯"，而截断符集合里就写着 `^~<>` ——
///     `^1.2.3` 在**第一个字符**处断成空串 → `parts.isEmpty` → 返回 `[0]`，
///     于是任何 caret 声明都"落后于"任何最新版本（虚报过旧），
///     `*` / `latest` / `未声明` / `abc` 同样被折成 0.0.0 参与比较；
///   · 同一仓的 `KnownVulnerability.comparableCore` 却会先吃掉 `^`（两处不一致，台账点名）。
///
/// 现在的形状：
///   1. **全仓只有一把版本尺子** —— 比较一律下沉到 `DependencySemver`
///      （`Services/Dependencies/DependencyVersionIdentity.swift`），本类型不再自带第二套解析；
///      预发布（`-beta` / `-SNAPSHOT`）低于正式版，构建元数据（`+build`）不参与先后。
///   2. **认不出就是认不出**：`normalize` 返回空数组（旧返回 `[0]`），`outcome` 返回 `.unknown`，
///      `isOlder` 对不可比较的一侧返回 false —— 但**上层必须出声**，
///      逐条依赖的"为什么判不了"由 `DependencyVersionBlocker` 承载，不靠沉默。
///
/// ⚠ 本类型只回答"这两个串谁在前谁在后"。**"这条依赖装的是哪个版本"是另一件事**：
/// 声明范围 / 实际解析版本 / 最新已知版本三份身份住在 `DependencyVersionIdentity`，
/// `isProbablyOutdated` 已改走它 —— 那里明确禁止把 `^1.2.3` 的下界当安装版本。
enum DependencyVersion {
    /// 数字芯（不含预发布语义）。解析不出返回**空数组**（旧实现给 `[0]`，那正是 RD-10 的病根）。
    static func normalize(_ raw: String) -> [Int] {
        Self.core(raw)?.segments ?? []
    }

    /// 这个串能不能收敛成一个版本号。
    static func isComparable(_ raw: String) -> Bool { Self.core(raw) != nil }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        guard let left = Self.core(lhs), let right = Self.core(rhs) else { return .orderedSame }
        return DependencySemver.compare(left, right)
    }

    static func isOlder(current: String, than latest: String) -> Bool {
        outcome(current: current, than: latest) == .older
    }

    /// 三态结局：不可比较时**明确返回 `.unknown`**，调用方必须出声，不许按"更旧"或"不旧"处理。
    static func outcome(current: String, than latest: String) -> Outcome {
        guard let left = Self.core(current), let right = Self.core(latest) else { return .unknown }
        switch DependencySemver.compare(left, right) {
        case .orderedAscending: return .older
        case .orderedDescending: return .newer
        default: return .same
        }
    }

    enum Outcome: Equatable, Sendable {
        case older, same, newer, unknown
    }

    private static func core(_ raw: String) -> DependencySemver? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // 前缀范围算符与 `v`：`^` `~` `>=` `>` `<=` `<` `=`，允许跟空格（`>= 1.2.3`）。
        while let first = text.first, "^~<>=".contains(first) {
            text = String(text.dropFirst())
            text = text.trimmingCharacters(in: .whitespaces)
        }
        // 带区间 / 多选 / 通配结构的串不是"一个版本号"，宁可不解，也不去取它某个端点冒充版本。
        if text.contains(where: { "[],()|*".contains($0) }) { return nil }
        if text.split(separator: ".").contains(where: { $0.lowercased() == "x" }) { return nil }
        return DependencySemver.parse(text)
    }
}
