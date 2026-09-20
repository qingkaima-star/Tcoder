/// OWNER: WS-X3 TestSplit —— 自 GitDependencyTests.swift 整块拆出：提交窗口截断与含 merge/非 merge 计数矩阵。用例本体一字未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

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
