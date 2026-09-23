import Foundation

/// Entry point that composes WS-C's engines: LogDiscovery -> LogReader ->
/// (CrashReportParser for .ips) -> LogAggregator. Runs inside the detached
/// analysis task AppState already provides, so the file IO stays off the main actor.
final class FileLogAnalyzer: LogAnalysisProviding {
    private static let maxBytesPerFile = 20_000_000
    private static let maxLinesPerFile = 50_000
    private static let maxDiscoveredFiles = 60
    private static let topErrorLimit = 20

    func analyze(projectRoot: URL, extraLogURLs: [URL], withinDays: Int) async throws -> LogSummary {
        let result = try analyzeWithEvidence(projectRoot: projectRoot, extraLogURLs: extraLogURLs,
                                             withinDays: withinDays)
        return result.summary
    }

    /// 与 `analyze` 同一条流水线，只是**额外**交回崩溃证据台账。
    ///
    /// 为什么要两个口子：`analyze` 是冻结协议 `LogAnalysisProviding` 的签名（只回 `LogSummary`），
    /// GUI 与 CLI 都走它；`analyzeWithEvidence` 多交回一本台账，给要逐条原因的用例与直接调用方。
    /// RD-60 第二半之后**两条路说的是同一句真话**：八种原因已经由上面那段直传进
    /// `summary.crashEvidence`（九格快照），所以 `analyze` 交回的 `LogSummary` 自己就带着细账，
    /// 视图与 CLI 从落盘字段按名字接回即可，不必再拿到台账本体。
    /// **不许**因为字段放不下就把这些状态折进 `crashCount` 或干脆不算。
    func analyzeWithEvidence(projectRoot: URL, extraLogURLs: [URL], withinDays: Int) throws
        -> (summary: LogSummary, evidence: CrashEvidenceLedger) {
        let windowDays = max(1, withinDays)
        let targets = dedupedTargets(projectRoot: projectRoot, windowDays: windowDays,
                                     extraLogURLs: extraLogURLs)
        // 与 `attached(urls:)` 一字同形：那条路不做 canonical 化，这里也不能多做，
        // 否则例外名单会指到一个不一样的路径上（例：/private/var 与 /var）。
        let attachedPaths = Set(extraLogURLs.map(\.path))
        let batch = readAll(targets)
        let readings = batch.readings

        // 观察窗口按**事件时间**落实；mtime 只在 `LogDiscovery` 里用于发现候选。
        let cutoff = Date().addingTimeInterval(-Double(windowDays) * 86_400)
        let ledger = CrashEvidenceLedger.build(records: batch.records, windowCutoff: cutoff)

        let aggregate = LogAggregator.aggregate(
            readings: readings,
            // 进 `crashCount` 的唯一集合：确认崩溃 ∧ 有真实事件时间 ∧ 窗口内 ∧ 非旧构建。
            extraEvents: batch.crashEvents.filter { ledger.countablePaths.contains($0.sourceLogPath) },
            topLimit: Self.topErrorLimit,
            windowCutoff: cutoff,
            // 崩溃通道**出过事件**的路径都算被它接管（哪怕事件最后不够格计数），
            // 否则同一份报告里的 `Exception Type:` 行会被行解析再数一次。
            crashHandledPaths: batch.suppressedPaths,
            windowExemptPaths: attachedPaths
        )

        var summary = LogSummary()
        summary.analyzedAt = Date()
        summary.windowStart = aggregate.windowStart
        summary.windowEnd = aggregate.windowEnd
        summary.errorCount = aggregate.errorCount
        summary.exceptionCount = aggregate.exceptionCount
        summary.warningCount = aggregate.warningCount
        // 台账已经按四态分过类，这里**不再**从 aggregate 二次推导崩溃数。
        summary.crashCount = ledger.countedCrashCount
        // RD-60 的**写者**：八种原因直传**同一个 `ledger`** —— 就是上面那一枚、同一次遍历、
        // 同一次窗口裁剪。为凑字段再 build 一遍台账就是第二把尺子（RD-38/43 那一族）。
        // 两枚读数**同刻同源**钉在这里：`crashCount` 与 `crashEvidence.countedCrashCount`
        // 读的都是 `ledger.countedCrashCount` 这同一个表达式，由 `CrashEvidenceWiringTests`
        // 两条各钉一次（真分析后的值相等 + 源码形状必须同指一个 ledger）。
        // 九格全是台账自己算好的数，这里一个不加不减：`nil`=没统计、`0`=查过真的是 0，
        // 两者不许互相冒充。崩溃这一路跑过就一定写满九格；"没跑"走到不了这一行
        // （那一版报告整键缺席，由 `CrashEvidenceContractTests` 钉旧 JSON 照样解得开）。
        summary.crashEvidence = CrashEvidenceSnapshot(
            countedCrashCount: ledger.countedCrashCount,
            historicalConfirmedCount: ledger.historicalConfirmedCount,
            staleBuildConfirmedCount: ledger.staleBuildConfirmedCount,
            undatedConfirmedCount: ledger.undatedConfirmedCount,
            suspectedCount: ledger.suspectedCount,
            parseFailedCount: ledger.parseFailedCount,
            readFailedCount: ledger.readFailedCount,
            duplicateCount: ledger.duplicateCount,
            filesWithCountedEvidence: ledger.countablePaths.count)
        summary.fatalCount = aggregate.fatalCount
        summary.infoLineCount = aggregate.infoLineCount
        // 分母 = **真日志行**（RD-46b）：崩溃报告的正文已经在 `crashCount` 那一路扣过分，
        // 不许再拿它去稀释「每千行日志错误数」。被移出的那些行没有消失，
        // 它们落在下面两格，界面与 CLI 也仍然逐份留在 `scannedFiles`（role == 崩溃报告，各带行数）。
        // ⚠️ 这条边的后果已立案 **RD-49**：一个只有崩溃报告、没有真日志的项目现在分母是 0，
        //    会让稳定维整维缺席、那几次崩溃也不再扣分。修在 Health 侧
        //    `HealthRuntimeDimensions.stabilityOutcome`（工单 R9b §0），**不在这里**。
        summary.totalLinesScanned = aggregate.totalLinesScanned
        // 两格直传装配口的读数，不在这里二次推导（那就是第二把尺子）。
        // 崩溃分析跑过就一定写值（哪怕是 0 = 「看了，一份都没有」），`nil` 只留给"这一路没跑"。
        summary.crashReportCount = aggregate.crashReportFileCount
        summary.crashReportLineCount = aggregate.crashReportLineCount
        summary.topErrors = aggregate.topErrors
        summary.trend = aggregate.trend
        summary.affectedFiles = aggregate.affectedFiles
        // 读取失败的文件不进「已扫描文件」：`LogSummary.hasData` 认 scannedFiles 非空，
        // 让它们混进来等于用一次权限不足换一张 all-clear（审计 P1 #11）。
        // 读到但内容为空的文件**保留**——那是「已核对零命中」，与「没核对」是两种状态。
        summary.scannedFiles = Self.scannableReadings(readings)
        // 被剔掉的那些不能就此消失：单独一本账带着各自的原因，UI 才说得出
        // 「已跳过 N 份读取失败（权限不足 ×2、文件已不存在 ×1）」。
        // 只在非空时赋值——没有失败就没有这个 key，旧报告的形状也不变。
        let failed = Self.readFailures(readings)
        if !failed.isEmpty { summary.readFailedFiles = failed }
        return (summary, ledger)
    }

    /// 发现 + 附加 + 按绝对路径去重（用户手工附加的文件常常就在项目自己的 Logs/ 里）。
    private func dedupedTargets(projectRoot: URL, windowDays: Int,
                                extraLogURLs: [URL]) -> [DiscoveredLog] {
        let identity = LogProjectIdentity.resolve(scanRoot: projectRoot)
        var discovered = LogDiscovery.discover(
            projectRoot: projectRoot,
            identity: identity,
            withinDays: windowDays,
            maxFiles: Self.maxDiscoveredFiles
        )
        discovered.append(contentsOf: attached(urls: extraLogURLs, projectRoot: projectRoot))
        var seen = Set<String>()
        return discovered.filter { seen.insert($0.url.path).inserted }
    }

    /// 逐份读取；崩溃候选另外过一遍四态通道。顺序即 targets 的顺序。
    private func readAll(_ targets: [DiscoveredLog])
        -> (readings: [LogFileReading], crashEvents: [LogEvent], records: [CrashEvidenceRecord],
            suppressedPaths: Set<String>) {
        var readings: [LogFileReading] = []
        var crashEvents: [LogEvent] = []
        var records: [CrashEvidenceRecord] = []
        var suppressed: Set<String> = []
        for log in targets {
            let reading = LogReader.read(log, maxBytes: Self.maxBytesPerFile,
                                         maxLines: Self.maxLinesPerFile)
            readings.append(reading)
            let outcome = CrashReportParser.crashChannel(reading: reading)
            crashEvents.append(contentsOf: outcome.events)
            records.append(contentsOf: outcome.records)
            if outcome.suppressLineEvents { suppressed.insert(log.url.path) }
        }
        return (readings, crashEvents, records, suppressed)
    }

    /// 「已扫描」= 读成功的（含读到但内容为空的），失败的那些走 `readFailures` 单独一本账。
    static func scannableReadings(_ readings: [LogFileReading]) -> [ScannedLogFile] {
        readings.filter { $0.readFailed == false }.map {
            ScannedLogFile(path: $0.url.path, sizeBytes: $0.sizeBytes, lineCount: $0.totalLines,
                           modifiedAt: $0.modifiedAt, role: $0.role)
        }
    }

    static func readFailures(_ readings: [LogFileReading]) -> [ScannedLogFile] {
        readings.filter { $0.readFailed }.map {
            ScannedLogFile(path: $0.url.path, sizeBytes: $0.sizeBytes, lineCount: $0.totalLines,
                           modifiedAt: $0.modifiedAt, role: $0.role,
                           readFailure: $0.readFailure ?? "读取失败（原因未记录）")
        }
    }

    /// 用户显式附加的文件**不参与时间窗口裁剪**（`LogDiscovery.discover` 才裁）：
    /// 刚点上来的文件因为日期老就被静默丢掉，比窗口口径更让人意外。
    /// 因此窗口只描述自动发现的范围，UI 若要把这句话写全，需要说明附加文件不受限。
    private func attached(urls: [URL], projectRoot: URL) -> [DiscoveredLog] {        return urls.compactMap { url in
            guard let values = try? url.resourceValues(
                forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
            ), values.isRegularFile == true else { return nil }

            let size = Int64(values.fileSize ?? 0)
            guard size > 0 else { return nil }
            let modified = values.contentModificationDate ?? Date.distantPast
            return DiscoveredLog(
                url: url,
                role: LogDiscovery.role(for: url, in: projectRoot),
                sizeBytes: size,
                modifiedAt: modified
            )
        }
    }
}

// MARK: - 崩溃证据的界面读数（RD-21/22/23 的"解释准确"落点；RD-60 起改走唯一装配口）

/// 中文串在 Services 侧拼，与 CLI 的产品散文同一口径（AGENTS §5.9 第 4 条）。
///
/// 为什么不在 `Views/Logs` 里拼：那两条双语棘轮都按**视图文件里的字面量**计数
/// （`LocalizationGuardTests` 未登记串存量 19/19、`LocalizationGuardTests+InterpolatedCopy`
/// 插值中文串 40/40），在界面里加一句新中文就是新增债；
/// 而 Services 侧的拼接与 CLI 一样走"产品散文"，不进那两本账。
/// 视图只接已经拼好的变量。
///
/// ⚠️ RD-60（台账 §48）：本文件原先住着 `LogSummary` 的两句话与一把**平行尺子**
/// （`crashEvidenceFootnote` + `historicalCrashCount`，从已落盘的趋势桶按事件时间求和）。
/// 它与细账 `CrashEvidenceLedger.historicalConfirmedCount` 分母不同（趋势桶既漏掉窗口外的
/// 真崩溃报告、又把普通日志的 FATAL 行算成崩溃），差值已由 `CrashEvidenceRulerReproductionTests`
/// 在同一个总体上量出来。现在：
/// · **`historicalCrashCount` 已删**（零测试调用者、删前查过 `git stash list` 无在途实现、
///   全仓无第二处同名实现），"窗口外历史几次"从此只能由台账说出口；
/// · `crashTileCaption` 仍然留在这里（它不含任何重算，只读一个已落盘的数），
///   但崩溃脚注那整段话搬去唯一装配口 `CrashEvidenceReadout`，本文件只剩一行转发。
/// 想再把趋势桶拿来当崩溃尺子，会被 `CrashEvidenceReadoutGuardTests` 当场判红。
extension LogSummary {
    /// 崩溃那一格的 caption：计数 + 一句边界，替代原来只写「其中 FATAL n 条」的读数。
    var crashTileCaption: String {
        "窗口内确认崩溃；其中 FATAL \(NumberFormat.grouped(fatalCount)) 条"
    }

    /// 崩溃那一格 ⓘ 的完整句 —— **一行转发**，一个汉字都不在这里拼（拼话只在
    /// `CrashEvidenceReadout` 那一处）。本文件是它在 `Sources/**` 里的唯一调用点，
    /// 因此这个类型不是「只有单测在用」的实现文件（`SourceFileReachabilityTests` 只认代码调用点）。
    ///
    /// - Parameter evidence: 同一次分析的崩溃证据台账。**来路三态**（装配口决定，这里不判断）：
    ///   ① 传台账 ⇒ 逐字引台账那两句；② 不传而 `crashEvidence` 九格齐全 ⇒ **按名字从落盘接回**
    ///   （视图与 CLI 走的就是这一条，RD-60 那座桥）；③ 两者都没有 ⇒ 明说本次未统计，
    ///   **绝不**回落到趋势桶去估一个数（那是 RD-60 立掉的那把第二把尺子）。
    ///
    /// ⚠️ 签名里**没有** `now` 这个参数，这是有意的：窗口由台账在分析那一刻裁一次，
    /// 上屏时再按当时的 `Date()` 裁第二次，就是同一个判据两处入口（RD-38 同族）。
    func crashEvidenceFootnote(windowDays: Int, evidence: CrashEvidenceLedger? = nil) -> String {
        CrashEvidenceReadout.footnote(
            CrashEvidenceReadout.reading(from: self, evidence: evidence, windowDays: windowDays),
            readFailureReasons: CrashEvidenceReadout.readFailureDistribution(self))
    }

    /// 崩溃那一段脚注**有没有可说的**（界面 ⓘ 与 CLI 的文本读数共用这一个判据 ——
    /// 两处各写一遍就会长成两个条件，迟早只改一处）。
    ///
    /// `crashCount == 0` 而崩溃通道里读到过报告，正是"查过了、真的没有"那一句该出声的场合，
    /// 所以这里不能只看 `crashCount`。反过来，一份崩溃证据都没有的项目不必被塞一行空账
    /// （那会把"没账"读成"有账且干净"）。
    var hasCrashEvidenceToReport: Bool {
        crashCount > 0 || CrashEvidenceReadout.crashChannelFiles(in: self) > 0
    }
}
