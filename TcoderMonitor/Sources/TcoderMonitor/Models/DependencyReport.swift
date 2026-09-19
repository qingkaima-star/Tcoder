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

    var id: String { "\(ecosystem.rawValue):\(manifestPath):\(name)" }

    var isDevDependency: Bool { scope == .dev }
    var isProbablyOutdated: Bool {
        guard let latest = latestKnownVersion else { return false }
        return DependencyVersion.isOlder(current: version, than: latest)
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
enum DependencyVersion {
    static func normalize(_ raw: String) -> [Int] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let core = trimmed.prefix(while: { !$0.isWhitespace && "-+~^<>=()".firstIndex(of: $0) == nil })
        let parts = core.split(separator: ".").map { segment -> Int in
            Int(segment.prefix(while: { $0.isNumber })) ?? 0
        }
        return parts.isEmpty ? [0] : parts
    }

    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let a = normalize(lhs), b = normalize(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }

    static func isOlder(current: String, than latest: String) -> Bool {
        compare(current, latest) == .orderedAscending
    }
}
