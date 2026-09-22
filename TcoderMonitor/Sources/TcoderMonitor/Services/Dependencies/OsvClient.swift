// OSV 客户端（WS-B · 依赖安全四层里的第 3 层）
//
// `DependencyNetworkLookup` 的 OSV 侧实现：querybatch + /v1/vulns/<id> 详情补齐、
// 详情展开的三态账本、OSV -> SecurityAdvisory 映射、以及全部 JSON 形状。
import Foundation

extension DependencyNetworkLookup {
    // MARK: - OSV pipeline internals

    struct OsvPayload: Sendable {
        var advisories: [SecurityAdvisory]
        var failedRequests: Int
        var note: String?
    }

    struct NpmPayload: Sendable {
        var versions: [String: String]
        var failedRequests: Int
        var note: String?
    }

    /// 同一条 OSV 记录可能被多个包命中，用这个累加结构做关联与去重。
    struct OsvEntry {
        var vuln: OsvVuln?
        var queryIndices: [Int]
    }

    /// OSV 详情拉取的三种结局。混为一谈就会把"没来得及展开"报成"全丢"，
    /// 或反过来让已经取回的那部分悄悄消失（缺陷 D2）。
    static func tallyOsvDetails(totalIDs: Int, outcomes: [OsvDetailOutcome]) -> OsvDetailTally {
        OsvDetailTally(totalIDs: totalIDs, outcomes: outcomes)
    }

    /// 展开不全时必须把总量与去向说清楚：共 N 条 / 上限截断多少 / 预算内没跑到多少 /
    /// 拉取失败多少 / 已取回多少条计入结果。
    static func osvDetailNote(totalIDs: Int, tally: OsvDetailTally, cap: Int) -> String? {
        guard tally.needsDisclosure else { return nil }
        var parts: [String] = []
        if tally.skippedByCap > 0 {
            parts.append("共 \(totalIDs) 条，受单次上限只展开 \(min(cap, totalIDs)) 条、\(tally.skippedByCap) 条未展开")
        }
        if tally.notAttemptedByBudget > 0 { parts.append("\(tally.notAttemptedByBudget) 条因时间预算未展开") }
        if tally.failed > 0 { parts.append("\(tally.failed) 条详情拉取失败") }
        parts.append("已取回 \(tally.fetched) 条并计入结果")
        return "OSV 详情：" + parts.joined(separator: "；")
    }

    /// 一次 OSV 在线查询的账本：条目累加结果 + 失败计数 + 自述说明。
    struct OsvSeed: Sendable {
        var entries: [String: OsvEntry]
        var failed: Int
        var note: String?
    }

    static func performOsvLookup(_ queries: [OsvPackageQuery], deadline: Date) async -> OsvPayload {
        let seed = await osvSeedEntries(queries, deadline: deadline)
        guard !seed.entries.isEmpty else {
            return OsvPayload(advisories: [], failedRequests: seed.failed, note: seed.note)
        }
        var entries = seed.entries
        var note = seed.note
        await expandOsvDetails(&entries, deadline: deadline, note: &note)
        let advisories = osvAdvisories(from: entries, queries: queries)
        if seed.failed > 0 { appendNote(&note, "本次 \(seed.failed) 个 OSV 请求失败") }
        return OsvPayload(advisories: VulnerabilitySource.sortedAdvisories(advisories),
                          failedRequests: seed.failed, note: note)
    }

    /// 第一步：批量端点拿 id，拿不到就整批退回逐包查询。
    /// 「批量失败算 1 次 + 逐包逐次算」这个计数口径，以及那句中文，与拆分前逐字相同。
    static func osvSeedEntries(_ queries: [OsvPackageQuery], deadline: Date) async -> OsvSeed {
        var failed = 0
        var note: String?
        var entries = [String: OsvEntry]()
        if let idsByQuery = await osvQueryBatch(queries, deadline: deadline) {
            for (index, ids) in idsByQuery.enumerated() where index < queries.count {
                for id in ids { merge(&entries, id: id, queryIndex: index, vuln: nil) }
            }
        } else {
            failed += 1
            note = "OSV 批量接口不可用，已改用逐包查询"
            let fallback = await osvSingleQueryFallback(queries, deadline: deadline)
            failed += fallback.failedRequests
            for row in fallback.rows { merge(&entries, id: row.id, queryIndex: row.queryIndex, vuln: row.vuln) }
        }
        return OsvSeed(entries: entries, failed: failed, note: note)
    }

    /// 第二步：批量接口只回 id，需要再按 id 拉完整记录。
    /// 展开不全时的三态账本与那句披露说明原样搬过来，没有改判定顺序。
    static func expandOsvDetails(_ entries: inout [String: OsvEntry],
                                 deadline: Date,
                                 note: inout String?) async {
        let missing = entries.compactMap { $0.value.vuln == nil ? $0.key : nil }.sorted()
        let toFetch = Array(missing.prefix(maxOsvDetailRequests))
        let detailRows: [(id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?)] =
            toFetch.isEmpty ? [] : await fetchOsvDetails(toFetch, deadline: deadline)
        for row in detailRows {
            if let vuln = row.vuln {
                merge(&entries, id: row.id, queryIndex: nil, vuln: vuln)
            } else {
                // 展开失败/未展开的 id 出不了公告，但已取回的那些必须留下。
                entries[row.id] = nil
            }
        }
        let tally = OsvDetailTally(totalIDs: missing.count, outcomes: detailRows.map(\.outcome))
        if let truncation = osvDetailNote(totalIDs: missing.count, tally: tally,
                                         cap: maxOsvDetailRequests) {
            appendNote(&note, truncation)
        }
    }

    /// 第三步：条目 -> SecurityAdvisory。
    /// 「内置快照已命中同一 CVE / 规则的包跳过，避免与离线结果重复计入」这条覆盖口径
    /// 逐字未改，`ecosystem` 取第一条可归因的查询、`packages` 去重后升序也一样。
    static func osvAdvisories(from entries: [String: OsvEntry],
                              queries: [OsvPackageQuery]) -> [SecurityAdvisory] {
        var advisories: [SecurityAdvisory] = []
        advisories.reserveCapacity(entries.count)
        for (id, entry) in entries {
            guard let vuln = entry.vuln else { continue }
            var packages: [String] = []
            var ecosystem: DependencyEcosystem?
            for index in entry.queryIndices where index < queries.count {
                let query = queries[index]
                guard let queryEcosystem = OsvPackageQuery.dependencyEcosystem(for: query.ecosystem) else { continue }
                // 内置快照已命中同一 CVE / 规则的包，跳过，避免与离线结果重复计入。
                let covered = VulnerabilitySource.coveredIdentifiers(
                    ecosystem: queryEcosystem, name: query.package, version: query.version
                )
                if ([id] + (vuln.aliases ?? [])).contains(where: { covered.contains($0) }) { continue }
                if ecosystem == nil { ecosystem = queryEcosystem }
                packages.append(query.coordinate)   // RD-12：与查询侧同一个 key，回填才接得上
            }
            guard let ecosystem else { continue }
            advisories.append(makeAdvisory(id: id, vuln: vuln, ecosystem: ecosystem,
                                           affectedPackages: Array(Set(packages)).sorted()))
        }
        return advisories
    }

    static func merge(_ entries: inout [String: OsvEntry], id: String,
                              queryIndex: Int?, vuln: OsvVuln?) {
        var entry = entries[id] ?? OsvEntry(vuln: nil, queryIndices: [])
        if entry.vuln == nil { entry.vuln = vuln }
        if let queryIndex, !entry.queryIndices.contains(queryIndex) {
            entry.queryIndices.append(queryIndex)
        }
        entries[id] = entry
    }

    /// POST https://api.osv.dev/v1/querybatch；失败返回 nil（由调用方走逐包回退）。
    static func osvQueryBatch(_ queries: [OsvPackageQuery], deadline: Date) async -> [[String]]? {
        guard let url = osvURL("v1/querybatch"),
              let body = try? JSONEncoder().encode(osvBatchPayload(for: queries)) else { return nil }
        var request = makeRequest(url: url, deadline: deadline)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request), isOK(response),
              let decoded = try? jsonDecoder.decode(OsvBatchResponse.self, from: data),
              let results = decoded.results else { return nil }
        return queries.indices.map { index in
            index < results.count ? (results[index].vulns ?? []).map(\.id) : []
        }
    }

    static func osvBatchPayload(for queries: [OsvPackageQuery]) -> OsvBatchPayload {
        OsvBatchPayload(queries: queries.map { query in
            OsvQueryPayload(package: OsvEcosystemPackage(name: query.package, ecosystem: query.ecosystem),
                            version: query.version)
        })
    }

    /// 回退路径：逐包 `POST https://api.osv.dev/v1/query`（单条 query，直接返回完整记录）。
    ///
    /// `osvQuerySingle` 用 `nil` 表示「这条请求没成功」，`[]` 表示「成功了但没有公告」——
    /// 两者以前都返回 `[]`，于是 `chunk.count - chunkRows.count` 恒为 0，
    /// **12 个包全失败也只报批量那 1 次**（缺陷 D1：把失败面往小里报）。
    static func osvSingleQueryFallback(_ queries: [OsvPackageQuery], deadline: Date) async
        -> (rows: [(queryIndex: Int, id: String, vuln: OsvVuln)], failedRequests: Int) {
        let capped = Array(queries.prefix(30))
        var rows: [(queryIndex: Int, id: String, vuln: OsvVuln)] = []
        var failed = 0
        var index = 0
        while index < capped.count {
            guard Date() < deadline else {
                failed += capped.count - index
                break
            }
            let range = index..<min(index + 10, capped.count)
            let chunk = Array(range).map { (position: $0, query: capped[$0]) }
            index = range.upperBound
            let chunkRows = await withTaskGroup(
                of: (queryIndex: Int, vulns: [OsvVuln]?).self,
                returning: [(queryIndex: Int, vulns: [OsvVuln]?)].self
            ) { group in
                for item in chunk {
                    group.addTask { (item.position, await self.osvQuerySingle(item.query, deadline: deadline)) }
                }
                var acc: [(queryIndex: Int, vulns: [OsvVuln]?)] = []
                for await row in group { acc.append(row) }
                return acc
            }
            for row in chunkRows {
                if let vulns = row.vulns {
                    for vuln in vulns { rows.append((row.queryIndex, vuln.id, vuln)) }
                } else {
                    failed += 1        // 这一包的请求失败了，逐包如实计数
                }
            }
            failed += max(0, chunk.count - chunkRows.count)
        }
        return (rows, failed)
    }

    /// 返回 `nil` = 请求没成功（网络/HTTP/解码失败）；返回 `[]` = 成功且确实没有公告。
    static func osvQuerySingle(_ query: OsvPackageQuery, deadline: Date) async -> [OsvVuln]? {
        guard let url = osvURL("v1/query"),
              let body = try? JSONEncoder().encode(
                OsvQueryPayload(package: OsvEcosystemPackage(name: query.package, ecosystem: query.ecosystem),
                                version: query.version)
              ) else { return nil }
        var request = makeRequest(url: url, deadline: deadline)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request), isOK(response),
              let decoded = try? jsonDecoder.decode(OsvQueryResponse.self, from: data) else { return nil }
        return decoded.vulns ?? []
    }

    static func fetchOsvDetails(_ ids: [String], deadline: Date) async
        -> [(id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?)] {
        var output: [(id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?)] = []
        output.reserveCapacity(ids.count)
        var index = 0
        while index < ids.count {
            guard Date() < deadline else {
                // 时间预算用尽：剩下的只是"没来得及展开"，不是拉取失败，
                // 更不能因为它们没回来就把已取回的那部分一起丢掉。
                output.append(contentsOf: ids[index...].map { (id: $0, outcome: OsvDetailOutcome.notAttempted, vuln: nil) })
                break
            }
            let range = index..<min(index + osvDetailConcurrency, ids.count)
            let chunk = Array(ids[range])
            index = range.upperBound
            let rows = await withTaskGroup(
                of: (id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?).self,
                returning: [(id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?)].self
            ) { group in
                for id in chunk {
                    group.addTask {
                        let vuln = await self.fetchOsvVuln(id: id, deadline: deadline)
                        return (id, vuln == nil ? OsvDetailOutcome.failed : OsvDetailOutcome.fetched, vuln)
                    }
                }
                var acc: [(id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?)] = []
                for await row in group { acc.append(row) }
                return acc
            }
            output.append(contentsOf: rows)
        }
        return output
    }

    /// GET https://api.osv.dev/v1/vulns/<id>
    static func fetchOsvVuln(id: String, deadline: Date) async -> OsvVuln? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = osvURL("v1/vulns/\(encoded)") else { return nil }
        guard let (data, response) = try? await session.data(for: makeRequest(url: url, deadline: deadline)),
              isOK(response) else { return nil }
        return try? jsonDecoder.decode(OsvVuln.self, from: data)
    }

    // MARK: - OSV -> SecurityAdvisory 映射

    static func makeAdvisory(id: String, vuln: OsvVuln, ecosystem: DependencyEcosystem,
                                     affectedPackages: [String]) -> SecurityAdvisory {
        var severity: RiskLevel = .medium
        var severityKnown = false
        if let label = vuln.databaseSpecific?.severity, let mapped = mapSeverityLabel(label) {
            severity = mapped
            severityKnown = true
        } else if let score = vuln.severity?.first?.score {
            let trimmed = score.trimmingCharacters(in: .whitespacesAndNewlines)
            if let numeric = Double(trimmed) {
                severity = mapCvssScore(numeric)
                severityKnown = true
            } else if let mapped = mapSeverityLabel(trimmed) {
                severity = mapped
                severityKnown = true
            }
        }

        let summary = firstNonEmpty(vuln.summary, vuln.details)
        var parts: [String] = []
        let body = truncate(firstNonEmpty(vuln.details, vuln.summary), length: 700)
        if !body.isEmpty { parts.append(body) }
        let rangeText = rangeDescription(for: vuln)
        if !rangeText.isEmpty { parts.append("影响版本范围（OSV）：\(rangeText)") }
        if !severityKnown { parts.append("OSV 未标注严重度，暂按「中」处理，请以官方公告为准。") }

        return SecurityAdvisory(
            id: id,
            aliases: vuln.aliases ?? [],
            summary: summary.isEmpty ? "OSV 披露 \(id)" : summary,
            details: parts.isEmpty ? "详见 OSV 记录 \(id)。" : parts.joined(separator: "\n"),
            severity: severity,
            cvssScore: nil,
            affectedPackages: affectedPackages,
            ecosystem: ecosystem,
            publishedAt: parseDate(vuln.published),
            source: "OSV (api.osv.dev)"
        )
    }

    /// affected[].ranges[].events 的 introduced / fixed / last_affected 拼成人可读范围。
    static func rangeDescription(for vuln: OsvVuln) -> String {
        var pieces: [String] = []
        var seen = Set<String>()
        for affected in vuln.affected ?? [] {
            for range in affected.ranges ?? [] {
                var introduced: String?
                var fixed: String?
                for event in range.events ?? [] {
                    if let value = event.introduced, introduced == nil { introduced = value }
                    if let value = event.fixed, fixed == nil { fixed = value }
                    if let value = event.lastAffected, fixed == nil { fixed = "\(value) 及更早" }
                }
                let text: String
                switch (introduced, fixed) {
                case let (lower?, upper?): text = ">= \(lower) < \(upper)"
                case let (lower?, nil): text = ">= \(lower)"
                case let (nil, upper?): text = "< \(upper)"
                default: continue
                }
                if seen.insert(text).inserted { pieces.append(text) }
            }
        }
        return pieces.joined(separator: "，")
    }

    static func mapSeverityLabel(_ label: String) -> RiskLevel? {
        switch label.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() {
        case "CRITICAL": return .critical
        case "HIGH": return .high
        case "MODERATE", "MEDIUM": return .medium
        case "LOW": return .low
        case "NONE", "UNSPECIFIED": return RiskLevel.none
        default: return nil
        }
    }

    static func mapCvssScore(_ score: Double) -> RiskLevel {
        switch score {
        case 9...: return .critical
        case 7..<9: return .high
        case 4..<7: return .medium
        case 0.1..<4: return .low
        default: return .medium
        }
    }

    static func firstNonEmpty(_ candidates: String?...) -> String {
        for candidate in candidates {
            let text = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !text.isEmpty { return text }
        }
        return ""
    }

    static func truncate(_ text: String, length: Int) -> String {
        guard text.count > length else { return text }
        let end = text.index(text.startIndex, offsetBy: length)
        return String(text[..<end]) + "…"
    }

    static func parseDate(_ text: String?) -> Date? {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return nil }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        if let date = plain.date(from: raw) { return date }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        let dayOnly = DateFormatter()
        dayOnly.locale = Locale(identifier: "en_US_POSIX")
        dayOnly.timeZone = TimeZone(identifier: "UTC")
        dayOnly.dateFormat = "yyyy-MM-dd"
        return dayOnly.date(from: raw)
    }
}
