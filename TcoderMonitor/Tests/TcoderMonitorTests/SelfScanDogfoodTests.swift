import XCTest
@testable import TcoderMonitor

/// OWNER: WS-J 自食其果。**仓库形态门**：用 Tcoder 扫 Tcoder 自己——巨大文件、
/// 只减不增棘轮、Git 同口径对账、评分链路诚实性，外加完整证据转储。
/// 口径/普查门在 `SelfScanConventionGates`，共用管道在 `SelfScanHarnessCase`。
///
/// 一个自称能识别巨大文件与高圈复杂度的工具，如果对自己的坨不报警，结论就没有可信度。
///
/// 完整证据转储默认跳过（避免刷屏同事的测试轮次），开法：
///   TCODER_SELF_SCAN=1 ./scripts/locked_build.sh test
final class SelfScanDogfoodTests: SelfScanHarnessCase {

    private func hugeFilePaths(in metrics: CodeMetrics) -> Set<String> {
        Set(metrics.hugeFiles.map { URL(fileURLWithPath: $0.path).path })
    }

    // MARK: - 防作弊门 1：超限文件必须被工具自己报出来（双向一致性）

    /// 只问一件事：**独立数出来的超限文件集合，与工具报出来的集合，是不是同一批。**
    /// 这里原来还有一条 `XCTAssertFalse(over.isEmpty)`，把「仓库里必须有 800+ 行文件」
    /// 当成不变事实——于是 WS-V 把债还清的那天，它把成功判成了故障。
    /// 「工具是否还有能力看见超限文件」改由 `SelfScanHugeFileMechanismTests` 用
    /// 合成夹具单独把关（那条与仓库有没有债无关，工具瞎了它就红）。
    func testEveryFileOverHighLineBarIsReportedByTheToolItself() async throws {
        let metrics = try await selfScan().code
        let reported = hugeFilePaths(in: metrics)
        // #49：必须与工具同一总体（含 `.md`），否则文档一长就变成"凭空造"。
        let over = try independentSourceLineCounts().filter { $0.lines > Self.toolHighFileLines }

        // 方向一（漏报）：我独立数出的超限文件，工具一个都不许漏。
        let missed = over.filter { !reported.contains($0.path) }.map { "\($0.path)(\($0.lines) 行)" }
        XCTAssertTrue(missed.isEmpty, """
        工具没有把超限文件报进 hugeFiles，等于自我失明。漏报：\(missed.sorted().joined(separator: ", "))
        """)

        // 方向二（凭空造）：工具报进 hugeFiles 且自称 800+ 行的，我必须能独立数出来。
        let claimed = Set(metrics.hugeFiles
            .filter { $0.lineCount > Self.toolHighFileLines }
            .map { URL(fileURLWithPath: $0.path).path })
        let invented = claimed.subtracting(Set(over.map(\.path))).sorted()
        XCTAssertTrue(invented.isEmpty, """
        工具把 \(invented.count) 个文件当成 800+ 行，独立复检却数不到，等于无中生有：\(invented)
        """)

        // 债还清是合法终态：两边同时为空才允许为空，只许同增同减。
        XCTAssertTrue(over.isEmpty == claimed.isEmpty,
                      "独立口径 \(over.count) 个 / 工具口径 \(claimed.count) 个，一个清零一个没清，两边在量不同的东西")

        let overThousand = over.filter { $0.lines > Self.thousandLineBar }
        print("【防作弊门】独立数出的超限文件 \(over.count) 个（其中 >\(Self.thousandLineBar) 行 \(overThousand.count) 个），"
            + "工具 hugeFiles 报 \(metrics.hugeFiles.count) 个（其中自称 >\(Self.toolHighFileLines) 行 \(claimed.count) 个），"
            + "最大 \(metrics.largestFileLineCount) 行"
            + (over.isEmpty ? " —— 800+ 行债务已清零，机制由合成夹具把关" : ""))
    }

    // MARK: - 防作弊门 2：行数只降不升（dogfooding 棘轮）

    /// 这是"分数必须自己变好"的机械保证：新增一个 800+ 行文件会让这条测试变红。
    /// 把某个文件改小的人应当**同时**把下面的上限调低——棘轮只许往紧里拧。
    ///
    /// **`ceiling = 0` 的来由**：WS-V 把最后三个超限测试文件拆完，
    /// main `2f0e9e0` 上实测 `Sources+Tests 共 159 个 .swift / 超 800 行的 0 个`，
    /// 所以按"只往紧拧"的规矩把 9 降到 0。800 这个**阈值本身一个字没动**（冻结区）。
    ///
    /// 别把这条读成"仓库从此不许有长文件"或"这条测试不再需要债"：它只管**不新增**。
    /// "工具到底能不能数出超限文件"改由 `SelfScanHugeFileMechanismTests` 用合成夹具
    /// 双向证明（超线的必须被看见、未超线的不得被误报）——上一版守卫把靶子立在
    /// "仓库恰好欠着债"上，债还上了它就假，那是找错对象。
    /// #49 元测试：尺子的归属必须**由目录决定**，不是由我手抄的清单决定。
    /// 双向：目录认的扩展名（含 `.md`）必须被收；目录不认的（`.txt`、无扩展名）必须被排除。
    func testIndependentRulerUsesTheSamePopulationAsTheTool() {
        XCTAssertTrue(Self.isToolScannedExtension("swift"))
        XCTAssertTrue(Self.isToolScannedExtension("md"),
                      "文档也要数：漏了 .md 就是本次回归的根因")
        XCTAssertTrue(Self.isToolScannedExtension("markdown"))
        XCTAssertFalse(Self.isToolScannedExtension("txt"), "目录不收的不得混进分母")
        XCTAssertFalse(Self.isToolScannedExtension(""), "无扩展名文件不是源码")
        // 反向对照：若有人把尺子退回"只数 .swift"，这条就会红。
        let nonSwift = ["md", "markdown", "sh", "py", "rb"].filter(Self.isToolScannedExtension)
        XCTAssertGreaterThan(nonSwift.count, 1, "尺子退化成 swift-only 了")
    }

    func testRepositoryDoesNotGrowMoreHugeFiles() async throws {
        let over = try independentSourceLineCounts()
            .filter { $0.lines > Self.toolHighFileLines }
            .sorted { $0.lines > $1.lines }
        let ceiling = 0
        XCTAssertLessThanOrEqual(over.count, ceiling, """
        新增了 \(over.count) 个超 \(Self.toolHighFileLines) 行的文件（合法上限 \(ceiling) 个，
        当前最大 \(over.first?.lines ?? 0) 行）。
        **闸门不降、阈值不动**——把文件拆开才是修复，改这里的数字不是。

        \(Self.productionSummary(over))
        \(Self.summaryOfTestFiles(over))
        逐个清单（行数 → 该目录现归属 → 路径）：
        \(Self.hugeFileRoster(over))
        """)
    }

    /// **派工单文案的元测试**。`ceiling` 降到 0 之后，仓库干净时那段失败信息
    /// 永远不会被触发——一段没人见过的报错文案，等于没有文案。
    /// 所以直接拿合成清单调用那三个渲染函数，断言它指名道姓：
    /// 路径、行数、归属三者都必须出现，认不出归属的必须显式写"认领"而不是留空。
    func testHugeFileTicketNamesEveryOffender() {
        let sample = [
            GroundTruthFile(path: "/repo/TcoderMonitor/Sources/TcoderMonitor/Services/Code/Wide.swift", lines: 1_500),
            GroundTruthFile(path: "/repo/TcoderMonitor/Tests/TcoderMonitorTests/LogWideTests.swift", lines: 912),
        ]

        let roster = Self.hugeFileRoster(sample)
        XCTAssertTrue(roster.contains("1500"), "派工单必须列出实际行数：\(roster)")
        XCTAssertTrue(roster.contains("912"), "派工单必须列出每一个超限文件，不能只报总数：\(roster)")
        XCTAssertTrue(roster.contains("Wide.swift") && roster.contains("LogWideTests.swift"),
                      "派工单必须给出文件路径：\(roster)")
        XCTAssertTrue(roster.contains("WS-R"), "Services/Code 应归口 WS-R：\(roster)")
        XCTAssertTrue(roster.contains("WS-C"), "Tests/Log* 应归口 WS-C：\(roster)")

        let production = Self.productionSummary([sample[0]])
        XCTAssertTrue(production.contains("生产代码（Sources/）：1 个超限"),
                      "生产/测试必须分栏报数：\(production)")
        XCTAssertTrue(Self.productionSummary([]).contains("已达标"),
                      "生产代码干净时要如实说达标，别只报个 0")
        XCTAssertTrue(Self.summaryOfTestFiles([sample[1]]).contains("测试代码（Tests/）：1 个超限"),
                      "测试文件的超限要单独归栏：\(Self.summaryOfTestFiles([sample[1]]))")

        // 认不出归属时不许留空——空字符串会让派工单看起来像"没人欠债"。
        let stranger = Self.owner(ofPath: "/repo/TcoderMonitor/Misc/WhoOwnsThis.swift")
        XCTAssertTrue(stranger.contains("认领") || stranger.contains("未归属"),
                      "认不出归属必须显式标注，不能返回空串：\"\(stranger)\"")
    }

    // MARK: - 防作弊门 3：复杂度榜不得为空，且必须覆盖独立数出的高复杂度函数

    func testComplexityHotspotRankingIsPopulated() async throws {
        let metrics = try await selfScan().code
        let hotspots = metrics.topComplexFunctions
        XCTAssertFalse(hotspots.isEmpty, "扫自己的仓库却一个热点函数都没有，说明复杂度引擎没接上")
        XCTAssertTrue(hotspots.allSatisfy { $0.cyclomaticComplexity >= 1 },
                      "热点函数复杂度必须 ≥1")
        if let top = hotspots.max(by: { $0.cyclomaticComplexity < $1.cyclomaticComplexity }) {
            // **翻正**（2026-09-21 收官轮）：原先钉的是「榜最高值 ≥ \(Self.complexFunctionBar)」，
            // 前提是本仓确实存在 CC≥16 的函数。四路把全仓 54 个拆到 0 个之后，
            // 那条前提消失了——再留着就成了**要求仓库必须保持差**（本仓规矩：缺陷被修好时
            // 要把留档断言反转成正确断言，而不是删掉，也不许反过来改实现迁就断言）。
            // 换成不依赖债务存在、且更强的等价式：榜最高值必须等于独立普查的最高 CC。
            let censusMax = try await independentMaxComplexity()
            XCTAssertEqual(top.cyclomaticComplexity, censusMax,
                           "榜单最高值与独立普查的最高 CC 不等：榜 \(top.cyclomaticComplexity) vs 普查 \(censusMax)")
            XCTAssertGreaterThanOrEqual(censusMax, 1, "一个函数都没认出 CC 来，说明引擎空转")
        }
        let count = hotspots.filter { $0.cyclomaticComplexity >= Self.complexFunctionBar }.count
        print("【复杂度榜】榜单 \(hotspots.count) 个，≥\(Self.complexFunctionBar) 的 \(count) 个，"
            + "全仓均复杂度 \(metrics.averageCyclomaticComplexity.map { String(format: "%.2f", $0) } ?? "nil")"
            + "（分母 \(metrics.analyzedFunctionCount)）")
    }

    /// 独立数一遍全仓最高圈复杂度：绕开 `topComplexFunctions` 这条生产路径，
    /// 直接走 `SourceTreeScanner` + `ComplexityEngine`（与自扫同一个引擎，但不经榜单截断）。
    private func independentMaxComplexity() async throws -> Int {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // 仓库根
        let scanned = await SourceTreeScanner(options: .default).scan(root: root)
        let all = scanned.files.flatMap { ComplexityEngine.functions(in: $0) }
        XCTAssertGreaterThan(all.count, 1000, "函数识别退化：只认出 \(all.count) 个函数")
        return all.map(\.complexity).max() ?? 0
    }

    // MARK: - 防作弊门 4：Git 结论必须与 git 命令**同口径**对得上

    /// 上一版这条**断言本身是错的**：它拿"作者和 ≥ 含 merge 全量"比，
    /// 把一个完全正确的结果（作者和 44 == 非合并全量 44）判成"漏计 10 人"，
    /// 而那 10 个其实是 merge 提交——分析器跑的一贯是 `git log --no-merges`。
    /// 现在两侧各按自己口径比，并额外钉住"含 merge 与不含 merge 是两个量"。
    func testGitSelfReportMatchesGitGroundTruth() async throws {
        let scan = try await selfScan()
        let git = scan.git
        XCTAssertTrue(git.isRepository, "工作树的 .git 是个 gitdir 文件，工具必须照样认出来")

        // 真值取自**与扫描同一快照**（`SelfScan.gitTruth`）——
        // 原来在这里现取，别的流一合 main 就会造成假红，机制与数字写在
        // `SelfScanHarness.measureGitTruth` 的注释里。
        let allCount = scan.gitTruth.all
        let nonMergeCount = scan.gitTruth.nonMerge
        let mergeCount = scan.gitTruth.merges

        XCTAssertEqual(git.totalCommits, allCount,
                       "totalCommits 必须等于 `git rev-list --count HEAD`（含 merge）")

        // 作者榜的正确基线是**非合并**口径，而且必须和分析器自己声明的窗口自洽。
        let authorSum = git.authors.reduce(0) { $0 + $1.commits }
        XCTAssertEqual(authorSum, git.commitsAnalyzed,
                       "每个被解析的提交都恰有一位作者：作者和 \(authorSum) 应等于 commitsAnalyzed "
                     + "\(git.commitsAnalyzed)；对不上才是真的漏人")
        XCTAssertLessThan(git.commitsAnalyzed, ShellGitAnalyzer.maxCommits,
                          "窗口上限 \(ShellGitAnalyzer.maxCommits) 用尽，下面的全量对齐不再成立")
        XCTAssertEqual(git.commitsAnalyzed, nonMergeCount,
                       "窗口没被用满时，commitsAnalyzed 必须等于 `rev-list --count --no-merges HEAD`")

        // 含 merge 与不含 merge 必须分开：谁冒充谁都会撞这里。
        XCTAssertEqual(allCount - nonMergeCount, mergeCount,
                       "含 merge 与非 merge 之差必须正好等于 merge 提交数")
        XCTAssertGreaterThan(mergeCount, 0,
                             "本仓库历史里有 merge 提交；若为 0，说明夹具形态变了，本门的意义要重新评估")

        let top = git.authors.max { $0.commits < $1.commits }
        let share = Double(top?.commits ?? 0) / Double(max(1, authorSum))
        print("【Git 自检】仓库根=\(git.resolvedRepositoryRoot ?? "nil") 模式=\(git.discoveryMode.rawValue) "
            + "含merge=\(git.totalCommits) 非merge=\(git.commitsAnalyzed) merge=\(mergeCount) "
            + "作者=\(git.authors.count) 最大占比=\(String(format: "%.0f%%", share * 100)) "
            + "BusFactor风险=\(git.busFactorRisk.rawValue) 截断旗=\(git.historyTruncated)")

        // 复核 WS-C 那句 "单一作者承担 72% 提交"：基线同样只认非合并 + 邮箱口径。
        let truthShare = scan.gitTruth.topShare
        XCTAssertEqual(share, truthShare, accuracy: 0.01,
                       "工具的作者集中度与 `git log --no-merges --format=%aE` 差 1 个点以上")

        // 钉（WS-B）：`historyTruncated = commitsAnalyzed < totalCommits` 比的是两个口径
        // （非合并窗口 vs 含 merge 全量），于是**只要仓库有 merge 提交它就永远为真**——
        // 而上面刚证明过窗口没被用满、非合并历史已被完整解析（commitsAnalyzed == 非合并全量）。
        // 用户可见的那半已被 WS-L 修好：Git 页的口径横幅走
        // `GitCommitScopeSection.message(for:)`，判据换成 `GitHistoryScope.isWindowTruncated`，
        // 不再读这个被污染的字段——"每个有合并历史的仓库都拉一次警告"已不成立。
        // 这里剩的是**模型字段本身**仍按错判据赋值（`ShellGitAnalyzer.makeInsights`）。
        // WS-B 把它改成真判据（如 commitsAnalyzed >= 窗口上限，或比对
        // `rev-list --count --no-merges HEAD`）之后，请把这里翻正为 XCTAssertFalse。
        XCTAssertTrue(git.historyTruncated,
                      "模型字段不再被 merge 污染了？改成 XCTAssertFalse，"
                    + "并确认横幅配色仍只在 isWindowTruncated 时取 warning")
    }

    // MARK: - 防作弊门 5：评分链路诚实性

    func testHealthScoreComponentsAreHonestOnSelfScan() async throws {
        let scan = try await selfScan()
        let score = scan.health
        XCTAssertTrue((0...100).contains(score.overall))
        XCTAssertFalse(score.components.isEmpty)
        let weightSum = score.components.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1.0, accuracy: 0.001)
        let recomputed = score.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(score.overall), recomputed, accuracy: 1.0)

        if !scan.coverage.hasData {
            XCTAssertFalse(score.components.contains { $0.name.contains("覆盖") },
                           "无覆盖率数据时不得按 0 分惩罚")
        }
        let worst = score.components.min { $0.score < $1.score }
        print("【评分自检】总分=\(score.overall) 等级=\(score.grade.rawValue) "
            + "拖后腿维度=\(worst?.name ?? "无")(\(worst?.score ?? 0))")
    }

    // MARK: - 取证落盘

    /// SwiftPM 在测试进程收尾时会丢掉 stdout 的后半段（实测 65 行的转储只剩前 20 行，
    /// 连后面的短行一起没了）。取证证据漏行比刷屏严重得多，所以完整转储写文件，
    /// 终端只留一行指针 + 各条防作弊门的单行结论。
    private static let evidenceURL = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("tcoder-wsj-selfscan-evidence.txt")

    private func writeEvidence(_ text: String) throws {
        let url = Self.evidenceURL
        if FileManager.default.fileExists(atPath: url.path),
           let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(text.data(using: .utf8) ?? Data())
            try handle.close()
        } else {
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - 完整证据转储

    func testFullSelfScanEvidenceDump() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TCODER_SELF_SCAN"] == "1",
                          "完整转储需显式开启：TCODER_SELF_SCAN=1")
        // 每次跑都从干净文件开始，免得上一轮的尾巴混进这一轮。
        try? FileManager.default.removeItem(at: Self.evidenceURL)
        let scan = try await selfScan()
        let truth = try independentSwiftLineCounts()
        let root = Self.repoRoot.path
        var lines: [String] = []
        func emit(_ text: String) { lines.append(text) }
        // WS-X3 拆分：本函数原判 CC 16 / 116 行，十个章节的渲染各成一个方法；
        // 每章的 emit 文本逐字未改（同一份输入下第 1/2/5~9 节的输出与拆分前逐行相同）。
        emit("\n======== Tcoder 自食其果：扫自己 ========")
        emit("扫描根目录：\(root)")
        try emitCodeScaleAndDuplicationSections(scan, root: root, into: &lines, truth: truth)
        try emitHugeFileAndHotspotSections(scan, root: root, into: &lines)
        try emitLogAndDependencySections(scan, root: root, into: &lines)
        try emitCoverageAndGitSections(scan, root: root, into: &lines)
        try emitHealthSection(scan, root: root, into: &lines)
        try await emitComplexityCensusSection(scan, root: root, into: &lines, truth: truth)
        emit("==========================================")
        try writeEvidence(lines.joined(separator: "\n") + "\n")
        print("【取证落盘】\(Self.evidenceURL.path)（\(lines.count) 行）")
    }

}
