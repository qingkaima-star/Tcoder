// OWNER: R3 依赖证据链 · 分析器的在线核对与状态落账（RD-11 / RD-12 / RD-13c）
//
// 自 `ManifestDependencyAnalyzer.swift` 拆出（400 行口径），并且把三件事一次改完：
//   ① 查询身份与回填身份**同源**（RD-12）：两侧都只经
//      `DependencyVersionIdentity.coordinate(ecosystem:name:queryVersion:)`，
//      旧实现是"查询用 `pkg@1.2.3`、回填查 `pkg@^1.2.3`"，于是总览有公告、依赖行不标。
//   ② 逐条依赖分别落**版本核对**与**漏洞核对**状态（RD-11），六态齐。
//   ③ 报告级账本 `versionLookup` / `vulnerabilityLookup` / `scopeBreakdown` 由**同一份
//      逐条状态**汇总（分母对得上由守卫用例钉住），三处消费者不再各推一遍。
import Foundation

extension ManifestDependencyAnalyzer {

    // MARK: - 在线核对（可注入假源；默认走真源）

    func applyNetworkKnowledge(_ report: inout DependencyReport) async {
        let records = report.ecosystems.flatMap(\.dependencies)
        var notes: [String] = []
        var attempted = 0
        var receipt = DependencyOnlineReceipt()

        // npm 版本核对路：先去重、再按单次上限切，切掉的那些是**我们主动没查**，
        // 必须落 `.budgetExcluded`，不能让他们在报告里长成"查过、干净"。
        let npmRecords = records.filter { $0.ecosystem == .npm }
        let npmNames = Array(Set(npmRecords.compactMap { record in
            DependencyVersionIdentity.of(record).query == nil ? nil : record.name
        })).sorted()
        let npmBatch = Array(npmNames.prefix(DependencyNetworkLookup.maxNpmPackages))
        let npmBudgetExcluded = npmNames.count - npmBatch.count
        if !npmBatch.isEmpty {
            attempted += 1
            let registry = await onlineSource.registryLatestVersions(for: npmBatch)
            receipt.latestVersions = registry.latestVersions
            receipt.failedRegistryPackages = registry.failedRegistryPackages
            receipt.registryNote = registry.registryNote
            Self.applyRegistryVersions(RegistryLookupResult(latestVersions: registry.latestVersions,
                                                           packagesChecked: npmBatch.count,
                                                           failedRequests: registry.failedRegistryPackages.count,
                                                           note: registry.registryNote),
                                      to: &report.ecosystems)
        }

        // OSV 漏洞核对路：查询身份由版本身份给出（锁文件解析值优先）。
        var queries: [(query: OsvPackageQuery, coordinate: String)] = []
        for record in records {
            guard let built = OsvPackageQuery.query(from: record) else { continue }
            queries.append(built)
        }
        let osvBatchQueries = Array(queries.prefix(DependencyNetworkLookup.maxOsvBatchPackages))
        let osvBudgetExcluded = queries.count - osvBatchQueries.count
        if !osvBatchQueries.isEmpty {
            attempted += 1
            let osv = await onlineSource.osvAdvisories(for: osvBatchQueries.map(\.query))
            receipt.osvOutcomes = osv.osvOutcomes
            receipt.osvPathUnavailable = osv.osvPathUnavailable
            receipt.osvNote = osv.osvNote
            // 去重：内置规则已经命中同一 CVE / 规则的包，在线不再重复计入。
            let covered = Self.coveredIdentifiers(in: records)
            let fresh = osv.osvOutcomes.values.flatMap { outcome -> [SecurityAdvisory] in
                guard case .answered(let advisories) = outcome else { return [] }
                return advisories
            }
            let unseen = fresh.filter { advisory in
                !Self.intersects(covered, with: [advisory.id] + advisory.aliases)
            }
            let merged = VulnerabilitySource.sortedAdvisories(Self.dedupedAdvisories(unseen))
            report.advisories = merged
            Self.backfill(advisories: merged, coordinates: queries, into: &report.ecosystems)
        }
        if !receipt.registryNote.isEmpty { notes.append(receipt.registryNote) }
        if !receipt.osvNote.isEmpty { notes.append(receipt.osvNote) }
        if npmBudgetExcluded > 0 {
            notes.append("npm registry 单次上限：\(npmBudgetExcluded) 个包未查询")
        }
        if osvBudgetExcluded > 0 {
            notes.append("OSV 单次上限：\(osvBudgetExcluded) 条未查询")
        }

        report.networkLookupPerformed = attempted > 0
        report.networkLookupNote = DependencySnapshot.noteAppended(to: notes.isEmpty
            ? (attempted > 0 ? "在线查询已完成（OSV + npm registry）"
                              : "本项目没有可在线查询的生态（SwiftPM / CocoaPods 不在 OSV 覆盖范围内）")
            : notes.joined(separator: localizedCopy("；")))
        // 状态落账：把逐条结局 + 报告级账本一次写完（离线侧在 analyze 里走同一个函数）。
        var excluded = [String: Int]()
        if npmBudgetExcluded > 0 { excluded["npm"] = npmBudgetExcluded }
        if osvBudgetExcluded > 0 { excluded["osv"] = osvBudgetExcluded }
        applyCheckStates(&report, online: receipt, budgetExcluded: excluded)
    }

    // MARK: - 回填（RD-12：按查询身份，不按字符串拼装）

    /// 把在线公告并回受影响依赖的 `knownVulnerabilities`。
    ///
    /// 两侧 key 都由 `OsvPackageQuery.coordinate` / `DependencyVersionIdentity.coordinate`
    /// 生成 —— 旧实现一侧是 `pkg@1.2.3`（查询用的收敛版本）、一侧是 `pkg@^1.2.3`
    /// （记录里的声明原文），永不相等，公告于是永远回不到依赖行上。
    static func backfill(advisories: [SecurityAdvisory],
                         coordinates: [(query: OsvPackageQuery, coordinate: String)],
                         into ecosystems: inout [EcosystemReport]) {
        guard !advisories.isEmpty else { return }
        var identifiersByCoordinate: [String: [String]] = [:]
        for advisory in advisories {
            let payload = advisory.aliases.filter { $0.hasPrefix("CVE-") }
            let identifiers = payload.isEmpty ? [advisory.id] : payload
            for coordinate in advisory.affectedPackages {
                identifiersByCoordinate[coordinate, default: []].append(contentsOf: identifiers)
            }
        }
        guard !identifiersByCoordinate.isEmpty else { return }
        let byName: [String: [String]] = Dictionary(uniqueKeysWithValues: Set(coordinates.map(\.query.package))
            .map { package in (package, coordinates.filter { $0.query.package == package }.map(\.coordinate)) })
        mutateRecords(&ecosystems) { record in
            // 只在该包名可能命中的坐标里找，找到就并回；找不到就是真没查到。
            let candidates = byName[record.name] ?? []
            let own = DependencyVersionIdentity.of(record).queryCoordinate
            guard let key = own, candidates.contains(key),
                  let extra = identifiersByCoordinate[key] else { return }
            record.knownVulnerabilities = deduped(record.knownVulnerabilities + extra)
        }
    }

    /// 公告按 id 去重（同一公告可能被多条查询各自带回）。
    static func dedupedAdvisories(_ advisories: [SecurityAdvisory]) -> [SecurityAdvisory] {
        var seen = Set<String>()
        return advisories.filter { seen.insert($0.id).inserted }
    }

    // MARK: - 状态与账本（RD-11 / RD-13c）

    /// 逐条落两个核对状态，并把它们**汇总**成报告级账本与分 scope 统计。
    /// 离线时 `online == nil`：任何"在线才查得出"的结论都必须落回未查。
    func applyCheckStates(_ report: inout DependencyReport,
                          online: DependencyOnlineReceipt?,
                          budgetExcluded: [String: Int] = [:]) {
        Self.mutateRecords(&report.ecosystems) { record in
            let identity = DependencyVersionIdentity.of(record)
            record.versionCheckState = Self.versionState(record: record, identity: identity, online: online)
            record.vulnerabilityCheckState = Self.vulnerabilityState(record: record, identity: identity,
                                                                    online: online,
                                                                    budgetExcluded: budgetExcluded["osv"] ?? 0)
            // 版本值与来源字段成对写：registry 答上了才算在线源，答不上原样留着。
            if record.versionCheckState == .checked, record.latestKnownVersion != nil,
               record.versionCheckSource == .none, let latest = online?.latestVersions[record.name] {
                record.latestKnownVersion = latest
                record.versionCheckSource = .onlineRegistry
            }
        }
        report.versionLookup = Self.lookupEvidence(source: online == nil
            ? localizedCopy("内置快照") : localizedCopy("内置快照 + npm registry"),
                                                   records: report.allRecordsView,
                                                   keyPath: \.versionCheckState)
        report.vulnerabilityLookup = Self.lookupEvidence(source: online == nil
            ? localizedCopy("内置规则") : localizedCopy("内置规则 + OSV"),
                                                         records: report.allRecordsView,
                                                         keyPath: \.vulnerabilityCheckState)
        report.scopeBreakdown = Self.scopeBreakdown(in: report)
    }

    /// 版本核对的六态。判定只用结构化事实：解析身份 + 有没有拿到最新值 + 该路结局。
    static func versionState(record: DependencyRecord,
                             identity: DependencyVersionIdentity,
                             online: DependencyOnlineReceipt?) -> DependencyCheckState {
        guard identity.comparisonVersion != nil else {
            // 只有范围 / 通配 / workspace / 外部来源：安装版本没量到。
            return record.latestKnownVersion == nil && !DependencyLockSupport.isEcosystemTrackable(record.ecosystem)
                ? .ecosystemUnsupported : .versionUnresolved
        }
        guard record.latestKnownVersion != nil else {
            guard DependencyLockSupport.isEcosystemTrackable(record.ecosystem) else { return .ecosystemUnsupported }
            if let online, online.failedRegistryPackages.contains(record.name) { return .failed }
            return online == nil ? .notAttempted : .failed
        }
        return .checked
    }

    /// 漏洞核对的六态。**不看 `versionCheckSource`** —— 版本查成功不代表漏洞查过。
    static func vulnerabilityState(record: DependencyRecord,
                                   identity: DependencyVersionIdentity,
                                   online: DependencyOnlineReceipt?,
                                   budgetExcluded: Int) -> DependencyCheckState {
        if !record.knownVulnerabilities.isEmpty { return .checked }
        guard OsvPackageQuery.osvEcosystem(for: record.ecosystem) != nil else { return .ecosystemUnsupported }
        guard let coordinate = identity.queryCoordinate else { return .versionUnresolved }
        if let outcome = online?.osvOutcomes[coordinate] {
            switch outcome {
            case .answered: return .checked
            case .failed: return .failed
            case .skipped: break
            }
        }
        if online == nil { return .notAttempted }
        // 在线跑了、但这坐标没回执：要么被单次上限切掉，要么是回执缺账 —— 都算没覆盖到。
        return budgetExcluded > 0 ? .budgetExcluded : .notAttempted
    }

    /// 报告级账本 = 逐条状态求和（分母恒等于记录总数，由用例钉住）。
    static func lookupEvidence(source: String,
                               records: [DependencyRecord],
                               keyPath: KeyPath<DependencyRecord, DependencyCheckState?>) -> DependencyLookupEvidence {
        var evidence = DependencyLookupEvidence(source: source)
        evidence.totalRecords = records.count
        for record in records {
            guard let state = record[keyPath: keyPath] else { continue }
            switch state {
            case .notAttempted: break
            case .checked: evidence.checked += 1; evidence.attempted += 1
            case .failed: evidence.failed += 1; evidence.attempted += 1
            case .versionUnresolved: evidence.versionUnresolved += 1
            case .ecosystemUnsupported: evidence.ecosystemUnsupported += 1
            case .budgetExcluded: evidence.budgetExcluded += 1
            }
            if DependencyVersionIdentity.of(record).query?.basis == .rangeLowerBound {
                evidence.lowerBoundQueries += 1
            }
        }
        return evidence
    }

    /// 分 scope 统计（RD-13c）。**每个 scope 一行，空桶也保留**。
    static func scopeBreakdown(in report: DependencyReport) -> [DependencyScopeCount] {
        var buckets: [DependencyScope: DependencyScopeCount] = [:]
        for record in report.allRecordsView {
            var bucket = buckets[record.scope] ?? DependencyScopeCount(scope: record.scope.rawValue)
            bucket.declared += 1
            if record.vulnerabilityCheckState?.isCovered == true { bucket.vulnerabilityChecked += 1 }
            if record.versionCheckState?.isCovered == true { bucket.versionChecked += 1 }
            if !record.knownVulnerabilities.isEmpty { bucket.vulnerable += 1 }
            buckets[record.scope] = bucket
        }
        return DependencyScope.allScopeStyles.map { buckets[$0] ?? DependencyScopeCount(scope: $0.rawValue) }
    }

    // MARK: - 从分析器主体搬来的三个助手（跨文件同类型扩展不得是 private）

    /// 把 registry 取回的最新版本写回记录，并把来源**一并**归因为在线源。
    ///
    /// 版本值和来源字段必须成对写：只写值不改来源，UI 会把"实现在线核对过"读成"没核对"；
    /// 反过来把来源改掉却不落值，就是凭空声称。registry 没答的包一律原样保留
    /// （内置快照或 `.none`），这样"其实没查到"仍然读起来像"没查到"。
    static func applyRegistryVersions(_ registry: RegistryLookupResult,
                                      to ecosystems: inout [EcosystemReport]) {
        mutateRecords(&ecosystems) { record in
            let identity = DependencyVersionIdentity.of(record)
            guard record.ecosystem == .npm, identity.query != nil,
                  let latest = registry.latestVersions[record.name] else { return }
            record.latestKnownVersion = latest
            record.versionCheckSource = .onlineRegistry
        }
    }

    /// 已被内置规则覆盖的标识（CVE + 规则 id），用于避免在线结果重复计入。
    static func coveredIdentifiers(in records: [DependencyRecord]) -> Set<String> {
        var covered = Set<String>()
        for record in records {
            // 取数口径与在线查询同一个身份函数，不再各剥一次 `^`。
            guard let queryVersion = DependencyVersionIdentity.of(record).query?.version else { continue }
            covered.formUnion(VulnerabilitySource.coveredIdentifiers(ecosystem: record.ecosystem,
                                                                    name: record.name,
                                                                    version: queryVersion))
        }
        return covered
    }

    static func intersects(_ set: Set<String>, with values: [String]) -> Bool {
        values.contains { set.contains($0) }
    }
}

extension DependencyReport {
    /// 展平后的记录视图（账本与统计的共用入口，避免各处各写一遍 flatMap）。
    var allRecordsView: [DependencyRecord] { ecosystems.flatMap(\.dependencies) }
}
