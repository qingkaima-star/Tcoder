import XCTest
@testable import TcoderMonitor

/// OWNER: WS-T（Git 时间口径）。缺陷 #42 的守卫：**按日/周/月分桶必须按提交者当地时区切，
/// 不许再用 UTC 切桶却用本地贴标签。**
///
/// 实测过的坏样子（main `9757722` 上，总工实拍 + 复算）：界面「提交趋势」写
/// 「按 日 分桶 · 共 1 桶 · 峰值桶 152 · 9月19日 → 9月19日」，
/// 而 `TZ=Asia/Shanghai git log --no-merges --date=format-local:'%Y-%m-%d' | uniq -c`
/// 给的是 `96 2026-09-19` + `56 2026-09-20`；按 UTC 日复算恰好是 `152 2026-09-19`。
///
/// 每条守卫都配了**双向断言**：既造"该被拆开"的输入，也造"不该被拆开"的输入，
/// 否则守卫会退化成单向的永真绿。分母一律显式断言非 0（防"假零"）。
final class GitTimeSemanticsTests: XCTestCase {

    // MARK: - 夹具（刻意自带一份锚点，不复用 GitDependencyTests.Fixture：
    // 两处共享常量时，常量被改坏会两边一起瞎）

    /// 2026-09-14 是周一，其 UTC 零点。
    static let mondayUTC: TimeInterval = 1_789_344_000
    static let eastEight = 28_800
    static let westFive = -18_000

    /// 造一条「作者**当地** 第 `localDays` 天（0 = 2026-09-14 周一）凌晨 `localHour` 点」的提交。
    /// 绝对时刻 = 当地瞬间 - 作者偏移，与 `GitLogParser.parseAuthorTimestamp` 同一套算法。
    func commit(_ sha: String, localDays: Int, localHour: Int, offset: Int) -> ParsedCommit {
        let localInstant = Self.mondayUTC + Double(localDays * 86_400 + localHour * 3_600)
        return ParsedCommit(sha: sha, authorName: "ws-t", authorEmail: "ws-t@tcoder.local",
                            date: Date(timeIntervalSince1970: localInstant - Double(offset)),
                            authorOffsetSeconds: offset, subject: "chore: \(sha)", changes: [])
    }

    /// 独立算「作者当地的日零点」对应的绝对瞬间：平移到当地 → 向下取整到整天 → 平移回去。
    func localDayStart(_ date: Date, offset: Int) -> TimeInterval {
        (floor((date.timeIntervalSince1970 + Double(offset)) / 86_400) * 86_400) - Double(offset)
    }

    func counts(_ buckets: [CommitBucket]) -> [Int] { buckets.map(\.commits) }

    // MARK: - ① 同一 UTC 日、不同当地日：必须拆成两个桶

    /// 任务点名的那对夹具：`23:00 +08:00` 与 `02:00 +08:00`。
    /// 两者的 UTC 瞬间都落在 2026-09-19（15:00Z 与 18:00Z），但**提交者当地是两天**。
    func testSameUTCMDifferentAuthorLocalDaysGetTwoBuckets() {
        let pair = [commit("c1", localDays: 5, localHour: 23, offset: Self.eastEight),
                    commit("c2", localDays: 6, localHour: 2, offset: Self.eastEight)]

        // 先证明这对输入**确实**是"同一 UTC 日"——否则本条会退化成一句空话。
        let utcBuckets = GitAggregation.buckets(from: pair, granularity: .day,
                                                calendar: GitAggregation.utcCalendar())
        XCTAssertEqual(utcBuckets.count, 1, "反面证据：旧口径（UTC 切桶）把两天并成一桶")
        XCTAssertEqual(counts(utcBuckets), [2], "旧口径的 2 全塞在一个桶里，这就是界面上那个『共 1 桶』")

        // 修好之后：按提交者当地切，两个桶。
        let local = GitAggregation.buckets(from: pair, granularity: .day,
                                           calendar: GitAggregation.authorCalendar(for: pair))
        XCTAssertEqual(counts(local), [1, 1], "当地口径必须切成 1 + 1，实得 \(counts(local))")
        XCTAssertFalse(local.isEmpty, "分母为 0 就是假零，本条判失败")
        XCTAssertEqual(local.reduce(0) { $0 + $1.commits }, pair.count, "分桶之和必须等于提交数")
        XCTAssertEqual(local[0].date.timeIntervalSince1970,
                       localDayStart(pair[0].date, offset: Self.eastEight), accuracy: 0.5,
                       "第一个桶起点 = 提交者当地那天零点")
        XCTAssertEqual(local[1].date.timeIntervalSince1970,
                       localDayStart(pair[1].date, offset: Self.eastEight), accuracy: 0.5,
                       "第二个桶起点 = 次当地日零点")
        XCTAssertLessThan(local[0].date, local[1].date, "桶必须升序")
    }

    /// 反向（好例必须放过）：同一当地日的两次提交，哪怕相隔 13 小时、跨了 UTC 正午，也只能一个桶。
    func testSameAuthorLocalDayStaysInOneBucket() {
        let pair = [commit("d1", localDays: 5, localHour: 9, offset: Self.eastEight),
                    commit("d2", localDays: 5, localHour: 22, offset: Self.eastEight)]
        let local = GitAggregation.buckets(from: pair, granularity: .day,
                                           calendar: GitAggregation.authorCalendar(for: pair))
        XCTAssertEqual(counts(local), [2], "同当地日不得被拆开，实得 \(counts(local))")
        guard local.count == 1 else { return XCTFail("分母不是 1 就是假零，实得 \(counts(local))") }
        XCTAssertEqual(local[0].date.timeIntervalSince1970,
                       localDayStart(pair[0].date, offset: Self.eastEight), accuracy: 0.5,
                       "桶起点仍是那天零点")
    }

    // MARK: - ② 生产接线：分析器自己必须走当地口径

    // MARK: - ③ 周桶 / 月桶同一条尺子

    // MARK: - ④ 补空桶 / 去重 / 120 上限这些既有语义一个都不许变

    // MARK: - ⑤ 主导作者偏移的选取：可复现、且不许有人从趋势里掉出去

    // MARK: - ⑥ 真实仓库对照（env 门控）与其元测试

    /// 把工具桶与 git 真值逐日对账：两边都是 `[YYYY-MM-DD -> 条数]`。
    /// 返回 nil = 完全一致；**任何一边为空都返回差异说明**，因为"谁都没数到"不是"数得一样"。
    /// 门控测试与下面的元测试**共用这一个函数**，所以门控被跳过时这把尺子仍在被无条件检验。
    func diffAgainstTruth(tool: [String: Int], truth: [String: Int]) -> String? {
        guard !truth.isEmpty else { return "git 真值为空，取数失败（不得当成一致）" }
        guard !tool.isEmpty else { return "工具分桶为空，一天都没切出来" }
        var diffs: [String] = []
        for key in Set(tool.keys).union(truth.keys).sorted() {
            let t = truth[key] ?? 0, g = tool[key] ?? 0
            if t != g { diffs.append("\(key): 工具 \(g) / git \(t)") }
        }
        return diffs.isEmpty ? nil : diffs.joined(separator: "、")
    }

    /// 元测试：那把对账尺子必须**双向**有效——坏例抓到、好例放过、空输入判失败。
    /// 没有这条，`TCODER_GIT_TIME` 不设时那个真实仓库门就是一次都没跑过的摆设。
    func testTruthComparatorCatchesBadAndPassesGood() {
        let truth = ["2026-09-19": 96, "2026-09-20": 56]
        XCTAssertNil(diffAgainstTruth(tool: truth, truth: truth), "同一批数必须判为一致（好例放过）")

        // 坏例 1：旧口径的「152 全压在 9-19」——正是缺陷 #42 的实测形状。
        let utcShaped = diffAgainstTruth(tool: ["2026-09-19": 152], truth: truth)
        XCTAssertNotNil(utcShaped, "UTC 分桶必须被这把尺子抓到")
        XCTAssertTrue(utcShaped!.contains("2026-09-20"), "差异必须点名缺失那天：\(utcShaped!)")

        // 坏例 2：整体平移一天（桶边界差 8 小时的典型症状）。
        XCTAssertNotNil(diffAgainstTruth(tool: ["2026-09-18": 96, "2026-09-19": 56], truth: truth),
                        "平移一天的桶必须被抓到")
        // 坏例 3：总数对得上但少切一天。
        XCTAssertNotNil(diffAgainstTruth(tool: ["2026-09-19": 152, "2026-09-20": 0], truth: truth))

        // 假零防线：两边都空 / 真值空 / 工具空，一律不得返回 nil（"一致"）。
        XCTAssertNotNil(diffAgainstTruth(tool: [:], truth: [:]), "两边都没有数，判失败")
        XCTAssertNotNil(diffAgainstTruth(tool: truth, truth: [:]), "真值取空了，判失败")
        XCTAssertNotNil(diffAgainstTruth(tool: [:], truth: truth), "工具没切出桶，判失败")
    }

    /// 元测试：我自己那把「绝对瞬间 -> 当地日历日」的独立尺子也得有真值。
    /// 它在门控关掉时也必须跑——否则真实仓库门用的就是一把从没对过表的尺子。
    func testIndependentCivilDayRulerIsCorrect() {
        XCTAssertEqual(civilDay(Date(timeIntervalSince1970: 0), offsetSeconds: 0), "1970-01-01")
        XCTAssertEqual(civilDay(Date(timeIntervalSince1970: Self.mondayUTC), offsetSeconds: 0), "2026-09-14")
        // 2026-09-19T16:00Z：UTC 还是 19 日，+08:00 已经是 20 日凌晨。
        let shifted = Date(timeIntervalSince1970: Self.mondayUTC + 5 * 86_400 + 16 * 3_600)
        XCTAssertEqual(civilDay(shifted, offsetSeconds: 0), "2026-09-19")
        XCTAssertEqual(civilDay(shifted, offsetSeconds: Self.eastEight), "2026-09-20")
        // 跨年边界：2027-01-01 与闰年 2028-02-29（epoch 秒已用 `datetime.utcfromtimestamp` 核过）。
        XCTAssertEqual(civilDay(Date(timeIntervalSince1970: 1_798_761_600), offsetSeconds: 0), "2027-01-01")
        XCTAssertEqual(civilDay(Date(timeIntervalSince1970: 1_835_395_200), offsetSeconds: 0), "2028-02-29")
        XCTAssertEqual(civilDay(Date(timeIntervalSince1970: 1_835_481_600), offsetSeconds: 0), "2028-03-01")
    }

    /// 门控测试用到的时间戳小工具也必须有真值——否则等门控真跑起来才发现自己解析错。
    func testGitTimestampParsersHaveKnownValues() throws {
        XCTAssertEqual(try offsetSeconds(fromAuthorISO: "2026-09-19T17:07:54+08:00"), 28_800)
        XCTAssertEqual(try offsetSeconds(fromAuthorISO: "2026-09-19T17:07:54+0800"), 28_800)
        XCTAssertEqual(try offsetSeconds(fromAuthorISO: "2026-09-19T17:07:54-05:30"), -19_800)
        XCTAssertEqual(try offsetSeconds(fromAuthorISO: "2026-09-19T17:07:54Z"), 0)
        XCTAssertThrowsError(try offsetSeconds(fromAuthorISO: "2026-09-19T17:07:54"), "没有偏移必须报错")
        XCTAssertThrowsError(try offsetSeconds(fromAuthorISO: "昨天下午"), "非 ISO 串必须报错")
    }

    /// 真实仓库级对照：跑本工作树，工具的分桶必须逐日等于
    /// `git log --no-merges --pretty=%ad --date=short`（git 按**每条提交自己的作者时区**给的日号）。
    /// 开法：`TCODER_GIT_TIME=1 ./scripts/locked_build.sh test`
    func testRealRepositoryBucketsMatchGitGroundTruth() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TCODER_GIT_TIME"] == "1",
                          "真实仓库对照需显式开启：TCODER_GIT_TIME=1")
        let root = Self.repoRoot
        let git = try await ShellGitAnalyzer().analyze(repositoryURL: root)
        XCTAssertTrue(git.isRepository, "本工作树必须是仓库，否则这条门什么都没比对")
        XCTAssertGreaterThan(git.commitsAnalyzed, 0, "分析器一条提交都没解析出来，比对形同虚设")
        XCTAssertFalse(git.commitsPerPeriod.isEmpty, "工具一个桶都没切出来，比对形同虚设")

        // 真值与作者偏移一次性取回。混合时区仓库里工具按主导偏移统一切、
        // git 的 `%ad` 按各提交自己的偏移报，两边不是同一把尺子，此时显式跳过并说清理由
        // （跳过条件与理由都在这一条里，比对逻辑本身由上面的元测试无条件跑着）。
        let samples = try authorDaySamples(in: root)
        XCTAssertFalse(samples.isEmpty, "git 一条 %ad/%aI 都没返回，取数失败")
        XCTAssertEqual(samples.count, git.commitsAnalyzed,
                       "两边量的必须同一批提交：git 非合并 \(samples.count) 条 vs 分析器 \(git.commitsAnalyzed) 条")
        let offsets = Set(samples.map(\.offset))
        guard offsets.count == 1 else {
            throw XCTSkip("仓库作者偏移不止一个 \(offsets.sorted())，"
                + "工具按主导偏移统一切、真值按各自偏移报，两把尺子不可直接对账")
        }
        let offset = samples[0].offset

        var truth: [String: Int] = [:]
        for sample in samples { truth[sample.day, default: 0] += 1 }
        // 只拿**非空桶**比：补出来的 0 提交空桶对应的日子 git 真值里本来就没有条数。
        var tool: [String: Int] = [:]
        for bucket in git.commitsPerPeriod where bucket.commits > 0 {
            tool[civilDay(bucket.date, offsetSeconds: offset)] = bucket.commits
        }
        XCTAssertFalse(tool.isEmpty, "过滤后一个非空桶都没有，比对形同虚设")
        XCTAssertEqual(Set(samples.map(\.day)), Set(tool.keys),
                       "工具切出的当地日集合与 git 的集合不同")

        let diffs = diffAgainstTruth(tool: tool, truth: truth)
        XCTAssertNil(diffs, "逐日对账失败：\(diffs ?? "")")
        XCTAssertEqual(truth.values.reduce(0, +), git.commitsAnalyzed,
                       "git 非合并计数必须等于分析器解析条数（同一批提交）")
        print("【真实仓库分桶】作者偏移 \(offset) 共 \(truth.count) 天："
            + truth.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))

        // 同一个真实仓库顺带把 #43 的效果打出来：冻结字段给什么、派生判断给什么、评分给几分。
        let cadence = GitCadenceEvidence.assess(git)
        let health = WeightedHealthScorer().score(HealthInputs(git: git))
        let activity = health.components.first { $0.name == HealthDimension.activity.rawValue }
        print("【真实仓库节奏】冻结日均 \(String(format: "%.1f", git.commitsPerDay))"
            + "（= 提交总数 \(git.totalCommits)？）vs 派生日均 \(String(format: "%.1f", cadence.ratePerDay))"
            + " 状态=\(cadence.status.rawValue) 跨度=\(String(format: "%.2f", cadence.spanDays)) 天"
            + " 活跃度分量=\(activity.map { "\($0.score) 分/\($0.risk.rawValue)" } ?? "缺席")"
            + " 说了节奏稳定=\(health.strengths.contains { $0.contains("提交节奏稳定") })")
    }

    // MARK: - 独立取数（自己起 git 进程，不复用 WS-J 的取证管道）

    /// 本工作树根（= git 仓库根）：测试文件往上四层。用 `#filePath` 推导，主树与各 worktree 都能跑。
    static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // 工作树根 = 仓库根
    }()

    /// 一条非合并提交的「git 自己给的当地日号 + 作者偏移」。
    /// `%ad --date=short` 用的是**该提交作者的时区**（实测：强制 `TZ=UTC` 结果一字不变），
    /// 所以它是与本机时区无关的独立真值，比 `--date=format-local` 更干净。
    /// 偏移取 `%aI` 尾部的 ±hh:mm（pretty 里没有 `%z` 这个占位符，实测会原样吐出 "%z"）。
    func authorDaySamples(in root: URL) throws -> [(day: String, offset: Int)] {
        let lines = try runGit(["log", "--no-merges", "--pretty=format:%ad%x1f%aI", "--date=short"], in: root)
            .split(separator: "\n", omittingEmptySubsequences: true)
        return try lines.map { line in
            let fields = line.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2 else { throw AnalysisError.empty("git 行形状不对：\(line)") }
            let day = String(fields[0]).trimmingCharacters(in: .whitespaces)
            let iso = String(fields[1]).trimmingCharacters(in: .whitespaces)
            guard day.count == 10, day.contains("-") else {
                throw AnalysisError.empty("当地日号形状不对：\(day)")
            }
            return (day, try offsetSeconds(fromAuthorISO: iso))
        }
    }

    /// 从 `%aI`（如 `2026-09-19T17:07:54+08:00`）尾部取偏移秒数。
    /// 手写，不走 DateFormatter：不依赖本机 locale 与 TZ 表。
    /// `%aI` 恒为 `±hh:mm`（6 字符），但按解析器同样的宽容也吃 `±hhmm`（5 字符）。
    func offsetSeconds(fromAuthorISO text: String) throws -> Int {
        if text.hasSuffix("Z") || text.hasSuffix("z") { return 0 }
        guard let signIndex = text.lastIndex(of: "+") ?? text.lastIndex(of: "-"),
              (5...6).contains(text.distance(from: signIndex, to: text.endIndex)) else {
            throw AnalysisError.empty("作者时间戳尾部取不出偏移：\(text)")
        }
        return try parseOffset(String(text[signIndex...]))
    }

    /// `+08:00` / `+0800` / `-0530` -> 秒。
    func parseOffset(_ text: String) throws -> Int {
        let characters = Array(text.filter { $0 != ":" })
        guard characters.count == 5, characters[0] == "+" || characters[0] == "-",
              let hour = Int(String(characters[1...2])), let minute = Int(String(characters[3...4])) else {
            throw AnalysisError.empty("偏移串无法解析：\(text)")
        }
        return (characters[0] == "-" ? -1 : 1) * (hour * 3_600 + minute * 60)
    }

    /// 独立实现「绝对瞬间 + 固定偏移 -> YYYY-MM-DD」：Howard Hinnant 的 civil_from_days，
    /// 与解析器 `GitLogParser.daysFromCivil` 互为反函数。**故意不借用产品代码**，
    /// 否则两边共享同一个盲区，比对就成了自证。
    func civilDay(_ date: Date, offsetSeconds: Int) -> String {
        let days = Int(floor((date.timeIntervalSince1970 + Double(offsetSeconds)) / 86_400))
        let z = days + 719_468
        let era = (z >= 0 ? z : z - 146_096) / 146_097
        let dayOfEra = z - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1_460 + dayOfEra / 36_524 - dayOfEra / 146_096) / 365
        let year0 = yearOfEra + era * 400
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let shiftedMonth = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * shiftedMonth + 2) / 5 + 1
        let month = shiftedMonth < 10 ? shiftedMonth + 3 : shiftedMonth - 9
        let year = year0 + (month <= 2 ? 1 : 0)
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    func runGit(_ arguments: [String], in root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", root.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
