import Foundation

protocol CoverageProviding: AnyObject {
    func analyze(projectRoot: URL, options: ScanOptions) async throws -> CoverageMetrics
}

/// Reads coverage artefacts the repository already produces. Nothing here runs a
/// test suite — it only parses existing reports, so it stays read-only and fast.
///
/// RD-25/RD-26 之后这条链的形状：**发现 → 解析（带原因）→ 四类身份 → 合并规划 → 落盘**。
/// 身份见 `CoverageReportIdentity`（格式/运行/模块）与 `CoverageSourceBinding`（源码指纹），
/// 合并见 `CoverageLineLedger`（按源码行求并）与 `CoverageMergePlanner`（谁能进总数、谁被丢掉）。
/// 本文件只留「读文件 + 五种格式怎么读」这两件事，其余整块搬去了同目录的新文件。
final class CoverageAnalyzer: CoverageProviding {
    private static let maxReportBytes = 20_000_000

    /// 单份 lcov 账本允许跟踪多少行。默认 30 万行（真实大仓一份 lcov 的量级），
    /// **可注入**是为了让"预算命中 ⇒ 该份账本判不可信并点名"这条判定可测。
    private let lineBudget: Int

    init(lineBudget: Int = CoverageLineLedger.defaultLineBudget) { self.lineBudget = lineBudget }

    func analyze(projectRoot: URL, options: ScanOptions) async throws -> CoverageMetrics {
        try await analyzeWithLedger(projectRoot: projectRoot, options: options).metrics
    }

    /// 主入口：**读数与台账一起给**。`CoverageMetrics` 那半边是冻结契约，
    /// 台账那半边是本轮新增的（契约缺口：要总工把字段上提进 `Models/CoverageMetrics.swift`）。
    func analyzeWithLedger(projectRoot: URL, options: ScanOptions) async throws -> CoverageMetrics.AnalysisOutcome {
        var metrics = CoverageMetrics()
        let discovery = CoverageReportDiscovery.discover(in: projectRoot)
        let candidates = discovery.found
        metrics.scannedFileCount = candidates.count
        // 每次分析都写下这一格（0 也是一句真话："扫到的每个目录都读得动"）。
        // 旧报告里它是 nil = 那个版本根本没统计过，两者在界面上必须分开。
        metrics.unreadableDirectoryCount = discovery.stats.unreadableDirectories

        let source = CoverageSourceState.read(at: projectRoot)
        var parsed: [CoverageCandidate] = []
        var failures: [CoverageParseFailure] = []
        for url in candidates {
            switch parse(url: url, root: projectRoot, source: source) {
            case .success(let candidate): parsed.append(candidate)
            case .failure(let failure): failures.append(failure)
            }
        }

        let plan = CoverageMergePlanner.plan(candidates: parsed,
                                             consideredCount: candidates.count,
                                             parseFailures: failures,
                                             discovery: discovery.stats)
        metrics.reports = plan.scoring
        metrics.analyzedAt = Date()
        return CoverageMetrics.AnalysisOutcome(metrics: metrics, merge: plan.ledger)
    }

    // MARK: Parsing

    enum ParseResult {
        case success(CoverageCandidate)
        case failure(CoverageParseFailure)
    }

    /// 一份报告文件 → 候选（带身份与账本）或**带原因的失败**。
    /// 旧实现这里所有失败路径都是 `return nil`（空文件 / >20 MiB / 非 UTF-8 / 认不出格式 /
    /// 读不出数字，五种病共用一次静默丢弃），现在每种原因各自计数并上屏。
    private func parse(url: URL, root: URL, source: CoverageSourceState) -> ParseResult {
        let path = url.path
        let name = url.lastPathComponent
        let format = CoverageReportFormat.identify(fileName: name)
        guard format != .unrecognized else {
            return .failure(CoverageParseFailure(path: path, reason: .unrecognizedFormat,
                                                 byteCount: byteSize(of: url)))
        }
        let size = byteSize(of: url)
        if size == 0 { return .failure(CoverageParseFailure(path: path, reason: .emptyFile, byteCount: size)) }
        if let size, size > Self.maxReportBytes {
            return .failure(CoverageParseFailure(path: path, reason: .oversize, byteCount: size))
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return .failure(CoverageParseFailure(path: path,
                                                 reason: size == nil ? .unreadable : .notUtf8,
                                                 byteCount: size))
        }

        let report: CoverageReport?
        let ledger: CoverageLineLedger?
        switch format {
        case .lcov:
            let tally = Self.parseLCovWithLedger(text: text, url: url, root: root,
                                                 lineBudget: lineBudget)
            report = tally?.report
            ledger = tally?.ledger
        case .istanbulSummary: report = parseIstanbulSummary(text: text, url: url, root: root); ledger = nil
        case .jacocoXml: report = parseJaCoCo(text: text, url: url, root: root); ledger = nil
        case .coveragePyXml: report = parseCoveragePy(text: text, url: url, root: root); ledger = nil
        case .cloverXml: report = parseClover(text: text, url: url, root: root); ledger = nil
        case .unrecognized: report = nil; ledger = nil      // 上面已拦，这里只为穷尽
        }

        guard var filled = report else {
            return .failure(CoverageParseFailure(path: path, reason: .noUsableNumbers, byteCount: size))
        }
        filled = fill(url: url, with: filled)
        // 运行时刻只能来自**正文**（coverage.py 的 `timestamp=`、clover 的 `generated=`）。
        // 报告文件的 mtime 不算运行证据：它记的是"这个文件什么时候被写/被复制"，
        // 不是"哪一次测试运行产出了它"（`cp` 一次就变了，见 `CoverageSourceBinding.swift` 的边界）。
        let runStamp = CoverageRunIdentity.runStamp(in: text, format: format)
        let identity = CoverageReportIdentity.derive(path: path, root: root, format: format,
                                                    runStamp: runStamp)
        // 带文件粒度的格式即使一条 `DA:` 都没有，也要交出一个（可能只有汇总计数的）账本，
        // 让规划器去判"能不能合并"；汇总粒度的格式压根没有账本这回事 ⇒ nil。
        let resolvedLedger = ledger ?? (identity.format.carriesPerSourceFileRecords ? CoverageLineLedger() : nil)
        return .success(CoverageCandidate(
            report: filled, identity: identity,
            binding: CoverageBinding.state(generatedAt: filled.generatedAt, source: source),
            ledger: resolvedLedger,
            // 源码身份：本次扫描时**被扫仓库**的提交指纹。读不到就是 nil，
            // 绝不允许拿 mtime 或本次分析时刻顶替成一格"有身份"。
            sourceFingerprint: source.headCommit))
    }

    private func byteSize(of url: URL) -> Int? {
        (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize
    }

    /// 五种格式的解析器都不关心「这份文件是哪天的」，所以在这里统一补一次：
    /// 生成时间取报告文件**自身的 mtime**。
    /// ⚠ mtime **不是提交绑定**：它只能用来证伪（早于最新提交 ⇒ 已知陈旧），
    ///   绝不允许反过来声称"这份报告测的就是当前 HEAD"。见 `CoverageSourceBinding.swift`。
    /// 读不到就留 nil，由 `CoverageReport.generationText` 明说「未知生成时间」，
    /// 绝不允许拿本次分析时刻顶替（那等于把陈旧报告洗成新数据）。
    private func fill(url: URL, with report: CoverageReport) -> CoverageReport {
        var filled = report
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey])
        filled.generatedAt = values?.contentModificationDate
        return filled
    }

    /// lcov 是唯一带**源文件粒度**的格式（每条记录一个 `SF:`），所以只有它能真的
    /// 把测试代码从计分分母里剔出去、也只有它能给出跨报告的按行并集。
    /// 其余四种格式只有汇总数字，标成 `.aggregateOnly` 让它们的生产码口径**明说等同全量**，
    /// 而不是假装区分过。逐行累加器见 `CoverageAnalyzer.LCovTally`（`CoverageLineLedger.swift`）。
    static func parseLCovWithLedger(text: String, url: URL, root: URL,
                                    lineBudget: Int = CoverageLineLedger.defaultLineBudget)
        -> (report: CoverageReport, ledger: CoverageLineLedger)? {
        var tally = LCovTally(root: root, lineBudget: lineBudget)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            tally.consume(raw.trimmingCharacters(in: .whitespaces))
        }
        guard tally.allLinesFound > 0 else { return nil }
        return (tally.report(url: url), tally.ledger)
    }

    private func parseIstanbulSummary(text: String, url: URL, root: URL) -> CoverageReport? {
        // 局部名不叫 `root`：那个名字是**被扫目录**（参数），撞名会把 `classify` 的
        // 坐标换成一份 JSON 字典（编译器拦住了，注释留在这里免得下次再撞）。
        guard let data = text.data(using: .utf8),
              let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let total = document["total"] as? [String: Any] else { return nil }

        // 两级判断不能合并成一次回退：lines 桶**存在但为 0** 时不认 statements，
        // 只有 lines 缺失才回退。合起来会把"零覆盖"悄悄报成 83% 覆盖。
        guard let lines = Self.istanbulCounter(total["lines"]) ?? Self.istanbulCounter(total["statements"]),
              lines.total > 0 else { return nil }
        let branches = Self.istanbulCounter(total["branches"])
        let functions = Self.istanbulCounter(total["functions"])
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url, root: root),
            toolName: CoverageReportFormat.istanbulSummary.toolName,
            linesCovered: lines.covered, linesTotal: lines.total,
            branchesCovered: branches?.covered ?? 0,
            branchesTotal: Self.positiveTotal(of: branches),
            methodsCovered: functions?.covered ?? 0, methodsTotal: functions?.total ?? 0,
            allLinesCovered: lines.covered, allLinesTotal: lines.total,
            allBranchesCovered: branches?.covered ?? 0,
            allBranchesTotal: Self.positiveTotal(of: branches),
            scopeGranularity: .aggregateOnly
        )
    }

    /// istanbul 的一个计数桶。`pct` 故意不读：`CoverageReport` 从不消费它
    /// （百分比由 `linePercent` 现场派生），原来那次 `??` 加三元只是白加判定分。
    private static func istanbulCounter(_ entry: Any?) -> (covered: Int, total: Int)? {
        guard let bucket = entry as? [String: Any] else { return nil }
        return (covered: bucket["covered"] as? Int ?? 0, total: bucket["total"] as? Int ?? 0)
    }

    /// 分支总数为 0 视作"这份报告没统计分支"，返回 nil 而不是 0/0。
    private static func positiveTotal(of counter: (covered: Int, total: Int)?) -> Int? {
        guard let counter, counter.total > 0 else { return nil }
        return counter.total
    }

    private func parseJaCoCo(text: String, url: URL, root: URL) -> CoverageReport? {
        // Report-level counters are the last ones in the document; per-package and
        // per-class counters appear earlier and would double-count.
        guard let line = Self.jacocoTotals(for: "LINE", in: text) else { return nil }
        let branch = Self.jacocoTotals(for: "BRANCH", in: text)
        let method = Self.jacocoTotals(for: "METHOD", in: text)
        let total = line.missed + line.covered
        guard total > 0 else { return nil }
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url, root: root),
            toolName: CoverageReportFormat.jacocoXml.toolName,
            linesCovered: line.covered, linesTotal: total,
            branchesCovered: branch?.covered ?? 0,
            branchesTotal: Self.jacocoSumIfPositive(branch),
            methodsCovered: method?.covered ?? 0,
            methodsTotal: Self.jacocoSum(method),
            allLinesCovered: line.covered, allLinesTotal: total,
            allBranchesCovered: branch?.covered ?? 0,
            allBranchesTotal: Self.jacocoSumIfPositive(branch),
            scopeGranularity: .aggregateOnly
        )
    }

    static func jacocoTotals(for type: String, in text: String) -> (missed: Int, covered: Int)? {
        let pattern = "<counter\\s+type=\"\(type)\"\\s+missed=\"(\\d+)\"\\s+covered=\"(\\d+)\"\\s*/>"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              match.numberOfRanges == 3 else { return nil }
        return (jacocoValue(at: 1, of: match, in: text), jacocoValue(at: 2, of: match, in: text))
    }

    static func jacocoValue(at index: Int, of match: NSTextCheckingResult, in text: String) -> Int {
        let range = match.range(at: index)
        guard range.location != NSNotFound, let swiftRange = Range(range, in: text) else { return 0 }
        return Int(text[swiftRange]) ?? 0
    }

    /// 分支总数为 0 时报 nil（"这份报告没有分支数据"），不是报 0（"分支覆盖 0%"）。
    static func jacocoSumIfPositive(_ counter: (missed: Int, covered: Int)?) -> Int? {
        guard let counter else { return nil }
        let sum = counter.missed + counter.covered
        return sum > 0 ? sum : nil
    }

    static func jacocoSum(_ counter: (missed: Int, covered: Int)?) -> Int {
        counter.map { $0.missed + $0.covered } ?? 0
    }

    private func parseCoveragePy(text: String, url: URL, root: URL) -> CoverageReport? {
        guard let start = text.range(of: "<coverage") else { return nil }
        let headerEnd = text.range(of: ">", range: start.lowerBound..<text.endIndex)?.lowerBound
            ?? start.upperBound
        let header = String(text[start.lowerBound..<headerEnd])

        func attr(_ name: String) -> Double? {
            guard let regex = try? NSRegularExpression(pattern: "\(name)=\"([0-9.]+)\""),
                  let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)),
                  match.numberOfRanges == 2,
                  let range = Range(match.range(at: 1), in: header) else { return nil }
            return Double(header[range])
        }

        let valid = Int(attr("lines-valid") ?? 0)
        guard valid > 0 else { return nil }
        let covered = Int(attr("lines-covered") ?? 0)
        let branchValid = Int(attr("branches-valid") ?? 0)
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url, root: root),
            toolName: CoverageReportFormat.coveragePyXml.toolName,
            linesCovered: covered, linesTotal: valid,
            branchesCovered: Int(attr("branches-covered") ?? 0),
            branchesTotal: branchValid > 0 ? branchValid : nil,
            methodsCovered: 0, methodsTotal: 0,
            allLinesCovered: covered, allLinesTotal: valid,
            allBranchesCovered: Int(attr("branches-covered") ?? 0),
            allBranchesTotal: branchValid > 0 ? branchValid : nil,
            scopeGranularity: .aggregateOnly
        )
    }

    private func parseClover(text: String, url: URL, root: URL) -> CoverageReport? {
        let pattern = "<metrics\\s+statements=\"(\\d+)\"\\s+coveredstatements=\"(\\d+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
              match.numberOfRanges == 3 else { return nil }
        func value(_ index: Int) -> Int {
            guard let range = Range(match.range(at: index), in: text) else { return 0 }
            return Int(text[range]) ?? 0
        }
        let total = value(1)
        guard total > 0 else { return nil }
        return CoverageReport(
            path: url.path,
            kind: Self.classify(url: url, root: root),
            toolName: CoverageReportFormat.cloverXml.toolName,
            linesCovered: value(2), linesTotal: total,
            branchesCovered: 0, branchesTotal: nil,
            methodsCovered: 0, methodsTotal: 0,
            allLinesCovered: value(2), allLinesTotal: total,
            allBranchesCovered: 0, allBranchesTotal: nil,
            scopeGranularity: .aggregateOnly
        )
    }

    // MARK: Helpers

    static func int(after line: String) -> Int {
        guard let colon = line.firstIndex(of: ":") else { return 0 }
        return Int(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)) ?? 0
    }

    /// 这份报告属于 unit / 集成 / 整体。**判据只准看被扫目录之内的相对路径**：
    /// 原来读的是 `url.path`（绝对路径），于是机器上那串临时目录名也能参与匹配 ——
    /// `NSTemporaryDirectory()` 里那个 UUID 是十六进制串，含 `e2e` 的概率约 0.7%
    /// （32 个字符 × 30 个三字符窗口 × 1/16³），命中时**整棵夹具**会被判成"集成测试"，
    /// 同一份夹具两次跑出两个数（台账 RD-39 那条"只在整套跑时红"就是它）。
    /// 相对路径切不出来（报告在被扫目录之外）时一律 `.combined`：不猜。
    static func classify(url: URL, root: URL) -> CoverageReport.Kind {
        let scoped = CoverageReportIdentity.relativePath(of: url.path, root: root) ?? ""
        let path = scoped.lowercased()
        if path.isEmpty { return .combined }
        if path.contains("integration") || path.contains("/itest") || path.contains("e2e") { return .integration }
        if path.contains("unit") || path.contains("/test/") || path.contains("surefire") { return .unit }
        return .combined
    }
}
