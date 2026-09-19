import XCTest
@testable import TcoderMonitor

/// OWNER: WS-J 自食其果（dogfooding）。类型名不匹配 WS-A/B/C 的任何 glob，也不在冻结区。
///
/// 目的：把 Tcoder 的六个分析器对准 **Tcoder 自己**，用它自己报出的结论决定我们先修什么。
/// 一个自称能识别巨大文件与高圈复杂度的工具，如果对自己的坨不报警，它的结论就没有可信度。
///
/// 为什么阈值在这里写成**字面量**而不是引用 `FileSystemCodeAnalyzer.highFileLines`：
/// 一旦有人把阈值抬高来"把分数刷上去"，超限清单会立刻变小、本文件当场变红。
/// 这是自食其果的防作弊门，不是普通回归测试。**改这些字面量必须先向总工说明理由。**
///
/// 完整证据转储默认跳过（避免刷屏同事的测试轮次），开法：
///   TCODER_SELF_SCAN=1 ./scripts/locked_build.sh test
final class SelfScanDogfoodTests: XCTestCase {

    // MARK: - 冻结的复检口径（不得为了变好看而修改）

    /// 工具自己的 `FileSystemCodeAnalyzer.highFileLines`，此处按字面量复检。
    private static let toolHighFileLines = 800
    /// "巨大文件" 的常识线：四位数行数的单文件没有任何辩护空间。
    private static let thousandLineBar = 1_000
    /// WS-C 报过 "20 个函数圈复杂度 ≥ 16"，按同一口径复检。
    private static let complexFunctionBar = 16

    /// 本仓库根：从测试文件自身位置往上三层
    /// （Tests/TcoderMonitorTests/本文件 → TcoderMonitor → 工作树根）。
    /// 用 `#filePath` 而不是硬编码绝对路径：这样主树和各 worktree 都能跑。
    private static let repoRoot: URL = {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // TcoderMonitorTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // TcoderMonitor
            .deletingLastPathComponent()   // 工作树根
    }()

    private static let skipDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", "dist", "build", "node_modules", ".worktrees",
    ]

    // MARK: - 一次性扫描缓存（六个分析器都跑一遍，多个测试复用）

    private struct SelfScan {
        var code: CodeMetrics
        var git: GitInsights
        var logs: LogSummary
        var dependencies: DependencyReport
        var coverage: CoverageMetrics
        var health: HealthScore
    }

    private static let cacheStore = ScanCacheStore()

    /// 用 actor 而不是 NSLock 做缓存门：`NSLock.lock()` 在 async 上下文里不可用。
    private actor ScanCacheStore {
        private var cached: SelfScan?

        func value(orMake make: @Sendable () async throws -> SelfScan) async rethrows -> SelfScan {
            if let cached { return cached }
            let fresh = try await make()
            cached = fresh
            return fresh
        }
    }

    private func selfScan() async throws -> SelfScan {
        try await Self.cacheStore.value {
            let root = Self.repoRoot
            let code = try await FileSystemCodeAnalyzer().analyze(root: root, options: .default)
            let git = try await ShellGitAnalyzer().analyze(repositoryURL: root)
            let logs = try await FileLogAnalyzer()
                .analyze(projectRoot: root, extraLogURLs: [], withinDays: 30)
            let dependencies = try await ManifestDependencyAnalyzer()
                .analyze(projectRoot: root, allowNetwork: false)
            let coverage = try await CoverageAnalyzer().analyze(projectRoot: root, options: .default)
            let health = WeightedHealthScorer().score(
                HealthInputs(code: code, git: git, logs: logs,
                             dependencies: dependencies, coverage: coverage))

            return SelfScan(code: code, git: git, logs: logs,
                            dependencies: dependencies, coverage: coverage, health: health)
        }
    }

    // MARK: - 独立取证：不依赖任何分析器，自己数行数

    private struct GroundTruthFile {
        var path: String
        var lines: Int
    }

    /// 自己走一遍目录树，按换行数数 `.swift` 文件行数。
    /// 与分析器无关，所以分析器漏文件 / 抬阈值都会被这里抓到。
    ///
    /// 手写递归而不是 `enumerator(at:)`：`FileManager.DirectoryEnumerator` 没有
    /// `skipSubtree`，而剪枝必须发生在下潜之前，否则会把 `.build` 整个走一遍。
    private func independentSwiftLineCounts() throws -> [GroundTruthFile] {
        var result: [GroundTruthFile] = []
        try collectSwiftFiles(in: Self.repoRoot, into: &result)
        return result
    }

    private func collectSwiftFiles(in directory: URL, into result: inout [GroundTruthFile]) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        )
        for url in children.sorted(by: { $0.path < $1.path }) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                guard !Self.skipDirectoryNames.contains(url.lastPathComponent) else { continue }
                try collectSwiftFiles(in: url, into: &result)
                continue
            }
            guard values.isRegularFile == true, url.pathExtension == "swift" else { continue }
            guard let data = fm.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else { continue }
            // 与分析器同口径：按换行切分，行数 = 段数（末段可为空行）。
            let lines = text.components(separatedBy: "\n").count
            result.append(GroundTruthFile(path: url.path, lines: lines))
        }
    }

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
        let over = try independentSwiftLineCounts().filter { $0.lines > Self.toolHighFileLines }
        let ceiling = 9
        XCTAssertLessThanOrEqual(over.count, ceiling, """
        800 行以上的文件从 \(ceiling) 个涨到了 \(over.count) 个：
        \(over.sorted { $0.lines > $1.lines }.map { "\($0.path):\($0.lines)" }.joined(separator: "\n"))
        新代码不要再堆成巨大文件；若你刚拆掉一个，请把 ceiling 一起调低。
        """)
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

    // MARK: - 独立复核：绕开 top-20 截断，数全量函数

    private struct ComplexityCensus {
        var functionCount: Int
        var repoMean: Double
        var atLeast16: Int
        var atLeast21: Int
        var atLeast31: Int
        var maxValue: Int
        var hotspotMean: Double
    }

    /// 自己调 `ComplexityEngine` 把**全仓每个函数**过一遍。
    /// 这是为了复核一句要进汇报的话："20 个函数圈复杂度 ≥ 16"。
    /// `topComplexFunctions` 被 `prefix(20)` 截断过，所以它的条数既可能是巧合，
    /// 也可能是"只数了榜单"——只有去截断之外数才知道。
    private func complexityCensus() async throws -> ComplexityCensus {
        let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
        let all = files.map { ComplexityEngine.functions(in: $0) }.flatMap { $0 }
        let complexities = all.map(\.complexity)
        let sum = complexities.reduce(0, +)
        let hotspots = all.filter { $0.complexity >= Self.complexFunctionBar }
            .sorted { $0.complexity > $1.complexity }
            .prefix(20)
            .map(\.complexity)
        return ComplexityCensus(
            functionCount: all.count,
            repoMean: all.isEmpty ? 0 : Double(sum) / Double(all.count),
            atLeast16: complexities.filter { $0 >= 16 }.count,
            atLeast21: complexities.filter { $0 >= 21 }.count,
            atLeast31: complexities.filter { $0 >= 31 }.count,
            maxValue: complexities.max() ?? 0,
            hotspotMean: hotspots.isEmpty ? 0 : Double(hotspots.reduce(0, +)) / Double(hotspots.count)
        )
    }

    /// **缺陷钉住测试**：断言的是"现在还错着"这件事，不是"这样对"。
    /// 每条断言失败信息里都写清了修复后应当改成什么——负责的工作流改完，
    /// 这条测试会红，逼他把断言翻正，而不是让缺陷悄悄回潮。
    func testKnownSelfScanDefectsArePinned() async throws {
        let scan = try await selfScan()
        let census = try await complexityCensus()

        // 钉 1（WS-A）：FileSystemCodeAnalyzer 从不给这两个字段赋值，
        // 于是 e676fad 声称的"改用全仓平均圈复杂度"在真实扫描里永远走不到。
        XCTAssertEqual(scan.code.analyzedFunctionCount, 0,
                       "WS-A 已经会填 analyzedFunctionCount 了？很好，请把本断言改成："
                     + "XCTAssertEqual(code.analyzedFunctionCount, census.functionCount) 并删掉这句注释。")
        XCTAssertNil(scan.code.averageCyclomaticComplexity,
                     "WS-C 修好评分口径、WS-A 填上均值后请把本断言改为 "
                     + "XCTAssertEqual(code.averageCyclomaticComplexity!, census.repoMean, accuracy: 0.01)")

        // 钉 2（WS-C）：复杂度维度自称用全仓均值，实际用热点样本均值。
        let complexity = scan.health.components.first { $0.name.contains("复杂度") }
        XCTAssertNotNil(complexity, "复杂度维度必须存在（它现在的存在方式是缺陷）")
        XCTAssertTrue(complexity?.detail.contains("热点样本") == true,
                      "复杂度维度不再写『热点样本』说明已改用全仓均值，请把本断言翻正为"
                    + " detail 含『全仓』且分数不再依赖 top-20。")

        // 钉 3（产品口径）：榜单被截断到 20，所以"20 个函数 ≥16"这句话不能当作普查。
        XCTAssertEqual(scan.code.topComplexFunctions.count, 20,
                       "榜单条数变了，说明截断口径改了，本测试与汇报里的措辞都要同步")
        XCTAssertGreaterThanOrEqual(census.atLeast16, scan.code.topComplexFunctions.count,
                                    "全量普查不可能少于榜单条数")

        print("【普查 vs 榜单】全仓函数 \(census.functionCount) 个，全仓均复杂度 "
            + String(format: "%.2f", census.repoMean)
            + "，≥16 的 \(census.atLeast16) 个，≥21 的 \(census.atLeast21) 个，≥31 的 \(census.atLeast31) 个，最高 \(census.maxValue)"
            + "；榜单只有 \(scan.code.topComplexFunctions.count) 条、其均值 "
            + String(format: "%.1f", census.hotspotMean))
    }

    // MARK: - 复杂度引擎口径探针（最小可复现夹具，建在 /tmp 下用完即删）

    /// 把只含一种语法的最小函数喂给 `ComplexityEngine`，看它各加几分。
    /// 目的：判定"平均圈复杂度 26.3"里有多少是真实判定，多少是口径通胀。
    func testComplexityEngineBranchCountingConvention() async throws {
        let fixture = #"""
        import Foundation
        func plain() -> Int {
            return 1
        }
        func oneIf(_ flag: Bool) -> Int {
            if flag { return 2 }
            return 1
        }
        func oneNilCoalesce(_ dict: [String: Int]) -> Int {
            return dict["k"] ?? 0
        }
        func failableCast(_ raw: Any) -> Int {
            let box = raw as? [String: Int]
            return box?.count ?? 0
        }
        func oneTernary(_ flag: Bool) -> Int {
            return flag ? 1 : 2
        }
        """#

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-wsj-cc-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("Probe.swift")
        try fixture.write(to: file, atomically: true, encoding: .utf8)

        let files = await SourceTreeScanner(options: .default).scan(root: dir).files
        let measured = ComplexityEngine.functions(in: files[0])
        let byName = Dictionary(uniqueKeysWithValues: measured.map { ($0.name, $0.complexity) })

        func cc(_ name: String) -> Int { byName[name] ?? -1 }
        print("【引擎口径】plain=\(cc("plain")) oneIf=\(cc("oneIf")) "
            + "nilCoalesce=\(cc("oneNilCoalesce")) failableCast=\(cc("failableCast")) "
            + "ternary=\(cc("oneTernary"))")

        XCTAssertEqual(cc("plain"), 1, "无分支函数必须是 1，否则整个榜单口径都不可信")
        XCTAssertEqual(cc("oneIf"), 2, "单个 if 应当 +1")
        XCTAssertEqual(cc("oneNilCoalesce"), 2, "?? 算一次判定；数字变了说明 Swift 口径被动过")
        XCTAssertEqual(cc("oneTernary"), 2, "三元算一次判定，且不重复计数")
        // 这一条是**口径与阈值不匹配**的证据：一个 2 行、线性、无嵌套的函数，
        // 仅仅因为写了 as? / ?. / ?? 就被判 CC=4。`parseIstanbulSummary` 27 行
        // 被测成 CC=24 并打上[高]风险，根因就在这里——阈值 highFunctionComplexity=21
        // 是按经典 McCabe 标定的，而计数口径把可选值语法糖也记成了判定。
        XCTAssertEqual(cc("failableCast"), 4,
                       "as?/?. 与 ?? 各算一次判定。若你收紧了口径，请把本条与 48 号笔记一起更新")
    }

    // MARK: - git 独立基线（只读命令）

    /// `git rev-list --count HEAD`，可带 `--no-merges` / `--merges` 取不同口径。
    private func revListCount(_ filter: [String]) throws -> Int {
        let output = try runGit(["rev-list", "--count"] + filter + ["HEAD"])
        guard let count = Int(output.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw AnalysisError.empty("git rev-list --count \(filter) 输出不可解析：\(output)")
        }
        return count
    }

    /// 按**作者邮箱**独立算最大作者占比：`%aE` + `--no-merges`，与分析器同口径。
    /// 刻意不用 `git shortlog -sn`——那个按**姓名**分组，而本仓库有两个姓名
    /// （`Tcoder Team` 与 `WS-B Git与依赖`）共用 `dev@tcoder.local`。
    /// 用姓名口径量出来的 top 是 68%，工具按邮箱归并给的是 72%，
    /// 差 4 个点会被 5 个点的容差吞掉——等于这条门白设。
    private func independentTopAuthorShare() throws -> Double {
        let output = try runGit(["log", "--no-merges", "--format=%aE", "HEAD"])
        var counts: [String: Int] = [:]
        for line in output.split(separator: "\n") {
            let email = line.trimmingCharacters(in: .whitespaces)
            guard !email.isEmpty else { continue }
            counts[email, default: 0] += 1
        }
        guard let top = counts.values.max(), !counts.isEmpty else { return 0 }
        return Double(top) / Double(counts.values.reduce(0, +))
    }

    private func runGit(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "-C", Self.repoRoot.path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
