import XCTest
@testable import TcoderMonitor

/// OWNER: WS-X3 TestSplit —— 自 SourceFileReachabilityTests.swift 的 `buildOutcome` 抽出的取证步骤。
///
/// 为什么要抽：`buildOutcome` 原判 **CC 29 / 73 行**，是本工具自己扫出来并点名的高复杂度热点
/// （见 `TCODER_SELF_SCAN=1` 取证转储第 4 节）。抽完之后每一步各自 1–5 个判定，
/// 判定顺序、过滤条件、`sorted()` 与 `Array(...)` 的写法**逐字保留**，只是分了家。
///
/// 四条取证规则（uniqueType / qualified / dispatcher / staticShorthand）的语义一个字没改：
/// 元测试仍在 `SourceFileReachabilityMetaTests.swift`，端到端断言仍在
/// `SourceFileReachabilityTests+SyntheticGuards.swift`。
extension SourceFileReachabilityTests {

    /// 「谁在哪些文件里声明过这个类型 / 这个成员」。唯一性必须在 Sources + Tests 全集上算。
    static func declarerIndex(_ docs: [RDoc], analyses: [String: RAnalysis])
        -> (types: [String: Set<String>], members: [OwnerMember: Set<String>]) {
        var typeDeclarers: [String: Set<String>] = [:]
        var memberDeclarers: [OwnerMember: Set<String>] = [:]
        for doc in docs {
            guard let a = analyses[doc.relativePath] else { continue }
            for t in a.types { typeDeclarers[t, default: []].insert(doc.relativePath) }
            for m in a.members { memberDeclarers[m, default: []].insert(doc.relativePath) }
        }
        return (typeDeclarers, memberDeclarers)
    }

    /// 一个生产文件拿到的全部证据；`candidates` 是「只在这里声明」的候选数（分母）。
    static func evidence(for path: String, analysis: RAnalysis, index: TokenIndex,
                         declarers: (types: [String: Set<String>],
                                     members: [OwnerMember: Set<String>]),
                         analyses: [String: RAnalysis], candidates: inout Int) -> [Evidence] {
        typeEvidence(analysis, path: path, index: index, declarers: declarers.types,
                     analyses: analyses, candidates: &candidates)
            + memberEvidence(analysis, path: path, index: index, declarers: declarers.members,
                             analyses: analyses, candidates: &candidates)
    }

    /// 规则一 `uniqueType`：类型只在本文件声明，别处整词提到它。
    static func typeEvidence(_ analysis: RAnalysis, path: String, index: TokenIndex,
                             declarers: [String: Set<String>],
                             analyses: [String: RAnalysis], candidates: inout Int) -> [Evidence] {
        var list: [Evidence] = []
        for t in analysis.types.sorted() {
            guard declaredOnlyIn(declarers, t, path) else { continue }
            candidates += 1
            let hits = Array((index.word[t] ?? []).filter { $0 != path })
            list += witness(.uniqueType, symbol: t, owner: t, hits: hits, analyses: analyses)
        }
        return list
    }

    /// 规则二~四：限定名 `Owner.member`、同作用域派发、静态取词式 `.member`。
    static func memberEvidence(_ analysis: RAnalysis, path: String, index: TokenIndex,
                               declarers: [OwnerMember: Set<String>],
                               analyses: [String: RAnalysis], candidates: inout Int) -> [Evidence] {
        var list: [Evidence] = []
        for key in analysis.members.sorted() {
            guard declaredOnlyIn(declarers, key, path) else { continue }
            candidates += 1
            let sym = "\(key.owner).\(key.member)"
            let qualifiedHits = Array((index.qualified[sym] ?? []).filter { $0 != path })
            list += witness(.qualified, symbol: sym, owner: key.owner,
                            hits: qualifiedHits, analyses: analyses)
            // 派发点：另一文件自己拥有 Owner 作用域，并整词提到该成员名
            let dispatchHits = Array((index.word[key.member] ?? []).filter { other in
                other != path && analyses[other]?.owners.contains(key.owner) == true
            })
            list += witness(.dispatcher, symbol: sym, owner: key.owner,
                            hits: dispatchHits, analyses: analyses)
            guard analysis.staticMembers.contains(key) else { continue }
            // 取词式必须带前导限制，否则 `NSWorkspace.shared` 会被当成前导点简写、
            // 白送证据（真漏过一次）。完整说明与两条元测试见
            // `SourceFileReachabilityMetaTests.swift`。
            // 元测试：`testStaticShorthandNeedsTheOwnerInScope` + `testLeadingDotRegexRequiresABareDot`。
            let dotHits = Array((index.dot[key.member] ?? []).filter { $0 != path })
            list += witness(.staticShorthand, symbol: sym, owner: key.owner,
                            hits: dotHits, analyses: analyses)
        }
        return list
    }

    /// 「命中别的文件 → 一条证据」，没命中就不产出（原来的 `if let` 就是这个形状）。
    static func witness(_ rule: Rule, symbol: String, owner: String, hits: [String],
                        analyses: [String: RAnalysis]) -> [Evidence] {
        guard let w = bestHit(hits, preferring: owner, analyses: analyses) else { return [] }
        return [Evidence(rule: rule, symbol: symbol, witness: w)]
    }

    /// 三分类 + 规则计票：白名单 / 零证据（判死）/ 在用。顺序即原判据顺序。
    static func classifyFiles(_ out: inout ScanOutcome, whitelist: Set<String>) {
        for path in out.productionFiles {
            let list = out.evidence[path] ?? []
            if whitelist.contains(path) { out.whitelisted.append(path) }
            else if list.isEmpty { out.unused.append(path) }
            else {
                out.inUse.append(path)
                for e in list { out.ruleTally[e.rule, default: 0] += 1 }
            }
        }
    }
}
