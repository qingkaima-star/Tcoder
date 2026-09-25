import XCTest
@testable import TcoderMonitor

/// OWNER: WS-R37 评分支路可达性（分支 `ws/rd27-reach`）—— 工单交付 ①②③④⑤ 的本体。
///
/// **这一族证的是另一件事**。`ScoreEvidenceFloorTests` / `ScoreEvidenceFloorCrashStatesTests`
/// 那一族是「手搓 `HealthInputs` 喂给评分器 ⇒ 评分器在那个数上会说什么」；
/// 本族一个 `HealthInputs` 都不手搓，只把**真夹具目录**交给 `CLIScan`
/// （与 GUI 同一批分析器、同一个 `WeightedHealthScorer`、同一套缺席装配），
/// 于是它回答的是台账里那句「先证明可达再动」：
///
/// | 形状 | 结论（本文件逐条钉住） |
/// |---|---|
/// | ① 只有崩溃报告、零真日志行 | **可达**（RD-49 第②态真的会长出来） |
/// | ② 3 行日志、0 错误 | **可达**（走 `isThin` 降档，不是满分） |
/// | ③ `git init` 后零提交 | `commitBasis == 0` **成立**，但 fail-loud 那一支**走不到** —— 被 `HealthTeamDimensions.busFactorOutcome` 的 `totalCommits > 0` 挡在前面 |
/// | ③b 有提交、作者表却是空的 | fail-loud 那一支**可达**，真正的入口形状是「作者日期年份五位数 ⇒ 上游整条丢行」，不是「零提交」 |
/// | ④ 不是仓库的普通目录 | **可达**（Git 那一维整维缺席） |
/// | ⑤ 提交全在一个署名下 | **可达**（单人占比那一支，进加权） |
///
/// 夹具与盘上独立真值在 `R37ReachabilityFixture.swift`；三出口对表在
/// `ScoreBranchReachabilityParityTests.swift`。
final class ScoreBranchReachabilityTests: XCTestCase {

    private var sandbox: URL!
    private var originalLogsDirectory: String?

    override func setUpWithError() throws {
        originalLogsDirectory = ProcessInfo.processInfo.environment["TCODER_LIBRARY_LOGS_DIR"]
        sandbox = try R37ReachFixture.makeSandbox()
        // 崩溃报告目录指到夹具里一个**空**目录：真 `~/Library/Logs/DiagnosticReports`
        // 一个字都不读（那是全机共用目录，绝大多数属于别的工程，AGENTS §-1 禁区）。
        let libraryLogs = sandbox.appendingPathComponent("fake-library-logs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: libraryLogs.appendingPathComponent("DiagnosticReports", isDirectory: true),
            withIntermediateDirectories: true)
        setenv("TCODER_LIBRARY_LOGS_DIR", libraryLogs.path, 1)
    }

    override func tearDownWithError() throws {
        if let original = originalLogsDirectory { setenv("TCODER_LIBRARY_LOGS_DIR", original, 1) }
        else { unsetenv("TCODER_LIBRARY_LOGS_DIR") }
        try? FileManager.default.removeItem(at: sandbox)
    }

    // MARK: - ① 只有崩溃报告、零真日志行（RD-49 那一格）

    func test_shape1CrashReportWithoutAnyLogLineIsReachable() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37CrashOnlyApp", under: sandbox)
        try R37ReachFixture.makeRepository(at: root, count: 9)
        let ips = try R37ReachFixture.writeCrashReport(in: root, product: "R37CrashOnlyApp", lines: 400)
        let scan = try await productScan(root)
        let logs = try XCTUnwrap(scan.logs)

        // 盘上独立真值：这份读数是夹具喂出来的，不是「什么都没读到」。
        try assertFixtureFeedsAnalyzer(logs, urls: [ips])
        XCTAssertEqual(logs.totalLinesScanned, 0, "只有崩溃报告 ⇒ 分母必须是 0")
        XCTAssertEqual(logs.crashCount, 1, "崩溃报告真被认成了确认崩溃（不是 0）")
        XCTAssertEqual(logs.crashReportCount, 1)
        XCTAssertGreaterThan(logs.crashReportLineCount ?? 0, 0, "被移出分母的行数要仍然数得出来")
        XCTAssertTrue(logs.hasData, "hasData 为真而分母为 0 —— 这正是 RD-49 的病根形状")

        XCTAssertNil(component(of: scan, .stability), "这一维不许带着崩溃数进加权")
        XCTAssertTrue(try missing(of: scan).contains(.stability))
        let advice = try XCTUnwrap(recommendation(of: scan, containing: "错误密度算不出分母"),
                                   "三态第②态那句话没出口：\(recommendations(of: scan))")
        XCTAssertEqual(advice, "读到 1 次确认崩溃（1 份崩溃报告），但零真日志行 ⇒ 错误密度算不出分母，"
                             + "本维度不参与本次评分；崩溃明细见「错误日志」页。", "那句话要逐字")
        XCTAssertFalse(recommendations(of: scan).contains { $0.contains("没有可扫描的日志") },
                       "扫到了崩溃报告还说那句就是假话")
    }

    // MARK: - ② 日志有内容但极薄 ⇒ 必须走 isThin 降档，不许满分

    func test_shape2ThreeLineLogReachesTheThinEvidenceDowngrade() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37ThinLogApp", under: sandbox)
        try R37ReachFixture.makeRepository(at: root, count: 9)
        let written = try R37ReachFixture.writeLog(under: root, lines: 3, every: 0)
        let scan = try await productScan(root)
        let logs = try XCTUnwrap(scan.logs)

        try assertFixtureFeedsAnalyzer(logs, urls: [written])
        XCTAssertEqual(logs.totalLinesScanned, 3, "分母就是盘上那 3 行")
        XCTAssertEqual(logs.errorCount + logs.exceptionCount, 0, "夹具里一条错误都没有 ⇒ 密度 0")

        let stability = try XCTUnwrap(component(of: scan, .stability),
                                      "薄证据这一维不许缺席（缺席会把已量到的读数一起抹掉）")
        XCTAssertEqual(stability.score, Int(StabilityEvidence.thinEvidenceScoreCeiling),
                       "3 行 0 错误必须被封顶，实得 \(stability.score)")
        XCTAssertLessThan(stability.score, 100, "「3 行没出错」不配与「跑了半年没出错」拿同一个数")
        XCTAssertTrue(stability.detail.contains("证据太薄·未判定"), stability.detail)
        let advice = try XCTUnwrap(recommendation(of: scan, containing: "证据太薄"),
                                   "降档那句没进建议：\(recommendations(of: scan))")
        XCTAssertTrue(advice.contains("只读到 3 行真日志"), "建议要点名实际读到的行数：\(advice)")
        XCTAssertFalse(strengths(of: scan).contains { $0.contains("未见确认崩溃") },
                       "同一道门槛必须管住优点句：\(strengths(of: scan))")
    }

    // MARK: - ③ 零提交：`commitBasis == 0` 成立，但 fail-loud 那一支走不到

    func test_shape3ZeroCommitRepositoryNeverReachesTheFailLoudBranch() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37EmptyRepo", under: sandbox)
        try R37ReachFixture.makeEmptyRepository(at: root)
        let scan = try await productScan(root)
        // 空仓库也是真仓库：Git 那一路要产出对象（0 笔是真实答案），而不是把这一路判成失败。
        let git = try XCTUnwrap(scan.git, "Git 那一路没产出对象，五路台账：\(ledgerLine(scan))")

        XCTAssertEqual(git.totalCommits, 0)
        XCTAssertEqual(git.authorBasisCommits, 0, "工单那一格的字面条件成立")
        XCTAssertTrue(R37ReachFixture.revListCount(at: root).contains("非零退出"),
                      "上游真值：这笔仓库的 rev-list 根本数不出 HEAD ⇒ totalCommits 只能落回 0")
        for dimension in [HealthDimension.activity, .busFactor] {
            XCTAssertNil(component(of: scan, dimension), "\(dimension.rawValue) 不许参与加权")
            XCTAssertTrue(try missing(of: scan).contains(dimension))
        }
        // 这一格要的判定就在这里：那一支**没被走到**，所以它那句话一句都出不来。
        XCTAssertNil(recommendation(of: scan, containing: "非合并口径 0 笔"),
                     "零提交走的是 totalCommits 那道 guard，不该出现 fail-loud 那句：\(recommendations(of: scan))")
        XCTAssertNil(recommendation(of: scan, containing: "占比无定义"),
                     "新地板那句也不该出现：\(recommendations(of: scan))")
        XCTAssertEqual(MissingDimensionReason.text(for: .busFactor, report: scan),
                       "该仓库没有任何提交，Git 两维都没有输入。", "屏上那一格的原文")
    }

    // MARK: - ③b fail-loud 那一支的真正入口：有提交、作者表为空

    /// 上游怎么把 ③ 变成 ③b 的：`GitLogParser.commit(fromHeaderLine:)` 认不下五位数年份的
    /// `%aI` ⇒ 整条提交被丢掉（`commitsAnalyzed` 归 0），而 `rev-list --count HEAD` 仍然数得到 ⇒
    /// `totalCommits > 0` 与 `authorBasisCommits == 0` 同时成立，那一支这才被走到。
    func test_shape3bEmptyAuthorTableWithCommitsReachesTheFailLoudBranch() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37FarFutureRepo", under: sandbox)
        try makeRepositoryWithFiveDigitAuthorYear(at: root)
        let stamp = R37ReachFixture.authorDateStamp(at: root)
        XCTAssertTrue(stamp.hasPrefix("33658-"), "夹具前提：%aI 是五位数年份，实得 \(stamp)")
        XCTAssertEqual(R37ReachFixture.revListCount(at: root), "1", "上游真值：仓库确实有 1 笔提交")

        let scan = try await productScan(root)
        let git = try XCTUnwrap(scan.git)
        XCTAssertEqual(git.totalCommits, 1)
        XCTAssertEqual(git.commitsAnalyzed, 0, "解析器一条都没收下 ⇒ 作者表空")
        XCTAssertEqual(git.authorBasisCommits, 0)
        XCTAssertTrue(git.authors.isEmpty)

        XCTAssertNotNil(component(of: scan, .activity), "活跃度只依赖 totalCommits，应当照常计分")
        XCTAssertNil(component(of: scan, .busFactor), "协作分布要整维缺席、不按 0 计入")
        XCTAssertTrue(try missing(of: scan).contains(.busFactor))
        let advice = try XCTUnwrap(recommendation(of: scan, containing: "作者表里没有可算分布的提交"),
                                   "fail-loud 那句没出口：\(recommendations(of: scan))")
        XCTAssertEqual(advice, "作者表里没有可算分布的提交（非合并口径 0 笔，含合并共 1 笔），"
                             + "协作分布不参与本次计分；这一维读的是「署名分布」，要有非合并提交才谈得上分散与否。")
        XCTAssertNil(recommendation(of: scan, containing: "占比无定义"),
                     "0 总体与总体太小是两件事，不许被新地板抢先兜住（工单 R9b §4.4）")
        XCTAssertEqual(MissingDimensionReason.text(for: .busFactor, report: scan),
                       "含合并共 1 笔提交里没有一笔非合并提交，作者分布没有可算的总体，本维度不参与计分。")
    }

    private func makeRepositoryWithFiveDigitAuthorYear(at root: URL) throws {
        try R37ReachFixture.git(["init", "-q", "-b", "main"], in: root)
        try "x\n".write(to: root.appendingPathComponent("tracked.txt"), atomically: true, encoding: .utf8)
        try R37ReachFixture.git(["add", "-A"], in: root)
        // 33658 年：git 收下单、本仓时间戳解析器不收 —— 上游静默丢行才产出「作者表为空」。
        let bogus = "@999999999999 +0800"
        try R37ReachFixture.git(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=",
                                 "commit", "-qm", "a five-digit author year"], in: root,
                                environment: ["GIT_AUTHOR_DATE": bogus, "GIT_COMMITTER_DATE": bogus,
                                              "GIT_AUTHOR_NAME": "R37 Timeless",
                                              "GIT_COMMITTER_NAME": "R37 Timeless"])
    }

    // MARK: - ④ 不是仓库的普通目录 ⇒ Git 那一维整维缺席

    func test_shape4PlainDirectoryAbsentsTheWholeGitDimension() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37PlainDirectory", under: sandbox)
        XCTAssertNil(R37ReachFixture.firstGitAncestor(of: root), "夹具前提：祖先链上没有仓库")
        let scan = try await productScan(root, expectingRepository: false)

        XCTAssertNil(scan.git, "Git 那一路要交回 nil，而不是一个空对象冒充成功")
        XCTAssertTrue(scan.failedSections.contains(AnalyzerLedger.sectionLabels[1]),
                      "这一路要报失败，实得 \(scan.failedSections)")
        for dimension in [HealthDimension.activity, .busFactor] {
            XCTAssertNil(component(of: scan, dimension))
            XCTAssertTrue(try missing(of: scan).contains(dimension))
        }
        // 三出口分叉点（报告里点名）：屏上这一格读的是「这一路失败」，不是「不是仓库」那句。
        XCTAssertEqual(MissingDimensionReason.text(for: .busFactor, report: scan),
                       "上次扫描「Git 分析」失败，本维度没有输入。")
    }

    // MARK: - ⑤ 提交全在一个署名下 ⇒ 单人占比那一支

    func test_shape5SingleAuthorHistoryScoresTheBusFactorDimension() async throws {
        let root = try R37ReachFixture.makeProject(named: "R37SoloAuthor", under: sandbox)
        try R37ReachFixture.makeRepository(at: root, count: 12, authors: ["R37 Solo Owner"])
        let scan = try await productScan(root)
        let git = try XCTUnwrap(scan.git)

        XCTAssertEqual(git.authorBasisCommits, 12, "上游真值：12 笔非合并提交都在一个署名上")
        XCTAssertEqual(git.activeAuthorCount, 1)
        XCTAssertEqual(git.topAuthor?.commits, 12)

        // 地板只管多人：单人再小的总体也不许被兜成「无从评估」，这里连总体都够。
        let busFactor = try XCTUnwrap(component(of: scan, .busFactor),
                                      "单人占比这一支必须进加权，实得 \(recommendations(of: scan))")
        XCTAssertLessThan(busFactor.score, 40, "包揽必须是低分，实得 \(busFactor.score)")
        XCTAssertTrue(busFactor.detail.contains("12 次非合并提交"), busFactor.detail)
        let issue = try XCTUnwrap(issues(of: scan).first { $0.contains("单点风险高") },
                                  "单点风险那句没上 issues：\(issues(of: scan))")
        XCTAssertTrue(issue.contains("「R37 Solo Owner」这个署名占 100% 提交"), issue)
        XCTAssertFalse(recommendations(of: scan).contains { $0.contains("占比无定义") },
                       "单人谈不上占比无定义")
    }

    // MARK: - 帮手：真产品路径 + 盘上真值对账

    /// 唯一入口：`CLIScan` 的无头装配（五个分析器 + `WeightedHealthScorer` + 缺席台账），
    /// 与 GUI 共用同一批类型。**这里不手搓 `HealthInputs`** —— 那正是本族与
    /// `ScoreEvidenceFloor*` 那一族的分界。
    private func productScan(_ root: URL, expectingRepository: Bool = true) async throws -> ProjectReport {
        var outcome = await CLIScan().outcome(path: root.path, allowNetwork: false)
        // 环境抖动的合法形状：本机 load 高时 `git log` 会**空等到整个超时**（源码里
        // `ShellGitAnalyzer.runResilient` 的注释就记着这件事），于是「仓库」被读成「没有对象」。
        // 这里只在**独立真值确认它是仓库**、而装配这一路把 Git 判失败时重跑一次；
        // 重跑仍失败就照常判败，并把两次的台账一起抄出来（不改任何判据、不放宽任何东西）。
        if expectingRepository, R37ReachFixture.isGitRepository(at: root),
           gitSectionMissing(outcome.report) {
            let firstLedger = outcome.report.map(ledgerLine) ?? "无报告"
            outcome = await CLIScan().outcome(path: root.path, allowNetwork: false)
            print("【R37 重跑一次】Git 那一路首跑判失败（真值：它是仓库）。台账首跑=\(firstLedger)"
                  + " · 重跑=\(outcome.report.map(ledgerLine) ?? "无报告")")
        }
        let report = try XCTUnwrap(outcome.report, "无头装配没产出报告：\(outcome.problem ?? "无原因")")
        print("【R37 五路台账】" + ledgerLine(report))
        return report
    }

    func gitSectionMissing(_ report: ProjectReport?) -> Bool { report?.git == nil }

    /// 每条用例开跑前先对一次盘上独立真值：**分析器没读到夹具就当场判败**，
    /// 后面那些「这句话出来了」的断言才不会建立在一份空跑上。
    private func assertFixtureFeedsAnalyzer(_ logs: LogSummary, urls: [URL]) throws {
        XCTAssertFalse(urls.isEmpty, "夹具里一个日志类文件都没有 ⇒ 这一格谈不上「分母从哪来」")
        let onDisk = try urls.map { (url: $0, lines: try R11DenominatorFixture.newlineCount(of: $0)) }
        let problems = R37ReachFixture.discrepancies(logs: logs, onDisk: onDisk)
        XCTAssertTrue(problems.isEmpty, "夹具与读数对不上账：\n" + problems.joined(separator: "\n"))
        print("【R37 盘上真值】" + onDisk.map { "\($0.url.lastPathComponent)=\($0.lines)行" }
            .joined(separator: " ") + " · totalLinesScanned=\(logs.totalLinesScanned)"
            + " crashReportCount=\(logs.crashReportCount ?? -1)")
    }
}

// MARK: - 报告读数的取用（维度成员、缺席名单、三组文案）

private extension ScoreBranchReachabilityTests {

    func component(of report: ProjectReport, _ dimension: HealthDimension) -> ScoreComponent? {
        report.health?.components.first { $0.name == dimension.rawValue }
    }

    func missing(of report: ProjectReport) throws -> [HealthDimension] {
        HealthBreakdown.missingDimensions(of: try XCTUnwrap(report.health))
    }

    func recommendations(of report: ProjectReport) -> [String] { report.health?.recommendations ?? [] }
    func strengths(of report: ProjectReport) -> [String] { report.health?.strengths ?? [] }
    func issues(of report: ProjectReport) -> [String] { report.health?.issues ?? [] }

    /// 五路台账压成一行，失败时把它抄进判败消息（只看「这一路是 nil」看不出为什么）。
    func ledgerLine(_ report: ProjectReport) -> String {
        (report.analyzerLedger ?? []).map { record in
            "\(record.name)=\(record.state.rawValue)" + (record.failureReason.map { "(\($0))" } ?? "")
        }.joined(separator: " · ")
    }

    func recommendation(of report: ProjectReport, containing needle: String) -> String? {
        recommendations(of: report).first { $0.contains(needle) }
    }
}
