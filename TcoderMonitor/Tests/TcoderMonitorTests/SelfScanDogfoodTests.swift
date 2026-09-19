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

    private func hugeFilePaths(in metrics: CodeMetrics) -> Set<String> {
        Set(metrics.hugeFiles.map { URL(fileURLWithPath: $0.path).path })
    }

    // MARK: - 防作弊门 1：超限文件必须被工具自己报出来

    func testEveryFileOverHighLineBarIsReportedByTheToolItself() async throws {
        let metrics = try await selfScan().code
        let reported = hugeFilePaths(in: metrics)
        let over = try independentSwiftLineCounts().filter { $0.lines > Self.toolHighFileLines }

        XCTAssertFalse(over.isEmpty,
                       "本仓库有 \(Self.toolHighFileLines) 行以上的 Swift 文件是既定事实，若为空说明口径变了")
        let missed = over.filter { !reported.contains($0.path) }.map { "\($0.path)(\($0.lines) 行)" }
        XCTAssertTrue(missed.isEmpty, """
        工具没有把超限文件报进 hugeFiles，等于自我失明。漏报：\(missed.sorted().joined(separator: ", "))
        """)

        let overThousand = over.filter { $0.lines > Self.thousandLineBar }
        print("【防作弊门】独立数出的超限文件 \(over.count) 个（其中 >\(Self.thousandLineBar) 行 \(overThousand.count) 个），"
            + "工具 hugeFiles 报 \(metrics.hugeFiles.count) 个，最大 \(metrics.largestFileLineCount) 行")
    }

    // MARK: - 防作弊门 2：行数只降不升（dogfooding 棘轮）

    /// 这是"分数必须自己变好"的机械保证：新增一个 800+ 行文件会让这条测试变红。
    /// 把某个文件改小的人应当**同时**把下面的上限调低——棘轮只许往紧里拧。
    func testRepositoryDoesNotGrowMoreHugeFiles() async throws {
        let over = try independentSwiftLineCounts()
            .filter { $0.lines > Self.toolHighFileLines }
            .sorted { $0.lines > $1.lines }
        let ceiling = 9
        XCTAssertLessThanOrEqual(over.count, ceiling, """
        800 行以上的文件从 \(ceiling) 个涨到了 \(over.count) 个（当前最大 \(over.first?.lines ?? 0) 行）。
        **闸门不降、基线不改**——还债方式是各自拆自己那份，不是把这条改绿。

        \(Self.productionSummary(over))
        \(Self.testFileSummary(over))
        逐个清单（行数 → 该目录现归属 → 路径）：
        \(Self.hugeFileRoster(over))
        """)
    }

    // MARK: - 超限文件归人（只用于失败信息，不参与判定）

    /// 第二轮（`AGENTS.md` §7 + 总工派工）把目录重切了一遍，所以按**现归属**报：
    /// `Services/Health|Code|Logs`→WS-R、`Services/Dependencies`→WS-N、`Services/Performance`→WS-C、
    /// `Views/Root|ProjectDetail|Dashboard`→WS-K、`Views/Code|Git|Dependencies|CodeGit`→WS-L、
    /// `Views/Performance|Logs|Health|PerfLogs`→WS-M、`Design/**`+`App/Theme.swift`→WS-G。
    private static func owner(ofPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        if splitByWSV.contains(name) {
            return "WS-V（本轮派拆；原文归 \(legacyOwner(ofPath: path))）"
        }
        return legacyOwner(ofPath: path)
    }

    /// 总工 2026-09-19 派给 WS-V 拆的测试文件名单。
    private static let splitByWSV: Set<String> = [
        "ManifestLabFixtureTests.swift", "HealthScoreTests.swift",
        "LogAnalysisTests.swift", "GitDependencyTests.swift",
    ]

    private static func legacyOwner(ofPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        // 测试文件按 `AGENTS.md` §3 写在纸面上的 glob 归口（第二轮只重切了
        // Services/ 与 Views/，Tests/ 仍按原表），别拿目录规则去猜。
        if name.hasSuffix("Tests.swift") {
            if name.hasPrefix("Code") { return "WS-A（Tests/Code*）" }
            if name.hasPrefix("Git") || name.hasPrefix("Dependency") { return "WS-B（Tests/Git*|Dependency*）" }
            if name.hasPrefix("Log") || name.hasPrefix("Health") || name.hasPrefix("Performance") {
                return "WS-C（Tests/Log*|Health*|Performance*）"
            }
            return "Tests/ 未命中 glob·报总工认领"
        }
        switch true {
        case path.contains("/Sources/TcoderMonitor/Models/"), name == "Package.swift",
             name == "AppState.swift", name == "TcoderMonitorApp.swift",
             name == "ServiceContracts.swift", name == "ProjectStore.swift",
             name == "SharedUtilities.swift", name == "DemoData.swift":
            return "总工（冻结区）"
        case name == "Theme.swift", path.contains("/Sources/TcoderMonitor/Design/"):
            return "WS-G"
        case name == "RootView.swift", name == "ProjectDetailView.swift", name == "DashboardView.swift":
            return "WS-K"
        case path.contains("/Views/Code/"), path.contains("/Views/Git/"),
             path.contains("/Views/Dependencies/"), path.contains("/Views/CodeGit/"):
            return "WS-L"
        case path.contains("/Views/Performance/"), path.contains("/Views/Logs/"),
             path.contains("/Views/Health/"), path.contains("/Views/PerfLogs/"):
            return "WS-M"
        case path.contains("/Services/Health/"), path.contains("/Services/Code/"),
             path.contains("/Services/Logs/"):
            return "WS-R"
        case path.contains("/Services/Dependencies/"):
            return "WS-N"
        case path.contains("/Services/Performance/"):
            return "WS-C"
        case path.contains("/Services/Coverage/"):
            return "WS-J（本流，唯一无主 Services 文件）"
        case path.contains("/scripts/"):
            return "WS-E（脚本）"
        default:
            return "未归属（报总工认领）"
        }
    }

    /// 生产代码与测试代码分栏：只看一个合并数字，会分不清"产品又堆坨了"
    /// 还是"测试文件待拆"——这两件事的责任人和紧迫度完全不同。
    private static func productionSummary(_ over: [GroundTruthFile]) -> String {
        let production = over.filter { $0.path.contains("/Sources/") }
        guard !production.isEmpty else { return "生产代码（Sources/）：0 个超限，已达标" }
        return "生产代码（Sources/）：\(production.count) 个超限 —— \(tally(production))"
    }

    private static func testFileSummary(_ over: [GroundTruthFile]) -> String {
        let tests = over.filter { !$0.path.contains("/Sources/") }
        guard !tests.isEmpty else { return "测试代码（Tests/）：0 个超限" }
        return "测试代码（Tests/）：\(tests.count) 个超限 —— \(tally(tests))"
    }

    private static func tally(_ files: [GroundTruthFile]) -> String {
        Dictionary(grouping: files, by: { owner(ofPath: $0.path) })
            .map { "\($0.key) \($0.value.count) 个" }
            .sorted()
            .joined(separator: " · ")
    }

    private static func hugeFileRoster(_ over: [GroundTruthFile]) -> String {
        let root = Self.repoRoot.path
        return over.map { file in
            let relative = file.path.hasPrefix(root)
                ? String(file.path.dropFirst(root.count + 1)) : file.path
            return "  \(String(format: "%5d", file.lines)) 行 → \(owner(ofPath: file.path))\t\(relative)"
        }.joined(separator: "\n")
    }

    // MARK: - 防作弊门 3：复杂度榜不得为空，且必须覆盖独立数出的高复杂度函数

    func testComplexityHotspotRankingIsPopulated() async throws {
        let metrics = try await selfScan().code
        let hotspots = metrics.topComplexFunctions
        XCTAssertFalse(hotspots.isEmpty, "扫自己的仓库却一个热点函数都没有，说明复杂度引擎没接上")
        XCTAssertTrue(hotspots.allSatisfy { $0.cyclomaticComplexity >= 1 },
                      "热点函数复杂度必须 ≥1")
        if let top = hotspots.max(by: { $0.cyclomaticComplexity < $1.cyclomaticComplexity }) {
            XCTAssertGreaterThanOrEqual(top.cyclomaticComplexity, Self.complexFunctionBar,
                                        "本仓库存在复杂度 ≥\(Self.complexFunctionBar) 的函数，榜单最高值不该低于它")
        }
        let count = hotspots.filter { $0.cyclomaticComplexity >= Self.complexFunctionBar }.count
        print("【复杂度榜】榜单 \(hotspots.count) 个，≥\(Self.complexFunctionBar) 的 \(count) 个，"
            + "全仓均复杂度 \(metrics.averageCyclomaticComplexity.map { String(format: "%.2f", $0) } ?? "nil")"
            + "（分母 \(metrics.analyzedFunctionCount)）")
    }

    // MARK: - 防作弊门 4：Git 结论必须与 git 命令**同口径**对得上

    /// 上一版这条**断言本身是错的**：它拿"作者和 ≥ 含 merge 全量"比，
    /// 把一个完全正确的结果（作者和 44 == 非合并全量 44）判成"漏计 10 人"，
    /// 而那 10 个其实是 merge 提交——分析器跑的一贯是 `git log --no-merges`。
    /// 现在两侧各按自己口径比，并额外钉住"含 merge 与不含 merge 是两个量"。
    func testGitSelfReportMatchesGitGroundTruth() async throws {
        let git = try await selfScan().git
        XCTAssertTrue(git.isRepository, "工作树的 .git 是个 gitdir 文件，工具必须照样认出来")

        let allCount = try revListCount([])
        let nonMergeCount = try revListCount(["--no-merges"])
        let mergeCount = try revListCount(["--merges"])

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
        let truthShare = try independentTopAuthorShare()
        XCTAssertEqual(share, truthShare, accuracy: 0.01,
                       "工具的作者集中度与 `git log --no-merges --format=%aE` 差 1 个点以上")

        // 钉（WS-B）：`historyTruncated = commitsAnalyzed < totalCommits` 比的是两个口径
        // （非合并窗口 vs 含 merge 全量），于是**只要仓库有 merge 提交它就永远为真**——
        // 而上面刚证明过窗口没被用满、非合并历史已被完整解析（commitsAnalyzed == 非合并全量）。
        // 后果是 Git 页对每个有合并历史的仓库都拉一次警告横幅：
        // `GitInsightsView.swift:82-87`「提交统计只覆盖最近 N 条…不代表全部历史」。
        // WS-B 改成真判据（如 commitsAnalyzed >= 窗口上限，或比对
        // `rev-list --count --no-merges HEAD`）之后，请把这里翻正为 XCTAssertFalse。
        XCTAssertTrue(git.historyTruncated,
                      "截断旗不再被 merge 污染了？改成 XCTAssertFalse，"
                    + "并确认 GitInsightsView.swift:82 的横幅只在真截断时出现")
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
        func rel(_ path: String) -> String {
            path.hasPrefix(root) ? String(path.dropFirst(root.count + 1)) : path
        }
        emit("\n======== Tcoder 自食其果：扫自己 ========")
        emit("扫描根目录：\(root)")

        emit("—— 1. 代码规模 ——")
        let code = scan.code
        emit([
            "分析器口径 文件=\(code.totalFiles) 总行=\(code.totalLines) 有效码=\(code.codeLines) "
                + "注释=\(code.commentLines) 空行=\(code.blankLines) 耗时=\(code.durationMs)ms",
        ].joined(separator: " "))
        emit("独立口径 .swift 文件=\(truth.count) 行=\(truth.reduce(0) { $0 + $1.lines })")
        emit("语言分布：\(code.languages.prefix(6).map { "\($0.language)=\($0.lineCount)行/\($0.fileCount)个" }.joined(separator: " "))")
        emit("TODO=\(code.todoCount) FIXME=\(code.fixmeCount) 长函数(>\(FileSystemCodeAnalyzer.longFunctionThreshold))=\(code.longFunctions) 平均函数长=\(code.averageFunctionLength)")
        emit("整体风险=\(code.overallRisk.rawValue)")

        emit("—— 2. 重复率 ——")
        emit(String(format: "duplicationRatio=%.4f 重复块=%d", code.duplicationRatio, code.duplicatedBlocks.count))
        for block in code.duplicatedBlocks.prefix(10) {
            let paths = block.occurrences.map { "\($0.path):\(($0.startLine))" }.joined(separator: " ↔ ")
            emit("  重复 \(block.lineCount) 行 相似=\(String(format: "%.2f", block.similarity)) \(paths)")
        }

        emit("—— 3. 巨大文件榜 ——")
        for file in code.hugeFiles {
            let rel = file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count + 1)) : file.path
            emit("  \(file.lineCount)行 [\(file.risk.rawValue)] \(rel)")
            emit("      建议：\(file.suggestion)")
        }

        emit("—— 4. 高圈复杂度函数 Top 榜 ——")
        for hotspot in code.topComplexFunctions {
            let rel = hotspot.filePath.hasPrefix(root) ? String(hotspot.filePath.dropFirst(root.count + 1)) : hotspot.filePath
            emit("  CC=\(hotspot.cyclomaticComplexity) [\(hotspot.risk.rawValue)] \(rel):\(hotspot.startLine) "
                + "\(hotspot.name)（\(hotspot.lineCount) 行，\(hotspot.parameterCount) 参）")
        }

        emit("—— 5. 日志分析 ——")
        let logs = scan.logs
        emit("hasData=\(logs.hasData) 扫文件=\(logs.scannedFiles.count) 总行=\(logs.totalLinesScanned) "
            + "error=\(logs.errorCount) exception=\(logs.exceptionCount) warning=\(logs.warningCount) "
            + "crash=\(logs.crashCount) fatal=\(logs.fatalCount) 风险=\(logs.overallRisk.rawValue)")
        for cluster in logs.topErrors.prefix(5) {
            emit("  \(cluster.severity.rawValue) ×\(cluster.count) \(cluster.signature)")
        }

        emit("—— 6. 依赖 ——")
        let deps = scan.dependencies
        emit("生态=\(deps.distinctEcosystemNames) 依赖总数=\(deps.totalDependencies) "
            + "生产=\(deps.productionCount) 开发=\(deps.devCount) 过期=\(deps.outdatedCount) "
            + "漏洞=\(deps.vulnerableCount) 风险=\(deps.riskLevel.rawValue) 联网=\(deps.networkLookupPerformed)")
        for eco in deps.ecosystems {
            emit("  \(eco.ecosystem.displayName) 清单=\(eco.manifestPath) lock=\(eco.lockfileName ?? "无") "
                + "依赖=\(eco.dependencies.count) 标记=\(eco.frameworkMarkers)")
        }
        for dep in deps.ecosystems.flatMap(\.dependencies).prefix(15) {
            emit("    \(dep.name) \(dep.version) [\(dep.scope.rawValue)] 最新=\(dep.latestKnownVersion ?? "nil") 来源=\(dep.versionCheckSource.rawValue)")
        }
        for advisory in deps.advisories.prefix(5) {
            emit("  漏洞 \(advisory.id) [\(advisory.severity.rawValue)] \(advisory.summary)")
        }
        if !deps.networkLookupNote.isEmpty { emit("  联网说明：\(deps.networkLookupNote)") }

        emit("—— 7. 覆盖率 ——")
        emit("hasData=\(scan.coverage.hasData) 报告数=\(scan.coverage.reports.count) 扫描文件=\(scan.coverage.scannedFileCount) "
            + "行覆盖=\(scan.coverage.overallLinePercent.map { String(format: "%.1f%%", $0) } ?? "nil")")
        for report in scan.coverage.reports.prefix(5) {
            emit("  \(report.toolName) [\(report.kind.rawValue)] \(report.linesCovered)/\(report.linesTotal) @\(report.path)")
        }

        emit("—— 8. Git ——")
        let git = scan.git
        emit("isRepo=\(git.isRepository) 模式=\(git.discoveryMode.rawValue) 根=\(git.resolvedRepositoryRoot ?? "nil") "
            + "分支=\(git.branch) 提交=\(git.totalCommits)(窗口 \(git.commitsAnalyzed) 截断=\(git.historyTruncated)) "
            + "增删=+\(git.totalAdditions)/-\(git.totalDeletions) 年龄=\(git.projectAgeDays)天")
        for author in git.authors {
            emit("  \(author.name) <\(author.email)> 提交=\(author.commits) +\(author.additions)/-\(author.deletions) 风险=\(git.busFactorRisk.rawValue)")
        }

        emit("—— 9. 健康评分与全部分量 ——")
        let health = scan.health
        emit("总分=\(health.overall) 等级=\(health.grade.rawValue)")
        for component in health.components {
            emit("  \(component.name) 分=\(component.score) 权重=\(String(format: "%.3f", component.weight)) "
                + "贡献=\(String(format: "%.1f", component.weightedContribution)) 风险=\(component.risk.rawValue)")
            emit("      \(component.detail)")
        }
        emit("总评：\(health.narrative)")
        emit("优势：\(health.strengths)")
        emit("问题：\(health.issues)")
        emit("建议：\(health.recommendations)")

        let census = try await complexityCensus()
        emit("—— 10. 普查 vs 榜单（绕开 prefix(20) 自己数）——")
        emit("全仓函数 \(census.functionCount) 个，全仓均复杂度 \(String(format: "%.2f", census.repoMean))，"
            + "≥\(Self.complexFunctionBar) 的 \(census.atLeast16) 个，≥21 的 \(census.atLeast21) 个，"
            + "≥31 的 \(census.atLeast31) 个，最高 \(census.maxValue)")
        emit("榜单 topComplexFunctions 只留 \(scan.code.topComplexFunctions.count) 条（被 prefix(20) 截断），"
            + "其均值 \(String(format: "%.1f", census.hotspotMean)) ← 评分现在用的就是这个数")
        emit("独立口径 >\(Self.toolHighFileLines) 行的 .swift 文件 \(truth.filter { $0.lines > Self.toolHighFileLines }.count) 个，"
            + ">1000 行 \(truth.filter { $0.lines > Self.thousandLineBar }.count) 个")
        emit("==========================================")
        try writeEvidence(lines.joined(separator: "\n") + "\n")
        print("【取证落盘】\(Self.evidenceURL.path)（\(lines.count) 行）")
    }
}
