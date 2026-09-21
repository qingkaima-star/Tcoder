import XCTest
@testable import TcoderMonitor

/// 无头 CLI 的行为契约。
///
/// 为什么处处用假分析器而不是真扫目录：退出码 2 / 4 这两档在真仓库上**造不出来**
/// （要么五路全成、要么路径根本不存在），靠真扫去凑只会得到一组永远不跑的断言。
/// 注入缝由 `CLIScan.init` 的带默认值参数提供，那也正是"CLI 与 GUI 同一把尺子"
/// 能被测出来的前提。
final class CLIHeadlessTests: XCTestCase {

    // MARK: - 假分析器

    private final class StubCode: CodeAnalysisProviding {
        let result: CodeMetrics?
        let error: Error?
        private(set) var calls = 0
        init(result: CodeMetrics?, error: Error? = nil) { self.result = result; self.error = error }
        func analyze(root: URL, options: ScanOptions) async throws -> CodeMetrics {
            calls += 1
            if let error { throw error }
            return result ?? CodeMetrics()
        }
    }

    private final class StubGit: GitAnalysisProviding {
        let result: GitInsights?
        let error: Error?
        private(set) var calls = 0
        init(result: GitInsights?, error: Error? = nil) { self.result = result; self.error = error }
        func analyze(repositoryURL: URL) async throws -> GitInsights {
            calls += 1
            if let error { throw error }
            return result ?? GitInsights()
        }
    }

    private final class StubLogs: LogAnalysisProviding {
        let error: Error?
        private(set) var seenExtraURLs: [URL] = []
        private(set) var seenWindowDays: Int?
        init(error: Error? = nil) { self.error = error }
        func analyze(projectRoot: URL, extraLogURLs: [URL], withinDays: Int) async throws -> LogSummary {
            seenExtraURLs = extraLogURLs
            seenWindowDays = withinDays
            if let error { throw error }
            return LogSummary()
        }
    }

    private final class StubDeps: DependencyAnalysisProviding {
        let error: Error?
        init(error: Error? = nil) { self.error = error }
        func analyze(projectRoot: URL, allowNetwork: Bool) async throws -> DependencyReport {
            if let error { throw error }
            return DependencyReport()
        }
    }

    private final class StubCoverage: CoverageProviding {
        let error: Error?
        init(error: Error? = nil) { self.error = error }
        func analyze(projectRoot: URL, options: ScanOptions) async throws -> CoverageMetrics {
            if let error { throw error }
            return CoverageMetrics()
        }
    }

    private static let boom = AnalysisError.empty("假失败")

    private static func healthyCode() -> CodeMetrics {
        var code = CodeMetrics()
        code.totalFiles = 128
        code.totalLines = 9_000
        code.codeLines = 7_400
        return code
    }

    private static func healthyGit() -> GitInsights {
        var git = GitInsights()
        git.isRepository = true
        git.totalCommits = 57
        git.commitsAnalyzed = 57
        git.branch = "main"
        git.headSHA = "deadbeef"
        return git
    }

    private func scan(code: CodeMetrics? = healthyCode(),
                      git: GitInsights? = healthyGit(),
                      codeError: Error? = nil,
                      gitError: Error? = nil,
                      logsError: Error? = nil,
                      depsError: Error? = nil,
                      coverageError: Error? = nil) -> CLIScan {
        CLIScan(code: StubCode(result: code, error: codeError),
                git: StubGit(result: git, error: gitError),
                logs: StubLogs(error: logsError),
                deps: StubDeps(error: depsError),
                coverage: StubCoverage(error: coverageError),
                scorer: WeightedHealthScorer())
    }

    /// 只指向一个真存在的目录，路径校验才过得去；内容不重要，五路全是假的。
    private var fixtureDir: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
    }

    // MARK: - 分派词表：不许误判 GUI

    func test_onlyExactSubcommandWordsDispatchToCLI() {
        for word in ["scan", "score", "doctor"] {
            XCTAssertTrue(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", word, "/tmp/x"]), word)
        }
        // GUI 侧确实会传这两个：取证链的 -ApplePersistenceIgnoreState、LaunchServices 的 -psn_
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", "-ApplePersistenceIgnoreState", "YES"]))
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", "-psn_0_123456"]))
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor"]))
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", "Scan", "/tmp/x"]), "大小写要精确匹配，不做模糊认")
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", "scanner", "/tmp/x"]))
        // 子命令词只能出现在 argv[1]：路径里带 scan 不算
        XCTAssertFalse(CLIRouter.isHeadlessInvocation(argv: ["TcoderMonitor", "/tmp/scan", "scan"]))
    }

    // MARK: - 参数解析

    func test_parse_scanCarriesGUIIdenticalDefaults() throws {
        guard case let .request(req) = CLIRouter.parse(argv: ["x", "scan", "/tmp/repo"]) else {
            return XCTFail("scan 应当解析成 request")
        }
        XCTAssertEqual(req.mode, .scan)
        XCTAssertEqual(req.path, "/tmp/repo")
        XCTAssertFalse(req.allowNetwork, "默认不联网，与 AppState.allowNetworkLookups = false 对齐")
        XCTAssertFalse(req.compact)
        XCTAssertNil(req.outPath)
    }

    func test_parse_flagsAndUsageErrors() {
        guard case let .request(req) = CLIRouter.parse(
            argv: ["x", "scan", "/tmp/r", "--allow-network", "--compact", "--out=/tmp/o.json"]) else {
            return XCTFail("三个参数应当被认下")
        }
        XCTAssertTrue(req.allowNetwork)
        XCTAssertTrue(req.compact)
        XCTAssertEqual(req.outPath, "/tmp/o.json")

        for bad in [["x", "scan"], ["x", "frobnicate", "/tmp"], ["x", "scan", "/tmp", "--wat"]] {
            guard case .usage = CLIRouter.parse(argv: bad) else {
                return XCTFail("这些形状必须判用法错：\(bad)")
            }
        }
        // help / version 是用法而非错误：退出码 0
        if case let .request(req) = CLIRouter.parse(argv: ["x", "--help"]) { XCTAssertEqual(req.mode, .help) }
        else { XCTFail("--help 不该走用法错") }
        XCTAssertEqual(CLIRouter.exitCode(for: CLIRouter.parse(argv: ["x", "scan"])), .usage)
        XCTAssertEqual(CLIRouter.exitCode(for: CLIRouter.parse(argv: ["x", "--version"])), .ok)
    }

    // MARK: - 退出码：没有"静默成功"这一档

    // MARK: - 日志入参：界面能手动附加，CLI 不能就是假无

    func test_parseCarriesRepeatableLogPathsAndWindow() throws {
        let file = fixtureDir + "/CLIHeadlessTests.swift"      // 一个真存在的文件才该被认下
        guard case let .request(req) = CLIRouter.parse(
            argv: ["x", "score", "/tmp/r", "--log=\(file)", "--window-days=14"]) else {
            return XCTFail("--log / --window-days 应当被认下")
        }
        XCTAssertEqual(req.logPaths, [file])
        XCTAssertEqual(req.windowDays, 14)
        guard case let .request(multi) = CLIRouter.parse(
            argv: ["x", "scan", "/tmp/r", "--log=\(file)", "--log=\(file)"]) else {
            return XCTFail("--log 要可重复（界面上的附加日志就是一个数组）")
        }
        XCTAssertEqual(multi.logPaths.count, 2)
        if case let .request(bare) = CLIRouter.parse(argv: ["x", "scan", "/tmp/r"]) {
            XCTAssertEqual(bare.windowDays, CLIScan.logWindowDays,
                           "不传时必须落回 GUI 的默认窗口，否则与界面对不上表")
        } else {
            XCTFail("scan 带路径应当解析成 request")
        }
    }

    func test_rejectsUnparseableLogInputs() {
        for bad in [["x", "score", "/tmp", "--window-days=abc"],
                    ["x", "score", "/tmp", "--window-days=0"],
                    ["x", "score", "/tmp", "--log=/definitely/not/here-\(UUID().uuidString).log"]] {
            guard case .usage = CLIRouter.parse(argv: bad) else { return XCTFail("这些必须判用法错：\(bad)") }
        }
    }

    func test_logInputsReachTheAnalyzer() async throws {
        let file = fixtureDir + "/CLIHeadlessTests.swift"
        let logs = StubLogs()
        let sut = CLIScan(code: StubCode(result: Self.healthyCode()), git: StubGit(result: Self.healthyGit()),
                          logs: logs, deps: StubDeps(), coverage: StubCoverage(), scorer: WeightedHealthScorer())
        _ = await sut.outcome(path: fixtureDir, allowNetwork: false,
                              extraLogPaths: [file], windowDays: 21)
        XCTAssertEqual(logs.seenExtraURLs.map(\.path), [file], "附加日志没传到分析器 = 界面有而 CLI 没有的第二份实现")
        XCTAssertEqual(logs.seenWindowDays, 21)
    }

    func test_exitCodeFollowsFailedSectionCount() {
        XCTAssertEqual(CLIExit.failedSections(0), .ok)
        XCTAssertEqual(CLIExit.failedSections(1), .partial)
        XCTAssertEqual(CLIExit.failedSections(4), .partial)
        XCTAssertEqual(CLIExit.failedSections(CLIScan.sectionLabels.count), .allFailed)
        XCTAssertEqual(CLIExit.failedSections(99), .allFailed, "超出五路只能是更糟，不许回落成 partial")
    }

    func test_unusablePathExitsThreeWithoutTouchingAnalyzers() async {
        let code = StubCode(result: nil)
        let sut = CLIScan(code: code, git: StubGit(result: nil), logs: StubLogs(),
                          deps: StubDeps(), coverage: StubCoverage(), scorer: WeightedHealthScorer())
        let outcome = await sut.outcome(path: "/definitely/not/here-\(UUID().uuidString)", allowNetwork: false)
        XCTAssertEqual(outcome.exit, .badPath)
        XCTAssertNil(outcome.report, "路径不成立时不许吐一份看起来像结论的空报告")
        XCTAssertEqual(code.calls, 0, "路径校验必须前置，否则白扫一遍还给出可读的假报告")
    }

    // MARK: - schema 同源：JSON 要能解回同一个类型

    func test_scanJSONDecodesBackIntoProjectReport() async throws {
        let outcome = await scan().outcome(path: fixtureDir, allowNetwork: false)
        XCTAssertEqual(outcome.exit, .ok, "\(outcome.report?.failedSections ?? [])")
        guard let report = outcome.report else { return XCTFail("应有报告") }

        let json = try CLIScan.json(report, compact: true)
        let back = try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: Data(json.utf8))
        XCTAssertEqual(back.project.path, report.project.path)
        XCTAssertEqual(back.code?.totalFiles, 128)
        XCTAssertEqual(back.git?.totalCommits, 57)
        XCTAssertEqual(back.health?.overall, report.health?.overall)
        XCTAssertEqual(back.failedSections, [])
        XCTAssertEqual(back.project.name, URL(fileURLWithPath: fixtureDir).lastPathComponent,
                       "project 段是入参的如实记录，不是编出来的名字")
    }

    func test_partialFailureReportsExitTwoAndNamesTheFailedSections() async {
        let outcome = await scan(logsError: Self.boom, depsError: Self.boom).outcome(path: fixtureDir, allowNetwork: false)
        XCTAssertEqual(outcome.exit, .partial)
        XCTAssertEqual(outcome.report?.failedSections.count, 2)
        XCTAssertTrue(outcome.report!.failedSections.contains(CLIScan.sectionLabels[2]))
        XCTAssertNotNil(outcome.report?.health, "部分失败时仍要给出可评的维度，不能整份作废")
    }

    func test_allFiveFailedExitsFour() async {
        let outcome = await scan(codeError: Self.boom, gitError: Self.boom, logsError: Self.boom,
                                 depsError: Self.boom, coverageError: Self.boom)
            .outcome(path: fixtureDir, allowNetwork: false)
        XCTAssertEqual(outcome.exit, .allFailed)
        XCTAssertEqual(outcome.report?.failedSections.count, CLIScan.sectionLabels.count)
    }

    func test_missingSectionIsAbsentRatherThanZeroFilled() async throws {
        let outcome = await scan(codeError: Self.boom).outcome(path: fixtureDir, allowNetwork: false)
        guard let report = outcome.report else { return XCTFail("应有报告") }
        let json = try CLIScan.json(report, compact: true)
        // 合成编码器对 nil 走 `encodeIfPresent` = 整键缺席，这与 GUI 落盘同形状。
        // 真正的坑是反过来：为了"JSON 好看"把缺的一路填成一个全 0 的对象。
        XCTAssertFalse(json.contains("\"code\":"), "缺的那一路应当整键缺席：\n\(json.prefix(400))")
        XCTAssertFalse(json.contains("\"totalFiles\":0"), "出现 totalFiles:0 就是把没扫当成扫过了")
        let back = try JSONDecoder.tcoderReportDecoder().decode(ProjectReport.self, from: Data(json.utf8))
        XCTAssertNil(back.code)
        XCTAssertEqual(back.failedSections, [CLIScan.sectionLabels[0]])
    }

    // MARK: - score 文本读数

    func test_scoreTextListsFailuresBeforeTheScore() async {
        let outcome = await scan(gitError: Self.boom).outcome(path: fixtureDir, allowNetwork: false)
        let text = CLIScoreText.render(outcome.report!, exit: outcome.exit)
        let failureAt = text.range(of: "Git 分析")!.lowerBound
        let scoreAt = text.range(of: "综合健康分")!.lowerBound
        XCTAssertLessThan(failureAt, scoreAt, "先说哪几路没跑出来，再说分；反过来会让 AI 先信了分")
        XCTAssertTrue(text.contains("7400") || text.contains("7,400"), "总体（码行数）必须在读数旁边")
        XCTAssertTrue(text.contains(fixtureDir), "被扫目录的绝对路径必须出现在首行")
    }

    func test_scoreTextSaysUnscannedWhenNothingReturned() {
        var report = ProjectReport(project: MonitoredProject(name: "x", path: "/tmp/x"))
        report.failedSections = CLIScan.sectionLabels
        let text = CLIScoreText.render(report, exit: .allFailed)
        XCTAssertTrue(text.contains("五路全部失败"))
        XCTAssertFalse(text.contains("综合健康分 0"), "全失败时不许把 overall 的默认 0 当成读数打出来")
    }

    // MARK: - 缺席维度与核对口径（复用界面那一份，不另写）

    func test_absentDimensionsPointBackToThisRunsFailures() async {
        let outcome = await scan(codeError: Self.boom).outcome(path: fixtureDir, allowNetwork: false)
        let text = CLIScoreText.render(outcome.report!, exit: outcome.exit)
        XCTAssertTrue(text.contains("缺席维度"), text)
        XCTAssertTrue(text.contains("原因见上面「失败路」那一行"), text)
        XCTAssertFalse(text.contains("上次扫描"),
                       "原因表里那句「上次扫描」讲的是界面上的历史报告；CLI 一次性的读数里失败就是本次，照抄会把本次读成历史账")
    }

    func test_offlineVulnerabilityNoteRidesAlongWithTheReadout() async {
        let clean = await scan().outcome(path: fixtureDir, allowNetwork: false)
        XCTAssertFalse(CLIScoreText.render(clean.report!, exit: clean.exit).contains("漏洞核对"),
                       "分析器没说没查，CLI 不许凭空造一句")

        var report = clean.report!
        var deps = DependencyReport()
        deps.networkLookupNote = "未联网核对，仅内置快照。"
        report.dependencies = deps
        XCTAssertTrue(CLIScoreText.render(report, exit: .ok)
                        .contains("漏洞核对：未联网核对，仅内置快照。"),
                      "界面上常驻的那句「没查 ≠ 没有病」，CLI 读数里也必须出现")
    }

    // MARK: - 两个行数分母必须各自点名（反扫自己抓出来的那条）

    /// 一次 `score` 读数里同时出现两个行数：首行的「码行」是**有效代码行**，
    /// 注释维度的分母是**总行（空行 + 注释 + 代码）**。差着一截却不点名，
    /// 读的人（人或 AI）就会判成"同一个量的两次读数不一致"—— 本仓为这类事故记过账。
    func test_theTwoLineDenominatorsNameThemselves() {
        let curve = HealthCurves.documentation(commentRatio: 0.157, todoCount: 9, fixmeCount: 9,
                                               totalLines: 69_199)
        XCTAssertTrue(curve.detail.contains("总行 69,199"),
                      "分母没点名：\(curve.detail)")
        XCTAssertFalse(curve.detail.contains("源码"),
                      "「源码 N 行」和首行的「码行 M」并排出现时会被读成同一个量：" + curve.detail)
    }

    // MARK: - 一路名只许有一份真值

    private static let appStateURL = URL(fileURLWithPath: #filePath)   // …/Tests/TcoderMonitorTests/本文件.swift
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/TcoderMonitor/App/AppState.swift")

    /// CLI 与 GUI 各自硬编码一套中文路名，早晚分叉 —— 而 `failedSections` 是要被
    /// 人和机器一起读的字段，分叉之后"新老两条路对表"这句话就是空的。
    func test_sectionLabelsAreTheOnlyOnesAppStateUses() throws {
        let src = try String(contentsOf: Self.appStateURL, encoding: .utf8)
        let inApp = Self.chineseLiteralsPassedToSectionFailures(src)
        XCTAssertEqual(Set(inApp), Set(CLIScan.sectionLabels),
                       "AppState 里的路名是 \(inApp)，CLI 声明的是 \(CLIScan.sectionLabels)")
    }

    /// 元测试：上面那条扫描器必须真能抓到分叉，否则它是永真绿。
    func test_sectionLabelScannerCatchesADivergedLabel() {
        let dirty = """
        let failures = Self.sectionFailures([
            (codeResult.error, "代码扫描"),
            (gitResult.error, "Git 分析"),
            (logResult.error, "日志分析"),
            (depsResult.error, "依赖分析"),
            (coverageResult.error, "测试覆盖率"),
        ])
        """
        XCTAssertEqual(Self.chineseLiteralsPassedToSectionFailures(dirty).count, 5)
        XCTAssertTrue(Self.chineseLiteralsPassedToSectionFailures("let x = 1").isEmpty)
    }

    private static func chineseLiteralsPassedToSectionFailures(_ src: String) -> [String] {
        // 只认 `<expr>.error, "含汉字的串"` 这一种形状：它就是 AppState 调用点的原样。
        let re = try! NSRegularExpression(
            pattern: "\\([\\w.]+\\.error,\\s*\"([^\"]*[\\u4e00-\\u9fff][^\"]*)\"\\)")
        var out: [String] = []
        for line in src.split(separator: "\n") {
            let l = String(line)
            let range = NSRange(l.startIndex..., in: l)
            for m in re.matches(in: l, options: [], range: range) {
                guard let r = Range(m.range(at: 1), in: l) else { continue }
                out.append(String(l[r]))
            }
        }
        return out
    }

    /// CLI 与 GUI 落盘共用同一套 coder 配置（`.iso8601`），否则两侧的 JSON 互读不回来。
    func test_datesUseTheSameISO8601StrategyAsProjectStore() async throws {
        let outcome = await scan().outcome(path: fixtureDir, allowNetwork: false)
        let json = try CLIScan.json(outcome.report!, compact: true)
        let re = try! NSRegularExpression(pattern: "\"generatedAt\":\"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]+Z\"")
        XCTAssertNotNil(re.firstMatch(in: json, range: NSRange(json.startIndex..., in: json)),
                        "generatedAt 不是 ISO8601，GUI 的 decoder 会整份解不动：\n\(json.prefix(300))")
    }
}
