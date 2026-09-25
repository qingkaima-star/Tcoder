import Foundation

//  R5b 搬家说明（**不是删除**，逐字节搬动）：丢弃原因、丢弃条目、总数口径与**台账本体**
//  这四块原来与规划器同住 `CoverageMergePlanner.swift`，加上 R5b 的身份读数后整文件越过
//  400 行闸门（`SourcesSizeAuditTests`），所以按类型整块搬进本文件。
//  规划器（`CoverageMergePlanner`）留在原文件里，一字未改地继续消费这些类型。

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

    // MARK: R5b · 身份层读数（契约缺口，见 `docs/R5b-覆盖率身份层契约字段清单.md`）

    /// 进总数的那几份**缺了哪些身份格**（去重、稳定序）。`mergeConfident == true` 时必为空。
    var identityGaps: [CoverageIdentityGap] = []
    /// 缺哪格是逐份点名的（路径 → 缺的格），免得"五份里有一份缺"被说成"五份都缺"。
    var identityGapsByPath: [CoverageIdentityGapPerReport] = []
    /// **认不出属于哪次运行**的报告路径（`runKey == nil`）。R5b 的判据：认不出就明说，
    /// 不许由"文件名像 unit / integration"替用户猜一次运行归属。
    var unattributedRunPaths: [String] = []

    /// 未进总数、但真实存在的读数。**分开呈现的数据源**（界面读它 = 契约缺口）。
    var separateReadings: [CoverageReport] = []

    var droppedCount: Int { dropped.count }

    /// §6.1 显示形状（三道截断共用那**一个**形状）。台账与落盘都从这一处取数，
    /// 不留第二个算式：`CoverageMetrics` 里那 6 格就是它抄过去的。
    var displayShape: CoverageDisplayShape {
        CoverageDisplayShape.evaluate(discovery: discovery, displayedCount: consideredCount)
    }

    /// "有可核对的证据没并进总数"—— 这句话**只**由它回答，与 `mergeConfident`（身份齐不齐）
    /// 是两件事，压进同一个布尔就会分不清"没测"与"测了但可疑"。
    var evidenceLeftOut: Bool {
        !dropped.isEmpty || conflictingFileCount > 0
    }

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
            parts.append("丢弃 " + grouped.joined(separator: localizedListSeparator()))
        }
        if !parseFailures.isEmpty {
            let grouped = Dictionary(grouping: parseFailures, by: { $0.reason })
                .map { "\($0.key.note) \($0.value.count) 份" }
                .sorted()
            parts.append("读取失败 " + grouped.joined(separator: localizedListSeparator()))
        }
        parts.append(contentsOf: displayShape.statementParts)
        if !unattributedRunPaths.isEmpty {
            let sorted = unattributedRunPaths.sorted()
            let named = sorted.prefix(3).map(coverageCoordinateShort)   // 只报 basename 等于没点名
            let head = sorted.count == 1 ? "这份报告认不出属于哪次运行"
                                        : "\(sorted.count) 份报告认不出属于哪次运行"
            parts.append(head + "：" + named.joined(separator: localizedListSeparator())
                + (sorted.count > named.count ? " 等" : "") + "（未知不参与去重）")
        }
        if let confident = mergeConfident, !confident, !identityGaps.isEmpty {
            parts.append("⚠ 合并身份未互证：" + identityGaps.map { $0.note }.joined(separator: localizedListSeparator()))
        }
        let details = dropped.compactMap(\.detail)
        if details.contains(where: { $0.contains(CoverageLineLedger.Blocker.budgetExceeded.rawValue) }) {
            let n = details.filter { $0.contains(CoverageLineLedger.Blocker.budgetExceeded.rawValue) }.count
            parts.append("\(n) 份报告逐行账本被内存预算截断 ⇒ 判不可信、未并入（残缺并集比没有并集更坏）")
        }
        if staleReportCount > 0 { parts.append("\(staleReportCount) 份报告早于当前源码提交，未计入") }
        if unboundReportCount > 0 { parts.append("\(unboundReportCount) 份报告没有提交绑定（mtime 不等于提交绑定）") }
        if evidenceLeftOut, basis != .nothingMergeable {
            parts.append("⚠ 总数未覆盖全部报告，别当项目全量")
        }
        return parts.joined(separator: " · ")
    }
}

/// "哪份报告缺哪几格身份"的一条点名记录。
/// **不用元组**：`(path:, gaps:)` 数组会让 `CoverageMergeLedger` 的
/// `Equatable`/`Sendable` 综合实现直接编译失败（元组不能遵守协议）。
struct CoverageIdentityGapPerReport: Equatable, Sendable {
    var path: String
    var gaps: [CoverageIdentityGap]
}
