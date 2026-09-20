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

private enum RepoFixture {
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

final class GitRepositoryDiscoveryTests: XCTestCase {
    private var sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    override func setUpWithError() throws {
        try XCTSkipIf(!Shell.isAvailable("git"), "未找到 git 可执行文件，跳过仓库定位测试")
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-wsb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.sandbox) }
    }

    private func canonical(_ url: URL) -> String { ShellGitAnalyzer.canonicalPath(url.path) }

    // MARK: ① 所选目录即仓库

    func testSelectedDirectoryIsItselfTheRepository() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("plainRepo"), commits: 3)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: repo)

        XCTAssertEqual(insights.discoveryMode, .selectedDirectory, "自身就是仓库时模式必须是 selectedDirectory")
        XCTAssertEqual(insights.discoveryHops, 0, "自身就是仓库时不跳层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(repo), "解析出的根就是所选目录")
        XCTAssertEqual(insights.totalCommits, 3, "3 个提交要如实统计")
        XCTAssertTrue(insights.nestedCandidates.isEmpty, "自身是仓库时不该报嵌套候选")
        XCTAssertTrue(insights.isRepository)
    }

    // MARK: ② 向上找父仓库

    func testSelectingASubdirectoryWalksUpToTheParentRepository() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("upRepo"),
                                                 commits: 2, in: "Sources/App")
        let deep = repo.appendingPathComponent("Sources/App", isDirectory: true)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: deep)

        XCTAssertEqual(insights.discoveryMode, .parentDirectory, "选了仓库内部的子目录要归到父仓库")
        XCTAssertEqual(insights.discoveryHops, 2, "Sources/App 距仓库根是向上 2 层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(repo), "解析出的根必须是仓库根而不是所选子目录")
        XCTAssertEqual(insights.totalCommits, 2, "沿父链找到的仓库要能被完整分析")
    }

    func testSelectingTheGitMetadataDirectoryClimbsOneLevel() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("metaRepo"), commits: 1)
        let dotGit = repo.appendingPathComponent(".git", isDirectory: true)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: dotGit)

        // git 在 .git 里直接拒绝判定 work tree，这条路径由「逐级向上」兜住。
        XCTAssertEqual(insights.discoveryMode, .parentDirectory, "选中 .git 目录时要向上回退到仓库根")
        XCTAssertEqual(insights.discoveryHops, 1, "从 .git 向上恰好 1 层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(repo), "不能把 .git 本身当仓库根")
    }

    // MARK: ③ 向下找子仓库

    func testNestedRepositoriesPickTheBiggestAndListEveryCandidate() async throws {
        let workspace = sandbox.appendingPathComponent("workspace", isDirectory: true)
        let big = try RepoFixture.makeRepository(at: workspace.appendingPathComponent("bigRepo"), commits: 4)
        let small = try RepoFixture.makeRepository(at: workspace.appendingPathComponent("smallRepo"), commits: 1)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("notARepo"),
                                               withIntermediateDirectories: true)

        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: workspace)

        XCTAssertEqual(insights.discoveryMode, .nestedSubdirectory, "所选目录不是仓库、下面躺着仓库时要往下找")
        XCTAssertEqual(insights.discoveryHops, 1, "候选仓库在所选目录下 1 层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(big), "必须选提交数最多的那个仓作为分析对象")
        XCTAssertEqual(insights.totalCommits, 4, "分析对象是 bigRepo 的 4 个提交")
        XCTAssertEqual(insights.nestedCandidates.count, 2, "两个候选都要上报，不能只报被选中的")
        let counts = insights.nestedCandidates.map(\.commitCount)
        XCTAssertEqual(counts, [4, 1], "候选按提交数降序排列")
        XCTAssertEqual(insights.nestedCandidates.map(\.path), [canonical(big), canonical(small)],
                       "上报的候选路径必须就是那两个仓库，且首位是被选中的大仓")
        XCTAssertEqual(insights.nestedCandidates.first?.directoryName, "bigRepo")
        XCTAssertEqual(insights.nestedCandidates.last?.directoryName, "smallRepo")
        XCTAssertNotNil(insights.nestedCandidates.first?.lastCommitAt, "候选要带最近提交时间")
        XCTAssertFalse(insights.nestedCandidates.first?.branch.isEmpty ?? true, "候选要带分支名")
    }

    func testNestedCandidateBeyondDepthLimitIsNotDiscovered() async throws {
        // maxNestedDepth = 3：仓库放在 deep/a/b/c/d 之下（第 5 层）应该找不到。
        let outer = sandbox.appendingPathComponent("deep/a/b/c/d", isDirectory: true)
        _ = try RepoFixture.makeRepository(at: outer.appendingPathComponent("lateRepo"), commits: 2)
        let root = sandbox.appendingPathComponent("deep", isDirectory: true)

        do {
            _ = try await ShellGitAnalyzer().analyze(repositoryURL: root)
            XCTFail("超出向下扫描深度的仓库不应被当成候选")
        } catch let error as AnalysisError {
            guard case .notGitRepository(let detail) = error else {
                return XCTFail("应抛 notGitRepository，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("向下最多 3 层"), "错误信息要说清试过向下几层，实际：\(detail)")
            XCTAssertTrue(detail.contains("向上最多 6 层"), "错误信息要说清试过向上几层，实际：\(detail)")
        }
    }

    // MARK: ④ 全落空

    func testPlainDirectoryThrowsAndListsTriedLocations() async throws {
        let plain = sandbox.appendingPathComponent("plainDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        do {
            _ = try await ShellGitAnalyzer().analyze(repositoryURL: plain)
            XCTFail("非仓库目录必须抛错，不能返回空对象冒充成功")
        } catch let error as AnalysisError {
            guard case .notGitRepository(let detail) = error else {
                return XCTFail("应抛 notGitRepository，实际 \(error)")
            }
            XCTAssertTrue(detail.contains(ShellGitAnalyzer.canonicalPath(plain.path).components(separatedBy: "/").last ?? ""),
                          "错误信息里要带上被选的目录名，实际：\(detail)")
        }
    }

    // MARK: 纯函数件

    func testMakeInsightsStampsDiscoveryFields() throws {
        var candidates: [NestedRepositoryCandidate] = []
        candidates.append(NestedRepositoryCandidate(path: "/ws/big", branch: "main", commitCount: 4, lastCommitAt: nil))
        candidates.append(NestedRepositoryCandidate(path: "/ws/small", branch: "dev", commitCount: 1, lastCommitAt: nil))
        let resolution = ShellGitAnalyzer.RepositoryResolution(selectedPath: "/ws", rootPath: "/ws/big",
                                                              mode: .nestedSubdirectory, hops: 1,
                                                              nestedCandidates: candidates)
        let insights = ShellGitAnalyzer.makeInsights(commits: [], branch: "main", headSHA: "abc1234",
                                                    remoteURL: "", resolution: resolution)
        XCTAssertEqual(insights.discoveryMode, .nestedSubdirectory)
        XCTAssertEqual(insights.discoveryHops, 1)
        XCTAssertEqual(insights.resolvedRepositoryRoot, "/ws/big")
        XCTAssertEqual(insights.nestedCandidates.count, 2)
        XCTAssertTrue(insights.isRepository, "定位成功即视为仓库，即使 0 提交")

        let legacy = ShellGitAnalyzer.makeInsights(commits: [], branch: "", headSHA: "", remoteURL: "")
        XCTAssertEqual(legacy.discoveryMode, .none, "不传定位结果时保持模型默认值")
        XCTAssertNil(legacy.resolvedRepositoryRoot)
    }

    func testUpwardHopsAndParentChainArithmetic() {
        XCTAssertEqual(ShellGitAnalyzer.upwardHops(fromRoot: "/a/b", to: "/a/b"), 0, "相等记 0 跳")
        XCTAssertEqual(ShellGitAnalyzer.upwardHops(fromRoot: "/a/b", to: "/a/b/c/d"), 2, "两层子目录")
        XCTAssertNil(ShellGitAnalyzer.upwardHops(fromRoot: "/a/b", to: "/a/bc"), "前缀相同但不是父目录")
        XCTAssertNil(ShellGitAnalyzer.upwardHops(fromRoot: "/x/y", to: "/a/b"), "完全不相干")

        let chain = ShellGitAnalyzer.parentChain(of: "/a/b/c/d/e/f/g", limit: 6) { _, _ in true }
        XCTAssertEqual(chain.count, 6, "严格受 limit 限制")
        XCTAssertEqual(chain.first, "/a/b/c/d/e/f", "由近及远")
        XCTAssertEqual(chain.last, "/a", "第 6 层正好停在 /a")

        let cut = ShellGitAnalyzer.parentChain(of: "/x/y/z/w", limit: 5) { parent, _ in parent != "/x" }
        XCTAssertEqual(cut, ["/x/y/z", "/x/y"], "跨挂载点必须停止上溯")
    }

    func testCanonicalPathFoldsSymlinksAndTrailingSlash() throws {
        XCTAssertEqual(ShellGitAnalyzer.canonicalPath("/tmp/"), ShellGitAnalyzer.canonicalPath("/tmp"),
                       "尾随斜杠不得影响可比性")
        XCTAssertEqual(ShellGitAnalyzer.canonicalPath("/tmp"), ShellGitAnalyzer.canonicalPath("/private/tmp"),
                       "/tmp 与 /private/tmp 是同一个目录，必须归一")
        XCTAssertEqual(ShellGitAnalyzer.canonicalPath(sandbox.path + "/"),
                       ShellGitAnalyzer.canonicalPath(sandbox.path), "临时目录自身也要归一")
        XCTAssertFalse(ShellGitAnalyzer.canonicalPath(sandbox.path).hasSuffix("/"), "产出不能带尾随斜杠")
    }

    func testPickPrimaryCandidateOrderingIsDeterministic() {
        func candidate(_ path: String, _ count: Int) -> NestedRepositoryCandidate {
            NestedRepositoryCandidate(path: path, branch: "main", commitCount: count, lastCommitAt: nil)
        }
        let entries: [(candidate: NestedRepositoryCandidate, depth: Int)] = [
            (candidate("/ws/a", 2), 1), (candidate("/ws/b", 7), 2), (candidate("/ws/c", 7), 1),
        ]
        XCTAssertEqual(ShellGitAnalyzer.pickPrimaryCandidate(entries)?.candidate.path, "/ws/c",
                     "先比提交数，并列取更浅的一层")
        let tied: [(candidate: NestedRepositoryCandidate, depth: Int)] = [
            (candidate("/ws/z", 3), 1), (candidate("/ws/a", 3), 1),
        ]
        XCTAssertEqual(ShellGitAnalyzer.pickPrimaryCandidate(tied)?.candidate.path, "/ws/a",
                     "再并列按路径字典序，结果必须可复现")
        XCTAssertNil(ShellGitAnalyzer.pickPrimaryCandidate([]), "空候选返回 nil")
    }

    func testAttemptedLocationsTextMentionsBothDirections() {
        let text = ShellGitAnalyzer.attemptedLocationsText(upward: 6, nested: 3)
        XCTAssertTrue(text.contains("自身"), "要说清试过所选目录自身")
        XCTAssertTrue(text.contains("向上最多 6 层"))
        XCTAssertTrue(text.contains("向下最多 3 层"))
    }
}

// MARK: - 契约 E：历史窗口截断的诚实报数
//
// totalCommits 是仓库真值（含 merge），commitsAnalyzed 只是被 `-n 窗口` 截断后实际解析的
// 非合并提交数。两者不等就必须置 historyTruncated，UI 才有机会声明「以下统计只是窗口」。
// 说明：规格建议「造超过 maxCommits 的仓」，但 20,001 次 `git commit --allow-empty` 要 6~7 分钟，
// 不适合放单测；这里把窗口上限做成可注入参数（`init(commitWindowLimit:)`），
// 用 12 个提交 + 上限 5 走完全相同的代码路径；真实的 2 万条上限由 Homebrew 压测覆盖（见工作日志）。

final class GitHistoryTruncationTests: XCTestCase {
    private var sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    override func setUpWithError() throws {
        try XCTSkipIf(!Shell.isAvailable("git"), "未找到 git 可执行文件，跳过窗口截断测试")
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-wsb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.sandbox) }
    }

    func testWindowSmallerThanHistoryReportsTrueTotal() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("twelve"), commits: 12)
        let insights = try await ShellGitAnalyzer(commitWindowLimit: 5).analyze(repositoryURL: repo)

        XCTAssertEqual(insights.totalCommits, 12, "总数必须是仓库真值，不能是被截断的 5")
        XCTAssertEqual(insights.commitsAnalyzed, 5, "窗口只解析了 5 条")
        XCTAssertTrue(insights.historyTruncated, " analyzed < total 必须标记截断")
        XCTAssertLessThan(insights.commitsAnalyzed, insights.totalCommits)
        XCTAssertEqual(insights.recentCommits.count, 5, "最近提交列表也来自同一个窗口")
    }

    func testWindowCoveringWholeHistoryIsNotTruncated() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("three"), commits: 3)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: repo)

        XCTAssertEqual(insights.totalCommits, 3, "默认上限下小仓库总数就是真值")
        XCTAssertEqual(insights.commitsAnalyzed, 3, "三条全部解析到了")
        XCTAssertFalse(insights.historyTruncated, "窗口盖住全部历史时不得虚报截断")
    }

    func testMergeCommitsWidenGapBetweenTotalAndWindow() async throws {
        let root = sandbox.appendingPathComponent("mergeRepo")
        _ = try RepoFixture.makeRepository(at: root, commits: 1)
        _ = try RepoFixture.git(["checkout", "-q", "-b", "feature"], at: root)
        try "feature\n".write(to: root.appendingPathComponent("feat.txt"), atomically: true, encoding: .utf8)
        _ = try RepoFixture.git(["add", "-A"], at: root)
        _ = try RepoFixture.git(["commit", "-q", "--no-verify", "-m", "分支上的提交"], at: root)
        _ = try RepoFixture.git(["checkout", "-q", "-"], at: root)
        _ = try RepoFixture.git(["merge", "--no-ff", "-q", "feature", "-m", "合并 feature"], at: root)

        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: root)
        XCTAssertEqual(insights.totalCommits, 3, "真值含合并：主干 + 分支 + merge 共 3 条")
        XCTAssertEqual(insights.commitsAnalyzed, 2, "--no-merges 窗口只有 2 条")
        XCTAssertTrue(insights.historyTruncated,
                      "按约定 analyzed < total 即算截断（merge 提交也计入这个差额）")
    }

    func testMakeInsightsCountMatrix() {
        let made = ShellGitAnalyzer.makeInsights(commits: threeCommits(), branch: "main",
                                                headSHA: "abc1234", remoteURL: "", fullCommitCount: 50)
        XCTAssertEqual(made.commitsAnalyzed, 3, "解析到几条就报几条")
        XCTAssertEqual(made.totalCommits, 50, "总数取 rev-list 真值")
        XCTAssertTrue(made.historyTruncated, "3 < 50 必须标记截断")

        let uncut = ShellGitAnalyzer.makeInsights(commits: threeCommits(), branch: "main",
                                                 headSHA: "abc1234", remoteURL: "", fullCommitCount: 3)
        XCTAssertEqual(uncut.totalCommits, 3)
        XCTAssertFalse(uncut.historyTruncated, "窗口盖住全部历史时不得虚报截断")

        let legacy = ShellGitAnalyzer.makeInsights(commits: threeCommits(), branch: "main",
                                                  headSHA: "abc1234", remoteURL: "", fullCommitCount: nil)
        XCTAssertEqual(legacy.totalCommits, 3, "取不到真值时退回窗口条数，不编造")
        XCTAssertFalse(legacy.historyTruncated)

        // 两条命令之间有人又提交了（真值反而小于已解析条数）时，总数不得倒退
        let raced = ShellGitAnalyzer.makeInsights(commits: threeCommits(), branch: "main",
                                                 headSHA: "abc1234", remoteURL: "", fullCommitCount: 1)
        XCTAssertEqual(raced.totalCommits, 3, "总数不得小于已解析条数")
        XCTAssertFalse(raced.historyTruncated)
    }

    private func threeCommits() -> [ParsedCommit] {
        let shas = [Fixture.shaA, Fixture.shaB, Fixture.shaC]
        return shas.enumerated().map { index, sha in
            Fixture.commit(sha: sha, date: Fixture.utc(days: index),
                           changes: [Fixture.change("Sources/TCoder/f\(index).swift")])
        }
    }
}
