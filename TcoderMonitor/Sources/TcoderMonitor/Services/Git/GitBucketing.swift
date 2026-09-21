// MARK: - Git 时间分桶（WS-B · 子代理2）
//
// 从 GitAggregation.swift 拆出，只为守住本轮的文件规模线（单文件 ≤ 400 行）。
// 粒度选择阈值、`Calendar` 的构造（UTC 与「作者主导偏移」两条）、桶起点与补洞逻辑
// **逐字照抄**，没有改任何一个判定与取值。
//
// 跨文件后仅把「被 GitAggregation.swift 另一边也要调」的可见性保持原样；
// 这一段内部自用的四个 helper 仍是 private（private 现在是本文件内可见，与拆分前一致）。

import Foundation

extension GitAggregation {

    /// 补洞时最多愿意填多少个桶。**值 120 一字未动**，只是跟着唯一使用它的
    /// 分桶代码搬了家（原先在 GitAggregation.swift 里是 private static let）。
    /// Upper bound on the number of buckets we are willing to zero-fill.
    private static let fillLimit = 120
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
}
