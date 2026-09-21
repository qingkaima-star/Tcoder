import Foundation

/// 无头扫描：把 `AppState.scan` 那五路扇出搬到不依赖 GUI 的路径上。
///
/// 为什么自己写一份扇出而不是复用 `AppState`：`AppState` 是 `@MainActor`，它的 `scan`
/// 还兼着进度环、`ProjectStore` 落盘与分数历史三件事 —— 无头模式一件都不该做（见文件尾）。
/// 但**评分与入参一律同源**：五个分析器、`HealthInputs`、`WeightedHealthScorer`
/// 全是 GUI 在用的同一批类型，`sectionLabels` 也与 GUI 那一套逐字相同（由测试钉住）。
final class CLIScan {

    /// 五路的中文名字，顺序即 `outcome` 里失败位的顺序。
    /// 必须与 `AppState.sectionFailures` 调用点用的那五个字面一字不差 ——
    /// `CLIHeadlessTests.test_sectionLabelsAreTheOnlyOnesAppStateUses` 盯着这条。
    static let sectionLabels = ["代码扫描", "Git 分析", "错误日志", "依赖分析", "测试覆盖率"]

    /// 与 GUI 默认值对齐：`AppState.logWindowDays`。
    static let logWindowDays = 7

    private let code: CodeAnalysisProviding
    private let git: GitAnalysisProviding
    private let logs: LogAnalysisProviding
    private let deps: DependencyAnalysisProviding
    private let coverage: CoverageProviding
    private let scorer: HealthScoringProviding

    /// 五个分析器都做成**带默认值的参数**：这是冻结区指定的做法
    /// （"实现需要更多输入时，给自己那个具体类型加带默认值的参数，不要动协议"）。
    /// 没有这个缝，退出码 2 / 4 就只能靠真扫一个坏仓库去凑，那种测试既慢又永远跑不齐。
    init(code: CodeAnalysisProviding = FileSystemCodeAnalyzer(),
         git: GitAnalysisProviding = ShellGitAnalyzer(),
         logs: LogAnalysisProviding = FileLogAnalyzer(),
         deps: DependencyAnalysisProviding = ManifestDependencyAnalyzer(),
         coverage: CoverageProviding = CoverageAnalyzer(),
         scorer: HealthScoringProviding = WeightedHealthScorer()) {
        self.code = code
        self.git = git
        self.logs = logs
        self.deps = deps
        self.coverage = coverage
        self.scorer = scorer
    }

    /// `extraLogPaths` / `windowDays` 对应界面上的「附加日志文件」与日志窗口天数：
    /// 界面能手动指日志，CLI 少这两个入口，扫出来的"运行稳定性缺席"就分不清是
    /// "这项目真没日志"还是"日志放在约定位置之外而没人告诉 CLI"。
    func outcome(path raw: String, allowNetwork: Bool,
                 extraLogPaths: [String] = [], windowDays: Int = logWindowDays) async -> CLIScanOutcome {
        guard let root = Self.validatedURL(for: raw) else {
            return CLIScanOutcome(report: nil, exit: .badPath,
                                  problem: "路径不可用：\(raw)（不存在、不是目录或不可读）")
        }
        var report = ProjectReport(project: MonitoredProject(name: root.lastPathComponent, path: root.path))

        let codeAnalyzer = code, gitAnalyzer = git, logAnalyzer = logs
        let depAnalyzer = deps, coverageAnalyzer = coverage
        let extraLogURLs = extraLogPaths.map { URL(fileURLWithPath: $0) }

        async let codeResult = Self.attempt { try await codeAnalyzer.analyze(root: root, options: .default) }
        async let gitResult = Self.attempt { try await gitAnalyzer.analyze(repositoryURL: root) }
        async let logResult = Self.attempt {
            try await logAnalyzer.analyze(projectRoot: root, extraLogURLs: extraLogURLs, withinDays: windowDays)
        }
        async let depResult = Self.attempt { try await depAnalyzer.analyze(projectRoot: root, allowNetwork: allowNetwork) }
        async let coverageResult = Self.attempt { try await coverageAnalyzer.analyze(projectRoot: root, options: .default) }

        let (cm, gi, ls, dp, cv) = await (codeResult, gitResult, logResult, depResult, coverageResult)
        // 五路的返回类型各不相同，只能把「有没有失败」这一维先收成同一种元素，
        // 再与路名 zip —— 顺序即 `sectionLabels` 的顺序，两处必须一起动。
        let errors = [cm.error, gi.error, ls.error, dp.error, cv.error]
        let failures = zip(Self.sectionLabels, errors).compactMap { $1 == nil ? nil : $0 }

        report.code = cm.value
        report.git = gi.value
        report.logs = ls.value
        report.dependencies = dp.value
        report.coverage = cv.value
        report.health = scorer.score(HealthInputs(code: cm.value, git: gi.value, logs: ls.value,
                                                  dependencies: dp.value, coverage: cv.value,
                                                  previousScore: nil))
        report.generatedAt = Date()
        report.attemptedAt = Date()
        report.failedSections = failures

        return CLIScanOutcome(report: report,
                              exit: CLIExit.failedSections(failures.count),
                              problem: errors.compactMap { $0 }.joined(separator: " · "))
    }

    // MARK: - 路径校验（前置于任何分析，否则白扫一遍还会给出像结论的空报告）

    static func validatedURL(for raw: String) -> URL? {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return nil
        }
        return url
    }

    static func looksLikeRepository(_ url: URL) -> Bool {
        let dotGit = url.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory)
    }

    // MARK: - JSON：与 GUI 落盘同一套 coder 配置

    static func json(_ report: ProjectReport, compact: Bool) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = compact ? [.sortedKeys] : [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    private static func attempt<T: Sendable>(
        _ work: @Sendable () async throws -> T
    ) async -> (value: T?, error: String?) {
        do { return (try await work(), nil) }
        catch { return (nil, error.localizedDescription) }
    }
}

extension JSONDecoder {
    /// `ProjectStore` 的 decoder 用的是 `.iso8601`；CLI 必须同配置，
    /// 否则两边写出的 JSON 互读不回来，"同一把尺子"就成了话术。
    static func tcoderReportDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

struct CLIScanOutcome {
    let report: ProjectReport?
    let exit: CLIExit
    let problem: String?
}

// 无头模式**零写盘**：不读也不写 `TCODER_SUPPORT_DIR` / `projects.json` / `reports/`
// / `score-history.json`。落盘与分数历史仍只归 GUI —— AI 每扫一次就污染一次真实用户的
// 项目列表与历史，比"没有 CLI"更糟。
