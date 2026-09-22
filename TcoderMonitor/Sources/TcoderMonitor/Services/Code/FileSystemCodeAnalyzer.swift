import Foundation

/// OWNER: Workstream A (静态代码分析). Type name and protocol conformance are frozen.
///
/// 编排流程：SourceTreeScanner（遍历 + 行分类）→ ComplexityEngine / DuplicationEngine → CodeMetrics。
/// 运行在 AppState 的 Task.detached 里，因此这里不得触碰任何 @MainActor 对象。
final class FileSystemCodeAnalyzer: CodeAnalysisProviding {
    private let fallbackOptions: ScanOptions

    init(options: ScanOptions = .default) {
        self.fallbackOptions = options
    }

    func analyze(root: URL, options: ScanOptions) async throws -> CodeMetrics {
        try await analyzeWithCoverage(root: root, options: options).metrics
    }

    struct AnalysisOutcome: Sendable {
        var metrics: CodeMetrics
        var coverage: CodeScanCoverage
    }

    /// 与 `analyze` 同一次遍历、同一批数据，额外带回覆盖度；不重复扫描。
    ///
    /// `scanLimitations` 在这里拼两段：`limitationSummary`（**扫描范围**：哪些上限真的生效过）
    /// 加 `JavaSignatureDeclines.notes`（**识别覆盖面**：轻量正则认不出的 Java 形状）。
    /// 两段共用同一条纪律——零命中不出声，否则「没测到」会长成「这个文件没有复杂函数」。
    /// 本函数体停在 50 行口径内（`CodeComplexityDebtTests`），要补理由请补到上面的文档注释里。
    func analyzeWithCoverage(root: URL, options: ScanOptions) async throws -> AnalysisOutcome {
        let startedAt = Date()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AnalysisError.notDirectory(root.path)
        }

        let scan = await SourceTreeScanner(options: options).scan(root: root)
        let files = scan.files

        let functionTask = Task.detached(priority: .userInitiated) { () -> [ComplexityEngine.FunctionScanOutcome] in
            files.map { ComplexityEngine.functionsWithIntegrity(in: $0) }
        }
        let duplicationTask = Task.detached(priority: .userInitiated) { () -> DuplicationResult in
            DuplicationEngine.analyze(files)
        }
        let functionOutcomes = await functionTask.value
        let functionsPerFile: [[FunctionCandidate]] = functionOutcomes.map(\.candidates)
        let duplication = await duplicationTask.value
        // R2：逐文件词法读数汇总成「这一路的测量范围」；只报一处会把其余文件藏起来。
        let lex = ComplexityEngine.LexAggregate.accumulate(functionOutcomes)

        var metrics = CodeMetrics()
        metrics.scannedAt = startedAt
        metrics.durationMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        apply(
            files: files,
            functionsPerFile: functionsPerFile,
            duplication: duplication,
            to: &metrics
        )
        let coverage = Self.coverage(from: scan, duplication: duplication, options: options, lex: lex)
        // 契约接入（P7-C 3-2）：判据用 `limitationSummary` 非空而不是 `isPartial` —— 前者还含
        // 「按规则排除了多少条目」这类**范围**事实，读者要知道数字是在什么范围内测出来的。
        let limits = coverage.limitationSummary + coverage.surfaceNotes
            + ComplexityEngine.JavaSignatureDeclines.notes(for: files)
        metrics.scanLimitations = limits.isEmpty ? nil : limits
        return AnalysisOutcome(metrics: metrics, coverage: coverage)
    }

    /// 兼容无参构造（AppState 用的就是 `FileSystemCodeAnalyzer()`）。
    func analyze(root: URL) async throws -> CodeMetrics {
        try await analyze(root: root, options: fallbackOptions)
    }

    /// 剔除台账：回答「扫出来的文件比 `find` 少，少掉的那些各是被哪条规则剔掉的」。
    /// `countSkippedLines = true` 进入审计模式，会额外读出被剔除文件的真实行数（要读盘，
    /// 受 `SourceSkipLedger.defaultAuditBudget` 字节预算约束）；默认只记条数与字节数，零额外 I/O。
    ///
    /// 契约缺口：`CodeMetrics` 目前没有承载台账的字段，所以视图拿不到它，只能由这个入口单独取。
    func skipLedger(root: URL, options: ScanOptions, countSkippedLines: Bool = false) async throws -> SourceSkipLedger {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AnalysisError.notDirectory(root.path)
        }
        let budget = countSkippedLines ? Int64(SourceSkipLedger.defaultAuditBudget) : 0
        return await SourceTreeScanner(options: options, auditLineBudget: budget).scan(root: root).skipLedger
    }

    // MARK: - Aggregation

    private func apply(
        files: [ScannedSourceFile],
        functionsPerFile: [[FunctionCandidate]],
        duplication: DuplicationResult,
        to metrics: inout CodeMetrics
    ) {
        let totals = Self.lineTotals(files)
        metrics.totalFiles = files.count
        // totalLines 取真实行计数之和；不变式由单测在真实目录上把关。
        metrics.totalLines = totals.total
        metrics.blankLines = totals.blank
        metrics.commentLines = totals.comment
        metrics.codeLines = totals.code
        metrics.todoCount = totals.todo
        metrics.fixmeCount = totals.fixme
        metrics.languages = languageShares(files: files, codeLineTotal: totals.code)

        let largest = files.map(\.totalLineCount).max() ?? 0
        metrics.largestFileLineCount = largest
        // 榜单封顶 20 个是给界面用的；**占比的分子必须用真个数**，否则仓库越大越显干净
        // （本 App 扫自己：榜内 20 / 实际 38，占比会从 20% 被报成 10.5%）。
        let huge = hugeFiles(files: files, functionsPerFile: functionsPerFile)
        metrics.hugeFileCount = huge.count
        metrics.hugeFiles = Array(huge.prefix(20))

        let hotspots = hotspots(files: files, functionsPerFile: functionsPerFile)
        metrics.topComplexFunctions = Self.rankedHotspots(hotspots)
        applyFunctionMetrics(functionsPerFile.flatMap { $0 }, to: &metrics)

        metrics.duplicationRatio = duplication.ratio
        metrics.duplicatedBlocks = duplication.blocks
        metrics.overallRisk = overallRisk(
            metrics: metrics,
            hotspotCount: hotspots.count,
            longestFileLines: largest
        )
    }

    /// 覆盖度台账的装配。从 `analyzeWithCoverage` 里搬出来只为一件事：
    /// 那条链路本身只有「扫 → 两路并行 → 摆字段」四步，摊在一起就成 60 行的超长函数了
    /// （本包的自扫门 `CodeComplexityDebtTests` 管这条）。
    private static func coverage(from scan: SourceScanResult, duplication: DuplicationResult,
                                 options: ScanOptions, lex: ComplexityEngine.LexAggregate) -> CodeScanCoverage {
        return CodeScanCoverage(
            visitedEntryCount: scan.visitedFileCount,
            includedFileCount: scan.scannedFileCount,
            skippedFileCount: scan.skippedFileCount,
            truncatedByMaxFiles: scan.truncatedByMaxFiles,
            maxFiles: options.maxFiles,
            maxFileBytes: options.maxFileBytes,
            lineTruncatedFileCount: scan.lineTruncatedFileCount,
            filesHittingDuplicateLineCap: duplication.filesHittingLineCap,
            duplicateFragmentsDroppedByBudget: duplication.fragmentsDroppedByBudget,
            duplicateBlocksDroppedByCap: duplication.blocksDroppedByCap,
            duplicateLinesOutsideReportedBlocks: duplication.linesOutsideReportedBlocks,
            unreadableDirectoryCount: scan.unreadableDirectoryCount,
            lexIntegrity: lex.integrity,
            lexAnomalousFileCount: lex.anomalousFileCount,
            unboundedFunctionSignatureCount: lex.unboundedSignatureCount,
            vueRegionFallbackFileCount: lex.vueRegionFallbackFileCount,
            skipLedger: scan.skipLedger,
            roleTally: SourceRoleTally(of: scan.files),
            treeFollowing: scan.treeFollowing
        )
    }

    /// 六项行计数的逐文件累加。抽出来只为了让 `apply` 只剩「摆字段」这一件事。
    private static func lineTotals(_ files: [ScannedSourceFile])
        -> (blank: Int, comment: Int, code: Int, total: Int, todo: Int, fixme: Int) {
        var blank = 0
        var comment = 0
        var code = 0
        var total = 0
        var todo = 0
        var fixme = 0
        for file in files {
            blank += file.blankLineCount
            comment += file.commentLineCount
            code += file.codeLineCount
            total += file.totalLineCount
            todo += file.todoCount
            fixme += file.fixmeCount
        }
        return (blank, comment, code, total, todo, fixme)
    }

    // MARK: - Risk model 阈值（冻结区：数值不得为了任何指标变动，见 AGENTS.md §3）

    static let criticalFunctionComplexity = 31
    static let highFunctionComplexity = 21
    static let mediumFunctionComplexity = 11
    static let longFunctionThreshold = 50
    static let criticalFileLines = 1_500
    static let highFileLines = 800
    static let mediumFileLines = 400

    /// 热点榜：按 CC 降序、同 CC 再按行数降序，截断到 20 条（截断本身的行为由自扫守卫钉着）。
    /// 榜单**尾部必须可复现**。原来只有「复杂度、行数」两把键：CC 相同的一大群函数在
    /// 20 名的截断线上谁进榜，取决于合并进来的文件顺序 —— 而 Swift 的 `sorted`
    /// **不是稳定排序**，五路并发扫完再拼的顺序也不固定。
    /// 实测（同一条 CLI 扫同一个仓库）第 20 名会在
    /// `parseTarget`(31 行 · 3 参) 与 `gradleDependencies`(60 行 · 2 参) 之间换人，
    /// 于是"新老两条路逐项一致"这条验收永远差一项。
    /// 补三把全序键（路径 → 起始行 → 函数名）：截断线与顺序此后只由**内容**决定。
    /// **没有动任何阈值或上限**（前 20、CC 判级一字未改）。
    private static func rankedHotspots(_ hotspots: [FunctionHotspot]) -> [FunctionHotspot] {
        Array(hotspots.sorted {
            if $0.cyclomaticComplexity != $1.cyclomaticComplexity {
                return $0.cyclomaticComplexity > $1.cyclomaticComplexity
            }
            if $0.lineCount != $1.lineCount { return $0.lineCount > $1.lineCount }
            if $0.filePath != $1.filePath { return $0.filePath < $1.filePath }
            if $0.startLine != $1.startLine { return $0.startLine < $1.startLine }
            return $0.name < $1.name
        }.prefix(20))
    }

    /// 函数维度的四个派生量。
    private func applyFunctionMetrics(_ allFunctions: [FunctionCandidate], to metrics: inout CodeMetrics) {
        metrics.longFunctions = allFunctions.filter { $0.lineCount > Self.longFunctionThreshold }.count
        metrics.averageFunctionLength = allFunctions.isEmpty
            ? 0
            : Int((Double(allFunctions.map(\.lineCount).reduce(0, +)) / Double(allFunctions.count)).rounded())
        // 全仓真均值，不是热点榜均值：健康评分的复杂度曲线按「所有被识别函数的平均圈复杂度」标定，
        // 代进 topComplexFunctions 的均值会随仓库规模失真（仓库越大、上榜越是极端值、分数越低）。
        // 一个函数都没识别出来时给 nil 而不是 0 —— 「没有函数」是未知，不是「极简」，
        // 给 0 会把纯脚本仓/配置仓的复杂度分量评成满分。
        metrics.analyzedFunctionCount = allFunctions.count
        metrics.averageCyclomaticComplexity = allFunctions.isEmpty
            ? nil
            : Double(allFunctions.map(\.complexity).reduce(0, +)) / Double(allFunctions.count)
        // 识别规则降级台账随报告一起落盘：它解释的是"这一份数字为什么可能偏低"。
        // 没有它，一个坏掉的正则会在界面上长成"这个仓库 0 个函数"。
        let degraded = ComplexityEngine.RuleDegradeLedger.all
        metrics.analyzerRuleFailures = degraded.isEmpty ? nil : degraded
    }

    private func languageShares(files: [ScannedSourceFile], codeLineTotal: Int) -> [LanguageShare] {
        var fileCount: [String: Int] = [:]
        var lineCount: [String: Int] = [:]
        for file in files {
            fileCount[file.language, default: 0] += 1
            lineCount[file.language, default: 0] += file.codeLineCount
        }
        return lineCount
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { language, lines in
                LanguageShare(
                    language: language,
                    fileCount: fileCount[language] ?? 0,
                    lineCount: lines,
                    share: codeLineTotal == 0 ? 0 : Double(lines) / Double(codeLineTotal)
                )
            }
    }

    private func hugeFiles(
        files: [ScannedSourceFile],
        functionsPerFile: [[FunctionCandidate]]
    ) -> [FileHotspot] {
        var result: [FileHotspot] = []
        for (index, file) in files.enumerated() {
            let lineCount = file.totalLineCount
            guard lineCount > Self.mediumFileLines else { continue }
            let functions = index < functionsPerFile.count ? functionsPerFile[index] : []
            result.append(
                FileHotspot(
                    path: file.url.path,
                    lineCount: lineCount,
                    risk: fileRisk(forLines: lineCount),
                    suggestion: splitSuggestion(for: file, functions: functions)
                )
            )
        }
        return result.sorted { $0.lineCount > $1.lineCount }
    }

    private func hotspots(
        files: [ScannedSourceFile],
        functionsPerFile: [[FunctionCandidate]]
    ) -> [FunctionHotspot] {
        var result: [FunctionHotspot] = []
        for (index, file) in files.enumerated() {
            guard index < functionsPerFile.count else { break }
            for candidate in functionsPerFile[index] {
                result.append(
                    FunctionHotspot(
                        name: candidate.name,
                        filePath: file.url.path,
                        startLine: candidate.startLine,
                        lineCount: candidate.lineCount,
                        cyclomaticComplexity: candidate.complexity,
                        parameterCount: candidate.parameterCount,
                        risk: functionRisk(complexity: candidate.complexity, lineCount: candidate.lineCount)
                    )
                )
            }
        }
        return result
    }
}
