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

    /// 一次在线核对的编排：两条路各发一批、各自记结局，最后把逐条状态与报告级账本一次写完。
    ///
    /// 拆成三个小函数（`dispatchRegistryLookup` / `dispatchOsvLookup` / `onlineNotes`），
    /// 因为合在一起是 73 行、超过本仓"函数不超过自身 CC(20)"的申报线，
    /// 且这一段每多一条判断就多一处"账本与事实分叉"的地方。
    func applyNetworkKnowledge(_ report: inout DependencyReport) async {
        let records = report.ecosystems.flatMap(\.dependencies)
        var receipt = DependencyOnlineReceipt()
        var dispatch = DependencyOnlineDispatch()
        var attempted = 0

        if await dispatchRegistryLookup(records: records, receipt: &receipt, dispatch: &dispatch,
                                        ecosystems: &report.ecosystems) { attempted += 1 }
        if await dispatchOsvLookup(records: records, receipt: &receipt, dispatch: &dispatch,
                                   report: &report) { attempted += 1 }

        let notes = Self.onlineNotes(receipt: receipt, dispatch: dispatch, attempted: attempted)
        report.networkLookupPerformed = attempted > 0
        report.networkLookupNote = DependencySnapshot.noteAppended(to: notes.joined(separator: localizedCopy("；")))
        // 状态落账：逐条结局 + 报告级账本 + 分 scope 统计（离线侧在 analyze 里走同一个函数）。
        applyCheckStates(&report, online: receipt, dispatch: dispatch)
    }

    /// npm registry 那条路（版本核对）。返回"这一路到底发没发"。
    ///
    /// 先去重、再按单次上限切：切掉的那些是**我们主动没查**，必须按**身份**记下来，
    /// 让他们落 `.budgetExcluded` —— 只记条数的话，"发出去了但数据源没答"与"根本没发"
    /// 在逐条状态上就长成一个样（那正是本条流要消灭的形状）。
    private func dispatchRegistryLookup(records: [DependencyRecord],
                                        receipt: inout DependencyOnlineReceipt,
                                        dispatch: inout DependencyOnlineDispatch,
                                        ecosystems: inout [EcosystemReport]) async -> Bool {
        let npmNames = Array(Set(records.filter { $0.ecosystem == .npm }.compactMap { record in
            DependencyVersionIdentity.of(record).query == nil ? nil : record.name
        })).sorted()
        let batch = Array(npmNames.prefix(DependencyNetworkLookup.maxNpmPackages))
        dispatch.registrySent = Set(batch)
        dispatch.registryDeferred = Set(npmNames.dropFirst(batch.count))
        guard !batch.isEmpty else { return false }
        let registry = await onlineSource.registryLatestVersions(for: batch)
        receipt.latestVersions = registry.latestVersions
        receipt.failedRegistryPackages = registry.failedRegistryPackages
        receipt.registryNote = registry.registryNote
        Self.applyRegistryVersions(RegistryLookupResult(latestVersions: registry.latestVersions,
                                                       packagesChecked: batch.count,
                                                       failedRequests: registry.failedRegistryPackages.count,
                                                       note: registry.registryNote),
                                   to: &ecosystems)
        return true
    }

    /// OSV 那条路（漏洞核对）。查询身份由版本身份给出（锁文件解析值优先）。
    private func dispatchOsvLookup(records: [DependencyRecord],
                                   receipt: inout DependencyOnlineReceipt,
                                   dispatch: inout DependencyOnlineDispatch,
                                   report: inout DependencyReport) async -> Bool {
        var queries: [(query: OsvPackageQuery, coordinate: String)] = []
        for record in records {
            guard let built = OsvPackageQuery.query(from: record) else { continue }
            queries.append(built)
        }
        let batch = Array(queries.prefix(DependencyNetworkLookup.maxOsvBatchPackages))
        dispatch.osvSent = Set(batch.map(\.coordinate))
        dispatch.osvDeferred = Set(queries.dropFirst(batch.count).map(\.coordinate))
        guard !batch.isEmpty else { return false }
        let osv = await onlineSource.osvAdvisories(for: batch.map(\.query))
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
        return true
    }

    /// 给人看的那句在线说明。**不参与任何判定**（判定只读 `DependencyCheckState`）。
    static func onlineNotes(receipt: DependencyOnlineReceipt,
                            dispatch: DependencyOnlineDispatch,
                            attempted: Int) -> [String] {
        var notes: [String] = []
        if !receipt.registryNote.isEmpty { notes.append(receipt.registryNote) }
        if !receipt.osvNote.isEmpty { notes.append(receipt.osvNote) }
        if !dispatch.registryDeferred.isEmpty {
            notes.append("npm registry 单次上限：\(dispatch.registryDeferred.count) 个包未查询")
        }
        if !dispatch.osvDeferred.isEmpty {
            notes.append("OSV 单次上限：\(dispatch.osvDeferred.count) 条未查询")
        }
        if notes.isEmpty {
            notes.append(attempted > 0 ? "在线查询已完成（OSV + npm registry）"
                                       : "本项目没有可在线查询的生态（SwiftPM / CocoaPods 不在 OSV 覆盖范围内）")
        }
        return notes
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
    ///
    /// `dispatch` 是"这一轮到底把哪些身份发出去了"的账 —— **`.budgetExcluded` 只能按身份落**。
    /// 接手时这里传的是条数（`["osv": 7]`），于是"被上限切掉的 7 条"会把**发出去的 100 条**
    /// 也一起说成"未进批次"（实测 107 条全落 budgetExcluded），而数据源明明答过它们；
    /// 反过来说谎的方向也一样：账没收上来的那条被说成"没发"，就永远不会有人去查。
    func applyCheckStates(_ report: inout DependencyReport,
                          online: DependencyOnlineReceipt?,
                          dispatch: DependencyOnlineDispatch = .empty) {
        Self.mutateRecords(&report.ecosystems) { record in
            let identity = DependencyVersionIdentity.of(record)
            record.versionCheckState = Self.versionState(record: record, identity: identity,
                                                         online: online, dispatch: dispatch)
            record.vulnerabilityCheckState = Self.vulnerabilityState(record: record, identity: identity,
                                                                     online: online, dispatch: dispatch)
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

    /// 版本核对的六态。判定只用结构化事实：解析身份 + 有没有拿到最新值 + 这一条发没发出去。
    static func versionState(record: DependencyRecord,
                             identity: DependencyVersionIdentity,
                             online: DependencyOnlineReceipt?,
                             dispatch: DependencyOnlineDispatch = .empty) -> DependencyCheckState {
        guard identity.comparisonVersion != nil else {
            // 只有范围 / 通配 / workspace / 外部来源：安装版本没量到 —— 哪怕 registry 答了
            // "最新是哪个"，也不知道**本机装的是哪个**，所以这一格不是"已核对"。
            return record.latestKnownVersion == nil && !DependencyLockSupport.isEcosystemTrackable(record.ecosystem)
                ? .ecosystemUnsupported : .versionUnresolved
        }
        guard record.latestKnownVersion != nil else {
            guard DependencyLockSupport.isEcosystemTrackable(record.ecosystem) else { return .ecosystemUnsupported }
            // 被单次上限挡在门外 = 我们主动没查，不是数据源失败。
            if online != nil, dispatch.registryDeferred.contains(record.name) { return .budgetExcluded }
            if let online, online.failedRegistryPackages.contains(record.name) { return .failed }
            return online == nil ? .notAttempted : .failed
        }
        return .checked
    }

    /// 漏洞核对的六态。**不看 `versionCheckSource`** —— 版本查成功不代表漏洞查过。
    static func vulnerabilityState(record: DependencyRecord,
                                   identity: DependencyVersionIdentity,
                                   online: DependencyOnlineReceipt?,
                                   dispatch: DependencyOnlineDispatch = .empty) -> DependencyCheckState {
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
        guard online != nil else { return .notAttempted }
        // 在线跑了、这一条却没有回执：按**身份**分清两种结局，谁也不许冒充谁。
        if dispatch.osvDeferred.contains(coordinate) { return .budgetExcluded }
        return dispatch.osvSent.contains(coordinate) ? .failed : .notAttempted
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
