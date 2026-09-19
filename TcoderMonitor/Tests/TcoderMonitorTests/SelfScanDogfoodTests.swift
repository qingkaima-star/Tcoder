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
            // 行数按 `wc -l` 的口径数换行符，末尾不成行的一段算一行；
            // 这样三个来源（wc、分析器的 lines.count、这里）能对上同一个数。
            // 早先用 components(separatedBy:"\n").count 会整体 +1，
            // 因为结尾换行会多出一个空段——差 1 行看起来就像两边在量不同的文件。
            let newlines = text.reduce(0) { $1 == "\n" ? $0 + 1 : $0 }
            let lines = text.hasSuffix("\n") ? newlines : newlines + 1
            result.append(GroundTruthFile(path: url.path, lines: lines))
        }
    }

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
        let over = try independentSwiftLineCounts().filter { $0.lines > Self.toolHighFileLines }

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
    func testRepositoryDoesNotGrowMoreHugeFiles() async throws {
        let over = try independentSwiftLineCounts()
            .filter { $0.lines > Self.toolHighFileLines }
            .sorted { $0.lines > $1.lines }
        let ceiling = 9
        XCTAssertLessThanOrEqual(over.count, ceiling, """
        800 行以上的文件从 \(ceiling) 个涨到了 \(over.count) 个（当前最大 \(over.first?.lines ?? 0) 行）。
        **闸门不降、基线不改**——还债方式是各自拆自己那份，不是把这条改绿。
        谁还差几个：\(Self.ownerTally(over))
        逐个清单（行数 → 负责人）：
        \(Self.hugeFileRoster(over))
        """)
    }

    // MARK: - 超限文件归人（只用于失败信息，不参与判定）

    /// 按 `AGENTS.md` §3 的文件所有权表 + 20:38 扩充流表归口。
    /// 只影响"这条红该找谁"的可读性，所以宁可粗也别写错：认不出的一律"未归属"。
    private static func owner(ofPath path: String) -> String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let isTestFile = name.hasSuffix("Tests.swift")
        switch true {
        case path.contains("/Sources/TcoderMonitor/Models/"), name == "Package.swift",
             name == "AppState.swift", name == "TcoderMonitorApp.swift",
             name == "ServiceContracts.swift", name == "ProjectStore.swift",
             name == "SharedUtilities.swift", name == "DemoData.swift",
             name == "RootView.swift", name == "ProjectDetailView.swift", name == "DashboardView.swift",
             name == "RealRepositoryEvidenceTests.swift", name == "ContractRoundTripTests.swift",
             name == "CoverageAnalyzerTests.swift":
            return "总工（冻结区）"
        case name == "Theme.swift", path.contains("/Sources/TcoderMonitor/Design/"):
            return "WS-G"
        case name == "ManifestLabFixtureTests.swift":
            return "WS-F"
        case name.hasPrefix("SelfScan"):
            return "WS-J（本流）"
        case path.contains("/Services/Code/"), path.contains("/Views/Code/"),
             isTestFile && name.hasPrefix("Code"):
            return "WS-A"
        case path.contains("/Services/Git/"), path.contains("/Services/Dependencies/"),
             path.contains("/Views/Git/"), path.contains("/Views/Dependencies/"),
             isTestFile && (name.hasPrefix("Git") || name.hasPrefix("Dependency")):
            return "WS-B"
        case path.contains("/Services/Performance/"), path.contains("/Services/Logs/"),
             path.contains("/Services/Health/"), path.contains("/Views/Performance/"),
             path.contains("/Views/Logs/"), path.contains("/Views/Health/"),
             isTestFile && (name.hasPrefix("Performance") || name.hasPrefix("Log")
                            || name.hasPrefix("Health")):
            return "WS-C"
        case path.contains("/Services/Coverage/"):
            return "WS-J（本流，唯一无主 Services 文件）"
        default:
            return "未归属（报总工认领）"
        }
    }

    private static func hugeFileRoster(_ over: [GroundTruthFile]) -> String {
        over.map { file in
            "  \(String(format: "%5d", file.lines)) 行 → \(owner(ofPath: file.path))\t\(file.path)"
        }.joined(separator: "\n")
    }

    private static func ownerTally(_ over: [GroundTruthFile]) -> String {
        Dictionary(grouping: over, by: { owner(ofPath: $0.path) })
            .map { "\($0.key) \($0.value.count) 个" }
            .sorted()
            .joined(separator: " · ")
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

    /// 自扫复核台。**上半段是已经翻正的历史缺陷**（负责人修好后按约定翻正，
    /// 过程记在 48 号笔记），**下半段是仍在身的缺陷钉**：断言的是"现在还错着"这件事，
    /// 每条失败信息都写清了修好后该改成什么，谁修谁翻正，不让缺陷悄悄回潮。
    func testKnownSelfScanDefectsArePinned() async throws {
        let scan = try await selfScan()
        let census = try await complexityCensus()
        let code = scan.code

        // —— 已翻正 1（WS-A `f55e4a0`）：全仓普查的两个字段终于有生产者了。
        // 基线不是我抄分析器的，而是我自己调 ComplexityEngine 绕开榜单重数一遍。
        XCTAssertEqual(code.analyzedFunctionCount, census.functionCount,
                       "analyzedFunctionCount=\(code.analyzedFunctionCount) 与独立普查 "
                     + "\(census.functionCount) 不一致：要么生产者漏了文件，要么我的走树口径变了")
        XCTAssertNotNil(code.averageCyclomaticComplexity, "有函数可数时全仓均值不得是 nil")
        XCTAssertEqual(code.averageCyclomaticComplexity!, census.repoMean, accuracy: 0.01,
                       "全仓均复杂度与独立普查对不上（测得 "
                     + "\(code.averageCyclomaticComplexity ?? -1) vs 普查 \(census.repoMean)）")

        // —— 已翻正 2（WS-C + WS-A）：复杂度维度不再拿 top-20 热点均值冒充全仓水位。
        // 校法刻意**不碰数字字面量**：detail 把 4.098 写成 "4" 还是 "4.1" 是格式化选择，
        // 拿字符串去比小位数等于用测试绑架实现格式（上一轮就是这么红的：断言 "4.0"，
        // 而实现如实给出 "4"）。改成三层，各管一件事。
        let complexity = try XCTUnwrap(scan.health.components.first { $0.name.contains("复杂度") },
                                       "复杂度维度必须存在")

        // ① 校**口径声明**：均值必须自称全仓，且不得再出现"热点样本"。
        XCTAssertTrue(complexity.detail.contains("全仓"),
                      "复杂度维度没声明均值口径是全仓，当前 detail：\(complexity.detail)")
        XCTAssertFalse(complexity.detail.contains("热点样本"),
                       "复杂度维度又拿 top-20 热点样本均值冒充全仓水位了")

        // ② 要校数值就**先解析再比数**，容差跟着它自己的显示精度走：
        //    只写整数位就允许 ±0.5，写了一位小数就收紧到 ±0.05。
        let reported = try XCTUnwrap(reportedRepoMean(in: complexity.detail),
                                     "detail 里解析不出『平均圈复杂度 <数字>』，数值校验形同虚设")
        let tolerance = reported.text.contains(".") ? 0.05 : 0.5
        XCTAssertEqual(reported.value, census.repoMean, accuracy: tolerance,
                       "detail 报的均值 \(reported.text) 与独立普查 "
                     + "\(String(format: "%.3f", census.repoMean)) 对不上")
        XCTAssertLessThan(abs(reported.value - census.repoMean),
                          abs(reported.value - census.hotspotMean),
                          "detail 里的均值离热点样本均值 \(census.hotspotMean) 反而更近，疑似又用错口径")

        // ③ **分母也必须上屏**：均值为 4 的可信度完全取决于"4 是多少个函数的 4"，
        //    不报样本量的均值没有意义。
        XCTAssertTrue(complexity.detail.contains("\(census.functionCount)"),
                      "detail 没报出分母（独立普查 \(census.functionCount) 个函数）："
                    + "不报样本量的均值没有意义。当前 detail：\(complexity.detail)")

        // —— 仍在身（产品口径）：detail 里"N 个函数 CC≥16"数的还是被 prefix(20)
        //    截断的榜单条数，而真实普查见下面 print。修好后把这条翻正为
        //    "detail 含 \u{201c}\(census.atLeast16) 个函数\u{201d}"。
        XCTAssertEqual(code.topComplexFunctions.count, 20,
                       "榜单截断长度变了，本门与 48 号笔记里的措辞要同步")
        XCTAssertTrue(complexity.detail.contains("\(code.topComplexFunctions.count) 个函数"),
                      "detail 不再引用截断条数 \(code.topComplexFunctions.count)，说明普查计数已进契约，"
                    + "请把本断言改为 detail 含 \"\(census.atLeast16) 个函数\"")
        XCTAssertGreaterThan(census.atLeast16, code.topComplexFunctions.count,
                             "全仓 CC≥\(Self.complexFunctionBar) 已经不多于榜单条数，截断不再误导人，"
                           + "连同上面那条一起删掉")

        print("【普查 vs 榜单】真实 CC≥\(Self.complexFunctionBar) 共 \(census.atLeast16) 个，"
            + "而工具 detail 报的是 \(code.topComplexFunctions.count) 个（榜单截断条数）")
    }

    /// 手算可验证的普查门：用一个我能逐个点数函数的最小夹具，
    /// 确认 `analyzedFunctionCount` / `averageCyclomaticComplexity` 不是"自洽的错数"。
    /// 夹具 5 个函数、期望复杂度 `1 + 2 + 2 + 4 + 2 = 11`，手算均值 11 ÷ 5 = **2.2**。
    func testComplexityCensusMatchesHandCountedFixture() async throws {
        let dir = try makeComplexityProbeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let metrics = try await FileSystemCodeAnalyzer().analyze(root: dir, options: .default)

        XCTAssertEqual(metrics.analyzedFunctionCount, 5,
                       "夹具里只有 5 个函数，生产者数出来的却不是我手点数的那个")
        let expectedMean = (1 + 2 + 2 + 4 + 2) / 5.0
        XCTAssertEqual(metrics.averageCyclomaticComplexity ?? -1, expectedMean, accuracy: 0.01,
                       "手算全仓均复杂度应为 \(expectedMean)")
        print("【手算核对】夹具函数 5 个、手算均值 \(expectedMean)，测得 "
            + "\(metrics.analyzedFunctionCount) 个 / \(metrics.averageCyclomaticComplexity ?? -1)")
    }

    // MARK: - 复杂度引擎口径探针（最小可复现夹具，建在 /tmp 下用完即删）

    /// 5 个函数，每个只含一种语法。手算期望：plain=1、oneIf=2、nilCoalesce=2、
    /// failableCast=4、oneTernary=2 → 合计 11，均值 11÷5=2.2。
    private static let probeFixture = #"""
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

    /// 把那份夹具写到 /tmp（AGENTS.md 允许的临时夹具位置）下，返回目录。
    /// 先整目录删掉再建，保证"这里只有 5 个函数"这个手算前提不被上一轮污染。
    private func makeComplexityProbeDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tcoder-wsj-cc-probe", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.probeFixture.write(to: dir.appendingPathComponent("Probe.swift"),
                                    atomically: true, encoding: .utf8)
        return dir
    }

    /// 把只含一种语法的最小函数喂给 `ComplexityEngine`，看它各加几分。
    /// 目的：判定"平均圈复杂度"里有多少是真实判定、多少是 Swift 口径通胀。
    func testComplexityEngineBranchCountingConvention() async throws {
        let dir = try makeComplexityProbeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }

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

    /// 从评分 detail 里解析"平均圈复杂度 X"的那个数，**连带它写出来的原文**——
    /// 原文里有没有小数点决定我们允许多大的比对容差。
    /// 这样实现方爱保留几位就保留几位，测试只管"这个数是不是全仓均值"。
    private func reportedRepoMean(in detail: String) -> (value: Double, text: String)? {
        let pattern = "平均圈复杂度\\s*([0-9]+(?:\\.[0-9]+)?)"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: detail, range: NSRange(detail.startIndex..., in: detail)),
              match.numberOfRanges >= 2,
              let captured = Range(match.range(at: 1), in: detail),
              let value = Double(detail[captured]) else { return nil }
        return (value, String(detail[captured]))
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
