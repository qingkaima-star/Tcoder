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

    // 权威基线，20:12 用系统工具独立测得（不是从 App 里抄的）。
    private static let truthCommits = 50_666          // git rev-list --count HEAD
    private static let truthRubyLines = 592_452       // find *.rb | cat | wc -l
    private static let truthTodoOccurrences = 299     // grep -o TODO（出现次数）
    private static let truthFixmeOccurrences = 52

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

        XCTAssertGreaterThan(code.totalFiles, 2_000, "该树有 3 千多个被跟踪文件")
        XCTAssertGreaterThan(code.totalLines, 400_000, "仅 .rb 就有 59 万行")

        // 语言占比必须认得 Ruby，且行数与 find 实测同量级（±20%，容许分类口径差）。
        let ruby = code.languages.first { $0.language.lowercased().contains("ruby") }
        XCTAssertNotNil(ruby, "语言分布里必须有 Ruby")
        if let ruby {
            let lo = Double(Self.truthRubyLines) * 0.8, hi = Double(Self.truthRubyLines) * 1.2
            XCTAssertGreaterThanOrEqual(Double(ruby.lineCount), lo, ".rb 行数明显偏低")
            XCTAssertLessThanOrEqual(Double(ruby.lineCount), hi, ".rb 行数明显偏高")
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

        // 标记计数与 grep 同量级（词边界会滤掉 todoCount 这类标识符，故不要求精确相等）。
        let todoRatio = Double(code.todoCount) / Double(Self.truthTodoOccurrences)
        XCTAssertGreaterThan(todoRatio, 0.5, "TODO 计数与 grep 差得太远，疑似漏统计")
        XCTAssertLessThan(todoRatio, 1.5, "TODO 计数与 grep 差得太远，疑似重复统计")
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
}
