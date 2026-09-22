// OWNER: R3 依赖证据链 · 核对状态账本（RD-11 / RD-13 / RD-13c 的单一证据源）
//
// 这个类型是"依赖行 / 总览 / 健康评分 / 无头出口"**共用的那一份证据**。
// 它存在的理由是用户点名的那条红线：不许只修一个界面。只要三处各自再推一遍，
// 就一定会长回三套口径（本轮的原始症状就是：总览说 N 条公告、依赖行一个没标、评分当干净）。
//
// 三条硬规矩：
//   1. **禁止用中文说明里含不含"失败"决定业务状态**（RD-13）。状态只读结构化字段
//      `DependencyRecord.versionCheckState` / `.vulnerabilityCheckState` 与
//      `DependencyReport.versionLookup` / `.vulnerabilityLookup`。
//   2. **字段缺席 = 没测过**，一律落 `.notAttempted`，不做任何"看起来查过了"的猜测。
//      旧报告（没有这些字段）因此会读成"未核对"而不是"无漏洞" —— 保守方向与整改前一致。
//   3. **npm 版本查成功 ≠ OSV 漏洞查成功**：两个维度各一格，任何一处把两格合成一格都算回归。
import Foundation

// MARK: - 逐条证据

/// 一条依赖在两个核对维度上的结局，加上"为什么判不了"的原因。
struct DependencyRecordEvidence: Equatable, Sendable {
    let recordID: String
    let name: String
    let ecosystem: DependencyEcosystem
    let scope: DependencyScope
    let identity: DependencyVersionIdentity
    let versionState: DependencyCheckState
    let vulnerabilityState: DependencyCheckState
    /// 命中的漏洞标识（内置规则 + 在线公告并集）。非空即说明这一条**确实查出过东西**。
    let findings: [String]
    /// 查询用的是解析版本还是范围下界（"按下界查的"必须能在出口里说出来）。
    let queriedByLowerBound: Bool

    /// 这条依赖有没有被**任何**一路覆盖到。false 时"无漏洞"这句话对它不成立。
    var isCheckedOnBothAxes: Bool { versionState.isCovered && vulnerabilityState.isCovered }
}

// MARK: - 账本

/// 一份报告的核对账本：逐条状态 + 分 scope 统计 + "能不能说未发现漏洞"。
struct DependencyEvidenceLedger: Sendable {
    let records: [DependencyRecordEvidence]
    let versionLookup: DependencyLookupEvidence?
    let vulnerabilityLookup: DependencyLookupEvidence?
    let scopeBreakdown: [DependencyScopeCount]

    func evidence(for record: DependencyRecord) -> DependencyRecordEvidence? {
        records.first { $0.recordID == Self.recordID(for: record) }
    }

    static func recordID(for record: DependencyRecord) -> String {
        DependencyVersionIdentity.recordID(ecosystem: record.ecosystem, manifestPath: record.manifestPath,
                                           name: record.name, declaredRange: record.version)
    }

    var totalCount: Int { records.count }
    var vulnerabilityCheckedCount: Int { records.filter { $0.vulnerabilityState.isCovered }.count }
    var versionCheckedCount: Int { records.filter { $0.versionState.isCovered }.count }
    /// 有几条是**按声明范围的下界**去查的（实际安装版本没量到）。
    /// 这个数必须能单独说出来：它决定"未发现漏洞"这句话的强度 ——
    /// 按下界查到公告 ≠ 你装的这一版有公告（RD-10 明令不许把下界当安装版本）。
    var lowerBoundQueryCount: Int { records.filter { $0.queriedByLowerBound }.count }
    var vulnerableCount: Int { records.filter { !$0.findings.isEmpty }.count }

    /// 各状态的条数，出口文案与守卫用例都读它（分母必须能对上 `totalCount`）。
    func counts(of keyPath: KeyPath<DependencyRecordEvidence, DependencyCheckState>) -> [DependencyCheckState: Int] {
        var table: [DependencyCheckState: Int] = [:]
        for record in records { table[record[keyPath: keyPath], default: 0] += 1 }
        return table
    }

    var versionStateCounts: [DependencyCheckState: Int] { counts(of: \.versionState) }
    var vulnerabilityStateCounts: [DependencyCheckState: Int] { counts(of: \.vulnerabilityState) }
}

// MARK: - 构建与读取

enum DependencyEvidence {

    /// 从一份报告读出账本。纯函数：同一个报告永远得到同一份账本
    /// （GUI 重新加载旧报告、CLI 落盘后再读、评分侧都走这一个入口 ⇒ 三处必然同形）。
    static func ledger(for report: DependencyReport) -> DependencyEvidenceLedger {
        DependencyLedgerReader.read(report)
    }

    /// 单条依赖的版本核对状态。字段缺席时的推导**只许保守**：
    /// 有正向证据（拿到了最新值 / 来源标了在线源）才算 `.checked`，其余按原因落态。
    static func versionState(of record: DependencyRecord) -> DependencyCheckState {
        if let stored = record.versionCheckState { return stored }
        let identity = DependencyVersionIdentity.of(record)
        guard identity.latestKnownVersion != nil || record.versionCheckSource != .none else {
            return DependencyLockSupport.isEcosystemTrackable(record.ecosystem)
                ? .notAttempted : .ecosystemUnsupported
        }
        return identity.comparisonVersion == nil ? .versionUnresolved : .checked
    }

    /// 单条依赖的漏洞核对状态。注意它**不读** `versionCheckSource`：
    /// 版本查成功不代表漏洞查过（RD-11 的冒充关系）。
    static func vulnerabilityState(of record: DependencyRecord) -> DependencyCheckState {
        if let stored = record.vulnerabilityCheckState { return stored }
        if !record.knownVulnerabilities.isEmpty { return .checked }   // 查出过东西 = 确实核对过
        guard OsvPackageQuery.osvEcosystem(for: record.ecosystem) != nil else { return .ecosystemUnsupported }
        let identity = DependencyVersionIdentity.of(record)
        guard identity.query != nil else { return .versionUnresolved }
        // 报告级只说"尝试过"（`networkLookupPerformed` 的字段名就是它自己），
        // 逐条没有落账就一律"未查" —— 宁可得罪人，不得给假绿灯。
        return .notAttempted
    }

    /// 「未发现已知漏洞」这句话**必须同时说明已成功核对的范围与条数**（RD-11）。
    /// 覆盖不足时不允许出现这句话，改口播未覆盖的清单。
    static func findingsStatement(for report: DependencyReport, ledger: DependencyEvidenceLedger) -> String {
        let vulnerable = ledger.vulnerableCount
        if vulnerable > 0 {
            return localizedFormat("命中 %1$@ 条（%2$@ 个依赖带已知漏洞），另有 %3$@ 条未覆盖，见「安全公告」",
                                   NumberFormat.grouped(report.vulnerableCount),
                                   NumberFormat.grouped(vulnerable),
                                   NumberFormat.grouped(ledger.totalCount - ledger.vulnerabilityCheckedCount))
        }
        let checked = ledger.vulnerabilityCheckedCount
        guard checked > 0 else { return noCoverageStatement(ledger) }
        let uncovered = ledger.totalCount - checked
        var text = localizedFormat("已核对 %1$@ / %2$@ 个依赖，未发现已知漏洞",
                                   NumberFormat.grouped(checked), NumberFormat.grouped(ledger.totalCount))
        if uncovered > 0 { text += localizedFormat("；另有 %1$@ 个未覆盖：", NumberFormat.grouped(uncovered)) + tail(for: ledger) }
        else { text += "（\(sourcesPhrase(ledger))）" }
        return text
    }

    /// 一条都没核对成时的那句 —— 这句是本页最不该被省略的。
    static func noCoverageStatement(_ ledger: DependencyEvidenceLedger) -> String {
        var text = localizedFormat("漏洞核对未覆盖任何依赖（共 %1$@ 个）：", NumberFormat.grouped(ledger.totalCount))
        text += tail(for: ledger)
        return text
    }

    /// 未覆盖部分按状态点名（每种状态都要出声，不许只报一个总数）。
    static func tail(for ledger: DependencyEvidenceLedger) -> String {
        let pieces = tailPieces(ledger)
        return pieces.isEmpty ? localizedCopy("无") : pieces.joined(separator: localizedCopy("、"))
    }

    /// 同上，但**逐条返回**：调用方要判"有没有尾巴"时读这个，
    /// 不许去比较中文字面量（那是把文案当判据，RD-13 的另一种犯法形状）。
    static func tailPieces(_ ledger: DependencyEvidenceLedger) -> [String] {
        uncoveredPhrases(ledger.vulnerabilityStateCounts)
    }

    static func versionTailPieces(_ ledger: DependencyEvidenceLedger) -> [String] {
        uncoveredPhrases(ledger.versionStateCounts)
    }

    static func tailOfVersionStates(for ledger: DependencyEvidenceLedger) -> String {
        let pieces = versionTailPieces(ledger)
        return pieces.isEmpty ? localizedCopy("无") : pieces.joined(separator: localizedCopy("、"))
    }

    private static func uncoveredPhrases(_ counts: [DependencyCheckState: Int]) -> [String] {
        var pieces: [String] = []
        let order: [(DependencyCheckState, String)] = [
            (.notAttempted, "%1$@ 个未查"),
            (.failed, "%1$@ 个核对失败"),
            (.versionUnresolved, "%1$@ 个版本未解析"),
            (.ecosystemUnsupported, "%1$@ 个生态不支持"),
            (.budgetExcluded, "%1$@ 个未进查询批次（预算/上限）"),
        ]
        for (state, template) in order {
            guard let value = counts[state], value > 0 else { continue }
            pieces.append(localizedFormat(template, NumberFormat.grouped(value)))
        }
        return pieces
    }

    static func sourcesPhrase(_ ledger: DependencyEvidenceLedger) -> String {
        [ledger.vulnerabilityLookup?.source, ledger.versionLookup?.source]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: localizedCopy("、"))
    }

    /// 「能不能对外说未发现漏洞」的唯一闸门：**逐条覆盖到位**才算。
    static func mayClaimNoKnownVulnerabilities(_ ledger: DependencyEvidenceLedger) -> Bool {
        ledger.totalCount > 0 && ledger.vulnerabilityCheckedCount == ledger.totalCount
            && ledger.vulnerableCount == 0
    }
}

// MARK: - 读取实现（与账本类型分开，是为了把"推导"这段的复杂度留在一个可见的位置）

enum DependencyLedgerReader {
    static func read(_ report: DependencyReport) -> DependencyEvidenceLedger {
        var records: [DependencyRecordEvidence] = []
        for ecosystem in report.ecosystems {
            for record in ecosystem.dependencies {
                let identity = DependencyVersionIdentity.of(record)
                records.append(DependencyRecordEvidence(
                    recordID: DependencyEvidenceLedger.recordID(for: record),
                    name: record.name,
                    ecosystem: record.ecosystem,
                    scope: record.scope,
                    identity: identity,
                    versionState: DependencyEvidence.versionState(of: record),
                    vulnerabilityState: DependencyEvidence.vulnerabilityState(of: record),
                    findings: record.knownVulnerabilities,
                    queriedByLowerBound: identity.query?.basis == .rangeLowerBound
                ))
            }
        }
        return DependencyEvidenceLedger(records: records,
                                       versionLookup: report.versionLookup,
                                       vulnerabilityLookup: report.vulnerabilityLookup,
                                       scopeBreakdown: report.scopeBreakdown
                                        ?? DependencyScopeTally.tally(report: report, records: records))
    }
}

// MARK: - 分 scope 统计（RD-13c）

enum DependencyScopeTally {
    /// 六个 scope 各算一份：声明数 / 漏洞核对成功数 / 版本核对成功数 / 命中数。
    /// 顺序按 `DependencyScope.allCasesStyle`，空桶也保留（否则"这一档是 0"和
    /// "这一档没统计"在界面上又分不开了）。
    static func tally(report: DependencyReport, records: [DependencyRecordEvidence]) -> [DependencyScopeCount] {
        var buckets: [DependencyScope: DependencyScopeCount] = [:]
        for record in records {
            var bucket = buckets[record.scope] ?? DependencyScopeCount(scope: record.scope.rawValue)
            bucket.declared += 1
            if record.vulnerabilityState.isCovered { bucket.vulnerabilityChecked += 1 }
            if record.versionState.isCovered { bucket.versionChecked += 1 }
            if !record.findings.isEmpty { bucket.vulnerable += 1 }
            buckets[record.scope] = bucket
        }
        return DependencyScope.allScopeStyles.map { scope in
            buckets[scope] ?? DependencyScopeCount(scope: scope.rawValue)
        }
    }
}

extension DependencyScope {
    /// 展示与统计的稳定顺序（不是 `CaseIterable`：那会让新增一态就悄悄改变既有分档口径）。
    static let allScopeStyles: [DependencyScope] = [.runtime, .dev, .test, .build, .platform, .unknown]
}

// MARK: - 分 scope 的出口文案（RD-13c：runtime / dev / test / build 不许混成一个数）

enum DependencyScopeLines {
    /// 每个非空 scope 一行：声明多少、漏洞核对成功多少、命中多少。
    /// 空桶直接跳过（"开发依赖 0 个"不是需要用户读的东西），但**总数为 0 时也要有一行**，
    /// 否则"这页没统计"与"这个项目没有依赖"在无头出口里又长成一个样。
    static func lines(_ report: DependencyReport) -> [String] {
        let ledger = DependencyEvidence.ledger(for: report)
        let rows = ledger.scopeBreakdown.filter { $0.declared > 0 }
        guard !rows.isEmpty else {
            return ["分 scope 统计：没有可统计的依赖声明"]
        }
        return rows.map { row in
            var text = "分 scope · \(row.scope)：声明 \(row.declared)"
            text += "，漏洞已核对 \(row.vulnerabilityChecked)"
            text += "，版本已核对 \(row.versionChecked)"
            if row.vulnerable > 0 { text += "，命中 \(row.vulnerable)" }
            return text
        }
    }
}

// MARK: - 生态可跟踪性（版本核对这一路的"支持"判据）

enum DependencyLockSupport {
    /// 这个生态有没有"最新版本"这条路：内置快照收录表里有条目，或 OSV/registry 覆盖它。
    /// 判据从表里**推导**，不另抄一份清单（抄一份就会在规则增删后腐烂）。
    static func isEcosystemTrackable(_ ecosystem: DependencyEcosystem) -> Bool {
        if OsvPackageQuery.osvEcosystem(for: ecosystem) != nil { return true }
        let scopes = DependencySnapshot.lookupScopes(for: ecosystem)
        return scopes.contains { scope in DependencySnapshot.table.keys.contains { $0.hasPrefix(scope + "|") } }
    }
}
