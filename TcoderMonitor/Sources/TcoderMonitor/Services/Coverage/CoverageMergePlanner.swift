import Foundation

//  RD-25 · 合并策略与**丢弃台账**。
//
//  旧实现只有一句：`Array(reports.sorted { $0.linesTotal > $1.linesTotal }.prefix(6))`
//  —— 按分母大小留前六份，剩下的**静默丢掉**，留下的那些再被 `overallLinePercent` 直接累加相除。
//  这一页把两件事拆开：**谁能进总数**（身份 + 逐行账本说了算）与
//  **谁被丢掉了、为什么**（全部计数并上屏，nil 与 0 分得开）。
//
//  三条硬规则（本轮的判断骨架）：
//  1. **同一来源只数一次**：同模块同运行、由同一次测试导出的两种落法
//     （`nyc --reporter=lcov --reporter=json-summary`）是一份证据，相加就是双计。
//  2. **相加不等于并集**：unit 与 integration 覆盖同一批源码行时，只有按行求并才是联合覆盖；
//     拿不到逐行证据就判冲突，宁可不给总数。
//  3. **不可靠就不给总数**：拿不出可信并集时返回空集 ⇒ `hasData == false`、
//     `overallLinePercent == nil`，界面上是"缺证据"而不是 0%，也不是伪精确总数。

// MARK: - 候选（解析成功之后、合并之前的一份报告）

struct CoverageCandidate: Sendable {
    var report: CoverageReport
    var identity: CoverageReportIdentity
    var binding: CoverageBindingState
    /// `nil` = 这个格式根本没有文件粒度（istanbul 摘要 / JaCoCo report 级 counter / …）。
    var ledger: CoverageLineLedger?

    /// 能不能拿去做跨报告的按行并集。
    var isMergeEligible: Bool {
        guard let ledger, ledger.isMergeSafe else { return false }
        // 账本与报告自己的 LF/LH 必须是同一批文件，否则并集会悄悄换口径。
        return ledger.agrees(with: report)
    }
}

// MARK: - 丢弃原因

enum CoverageDropReason: String, Codable, Sendable, CaseIterable {
    /// 报告时刻早于被扫仓库最新提交 ⇒ 测的不是当前源码。
    case staleAgainstSource
    /// 与另一份是**同一次运行的另一种落法**（同模块、同运行键、格式对偶）。
    case sameRunDuplicate
    /// 只有汇总桶：与别份无法核对是否重叠 ⇒ 不并入总数（旧实现正是把这些直接相加的）。
    case aggregateOnlyCannotCrossCheck
    /// 账本不可信（逐行预算截断 / 同文件重复且数字不一 / 有 `SF:` 之外的孤儿计数）。
    case ledgerUntrusted
    /// 与别份提到同一文件而双方都给不出可核对的行集合 ⇒ 两边一起摘出分母。
    case lineSetConflict

    var note: String {
        switch self {
        case .staleAgainstSource: return "早于当前源码提交（陈旧）"
        case .sameRunDuplicate: return "与已计入的那份是同一次运行的另一种落法"
        case .aggregateOnlyCannotCrossCheck: return "只有汇总粒度，无法与其它报告核对重叠"
        case .ledgerUntrusted: return "逐行账本不可信（预算截断或同文件数字冲突）"
        case .lineSetConflict: return "与别份重叠且拿不出可核对的行集合"
        }
    }
}

struct CoverageDroppedReport: Equatable, Sendable {
    var path: String
    var toolName: String
    var linesCovered: Int
    var linesTotal: Int
    var reason: CoverageDropReason
    /// 细分原因（账本不可信时说是预算命中还是同文件数字冲突）。`nil` = 该档没有更细的说法。
    var detail: String?
}

// MARK: - 总数是从哪种证据算出来的

enum CoverageTotalBasis: String, Codable, Sendable {
    /// 一份报告文件都没扫到 ⇒ 缺证据。
    case nothingDiscovered
    /// 扫到了但没有任何一份能可信地合成总数 ⇒ **分开呈现**，不给总数。
    case nothingMergeable
    /// 只有一份可用报告：不存在合并，也就谈不上重复计数。
    case singleReport
    /// 多份带文件粒度的报告按**源码行集合求并**。
    case lineSetUnion
    /// 只有那一份带文件粒度的进总数，其余汇总粒度报告未并入（总数可能偏低，已披露）。
    case perFileReportWithUnmergedSummaries

    var note: String {
        switch self {
        case .nothingDiscovered: return "没有扫到任何覆盖率报告文件"
        case .nothingMergeable: return "有报告，但彼此无法核对重叠 ⇒ 不给伪精确总数，分开呈现"
        case .singleReport: return "只有一份可用报告，未做合并"
        case .lineSetUnion: return "按源码行命中集合求并（同一次运行只数一次）"
        case .perFileReportWithUnmergedSummaries: return "只按带文件粒度的报告求并，汇总粒度的未并入"
        }
    }
}

// MARK: - 台账

/// 这次覆盖率合并的**全部账目**。旧报告里没有这一格 ⇒ 全部 Optional，
/// 契约缺口见 Obsidian `112` 的 ## 契约缺口（要总工上提到 `Models/CoverageMetrics.swift`）。
struct CoverageMergeLedger: Equatable, Sendable {
    /// 发现阶段看到的候选文件数（= 旧字段 `scannedFileCount`，两者必须相等，守卫钉着）。
    var consideredCount = 0
    var parsedCount = 0
    /// 进了总数的那几份**输入**报告（并集情形下是"合成总数用了 4 份"）。
    var mergedInputCount = 0
    /// 落到 `CoverageMetrics.reports` 里的读数份数（并集情形下是 1）。
    var includedCount = 0
    var dropped: [CoverageDroppedReport] = []
    var parseFailures: [CoverageParseFailure] = []
    var basis: CoverageTotalBasis = .nothingDiscovered
    /// true = 总数就是全部可信证据的并集；false = 有可核对的东西没并进总数；
    /// `nil` = **压根没给总数**（谈不上置不置信）。nil 与 false 必须分得开。
    var mergeConfident: Bool?
    var conflictingFileCount = 0
    var excludedFoundLines = 0
    var staleReportCount = 0
    /// 没有提交绑定（非 git / mtime 读不到）的报告数。它们**不被排除**，只是不能声称新鲜。
    var unboundReportCount = 0
    var unionFileCount = 0
    var discovery: CoverageDiscoveryStats = CoverageDiscoveryStats()

    /// 未进总数、但真实存在的读数。**分开呈现的数据源**（界面读它 = 契约缺口）。
    var separateReadings: [CoverageReport] = []

    var droppedCount: Int { dropped.count }

    /// 恒等式①：考虑 = 解析成功 + 读取失败（每一份被发现的文件都要有个交代）。
    var consideredAccountBalanced: Bool { consideredCount == parsedCount + parseFailures.count }
    /// 恒等式②：解析成功 = 并入总数 + 被丢弃（**没有一份报告是"悄悄不见"的**）。
    var parsedAccountBalanced: Bool { parsedCount == mergedInputCount + dropped.count }

    /// 一句人话。所有上限与丢弃都要在这里出声（静默截断是本轮要修的病根）。
    var statement: String {
        var parts: [String] = [
            "考虑 \(consideredCount) 份报告文件 · 解析成功 \(parsedCount) · "
                + "并入总数 \(mergedInputCount) 份（产出 \(includedCount) 份读数）· 丢弃 \(dropped.count)",
        ]
        parts.append(basis.note)
        if includedCount > 1 || basis == .lineSetUnion {
            parts.append("并集覆盖 \(unionFileCount) 个源文件"
                + (conflictingFileCount > 0
                   ? "，另有 \(conflictingFileCount) 个文件因重叠无法核对被摘出分母"
                     + "（\(excludedFoundLines) 行）" : ""))
        }
        if !dropped.isEmpty {
            let grouped = Dictionary(grouping: dropped, by: { $0.reason })
                .map { "\($0.key.note) \($0.value.count) 份" }
                .sorted()
            parts.append("丢弃 " + grouped.joined(separator: "、"))
        }
        if !parseFailures.isEmpty {
            let grouped = Dictionary(grouping: parseFailures, by: { $0.reason })
                .map { "\($0.key.note) \($0.value.count) 份" }
                .sorted()
            parts.append("读取失败 " + grouped.joined(separator: "、"))
        }
        parts.append(contentsOf: discovery.notes)
        let details = dropped.compactMap(\.detail)
        if details.contains(where: { $0.contains(CoverageLineLedger.Blocker.budgetExceeded.rawValue) }) {
            let n = details.filter { $0.contains(CoverageLineLedger.Blocker.budgetExceeded.rawValue) }.count
            parts.append("\(n) 份报告逐行账本被内存预算截断 ⇒ 判不可信、未并入（残缺并集比没有并集更坏）")
        }
        if staleReportCount > 0 { parts.append("\(staleReportCount) 份报告早于当前源码提交，未计入") }
        if unboundReportCount > 0 { parts.append("\(unboundReportCount) 份报告没有提交绑定（mtime 不等于提交绑定）") }
        if mergeConfident == false, basis != .nothingMergeable {
            parts.append("⚠ 总数未覆盖全部报告，别当项目全量")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 规划器

enum CoverageMergePlanner {
    /// 计入份数**不再设上限**（旧 `prefix(6)` 的病根就是"按分母大小留前六份、多的静默丢"）。
    /// 真正的界是发现上限（40 份，命中即披露）与逐行账本的内存预算（命中即该份降级并披露）。

    struct Result: Sendable {
        /// 进 `CoverageMetrics.reports` 的那一份或那几份：**它们的和恒等于并集**，
        /// 所以冻结区里 `overallLinePercent` 那句"直接累加相除"不再撒谎。
        var scoring: [CoverageReport]
        var ledger: CoverageMergeLedger
    }

    static func plan(candidates: [CoverageCandidate],
                     consideredCount: Int,
                     parseFailures: [CoverageParseFailure],
                     discovery: CoverageDiscoveryStats) -> Result {
        var ledger = CoverageMergeLedger(consideredCount: consideredCount,
                                        parsedCount: candidates.count,
                                        parseFailures: parseFailures,
                                        discovery: discovery)
        guard !candidates.isEmpty else {
            ledger.basis = consideredCount > 0 ? .nothingMergeable : .nothingDiscovered
            ledger.mergeConfident = consideredCount > 0 ? false : nil
            return Result(scoring: [], ledger: ledger)
        }

        // ① 陈旧：报告时刻早于最新源码提交 ⇒ 不参与"当前覆盖率"。
        var pool: [CoverageCandidate] = []
        for candidate in candidates {
            if candidate.binding.provesStaleness {
                ledger.dropped.append(dropped(candidate, reason: .staleAgainstSource))
                ledger.staleReportCount += 1
            } else {
                pool.append(candidate)
            }
            if candidate.binding == .undated || candidate.binding == .unbound {
                ledger.unboundReportCount += 1
            }
        }
        ledger.separateReadings = ledger.dropped.map { Self.standaloneReading(of: $0) }

        // ② 同一来源只数一次：同模块同运行、且是同一次导出的对偶格式（或同格式重名）。
        pool = dropSameRunDuplicates(from: pool, ledger: &ledger)

        // ③ 谁能进并集。
        // 只剩一份时**不存在合并**，也就谈不上双计：该给数就给数，
        // 不许为了"保守"把一份真实的单报告读数控成缺证据。
        if pool.count == 1, let only = pool.first {
            ledger.basis = .singleReport
            ledger.mergeConfident = true
            ledger.includedCount = 1
            ledger.mergedInputCount = 1
            return Result(scoring: [only.report], ledger: ledger)
        }

        let eligible = pool.filter { $0.isMergeEligible }
        for candidate in pool where !candidate.isMergeEligible {
            ledger.dropped.append(dropped(candidate, reason: candidate.ledger == nil
                ? .aggregateOnlyCannotCrossCheck : .ledgerUntrusted))
            ledger.separateReadings.append(candidate.report)
        }
        let bounded = eligible

        guard !bounded.isEmpty else {
            ledger.basis = .nothingMergeable
            ledger.mergeConfident = false        // 明确"没给总数"，与 nil（没扫到）分开
            return Result(scoring: [], ledger: ledger)
        }

        // ④ 按源码行集合求并。
        let merged = CoverageLedgerMerge.merge(bounded.map { $0.ledger ?? CoverageLineLedger() })
        ledger.conflictingFileCount = merged.conflictingFiles.count
        ledger.excludedFoundLines = merged.excludedFoundLines
        ledger.unionFileCount = merged.mergedFileCount
        guard !merged.isEmpty else {
            // 每一个文件都判了冲突 ⇒ 没有任何可信分母。给不出总数，
            // 但每一份输入都要在 `dropped` 里留名（恒等式②不许破）。
            ledger.basis = .nothingMergeable
            ledger.mergeConfident = false
            for candidate in bounded {
                ledger.dropped.append(dropped(candidate, reason: .lineSetConflict))
                ledger.separateReadings.append(candidate.report)
            }
            ledger.mergedInputCount = 0
            ledger.includedCount = 0
            return Result(scoring: [], ledger: ledger)
        }

        ledger.mergedInputCount = bounded.count
        let report: CoverageReport
        if bounded.count == 1, let only = bounded.first {
            report = only.report
            ledger.basis = pool.count == 1 ? .singleReport : .perFileReportWithUnmergedSummaries
            ledger.mergeConfident = ledger.basis == .singleReport
        } else {
            report = unionReport(from: bounded, merged: merged)
            ledger.basis = eligible.count == pool.count ? .lineSetUnion : .perFileReportWithUnmergedSummaries
            ledger.mergeConfident = ledger.basis == .lineSetUnion
        }
        ledger.includedCount = 1
        for candidate in bounded where candidate.report.id != report.id {
            ledger.separateReadings.append(candidate.report)
        }
        var result = Result(scoring: [report], ledger: ledger)
        result.ledger.includedCount = 1
        return result
    }

    // MARK: 同一来源

    /// 同 `runKey` 的一组里留一份：**优先留有逐行账本的**（它能参与合并），
    /// 其次留数字大的，最后按路径定序 —— 顺序必须与输入顺序无关（复现性是硬要求）。
    private static func dropSameRunDuplicates(from candidates: [CoverageCandidate],
                                              ledger: inout CoverageMergeLedger)
        -> [CoverageCandidate] {
        var groups: [String: [CoverageCandidate]] = [:]
        var unkeyed: [CoverageCandidate] = []
        for candidate in candidates {
            guard let key = candidate.identity.runKey else { unkeyed.append(candidate); continue }
            groups[key, default: []].append(candidate)
        }

        var kept: [CoverageCandidate] = unkeyed
        for (_, group) in groups {
            guard group.count > 1 else { kept.append(contentsOf: group); continue }
            let sorted = group.sorted { lhs, rhs in ranks(lhs) != ranks(rhs)
                ? ranks(lhs) > ranks(rhs)
                : lhs.report.path < rhs.report.path }
            guard let best = sorted.first else { continue }
            kept.append(best)
            for loser in sorted.dropFirst() {
                // 只有"同一次运行的对偶落法"或"同格式重复"才算同一来源；
                // 同目录但互不相干的两种工具**不许**凭目录相同就去重。
                let sameFamily = best.identity.format == loser.identity.format
                    || CoverageReportFormat.isCoPublishedPair(best.identity.format,
                                                              loser.identity.format)
                if sameFamily {
                    ledger.dropped.append(dropped(loser, reason: .sameRunDuplicate))
                    ledger.separateReadings.append(loser.report)
                } else {
                    kept.append(loser)
                }
            }
        }
        return kept.sorted { $0.report.path < $1.report.path }
    }

    private static func ranks(_ candidate: CoverageCandidate) -> Int {
        (candidate.isMergeEligible ? 1_000_000 : 0) + candidate.report.linesTotal
    }

    // MARK: 并集报告

    /// 并集报告：数字全部来自**真实账本的并集**，不掺任何"取其中一份"的近似。
    /// `path` 用 `union:` 前缀而不是某个真实文件路径 —— 它不是一份文件，装成文件就是造假证据。
    private static func unionReport(from members: [CoverageCandidate],
                                    merged: CoverageLedgerMerge.Outcome) -> CoverageReport {
        let kinds = Set(members.map { $0.report.kind })
        let contributors = members.compactMap { member in
            CoverageReportIdentity.relativePath(of: member.report.path,
                                                root: URL(fileURLWithPath: "/"))
        }
        let paths = contributors.isEmpty
            ? members.map { $0.report.path }
            : contributors
        var report = CoverageReport(
            path: "union:lcov+" + paths.sorted().joined(separator: "+"),
            kind: kinds.count == 1 ? kinds.first ?? .combined : .combined,
            toolName: "lcov 并集（\(members.count) 份按源码行合并）",
            linesCovered: merged.hit, linesTotal: merged.found,
            branchesCovered: 0, branchesTotal: nil,
            methodsCovered: 0, methodsTotal: 0,
            allLinesCovered: merged.allIsComplete ? merged.allHit : nil,
            allLinesTotal: merged.allIsComplete ? merged.allFound : nil,
            scopeGranularity: .perSourceFile)
        // 多份合并后分支/方法数**不再相加**：报告里没有逐分支、逐方法的身份，
        // 相加就是双计（这正是本轮的病）。所以这里给 nil（"没统计"），而不是给一个数。
        report.generatedAt = members.compactMap { $0.report.generatedAt }.min()
        return report
    }

    private static func dropped(_ candidate: CoverageCandidate,
                                reason: CoverageDropReason) -> CoverageDroppedReport {
        CoverageDroppedReport(path: candidate.report.path,
                              toolName: candidate.report.toolName,
                              linesCovered: candidate.report.linesCovered,
                              linesTotal: candidate.report.linesTotal,
                              reason: reason,
                              detail: blockerDetail(candidate.ledger))
    }

    /// 账本不可信时要说清是哪一种（预算截断 / 同文件数字冲突 / 孤儿计数 / 压根没有文件粒度）。
    private static func blockerDetail(_ ledger: CoverageLineLedger?) -> String? {
        guard let ledger else { return nil }
        let blockers = ledger.blockers
        return blockers.isEmpty ? nil : blockers.map { $0.rawValue }.joined(separator: "、")
    }

    private static func standaloneReading(of dropped: CoverageDroppedReport) -> CoverageReport {
        CoverageReport(path: dropped.path, kind: .unknown, toolName: dropped.toolName,
                       linesCovered: dropped.linesCovered, linesTotal: dropped.linesTotal,
                       branchesCovered: 0, branchesTotal: nil,
                       methodsCovered: 0, methodsTotal: 0,
                       scopeGranularity: .aggregateOnly)
    }
}

// MARK: - 分析器的一次输出

extension CoverageMetrics {
    /// 读数（冻结契约那半边）+ 合并台账（本轮新增那半边）。
    ///
    /// **为什么只能以派生类型存在**：`CoverageMetrics` 住在 `Models/**` 冻结区，
    /// 本轮不许改它；而"考虑了多少 / 收了多少 / 丢了多少 / 为什么"这些读数
    /// 必须跟着报告一起算出来才有意义。契约缺口（要总工落的 Optional 字段）
    /// 逐条写在 Obsidian `112 WS-R5 覆盖率身份与去重真修.md` 的 ## 契约缺口。
    struct AnalysisOutcome: Sendable {
        var metrics: CoverageMetrics
        var merge: CoverageMergeLedger
    }
}
