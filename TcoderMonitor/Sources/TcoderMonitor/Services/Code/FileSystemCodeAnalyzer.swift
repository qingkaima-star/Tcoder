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

    /// 一次扫描的「看到了多少、被哪条上限切掉了多少」。
    ///
    /// 背景（WS-D 诚实性审计 P1 #7）：扫描器本来就维护 `truncatedByMaxFiles` /
    /// `visitedFileCount` / `skippedFileCount`，但原先 `analyze` 只取 `scan.files`，
    /// 四个字段连同「2MB 单文件上限、30 项 skipDirectories、扩展名白名单、20 万行/文件截断」
    /// 一起被丢掉，UI 于是把一份**部分测量**呈现成完整测量。这里一个都不再丢。
    ///
    /// 契约缺口**已闭合**（批次 P7-C 3-2）：`CodeMetrics.scanLimitations` 承接
    /// `limitationSummary`，代码规模页据此挂一条"本次是部分测量"的提示。
    struct CodeScanCoverage: Sendable {
        var visitedEntryCount: Int
        var includedFileCount: Int
        var skippedFileCount: Int
        var truncatedByMaxFiles: Bool
        var maxFiles: Int
        var maxFileBytes: Int
        /// 超过 20 万行、只统计了前 20 万行的文件数
        var lineTruncatedFileCount: Int
        /// 归一化行数触到重复检测滑窗上限（2 万行/文件）而被丢弃后半部分的文件数
        var filesHittingDuplicateLineCap: Int
        /// 因每指纹片段预算而未展开成明细片段的拷贝窗口数
        var duplicateFragmentsDroppedByBudget: Int
        /// 榜单截断到 20 块时丢掉的块数与它们覆盖的行数
        var duplicateBlocksDroppedByCap: Int
        var duplicateLinesOutsideReportedBlocks: Int
        /// 遍历中读不动的目录数（权限 / 竞态消失）。这些子树里的文件**一个都没看到**，
        /// 与"看了、没有"是两件事 —— 见 `SourceScanResult.unreadableDirectoryCount`。
        var unreadableDirectoryCount: Int = 0
        var skipLedger: SourceSkipLedger = SourceSkipLedger()

        /// 有任一**上限**真的生效过 ⇒ 这份数字是部分测量，UI 不得当成全量展示。
        /// 注意不含「按规则主动排除」：跳过 vendor/二进制是范围定义，不是被截断。
        var isPartial: Bool {
            truncatedByMaxFiles || lineTruncatedFileCount > 0 || skippedFileCount > 0
                || filesHittingDuplicateLineCap > 0 || duplicateFragmentsDroppedByBudget > 0
                || duplicateBlocksDroppedByCap > 0 || unreadableDirectoryCount > 0
        }

        /// 有多少条目是按规则排除的（范围问题），与「被上限切掉」分开报，两件事混在一起用户就没法判断偏差方向。
        var excludedEntryCount: Int { skipLedger.skippedFileTotal }
        var excludedLineCount: Int { skipLedger.skippedLineTotal }

        /// 完整的「少掉的部分去哪了」清账，一行一条原因。`skipLedgerAuditRan` 为 false 时
        /// 如实标注行数未统计，不会把 0 当成「这些文件没有行」。
        func skipClearing() -> [String] {
            skipLedger.clearing(linesCounted: skipLedger.linesCounted)
        }

        /// 逐条带真实数字的限制说明，供横幅/脚注直接展示。
        var limitationSummary: [String] {
            var lines: [String] = []
            if truncatedByMaxFiles {
                lines.append("达到单次扫描文件上限 \(NumberFormat.grouped(maxFiles))，其余文件未读，结果偏小。")
            }
            if lineTruncatedFileCount > 0 {
                lines.append("\(NumberFormat.grouped(lineTruncatedFileCount)) 个文件超过 20 万行，只统计了前 20 万行。")
            }
            if skippedFileCount > 0 {
                lines.append("\(NumberFormat.grouped(skippedFileCount)) 个文件被跳过（超过 \(ByteFormat.string(UInt64(maxFileBytes))) 单文件上限、二进制或语言表未收录）。")
            }
            if skipLedger.skippedFileTotal > 0 {
                // 逐条原因的清账（条数 + 体积 + 行数到底统没统计），顶掉以前那句
                // 「另有 N 个条目按规则未纳入统计。」—— 那句只给一个总数，读者既不知道
                // 少在哪一类，也无从知道"行数"是没数还是数了是 0。
                // 审计模式（`countSkippedLines`）要额外读盘、预算 400 MB，产品默认不开：
                // 这一页的性能预算留给杀手功能，但**没数过就得写没数过**。
                lines.append(contentsOf: skipClearing())
            }
            if unreadableDirectoryCount > 0 {
                lines.append("\(NumberFormat.grouped(unreadableDirectoryCount)) 个目录读不动（权限不够或已消失），"
                    + "这些子树里的文件一个都没看到 —— 少掉的不是数量，是**看过的范围**。")
            }
            if filesHittingDuplicateLineCap > 0 {
                lines.append("\(NumberFormat.grouped(filesHittingDuplicateLineCap)) 个文件的重复检测只看前 2 万归一化行。")
            }
            if duplicateFragmentsDroppedByBudget > 0 || duplicateBlocksDroppedByCap > 0 {
                lines.append("重复率按全量命中计算，但明细榜单截断到 20 块、片段展开受指纹预算限制"
                    + "（本次未展开 \(NumberFormat.grouped(duplicateFragmentsDroppedByBudget)) 处拷贝、"
                    + "未列出 \(NumberFormat.grouped(duplicateBlocksDroppedByCap)) 个块 / "
                    + "\(NumberFormat.grouped(duplicateLinesOutsideReportedBlocks)) 行）。")
            }
            return lines
        }
    }

    func analyze(root: URL, options: ScanOptions) async throws -> CodeMetrics {
        try await analyzeWithCoverage(root: root, options: options).metrics
    }

    struct AnalysisOutcome: Sendable {
        var metrics: CodeMetrics
        var coverage: CodeScanCoverage
    }

    /// 与 `analyze` 同一次遍历、同一批数据，额外带回覆盖度；不重复扫描。
    func analyzeWithCoverage(root: URL, options: ScanOptions) async throws -> AnalysisOutcome {
        let startedAt = Date()

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AnalysisError.notDirectory(root.path)
        }

        let scan = await SourceTreeScanner(options: options).scan(root: root)
        let files = scan.files

        let functionTask = Task.detached(priority: .userInitiated) { () -> [[FunctionCandidate]] in
            files.map { ComplexityEngine.functions(in: $0) }
        }
        let duplicationTask = Task.detached(priority: .userInitiated) { () -> DuplicationResult in
            DuplicationEngine.analyze(files)
        }
        let functionsPerFile = await functionTask.value
        let duplication = await duplicationTask.value

        var metrics = CodeMetrics()
        metrics.scannedAt = startedAt
        metrics.durationMs = max(1, Int(Date().timeIntervalSince(startedAt) * 1000))
        apply(
            files: files,
            functionsPerFile: functionsPerFile,
            duplication: duplication,
            to: &metrics
        )
        let coverage = CodeScanCoverage(
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
            skipLedger: scan.skipLedger
        )
        // 契约接入（P7-C 3-2）：判据用 `limitationSummary` 非空而不是 `isPartial` —— 前者还含
        // 「按规则排除了多少条目」这类**范围**事实，读者要知道数字是在什么范围内测出来的。
        let limits = coverage.limitationSummary
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
