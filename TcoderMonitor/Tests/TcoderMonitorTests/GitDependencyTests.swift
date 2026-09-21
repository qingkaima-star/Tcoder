import XCTest
@testable import TcoderMonitor

// WS-B · 子代理5（测试）：Git 解析/聚合 + 依赖清单解析 + 内置漏洞快照的纯函数覆盖。
// 只依赖契约 A/B/C 与冻结模型；无网络、不 shell out、不读他人仓库。
// git 文本全是手写模拟输出，结构与真实
// `git log --pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e --numstat` 一致（已在 /tmp 自建临时仓库实测）。
// 所有 Date 由 timeIntervalSince1970 硬编码，不依赖本机时区。

// MARK: - 夹具

/// 两侧测试共用的夹具工厂。原为 fileprivate；把依赖侧拆进
/// DependencyAnalysisTests.swift 后改成模块内可见（本模块内唯一，不与
/// DepFixture / LogFixture / RepoFixture 撞名）。
enum Fixture {
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
    var commits: [ParsedCommit] {
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

    func merged(_ stats: [AuthorStats]) throws -> AuthorStats {
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
                                             calendar: GitAggregation.utcCalendar())
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
                                             calendar: GitAggregation.utcCalendar()), [], "空输入返回空数组")
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

// MARK: - 契约 D：仓库定位（ShellGitAnalyzer 的三级发现）
//
// 与上面几组不同，这一组会**真的 git init**：只在系统临时目录里给自己造私有夹具
// （`sandbox/<uuid>`，teardown 里删），绝不碰本机任何已有仓库，也不联网。
// 没装 Xcode 命令行工具时整组跳过而不是失败。
// macOS 上 `/var`、`/tmp` 都是符号链接，所以路径断言一律两边先过 `canonicalPath`。

enum RepoFixture {
    @discardableResult
    static func git(_ arguments: [String], at url: URL) throws -> String {
        let result = Shell.blockingRun("git", arguments: arguments, workingDirectory: url, timeout: 20)
        guard result.succeeded else {
            throw NSError(domain: "RepoFixture", code: Int(result.exitCode), userInfo: [
                NSLocalizedDescriptionKey: "git \(arguments.joined(separator: " ")) 失败：\(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
            ])
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 造一个有 `commits` 个提交的仓库；`subdir` 决定提交文件落在仓库内的哪个子目录。
    @discardableResult
    static func makeRepository(at url: URL, commits: Int, in subdir: String? = nil) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        _ = try git(["init", "-q"], at: url)
        _ = try git(["config", "user.email", "bot@tcoder.local"], at: url)
        _ = try git(["config", "user.name", "Tcoder Test"], at: url)
        _ = try git(["config", "commit.gpgsign", "false"], at: url)
        let workspace = subdir.map { url.appendingPathComponent($0, isDirectory: true) } ?? url
        try fm.createDirectory(at: workspace, withIntermediateDirectories: true)
        for index in 0..<max(commits, 0) {
            try "tcoder line \(index)\n".write(to: workspace.appendingPathComponent("file\(index).txt"),
                                              atomically: true, encoding: .utf8)
            _ = try git(["add", "-A"], at: url)
            _ = try git(["commit", "-q", "--no-verify", "-m", "TCoder 提交 \(index)"], at: url)
        }
        return url
    }
}

// 已按类各拆一个文件（WS-X3 TestSplit，用例本体一字未改）：
// `GitRepositoryDiscoveryTests.swift`（仓库根发现）、`GitHistoryTruncationTests.swift`（窗口截断计数矩阵）。
