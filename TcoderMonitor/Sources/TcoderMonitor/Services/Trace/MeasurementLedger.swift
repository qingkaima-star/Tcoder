import Foundation

/// R10b 第 2 件：**测量台账** —— 把「量出来的原始计数」与「算出来的比值/分位/评分」分栏，
/// 派生项逐条写明它由**哪几个测量项**算来。
///
/// 为什么要分栏：一份报告里「代码行数 12,345」与「重复率 8.4%」在屏上长得一样像真值，
/// 但前者的错法是"数错了"，后者的错法是"数对了、公式或分母错了"（本仓两种都犯过：
/// 分母用错总体把 91.4% 的集中度算成 51%，见 `GitInsights.authorBasisCommits` 的注释）。
/// 分开摆 + 点名来源，读的人才能只对那一半打折。
///
/// 两条红线（`ReportTraceabilityTests` 里各有一条反例钉着）：
/// 1. **本文件一次都不读盘、不重扫源码**。每个数都是从 `ProjectReport` 里已有的类型读出来的。
///    台账自己再扫一遍 ⇒ 与代码那一路迟早分叉（本轮这条坑踩过三次）。
/// 2. **派生项必须点名它由哪些测量项算来**，且点名的那些项必须真的在测量栏里
///    （`danglingSources` 非空 = 来源是编的）。要往这里加新字段，先报总工落 `Models/**`，
///    不许在本文件里私加一个"顺手算出来的"第五把尺子。
enum MeasurementBasis: String, Equatable, CaseIterable {
    case measured = "量出来的"
    case derived = "算出来的"
}

struct MeasurementRow: Equatable {
    var basis: MeasurementBasis
    /// 哪一路产的。五路用 `AnalyzerLedger.sectionLabels` 里那五个名字，
    /// 评分那一栏用 `MeasurementLedger.scorerPath`（它不是分析路，别混进五路计数）。
    var path: String
    /// 读数名。**派生项的 `source` 引用的就是这些名字**，所以名字只在这一处定义。
    var item: String
    var value: String
    /// measured：这个数落在契约的哪个字段上；derived：它由哪些测量项算来（用 `item` 名）。
    var source: [String]

    var key: String { "\(path) · \(item)" }
}

/// 测量项的名字只这一份：派生行引用常量，不重抄字符串。
/// 抄第二遍就会在改名字时留下"来源指着一个不存在的测量项"的 dangling。
enum MeasuredItem {
    static let files = "文件数"
    static let totalLines = "总行数"
    static let codeLines = "代码行数"
    static let commentLines = "注释行数"
    static let functions = "识别出的函数数"
    static let hotspotBoard = "复杂度上榜函数条数"
    static let hugeFileBoard = "巨大文件榜内条数"
    static let hugeFileTotal = "巨大文件真个数"
    static let duplicateBlocks = "重复块榜内条数"
    static let duplicatedLines = "重复块覆盖行数"
    static let analyzerDuration = "代码那一路的自计耗时"
    static let commits = "提交数"
    static let commitsAnalyzed = "实际解析的提交数"
    static let authorTableSize = "作者表条数"
    static let authorCommitsSum = "作者表提交数逐条之和"
    static let topAuthorCommits = "署名最多作者的提交数"
    static let activeAuthors = "活跃作者数"
    static let firstCommit = "最早提交时间"
    static let lastCommit = "最晚提交时间"
    static let scanLines = "扫到的日志行数"
    static let errorCount = "错误行数"
    static let warningCount = "告警行数"
    static let crashCount = "崩溃行数"
    static let logFileCount = "日志文件数"
    static let unreadableLogFiles = "读不动的日志文件数"
    static let dependencyRecords = "清单里读到的依赖条数"
    static let advisoryRows = "在线通告条数"
    static let offlineVulnRows = "内置快照命中条数"
    static let outdatedRows = "判为过期的依赖条数"
    static let coveredLines = "生产码已覆盖行"
    static let totalCoverableLines = "生产码总行"
    static let allCoveredLines = "全口径已覆盖行"
    static let allTotalLines = "全口径总行"
    static let componentScores = "各分量分"
    static let componentWeights = "各分量权重"
    static let codeScopeMembers = "代码口径计入的维度名"
}

struct MeasurementLedger: Equatable {

    /// 评分那一栏的归属名。刻意**不在**五路路名里：`HealthScore` 不是分析器，
    /// 它是把五路的读数再算一遍的那一步。
    static let scorerPath = "健康评分"

    var rows: [MeasurementRow]

    var measuredRows: [MeasurementRow] { rows.filter { $0.basis == .measured } }
    var derivedRows: [MeasurementRow] { rows.filter { $0.basis == .derived } }

    /// 反例①：派生项没点名来源 ⇒ 这一行不许当结论读（宁可少一行，也不留一条来路不明的"算出来的"）。
    var derivedWithoutNamedSource: [MeasurementRow] {
        derivedRows.filter { $0.source.isEmpty }
    }

    /// 本台账里出现过的所有读数名（甲栏与乙栏都算）—— 派生项引用另一个派生项是合法的，
    /// 但**不许引一个不存在的名字**。
    var knownItems: Set<String> { Set(rows.map(\.item)) }

    /// 反例②：派生项点名的来源既不是本表里的读数、也不在"契约外上游"清单里 ⇒ 来源是编的。
    /// 这一条就是「派生项不许凭空多一把尺子」的机器形状：要引新上游，
    /// 必须先在 `upstreamInputs` 里逐条写下它从哪来、凭什么不是第二次扫描。
    var danglingSources: [String] {
        let known = knownItems.union(MeasurementLedger.upstreamInputs.keys)
        return derivedRows.flatMap(\.source).filter { known.contains($0) == false }.sorted()
    }

    /// 契约里没有单独字段、但派生公式确实要吃的上游 —— **逐条点名并各写一句理由**。
    /// 与 `scripts/report_parity.py` 的容忍清单同一种纪律：静默引一个不存在的来源，
    /// 等于给一个派生读数编一条来路。这里的每一条都要求"值由分析器在同一次扫描里算过"，
    /// 也就是**不许由本文件去盘上再量一遍**。
    static let upstreamInputs: [String: String] = [
        "各函数行数之和": "ComplexityEngine 识别出每个函数时就读过它的行数，评分器求和后取整平均成 "
            + "CodeMetrics.averageFunctionLength；和值本身没有单独字段 ⇒ 只能引用，不能在本表里重算",
        "各函数 CC 之和": "同上，averageCyclomaticComplexity 的分子；分母才是落盘的 analyzedFunctionCount",
        "每条命中的受影响包/依赖数": "vulnerableCount 在 DependencyReport 里逐条相加 "
            + "affectedPackages / affectedDependencies，聚合发生在契约侧不在这里",
        "各错误簇 firstSeen/lastSeen": "ErrorCluster 自带两个时间戳，「今日」这一格按日志窗口现算，"
            + "契约里没有单独的今日计数字段",
    ]

    /// 两栏并排上屏。栏名带「甲/乙」是为了让它在一屏里可指认
    /// （「乙栏第三行」这种话在取证时能用）。
    func text() -> [String] {
        var lines: [String] = ["测量台账（甲＝量出来的原始计数，乙＝算出来的比值/分位/评分；"
                               + "乙栏每一项都写明它由哪几项算来）"]
        lines.append("  甲·量出来的 \(measuredRows.count) 项：")
        lines.append(contentsOf: measuredRows.map { "    \($0.path) · \($0.item) = \($0.value)"
            + "（\($0.source.joined(separator: localizedListSeparator()))）" })
        lines.append("  乙·算出来的 \(derivedRows.count) 项：")
        lines.append(contentsOf: derivedRows.map { "    \($0.path) · \($0.item) = \($0.value)"
            + " ← 由「" + $0.source.joined(separator: localizedListSeparator()) + "」算来" })
        let orphans = derivedWithoutNamedSource.count
        if orphans > 0 {
            lines.append("    ⚠ \(orphans) 项派生读数没点名来源 —— 这些项不许当结论读")
        }
        let dangling = danglingSources
        if dangling.isEmpty == false {
            lines.append("    ⚠ \(dangling.count) 个来源名在本表与上游清单里都不存在："
                         + dangling.joined(separator: localizedListSeparator()) + " —— 台账有出处写错了")
        }
        return lines
    }
}

/// 派生读数名里被**别的派生行引用**的那几个（引用名字而不是重抄字符串，改名时编译就跟着走）。
enum DerivedItem {
    static let topAuthorShare = "署名集中度"
    static let vulnerableTotal = "漏洞总数（占比分子）"
    static let scoredLinePercent = "生产码行覆盖率（计分口径）"
}

extension MeasurementLedger {

    // MARK: - 行的构造器（measured / derived 两种栏，形状只这一处）

    private static func measured(_ path: String, _ item: String, _ value: String,
                                 from: [String]) -> MeasurementRow {
        MeasurementRow(basis: .measured, path: path, item: item, value: value, source: from)
    }

    private static func derived(_ path: String, _ item: String, _ value: String,
                                from: [String]) -> MeasurementRow {
        MeasurementRow(basis: .derived, path: path, item: item, value: value, source: from)
    }

    private static func int(_ value: Int) -> String { NumberFormat.grouped(value) }

    private static func ratio(_ value: Double?) -> String {
        guard let value else { return "未量到" }
        return String(format: "%.2f", value)
    }

    /// 从一份已装配好的报告建台账。**只读**报告里已有的字段：不碰盘、不起进程、不重扫源码
    /// （红线第 1 条）。某一路缺席时照样出一行说明它缺席，不静默少一整栏。
    static func of(_ report: ProjectReport) -> MeasurementLedger {
        MeasurementLedger(rows: codeRows(report.code) + gitRows(report.git) + logsRows(report.logs)
            + dependencyRows(report.dependencies) + coverageRows(report.coverage) + scoreRows(report.health))
    }

    /// 一路没产出结果时**照样出一行**说它没产出：静默少一整栏会被读成"这一路没什么可报"，
    /// 而实情是那一路压根没交回东西（状态与原因去上面那段台账问）。
    private static func absent(_ path: String, field: String) -> [MeasurementRow] {
        [measured(path, "该路读数", "未量到（\(field) 缺席）", from: [field])]
    }

    private static func codeRows(_ code: CodeMetrics?) -> [MeasurementRow] {
        let path = AnalyzerLedger.sectionLabels[0]
        guard let code else { return absent(path, field: "code") }
        let boardSize = code.topComplexFunctions.count
        let hugeBoard = code.hugeFiles.count
        let duplicateBoard = code.duplicatedBlocks.count
        let duplicatedLines = code.duplicatedBlocks.reduce(0) { $0 + $1.lineCount }
        return [
            measured(path, MeasuredItem.files, int(code.totalFiles), from: ["CodeMetrics.totalFiles"]),
            measured(path, MeasuredItem.totalLines, int(code.totalLines), from: ["CodeMetrics.totalLines"]),
            measured(path, MeasuredItem.codeLines, int(code.codeLines), from: ["CodeMetrics.codeLines"]),
            measured(path, MeasuredItem.commentLines, int(code.commentLines), from: ["CodeMetrics.commentLines"]),
            measured(path, MeasuredItem.functions, int(code.analyzedFunctionCount),
                     from: ["CodeMetrics.analyzedFunctionCount"]),
            measured(path, MeasuredItem.hotspotBoard, int(boardSize),
                     from: ["CodeMetrics.topComplexFunctions 榜长（截断到 20，不是总数）"]),
            measured(path, MeasuredItem.hugeFileBoard, int(hugeBoard),
                     from: ["CodeMetrics.hugeFiles 榜长（截断到 20，不是总数）"]),
            measured(path, MeasuredItem.hugeFileTotal,
                     code.hugeFileCount.map(int) ?? "未记录（旧报告没这一格）",
                     from: ["CodeMetrics.hugeFileCount"]),
            measured(path, MeasuredItem.duplicateBlocks, int(duplicateBoard),
                     from: ["CodeMetrics.duplicatedBlocks 榜长"]),
            measured(path, MeasuredItem.duplicatedLines, int(duplicatedLines),
                     from: ["重复块榜内逐块 lineCount 之和（只含榜内，榜外未计入）"]),
            measured(path, MeasuredItem.analyzerDuration, "\(code.durationMs) ms",
                     from: ["CodeMetrics.durationMs（分析器自计，不含调度；台账那枚含调度 —— 两把尺子都留着）"]),
            derived(path, "注释占比", ratio(code.commentRatio),
                    from: [MeasuredItem.commentLines, MeasuredItem.totalLines]),
            derived(path, "平均函数长度", int(code.averageFunctionLength),
                    from: [MeasuredItem.functions, "各函数行数之和"]),
            derived(path, "平均圈复杂度", ratio(code.averageCyclomaticComplexity),
                    from: [MeasuredItem.functions, "各函数 CC 之和"]),
            derived(path, "重复行占比", ratio(code.duplicationRatio),
                    from: [MeasuredItem.duplicatedLines, MeasuredItem.codeLines]),
            derived(path, "判档达「高」及以上的函数数", int(code.reportedHighRiskHotspotCount),
                    from: [code.highRiskHotspotCount == nil ? MeasuredItem.hotspotBoard
                                                            : MeasuredItem.functions]),
            derived(path, "占比用的巨大文件数", int(code.reportedHugeFileCount),
                    from: [code.hugeFileCount == nil ? MeasuredItem.hugeFileBoard
                                                     : MeasuredItem.hugeFileTotal]),
        ]
    }

    private static func gitRows(_ git: GitInsights?) -> [MeasurementRow] {
        let path = AnalyzerLedger.sectionLabels[1]
        guard let git else { return absent(path, field: "git") }
        let top = git.topAuthor
        return [
            measured(path, MeasuredItem.commits, int(git.totalCommits), from: ["GitInsights.totalCommits（含合并）"]),
            measured(path, MeasuredItem.commitsAnalyzed, int(git.commitsAnalyzed),
                     from: ["GitInsights.commitsAnalyzed（上限内真解析数）"]),
            measured(path, "历史是否被截断", git.historyTruncated ? "是" : "否",
                     from: ["GitInsights.historyTruncated"]),
            measured(path, MeasuredItem.authorTableSize, int(git.authors.count), from: ["GitInsights.authors 条数"]),
            measured(path, MeasuredItem.authorCommitsSum, int(git.authorBasisCommits),
                     from: ["作者表逐条 commits 相加（--no-merges 口径）"]),
            measured(path, MeasuredItem.topAuthorCommits, int(top?.commits ?? 0),
                     from: ["最活跃那一行的 commits（作者表内 max，不再取一次 git）"]),
            measured(path, MeasuredItem.activeAuthors, int(git.activeAuthorCount),
                     from: ["作者表里 commits>0 的行数"]),
            measured(path, MeasuredItem.firstCommit, git.firstCommitAt.map { DateFormat.day.string(from: $0) } ?? "未记录",
                     from: ["GitInsights.firstCommitAt"]),
            measured(path, MeasuredItem.lastCommit, git.lastCommitAt.map { DateFormat.day.string(from: $0) } ?? "未记录",
                     from: ["GitInsights.lastCommitAt"]),
            measured(path, "工作区未提交条数", git.dirtyEntryCount.map(int) ?? "未量到",
                     from: ["GitInsights.dirtyEntryCount"]),
            derived(path, "日均提交", String(format: "%.2f", git.commitsPerDay),
                    from: [MeasuredItem.commits, MeasuredItem.firstCommit, MeasuredItem.lastCommit]),
            derived(path, "仓库年龄（天）", int(git.projectAgeDays),
                    from: [MeasuredItem.firstCommit, MeasuredItem.lastCommit]),
            derived(path, DerivedItem.topAuthorShare, top == nil || git.authorBasisCommits == 0
                        ? "未量到（分母为 0）"
                        : NumberFormat.percent(Double(top!.commits) / Double(git.authorBasisCommits)),
                    from: [MeasuredItem.topAuthorCommits, MeasuredItem.authorCommitsSum]),
            derived(path, "协作分布判级", git.busFactorRisk.rawValue,
                    from: [DerivedItem.topAuthorShare, MeasuredItem.activeAuthors]),
        ]
    }

    private static func logsRows(_ logs: LogSummary?) -> [MeasurementRow] {
        let path = AnalyzerLedger.sectionLabels[2]
        guard let logs else { return absent(path, field: "logs") }
        return [
            measured(path, MeasuredItem.scanLines, int(logs.totalLinesScanned), from: ["LogSummary.totalLinesScanned"]),
            measured(path, MeasuredItem.logFileCount, int(logs.scannedFiles.count), from: ["LogSummary.scannedFiles 条数"]),
            measured(path, MeasuredItem.unreadableLogFiles,
                     logs.readFailedFiles.map { int($0.count) } ?? "未统计（旧结构没这一格）",
                     from: ["LogSummary.readFailedFiles"]),
            measured(path, MeasuredItem.errorCount, int(logs.errorCount), from: ["逐条按等级计出的行数"]),
            measured(path, MeasuredItem.warningCount, int(logs.warningCount), from: ["逐条按等级计出的行数"]),
            measured(path, MeasuredItem.crashCount, int(logs.crashCount), from: ["逐条按等级计出的行数"]),
            derived(path, "今日错误数", int(logs.todayErrorCount),
                    from: [MeasuredItem.errorCount, "各错误簇 firstSeen/lastSeen"]),
            derived(path, "运行稳定性判级", logs.overallRisk.rawValue,
                    from: [MeasuredItem.errorCount, MeasuredItem.crashCount, MeasuredItem.scanLines]),
        ]
    }

    private static func dependencyRows(_ deps: DependencyReport?) -> [MeasurementRow] {
        let path = AnalyzerLedger.sectionLabels[3]
        guard let deps else { return absent(path, field: "dependencies") }
        return [
            measured(path, MeasuredItem.dependencyRecords, int(deps.totalDependencies),
                     from: ["各清单解析出的依赖条数逐份相加"]),
            measured(path, MeasuredItem.advisoryRows, int(deps.advisories.count),
                     from: ["SecurityAdvisory 条数（OSV 回包）"]),
            measured(path, MeasuredItem.offlineVulnRows, int(deps.offlineVulnerabilities.count),
                     from: ["VulnerabilitySource.matches 命中条数"]),
            measured(path, MeasuredItem.outdatedRows, int(deps.outdatedCount),
                     from: ["逐条 DependencyRecord.isProbablyOutdated 的真假计数"]),
            measured(path, "是否核对过在线源", deps.networkLookupPerformed ? "是" : "否",
                     from: ["DependencyReport.networkLookupPerformed"]),
            derived(path, DerivedItem.vulnerableTotal, int(deps.vulnerableCount),
                    from: [MeasuredItem.advisoryRows, MeasuredItem.offlineVulnRows,
                           "每条命中的受影响包/依赖数"]),
            derived(path, "过期占比", deps.totalDependencies == 0 ? "未量到（分母为 0）"
                        : NumberFormat.percent(Double(deps.outdatedCount) / Double(deps.totalDependencies)),
                    from: [MeasuredItem.outdatedRows, MeasuredItem.dependencyRecords]),
            derived(path, "依赖健康判级", deps.riskLevel.rawValue,
                    from: [DerivedItem.vulnerableTotal, MeasuredItem.outdatedRows,
                           MeasuredItem.dependencyRecords]),
        ]
    }

    private static func coverageRows(_ coverage: CoverageMetrics?) -> [MeasurementRow] {
        let path = AnalyzerLedger.sectionLabels[4]
        guard let coverage else { return absent(path, field: "coverage") }
        let covered = coverage.reports.reduce(0) { $0 + $1.linesCovered }
        let total = coverage.reports.reduce(0) { $0 + $1.linesTotal }
        return [
            measured(path, "覆盖率报告份数", int(coverage.reports.count), from: ["CoverageMetrics.reports 条数"]),
            measured(path, "遍历过的文件数", int(coverage.scannedFileCount), from: ["CoverageMetrics.scannedFileCount"]),
            measured(path, "读不动的目录数",
                     coverage.unreadableDirectoryCount.map(int) ?? "未统计（旧结构没这一格）",
                     from: ["CoverageMetrics.unreadableDirectoryCount"]),
            measured(path, MeasuredItem.coveredLines, int(covered), from: ["逐份报告 linesCovered 相加（生产码口径）"]),
            measured(path, MeasuredItem.totalCoverableLines, int(total), from: ["逐份报告 linesTotal 相加（生产码口径）"]),
            measured(path, MeasuredItem.allCoveredLines,
                     int(coverage.reports.reduce(0) { $0 + ($1.allLinesCovered ?? 0) }),
                     from: ["逐份报告 allLinesCovered 相加（含测试码）"]),
            measured(path, MeasuredItem.allTotalLines,
                     int(coverage.reports.reduce(0) { $0 + ($1.allLinesTotal ?? 0) }),
                     from: ["逐份报告 allLinesTotal 相加（含测试码）"]),
            derived(path, DerivedItem.scoredLinePercent, ratio(coverage.overallLinePercent),
                    from: [MeasuredItem.coveredLines, MeasuredItem.totalCoverableLines]),
            derived(path, "全口径行覆盖率（不参与评分）", ratio(coverage.allSourcesLinePercent),
                    from: [MeasuredItem.allCoveredLines, MeasuredItem.allTotalLines]),
            derived(path, "覆盖率判级", coverage.riskLevel.rawValue,
                    from: [DerivedItem.scoredLinePercent]),
        ]
    }

    private static func scoreRows(_ health: HealthScore?) -> [MeasurementRow] {
        guard let health, health.components.isEmpty == false else {
            return absent(scorerPath, field: "health.components")
        }
        var rows: [MeasurementRow] = [
            measured(scorerPath, MeasuredItem.componentScores,
                     health.components.map { "\($0.name)=\($0.score)" }.joined(separator: " "),
                     from: ["ScoreComponent.score（各维度分析器给的分数，不在这里重算）"]),
            measured(scorerPath, MeasuredItem.componentWeights,
                     health.components.map { "\($0.name)=\(String(format: "%.4f", $0.weight))" }
                        .joined(separator: " "),
                     from: ["ScoreComponent.weight（已按在场的权重归一）"]),
        ]
        rows.append(derived(scorerPath, "综合健康分", health.verdict.map(String.init) ?? "无（没有可计分证据）",
                            from: [MeasuredItem.componentScores, MeasuredItem.componentWeights]))
        rows.append(derived(scorerPath, "权重合计（归一后的检查值）",
                            String(format: "%.4f", health.components.reduce(0) { $0 + $1.weight }),
                            from: [MeasuredItem.componentWeights]))
        if let scope = health.codeScope {
            rows.append(derived(scorerPath, "工程质量（代码口径）", String(scope.overall),
                                from: [MeasuredItem.codeScopeMembers, MeasuredItem.componentScores,
                                       MeasuredItem.componentWeights]))
            rows.append(measured(scorerPath, MeasuredItem.codeScopeMembers,
                                 scope.includedDimensions.joined(separator: localizedListSeparator()),
                                 from: ["HealthSubScore.includedDimensions（名单由评分器给，不在这里挑）"]))
        }
        return rows
    }
}
