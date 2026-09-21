/// OWNER: WS-X3 TestSplit —— 自 SelfScanDogfoodTests.swift 拆出，取证转储十个章节的分节渲染（emit 文本逐字未改）。用例本体未改，只是搬了家。
import XCTest
@testable import TcoderMonitor

extension SelfScanDogfoodTests {

    /// 取证转储的一节（WS-X3 拆分：`testFullSelfScanEvidenceDump` 原 116 行 / CC 16）。1. 代码规模 + 2. 重复率。
    func emitCodeScaleAndDuplicationSections(_ scan: SelfScan, root: String, into lines: inout [String], truth: [GroundTruthFile]) throws {
        func emit(_ text: String) { lines.append(text) }
        emit("—— 1. 代码规模 ——")
        let code = scan.code
        emit([
            "分析器口径 文件=\(code.totalFiles) 总行=\(code.totalLines) 有效码=\(code.codeLines) "
                + "注释=\(code.commentLines) 空行=\(code.blankLines) 耗时=\(code.durationMs)ms",
        ].joined(separator: " "))
        emit("独立口径 .swift 文件=\(truth.count) 行=\(truth.reduce(0) { $0 + $1.lines })")
        emit("语言分布：\(code.languages.prefix(6).map { "\($0.language)=\($0.lineCount)行/\($0.fileCount)个" }.joined(separator: " "))")
        emit("TODO=\(code.todoCount) FIXME=\(code.fixmeCount) 长函数(>\(FileSystemCodeAnalyzer.longFunctionThreshold))=\(code.longFunctions) 平均函数长=\(code.averageFunctionLength)")
        emit("整体风险=\(code.overallRisk.rawValue)")

        emit("—— 2. 重复率 ——")
        emit(String(format: "duplicationRatio=%.4f 重复块=%d", code.duplicationRatio, code.duplicatedBlocks.count))
        for block in code.duplicatedBlocks.prefix(10) {
            let paths = block.occurrences.map { "\($0.path):\(($0.startLine))" }.joined(separator: " ↔ ")
            emit("  重复 \(block.lineCount) 行 相似=\(String(format: "%.2f", block.similarity)) \(paths)")
        }

    }

    /// 取证转储的一节（WS-X3 拆分：`testFullSelfScanEvidenceDump` 原 116 行 / CC 16）。3. 巨大文件榜 + 4. 高圈复杂度榜。
    func emitHugeFileAndHotspotSections(_ scan: SelfScan, root: String, into lines: inout [String]) throws {
        let code = scan.code   // 与第 1 节同源：巨大文件榜与热点榜都读它
        func emit(_ text: String) { lines.append(text) }
        emit("—— 3. 巨大文件榜 ——")
        for file in code.hugeFiles {
            let rel = file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count + 1)) : file.path
            emit("  \(file.lineCount)行 [\(file.risk.rawValue)] \(rel)")
            emit("      建议：\(file.suggestion)")
        }

        emit("—— 4. 高圈复杂度函数 Top 榜 ——")
        for hotspot in code.topComplexFunctions {
            let rel = hotspot.filePath.hasPrefix(root) ? String(hotspot.filePath.dropFirst(root.count + 1)) : hotspot.filePath
            emit("  CC=\(hotspot.cyclomaticComplexity) [\(hotspot.risk.rawValue)] \(rel):\(hotspot.startLine) "
                + "\(hotspot.name)（\(hotspot.lineCount) 行，\(hotspot.parameterCount) 参）")
        }

    }

    /// 取证转储的一节（WS-X3 拆分：`testFullSelfScanEvidenceDump` 原 116 行 / CC 16）。5. 日志分析 + 6. 依赖。
    func emitLogAndDependencySections(_ scan: SelfScan, root: String, into lines: inout [String]) throws {
        func emit(_ text: String) { lines.append(text) }
        emit("—— 5. 日志分析 ——")
        let logs = scan.logs
        emit("hasData=\(logs.hasData) 扫文件=\(logs.scannedFiles.count) 总行=\(logs.totalLinesScanned) "
            + "error=\(logs.errorCount) exception=\(logs.exceptionCount) warning=\(logs.warningCount) "
            + "crash=\(logs.crashCount) fatal=\(logs.fatalCount) 风险=\(logs.overallRisk.rawValue)")
        for cluster in logs.topErrors.prefix(5) {
            emit("  \(cluster.severity.rawValue) ×\(cluster.count) \(cluster.signature)")
        }

        emit("—— 6. 依赖 ——")
        let deps = scan.dependencies
        emit("生态=\(deps.distinctEcosystemNames) 依赖总数=\(deps.totalDependencies) "
            + "生产=\(deps.productionCount) 开发=\(deps.devCount) 过期=\(deps.outdatedCount) "
            + "漏洞=\(deps.vulnerableCount) 风险=\(deps.riskLevel.rawValue) 联网=\(deps.networkLookupPerformed)")
        for eco in deps.ecosystems {
            emit("  \(eco.ecosystem.displayName) 清单=\(eco.manifestPath) lock=\(eco.lockfileName ?? "无") "
                + "依赖=\(eco.dependencies.count) 标记=\(eco.frameworkMarkers)")
        }
        for dep in deps.ecosystems.flatMap(\.dependencies).prefix(15) {
            emit("    \(dep.name) \(dep.version) [\(dep.scope.rawValue)] 最新=\(dep.latestKnownVersion ?? "nil") 来源=\(dep.versionCheckSource.rawValue)")
        }
        for advisory in deps.advisories.prefix(5) {
            emit("  漏洞 \(advisory.id) [\(advisory.severity.rawValue)] \(advisory.summary)")
        }
        if !deps.networkLookupNote.isEmpty { emit("  联网说明：\(deps.networkLookupNote)") }

    }

    /// 取证转储的一节（WS-X3 拆分：`testFullSelfScanEvidenceDump` 原 116 行 / CC 16）。7. 覆盖率 + 8. Git。
    func emitCoverageAndGitSections(_ scan: SelfScan, root: String, into lines: inout [String]) throws {
        func emit(_ text: String) { lines.append(text) }
        emit("—— 7. 覆盖率 ——")
        emit("hasData=\(scan.coverage.hasData) 报告数=\(scan.coverage.reports.count) 扫描文件=\(scan.coverage.scannedFileCount) "
            + "行覆盖=\(scan.coverage.overallLinePercent.map { String(format: "%.1f%%", $0) } ?? "nil")")
        for report in scan.coverage.reports.prefix(5) {
            emit("  \(report.toolName) [\(report.kind.rawValue)] \(report.linesCovered)/\(report.linesTotal) @\(report.path)")
        }

        emit("—— 8. Git ——")
        let git = scan.git
        emit("isRepo=\(git.isRepository) 模式=\(git.discoveryMode.rawValue) 根=\(git.resolvedRepositoryRoot ?? "nil") "
            + "分支=\(git.branch) 提交=\(git.totalCommits)(窗口 \(git.commitsAnalyzed) 截断=\(git.historyTruncated)) "
            + "增删=+\(git.totalAdditions)/-\(git.totalDeletions) 年龄=\(git.projectAgeDays)天")
        for author in git.authors {
            emit("  \(author.name) <\(author.email)> 提交=\(author.commits) +\(author.additions)/-\(author.deletions) 风险=\(git.busFactorRisk.rawValue)")
        }

    }

    /// 取证转储的一节（WS-X3 拆分：`testFullSelfScanEvidenceDump` 原 116 行 / CC 16）。9. 健康评分与全部分量。
    func emitHealthSection(_ scan: SelfScan, root: String, into lines: inout [String]) throws {
        func emit(_ text: String) { lines.append(text) }
        emit("—— 9. 健康评分与全部分量 ——")
        let health = scan.health
        emit("总分=\(health.overall) 等级=\(health.grade.rawValue)")
        for component in health.components {
            emit("  \(component.name) 分=\(component.score) 权重=\(String(format: "%.3f", component.weight)) "
                + "贡献=\(String(format: "%.1f", component.weightedContribution)) 风险=\(component.risk.rawValue)")
            emit("      \(component.detail)")
        }
        emit("总评：\(health.narrative)")
        emit("优势：\(health.strengths)")
        emit("问题：\(health.issues)")
        emit("建议：\(health.recommendations)")

    }

    /// 取证转储的一节（WS-X3 拆分：`testFullSelfScanEvidenceDump` 原 116 行 / CC 16）。10. 普查 vs 榜单（绕开 prefix(20) 自己数）。
    func emitComplexityCensusSection(_ scan: SelfScan, root: String, into lines: inout [String], truth: [GroundTruthFile]) async throws {
        func emit(_ text: String) { lines.append(text) }
        let census = try await complexityCensus()
        emit("—— 10. 普查 vs 榜单（绕开 prefix(20) 自己数）——")
        emit("全仓函数 \(census.functionCount) 个，全仓均复杂度 \(String(format: "%.2f", census.repoMean))，"
            + "≥\(Self.complexFunctionBar) 的 \(census.atLeast16) 个，≥21 的 \(census.atLeast21) 个，"
            + "≥31 的 \(census.atLeast31) 个，最高 \(census.maxValue)")
        emit("榜单 topComplexFunctions 只留 \(scan.code.topComplexFunctions.count) 条（被 prefix(20) 截断），"
            + "其均值 \(String(format: "%.1f", census.hotspotMean)) ← 评分现在用的就是这个数")
        emit("独立口径 >\(Self.toolHighFileLines) 行的 .swift 文件 \(truth.filter { $0.lines > Self.toolHighFileLines }.count) 个，"
            + ">1000 行 \(truth.filter { $0.lines > Self.thousandLineBar }.count) 个")
    }

}
