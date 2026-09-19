import Foundation

/// OWNER: WS-B（Git 分析入口）。类型名与协议一致性已冻结。
///
/// 本文件只做三件事：探路、跑 git 命令、把 `GitLogParser` + `GitAggregation`
/// 的产出组装成 `GitInsights`。解析细节在 `GitLogParser.swift`，
/// 统计口径在 `GitAggregation.swift`。
///
/// 非仓库 / 没有 git 可执行文件一律 **抛错**（`AppState.attempt` 会把它隔离成
/// 单个分析器的失败提示），绝不返回空对象冒充成功。
final class ShellGitAnalyzer: GitAnalysisProviding {

    /// 历史上限：再大的仓库也只看最近 2 万条非合并提交。
    static let maxCommits = 20_000
    /// 最近提交列表的展示条数。
    static let recentCommitLimit = 20

    /// 规格固定的主命令。`%x1f` 分字段、`%x1e` 分提交，`%aI` 是带作者时区偏移的严格 ISO8601。
    static let logArguments: [String] = [
        "log", "--no-merges", "-n", "\(maxCommits)", "--date=iso-local",
        "--pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e", "--numstat",
    ]

    private static let gitBinary = "git"

    private let logTimeout: TimeInterval
    private let probeTimeout: TimeInterval

    /// - Parameters:
    ///   - logTimeout: `git log` 的硬超时，大仓库需要更宽的预算（默认 60 秒）。
    ///   - probeTimeout: 探路与元信息命令的超时。
    init(logTimeout: TimeInterval = 60, probeTimeout: TimeInterval = 10) {
        self.logTimeout = logTimeout
        self.probeTimeout = probeTimeout
    }

    // MARK: - Entry point

    func analyze(repositoryURL: URL) async throws -> GitInsights {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AnalysisError.notDirectory(repositoryURL.path)
        }
        guard Shell.isAvailable(Self.gitBinary) else { throw AnalysisError.gitBinaryMissing }

        let probe = await run(["rev-parse", "--is-inside-work-tree"], at: repositoryURL, timeout: probeTimeout)
        if probe.timedOut { throw AnalysisError.timedOut("git rev-parse") }
        guard probe.succeeded, probe.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
            throw AnalysisError.notGitRepository(repositoryURL.path)
        }

        async let branchProbe = run(["rev-parse", "--abbrev-ref", "HEAD"], at: repositoryURL, timeout: probeTimeout)
        async let headProbe = run(["rev-parse", "--short=7", "HEAD"], at: repositoryURL, timeout: probeTimeout)
        async let remoteProbe = run(["config", "--get", "remote.origin.url"], at: repositoryURL, timeout: probeTimeout)
        let log = await run(Self.logArguments, at: repositoryURL, timeout: logTimeout)
        let branchResult = await branchProbe
        let headResult = await headProbe
        let remoteResult = await remoteProbe

        let commits: [ParsedCommit]
        if log.succeeded {
            commits = GitLogParser.parse(log.stdout)
        } else if log.timedOut {
            throw AnalysisError.timedOut("git log")
        } else if Self.isEmptyRepository(stderr: log.stderr, headFailed: !headResult.succeeded) {
            // 刚 git init、还没有任何提交：0 是真实答案，不是失败。
            commits = []
        } else {
            throw AnalysisError.empty("git log 执行失败（\(Self.firstLine(log.stderr))）")
        }

        return Self.makeInsights(
            commits: commits,
            branch: Self.branchName(from: branchResult, headFailed: !headResult.succeeded),
            headSHA: headResult.succeeded ? Self.firstLine(headResult.stdout) : "",
            remoteURL: remoteResult.succeeded ? Self.firstLine(remoteResult.stdout) : ""
        )
    }

    // MARK: - Pure assembly (unit-testable without shelling out)

    static func makeInsights(commits: [ParsedCommit],
                             branch: String,
                             headSHA: String,
                             remoteURL: String,
                             now: Date = Date()) -> GitInsights {
        let dates = commits.map(\.date)
        let first = dates.min()
        let last = dates.max()
        let granularity = GitAggregation.granularity(forFirst: first, last: last)
        let calendar = GitAggregation.defaultCalendar()

        var insights = GitInsights()
        insights.analyzedAt = now
        insights.isRepository = true
        insights.branch = branch
        insights.headSHA = headSHA
        insights.remoteURL = remoteURL
        insights.totalCommits = commits.count
        insights.firstCommitAt = first
        insights.lastCommitAt = last
        if let first {
            insights.projectAgeDays = max(0, Int(now.timeIntervalSince(first) / 86_400))
        }
        insights.totalAdditions = commits.reduce(0) { $0 + $1.additions }
        insights.totalDeletions = commits.reduce(0) { $0 + $1.deletions }
        insights.filesTouched = GitAggregation.distinctFileCount(from: commits)
        insights.authors = GitAggregation.authorStats(from: commits)
        insights.commitsPerPeriod = GitAggregation.buckets(from: commits,
                                                          granularity: granularity,
                                                          calendar: calendar)
        insights.activityByHour = GitAggregation.activityByHour(from: commits)
        insights.activityByWeekday = GitAggregation.activityByWeekday(from: commits)
        insights.recentCommits = GitAggregation.recentCommits(from: commits, limit: recentCommitLimit)
        return insights
    }

    // MARK: - Command plumbing

    struct GitCommandOutcome: Sendable {
        let stdout: String
        let stderr: String
        let succeeded: Bool
        let timedOut: Bool
    }

    private func run(_ arguments: [String], at root: URL, timeout: TimeInterval) async -> GitCommandOutcome {
        let started = Date()
        let result = await Shell.run(Self.gitBinary,
                                     arguments: arguments,
                                     workingDirectory: root,
                                     timeout: timeout)
        let elapsed = Date().timeIntervalSince(started)
        // Shell 超时是 terminate() 之后才返回的，用耗时兜底判定（留 50ms 余量）。
        let timedOut = !result.succeeded && elapsed >= timeout - 0.05
        return GitCommandOutcome(stdout: result.stdout, stderr: result.stderr,
                                 succeeded: result.succeeded, timedOut: timedOut)
    }

    private static func isEmptyRepository(stderr: String, headFailed: Bool) -> Bool {
        let text = stderr.lowercased()
        if text.contains("does not have any commits yet") { return true }
        // HEAD 本身解不出来（游离/未出生分支的空仓库）且 log 没有任何输出。
        return headFailed && (text.contains("ambiguous argument 'head'")
            || text.contains("unknown revision")
            || text.contains("bad revision"))
    }

    private static func branchName(from outcome: GitCommandOutcome, headFailed: Bool) -> String {
        if !outcome.succeeded { return headFailed ? "未出生分支" : "" }
        let name = firstLine(outcome.stdout)
        return name == "HEAD" ? "游离 HEAD" : name
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.components(separatedBy: "\n").first else { return "" }
        return line.trimmingCharacters(in: .whitespaces)
    }
}
