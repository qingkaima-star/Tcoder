import Foundation

// MARK: - Git history analysis

struct GitInsights: Codable, Equatable, Sendable {
    var analyzedAt: Date = Date()
    var isRepository: Bool = false
    var branch: String = ""
    var headSHA: String = ""
    var remoteURL: String = ""

    var totalCommits: Int = 0
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
    var busFactorRisk: RiskLevel {
        guard let top = topAuthor, totalCommits > 0 else { return .none }
        let share = Double(top.commits) / Double(totalCommits)
        if activeAuthorCount <= 1 && totalCommits > 50 { return .critical }
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
