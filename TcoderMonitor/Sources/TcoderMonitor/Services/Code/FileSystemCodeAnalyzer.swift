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
        return metrics
    }

    /// 兼容无参构造（AppState 用的就是 `FileSystemCodeAnalyzer()`）。
    func analyze(root: URL) async throws -> CodeMetrics {
        try await analyze(root: root, options: fallbackOptions)
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
