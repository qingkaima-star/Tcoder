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
    /// 契约缺口：`CodeMetrics` 没有承接字段（Models 是冻结区），所以视图现在还读不到它 ——
    /// 已把中文化的 `limitationSummary` 备好后交给总工决定接入点。
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
        var skipLedger: SourceSkipLedger = SourceSkipLedger()

        /// 有任一**上限**真的生效过 ⇒ 这份数字是部分测量，UI 不得当成全量展示。
        /// 注意不含「按规则主动排除」：跳过 vendor/二进制是范围定义，不是被截断。
        var isPartial: Bool {
            truncatedByMaxFiles || lineTruncatedFileCount > 0 || skippedFileCount > 0
                || filesHittingDuplicateLineCap > 0 || duplicateFragmentsDroppedByBudget > 0
                || duplicateBlocksDroppedByCap > 0
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
                let top = skipLedger.topLineRules(.excludedDirectoryContent)
                lines.append("另有 \(NumberFormat.grouped(skipLedger.skippedFileTotal)) 个条目按规则未纳入统计"
                    + (top.isEmpty ? "。" : "，按行数排序：\(top)。"))
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
            skipLedger: scan.skipLedger
        )
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

        metrics.totalFiles = files.count
        // totalLines 取真实行计数之和；不变式由单测在真实目录上把关。
        metrics.totalLines = total
        metrics.blankLines = blank
        metrics.commentLines = comment
        metrics.codeLines = code
        metrics.todoCount = todo
        metrics.fixmeCount = fixme
        metrics.languages = languageShares(files: files, codeLineTotal: code)

        let largest = files.map(\.totalLineCount).max() ?? 0
        metrics.largestFileLineCount = largest
        metrics.hugeFiles = hugeFiles(files: files, functionsPerFile: functionsPerFile)

        let hotspots = hotspots(files: files, functionsPerFile: functionsPerFile)
        metrics.topComplexFunctions = Array(hotspots.sorted {
            if $0.cyclomaticComplexity != $1.cyclomaticComplexity {
                return $0.cyclomaticComplexity > $1.cyclomaticComplexity
            }
            return $0.lineCount > $1.lineCount
        }.prefix(20))

        let allFunctions = functionsPerFile.flatMap { $0 }
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

        metrics.duplicationRatio = duplication.ratio
        metrics.duplicatedBlocks = duplication.blocks
        metrics.overallRisk = overallRisk(
            metrics: metrics,
            hotspotCount: hotspots.count,
            longestFileLines: largest
        )
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
        return Array(result.sorted { $0.lineCount > $1.lineCount }.prefix(20))
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

    // MARK: - Risk model

    static let criticalFunctionComplexity = 31
    static let highFunctionComplexity = 21
    static let mediumFunctionComplexity = 11
    static let longFunctionThreshold = 50
    static let criticalFileLines = 1_500
    static let highFileLines = 800
    static let mediumFileLines = 400

    private func functionRisk(complexity: Int, lineCount: Int) -> RiskLevel {
        var risk: RiskLevel = complexity >= Self.criticalFunctionComplexity ? .critical
            : complexity >= Self.highFunctionComplexity ? .high
            : complexity >= Self.mediumFunctionComplexity ? .medium
            : .low
        if lineCount > 100 {
            risk = max(risk, RiskLevel.high)
        } else if lineCount > Self.longFunctionThreshold {
            risk = max(risk, RiskLevel.medium)
        }
        return risk
    }

    private func fileRisk(forLines lines: Int) -> RiskLevel {
        lines > Self.criticalFileLines ? .high : lines > Self.highFileLines ? .medium : .low
    }

    private func overallRisk(
        metrics: CodeMetrics,
        hotspotCount: Int,
        longestFileLines: Int
    ) -> RiskLevel {
        var score = 0

        let complexityBuckets = metrics.topComplexFunctions.map(\.risk)
        if complexityBuckets.contains(.critical) {
            score = max(score, 4)
        }
        if complexityBuckets.filter { $0 == .high }.count >= 3 {
            score = max(score, 3)
        } else if complexityBuckets.contains(.high) {
            score = max(score, 2)
        } else if complexityBuckets.contains(.medium) {
            score = max(score, 1)
        }

        let ratio = metrics.duplicationRatio
        if ratio >= 0.25 {
            score = max(score, 4)
        } else if ratio >= 0.15 {
            score = max(score, 3)
        } else if ratio >= 0.08 {
            score = max(score, 2)
        } else if ratio > 0 {
            score = max(score, 1)
        }

        if longestFileLines > Self.criticalFileLines {
            score = max(score, 3)
        } else if longestFileLines > Self.highFileLines {
            score = max(score, 2)
        } else if longestFileLines > Self.mediumFileLines {
            score = max(score, 1)
        }

        if hotspotCount > 10 {
            score = max(score, 2)
        }

        switch score {
        case 4: return .critical
        case 3: return .high
        case 2: return .medium
        case 1: return .low
        default: return .none
        }
    }

    // MARK: - Suggestions

    private func splitSuggestion(for file: ScannedSourceFile, functions: [FunctionCandidate]) -> String {
        let lines = file.totalLineCount
        let longOnes = functions.filter { $0.lineCount > Self.longFunctionThreshold }
        let longest = functions.map(\.lineCount).max() ?? 0
        let longestName = longestFunctionNameSample(functions)

        if functions.isEmpty {
            if file.codeLineCount * 4 < lines {
                return "\(file.language) 文件 \(NumberFormat.grouped(lines)) 行，几乎全是注释或文档：精简历史说明、把示例迁出源码目录，只保留必要的接口注释。"
            }
            return "\(file.language) 文件 \(NumberFormat.grouped(lines)) 行且未被识别出函数（多为配置、模板或数据表）：按领域或路由拆成多个文件，或改为外部数据资源加载。"
        }
        if !longOnes.isEmpty {
            return "\(file.language) 文件 \(NumberFormat.grouped(lines)) 行、含 \(longOnes.count) 个超过 \(Self.longFunctionThreshold) 行的函数（最长 \(longest) 行，如 \(longestName)）：先把这些函数按职责抽成独立类型或同类型的 extension，再把跨函数共享的状态收进构造注入的依赖，目标单文件 400 行以内。"
        }
        let topName = functions.sorted { $0.lineCount > $1.lineCount }.first?.name ?? "未知函数"
        return "\(file.language) 文件 \(NumberFormat.grouped(lines)) 行但函数都不长（\(functions.count) 个，最长 \(longest) 行）：按能力域横向切分成多个文件或子类型（例如解析/渲染/IO 分开），\(topName) 所在的这段职责适合第一个搬出去。"
    }

    private func longestFunctionNameSample(_ functions: [FunctionCandidate]) -> String {
        functions
            .sorted { $0.lineCount > $1.lineCount }
            .first?
            .name ?? "未知函数"
    }
}
