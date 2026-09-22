import Foundation

//  RD-25 · 「按源码行命中集合合并」的那把尺子。
//
//  为什么非要逐行：**unit 覆盖 A 的前 60 行、integration 覆盖 A 的后 60 行**时，
//  相加得 120/100（>100%）、取 max 得 60/100（漏掉一半），两种都是错的。
//  只有把"哪些行被覆盖了"当成集合，并集才是真值 —— lcov 的 `DA:` 记录就是这套集合。
//  拿不到逐行记录时（只有 LF/LH，或根本只有汇总桶）就**不假装能合并**：
//  两份报告若提到同一个文件而都拿不出逐行证据 ⇒ 判为冲突，两边一起从分母里摘出去并计数，
//  而不是挑一个数相加。

// MARK: - 源码范围（生产码口径 + 路径归一化）

/// 覆盖率分母"算不算这份源码"的判定入口。
/// 它是 `Models/CoverageMetrics.swift` 里 `CoverageScope`（冻结区）的**叠加层**，
/// 不是替代：本仓原有的四条 Swift 规则一字不改地继续生效，这里只补多语言那一截。
enum CoverageSourceScope {
    /// true = 计入**评分**分母（生产码）。测试码仍然进全量口径，只是不参与评分。
    static func isProductionSource(path: String) -> Bool {
        guard CoverageScope.isProductionSource(path: path) else { return false }
        return !CoverageTestPathRules.isTestSource(path: path)
    }

    /// 把 lcov 的 `SF:` 归一化成可跨报告比较的键：
    /// 去掉被扫目录前缀、去掉开头的 `./`。归一化失败的绝对路径原样保留 ——
    /// 它的后果只是"认不出是同一个文件"（于是被判冲突），不会把两个不同文件合成一个。
    static func normalizedKey(path: String, root: URL) -> String {
        var key = path.trimmingCharacters(in: .whitespaces)
        if let relative = CoverageReportIdentity.relativePath(of: key, root: root) {
            key = relative
        }
        while key.hasPrefix("./") { key.removeFirst(2) }
        return key
    }
}

// MARK: - 单个源文件的行账

struct CoverageFileLineRecord: Equatable, Sendable {
    var found: Int
    var hit: Int
    /// `DA:` 逐行证据。`nil` = 这份报告对该文件只有汇总计数，没有行集合。
    var foundLines: Set<Int>?
    var hitLines: Set<Int>?
    /// 生产码还是测试/派生码（口径见 `CoverageSourceScope`）。
    var isProduction: Bool

    var hasLineSet: Bool { foundLines != nil }
}

// MARK: - 一份报告的行账

/// 一份（带源文件粒度的）报告里每个源文件的行账，**两个口径同时记**：
/// 生产码那一截进总分，含测试码的那一截是次要读数（`allLines*`），两者不许混。
struct CoverageLineLedger: Equatable, Sendable {
    var files: [String: CoverageFileLineRecord] = [:]
    /// 见到过 `SF:` 记录（没有它就没有文件粒度可言）。
    var sawSourceFileRecords = false
    /// 见到过 `DA:` 记录（没有它就只能按"整份文件计数"合并，重叠时判冲突）。
    var sawLineRecords = false
    /// 逐行预算用尽 ⇒ 之后的行集合不再收。**这份账本降级为不可信**：
    /// 残缺的并集比没有并集更坏 —— 它会给出一个看起来精确、实际少算了文件的总数。
    var budgetExceeded = false
    /// 同一个文件在一份报告里出现两次且数字不一致 ⇒ 不知道信哪个。
    var duplicateFileEntries = 0
    /// `SF:` 之外（没有归属记录）的 LF/LH 计数。非零 ⇒ 汇总数与账本对不上，禁合并。
    var orphanAggregateFound = 0
    var orphanAggregateHit = 0

    /// 单份账本允许跟踪多少个文件（写死：它决定内存上界）。
    static let maxTrackedFiles = 5_000
    /// 单份账本默认允许跟踪多少行。**可注入**（`CoverageAnalyzer(lineBudget:)`），
    /// 因为"预算命中 ⇒ 该份账本不可信"这条判定必须有办法被测出来 ——
    /// 不可能为了测它写一份 30 万行的夹具。
    static let defaultLineBudget = 300_000

    enum Blocker: String, Sendable {
        case budgetExceeded = "逐行预算命中"
        case duplicateFileEntries = "同一文件重复且数字不一"
        case orphanAggregateCounts = "SF: 之外还有计数"
        case noSourceFiles = "没有 SF: 记录（无文件粒度）"
    }

    var lineBudget: Int = CoverageLineLedger.defaultLineBudget
    private var trackedLines = 0

    /// 不能合并的**全部**原因（披露要用，不许只报第一条）。
    var blockers: [Blocker] {
        var out: [Blocker] = []
        if !sawSourceFileRecords { out.append(.noSourceFiles) }
        if budgetExceeded { out.append(.budgetExceeded) }
        if duplicateFileEntries > 0 { out.append(.duplicateFileEntries) }
        if orphanAggregateFound != 0 || orphanAggregateHit != 0 { out.append(.orphanAggregateCounts) }
        return out
    }

    var totalFound: Int { files.values.reduce(0) { $0 + $1.found } }
    var totalHit: Int { files.values.reduce(0) { $0 + $1.hit } }
    var productionFound: Int { files.values.filter(\.isProduction).reduce(0) { $0 + $1.found } }
    var productionHit: Int { files.values.filter(\.isProduction).reduce(0) { $0 + $1.hit } }

    /// 见到一条 `SF:` 就登记（没有它就没有"按源文件区分"这句话说得起）。
    mutating func note(sourceFile path: String) {
        sawSourceFileRecords = true
        _ = path
    }

    /// 账本能不能拿去做跨报告合并。**四个条件任一不满足就判"不可信"**。
    var isMergeSafe: Bool {
        sawSourceFileRecords && !budgetExceeded && duplicateFileEntries == 0
            && orphanAggregateFound == 0 && orphanAggregateHit == 0
    }

    /// 账本与这份报告自带的 LF/LH 汇总是否**同一批文件**。
    /// 两个口径都要对得上：只对一个，说明账本缺了文件（或 `SF:` 之外还有计数），
    /// 拿它去求并集会给出一个看起来精确、实际少算了东西的总数。
    func agrees(with report: CoverageReport) -> Bool {
        productionFound == report.linesTotal && productionHit == report.linesCovered
            && totalFound == (report.allLinesTotal ?? report.linesTotal)
            && totalHit == (report.allLinesCovered ?? report.linesCovered)
    }

    /// 记一条 `DA:<line>,<hits>`。预算之外直接忽略并打上 `budgetExceeded`。
    mutating func noteLine(key: String, line: Int, isHit: Bool, isProduction: Bool) {
        guard trackedLines < lineBudget, files.count < Self.maxTrackedFiles else {
            budgetExceeded = true
            return
        }
        trackedLines += 1
        sawLineRecords = true
        var record = files[key] ?? CoverageFileLineRecord(found: 0, hit: 0,
                                                          foundLines: nil, hitLines: nil,
                                                          isProduction: isProduction)
        record.foundLines = (record.foundLines ?? []).union([line])
        if isHit { record.hitLines = (record.hitLines ?? []).union([line]) }
        record.found = record.foundLines?.count ?? record.found
        record.hit = record.hitLines?.count ?? record.hit
        files[key] = record
    }

    /// 一个 `SF:` 记录收尾时写下的 LF/LH 汇总（`DA:` 缺席时唯一的证据）。
    mutating func noteAggregate(key: String, found: Int, hit: Int, isProduction: Bool) {
        if let existing = files[key], existing.found != found || existing.hit != hit {
            duplicateFileEntries += 1
        }
        guard files[key]?.hasLineSet != true else { return }   // 已有逐行证据时不让汇总盖掉它
        files[key] = CoverageFileLineRecord(found: found, hit: hit,
                                            foundLines: nil, hitLines: nil,
                                            isProduction: isProduction)
    }

    mutating func noteOrphan(found: Int, hit: Int) {
        orphanAggregateFound += found
        orphanAggregateHit += hit
    }
}

// MARK: - 合并

/// 多份账本按**源码行集合**求并。
enum CoverageLedgerMerge {
    struct Outcome: Equatable, Sendable {
        /// 计分口径（生产码）。
        var found = 0
        var hit = 0
        /// 全量口径（含测试码）；`allIsComplete == false` 时这两个数不许用。
        var allFound = 0
        var allHit = 0
        var allIsComplete = true
        /// 并集里被算进分母的文件数。
        var mergedFileCount = 0
        /// 其中真正由两份以上**按行求并**得到的文件数。
        var unionOfLineSets = 0
        /// 认不出重叠、被整份摘出分母的文件（**必须披露**，不许静默）。
        var conflictingFiles: [String] = []
        /// 因为冲突而被摘掉的分母行数 —— 报告"总数少算了多少"。
        var excludedFoundLines = 0

        var isEmpty: Bool { found == 0 }
    }

    private enum Slot {
        case single(CoverageFileLineRecord)
        case merged(foundLines: Set<Int>, hitLines: Set<Int>, production: Bool)
        case conflict
    }

    static func merge(_ ledgers: [CoverageLineLedger]) -> Outcome {
        var slots: [String: Slot] = [:]
        for ledger in ledgers where ledger.isMergeSafe {
            for (key, record) in ledger.files {
                switch slots[key] {
                case nil: slots[key] = .single(record)
                case .single(let existing): slots[key] = combine(existing, record)
                case .merged(let found, let hit, let production):
                    slots[key] = record.hasLineSet
                        ? .merged(foundLines: found.union(record.foundLines ?? []),
                                  hitLines: hit.union(record.hitLines ?? []),
                                  production: production)
                        : .conflict
                case .conflict: break
                }
            }
        }

        var outcome = Outcome()
        for (key, slot) in slots {
            switch slot {
            case .single(let record):
                outcome.mergedFileCount += 1
                outcome.found += record.isProduction ? record.found : 0
                outcome.hit += record.isProduction ? record.hit : 0
                outcome.allFound += record.found
                outcome.allHit += record.hit
            case .merged(let foundLines, let hitLines, let production):
                outcome.mergedFileCount += 1
                outcome.unionOfLineSets += 1
                outcome.found += production ? foundLines.count : 0
                outcome.hit += production ? hitLines.count : 0
                outcome.allFound += foundLines.count
                outcome.allHit += hitLines.count
            case .conflict:
                outcome.conflictingFiles.append(key)
                outcome.allIsComplete = false
            }
        }
        outcome.conflictingFiles.sort()
        // 冲突文件的分母到底多大？两份账本各说各话，这里取"单份账本里这些文件行数的较大值"
        // 作为**被摘掉多少行**的下界。它只用于披露，不进任何比率。
        outcome.excludedFoundLines = ledgers.filter { $0.isMergeSafe }
            .reduce(0) { best, ledger in
                let perLedger = outcome.conflictingFiles.reduce(0) { partial, key in
                    partial + (ledger.files[key]?.found ?? 0)
                }
                return max(best, perLedger)
            }
        return outcome
    }

    /// 两份账本提到同一个文件时的判定。
    /// 只有**双方都有逐行证据**才敢求并集；只有一方有 ⇒ 无法核对重叠 ⇒ 判冲突；
    /// 双方都没有但数字完全相同 ⇒ 认成"同一份测量的重复"，按一份算。
    private static func combine(_ existing: CoverageFileLineRecord,
                                _ incoming: CoverageFileLineRecord) -> Slot {
        if existing.hasLineSet, incoming.hasLineSet {
            return .merged(foundLines: (existing.foundLines ?? []).union(incoming.foundLines ?? []),
                           hitLines: (existing.hitLines ?? []).union(incoming.hitLines ?? []),
                           production: existing.isProduction)
        }
        if !existing.hasLineSet, !incoming.hasLineSet,
           existing.found == incoming.found, existing.hit == incoming.hit,
           existing.isProduction == incoming.isProduction {
            return .single(existing)
        }
        return .conflict
    }
}

// MARK: - lcov 逐行累加器（从 `CoverageAnalyzer.swift` 整块搬来）

extension CoverageAnalyzer {
    /// lcov 的逐行累加器。从 `parseLCov` 里分出来只为了两个理由：
    /// 那段循环被本 App 自扫点名 CC 16（超过 `complexFunctionBar`），
    /// 而 RD-25 之后它还要**同时**产出跨报告合并要用的行账本。
    /// `LF/LH/BRF/BRH` 的语义一字未动 —— `SF:` 决定归属、`end_of_record` 关掉归属、
    /// 没有归属的计数不许悄悄进生产码。
    struct LCovTally {
        var allLinesFound = 0, allLinesHit = 0
        var prodLinesFound = 0, prodLinesHit = 0
        var allBranchesFound = 0, allBranchesHit = 0
        var prodBranchesFound = 0, prodBranchesHit = 0
        var functionsFound = 0, functionsHit = 0
        var inProductionRecord = false
        var sawSourceFileRecord = false
        var ledger = CoverageLineLedger()

        private let root: URL
        private var currentKey: String?
        private var currentIsProduction = false
        private var recordFound = 0
        private var recordHit = 0
        private var recordHasCounts = false

        init(root: URL, lineBudget: Int = CoverageLineLedger.defaultLineBudget) {
            self.root = root
            ledger.lineBudget = lineBudget
        }

        mutating func consume(_ line: String) {
            if line.hasPrefix("SF:") {
                closeRecord()
                let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                sawSourceFileRecord = true
                ledger.note(sourceFile: path)
                currentIsProduction = CoverageSourceScope.isProductionSource(path: path)
                currentKey = CoverageSourceScope.normalizedKey(path: path, root: root)
                inProductionRecord = currentIsProduction
                return
            }
            // 没有 SF: 归属的计数不允许悄悄算进生产码。
            if line == "end_of_record" {
                closeRecord()
                inProductionRecord = false
                currentKey = nil
                currentIsProduction = false
            }
            let value = CoverageAnalyzer.int(after: line)
            switch line.prefix(3) {
            case "LF:":
                recordFound += value
                recordHasCounts = true
                add(value, toAll: \.allLinesFound, toProduction: \.prodLinesFound)
            case "LH:":
                recordHit += value
                recordHasCounts = true
                add(value, toAll: \.allLinesHit, toProduction: \.prodLinesHit)
            case "BRF": add(value, toAll: \.allBranchesFound, toProduction: \.prodBranchesFound)
            case "BRH": add(value, toAll: \.allBranchesHit, toProduction: \.prodBranchesHit)
            case "DA:": consumeLineRecord(line)
            case "FNF": functionsFound += value
            case "FNH": functionsHit += value
            default: break
            }
        }

        /// `DA:<line>,<hits>`、`DA:<line>,<hits>,<name>`。hits 不是数字（少数工具写 `-`）
        /// 时按"未命中"处理：宁可少算分子，也不把未知当命中。
        private mutating func consumeLineRecord(_ line: String) {
            guard let key = currentKey else { return }
            let fields = String(line.dropFirst(3)).split(separator: ",", omittingEmptySubsequences: false)
            guard fields.count >= 2,
                  let number = Int(fields[0].trimmingCharacters(in: .whitespaces)) else { return }
            let hits = Int(fields[1].trimmingCharacters(in: .whitespaces)) ?? 0
            ledger.noteLine(key: key, line: number, isHit: hits > 0, isProduction: currentIsProduction)
        }

        /// 一条 `SF:` 记录收尾：有逐行证据时账本已经写好，没有时退化成整份文件的计数。
        private mutating func closeRecord() {
            guard recordHasCounts || ledger.files[currentKey ?? ""]?.hasLineSet == false else { return }
            defer { recordFound = 0; recordHit = 0; recordHasCounts = false }
            if let key = currentKey {
                ledger.noteAggregate(key: key, found: recordFound, hit: recordHit,
                                     isProduction: currentIsProduction)
            } else if recordHasCounts {
                // `SF:` 之外出现的 LF/LH：这份 lcov 的汇总数与文件清单对不上，
                // 拿它去做跨报告合并会少算文件 ⇒ 账本整体降级为不可信。
                ledger.noteOrphan(found: recordFound, hit: recordHit)
            }
        }

        /// 走 keyPath 而不是 `inout`：两个 `inout` 同时指向 self 的属性会撞
        /// 独占访问检查（编译器直接判错），而"全量 + 生产码"成对累加正是这里的形状。
        private mutating func add(_ value: Int,
                                  toAll all: WritableKeyPath<LCovTally, Int>,
                                  toProduction production: WritableKeyPath<LCovTally, Int>) {
            self[keyPath: all] += value
            if inProductionRecord { self[keyPath: production] += value }
        }

        /// `separated` = 这份报告真带 `SF:` 记录，才有资格谈"生产码口径"；
        /// 没有 SF: 时全量与生产码同值，且 `scopeGranularity` 必须落到 `.aggregateOnly`。
        func report(url: URL) -> CoverageReport {
            let separated = sawSourceFileRecord
            let prodBranches = separated ? prodBranchesFound : allBranchesFound
            return CoverageReport(
                path: url.path,
                kind: CoverageAnalyzer.classify(url: url),
                toolName: CoverageReportFormat.lcov.toolName,
                linesCovered: separated ? prodLinesHit : allLinesHit,
                linesTotal: separated ? prodLinesFound : allLinesFound,
                branchesCovered: separated ? prodBranchesHit : allBranchesHit,
                branchesTotal: prodBranches > 0 ? prodBranches : nil,
                methodsCovered: functionsHit, methodsTotal: functionsFound,
                allLinesCovered: allLinesHit, allLinesTotal: allLinesFound,
                allBranchesCovered: allBranchesHit,
                allBranchesTotal: allBranchesFound > 0 ? allBranchesFound : nil,
                scopeGranularity: separated ? .perSourceFile : .aggregateOnly
            )
        }
    }
}
