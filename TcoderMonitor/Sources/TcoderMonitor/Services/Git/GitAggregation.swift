import Foundation

// MARK: - Git aggregation (WS-B · 子代理2)
//
// OWNER: WS-B subagent 2. Pure derivation layer sitting on top of the parsed
// `git log --numstat` stream produced by `GitLogParser` (owned by subagent 1).
// Nothing here shells out to git, mutates state, or touches `@MainActor` types,
// so it is safe to call from `Task.detached` analysis paths.
//
// Contract notes:
// * `Models/GitInsights.swift` is frozen — every value produced here is a plain
//   transformation into those frozen shapes.
// * Authors are merged by email **only** (via `GitLogParser.normalizeEmail`);
//   the display name is taken from that email's chronologically last commit.
// * Hour/weekday histograms use each *author's own* committed timezone
//   (`authorOffsetSeconds`), never the machine timezone. Time bucketing
//   (`.day` / `.week` / `.month`, defect #42) uses the same yardstick: the grid is
//   a *fixed offset* calendar pinned to the commits' dominant author offset
//   (see `authorCalendar(for:)`). Bucketing in UTC while labelling in local time
//   used to split a single working day across two buckets (or merge two days into
//   one), which is exactly what the "提交趋势" chart showed.

enum GitAggregation {

    /// Upper bound on the number of buckets we are willing to zero-fill.
    private static let fillLimit = 120

    // MARK: - Author roll-up

    /// Merge commits by normalized email; one `AuthorStats` per distinct email.
    /// Sorted by commit count (desc), then name (asc), then email (asc) so the
    /// result is deterministic regardless of input order.
    static func authorStats(from commits: [ParsedCommit]) -> [AuthorStats] {
        guard !commits.isEmpty else { return [] }

        var boxes: [String: GitAuthorAccumulator] = [:]
        boxes.reserveCapacity(min(commits.count, 64))

        for commit in commits {
            let email = GitLogParser.normalizeEmail(commit.authorEmail)
            let box: GitAuthorAccumulator
            if let existing = boxes[email] {
                box = existing
            } else {
                box = GitAuthorAccumulator(email: email)
                boxes[email] = box
            }
            absorb(commit, into: box)
        }

        return boxes.values.map { $0.makeStats() }.sorted { lhs, rhs in
            if lhs.commits != rhs.commits { return lhs.commits > rhs.commits }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.email < rhs.email
        }
    }

    /// Single-commit accumulation for one author. Reference semantics box keeps
    /// the `Set`/`Dictionary` members uniquely owned, so inserts never pay for a
    /// copy-on-write buffer clone (important at ~20k commits).
    private static func absorb(_ commit: ParsedCommit, into box: GitAuthorAccumulator) {
        box.commits += 1
        box.additions += commit.additions
        box.deletions += commit.deletions

        let date = commit.date
        if box.firstCommitAt == nil || date < box.firstCommitAt! { box.firstCommitAt = date }
        if box.lastCommitAt == nil || date > box.lastCommitAt! {
            box.lastCommitAt = date
            box.name = commit.authorName        // name of the chronologically last commit
        }

        let hour = clampedHour(GitLogParser.localHour(of: date, offsetSeconds: commit.authorOffsetSeconds))
        box.activityByHour[hour] += 1

        for change in commit.changes {
            box.filesTouched.insert(change.path)
            box.directoryCounts[firstDirectory(of: change.path), default: 0] += 1
        }
    }

    // MARK: - Activity histograms

    /// Commits per local hour (0..<24) in each author's own timezone.
    /// Always returns exactly 24 buckets.
    static func activityByHour(from commits: [ParsedCommit]) -> [Int] {
        var result = [Int](repeating: 0, count: 24)
        for commit in commits {
            let hour = clampedHour(GitLogParser.localHour(of: commit.date, offsetSeconds: commit.authorOffsetSeconds))
            result[hour] += 1
        }
        return result
    }

    /// Commits per weekday, Monday-first (index 0 == Monday). Always 7 buckets.
    static func activityByWeekday(from commits: [ParsedCommit]) -> [Int] {
        var result = [Int](repeating: 0, count: 7)
        for commit in commits {
            let weekday = clampedWeekday(GitLogParser.localWeekdayMondayFirst(of: commit.date,
                                                                              offsetSeconds: commit.authorOffsetSeconds))
            result[weekday] += 1
        }
        return result
    }

    // MARK: - Time bucketing

    /// Span-adaptive granularity: <= 30 days -> `.day`, <= 200 days -> `.week`,
    /// otherwise `.month`. Missing endpoint -> `.day`.
    static func granularity(forFirst first: Date?, last: Date?) -> BucketGranularity {
        guard let first, let last else { return .day }
        let seconds = abs(last.timeIntervalSince(first))
        guard seconds.isFinite else { return .month }
        let days = Int(seconds / 86_400)
        if days <= 30 { return .day }
        if days <= 200 { return .week }
        return .month
    }

    /// Fixed UTC (GMT) ISO-8601 calendar with Monday-first weeks.
    ///
    /// **不再是生产路径的默认口径**（缺陷 #42）：生产分桶走 `authorCalendar(for:)`。
    /// 这里保留是因为「同一批提交在 UTC 下会被切成另一个样子」这件事必须能被测试
    /// 直接复现——没有这把反面的尺子，#42 的守卫就只能单向断言、随时可能空转。
    static func utcCalendar() -> Calendar {
        calendar(offsetSeconds: 0)
    }

    /// 这批提交**自己的**本地时区日历（缺陷 #42 的修法）。
    ///
    /// 时区取主导作者偏移（见 `dominantAuthorOffset(of:)`），于是 `.day` 桶的边界
    /// 就是「提交者眼里的那天零点」，与 `activityByHour` / `activityByWeekday`
    /// 用的是同一把尺子（`GitLogParser.localHour(of:offsetSeconds:)`）。
    /// 空输入没有作者可言，退回 `utcCalendar()`（此时也不会产出任何桶）。
    static func authorCalendar(for commits: [ParsedCommit]) -> Calendar {
        guard let offset = dominantAuthorOffset(of: commits) else { return utcCalendar() }
        return calendar(offsetSeconds: offset)
    }

    /// 固定偏移的 ISO-8601 日历：周一为一周起点、首周至少 4 天、时区为给定偏移。
    ///
    /// 刻意用**固定偏移**而不是命名时区（`Asia/Shanghai`）：
    /// ① git 的 `%aI` 只给出提交那一刻的 UTC 偏移，反查命名时区得依赖本机 TZ 数据库；
    /// ② 固定偏移没有 DST，桶边界与 `bucketKey` 在任何机器上都逐秒可复现——
    ///    这正是当年 `defaultCalendar()` 固定 UTC 想要的性质，只是那时连「本地」一起固定掉了。
    /// `TimeZone(secondsFromGMT:)` 造不出来的偏移（>±1 天的畸形值）退回 UTC，不崩、不猜。
    static func calendar(offsetSeconds: Int) -> Calendar {
        var calendar = Calendar(identifier: .iso8601)
        // 畸形偏移（超出 `TimeZone` 能表达的范围）造不出时区：退回 UTC 这把中立格子，
        // 不崩也不猜——趋势图照常产出，只是这一天按协调世界时切，见笔记里的契约缺口。
        calendar.timeZone = TimeZone(secondsFromGMT: offsetSeconds)
            ?? TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    /// 这批提交里出现次数最多的 `authorOffsetSeconds`——整批人共用的那把「本地」尺子。
    ///
    /// 为什么按主导偏移切一整条时间轴，而不是**每条提交按各自的偏移**：
    /// 后者会让不同时区的作者产出两套互相错开的桶边界，`filledSpanKeys` 的补空桶
    /// 走格点就会踩空（键对不上→空桶虚增、尾部桶被 `key >= lastKey` 提前 break 掉，
    /// 真实提交从趋势里消失）。跨时区仓库的诚实表达是「按多数人的那天切」，
    /// 而不是「切出两套没人对得上的日子」。
    /// 并列时取更接近 UTC 的那个，再并列取数值更小的——同一批输入永远得同一个结果。
    static func dominantAuthorOffset(of commits: [ParsedCommit]) -> Int? {
        guard !commits.isEmpty else { return nil }
        var counts: [Int: Int] = [:]
        for commit in commits { counts[commit.authorOffsetSeconds, default: 0] += 1 }
        return counts.min { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            let lhsDistance = abs(lhs.key), rhsDistance = abs(rhs.key)
            if lhsDistance != rhsDistance { return lhsDistance < rhsDistance }
            return lhs.key < rhs.key
        }?.key
    }

    /// `.day` -> start of day, `.week` -> Monday 00:00 of the containing ISO week,
    /// `.month` -> first day of the month 00:00, all evaluated in `calendar`.
    /// 生产路径传的 `calendar` 是 `authorCalendar(for:)`，所以这里的「零点」是
    /// **提交者当地零点**；`utcCalendar()` 只留给对照测试。
    static func bucketStart(for date: Date, granularity: BucketGranularity, calendar: Calendar) -> Date {
        switch granularity {
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            var weekly = calendar
            weekly.firstWeekday = 2
            weekly.minimumDaysInFirstWeek = 4
            if let interval = weekly.dateInterval(of: .weekOfYear, for: date) {
                return weekly.startOfDay(for: interval.start)
            }
            return mondayFallback(for: date, calendar: weekly)
        case .month:
            if let interval = calendar.dateInterval(of: .month, for: date) {
                return calendar.startOfDay(for: interval.start)
            }
            let parts = calendar.dateComponents([.year, .month], from: date)
            let composed = calendar.date(from: DateComponents(year: parts.year, month: parts.month, day: 1))
            return calendar.startOfDay(for: composed ?? date)
        }
    }

    /// Commits grouped by `bucketStart`, sorted ascending.
    /// Zero-fills interior gaps while the whole span is <= 120 buckets; otherwise
    /// emits only non-empty buckets (avoids multi-thousand empty buckets).
    static func buckets(from commits: [ParsedCommit],
                        granularity: BucketGranularity,
                        calendar: Calendar) -> [CommitBucket] {
        guard !commits.isEmpty else { return [] }

        var store: [Int: CommitBucket] = [:]
        var presentKeys: [Int] = []
        presentKeys.reserveCapacity(min(commits.count, 512))

        for commit in commits {
            let start = bucketStart(for: commit.date, granularity: granularity, calendar: calendar)
            let key = bucketKey(of: start)
            if var existing = store[key] {
                existing.commits += 1
                existing.additions += commit.additions
                existing.deletions += commit.deletions
                store[key] = existing
            } else {
                store[key] = CommitBucket(date: start,
                                          commits: 1,
                                          additions: commit.additions,
                                          deletions: commit.deletions,
                                          granularity: granularity)
                presentKeys.append(key)
            }
        }

        let sortedKeys = presentKeys.sorted()
        if sortedKeys.count <= fillLimit,
           let filled = filledSpanKeys(from: sortedKeys, store: store,
                                       granularity: granularity, calendar: calendar) {
            var output: [CommitBucket] = []
            output.reserveCapacity(filled.count)
            for entry in filled {
                if let bucket = store[entry.key] {
                    output.append(bucket)
                } else {
                    output.append(CommitBucket(date: entry.date, commits: 0,
                                               additions: 0, deletions: 0,
                                               granularity: granularity))
                }
            }
            return output
        }

        return sortedKeys.compactMap { store[$0] }
    }

    /// Walk first bucket -> last bucket one granularity step at a time.
    /// Returns `nil` when the span is wider than `fillLimit` or the calendar
    /// stops advancing, in which case the caller falls back to non-empty only.
    private static func filledSpanKeys(from sortedKeys: [Int],
                                       store: [Int: CommitBucket],
                                       granularity: BucketGranularity,
                                       calendar: Calendar) -> [(key: Int, date: Date)]? {
        guard let firstKey = sortedKeys.first, let lastKey = sortedKeys.last,
              let startDate = store[firstKey]?.date else { return nil }

        var walk: [(key: Int, date: Date)] = []
        walk.append((key: firstKey, date: startDate))
        var cursor = startDate

        while firstKey != lastKey {
            guard let next = nextBucket(after: cursor, granularity: granularity, calendar: calendar) else { return nil }
            let key = bucketKey(of: next)
            walk.append((key: key, date: next))
            cursor = next
            if key >= lastKey { break }
            if walk.count > fillLimit { return nil }
        }

        return walk.count <= fillLimit ? walk : nil
    }

    /// Next bucket start after `start`; `nil` when the calendar cannot advance.
    private static func nextBucket(after start: Date,
                                   granularity: BucketGranularity,
                                   calendar: Calendar) -> Date? {
        let candidate: Date?
        switch granularity {
        case .day: candidate = calendar.date(byAdding: .day, value: 1, to: start)
        case .week: candidate = calendar.date(byAdding: .day, value: 7, to: start)
        case .month: candidate = calendar.date(byAdding: .month, value: 1, to: start)
        }
        guard let candidate else { return nil }
        let normalized = bucketStart(for: candidate, granularity: granularity, calendar: calendar)
        return normalized > start ? normalized : nil
    }

    /// Whole-second key: bucket starts are calendar-normalized, so this is exact
    /// enough to compare and hash them without floating-point drift.
    private static func bucketKey(of date: Date) -> Int {
        Int(date.timeIntervalSinceReferenceDate.rounded())
    }

    /// Monday 00:00 computed from `weekday` (1 == Sunday in Gregorian-derived
    /// calendars). Only used when `dateInterval(of: .weekOfYear:)` is unavailable.
    private static func mondayFallback(for date: Date, calendar: Calendar) -> Date {
        let dayStart = calendar.startOfDay(for: date)
        let weekday = calendar.component(.weekday, from: dayStart)
        let daysSinceMonday = (weekday + 5) % 7
        guard let shifted = calendar.date(byAdding: .day, value: -daysSinceMonday, to: dayStart) else {
            return dayStart
        }
        return calendar.startOfDay(for: shifted)
    }

    // MARK: - Recent commits & file counters

    /// Assumes `commits` is newest-first and keeps that order. `limit <= 0` -> all.
    static func recentCommits(from commits: [ParsedCommit], limit: Int) -> [CommitRecord] {
        guard !commits.isEmpty else { return [] }
        let capped = limit > 0 ? min(limit, commits.count) : commits.count
        return commits.prefix(capped).map { commit in
            CommitRecord(sha: commit.sha,
                         author: commit.authorName,
                         email: commit.authorEmail,
                         date: commit.date,
                         subject: commit.subject,
                         filesChanged: commit.changes.count,
                         additions: commit.additions,
                         deletions: commit.deletions)
        }
    }

    /// Number of *distinct* paths touched anywhere in the history.
    static func distinctFileCount(from commits: [ParsedCommit]) -> Int {
        guard !commits.isEmpty else { return 0 }
        let changeCount = commits.reduce(into: 0) { total, commit in total += commit.changes.count }
        var seen = Set<String>()
        seen.reserveCapacity(changeCount)
        for commit in commits {
            for change in commit.changes { seen.insert(change.path) }
        }
        return seen.count
    }

    /// First path segment counts across every file change; top `limit` by count
    /// (desc) then name (asc). Paths without a "/" fall into `"(root)"`.
    static func topDirectories(for commits: [ParsedCommit], limit: Int) -> [String: Int] {
        guard limit > 0, !commits.isEmpty else { return [:] }
        var counts: [String: Int] = [:]
        for commit in commits {
            for change in commit.changes {
                counts[firstDirectory(of: change.path), default: 0] += 1
            }
        }
        return rankedDirectories(counts, limit: limit)
    }

    // MARK: - Small shared helpers

    /// Shared top-N ranking: count desc, then name asc. `fileprivate` so the
    /// per-author accumulator can reuse the exact same tie-breaking rules.
    fileprivate static func rankedDirectories(_ counts: [String: Int], limit: Int) -> [String: Int] {
        guard !counts.isEmpty, limit > 0 else { return [:] }
        let ranked = counts.sorted { lhs, rhs in
            if lhs.value != rhs.value { return lhs.value > rhs.value }
            return lhs.key < rhs.key
        }
        var result: [String: Int] = [:]
        result.reserveCapacity(min(limit, ranked.count))
        for entry in ranked.prefix(limit) { result[entry.key] = entry.value }
        return result
    }

    private static func firstDirectory(of path: String) -> String {
        var trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("./") { trimmed = String(trimmed.dropFirst(2)) }
        guard let slash = trimmed.firstIndex(of: "/") else { return "(root)" }
        let directory = String(trimmed[trimmed.startIndex..<slash])
        return directory.isEmpty ? "(root)" : directory
    }

    private static func clampedHour(_ hour: Int) -> Int {
        if hour < 0 { return 0 }
        if hour > 23 { return 23 }
        return hour
    }

    private static func clampedWeekday(_ weekday: Int) -> Int {
        if weekday < 0 { return 0 }
        if weekday > 6 { return 6 }
        return weekday
    }
}

// MARK: - Per-author accumulator

/// Mutable, reference-typed accumulator so the per-author `Set` and `Dictionary`
/// stay uniquely owned during a single pass over the history.
private final class GitAuthorAccumulator {
    let email: String
    var name = ""
    var commits = 0
    var additions = 0
    var deletions = 0
    var firstCommitAt: Date?
    var lastCommitAt: Date?
    var activityByHour = [Int](repeating: 0, count: 24)
    var filesTouched = Set<String>()
    var directoryCounts: [String: Int] = [:]

    init(email: String) {
        self.email = email
    }

    func makeStats() -> AuthorStats {
        AuthorStats(name: name,
                    email: email,
                    commits: commits,
                    additions: additions,
                    deletions: deletions,
                    filesTouched: filesTouched.count,
                    firstCommitAt: firstCommitAt,
                    lastCommitAt: lastCommitAt,
                    activityByHour: activityByHour,
                    topDirectories: GitAggregation.rankedDirectories(directoryCounts, limit: 3))
    }
}
