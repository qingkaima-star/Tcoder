import Foundation

//  R5b · `mergeConfident` 的**唯一**算法处（RD-25 剩余那半）。
//
//  R5 留下的实现里它是**从份数推出来的**（`CoverageMergePlanner`）：
//     · `pool.count == 1 → mergeConfident = true`（"只剩一份，所以谈不上合并"）
//     · `mergeConfident = (basis == .lineSetUnion)`
//  于是"进总数的那一份报告是哪次运行、测的哪份源码、属于哪个模块"全部未知时，
//  界面照样得到一句"合并可信"。**份数不是身份**：一份认不出来源的报告不会因为
//  "没有别份与它冲突"就变得可信。
//
//  现在的判据：`mergeConfident` 只回答一件事 —— **进入总数的每份报告，四格身份齐不齐、
//  互相核对过没有**。缺任意一格就不是 confident（`false`），并逐条点名缺哪格。
//  三态的分工不变：`nil` = 压根没给总数；`false` = 给了总数但身份不成立。
//  "有没有证据没并进总数"是**另一件事**，由 `CoverageMergeLedger.evidenceLeftOut` 说，
//  两件事不许压进同一个布尔（压了就分不清"没测"与"测了但可疑"）。

// MARK: - 缺的是哪一格

enum CoverageIdentityGap: String, Codable, Sendable, CaseIterable {
    case unrecognizedFormat       // 格式身份缺
    case unknownRun               // 运行身份缺（认不出属于哪次运行）
    case unknownModule            // 模块身份缺（报告在被扫目录之外）
    case unboundSource            // 源码身份缺（没有提交指纹）
    case lineSetConflict          // 撞上同一文件而双方都拿不出行集合
    case evidenceLeftOut          // 有可核对的证据没并进总数

    var note: String {
        switch self {
        case .unrecognizedFormat: return "认不出格式"
        case .unknownRun: return "认不出属于哪次运行"
        case .unknownModule: return "认不出属于哪个模块"
        case .unboundSource: return "没有源码提交指纹"
        case .lineSetConflict: return "重叠判冲突，已摘出分母"
        case .evidenceLeftOut: return "有报告未并进总数"
        }
    }
}

// MARK: - 结论

enum CoverageMergeConfidence {
    struct Verdict: Equatable, Sendable {
        /// `nil` = 没给总数（缺证据 ≠ 不可信）；`false` = 给了总数但身份不成立。
        var confident: Bool?
        /// 缺了哪些格（去重、稳定序）。`true` 时必为空。
        var gaps: [CoverageIdentityGap]
        /// 逐份点名。**只点名进总数的那几份** —— 没进总数的那份本来就在丢弃清单里，
        /// 两处各说各的。（形状见 `CoverageIdentityGapPerReport`：元组会让本类型
        /// 的 `Equatable`/`Sendable` 综合实现失败。）
        var missingByPath: [CoverageIdentityGapPerReport]

        static let noTotal = Verdict(confident: nil, gaps: [], missingByPath: [])
    }

    /// 一份报告**自己**缺哪几格身份。`fingerprint` 是被扫仓库的 HEAD 短哈希（读不到 ⇒ nil）。
    static func gaps(of candidate: CoverageCandidate, fingerprint: String?) -> [CoverageIdentityGap] {
        var gaps: [CoverageIdentityGap] = []
        if candidate.identity.format == .unrecognized { gaps.append(.unrecognizedFormat) }
        if candidate.identity.runKey == nil { gaps.append(.unknownRun) }
        if candidate.identity.moduleKey == nil { gaps.append(.unknownModule) }
        if fingerprint == nil { gaps.append(.unboundSource) }
        // 注：**不**把"只有汇总粒度"当身份缺口。一份报告能不能进总数由
        // `CoverageCandidate.isMergeEligible` 决定（进不来就落进 `dropped`，那边由
        // `.evidenceLeftOut` 说话），身份层再数一遍就是两套尺子。
        return gaps
    }

    /// 结论本身。**只看进总数的那几份 + 有没有证据被留在外面**，不看份数。
    static func verdict(included: [CoverageCandidate],
                        fingerprint: String?,
                        gaveTotal: Bool,
                        evidenceLeftOut: Bool,
                        conflictingFileCount: Int) -> Verdict {
        guard gaveTotal else { return .noTotal }
        // 局部名不能叫 `gaps`：它与静态方法 `gaps(of:fingerprint:)` 撞名（Swift 里
        // 变量会把同名方法挡掉），第一次编译就是这么报 "cannot call value of non-function type"。
        var collected: [CoverageIdentityGap] = []
        var missing: [CoverageIdentityGapPerReport] = []
        for candidate in included {
            let own = gaps(of: candidate, fingerprint: fingerprint)
            if !own.isEmpty {
                missing.append(CoverageIdentityGapPerReport(path: candidate.report.path, gaps: own))
            }
            collected.append(contentsOf: own)
        }
        if evidenceLeftOut { collected.append(.evidenceLeftOut) }
        if conflictingFileCount > 0 { collected.append(.lineSetConflict) }
        let unique = CoverageIdentityGap.allCases.filter { collected.contains($0) }   // 稳定序
        return Verdict(confident: unique.isEmpty ? true : false, gaps: unique, missingByPath: missing)
    }
}
