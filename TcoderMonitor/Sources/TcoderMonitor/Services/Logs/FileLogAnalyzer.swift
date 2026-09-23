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
    /// 为什么要两个口子：四态计数（疑似 / 解析失败 / 无事件时间 / 旧构建 / 去重合并）
    /// 需要 `LogSummary` 的新字段才能落盘，而 `Models/**` 是冻结区（AGENTS §3）。
    /// 台账先从这个口子出，界面与评分的接法已经写好，等总工按 Obsidian `110`
    /// 的 `## 契约缺口` 落完 Optional 字段，就把 `LogSummary` 变成唯一载体、本口子收掉。
    /// **不许**因为字段没地方放就把这些状态折进 `crashCount` 或干脆不算。
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

// MARK: - 崩溃证据的界面读数（RD-21/22/23 的"解释准确"落点）

/// 中文串在 Services 侧拼，与 CLI 的产品散文同一口径（AGENTS §5.9 第 4 条）。
///
/// 为什么不在 `Views/Logs` 里拼：那两条双语棘轮都按**视图文件里的字面量**计数
/// （`LocalizationGuardTests` 未登记串存量 19/19、`LocalizationGuardTests+InterpolatedCopy`
/// 插值中文串 40/40），在界面里加一句新中文就是新增债；
/// 而 Services 侧的拼接与 CLI 一样走"产品散文"，不进那两本账。
/// 视图只接已经拼好的变量。
///
/// ⚠️ 这里能精确说出口的只有**已落盘**的部分（`crashCount` / `scannedFiles` /
/// `readFailedFiles` / `trend`）。"无事件时间 / 旧构建 / 去重合并"三本小账目前
/// 只能并进"未产出可计数证据"这一句里，并且**明说是待落盘的缺口** ——
/// 需求登记在 Obsidian `110` 的 `## 契约缺口` ①（台账 §6.2 的形状）。
/// 落完字段之后这里改成直接读 records，界面一字不用动。
extension LogSummary {
    /// 崩溃那一格的 caption：计数 + 一句边界，替代原来只写「其中 FATAL n 条」的读数。
    var crashTileCaption: String {
        localizedCount("窗口内确认崩溃；其中 FATAL %lld 条", fatalCount)
    }

    /// 卡头 ⓘ 的完整句：为什么这一格的数比"崩溃通道文件数"小。
    func crashEvidenceFootnote(windowDays: Int, now: Date = Date()) -> String {
        let channelFiles = scannedFiles.filter { $0.role == .crash }.count
        let failed = (readFailedFiles ?? []).filter { $0.role == .crash }
        var parts: [String] = [localizedCount("窗口内确认崩溃 %lld 次，只统计有真实事件证据的报告", crashCount)]

        let historical = historicalCrashCount(windowDays: windowDays, now: now)
        if historical > 0 {
            // **两个复数槽**（次、天）：英文不光量词要变，动词也得跟着第一个槽变
            // （`1 confirmed crash has` / `3 confirmed crashes have`）。
            parts.append(localizedCount(
                "另有 %lld 次确认崩溃的事件时间在最近 %lld 天之外，属历史报告",
                slots: [historical, windowDays]))
        }
        if failed.isEmpty == false {
            let reasons = Dictionary(grouping: failed.compactMap(\.readFailure), by: { $0 })
                .sorted { $0.key < $1.key }
                .map { "\($0.key) ×\($0.value.count)" }
            // 混槽（复数 + 任意字符串）。形状钉死成 `%1$lld` + `%2$@`，
            // 实测 stringsdict 装得下 ⇒ 没有拆成两句（拆了就得让英文去猜词序）。
            parts.append(localizedCount("读取失败 %1$lld 份（%2$@）未参与判定",
                                        count: failed.count,
                                        note: reasons.joined(separator: localizedListSeparator())))
        }
        let unexplained = max(0, channelFiles - crashCount)
        if unexplained > 0 {
            // 这一句原先被 `+` 拆成三段（P53 立的守卫 1d 点名的正是这一族）：
            // 运行时查的是**拼完之后**那一整串，目录里永远没有这种键 ⇒ 半句键白登记。
            // 现在合成一条整句键，`（…）` 里的原因清单留在键内。
            parts.append(localizedCount(
                "还有 %lld 份崩溃通道文件未产出可计数的证据（内容损坏 / 只有文件名像 / 无事件时间 / 构建版本不是当前 / 同一事件的另一份），逐条原因待 LogSummary 落盘崩溃证据字段后展示",
                unexplained))
        }
        return endingSentence(parts.joined(separator: " · "))
    }

    /// 窗口外历史崩溃次数：**从已落盘的趋势桶推出来的**（桶按事件时间分日），
    /// 所以这一句不是近似，是精确读数 —— 前提是该事件真有事件时间。
    func historicalCrashCount(windowDays: Int, now: Date = Date()) -> Int {
        guard windowDays > 0 else { return 0 }
        let cutoff = now.addingTimeInterval(-Double(windowDays) * 86_400)
        return trend.filter { $0.date < cutoff }.reduce(0) { $0 + $1.crashes }
    }
}
