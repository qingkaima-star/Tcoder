import XCTest
@testable import TcoderMonitor

// WS-B · 子代理5（测试）：Git 解析/聚合 + 依赖清单解析 + 内置漏洞快照的纯函数覆盖。
// 只依赖契约 A/B/C 与冻结模型；无网络、不 shell out、不读他人仓库。
// git 文本全是手写模拟输出，结构与真实
// `git log --pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e --numstat` 一致（已在 /tmp 自建临时仓库实测）。
// 所有 Date 由 timeIntervalSince1970 硬编码，不依赖本机时区。

// MARK: - 夹具

private enum Fixture {
    /// 2026-09-14 是周一，其 UTC 零点。
    static let mondayUTC: TimeInterval = 1_789_344_000
    /// 2026-09-19T00:30:00Z（周六）。
    static let sat0030UTC: TimeInterval = 1_789_777_800
    static let shaA = String(repeating: "a", count: 40)
    static let shaB = String(repeating: "b", count: 40)
    static let shaC = String(repeating: "c", count: 40)

    /// 相对周一 UTC 零点第 `days` 天再加 `seconds` 秒。
    static func utc(days: Int, seconds: Int = 0) -> Date {
        Date(timeIntervalSince1970: mondayUTC + Double(days * 86_400 + seconds))
    }

    static func change(_ path: String, additions: Int = 1, deletions: Int = 0,
                       isBinary: Bool = false, renameFrom: String? = nil) -> ParsedFileChange {
        ParsedFileChange(path: path, additions: additions, deletions: deletions,
                         isBinary: isBinary, renameFrom: renameFrom)
    }

    static func commit(sha: String, date: Date, author: String = "tcoder", email: String = "dev@tcoder.local",
                       offset: Int = 0, subject: String = "chore: 占位提交",
                       changes: [ParsedFileChange] = []) -> ParsedCommit {
        ParsedCommit(sha: sha, authorName: author, authorEmail: email, date: date,
                     authorOffsetSeconds: offset, subject: subject, changes: changes)
    }

    /// 一段真实 git 输出块：头部（5 字段 + \u{1e}）、numstat 行、块间空行。
    static func block(_ sha: String, iso: String, subject: String, rows: [String] = [],
                      author: String = "tcoder", email: String = "dev@tcoder.local") -> String {
        let header = [sha, author, email, iso, subject].joined(separator: "\u{1F}")
        let body = rows.isEmpty ? "" : rows.joined(separator: "\n") + "\n"
        return header + "\u{1E}\n" + body + "\n"
    }

    static func record(name: String, version: String, ecosystem: DependencyEcosystem = .npm,
                       manifest: String = "package.json") -> DependencyRecord {
        DependencyRecord(name: name, version: version, ecosystem: ecosystem, scope: .runtime,
                         manifestPath: manifest, latestKnownVersion: nil, versionCheckSource: .none,
                         knownVulnerabilities: [])
    }

    static func names(_ list: [DependencyRecord]) -> Set<String> { Set(list.map { $0.name }) }

    static func found(_ list: [DependencyRecord], _ name: String) -> DependencyRecord? {
        list.first { $0.name == name }
    }

    static let pkgJSON = """
    {
      "name": "tcoder-web",
      "dependencies": { "react": "^18.3.1", "lodash": "4.17.15" },
      "devDependencies": { "vite": "^5.0.0" },
      "optionalDependencies": { "fsevents": "2.3.3" }
    }
    """

    static let pomXML = """
    <project>
      <properties><spring.version>5.3.30</spring.version><guava.version>32.1.3-jre</guava.version></properties>
      <modules><module>api</module><module>service-core</module></modules>
      <dependencies>
        <dependency>
          <groupId>org.springframework</groupId><artifactId>spring-core</artifactId>
          <version>${spring.version}</version><scope>test</scope>
        </dependency>
        <dependency>
          <groupId>com.google.guava</groupId><artifactId>guava</artifactId>
          <version>${guava.version}</version>
        </dependency>
      </dependencies>
    </project>
    """
}

// MARK: - 契约 A：GitLogParser

final class GitLogParserTests: XCTestCase {

    func testParseReturnsOneCommitPerHeader() {
        let output = Fixture.block(Fixture.shaA, iso: "2026-09-19T08:30:00+08:00", subject: "feat: 新增登录页",
                                   rows: ["10\t2\tSources/App.swift"])
            + Fixture.block(Fixture.shaB, iso: "2026-09-18T21:00:00-05:00", subject: "fix: 修掉乱码",
                            rows: ["1\t1\tREADME.md"])
        let commits = GitLogParser.parse(output)
        XCTAssertEqual(commits.count, 2, "两个头部解析出两次提交")
        XCTAssertEqual(commits[0].sha, Fixture.shaA, "sha 取自第一个字段")
        XCTAssertEqual(commits[0].subject, "feat: 新增登录页", "中文 subject 原样保留")
        XCTAssertEqual(commits[0].authorName, "tcoder", "作者名取自第二个字段")
        XCTAssertEqual(commits[0].authorEmail, "dev@tcoder.local", "邮箱取自第三个字段")
        XCTAssertEqual(commits[0].authorOffsetSeconds, 28_800, "+08:00 即 28800 秒")
        XCTAssertEqual(commits[1].authorOffsetSeconds, -18_000, "-05:00 即 -18000 秒")
        XCTAssertEqual(commits[0].date.timeIntervalSince1970, Fixture.sat0030UTC, accuracy: 0.5,
                       "带偏移的 ISO8601 必须折回同一绝对时刻")
    }

    func testParseAttachesNumstatRowsToOwningCommit() {
        let output = Fixture.block(Fixture.shaA, iso: "2026-09-19T08:30:00+08:00", subject: "feat: 多文件",
                                   rows: ["10\t2\tSources/App.swift", "-\t-\tAssets/logo.png"])
            + Fixture.block(Fixture.shaB, iso: "2026-09-18T21:00:00-05:00", subject: "docs: 文档",
                            rows: ["1\t1\tREADME.md"])
        let commits = GitLogParser.parse(output)
        XCTAssertEqual(commits.count, 2, "块数正确")
        XCTAssertEqual(commits[0].changes.map { $0.path }, ["Sources/App.swift", "Assets/logo.png"],
                       "numstat 行必须挂在它上面那个提交上")
        XCTAssertEqual(commits[1].changes.map { $0.path }, ["README.md"], "后一个提交不得吞掉前一个的变更")
        XCTAssertEqual(commits[0].additions, 10, "additions 是变更之和（二进制行贡献 0）")
        XCTAssertEqual(commits[0].deletions, 2, "deletions 是变更之和")
        XCTAssertEqual(commits[0].filesChanged, 2, "filesChanged 是变更条目数（含二进制）")
        XCTAssertEqual(commits[1].filesChanged, 1, "第二个提交的条目数独立计算")
    }

    func testNumstatLineParsesOrdinaryBinaryAndRejectsGarbage() throws {
        let text = try XCTUnwrap(GitLogParser.numstatLine("7\t3\tSources/Views/RootView.swift"), "普通行必须解析")
        XCTAssertEqual(text.additions, 7, "第一列是新增行数")
        XCTAssertEqual(text.deletions, 3, "第二列是删除行数")
        XCTAssertEqual(text.path, "Sources/Views/RootView.swift", "第三列是路径")
        XCTAssertFalse(text.isBinary, "数字行不是二进制")
        XCTAssertNil(text.renameFrom, "普通行没有重命名来源")
        let binary = try XCTUnwrap(GitLogParser.numstatLine("-\t-\tAssets/logo.png"), "二进制行必须解析")
        XCTAssertTrue(binary.isBinary, "-\\t- 必须标记为二进制")
        XCTAssertEqual(binary.path, "Assets/logo.png", "二进制行仍要取出路径")
        XCTAssertEqual(binary.additions + binary.deletions, 0, "二进制 churn 记 0")
        let header = [Fixture.shaC, "tcoder", "dev@tcoder.local", "2026-09-19T08:30:00+08:00", "feat: x"]
            .joined(separator: "\u{1F}")
        XCTAssertNil(GitLogParser.numstatLine(header), "含 \\u{1f} 的头部行不是 numstat 行")
        XCTAssertNil(GitLogParser.numstatLine("only-one-column"), "没有制表符返回 nil")
        XCTAssertNil(GitLogParser.numstatLine("1\t2"), "列数不足返回 nil")
        XCTAssertNil(GitLogParser.numstatLine(""), "空行返回 nil")
    }

    func testNumstatLineHandlesBothRenameForms() throws {
        let braced = try XCTUnwrap(GitLogParser.numstatLine("0\t0\tSources/App/{Alpha.swift => Beta.swift}"),
                                   "花括号重命名行必须解析")
        XCTAssertEqual(braced.path, "Sources/App/Beta.swift", "path 是新路径（含公共前缀）")
        XCTAssertEqual(braced.renameFrom, "Sources/App/Alpha.swift", "renameFrom 是旧路径（含公共前缀）")
        let whole = try XCTUnwrap(GitLogParser.numstatLine("0\t0\tOldName.txt => NewName.txt"),
                                  "整路径重命名行必须解析")
        XCTAssertEqual(whole.path, "NewName.txt", "path 是箭头右侧")
        XCTAssertEqual(whole.renameFrom, "OldName.txt", "renameFrom 是箭头左侧")
    }

    func testParseHandlesDirtyBlocksEmptyInputAndTrailingSeparators() {
        let dirty = [Fixture.shaC, "tcoder", "dev@tcoder.local"].joined(separator: "\u{1F}") + "\u{1E}\n"
        let good = Fixture.block(Fixture.shaA, iso: "2026-09-19T08:30:00+08:00", subject: "chore: 干净",
                                 rows: ["1\t0\tA.swift"])
        let commits = GitLogParser.parse(dirty + good)
        XCTAssertEqual(commits.count, 1, "字段数不足的脏块必须整体丢弃")
        XCTAssertEqual(commits[0].sha, Fixture.shaA, "干净块不得被脏块带偏")
        XCTAssertEqual(GitLogParser.parse(""), [], "空字符串解析成空数组")
        XCTAssertEqual(GitLogParser.parse("\n\n"), [], "只有换行解析成空数组")
        XCTAssertEqual(GitLogParser.parse("\u{1E}\n\u{1E}\n"), [], "只有分隔符解析成空数组")
        let trailing = GitLogParser.parse(Fixture.block(Fixture.shaA, iso: "2026-09-19T08:30:00+08:00",
                                                       subject: "chore: 空提交") + "\u{1E}")
        XCTAssertEqual(trailing.count, 1, "末尾多出的分隔符不得产生幽灵提交")
        XCTAssertEqual(trailing[0].filesChanged, 0, "无 numstat 行的提交 filesChanged 为 0")
    }
}

// MARK: - 契约 A：时区与邮箱归一

final class GitTimezoneTests: XCTestCase {

    func testParseAuthorTimestampSupportsSignedOffsets() {
        guard let east = GitLogParser.parseAuthorTimestamp("2026-09-19T08:30:00+08:00") else {
            return XCTFail("+08:00 形式必须解析成功")
        }
        XCTAssertEqual(east.offsetSeconds, 28_800, "偏移秒数必须带符号")
        XCTAssertEqual(east.date.timeIntervalSince1970, Fixture.sat0030UTC, accuracy: 0.5, "本地时刻折回 UTC 瞬间")
        guard let half = GitLogParser.parseAuthorTimestamp("2026-09-19T00:30:00-05:30") else {
            return XCTFail("-05:30 形式必须解析成功")
        }
        XCTAssertEqual(half.offsetSeconds, -19_800, "半小时负偏移必须支持")
        XCTAssertEqual(half.date.timeIntervalSince1970, 1_789_797_600, accuracy: 0.5, "-05:30 绝对时刻正确")
        let zulu = GitLogParser.parseAuthorTimestamp("2026-09-19T00:30:00Z")
        XCTAssertEqual(zulu?.offsetSeconds, 0, "Z 结尾当作 0 偏移")
        XCTAssertEqual(zulu?.date.timeIntervalSince1970 ?? -1, Fixture.sat0030UTC, accuracy: 0.5, "Z 瞬间正确")
        let zero = GitLogParser.parseAuthorTimestamp("2026-09-19T00:30:00+00:00")
        XCTAssertEqual(zero?.date.timeIntervalSince1970 ?? -1, Fixture.sat0030UTC, accuracy: 0.5, "+00:00 与 Z 等价")
        XCTAssertNil(GitLogParser.parseAuthorTimestamp("昨天下午"), "非 ISO8601 返回 nil")
        XCTAssertNil(GitLogParser.parseAuthorTimestamp(""), "空字符串返回 nil")
        XCTAssertNil(GitLogParser.parseAuthorTimestamp("2026-09-19"), "缺时间部分返回 nil")
    }

    func testLocalHourAndWeekdayFollowAuthorOffset() {
        let instant = Date(timeIntervalSince1970: Fixture.sat0030UTC)  // UTC 周六 00:30
        XCTAssertEqual(GitLogParser.localHour(of: instant, offsetSeconds: 0), 0, "Z 时区是 0 时")
        XCTAssertEqual(GitLogParser.localHour(of: instant, offsetSeconds: 28_800), 8, "+08:00 是 8 时")
        XCTAssertEqual(GitLogParser.localHour(of: instant, offsetSeconds: -18_000), 19, "-05:00 是前一天 19 时")
        XCTAssertEqual(GitLogParser.localHour(of: instant, offsetSeconds: 50_400), 14, "+14:00 是 14 时")
        let weekday = { GitLogParser.localWeekdayMondayFirst(of: instant, offsetSeconds: $0) }
        XCTAssertEqual(weekday(0), 5, "周六在 Monday-first 下索引 5")
        XCTAssertEqual(weekday(28_800), 5, "+08:00 仍是周六")
        XCTAssertEqual(weekday(-18_000), 4, "负偏移跨到前一天 -> 周五索引 4")
        XCTAssertEqual(weekday(50_400), 5, "+14:00 本地 14:30，仍是周六")
        let late = Date(timeIntervalSince1970: Fixture.sat0030UTC + 17 * 3_600)  // 周六 17:30Z
        XCTAssertEqual(GitLogParser.localHour(of: late, offsetSeconds: 50_400), 7, "+14:00 -> 次日 7 时")
        XCTAssertEqual(GitLogParser.localWeekdayMondayFirst(of: late, offsetSeconds: 50_400), 6,
                       "+14:00 跨到次日 -> 周日索引 6")
        let monday = Date(timeIntervalSince1970: Fixture.mondayUTC)
        XCTAssertEqual(GitLogParser.localWeekdayMondayFirst(of: monday, offsetSeconds: 0), 0, "周一必须是 0")
    }

    func testNormalizeEmailFoldsCaseAndGmailAlias() {
        XCTAssertEqual(GitLogParser.normalizeEmail("Dev@TCoder.Local"), "dev@tcoder.local", "邮箱整体小写化")
        XCTAssertEqual(GitLogParser.normalizeEmail("tcoder+wsbreview@gmail.com"), "tcoder@gmail.com",
                       "gmail 的 +alias 必须折叠")
        XCTAssertEqual(GitLogParser.normalizeEmail("tcoder@gmail.com"),
                       GitLogParser.normalizeEmail("TCoder+QA@GMAIL.com"), "同一人不同写法归一到同一 key")
    }
}

// MARK: - GitAggregation（已存在实现的回归保护）

final class GitAggregationTests: XCTestCase {

    /// c1 周一 01:00Z(+01:00)、c2 周二 02:00Z(+01:00)、c3 周三 00:01Z(-05:00，作者本地仍是周二)。
    private var commits: [ParsedCommit] {
        [
            Fixture.commit(sha: "c1", date: Fixture.utc(days: 0, seconds: 3_600), author: "张三",
                           email: "dev@tcoder.local", offset: 3_600, subject: "feat: 一",
                           changes: [Fixture.change("Sources/App/A.swift", additions: 10, deletions: 4),
                                     Fixture.change("docs/guide.md", additions: 2, deletions: 1)]),
            Fixture.commit(sha: "c2", date: Fixture.utc(days: 1, seconds: 7_200), author: "zhang san",
                           email: "Dev@TCoder.Local", offset: 3_600, subject: "feat: 二",
                           changes: [Fixture.change("Sources/App/A.swift", additions: 1, deletions: 1),
                                     Fixture.change("Sources/Views/B.swift", additions: 3),
                                     Fixture.change("scripts/run.sh", additions: 4, deletions: 2)]),
            Fixture.commit(sha: "c3", date: Fixture.utc(days: 2, seconds: 100), author: "李四",
                           email: "li.si@tcoder.local", offset: -18_000, subject: "fix: 三",
                           changes: [Fixture.change("Sources/Model/C.swift", additions: 5, deletions: 5),
                                     Fixture.change("README.md")]),
        ]
    }

    private func merged(_ stats: [AuthorStats]) throws -> AuthorStats {
        try XCTUnwrap(stats.first { $0.email == "dev@tcoder.local" }, "必须按归一化 email 归并出该作者")
    }

    func testAuthorStatsMergesByNormalizedEmail() throws {
        let stats = GitAggregation.authorStats(from: commits)
        XCTAssertEqual(GitAggregation.authorStats(from: []), [], "空输入返回空数组")
        XCTAssertEqual(stats.count, 2, "同 email（大小写不同、name 不同）必须合成 1 位作者")
        let author = try merged(stats)
        XCTAssertEqual(author.commits, 2, "该邮箱下 2 次提交")
        XCTAssertEqual(author.additions, 20, "additions 累加")
        XCTAssertEqual(author.deletions, 8, "deletions 累加")
        XCTAssertEqual(author.filesTouched, 4, "filesTouched 是不同文件数，重复文件只算一次")
        XCTAssertEqual(author.activityByHour.count, 24, "每位作者直方图长度 24")
        XCTAssertEqual(author.activityByHour.reduce(0, +), 2, "作者直方图之和等于其提交数")
        XCTAssertEqual(author.topDirectories.count, 3, "作者 topDirectories 只留前 3")
        XCTAssertEqual(author.topDirectories["Sources"], 3, "第一位目录计数正确")
        XCTAssertEqual(author.topDirectories.values.reduce(0, +), 5, "三位目录之和等于其变更条目数")
    }

    func testAuthorStatsTakesNameFromChronologicallyLastCommit() throws {
        let author = try merged(GitAggregation.authorStats(from: [commits[2], commits[0], commits[1]]))
        XCTAssertEqual(author.name, "zhang san", "name 取时间最晚那次，与数组顺序无关")
        let first = try XCTUnwrap(author.firstCommitAt, "firstCommitAt 必须有值")
        let last = try XCTUnwrap(author.lastCommitAt, "lastCommitAt 必须有值")
        XCTAssertEqual(first.timeIntervalSince1970, commits[0].date.timeIntervalSince1970, accuracy: 0.5,
                       "firstCommitAt 取最早一次")
        XCTAssertEqual(last.timeIntervalSince1970, commits[1].date.timeIntervalSince1970, accuracy: 0.5,
                       "lastCommitAt 取最晚一次")
    }

    func testActivityHistogramsLengthAndTotals() {
        let hours = GitAggregation.activityByHour(from: commits)
        XCTAssertEqual(hours.count, 24, "小时直方图固定 24 桶")
        XCTAssertEqual(hours.reduce(0, +), commits.count, "小时直方图之和等于提交数")
        XCTAssertEqual(hours[2], 1, "c1 是 01:00Z、作者 +01:00 -> 本地 2 时")
        XCTAssertEqual(hours[19], 1, "c3 是周三 00:01Z、作者 -05:00 -> 本地 19 时")
        let weekdays = GitAggregation.activityByWeekday(from: commits)
        XCTAssertEqual(weekdays.count, 7, "星期直方图固定 7 桶")
        XCTAssertEqual(weekdays.reduce(0, +), commits.count, "星期直方图之和等于提交数")
        XCTAssertEqual(weekdays[0], 1, "周一（索引 0）1 次提交")
        XCTAssertEqual(weekdays[1], 2, "c2 与 c3（按作者本地时区）都落在周二")
    }

    func testDistinctFileCountAndTopDirectories() {
        XCTAssertEqual(GitAggregation.distinctFileCount(from: commits), 6, "同一文件多次提交只算一次")
        XCTAssertEqual(GitAggregation.distinctFileCount(from: []), 0, "空输入返回 0")
        let top = GitAggregation.topDirectories(for: commits, limit: 3)
        XCTAssertEqual(top.count, 3, "只保留前 3 个目录")
        XCTAssertEqual(top["Sources"], 4, "Sources 下 4 个变更")
        XCTAssertEqual(top["docs"], 1, "docs 计数正确")
        XCTAssertEqual(top["(root)"], 1, "无斜杠的路径落到 (root)")
        XCTAssertNil(top["scripts"], "limit 之外的目录不得出现")
        XCTAssertEqual(GitAggregation.topDirectories(for: commits, limit: 0).count, 0, "limit <= 0 返回空字典")
        XCTAssertEqual(GitAggregation.topDirectories(for: [], limit: 3).count, 0, "空输入返回空字典")
    }

    func testGranularityThresholds() {
        let first = Fixture.utc(days: 0)
        XCTAssertEqual(GitAggregation.granularity(forFirst: first, last: Fixture.utc(days: 30)), .day, "30 天是 .day")
        XCTAssertEqual(GitAggregation.granularity(forFirst: first, last: Fixture.utc(days: 31)), .week, "31 天是 .week")
        XCTAssertEqual(GitAggregation.granularity(forFirst: first, last: Fixture.utc(days: 200)), .week, "200 天是 .week")
        XCTAssertEqual(GitAggregation.granularity(forFirst: first, last: Fixture.utc(days: 201)), .month, "201 天是 .month")
        XCTAssertEqual(GitAggregation.granularity(forFirst: nil, last: first), .day, "缺端点退回 .day")
        XCTAssertEqual(GitAggregation.granularity(forFirst: first, last: nil), .day, "缺端点退回 .day")
    }

    func testDayBucketsZeroFillAndAscendingOrder() {
        let buckets = GitAggregation.buckets(from: [commits[0], commits[2]], granularity: .day,
                                             calendar: GitAggregation.defaultCalendar())
        XCTAssertEqual(buckets.count, 3, "首尾之间的空必须补零桶")
        XCTAssertEqual(buckets[1].commits, 0, "中间那天提交数为 0")
        XCTAssertEqual(buckets[1].additions, 0, "零填充桶的 churn 也是 0")
        XCTAssertEqual(buckets[0].date.timeIntervalSince1970, Fixture.utc(days: 0).timeIntervalSince1970,
                       accuracy: 0.5, ".day 桶起点对齐当天零点")
        XCTAssertEqual(buckets[2].date.timeIntervalSince1970, Fixture.utc(days: 2).timeIntervalSince1970,
                       accuracy: 0.5, "最后一个桶是第三天")
        XCTAssertLessThan(buckets[0].date, buckets[1].date, "桶按时间升序")
        XCTAssertLessThan(buckets[1].date, buckets[2].date, "桶按时间升序")
        XCTAssertEqual(buckets[0].additions, 12, "桶内 additions 为该桶提交之和")
        XCTAssertEqual(buckets.map { $0.granularity }, Array(repeating: BucketGranularity.day, count: 3), "粒度回传")
        XCTAssertEqual(GitAggregation.buckets(from: [], granularity: .day,
                                             calendar: GitAggregation.defaultCalendar()), [], "空输入返回空数组")
    }

    func testRecentCommitsKeepsOrderAndCapsAtLimit() {
        let recent = GitAggregation.recentCommits(from: commits, limit: 2)
        XCTAssertEqual(recent.map { $0.sha }, ["c1", "c2"], "只取前 N 个且保持入参顺序")
        XCTAssertEqual(recent[0].subject, "feat: 一", "subject 原样映射")
        XCTAssertEqual(recent[0].email, "dev@tcoder.local", "email 原样映射（不归一化）")
        XCTAssertEqual(recent[0].filesChanged, 2, "filesChanged 取变更条目数")
        XCTAssertEqual(recent[0].additions, 12, "additions 求和")
        XCTAssertEqual(GitAggregation.recentCommits(from: commits, limit: 0).count, commits.count,
                       "limit <= 0 返回全部")
        XCTAssertEqual(GitAggregation.recentCommits(from: [], limit: 5), [], "空输入返回空数组")
    }
}

// MARK: - 契约 B：ManifestParsers

final class ManifestParserTests: XCTestCase {

    private func assertLock(_ ecosystem: DependencyEcosystem, _ listing: [String], _ expected: String?,
                            _ label: String) {
        XCTAssertEqual(ManifestParsers.lockfileName(for: ecosystem, in: Set(listing)), expected, label)
    }

    private func assertName(_ fileName: String, _ expected: DependencyEcosystem?, _ label: String) {
        XCTAssertEqual(ManifestFileName.ecosystem(for: fileName), expected, label)
    }

    func testPackageJSONScopesAndMalformedInput() {
        let deps = ManifestParsers.packageJSONDependencies(Fixture.pkgJSON, manifestPath: "package.json")
        XCTAssertEqual(Fixture.names(deps), ["react", "lodash", "vite", "fsevents"], "四个依赖都要抓到")
        XCTAssertEqual(Fixture.found(deps, "react")?.scope, .runtime, "dependencies 是运行时")
        XCTAssertEqual(Fixture.found(deps, "vite")?.scope, .dev, "devDependencies 是开发")
        XCTAssertTrue(Fixture.found(deps, "vite")?.isDevDependency == true, "isDevDependency 与 scope 一致")
        XCTAssertFalse(Fixture.found(deps, "fsevents")?.isDevDependency == true, "optional 不是开发依赖")
        XCTAssertTrue(Fixture.found(deps, "lodash")?.version.contains("4.17.15") == true, "版本号要抓到")
        XCTAssertEqual(deps.first?.ecosystem, .npm, "生态必须是 npm")
        XCTAssertEqual(ManifestParsers.packageJSONDependencies("{ not json", manifestPath: "package.json"), [],
                       "非法 JSON 返回空数组而不是崩溃")
        XCTAssertEqual(ManifestParsers.packageJSONDependencies("", manifestPath: "package.json"), [], "空文本返回空数组")
    }

    func testPomXMLSubstitutesPropertiesAndScope() {
        let deps = ManifestParsers.pomXMLDependencies(Fixture.pomXML, manifestPath: "pom.xml")
        XCTAssertEqual(Fixture.names(deps), ["org.springframework:spring-core", "com.google.guava:guava"],
                       "命名必须是 group:artifact")
        let spring = Fixture.found(deps, "org.springframework:spring-core")
        XCTAssertEqual(spring?.version, "5.3.30", "${spring.version} 必须被 properties 代入")
        XCTAssertEqual(spring?.scope, .test, "<scope>test</scope> 映射为测试")
        let guava = Fixture.found(deps, "com.google.guava:guava")
        XCTAssertEqual(guava?.version, "32.1.3-jre", "第二个属性也要代入")
        XCTAssertEqual(guava?.scope, .runtime, "无 scope 标签默认运行时")
        let paths = ManifestParsers.mavenModulePaths(in: Fixture.pomXML)
        XCTAssertEqual(Set(paths), ["api", "service-core"], "抽取两个 <module>")
        XCTAssertFalse(paths.contains { $0.isEmpty }, "不得产出空模块名")
        XCTAssertEqual(ManifestParsers.mavenModulePaths(in: "<project></project>"), [], "无 modules 返回空")
    }

    func testGradleBothStringSyntaxesAndTestConfiguration() {
        let deps = ManifestParsers.gradleDependencies("""
        dependencies {
            implementation 'com.google.guava:guava:33.0.0-jre'
            implementation("org.jetbrains.kotlin:kotlin-stdlib:1.9.20")
            testImplementation 'junit:junit:4.13.2'
        }
        """, manifestPath: "build.gradle")
        XCTAssertEqual(Fixture.names(deps), ["com.google.guava:guava", "org.jetbrains.kotlin:kotlin-stdlib",
                                             "junit:junit"], "单引号与括号两种形式都要解析")
        XCTAssertEqual(Fixture.found(deps, "com.google.guava:guava")?.version, "33.0.0-jre", "版本取第三段")
        XCTAssertEqual(Fixture.found(deps, "junit:junit")?.scope, .test, "testImplementation 是测试")
        XCTAssertEqual(Fixture.found(deps, "org.jetbrains.kotlin:kotlin-stdlib")?.scope, .runtime,
                       "implementation 是运行时")
        XCTAssertEqual(deps.first?.ecosystem, .gradle, "生态必须是 gradle")
    }

    func testSwiftPackageFromAndExactStripGitSuffix() {
        let deps = ManifestParsers.swiftPackageDependencies("""
        let package = Package(
            name: "TcoderKit",
            dependencies: [
                .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
                .package(url: "https://github.com/tcoder/Kit.git", exact: "2.0.0"),
            ]
        )
        """, manifestPath: "Package.swift")
        XCTAssertEqual(deps.count, 2, "两个 .package 都要抓到")
        XCTAssertTrue(deps.allSatisfy { !$0.name.hasSuffix(".git") }, "name 必须去掉 .git 后缀")
        XCTAssertTrue(deps.contains { $0.name.hasSuffix("swift-log") }, "第一个包名以 swift-log 结尾")
        XCTAssertTrue(deps.contains { $0.name.hasSuffix("Kit") }, "第二个包名以 Kit 结尾")
        XCTAssertTrue(deps.contains { $0.version.contains("1.5.0") }, "from: 语义版本要抓到")
        XCTAssertTrue(deps.contains { $0.version.contains("2.0.0") }, "exact: 语义版本要抓到")
        XCTAssertEqual(deps.first?.ecosystem, .swiftPM, "生态必须是 swiftPM")
    }

    func testRequirementsTxtSkipsCommentsAndReferences() {
        let deps = ManifestParsers.requirementsTxtDependencies("""
        # Tcoder 后端依赖
        flask==2.3.3
        requests>=2.31.0

        -r base.txt
        --index-url https://pypi.tcoder.local/simple
        """, manifestPath: "requirements.txt")
        XCTAssertEqual(Fixture.names(deps), ["flask", "requests"], "注释、空行、-r/--index-url 全部跳过")
        XCTAssertEqual(Fixture.found(deps, "flask")?.version, "2.3.3", "== 取精确版本")
        XCTAssertEqual(Fixture.found(deps, "requests")?.version, "2.31.0", ">= 取约束右侧版本")
        XCTAssertEqual(deps.first?.ecosystem, .python, "生态必须是 python")
    }

    func testGoModRequireBlock() {
        let deps = ManifestParsers.goModDependencies("""
        module tcoder.local/monitor
        go 1.22
        require (
        \tgithub.com/gin-gonic/gin v1.9.1
        \tgolang.org/x/net v0.17.0
        )
        """, manifestPath: "go.mod")
        XCTAssertEqual(Fixture.names(deps), ["github.com/gin-gonic/gin", "golang.org/x/net"],
                       "require 块内两条依赖都要抓到")
        XCTAssertTrue(Fixture.found(deps, "golang.org/x/net")?.version.hasSuffix("0.17.0") == true, "版本要解析出来")
        XCTAssertEqual(deps.first?.ecosystem, .go, "生态必须是 go")
    }

    func testCargoTomlThreeSections() {
        let deps = ManifestParsers.cargoTomlDependencies("""
        [package]
        name = "tcoder-monitor"
        [dependencies]
        serde = "1.0.190"
        [dev-dependencies]
        tempfile = "3.8.1"
        [build-dependencies]
        cc = "1.0.83"
        """, manifestPath: "Cargo.toml")
        XCTAssertEqual(Fixture.names(deps), ["serde", "tempfile", "cc"], "三个 section 都要解析")
        XCTAssertEqual(Fixture.found(deps, "serde")?.version, "1.0.190", "版本正确")
        XCTAssertEqual(Fixture.found(deps, "serde")?.scope, .runtime, "[dependencies] 是运行时")
        XCTAssertEqual(Fixture.found(deps, "tempfile")?.scope, .dev, "[dev-dependencies] 是开发")
        XCTAssertEqual(Fixture.found(deps, "cc")?.scope, .build, "[build-dependencies] 是构建")
        XCTAssertEqual(deps.first?.ecosystem, .cargo, "生态必须是 cargo")
    }

    func testLockfileNameDetectionForKnownLockfiles() {
        assertLock(.npm, ["package.json", "package-lock.json"], "package-lock.json", "npm 默认锁文件")
        assertLock(.npm, ["package.json", "yarn.lock"], "yarn.lock", "yarn 锁文件")
        assertLock(.npm, ["pnpm-lock.yaml", "package.json"], "pnpm-lock.yaml", "pnpm 锁文件")
        assertLock(.gradle, ["build.gradle", "gradle.lockfile"], "gradle.lockfile", "gradle 锁文件")
        assertLock(.cocoapods, ["Podfile", "Podfile.lock"], "Podfile.lock", "CocoaPods 锁文件")
        assertLock(.cargo, ["Cargo.toml", "Cargo.lock"], "Cargo.lock", "cargo 锁文件")
        assertLock(.go, ["go.mod", "go.sum"], "go.sum", "go 校验文件")
        assertLock(.npm, ["package.json"], nil, "无锁文件返回 nil")
    }

    func testFrameworkMarkersFromDependencyNames() {
        let web = ManifestParsers.frameworkMarkers(ecosystem: .npm, dependencyNames: ["react", "vite", "lodash"])
        XCTAssertTrue(web.contains("React"), "react 给出 React 标记")
        XCTAssertTrue(web.contains("Vite"), "vite 给出 Vite 标记")
        let server = ManifestParsers.frameworkMarkers(ecosystem: .maven, dependencyNames: [
            "org.springframework.boot:spring-boot-starter-web"])
        XCTAssertTrue(server.contains("Spring Boot"), "spring-boot-starter 给出 Spring Boot 标记")
        XCTAssertEqual(ManifestParsers.frameworkMarkers(ecosystem: .npm, dependencyNames: ["left-pad"]), [],
                       "无框架特征返回空数组")
    }

    func testManifestFileNameLookupAndFullSet() {
        assertName("package.json", .npm, "package.json -> npm")
        assertName("pom.xml", .maven, "pom.xml -> maven")
        assertName("build.gradle.kts", .gradle, "kts -> gradle")
        assertName("Package.swift", .swiftPM, "Package.swift -> swiftPM")
        assertName("requirements.txt", .python, "requirements -> python")
        assertName("go.mod", .go, "go.mod -> go")
        assertName("Cargo.toml", .cargo, "Cargo.toml -> cargo")
        assertName("Podfile", .cocoapods, "Podfile -> CocoaPods")
        assertName("README.md", nil, "未知文件名返回 nil")
        assertName("", nil, "空文件名返回 nil")
        for expected in ["package.json", "pom.xml", "build.gradle", "Package.swift", "go.mod", "Cargo.toml"] {
            XCTAssertTrue(ManifestFileName.allManifestNames.contains(expected), "清单名集合缺少 \(expected)")
        }
        XCTAssertFalse(ManifestFileName.allManifestNames.contains("README.md"), "集合不得混入非清单文件")
    }

    func testParseDispatchesByNameAndRejectsNonManifest() {
        let parsed = ManifestParsers.parse(text: Fixture.pkgJSON, manifestPath: "package.json",
                                           directoryRelativePath: "web",
                                           directoryListing: ["package.json", "yarn.lock"])
        guard let parsed else { return XCTFail("package.json 必须分派到 npm 解析器") }
        XCTAssertEqual(parsed.ecosystem, .npm, "生态由文件名决定")
        XCTAssertEqual(parsed.manifestRelativePath, "package.json", "清单相对路径原样回传")
        XCTAssertEqual(parsed.directoryRelativePath, "web", "目录相对路径原样回传")
        XCTAssertEqual(parsed.lockfileName, "yarn.lock", "锁文件由目录清单推出")
        XCTAssertTrue(parsed.frameworkMarkers.contains("React"), "框架标记要带上")
        XCTAssertEqual(parsed.dependencies.count, 4, "依赖数量正确")
        XCTAssertNil(ManifestParsers.parse(text: "hello", manifestPath: "notes.txt", directoryRelativePath: "",
                                           directoryListing: ["notes.txt"]), "非清单文件名返回 nil")
        XCTAssertNil(ManifestParsers.parse(text: "", manifestPath: "", directoryRelativePath: "",
                                           directoryListing: []), "空文件名返回 nil")
        let sub = ManifestParsers.parse(text: Fixture.pomXML, manifestPath: "backend/pom.xml",
                                        directoryRelativePath: "backend", directoryListing: ["pom.xml"])
        guard let sub else { return XCTFail("子目录里的 pom.xml 也要能解析") }
        XCTAssertEqual(sub.ecosystem, .maven, "生态必须是 maven")
        XCTAssertEqual(sub.directoryRelativePath, "backend", "子目录路径要保留")
        XCTAssertEqual(sub.dependencies.count, 2, "maven 依赖数正确")
    }
}

// MARK: - 契约 C：内置快照与离线漏洞

final class DependencySnapshotTests: XCTestCase {

    private func assertVulnerable(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String,
                                  _ label: String) {
        XCTAssertFalse(VulnerabilitySource.matches(ecosystem: ecosystem, name: name, version: version).isEmpty,
                       label)
    }

    private func assertClean(_ ecosystem: DependencyEcosystem, _ name: String, _ version: String,
                             _ label: String) {
        XCTAssertTrue(VulnerabilitySource.matches(ecosystem: ecosystem, name: name, version: version).isEmpty,
                      label)
    }

    private var vulnerableBatch: [DependencyRecord] {
        [Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json"),
         Fixture.record(name: "com.alibaba:fastjson", version: "1.2.68", ecosystem: .maven, manifest: "pom.xml"),
         Fixture.record(name: "org.apache.logging.log4j:log4j-core", version: "2.14.1", ecosystem: .maven,
                        manifest: "server/pom.xml"),
         Fixture.record(name: "axios", version: "0.21.1", manifest: "web/package.json")]
    }

    func testSnapshotMetadataAndLatestKnownVersion() throws {
        XCTAssertGreaterThan(DependencySnapshot.bundledEntryCount, 0, "内置快照不得为空")
        XCTAssertGreaterThan(DependencySnapshot.snapshotDate.timeIntervalSince1970, 1_600_000_000,
                             "快照日期必须晚于 2020 年")
        // 契约只要求「lodash 已收录、且最新已知版本不低于修复版 4.17.21」，不锁死具体小版本号。
        let lodash = try XCTUnwrap(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: "lodash"),
                                   "lodash 必须被内置快照收录")
        XCTAssertFalse(DependencyVersion.isOlder(current: lodash, than: "4.17.21"),
                       "lodash 的最新已知版本不得低于修复版 4.17.21")
        XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: "tcoder-not-real"),
                     "不存在的包返回 nil")
        XCTAssertNil(DependencySnapshot.latestKnownVersion(ecosystem: .npm, name: ""), "空包名返回 nil")
        let maven = DependencySnapshot.latestKnownVersion(ecosystem: .maven, name: "com.alibaba:fastjson")
        let gradle = DependencySnapshot.latestKnownVersion(ecosystem: .gradle, name: "com.alibaba:fastjson")
        XCTAssertNotNil(maven, "maven 坐标必须命中快照")
        XCTAssertEqual(gradle, maven, "gradle 与 maven 坐标互通")
    }

    func testMatchesRespectsFixVersionBoundary() throws {
        XCTAssertEqual(VulnerabilitySource.matches(ecosystem: .npm, name: "lodash", version: "4.17.15").count, 1,
                       "lodash 4.17.15 命中 1 条漏洞")
        assertClean(.npm, "lodash", "4.17.21", "lodash 4.17.21 是修复版本，不得命中")
        let hits = VulnerabilitySource.matches(ecosystem: .npm, name: "lodash", version: "4.17.15")
        let first = try XCTUnwrap(hits.first, "lodash 4.17.15 应有命中")
        XCTAssertTrue(first.affects(version: "4.17.20"), "受影响区间内为 true")
        XCTAssertFalse(first.affects(version: "4.17.21"), "修复版本本身为 false")
    }

    func testMatchesBoundariesAcrossEcosystems() {
        assertVulnerable(.maven, "com.alibaba:fastjson", "1.2.68", "fastjson 1.2.68 命中")
        assertVulnerable(.maven, "commons-collections:commons-collections", "3.2.1", "commons-collections 命中")
        assertVulnerable(.maven, "io.jsonwebtoken:jjwt", "0.9.1", "jjwt 0.9.1 命中")
        assertVulnerable(.maven, "org.apache.logging.log4j:log4j-core", "2.14.1", "log4j-core 2.14.1 命中")
        assertVulnerable(.npm, "axios", "0.21.1", "axios 0.21.1 命中")
        assertClean(.maven, "org.apache.logging.log4j:log4j-core", "2.20.0", "log4j-core 2.20.0 已修复")
        assertClean(.npm, "axios", "1.6.0", "新版 axios 不得命中")
        assertClean(.npm, "tcoder-not-real", "1.0.0", "不存在的包不得命中")
    }

    func testOfflineVulnerabilitiesAggregateAndCarryCVEIdentifiers() {
        let vulns = VulnerabilitySource.offlineVulnerabilities(for: vulnerableBatch)
        XCTAssertTrue(Set(["lodash", "com.alibaba:fastjson", "org.apache.logging.log4j:log4j-core", "axios"])
                        .isSubset(of: Set(vulns.map { $0.package })), "四个有漏洞的包都要出现")
        for vuln in vulns {
            XCTAssertFalse(vuln.cveIdentifiers.isEmpty, "\(vuln.package) 的 CVE 列表不得为空")
            XCTAssertTrue(vuln.cveIdentifiers.allSatisfy { $0.hasPrefix("CVE-") }, "\(vuln.package) 编号须为 CVE 格式")
            XCTAssertFalse(vuln.vulnerableRange.isEmpty, "\(vuln.package) 的区间描述不得为空")
            XCTAssertGreaterThan(vuln.severity.rank, RiskLevel.none.rank, "\(vuln.package) 级别不得是「无」")
        }
        let samePackage = VulnerabilitySource.offlineVulnerabilities(for: [
            Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json"),
            Fixture.record(name: "lodash", version: "4.17.20", manifest: "web/package.json"),
            Fixture.record(name: "lodash", version: "4.17.21", manifest: "app/package.json"),
        ])
        XCTAssertEqual(samePackage.count, 1, "同一包的多条命中聚合成 1 条")
        XCTAssertEqual(samePackage[0].package, "lodash", "包名正确")
        XCTAssertEqual(samePackage[0].ecosystem, .npm, "生态正确")
        XCTAssertEqual(samePackage[0].affectedDependencies.count, 2, "只有两个旧版本被计入")
        XCTAssertFalse(samePackage[0].affectedDependencies.contains { $0.isEmpty }, "受影响项不得为空串")
    }

    func testCleanInputProducesNoOfflineFindings() {
        let clean = [Fixture.record(name: "lodash", version: "4.17.21", manifest: "package.json"),
                     Fixture.record(name: "tcoder-not-real", version: "1.0.0", manifest: "package.json")]
        XCTAssertEqual(VulnerabilitySource.offlineVulnerabilities(for: clean), [], "干净依赖返回空数组")
        XCTAssertEqual(VulnerabilitySource.offlineVulnerabilities(for: []), [], "空输入返回空数组")
        XCTAssertEqual(VulnerabilitySource.bundledAdvisories(for: clean), [], "无漏洞时不得杜撰公告")
    }

    func testBundledAdvisoriesDescribeAffectedPackages() {
        let advisories = VulnerabilitySource.bundledAdvisories(
            for: [Fixture.record(name: "lodash", version: "4.17.15", manifest: "package.json")])
        XCTAssertFalse(advisories.isEmpty, "lodash 旧版本必须有公告")
        XCTAssertEqual(advisories[0].ecosystem, .npm, "公告生态正确")
        XCTAssertFalse(advisories[0].id.isEmpty, "公告 id 不得为空")
        XCTAssertFalse(advisories[0].summary.isEmpty, "公告标题不得为空")
        XCTAssertTrue(advisories[0].affectedPackages.contains { $0.contains("lodash") }, "受影响包含 lodash")
    }

    func testVersionIsOlderEdgeCases() {
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.0.0-SNAPSHOT", than: "1.0.0"), "-SNAPSHOT 后缀要截掉")
        XCTAssertTrue(DependencyVersion.isOlder(current: "^1.2.3", than: "1.2.4"), "^1.2.3 归一化为 0 视为落后")
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.2.3", than: "^1.2.4"), "latest 归一化为 0 时不得判落后")
        XCTAssertTrue(DependencyVersion.isOlder(current: "", than: "1.0.0"), "空串归一化为 [0]")
        XCTAssertTrue(DependencyVersion.isOlder(current: "abc", than: "1.0.0"), "纯字母归一化为 [0]")
        XCTAssertFalse(DependencyVersion.isOlder(current: "1.0.0.0.0.0.0", than: "1.0.0"), "多出的零段不得判落后")
        XCTAssertTrue(DependencyVersion.isOlder(current: "1.0.0.0.0.0.2", than: "1.0.0.0.0.0.3"), "超长段数逐位比较")
        XCTAssertEqual(DependencyVersion.normalize("2.0"), [2, 0], "normalize 行为冻结")
    }
}
