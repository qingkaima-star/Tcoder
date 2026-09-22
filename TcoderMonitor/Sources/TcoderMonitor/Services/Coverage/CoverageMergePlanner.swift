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
    /// 本次扫描时**被扫源码**的提交指纹（`git rev-parse HEAD` 短哈希）。
    /// `nil` = 非 git 目录 / git 读失败 ⇒ 身份层的"源码指纹"这一格就是缺的，
    /// 必须由 `CoverageMergeConfidence` 点名，不许悄悄当"没这个问题"。
    var sourceFingerprint: String? = nil

    /// 能不能拿去做跨报告的按行并集。
    var isMergeEligible: Bool {
        guard let ledger, ledger.isMergeSafe else { return false }
        // 账本与报告自己的 LF/LH 必须是同一批文件，否则并集会悄悄换口径。
        return ledger.agrees(with: report)
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

    static func plan(candidates raw: [CoverageCandidate],
                     consideredCount: Int,
                     parseFailures: [CoverageParseFailure],
                     discovery: CoverageDiscoveryStats) -> Result {
        // **运行归属先分配再谈去重**：`runKey` 只能由"同目录共位 + 正文互证"发出来
        // （`CoverageRunIdentity`），认不出就留 `nil`。原来那份身份是拿路径子串猜来的
        // unit/集成归类拼的 —— 猜错会把两次运行并成一次（丢证据）。
        let candidates = CoverageRunIdentity.assignRunKeys(to: raw)
        var ledger = CoverageMergeLedger(consideredCount: consideredCount,
                                        parsedCount: candidates.count,
                                        parseFailures: parseFailures,
                                        discovery: discovery)
        ledger.unattributedRunPaths = candidates.filter { $0.identity.runKey == nil }
            .map { $0.report.path }
        guard !candidates.isEmpty else {
            ledger.basis = consideredCount > 0 ? .nothingMergeable : .nothingDiscovered
            // `nil` = 压根没给总数。有报告却给不出总数时也是 `nil`（下面各分支同口径），
            // "有数字但身份不全"才是 `false`。
            ledger.mergeConfident = nil
            return Result(scoring: [], ledger: ledger)
        }

        // ① 陈旧：报告时刻早于最新源码提交 ⇒ 不参与"当前覆盖率"。
        var pool: [CoverageCandidate] = []
        for candidate in candidates {
            if candidate.binding.provesStaleness {
                ledger.dropped.append(dropped(candidate, reason: .staleAgainstSource))
                ledger.separateReadings.append(candidate.report)   // **原样留档**，不降级成占位对象
                ledger.staleReportCount += 1
            } else {
                pool.append(candidate)
            }
            if candidate.binding == .undated || candidate.binding == .unbound {
                ledger.unboundReportCount += 1
            }
        }

        // ② 同一来源只数一次：同目录、有正文互证的格式对偶（或同格式且账本一致）。
        pool = dropSameRunDuplicates(from: pool, ledger: &ledger)

        // ③ 谁能进并集。
        // 只剩一份时**不存在合并**，也就谈不上双计：该给数就给数，
        // 不许为了"保守"把一份真实的单报告读数控成缺证据。
        // ⚠ 但 `mergeConfident` 与"只剩一份"无关 —— 那一份身份缺格照样判不置信。
        if pool.count == 1, let only = pool.first {
            ledger.basis = .singleReport
            ledger.includedCount = 1
            ledger.mergedInputCount = 1
            applyConfidence(&ledger, included: [only], gaveTotal: true)
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
            applyConfidence(&ledger, included: [], gaveTotal: false)   // 没给总数 ⇒ nil
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
            applyConfidence(&ledger, included: [], gaveTotal: false)
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
        } else {
            report = unionReport(from: bounded, merged: merged)
            ledger.basis = eligible.count == pool.count ? .lineSetUnion : .perFileReportWithUnmergedSummaries
        }
        ledger.includedCount = 1
        for candidate in bounded where candidate.report.id != report.id {
            ledger.separateReadings.append(candidate.report)
        }
        applyConfidence(&ledger, included: bounded, gaveTotal: true)
        var result = Result(scoring: [report], ledger: ledger)
        result.ledger.includedCount = 1
        return result
    }

    /// `mergeConfident` 的**唯一**写入点：把"给了总数没有、进总数的那几份身份齐不齐"
    /// 交给 `CoverageMergeConfidence`。**份数不参与判定**（R5 那三处
    /// `= true` / `= basis == …` 的写法都由这一处取代）。
    private static func applyConfidence(_ ledger: inout CoverageMergeLedger,
                                        included: [CoverageCandidate],
                                        gaveTotal: Bool) {
        let verdict = CoverageMergeConfidence.verdict(included: included,
                                                     fingerprint: included.first?.sourceFingerprint,
                                                     gaveTotal: gaveTotal,
                                                     evidenceLeftOut: ledger.evidenceLeftOut,
                                                     conflictingFileCount: ledger.conflictingFileCount)
        ledger.mergeConfident = verdict.confident
        ledger.identityGaps = verdict.gaps
        ledger.identityGapsByPath = verdict.missingByPath
    }

    // MARK: 同一来源

    /// 同 `runKey` 的一组里留一份：**优先留有逐行账本的**（它能参与合并），
    /// 其次留数字大的，最后按路径定序 —— 顺序必须与输入顺序无关（复现性是硬要求）。
    /// 注：`runKey` 由 `CoverageRunIdentity.assignRunKeys` 发出来，**只有正文互证过的那些
    /// 才会共享同一个键**，所以这里的分组不再需要"猜它们是不是同一次运行"。
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
                    ledger.separateReadings.append(loser.report)   // 同一批数字的另一种落法，照样可查
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
