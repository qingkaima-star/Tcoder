// MARK: - 仓库定位与组装的纯函数层（WS-B · Git 分析入口）
//
// 从 ShellGitAnalyzer.swift 拆出，只为守住本轮的文件规模线（单文件 ≤ 400 行）。
// 这一层**不起进程、不读目录**，全部是给定输入即给定输出的纯函数，所以单元测试
// 直接打这一层。判定与文案（含「试过哪些位置」那句中文）逐字照抄，一字未改。
// 本来就是 `static func`（模块内可见），拆分不涉及任何可见性放宽。

import Foundation

extension ShellGitAnalyzer {
// MARK: - Pure helpers (unit-testable, no process spawning)

    /// 归一化路径：去掉符号链接差异与尾随斜杠，保证「git 报上来的根」和
    /// 「用户选的目录」可比（macOS 上 `/tmp` 是 `/private/tmp` 的符号链接）。
    static func canonicalPath(_ path: String) -> String {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath().path
        if resolved.count > 1, resolved.hasSuffix("/") { return String(resolved.dropLast()) }
        return resolved
    }

    /// `root` 是 `path` 的第几层祖先；不是祖先返回 nil，相等返回 0。
    static func upwardHops(fromRoot root: String, to path: String) -> Int? {
        if root == path { return 0 }
        guard path.hasPrefix(root + "/") else { return nil }
        return path.dropFirst(root.count + 1).components(separatedBy: "/").count
    }

    /// 逐级父目录链（不含起点自身，含到 `/` 或跨挂载点为止），最多 `limit` 层。
    static func parentChain(of path: String, limit: Int, sameVolume: (String, String) -> Bool) -> [String] {
        var result: [String] = []
        var cursor = canonicalPath(path)
        while result.count < limit {
            let parent = canonicalPath((cursor as NSString).deletingLastPathComponent)
            guard parent != cursor, !parent.isEmpty else { return result }
            guard sameVolume(parent, cursor) else { return result }
            result.append(parent)
            cursor = parent
        }
        return result
    }

    /// 多候选时选提交数最多的；并列时取更浅的，再并列按路径字典序（结果必须可复现）。
    static func pickPrimaryCandidate(_ entries: [(candidate: NestedRepositoryCandidate, depth: Int)])
        -> (candidate: NestedRepositoryCandidate, depth: Int)? {
        entries.min { lhs, rhs in
            if lhs.candidate.commitCount != rhs.candidate.commitCount {
                return lhs.candidate.commitCount > rhs.candidate.commitCount
            }
            if lhs.depth != rhs.depth { return lhs.depth < rhs.depth }
            return lhs.candidate.path < rhs.candidate.path
        }
    }

    /// 找不到仓库时给用户的「试过哪里」。
    static func attemptedLocationsText(upward: Int, nested: Int) -> String {
        "已尝试：所选目录自身、向上最多 \(upward) 层父目录、向下最多 \(nested) 层子目录，均未找到 .git"
    }

    /// 组装 `GitInsights`。
    ///
    /// 口径（重要，写进笔记也写在这里）：
    /// * `totalCommits` = 仓库真值，**含 merge 提交**，来自 `rev-list --count HEAD`；取不到时退回窗口条数。
    /// * `commitsAnalyzed` = 实际解析的提交数，来自 `git log --no-merges -n 窗口`，**不含 merge**。
    /// * `historyTruncated` = 前者大于后者。因此只要仓库里有 merge 提交，这个标志就为真 ——
    ///   它表达的是「下面的统计没覆盖全部历史」，而不是「进程出错」。
    /// * `authors` / `activityByHour` / `commitsPerPeriod` / `recentCommits` 一律只覆盖已分析窗口。
    /// * `commitsPerPeriod` 的日/周/月桶边界按**提交者自己的时区**切（`GitAggregation.authorCalendar`），
    ///   与逐时/逐日直方图同一把尺子；不再用 UTC 切桶却用本地贴标签（缺陷 #42）。
    static func makeInsights(commits: [ParsedCommit],
                             branch: String,
                             headSHA: String,
                             remoteURL: String,
                             fullCommitCount: Int? = nil,
                             resolution: RepositoryResolution? = nil,
                             workingTree: WorkingTreeOutcome = .notMeasured(reason: "本次分析未探测工作区"),
                             now: Date = Date()) -> GitInsights {
        let dates = commits.map(\.date)
        let first = dates.min()
        let last = dates.max()
        let granularity = GitAggregation.granularity(forFirst: first, last: last)
        let calendar = GitAggregation.authorCalendar(for: commits)

        var insights = GitInsights()
        insights.analyzedAt = now
        insights.isRepository = true
        if let resolution {
            insights.resolvedRepositoryRoot = resolution.rootPath
            insights.discoveryMode = resolution.mode
            insights.discoveryHops = resolution.hops
            insights.nestedCandidates = resolution.nestedCandidates
        }
        insights.branch = branch
        // 缩短只在这一处发生：上游 `rev-parse HEAD` 给全长，落盘/上屏给 `CommitIdentity` 那一把尺子的宽度。
        insights.headSHA = CommitIdentity.abbreviated(headSHA)
        insights.remoteURL = remoteURL
        switch workingTree {
        case .dirty(let entries):
            insights.workingTreeDirty = true
            insights.dirtyEntryCount = entries
        case .clean:
            insights.workingTreeDirty = false
            insights.dirtyEntryCount = 0
        case .notMeasured(let reason):
            insights.workingTreeDirty = nil
            insights.dirtyProbeNote = reason
        }
        insights.commitsAnalyzed = commits.count
        insights.totalCommits = max(fullCommitCount ?? commits.count, commits.count)
        insights.historyTruncated = insights.commitsAnalyzed < insights.totalCommits
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



    /// 跨挂载点就停：`/Volumes/...`、外部盘不该被算进「向上找父仓库」。
    static func isSameVolume(_ lhs: String, _ rhs: String) -> Bool {
        guard let left = try? URL(fileURLWithPath: lhs).resourceValues(forKeys: [.volumeIdentifierKey]),
              let right = try? URL(fileURLWithPath: rhs).resourceValues(forKeys: [.volumeIdentifierKey]) else {
            return true
        }
        guard let leftID = left.volumeIdentifier, let rightID = right.volumeIdentifier else { return true }
        return leftID.isEqual(rightID)
    }
}
