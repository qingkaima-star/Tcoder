// OWNER: R3 依赖证据链 · OSV 那一路"到底答没答上"的逐条归因（RD-11 / RD-13c）
//
// 本文件做两件事：
//   ① **整块搬入** `OsvClient.swift` 的四个查询管道函数
//      （`performOsvLookup` / `osvSeedEntries` / `expandOsvDetails` / `osvQueryBatch`）。
//      搬动逐字节，不改取义；搬的原因是 OsvClient.swift 已被 `SourcesSizeAuditTests`
//      的 400 行口径点死（余 6 行，台账 §7.5 明写"新增实现一律整块另起新文件"），
//      而下面 ② 的新逻辑必须落在这条链上。
//   ② 补上"attempted ≠ checked"的最后一个洞（RD-11 的第四态，工单原话：
//      **查询成功但这条包没被覆盖 ⇒ "没查到不等于没有"**）：
//      旧实现只有"整批失败"这一个失败面。两种"发出去了、也答了、却没查到底"的结局
//      会被摊成"查过了、干净"：
//        · `v1/querybatch` 的 `results` 与请求**按顺序一一对应**是它的合同。
//          旧写法 `queries.indices.map { index < results.count ? … : [] }` 把
//          **响应短于请求**的那一段尾部直接当成"答了、空数组"⇒ 永远查不到、永远绿。
//          现在判"这批不可用"，走逐包回退（回退会逐包如实计失败数）。
//        · 批量端点只回 id，详情要按 `v1/vulns/<id>` 二次拉；拉不到（失败 / 超出
//          `maxOsvDetailRequests` 被截断 / 预算用尽没来得及发）时旧实现只是
//          `entries[id] = nil` 并在那句中文里披露条数 —— **逐条状态却没人被改**，
//          于是"确实看到了公告 id、只是没展开成"的那条依赖被记成 `.checked`（已核对）。
//          现在这些查询身份经 `incompleteCoordinates` 结构化地交给归因层，
//          由它落 `.failed`（`DependencyCheckState.failed` 的注释就写着"响应解不出来"）。
import Foundation

extension DependencyNetworkLookup {

    /// 一次 OSV 查询的产出：公告 + 失败请求数 + 给人看的那句 + **没能查到底的查询身份**。
    ///
    /// `incompleteCoordinates` 不是计数而是身份清单：归因层要按坐标点名到哪一条依赖，
    /// 只报条数就会重演"被上限切掉 7 条 ⇒ 把答了的 100 条也说成没查"。
    struct OsvPayload: Sendable {
        var advisories: [SecurityAdvisory]
        var failedRequests: Int
        var note: String?
        var incompleteCoordinates: [String] = []
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
        let dropped = await expandOsvDetails(&entries, deadline: deadline, note: &note)
        let advisories = DependencyNetworkLookup.osvAdvisories(from: entries, queries: queries)
        if seed.failed > 0 { DependencyNetworkLookup.appendNote(&note, "本次 \(seed.failed) 个 OSV 请求失败") }
        return OsvPayload(advisories: VulnerabilitySource.sortedAdvisories(advisories),
                          failedRequests: seed.failed, note: note,
                          incompleteCoordinates: unresolvedOsvCoordinates(queries: queries,
                                                                          seed: seed.entries,
                                                                          expanded: entries,
                                                                          droppedIDs: dropped))
    }

    /// 第一步：批量端点拿 id，拿不到就整批退回逐包查询。
    /// 「批量失败算 1 次 + 逐包逐次算」这个计数口径，以及那句中文，与拆分前逐字相同。
    static func osvSeedEntries(_ queries: [OsvPackageQuery], deadline: Date) async -> OsvSeed {
        var failed = 0
        var note: String?
        var entries = [String: OsvEntry]()
        if let idsByQuery = await osvQueryBatch(queries, deadline: deadline) {
            for (index, ids) in idsByQuery.enumerated() where index < queries.count {
                for id in ids { DependencyNetworkLookup.merge(&entries, id: id, queryIndex: index, vuln: nil) }
            }
        } else {
            failed += 1
            note = "OSV 批量接口不可用，已改用逐包查询"
            let fallback = await DependencyNetworkLookup.osvSingleQueryFallback(queries, deadline: deadline)
            failed += fallback.failedRequests
            for row in fallback.rows { DependencyNetworkLookup.merge(&entries, id: row.id, queryIndex: row.queryIndex, vuln: row.vuln) }
        }
        return OsvSeed(entries: entries, failed: failed, note: note)
    }

    /// 第二步：批量接口只回 id，需要再按 id 拉完整记录。
    /// 展开不全时的三态账本与那句披露说明原样搬过来，没有改判定顺序。
    ///
    /// **返回"没能展开成的 id"**（新增的那一项）：调用方要把它们摊回查询身份。
    /// 三种"没展开成"都算：详情请求失败、时间预算用尽没发、超出 `maxOsvDetailRequests`
    /// 被截断（那批连队列都没进 —— 只披露条数而不改逐条状态，就是"没查到"长成"没有漏洞"）。
    static func expandOsvDetails(_ entries: inout [String: OsvEntry],
                                 deadline: Date,
                                 note: inout String?) async -> [String] {
        let missing = entries.compactMap { $0.value.vuln == nil ? $0.key : nil }.sorted()
        let toFetch = Array(missing.prefix(maxOsvDetailRequests))
        let detailRows: [(id: String, outcome: OsvDetailOutcome, vuln: OsvVuln?)] =
            toFetch.isEmpty ? [] : await DependencyNetworkLookup.fetchOsvDetails(toFetch, deadline: deadline)
        var dropped: [String] = detailRows.compactMap { $0.vuln == nil ? $0.id : nil }
        for row in detailRows {
            if let vuln = row.vuln {
                DependencyNetworkLookup.merge(&entries, id: row.id, queryIndex: nil, vuln: vuln)
            } else {
                // 展开失败/未展开的 id 出不了公告，但已取回的那部分必须留下。
                entries[row.id] = nil
            }
        }
        // 被条数上限截断、连队列都没进的那些：同样是"看到了公告 id 却没查到底"。
        dropped.append(contentsOf: missing.dropFirst(toFetch.count))
        let tally = OsvDetailTally(totalIDs: missing.count, outcomes: detailRows.map(\.outcome))
        if let truncation = DependencyNetworkLookup.osvDetailNote(totalIDs: missing.count, tally: tally,
                                         cap: maxOsvDetailRequests) {
            DependencyNetworkLookup.appendNote(&note, truncation)
        }
        return dropped
    }

    /// POST https://api.osv.dev/v1/querybatch；**响应不可用时**返回 nil（由调用方走逐包回退）。
    ///
    /// 「不可用」有两种（第二种是这里新认出来的）：
    ///   · 请求 / HTTP / 解码失败，或没有 `results` 键；
    ///   · `results` 的**条数与请求条数不等** —— 一一对应是这个端点的合同，收不齐就
    ///     无法判断"尾部那几条到底是答了空、还是根本没答"。旧写法按 `index < results.count`
    ///     补 `[]`，等于替数据源把没答的那几条说成"答了、干净"。
    static func osvQueryBatch(_ queries: [OsvPackageQuery], deadline: Date) async -> [[String]]? {
        guard let url = osvURL("v1/querybatch"),
              let body = try? JSONEncoder().encode(DependencyNetworkLookup.osvBatchPayload(for: queries)) else { return nil }
        var request = makeRequest(url: url, deadline: deadline)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        guard let (data, response) = try? await session.data(for: request), isOK(response),
              let decoded = try? jsonDecoder.decode(OsvBatchResponse.self, from: data),
              let results = decoded.results,
              results.count == queries.count else { return nil }
        return results.map { result in (result.vulns ?? []).map(\.id) }
    }

    /// 「哪些查询身份没能查到底」——纯函数，逐条按身份算，不看任何一句中文。
    ///
    /// 一条查询身份算"没查到底"的充要条件：它名下的公告 id **全部**没展开成，
    /// 且没有任何一条展开成功的公告落回它身上。
    /// 只要有一条展开成功了，这一条就是真的查出了东西（`.checked` + 命中），
    /// 那副"没查到底"的帽子不该扣在它头上 —— 反过来说，扣错了方向就是把有公告的包说成没公告。
    static func unresolvedOsvCoordinates(queries: [OsvPackageQuery],
                                         seed: [String: OsvEntry],
                                         expanded: [String: OsvEntry],
                                         droppedIDs: [String]) -> [String] {
        guard !droppedIDs.isEmpty else { return [] }
        var answered: Set<Int> = []
        for entry in expanded.values where entry.vuln != nil {
            // 只认"详情真的展开成了"的那些。被条数上限截断的 id 仍留在 entries 里但 `vuln == nil`
            // —— 把它们当成答过，这个函数就白写了。
            for index in entry.queryIndices { answered.insert(index) }
        }
        var dangling: Set<Int> = []
        for id in droppedIDs { for index in seed[id]?.queryIndices ?? [] { dangling.insert(index) } }
        return dangling.subtracting(answered).compactMap { index in
            index < queries.count ? queries[index].coordinate : nil
        }.sorted()
    }
}
