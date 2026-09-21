/// OWNER: WS-X3 TestSplit —— 自 GitDependencyTests.swift 整块拆出：仓库根发现（选中目录/子目录上溯/.git 目录/嵌套仓库/软链规范化）。用例本体一字未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

final class GitRepositoryDiscoveryTests: XCTestCase {
    private var sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)

    override func setUpWithError() throws {
        try XCTSkipIf(!Shell.isAvailable("git"), "未找到 git 可执行文件，跳过仓库定位测试")
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("tcoder-wsb-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.sandbox) }
    }

    private func canonical(_ url: URL) -> String { ShellGitAnalyzer.canonicalPath(url.path) }

    // MARK: ① 所选目录即仓库

    func testSelectedDirectoryIsItselfTheRepository() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("plainRepo"), commits: 3)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: repo)

        XCTAssertEqual(insights.discoveryMode, .selectedDirectory, "自身就是仓库时模式必须是 selectedDirectory")
        XCTAssertEqual(insights.discoveryHops, 0, "自身就是仓库时不跳层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(repo), "解析出的根就是所选目录")
        XCTAssertEqual(insights.totalCommits, 3, "3 个提交要如实统计")
        XCTAssertTrue(insights.nestedCandidates.isEmpty, "自身是仓库时不该报嵌套候选")
        XCTAssertTrue(insights.isRepository)
    }

    // MARK: ② 向上找父仓库

    func testSelectingASubdirectoryWalksUpToTheParentRepository() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("upRepo"),
                                                 commits: 2, in: "Sources/App")
        let deep = repo.appendingPathComponent("Sources/App", isDirectory: true)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: deep)

        XCTAssertEqual(insights.discoveryMode, .parentDirectory, "选了仓库内部的子目录要归到父仓库")
        XCTAssertEqual(insights.discoveryHops, 2, "Sources/App 距仓库根是向上 2 层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(repo), "解析出的根必须是仓库根而不是所选子目录")
        XCTAssertEqual(insights.totalCommits, 2, "沿父链找到的仓库要能被完整分析")
    }

    func testSelectingTheGitMetadataDirectoryClimbsOneLevel() async throws {
        let repo = try RepoFixture.makeRepository(at: sandbox.appendingPathComponent("metaRepo"), commits: 1)
        let dotGit = repo.appendingPathComponent(".git", isDirectory: true)
        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: dotGit)

        // git 在 .git 里直接拒绝判定 work tree，这条路径由「逐级向上」兜住。
        XCTAssertEqual(insights.discoveryMode, .parentDirectory, "选中 .git 目录时要向上回退到仓库根")
        XCTAssertEqual(insights.discoveryHops, 1, "从 .git 向上恰好 1 层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(repo), "不能把 .git 本身当仓库根")
    }

    // MARK: ③ 向下找子仓库

    func testNestedRepositoriesPickTheBiggestAndListEveryCandidate() async throws {
        let workspace = sandbox.appendingPathComponent("workspace", isDirectory: true)
        let big = try RepoFixture.makeRepository(at: workspace.appendingPathComponent("bigRepo"), commits: 4)
        let small = try RepoFixture.makeRepository(at: workspace.appendingPathComponent("smallRepo"), commits: 1)
        try FileManager.default.createDirectory(at: workspace.appendingPathComponent("notARepo"),
                                               withIntermediateDirectories: true)

        let insights = try await ShellGitAnalyzer().analyze(repositoryURL: workspace)

        XCTAssertEqual(insights.discoveryMode, .nestedSubdirectory, "所选目录不是仓库、下面躺着仓库时要往下找")
        XCTAssertEqual(insights.discoveryHops, 1, "候选仓库在所选目录下 1 层")
        XCTAssertEqual(insights.resolvedRepositoryRoot.map { canonical(URL(fileURLWithPath: $0)) },
                       canonical(big), "必须选提交数最多的那个仓作为分析对象")
        XCTAssertEqual(insights.totalCommits, 4, "分析对象是 bigRepo 的 4 个提交")
        XCTAssertEqual(insights.nestedCandidates.count, 2, "两个候选都要上报，不能只报被选中的")
        let counts = insights.nestedCandidates.map(\.commitCount)
        XCTAssertEqual(counts, [4, 1], "候选按提交数降序排列")
        XCTAssertEqual(insights.nestedCandidates.map(\.path), [canonical(big), canonical(small)],
                       "上报的候选路径必须就是那两个仓库，且首位是被选中的大仓")
        XCTAssertEqual(insights.nestedCandidates.first?.directoryName, "bigRepo")
        XCTAssertEqual(insights.nestedCandidates.last?.directoryName, "smallRepo")
        XCTAssertNotNil(insights.nestedCandidates.first?.lastCommitAt, "候选要带最近提交时间")
        XCTAssertFalse(insights.nestedCandidates.first?.branch.isEmpty ?? true, "候选要带分支名")
    }

    func testNestedCandidateBeyondDepthLimitIsNotDiscovered() async throws {
        // maxNestedDepth = 3：仓库放在 deep/a/b/c/d 之下（第 5 层）应该找不到。
        let outer = sandbox.appendingPathComponent("deep/a/b/c/d", isDirectory: true)
        _ = try RepoFixture.makeRepository(at: outer.appendingPathComponent("lateRepo"), commits: 2)
        let root = sandbox.appendingPathComponent("deep", isDirectory: true)

        do {
            _ = try await ShellGitAnalyzer().analyze(repositoryURL: root)
            XCTFail("超出向下扫描深度的仓库不应被当成候选")
        } catch let error as AnalysisError {
            guard case .notGitRepository(let detail) = error else {
                return XCTFail("应抛 notGitRepository，实际 \(error)")
            }
            XCTAssertTrue(detail.contains("向下最多 3 层"), "错误信息要说清试过向下几层，实际：\(detail)")
            XCTAssertTrue(detail.contains("向上最多 6 层"), "错误信息要说清试过向上几层，实际：\(detail)")
        }
    }

    // MARK: ④ 全落空

    func testPlainDirectoryThrowsAndListsTriedLocations() async throws {
        let plain = sandbox.appendingPathComponent("plainDirectory", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)

        do {
            _ = try await ShellGitAnalyzer().analyze(repositoryURL: plain)
            XCTFail("非仓库目录必须抛错，不能返回空对象冒充成功")
        } catch let error as AnalysisError {
            guard case .notGitRepository(let detail) = error else {
                return XCTFail("应抛 notGitRepository，实际 \(error)")
            }
            XCTAssertTrue(detail.contains(ShellGitAnalyzer.canonicalPath(plain.path).components(separatedBy: "/").last ?? ""),
                          "错误信息里要带上被选的目录名，实际：\(detail)")
        }
    }

    // MARK: 纯函数件

    func testMakeInsightsStampsDiscoveryFields() throws {
        var candidates: [NestedRepositoryCandidate] = []
        candidates.append(NestedRepositoryCandidate(path: "/ws/big", branch: "main", commitCount: 4, lastCommitAt: nil))
        candidates.append(NestedRepositoryCandidate(path: "/ws/small", branch: "dev", commitCount: 1, lastCommitAt: nil))
        let resolution = ShellGitAnalyzer.RepositoryResolution(selectedPath: "/ws", rootPath: "/ws/big",
                                                              mode: .nestedSubdirectory, hops: 1,
                                                              nestedCandidates: candidates)
        let insights = ShellGitAnalyzer.makeInsights(commits: [], branch: "main", headSHA: "abc1234",
                                                    remoteURL: "", resolution: resolution)
        XCTAssertEqual(insights.discoveryMode, .nestedSubdirectory)
        XCTAssertEqual(insights.discoveryHops, 1)
        XCTAssertEqual(insights.resolvedRepositoryRoot, "/ws/big")
        XCTAssertEqual(insights.nestedCandidates.count, 2)
        XCTAssertTrue(insights.isRepository, "定位成功即视为仓库，即使 0 提交")

        let legacy = ShellGitAnalyzer.makeInsights(commits: [], branch: "", headSHA: "", remoteURL: "")
        XCTAssertEqual(legacy.discoveryMode, .none, "不传定位结果时保持模型默认值")
        XCTAssertNil(legacy.resolvedRepositoryRoot)
    }

    func testUpwardHopsAndParentChainArithmetic() {
        XCTAssertEqual(ShellGitAnalyzer.upwardHops(fromRoot: "/a/b", to: "/a/b"), 0, "相等记 0 跳")
        XCTAssertEqual(ShellGitAnalyzer.upwardHops(fromRoot: "/a/b", to: "/a/b/c/d"), 2, "两层子目录")
        XCTAssertNil(ShellGitAnalyzer.upwardHops(fromRoot: "/a/b", to: "/a/bc"), "前缀相同但不是父目录")
        XCTAssertNil(ShellGitAnalyzer.upwardHops(fromRoot: "/x/y", to: "/a/b"), "完全不相干")

        let chain = ShellGitAnalyzer.parentChain(of: "/a/b/c/d/e/f/g", limit: 6) { _, _ in true }
        XCTAssertEqual(chain.count, 6, "严格受 limit 限制")
        XCTAssertEqual(chain.first, "/a/b/c/d/e/f", "由近及远")
        XCTAssertEqual(chain.last, "/a", "第 6 层正好停在 /a")

        let cut = ShellGitAnalyzer.parentChain(of: "/x/y/z/w", limit: 5) { parent, _ in parent != "/x" }
        XCTAssertEqual(cut, ["/x/y/z", "/x/y"], "跨挂载点必须停止上溯")
    }

    func testCanonicalPathFoldsSymlinksAndTrailingSlash() throws {
        XCTAssertEqual(ShellGitAnalyzer.canonicalPath("/tmp/"), ShellGitAnalyzer.canonicalPath("/tmp"),
                       "尾随斜杠不得影响可比性")
        XCTAssertEqual(ShellGitAnalyzer.canonicalPath("/tmp"), ShellGitAnalyzer.canonicalPath("/private/tmp"),
                       "/tmp 与 /private/tmp 是同一个目录，必须归一")
        XCTAssertEqual(ShellGitAnalyzer.canonicalPath(sandbox.path + "/"),
                       ShellGitAnalyzer.canonicalPath(sandbox.path), "临时目录自身也要归一")
        XCTAssertFalse(ShellGitAnalyzer.canonicalPath(sandbox.path).hasSuffix("/"), "产出不能带尾随斜杠")
    }

    func testPickPrimaryCandidateOrderingIsDeterministic() {
        func candidate(_ path: String, _ count: Int) -> NestedRepositoryCandidate {
            NestedRepositoryCandidate(path: path, branch: "main", commitCount: count, lastCommitAt: nil)
        }
        let entries: [(candidate: NestedRepositoryCandidate, depth: Int)] = [
            (candidate("/ws/a", 2), 1), (candidate("/ws/b", 7), 2), (candidate("/ws/c", 7), 1),
        ]
        XCTAssertEqual(ShellGitAnalyzer.pickPrimaryCandidate(entries)?.candidate.path, "/ws/c",
                     "先比提交数，并列取更浅的一层")
        let tied: [(candidate: NestedRepositoryCandidate, depth: Int)] = [
            (candidate("/ws/z", 3), 1), (candidate("/ws/a", 3), 1),
        ]
        XCTAssertEqual(ShellGitAnalyzer.pickPrimaryCandidate(tied)?.candidate.path, "/ws/a",
                     "再并列按路径字典序，结果必须可复现")
        XCTAssertNil(ShellGitAnalyzer.pickPrimaryCandidate([]), "空候选返回 nil")
    }

    func testAttemptedLocationsTextMentionsBothDirections() {
        let text = ShellGitAnalyzer.attemptedLocationsText(upward: 6, nested: 3)
        XCTAssertTrue(text.contains("自身"), "要说清试过所选目录自身")
        XCTAssertTrue(text.contains("向上最多 6 层"))
        XCTAssertTrue(text.contains("向下最多 3 层"))
    }
}
