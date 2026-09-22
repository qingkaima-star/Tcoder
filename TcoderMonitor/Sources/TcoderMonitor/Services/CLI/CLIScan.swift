import Foundation

/// 无头扫描：把 `AppState.scan` 那五路扇出搬到不依赖 GUI 的路径上。
///
/// 为什么自己写一份扇出而不是复用 `AppState`：`AppState` 是 `@MainActor`，它的 `scan`
/// 还兼着进度环、`ProjectStore` 落盘与分数历史三件事 —— 无头模式一件都不该做（见文件尾）。
/// 但**评分与入参一律同源**：五个分析器、`HealthInputs`、`WeightedHealthScorer`
/// 全是 GUI 在用的同一批类型，`sectionLabels` 也与 GUI 那一套逐字相同（由测试钉住）。
final class CLIScan {

    /// 五路的中文名字，顺序即 `outcome` 里失败位的顺序。
    /// 名字本身不在这里定义：`AnalyzerLedger.sectionLabels` 是唯一一份，GUI 那一路引用的是同一份
    /// （原来 `AppState` 在自己的 `attempt("日志分析")` 里又写了一遍，两个名字指同一路）。
    static let sectionLabels = AnalyzerLedger.sectionLabels

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

        async let codeResult = AnalyzerLedger.timed(Self.sectionLabels[0]) {
            try await codeAnalyzer.analyze(root: root, options: .default)
        }
        async let gitResult = AnalyzerLedger.timed(Self.sectionLabels[1]) {
            try await gitAnalyzer.analyze(repositoryURL: root)
        }
        async let logResult = AnalyzerLedger.timed(Self.sectionLabels[2]) {
            try await logAnalyzer.analyze(projectRoot: root, extraLogURLs: extraLogURLs, withinDays: windowDays)
        }
        async let depResult = AnalyzerLedger.timed(Self.sectionLabels[3]) {
            try await depAnalyzer.analyze(projectRoot: root, allowNetwork: allowNetwork)
        }
        async let coverageResult = AnalyzerLedger.timed(Self.sectionLabels[4]) {
            try await coverageAnalyzer.analyze(projectRoot: root, options: .default)
        }

        let (cm, gi, ls, dp, cv) = await (codeResult, gitResult, logResult, depResult, coverageResult)
        // 五路的返回类型各不相同，只能把「有没有失败」这一维先收成同一种元素，
        // 再与路名 zip —— 顺序即 `sectionLabels` 的顺序，两处必须一起动。
        let errors = [cm.attempt.failureReason, gi.attempt.failureReason, ls.attempt.failureReason,
                      dp.attempt.failureReason, cv.attempt.failureReason]
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
        // 台账与五路同源：`limitsHit` 目前只有代码那一路报得出（`scanLimitations`），
        // 其余四路尚无"我撞到过上限"的出口 —— 那是能力缺口，不是"它们没撞上限"，
        // 所以它们留 nil 而不是空数组（见 `AnalyzerRunRecord`）。
        var codeAttempt = cm.attempt
        codeAttempt.limitsHit = cm.value?.scanLimitations ?? []
        report.analyzerLedger = AnalyzerLedger.records(from: [codeAttempt, gi.attempt, ls.attempt, dp.attempt, cv.attempt])
        // 溯源块最后装配：它要读 Git 那一路已经拿到的提交号与工作区状态，
        // 自己不再起第二个 git 进程（两处各查一次迟早分叉）。
        report.provenance = ScanProvenance(report: report, scannedRoot: root.path, producedBy: "cli")

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
        // `fileExists` 对 **chmod 000 的目录返回 true** —— 只查存在性会把"根本读不了"
        // 放过去，于是五路里只有 Git 那路喊失败，其余四路各自交出**全零的成功读数**
        // （实测：`文件 0 · 码行 0 · scannedAt 有值`）。那是"空仓库"的样子，不是"没读到"的样子。
        // 判"可读"必须单独问一次：不可读就地判第 3 档，别让零去冒充结论。
        guard FileManager.default.isReadableFile(atPath: url.path) else { return nil }
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
