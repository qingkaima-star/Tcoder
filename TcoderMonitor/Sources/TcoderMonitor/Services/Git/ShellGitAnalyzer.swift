import Foundation

/// OWNER: WS-B（Git 分析入口）。类型名与协议一致性已冻结。
///
/// 三件事：① 在用户所选目录上**定位真正的仓库**（自身 / 向上父目录 / 向下子目录）；
/// ② 跑 git 命令；③ 把 `GitLogParser` + `GitAggregation` 的产出组装成 `GitInsights`。
///
/// 诚实原则：绝不做「默默分析了一个错位的仓库」这种事——只要解析出的根目录和用户选的
/// 目录不是同一个，就把 `resolvedRepositoryRoot` / `discoveryMode` / `discoveryHops`
/// 全部写进结果，UI 必须能告诉用户「我分析的是哪个仓、怎么找到的」。
/// 三条路都落空时抛 `AnalysisError.notGitRepository`（附带试过哪些位置），
/// 由 `AppState.attempt` 隔离成单个分析器的失败提示，不返回空对象冒充成功。
final class ShellGitAnalyzer: GitAnalysisProviding {

    /// 默认历史上限：再大的仓库也只看最近 2 万条非合并提交。
    /// 注意这是**分析窗口**，不是仓库总提交数 —— 真值走 `rev-list --count HEAD` 单独取。
    static let maxCommits = 20_000
    /// 最近提交列表的展示条数。
    static let recentCommitLimit = 20

    /// 向上最多探几层父目录。
    static let maxUpwardHops = 6
    /// 向下最多扫几层子目录找 `.git`。
    static let maxNestedDepth = 3
    /// 嵌套候选上限，防止在巨型目录树里发一堆 git 进程。
    static let maxNestedCandidates = 20

    /// 向下扫描时跳过的目录（含 `.git` 本身：仓库元数据目录里不该被当成候选）。
    static let nestedSkipDirectories: Set<String> = ScanOptions.defaultSkipDirectories

    private static let gitBinary = "git"

    private let logTimeout: TimeInterval
    private let probeTimeout: TimeInterval
    /// 重试时的超时：第一次用 `probeTimeout` 快速甩掉「假超时」，重试给足时间，
    /// 免得真慢的命令（比如巨型仓库的 `rev-list --count`）被短超时连累。
    private let probeRetryTimeout: TimeInterval
    /// 本次分析的 `git log` 窗口上限；小于仓库总提交数时会置 `historyTruncated`。
    private let commitWindowLimit: Int

    /// 规格固定的主命令（窗口上限按实例取值，便于用小上限做单元测试）。
    /// `%x1f` 分字段、`%x1e` 分提交，`%aI` 是带作者时区偏移的严格 ISO8601。
    var logArguments: [String] {
        ["log", "--no-merges", "-n", "\(commitWindowLimit)", "--date=iso-local",
         "--pretty=format:%H%x1f%an%x1f%ae%x1f%aI%x1f%s%x1e", "--numstat"]
    }

    /// - Parameters:
    ///   - logTimeout: `git log` 的硬超时，大仓库需要更宽的预算（默认 60 秒）。
    ///   - probeTimeout: 探路与元信息命令的首发超时（实测这类命令 26~70ms，5 秒已有 70 倍余量）。
    ///   - probeRetryTimeout: 首发被判超时后的重试预算（默认 25 秒）。
    ///   - commitWindowLimit: `git log -n` 的窗口上限，默认 `Self.maxCommits`。
    init(logTimeout: TimeInterval = 60, probeTimeout: TimeInterval = 5,
         probeRetryTimeout: TimeInterval = 25, commitWindowLimit: Int = ShellGitAnalyzer.maxCommits) {
        self.logTimeout = logTimeout
        self.probeTimeout = probeTimeout
        self.probeRetryTimeout = probeRetryTimeout
        self.commitWindowLimit = max(1, commitWindowLimit)
    }

    // MARK: - Repository resolution

    /// 一次定位的完整结果。`rootPath` 可能不等于 `selectedPath`。
    struct RepositoryResolution: Equatable, Sendable {
        var selectedPath: String
        var rootPath: String
        var mode: GitDiscoveryMode
        var hops: Int
        var nestedCandidates: [NestedRepositoryCandidate]

        var rootURL: URL { URL(fileURLWithPath: rootPath) }
        /// 是否真的挪了地方（UI 决定是否强调「分析的不是你选的那个目录」）。
        var relocated: Bool { rootPath != selectedPath }
    }

    /// 工作区探测的**三种**结局。必须有三态：把「没量到」压成 `false` 会让一份
    /// 带未提交改动的树看起来「与提交号一致」，按提交号复核的人就会白跑一趟。
    enum WorkingTreeOutcome: Sendable {
        case dirty(entries: Int)
        case clean
        case notMeasured(reason: String)
    }

    // MARK: - Entry point

    func analyze(repositoryURL: URL) async throws -> GitInsights {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: repositoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw AnalysisError.notDirectory(repositoryURL.path)
        }
        guard Shell.isAvailable(Self.gitBinary) else { throw AnalysisError.gitBinaryMissing }

        let resolution = try await resolveRepository(from: repositoryURL)

        async let branchProbe = runResilient(["rev-parse", "--abbrev-ref", "HEAD"], at: resolution.rootURL, timeout: probeTimeout)
        async let headProbe = runResilient(["rev-parse", "HEAD"], at: resolution.rootURL, timeout: probeTimeout)
        async let remoteProbe = runResilient(["config", "--get", "remote.origin.url"], at: resolution.rootURL, timeout: probeTimeout)
        // 仓库真实提交总数（含 merge），与下面被窗口截断的 `git log` 无关。
        async let fullCountProbe = runResilient(["rev-list", "--count", "HEAD"], at: resolution.rootURL, timeout: probeTimeout)
        // 工作区状态：报告要能说「这份结论是在哪个提交上、当时树干不干净」。
        // `-uno` 故意**不**用 —— 未跟踪文件也是「与提交号不一致」的一部分；
        // 但 `.build`/派生数据这类被 gitignore 的目录 git 自己会跳过，不必另造一套忽略规则。
        async let statusProbe = runResilient(["status", "--porcelain"], at: resolution.rootURL, timeout: probeTimeout)
        let log = await run(logArguments, at: resolution.rootURL, timeout: logTimeout)
        let branchResult = await branchProbe
        let headResult = await headProbe
        let remoteResult = await remoteProbe
        let fullCountResult = await fullCountProbe
        let statusResult = await statusProbe

        let commits: [ParsedCommit]
        if log.succeeded {
            commits = GitLogParser.parse(log.stdout)
        } else if log.timedOut {
            throw AnalysisError.timedOut("git log")
        } else if Self.isEmptyRepository(stderr: log.stderr, headFailed: !headResult.succeeded) {
            // 刚 git init、还没有任何提交：0 是真实答案，不是失败。
            commits = []
        } else {
            throw AnalysisError.empty("git log 执行失败（\(Self.firstLine(log.stderr))）")
        }

        return Self.makeInsights(
            commits: commits,
            branch: Self.branchName(from: branchResult, headFailed: !headResult.succeeded),
            headSHA: headResult.succeeded ? Self.firstLine(headResult.stdout) : "",
            remoteURL: remoteResult.succeeded ? Self.firstLine(remoteResult.stdout) : "",
            fullCommitCount: fullCountResult.succeeded ? Int(Self.firstLine(fullCountResult.stdout)) : nil,
            resolution: resolution,
            workingTree: Self.workingTree(from: statusResult)
        )
    }

    /// `git status --porcelain` 的结局 → 三态。
    ///
    /// 只认「退出码为 0」这一次探测；非零/超时时**不猜**干净与否，把 git 的第一行 stderr
    /// 当成原因带出去（`not a git repository`、`dubious ownership` 都是真实会遇到的）。
    static func workingTree(from outcome: GitCommandOutcome) -> WorkingTreeOutcome {
        guard outcome.succeeded else {
            if outcome.timedOut { return .notMeasured(reason: "工作区探测超时") }
            let reason = firstLine(outcome.stderr)
            return .notMeasured(reason: reason.isEmpty ? "git status 未成功退出" : reason)
        }
        let entries = outcome.stdout.components(separatedBy: "\n").filter { !$0.isEmpty }
        return entries.isEmpty ? .clean : .dirty(entries: entries.count)
    }

    /// 按「自身 → 向上 → 向下」三级定位仓库。
    func resolveRepository(from selected: URL) async throws -> RepositoryResolution {
        let selectedPath = Self.canonicalPath(selected.path)

        // ① 所选目录自身（或 git 直接报上来的归属）
        if let top = await toplevelPath(of: selectedPath) {
            let root = Self.canonicalPath(top)
            if root == selectedPath {
                return RepositoryResolution(selectedPath: selectedPath, rootPath: root,
                                            mode: .selectedDirectory, hops: 0, nestedCandidates: [])
            }
            if let hops = Self.upwardHops(fromRoot: root, to: selectedPath) {
                // 用户选到了仓库内部的某个子目录 —— 仓库根在上方。
                return RepositoryResolution(selectedPath: selectedPath, rootPath: root,
                                            mode: .parentDirectory, hops: hops, nestedCandidates: [])
            }
            // 符号链接/挂载点导致两边比不出父子关系：照实上报，让 UI 说明分析的是哪个根。
            return RepositoryResolution(selectedPath: selectedPath, rootPath: root,
                                        mode: .selectedDirectory, hops: 0, nestedCandidates: [])
        }

        // ② 逐级向上。git 自己会往上找，所以这条路只在「git 在当前位置直接拒绝判定」时才走得到，
        //    典型是用户选中了 `<repo>/.git` 本身：在那里 `rev-parse --show-toplevel` 会报
        //    "this operation must be run in a work tree"，而它的父目录是完好的仓库。
        if let climbed = await walkUp(from: selectedPath) {
            return RepositoryResolution(selectedPath: selectedPath, rootPath: climbed.rootPath,
                                        mode: .parentDirectory, hops: climbed.hops, nestedCandidates: [])
        }

        // ③ 向下扫子目录里的 `.git`，多个仓库时取提交数最多的那个作为分析对象，
        //    但把**全部**候选都带出去，交给 UI 列清楚，绝不假装只有一个。
        let candidates = await scanNestedRepositories(from: selectedPath)
        if let chosen = Self.pickPrimaryCandidate(candidates) {
            return RepositoryResolution(selectedPath: selectedPath, rootPath: chosen.candidate.path,
                                        mode: .nestedSubdirectory, hops: chosen.depth,
                                        nestedCandidates: candidates.map(\.candidate))
        }

        // ④ 全落空：保留原行为抛错，并把试过的范围一起说清楚。
        throw AnalysisError.notGitRepository("\(selectedPath)（\(Self.attemptedLocationsText(upward: Self.maxUpwardHops, nested: Self.maxNestedDepth))）")
    }

    // MARK: - Discovery plumbing (spawns git)

    /// git 认这个目录属于哪个工作树根；不属于任何仓库时返回 nil。
    private func toplevelPath(of path: String) async -> String? {
        let outcome = await runResilient(["rev-parse", "--show-toplevel"],
                                        at: URL(fileURLWithPath: path), timeout: probeTimeout)
        guard outcome.succeeded else { return nil }
        let top = Self.firstLine(outcome.stdout)
        return top.isEmpty ? nil : top
    }

    private func walkUp(from path: String) async -> (rootPath: String, hops: Int)? {
        for (index, parent) in Self.parentChain(of: path, limit: Self.maxUpwardHops,
                                                sameVolume: Self.isSameVolume).enumerated() {
            if let top = await toplevelPath(of: parent) {
                let root = Self.canonicalPath(top)
                let extra = Self.upwardHops(fromRoot: root, to: parent) ?? 0
                return (root, index + 1 + extra)
            }
        }
        return nil
    }

    /// 广度优先向下找含 `.git` 的目录；深度上限 `maxNestedDepth`，候选数上限 `maxNestedCandidates`。
    private func scanNestedRepositories(from path: String)
        async -> [(candidate: NestedRepositoryCandidate, depth: Int)] {
        var found: [(candidate: NestedRepositoryCandidate, depth: Int)] = []
        var queue: [(directory: String, depth: Int)] = [(Self.canonicalPath(path), 0)]
        var cursor = 0

        while cursor < queue.count, found.count < Self.maxNestedCandidates {
            let entry = queue[cursor]
            cursor += 1
            guard let names = try? FileManager.default.contentsOfDirectory(atPath: entry.directory) else { continue }

            for name in names.sorted() where name != ".DS_Store" {
                let child = entry.directory + "/" + name
                let values = try? URL(fileURLWithPath: child)
                    .resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                if values?.isSymbolicLink == true { continue }   // 不跟符号链接，避免环
                guard values?.isDirectory == true else { continue }
                if Self.isRepository(under: child) {
                    if let candidate = await probeRepository(child, name: name) {
                        found.append((candidate, entry.depth + 1))
                    }
                    if found.count >= Self.maxNestedCandidates { break }
                }
                if entry.depth + 1 < Self.maxNestedDepth,
                   !Self.nestedSkipDirectories.contains(name), !name.hasPrefix(".") {
                    queue.append((child, entry.depth + 1))
                }
            }
        }
        return found.sorted { lhs, rhs in
            if lhs.candidate.commitCount != rhs.candidate.commitCount {
                return lhs.candidate.commitCount > rhs.candidate.commitCount
            }
            return lhs.candidate.path < rhs.candidate.path
        }
    }

    /// 目录里有 `.git`（目录或 worktree/submodule 的 `.git` 文件）即视为仓库根。
    private static func isRepository(under directory: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory + "/.git", isDirectory: &isDir) else { return false }
        return true
    }

    private func probeRepository(_ path: String, name: String) async -> NestedRepositoryCandidate? {
        let url = URL(fileURLWithPath: path)
        async let branchOutcome = runResilient(["rev-parse", "--abbrev-ref", "HEAD"], at: url, timeout: probeTimeout)
        async let countOutcome = runResilient(["rev-list", "--count", "HEAD"], at: url, timeout: probeTimeout)
        async let dateOutcome = runResilient(["log", "-1", "--format=%aI"], at: url, timeout: probeTimeout)
        let branch = await branchOutcome
        let count = await countOutcome
        let date = await dateOutcome
        // 空仓库（还没有任何提交）也是真实存在的仓库，提交数记 0、时间留空。
        guard count.succeeded else { return nil }

        var lastCommit: Date?
        if date.succeeded {
            lastCommit = GitLogParser.parseAuthorTimestamp(Self.firstLine(date.stdout))?.date
        }
        return NestedRepositoryCandidate(path: Self.canonicalPath(path),
                                         branch: branch.succeeded ? Self.branchName(from: branch, headFailed: false) : "",
                                         commitCount: Int(Self.firstLine(count.stdout)) ?? 0,
                                         lastCommitAt: lastCommit)
    }
    // MARK: - Command plumbing

    struct GitCommandOutcome: Sendable {
        let stdout: String
        let stderr: String
        let succeeded: Bool
        let timedOut: Bool
    }

    private func run(_ arguments: [String], at root: URL, timeout: TimeInterval) async -> GitCommandOutcome {
        let started = Date()
        let result = await Shell.run(Self.gitBinary,
                                     arguments: arguments,
                                     workingDirectory: root,
                                     timeout: timeout)
        let elapsed = Date().timeIntervalSince(started)
        // Shell 超时是 terminate() 之后才返回的，用耗时兜底判定（留 50ms 余量）。
        let timedOut = !result.succeeded && elapsed >= timeout - 0.05
        return GitCommandOutcome(stdout: result.stdout, stderr: result.stderr,
                                 succeeded: result.succeeded, timedOut: timedOut)
    }

    /// 「超时」重试一次，只用于定位与元信息这类毫秒级命令。
    ///
    /// 实测边界（load≈12/15 核）：`Shell.run` 的固定开销 p50 约 68ms，偶发「空等到整个 timeout」
    /// —— 但**多数情况下进程早已退出，输出与退出码仍然正确**，停顿只损失时间不损失正确性；
    /// 只有 git 真的还在跑而被 `terminate()` 掉时退出码才非零，那种假失败才会让
    /// `rev-parse --show-toplevel` 返回空、把真仓库误判成「不是仓库」，这一条兜的就是它。
    /// 首发用 `probeTimeout`（5 秒 = 最慢的合法探测 `rev-list --count` 50,666 条用时 0.334s 的 15 倍），
    /// 重试给 `probeRetryTimeout`；git 明确非零退出（真的不是仓库）不重试，昂贵的主命令 `git log` 也不走这里。
    /// 停顿本体在 `Utilities/SharedUtilities.swift`（非本工作流所有），已带数据报给总工。
    private func runResilient(_ arguments: [String], at root: URL, timeout: TimeInterval) async -> GitCommandOutcome {
        let first = await run(arguments, at: root, timeout: timeout)
        guard !first.succeeded, first.timedOut else { return first }
        return await run(arguments, at: root, timeout: probeRetryTimeout)
    }

    private static func isEmptyRepository(stderr: String, headFailed: Bool) -> Bool {
        let text = stderr.lowercased()
        if text.contains("does not have any commits yet") { return true }
        // HEAD 本身解不出来（游离/未出生分支的空仓库）且 log 没有任何输出。
        return headFailed && (text.contains("ambiguous argument 'head'")
            || text.contains("unknown revision")
            || text.contains("bad revision"))
    }

    private static func branchName(from outcome: GitCommandOutcome, headFailed: Bool) -> String {
        if !outcome.succeeded { return headFailed ? "未出生分支" : "" }
        let name = firstLine(outcome.stdout)
        return name == "HEAD" ? "游离 HEAD" : name
    }

    private static func firstLine(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let line = trimmed.components(separatedBy: "\n").first else { return "" }
        return line.trimmingCharacters(in: .whitespaces)
    }
}
