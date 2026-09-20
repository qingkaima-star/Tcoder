import Foundation

// MARK: - Git history analysis

/// How the analyzer located the repository relative to the directory the user picked.
enum GitDiscoveryMode: String, Codable, Sendable {
    case selectedDirectory = "所选目录即仓库"
    case parentDirectory = "向上找到父仓库"
    case nestedSubdirectory = "向下找到子仓库"
    case none = "未找到仓库"
}

struct NestedRepositoryCandidate: Codable, Equatable, Hashable, Identifiable, Sendable {
    var path: String
    var branch: String
    var commitCount: Int
    var lastCommitAt: Date?

    var id: String { path }
    var directoryName: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct GitInsights: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var isRepository: Bool = false

    /// Where `.git` actually lives. May differ from the directory the user selected
    /// when discovery walked up to a parent or down into a subdirectory.
    var resolvedRepositoryRoot: String?
    var discoveryMode: GitDiscoveryMode = .none
    /// Depth of the hop between the selected directory and the resolved repository.
    var discoveryHops: Int = 0
    /// Other repositories found underneath the selected directory, so the UI can let
    /// the user pick one instead of silently analysing the wrong repository.
    var nestedCandidates: [NestedRepositoryCandidate] = []

    var branch: String = ""
    var headSHA: String = ""
    var remoteURL: String = ""

    var totalCommits: Int = 0
    /// How many commits were actually parsed. Large repositories are read within a
    /// cap, so this can be smaller than `totalCommits`; derived statistics
    /// (commits/day, author shares, activity heatmaps) describe this window only.
    var commitsAnalyzed: Int = 0
    /// True when the cap was hit, i.e. the analysis covers only the newest history.
    var historyTruncated: Bool = false
    var firstCommitAt: Date?
    var lastCommitAt: Date?
    var projectAgeDays: Int = 0

    var totalAdditions: Int = 0
    var totalDeletions: Int = 0
    var filesTouched: Int = 0

    var authors: [AuthorStats] = []
    var commitsPerPeriod: [CommitBucket] = []
    var activityByHour: [Int] = Array(repeating: 0, count: 24)
    var activityByWeekday: [Int] = Array(repeating: 0, count: 7)
    var recentCommits: [CommitRecord] = []

    var activeAuthorCount: Int { authors.filter { $0.commits > 0 }.count }
    var commitsPerDay: Double {
        guard let first = firstCommitAt, let last = lastCommitAt else { return 0 }
        let days = max(1, Int(last.timeIntervalSince(first) / 86_400))
        return Double(totalCommits) / Double(days)
    }
    var busiestHour: Int? {
        guard let maxCount = activityByHour.max(), maxCount > 0 else { return nil }
        return activityByHour.firstIndex(of: maxCount)
    }
    var topAuthor: AuthorStats? { authors.max { $0.commits < $1.commits } }

    /// 作者统计的总体：作者表按 `--no-merges` 建（AGENTS §21 定的口径），
    /// 所以任何"某作者占多少"的比值都必须以这个求和为分母。
    /// 拿 `totalCommits`（含合并）当分母是**分子分母来自两个不同总体**，
    /// 本仓实测会把 139/152 = 91.4% 的集中度算成 139/271 = 51%，
    /// 于是单点风险被腰斩、协作分布分量白拿分（缺陷 #44）。
    var authorBasisCommits: Int { authors.reduce(0) { $0 + $1.commits } }

    var busFactorRisk: RiskLevel {
        let basis = authorBasisCommits
        guard let top = topAuthor, basis > 0 else { return .none }
        let share = Double(top.commits) / Double(basis)
        if activeAuthorCount <= 1 && basis > 50 { return .critical }
        if share > 0.7 { return .high }
        if share > 0.5 { return .medium }
        return .low
    }
}

struct AuthorStats: Codable, Equatable, Hashable, Identifiable, Sendable {
    var name: String
    var email: String
    var commits: Int
    var additions: Int
    var deletions: Int
    var filesTouched: Int
    var firstCommitAt: Date?
    var lastCommitAt: Date?
    var activityByHour: [Int]
    var topDirectories: [String: Int]

    var id: String { "\(name)<\(email)>" }
    var totalChurn: Int { additions + deletions }

    var lastActiveDescription: String {
        guard let last = lastCommitAt else { return "无记录" }
        let days = Int(Date().timeIntervalSince(last) / 86_400)
        if days <= 0 { return "今天" }
        if days == 1 { return "昨天" }
        if days < 30 { return "\(days) 天前" }
        return "\(days / 30) 个月前"
    }
}

struct CommitBucket: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Bucket start, normalized to the granularity used (day or week).
    var date: Date
    var commits: Int
    var additions: Int
    var deletions: Int
    var granularity: BucketGranularity

    var id: Date { date }
}

enum BucketGranularity: String, Codable, Sendable {
    case day
    case week
    case month
}

struct CommitRecord: Codable, Equatable, Hashable, Identifiable, Sendable {
    var sha: String
    var author: String
    var email: String
    var date: Date
    var subject: String
    var filesChanged: Int
    var additions: Int
    var deletions: Int

    var id: String { sha }
}
