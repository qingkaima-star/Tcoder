import XCTest
@testable import TcoderMonitor

/// OWNER: 总工程师（跨分析器集成取证，不属于 WS-A/WS-B/WS-C 的任何 glob）
///
/// 目的：关闭目标第 (3) 项——用**真实仓库**驱动全部分析器，并把测得值与
/// 系统工具（`git` / `find` / `grep`）独立取到的权威基线逐项对齐。
///
/// 这里刻意断言的是**诚实性**而不是启发式的精度：重复率、复杂度分数会随
/// 算法演进变化，钉死它们只会得到一串假绿灯；但"提交总数不能是截断采样值"、
/// "不在仓库根也要认得出父仓库"、"没有覆盖率报告时 must be hasData == false"
/// 这类是契约，错了就是虚报。
///
/// 跑法（默认跳过，避免 59 万行压测拖住并行同事的测试轮次）：
///   TCODER_REAL_REPO=1 ./scripts/locked_build.sh test
final class RealRepositoryEvidenceTests: XCTestCase {

    /// 多语言大型开源仓库。它同时是 git 自动探测的真实用例：
    /// 这个目录本身**不是**仓库根，仓库根在上一级。
    private static let largeRepo = "/opt/homebrew/Library/Homebrew"
    private static let largeRepoGitRoot = "/opt/homebrew"

    // 权威基线，20:12 与 20:49 用系统工具独立测得（不是从 App 里抄的）。
    //
    // 注意口径：必须用**排除 vendor/ 与 .git/** 的可对比数字。
    // 我最初误用 `git ls-files` 的 3,144 与含 vendor 的 592,452 .rb 行，
    // 而 vendor/ 单独就有 352,784 行是被正确跳过的第三方代码——
    // 拿它当基准会把一次正常的扫描误判成 22% 漏扫。
    private static let truthCommits = 50_666          // git rev-list --count HEAD
    private static let truthRubyLinesExclVendor = 239_668
    private static let truthSourceFilesExclVendor = 1_798
    private static let truthTodoExclVendor = 87       // grep -o，出现次数
    /// FIXME 的基线口径 = **注释位上的标记**，不是"字符串出现次数"。
    /// 2026-09-24 00:15 独立复测（大仓自 2026-07-04 起没动过，所以差不是漂移）：
    ///   `grep -roh FIXME --exclude-dir=vendor` = **16**，但其中三处不是标记 ——
    ///   `dev-cmd/bump-formula-pr.rb:378` 的 `%w[TODO FIXME]`（字面量清单）、
    ///   同文件 `:380` 的 `"- [ ] TODO and FIXME comments have been checked."`（UI 文案）、
    ///   `yard/docstring_parser.rb:27` 的 `/^\s*(TODO|FIXME):\s*/i`（正则）。
    ///   按注释位取：`grep -rnE '#[[:space:]]*FIXME' --exclude-dir=vendor` = **13**，与 App 一致。
    /// ⇒ 原来钉的 16 是**基线口径错**（拿字符串出现次数当标记数），App 那一侧是对的。
    ///   同一条 dogfooding 教训的反面：本仓自己那次是"界面文案喂进计数器"导致**多算**，
    ///   这次是大仓同一形状导致基线**多算**——两边都要求"标记"按注释位取，不按子串取。
    private static let truthFixmeExclVendor = 13

    private func requireRealRepo() throws -> URL {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["TCODER_REAL_REPO"] == "1",
                          "压测需显式开启：TCODER_REAL_REPO=1")
        let fm = FileManager.default
        guard fm.fileExists(atPath: Self.largeRepo) else {
            throw XCTSkip("本机没有 \(Self.largeRepo)，跳过真实仓库取证")
        }
        return URL(fileURLWithPath: Self.largeRepo, isDirectory: true)
    }

    // MARK: - Git：向上探测 + 提交数不得虚报

    func testLargeRepositoryGitDiscoveryAndCommitTruth() async throws {
        let url = try requireRealRepo()
        let started = Date()
        let git = try await ShellGitAnalyzer().analyze(repositoryURL: url)
        let seconds = Date().timeIntervalSince(started)

        XCTAssertTrue(git.isRepository, "父目录有 .git，必须被识别为仓库")
        XCTAssertEqual(git.discoveryMode, .parentDirectory,
                       "该目录不是仓库根，应当命中『向上找到父仓库』")
        XCTAssertEqual(git.resolvedRepositoryRoot, Self.largeRepoGitRoot,
                       "解析出的仓库根必须是 \(Self.largeRepoGitRoot)")

        // 这一条就是"大仓提交数虚报"缺陷的回归门：totalCommits 必须是全量，
        // 而不是 `git log -n maxCommits` 那个被截断的采样窗口。
        XCTAssertEqual(git.totalCommits, Self.truthCommits,
                       "totalCommits 应等于 git rev-list --count HEAD 的 \(Self.truthCommits)")
        XCTAssertLessThanOrEqual(git.commitsAnalyzed, git.totalCommits,
                                 "窗口内实际解析数不可能超过全量")
        if git.commitsAnalyzed < git.totalCommits {
            XCTAssertTrue(git.historyTruncated,
                          "只解析了部分历史却未标记 historyTruncated，等于把采样说成全量")
        }

        // 用数组拼接而非长串 + 插值：后者在字段一多时会触发
        // "unable to type-check this expression in reasonable time"。
        print("【Git 取证】" + [
            "提交 total=\(git.totalCommits)",
            "解析窗口=\(git.commitsAnalyzed)",
            "截断=\(git.historyTruncated)",
            "作者=\(git.authors.count)",
            "增删=+\(git.totalAdditions)/-\(git.totalDeletions)",
            "模式=\(git.discoveryMode.rawValue)",
            "根=\(git.resolvedRepositoryRoot ?? "nil")",
            "耗时=\(String(format: "%.1f", seconds))s",
        ].joined(separator: " "))
    }

    // MARK: - 代码规模：量级必须与 find/cat 对得上

    func testLargeRepositoryCodeMetricsScale() async throws {
        let url = try requireRealRepo()
        let started = Date()
        let code = try await FileSystemCodeAnalyzer().analyze(root: url, options: .default)
        let seconds = Date().timeIntervalSince(started)

        XCTAssertGreaterThanOrEqual(code.totalFiles, Self.truthSourceFilesExclVendor,
                                    "扫描到的文件数少于实际存在的受支持源码文件数，疑似漏扫")
        XCTAssertGreaterThan(code.totalLines, 150_000, "量级 sanity 检查")

        // 语言占比必须认得 Ruby。行数与 find 实测同量级——容差 ±25%，
        // 因为 skip 规则（bin/dist/out/target/logs/pub/vendor…）合法地会再吃掉一部分，
        // 而这部分差值应当由 WS-A 的 skip 台账解释，不该由本断言假装不存在。
        let ruby = code.languages.first { $0.language.lowercased().contains("ruby") }
        XCTAssertNotNil(ruby, "语言分布里必须有 Ruby")
        if let ruby {
            let base = Double(Self.truthRubyLinesExclVendor)
            XCTAssertGreaterThanOrEqual(Double(ruby.lineCount), base * 0.75,
                                        ".rb 行数偏低超过容差，需查 skip 台账")
            XCTAssertLessThanOrEqual(Double(ruby.lineCount), base * 1.25,
                                     ".rb 行数偏高，疑似把 vendor/ 第三方代码算了进来")
        }

        let avgComplexity = code.averageCyclomaticComplexity.map { String(format: "%.2f", $0) } ?? "nil"
        print("【代码取证】" + [
            "文件=\(code.totalFiles)",
            "总行=\(code.totalLines)",
            "有效码=\(code.codeLines)",
            "注释=\(code.commentLines)",
            "空行=\(code.blankLines)",
            "TODO=\(code.todoCount)",
            "FIXME=\(code.fixmeCount)",
            "重复率=\(String(format: "%.3f", code.duplicationRatio))",
            "巨大文件=\(code.hugeFiles.count)",
            "热点函数=\(code.topComplexFunctions.count)",
            "全仓均复杂度=\(avgComplexity)(分母 \(code.analyzedFunctionCount))",
            "耗时=\(String(format: "%.1f", seconds))s",
        ].joined(separator: " "))

        // 标记计数：带词边界（`todoCount` 这类标识符不计），故不要求与 grep 精确相等。
        // 20:49 实测 102 vs 87（App 略高，方向待 WS-A 用 skip 台账解释）。
        let todoRatio = Double(code.todoCount) / Double(Self.truthTodoExclVendor)
        XCTAssertGreaterThan(todoRatio, 0.75, "TODO 计数远低于 grep，疑似漏统计")
        XCTAssertLessThan(todoRatio, 1.6, "TODO 计数远高于 grep，疑似重复统计或算进了第三方代码")
        XCTAssertEqual(code.fixmeCount, Self.truthFixmeExclVendor,
                       "FIXME 计数与**按注释位取的** grep 精确一致（不是 `grep -o` 的字符串出现次数，"
                     + "见 `truthFixmeExclVendor` 上面那段），这是唯一可钉死 exact 的标记指标")
    }

    // MARK: - 缺数据必须诚实为空，不能伪装成好数据

    func testLargeRepositoryAbsenceOfDataIsHonest() async throws {
        let url = try requireRealRepo()

        // 该树没有任何测试覆盖率产物（无 coverage/ 目录）。
        let cov = try await CoverageAnalyzer().analyze(projectRoot: url, options: .default)
        XCTAssertFalse(cov.hasData, "Homebrew 无覆盖率报告，hasData 必须为 false 而不是 0%")

        // 也没有本 App 认识的错误日志。
        let logs = try await FileLogAnalyzer()
            .analyze(projectRoot: url, extraLogURLs: [], withinDays: 30)
        XCTAssertEqual(logs.crashCount, 0, "不应把别人的崩溃报告算进这个项目")

        // 但它有 Gemfile —— 依赖分析必须真出数字，而不是空态。
        let deps = try await ManifestDependencyAnalyzer()
            .analyze(projectRoot: url, allowNetwork: false)
        XCTAssertFalse(deps.ecosystems.isEmpty,
                       "Gemfile 是受支持清单（ManifestParsers:47），此处为空说明发现逻辑漏了")

        print("【空态取证】" + [
            "覆盖率 hasData=\(cov.hasData)",
            "日志 crash=\(logs.crashCount)",
            "error=\(logs.errorCount)",
            "依赖生态=\(deps.ecosystems.map { $0.ecosystem })",
            "依赖数=\(deps.totalDependencies)",
            "漏洞=\(deps.vulnerableCount)",
            "联网说明=\(deps.networkLookupNote.isEmpty ? "无" : deps.networkLookupNote)",
        ].joined(separator: " · "))

        // 44 = Gemfile 直接声明；90 = Gemfile.lock 全量。报哪个都行，但不能两边都不沾。
        XCTAssertTrue((44...90).contains(deps.totalDependencies),
                      "依赖数 \(deps.totalDependencies) 与 Gemfile(44 直接声明)/Gemfile.lock(90 含传递) 都对不上，需核口径")
    }

    // MARK: - 日志分析器必须有真实日志来源
    //
    // 上面那条只断言 Homebrew 上 crashCount == 0，那是在证明"空态诚实"，
    // 并没有证明日志分析器真能解析出真实数字。本 App 自己崩过，
    // `~/Library/Logs/DiagnosticReports/TcoderMonitor-*.ips` 是现成的真实输入，
    // 而且正是当初 `ByteFormat.bitRate` 那个 `%s` 段错误留下的现场。
    // 用 `extraLogURLs` 显式喂进去（这是契约里给"用户自选文件"留的正规入口），
    // 断言解析出非零的真实崩溃计数与可读签名。
    func testLogAnalyzerParsesRealDiagnosticReports() async throws {
        let url = try requireRealRepo()
        let reports = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
        let samples = ((try? FileManager.default.contentsOfDirectory(at: reports,
                                                                    includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("TcoderMonitor-") && $0.pathExtension == "ips" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        guard !samples.isEmpty else {
            throw XCTSkip("本机没有本 App 的 .ips 诊断报告，跳过真实日志取证")
        }

        let logs = try await FileLogAnalyzer().analyze(
            projectRoot: url, extraLogURLs: samples, withinDays: 30)

        // 这一格喂进去的**全是**真实崩溃报告 ⇒ RD-46b 之后密度分母本来就该是 0（没有一行真日志）。
        // 原来那句 `totalLinesScanned > 0` 想说的是"真实报告不可能一行都没读到"= **读取覆盖**，
        // 所以它现在必须落在崩溃那一格上；把它改成 `== 0` 会让这条用例变成永真绿。
        XCTAssertGreaterThan(logs.crashReportLineCount ?? 0, 0, "真实报告不可能一行都没读到（崩溃正文那一格）")
        XCTAssertEqual(logs.totalLinesScanned, 0, "输入里一行真日志都没有 ⇒ 分母必须是 0（RD-46b）")
        XCTAssertFalse(logs.topErrors.isEmpty, "真实崩溃必须聚出至少一条 Top Error")
        guard let signature = logs.topErrors.first?.signature else { return }
        XCTAssertFalse(signature.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // 诚实性：签名必须是可读的崩溃语义，而不是裸 JSON 或机器字段堆。
        XCTAssertFalse(signature.contains("\"bug_type\""),
                       "签名里漏出了 .ips 机器字段，说明标题归一没生效")
        XCTAssertFalse(signature.contains("Incident Identifier"),
                       "签名里漏出了事件标识符")

        print("【日志取证】真实 .ips \(samples.count) 份 · crash=\(logs.crashCount) "
              + "error=\(logs.errorCount) 扫描行数=\(logs.totalLinesScanned) "
              + "首条签名=\(signature.prefix(90))")
    }

    // MARK: - 评分链路：只用真实测得的输入

    func testHealthScoreOnRealRepositoryInputs() async throws {
        let url = try requireRealRepo()
        let code = try await FileSystemCodeAnalyzer().analyze(root: url, options: .default)
        let git = try await ShellGitAnalyzer().analyze(repositoryURL: url)
        let deps = try await ManifestDependencyAnalyzer().analyze(projectRoot: url, allowNetwork: false)
        let cov = try await CoverageAnalyzer().analyze(projectRoot: url, options: .default)

        let score = WeightedHealthScorer().score(
            HealthInputs(code: code, git: git, logs: nil, dependencies: deps, coverage: cov))

        XCTAssertTrue((0...100).contains(score.overall), "总分必须落在 0...100")
        XCTAssertFalse(score.components.isEmpty)
        let weightSum = score.components.reduce(0.0) { $0 + $1.weight }
        XCTAssertEqual(weightSum, 1.0, accuracy: 0.001, "分量权重必须归一到 1.0")
        let recomputed = score.components.reduce(0.0) { $0 + Double($1.score) * $1.weight }
        XCTAssertEqual(Double(score.overall), recomputed, accuracy: 1.0,
                       "总分必须等于 Σ(分量分 × 权重)")
        XCTAssertFalse(score.narrative.isEmpty, "即便数据齐全也要给出说明")
        XCTAssertFalse(score.recommendations.isEmpty)

        // 无覆盖率数据时，该维度不得进入评分（缺数据既不奖励也不惩罚）。
        XCTAssertFalse(score.components.contains { $0.name.contains("覆盖") },
                       "coverage.hasData == false 时不该出现覆盖率维度，否则等于按 0 分惩罚")

        let dimensionList = score.components.map { "\($0.name):\($0.score)" }
        print("【评分取证】" + [
            "总分=\(score.overall)",
            "等级=\(score.grade.rawValue)",
            "维度=\(dimensionList)",
            "总评=\(score.narrative)",
        ].joined(separator: " · "))
    }

    // MARK: - 批次 P38：独立取数必须和被测数据同一快照（结构钉）

    /// 复核型断言（"分析器数到多少 vs 独立走一遍树数到多少"）**只许在快照里取一次数**。
    /// 共享主树每 1~2 分钟被并发合流推进一次，两次走树之间只要动过，比的就是两棵不同的树——
    /// 2026-09-22 这条门就是这么假红过 3 条（`analyzedFunctionCount` 4174 vs 普查 4230），
    /// 而单跑该文件 7 例 0 失败。P29 已给 git 真值做过同一处理，这条是同一机制的另一个落点。
    ///
    /// 钉的是形状：`complexityCensus()` 必须**转发**到 `selfScan().census`，
    /// 自己**不许**再走一遍树；真正取数的 `measureComplexityCensus()` 只许被 `make()` 调一次。
    static func censusIsTakenInsideTheScanSnapshot(_ harness: String)
        -> (forwards: Bool, walksAgain: Bool, takes: Int) {
        let lines = SurfaceScanKit.codeLines(harness)
        let code = lines.joined(separator: "\n")
        let forwards = code.contains("try await selfScan().census")
        // 取树那一行只要出现在 `complexityCensus()` 的头两行体内，就是断言在第二次走树。
        var walksAgain = false
        if let head = lines.firstIndex(where: { $0.contains("func complexityCensus()") }),
           head + 1 < lines.count {
            let body = lines[(head + 1)..<min(head + 3, lines.count)]
            walksAgain = body.contains { $0.contains("SourceTreeScanner(") }
        }
        let takes = code.components(separatedBy: "measureComplexityCensus()").count - 1
        return (forwards, walksAgain, takes)
    }

    func test_independentCensusIsTakenInsideTheScanSnapshot() throws {
        let harness = try XCTUnwrap(SurfaceScanKit.testSource("SelfScanHarness.swift"),
                                    "读不到测试基座 ⇒ 这条结构钉在空转")
        let shape = Self.censusIsTakenInsideTheScanSnapshot(harness)
        XCTAssertTrue(shape.forwards,
                      "`complexityCensus()` 不再转发到快照 ⇒ 断言会第二次走树，共享主树上必然漂红")
        XCTAssertFalse(shape.walksAgain,
                       "取树逻辑又写回 `complexityCensus()` 里了：那正是两棵树比大小的形状")
        XCTAssertEqual(shape.takes, 2,
                       "`measureComplexityCensus()` 出现 \(shape.takes) 次（定义 1 + 快照里调 1）；"
                       + "多了就是有人另开一处取数")
    }

    func test_censusSnapshotRulerCatchesSyntheticRegression() {
        let good = """
            func complexityCensus() async throws -> ComplexityCensus {
                try await selfScan().census
            }
            static func measureComplexityCensus() async throws -> ComplexityCensus {
                let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
            }
            let census = try await Self.measureComplexityCensus()
            """
        let shape = Self.censusIsTakenInsideTheScanSnapshot(good)
        XCTAssertTrue(shape.forwards); XCTAssertFalse(shape.walksAgain)
        XCTAssertEqual(shape.takes, 2, "合法形状被误判 ⇒ 下次没人敢动这块")

        let bad = """
            func complexityCensus() async throws -> ComplexityCensus {
                let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
            }
            static func measureComplexityCensus() async throws -> ComplexityCensus {
                let files = await SourceTreeScanner(options: .default).scan(root: Self.repoRoot).files
            }
            """
        let broken = Self.censusIsTakenInsideTheScanSnapshot(bad)
        XCTAssertFalse(broken.forwards, "丢掉快照转发的写法没抓到 → 这条守卫是摆设")
        XCTAssertTrue(broken.walksAgain, "断言里重新走树没抓到 → 假红会回来")
    }
}
