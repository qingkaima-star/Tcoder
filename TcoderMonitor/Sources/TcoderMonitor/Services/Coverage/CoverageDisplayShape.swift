import Foundation

//  R5b · **§6.1 统一显示形状**：三道截断（深度 ≤6、40 份上限、进总数份数上限）
//  共用**同一个**形状与**同一句**披露，不许各造一套。
//
//  为什么必须只有一个生产者：这三处历史上各自喊话 ——
//    · 发现阶段：`if depth > 6 || out.found.count >= 40 { continue }`（连列都不列，静默）；
//    · 合并阶段：`prefix(6)`（R5 已删，删完由 `displayedCount` 接管"交给合并几份"这件事）；
//    · 读不动的目录：只有 `unreadableDirectoryCount` 一个数。
//  每处自己造一句，界面上就会出现三个不同形状的"被截断了"，而**没有一处能说清总体有多大**。
//  本文件把四格读数 + 两句人话集中在 `evaluate` 一处算，`CoverageAnalyzer` 只负责抄进契约。
//
//  ⚠️ 口径写死（与 `docs/R5b-覆盖率身份层契约字段清单.md` §2.1 同源）：
//  `truncationTotalCount` **只含"看到了的"**（交给合并的 + 超限点名的）。
//  深到没下潜、命中上限后没下潜、读不动的那些目录里的东西**根本没被看到**，
//  所以它们不在这个数里，而是落在 `unmeasuredScope` 那句话里 ——
//  **单独读 `truncationTotalCount` 是低估**，这一条在 `statementParts` 里当场说明。

// MARK: - 形状本体

struct CoverageDisplayShape: Equatable, Sendable {
    /// 真实总数 = 已看到的候选 + **已点名**的超限项（不含"根本没下潜"的部分 ⇒ 单读会低估）。
    var truncationTotalCount: Int
    /// 真正交给解析/合并的份数（与 `CoverageMetrics.scannedFileCount` 同源）。
    var displayedCount: Int
    /// `max(0, truncationTotalCount - displayedCount)`。
    var undisplayedCount: Int
    /// 超限没交给合并的报告：**逐条相对路径**（可点名、可 diff；一行摘要不算台账）。
    var undisplayedReports: [String]
    /// 看见了但没下潜/没读动的目录：**逐条相对路径**（原因与计数在 `unmeasuredScope`）。
    var unexaminedDirectories: [String]
    /// 命中份数上限而没进合并的合法报告份数（= `undisplayedCount`，同一处写、守卫钉一致）。
    var droppedByCap: Int
    /// 人话 + 计数：「N 个目录深于 6 层没看、M 个目录读不动…**这一格非空时，
    /// "该项目没有覆盖率报告"这句话不成立**（有用例钉着）。`nil` = 扫描面完整。
    var unmeasuredScope: String?

    /// 唯一的计算入口。**只吃发现阶段的账 + 交给合并的份数**，不读盘、不改判定。
    static func evaluate(discovery: CoverageDiscoveryStats, displayedCount: Int) -> CoverageDisplayShape {
        let overCap = discovery.overCapReportPaths          // 发现阶段已排好稳定序
        let total = displayedCount + overCap.count
        var scopeParts: [String] = []
        if discovery.directoriesSkippedByDepth > 0 {
            scopeParts.append("\(discovery.directoriesSkippedByDepth) 个目录深于 \(discovery.depthCap) 层没有下潜")
        }
        if discovery.directoriesSkippedByFileCap > 0 {
            scopeParts.append("\(discovery.directoriesSkippedByFileCap) 个目录命中 \(discovery.fileCap) 份上限后没有下潜")
        }
        if discovery.unreadableDirectories > 0 {
            scopeParts.append("\(discovery.unreadableDirectories) 个目录读不动（权限或已消失）")
        }
        let unexamined = discovery.unexaminedDirectoryPaths       // 三类合起来，逐条点名
        return CoverageDisplayShape(
            truncationTotalCount: total,
            displayedCount: displayedCount,
            undisplayedCount: Swift.max(0, total - displayedCount),
            undisplayedReports: overCap,
            unexaminedDirectories: unexamined,
            droppedByCap: overCap.count,
            unmeasuredScope: scopeParts.isEmpty ? nil : scopeParts.joined(separator: "、"))
    }

    /// 「另有 N 份未合并」那一句的**唯一措辞**（RD-51）。
    ///
    /// 为什么只能有一处：历史上形状里写「…：坐标…等（逐条清单见 undisplayedReports）」、
    /// `CoverageMetrics.capDisclosureText` 另写一套「…（逐条点名见 undisplayedReports）」——
    /// 同一个 `droppedByCap` 在覆盖率页与健康页长成两句话，
    /// 而后一句**声称逐条点名却一个名字都不给**，读的人按它去 JSON 里找点名，
    /// 找到的那套其实早已被这一套替代。
    /// 点名给**相对路径**而不是 basename：一棵树里 40 份都叫 `lcov.info`，只报文件名等于没点。
    static func capSentence(dropped: Int, coordinates: [String]) -> String {
        let head = "另有 \(dropped) 份未合并"
        let named = coordinates.prefix(3).map(coverageCoordinateShort)
        guard !named.isEmpty else {
            // 计数在、坐标不在 ⇒ 那是两次统计拼出来的账，不许装作点过名。
            return head + "（这一版没留下逐条坐标，点不出名）"
        }
        return head + "：" + named.joined(separator: "、")
            + (coordinates.count > named.count ? "等（逐条清单见 undisplayedReports）" : "（已点名）")
    }

    /// 上屏那几句（**唯一**的披露生产者；`CoverageMergeLedger.statement` 只负责把它们拼进去）。
    var statementParts: [String] {
        var parts: [String] = []
        if droppedByCap > 0 {
            // 摘掉这句 ⇒ `CoverageContractFieldTests` 转红（超限每一份都要能点名）。
            parts.append(CoverageDisplayShape.capSentence(dropped: droppedByCap,
                                                          coordinates: undisplayedReports))
        }
        if let scope = unmeasuredScope {
            parts.append("⚠ 扫描面不完整：" + scope
                + " ⇒ 这里说的「没找到报告」不等于「该项目没有覆盖率报告」")
        }
        return parts
    }
}

/// 点名用的短坐标：相对路径原样（已经很短）；给的是绝对路径时退到**末两段**
/// —— 一棵树里几十份都叫 `lcov.info`，只报 basename 等于没点名。
func coverageCoordinateShort(_ path: String) -> String {
    let pieces = path.split(separator: "/", omittingEmptySubsequences: true)
    guard path.hasPrefix("/"), pieces.count > 2 else { return path }
    return pieces.suffix(2).joined(separator: "/")
}

// MARK: - 身份与可信度那句上屏话（视图未接线前，这里是唯一口径来源）

extension CoverageMetrics {
    /// `mergeConfident` 的三态说法。**`nil` 与 `false` 混掉就等于把"没测"说成"测了但可疑"**。
    var mergeConfidenceText: String? {
        guard let confident = mergeConfident else {
            return reports.isEmpty ? nil : "未给总数（缺证据 ≠ 不可信）"
        }
        if confident { return "总数可核对：进入总数的每份报告四格身份齐全" }
        let missing = reports.filter { $0.runEvidence == nil || $0.runKey == nil
            || $0.moduleKey == nil || $0.sourceFingerprint == nil || $0.format == nil }
        let head = missing.isEmpty ? "总数不可信" : "总数不可信：\(missing.count) 份报告缺身份格"
        let slots: [String] = [
            missing.contains { $0.runKey == nil } ? "认不出属于哪次运行" : nil,
            missing.contains { $0.format == nil || $0.format == CoverageReportFormat.unrecognized.rawValue }
                ? "格式未记录" : nil,
            missing.contains { $0.moduleKey == nil } ? "模块未知" : nil,
            missing.contains { $0.sourceFingerprint == nil } ? "未绑定提交" : nil,
        ].compactMap { $0 }
        return slots.isEmpty ? head : head + "（" + slots.joined(separator: "、") + "），已分开呈现"
    }

    /// 「有没有东西被上限摘掉」这句。**三态分开**，`nil` 不许渲染成"没有问题"。
    /// `droppedByCap > 0` 那一档**逐字转发** `capSentence`（RD-51：这里以前自己写了一套说法）。
    var capDisclosureText: String {
        guard let droppedByCap else { return "未统计是否有报告被上限丢弃" }
        guard droppedByCap > 0 else { return "没有报告因命中上限被丢弃" }
        return CoverageDisplayShape.capSentence(dropped: droppedByCap,
                                                coordinates: undisplayedReports ?? [])
    }

    /// §6.1 那几格合起来的那句**产品侧披露**（唯一生产者）：
    /// 健康分的"这一维为什么缺"那句就拼在它后面 —— 有了它，`unmeasuredScope` /
    /// `droppedByCap` / `undisplayedReports` 三格才算**有读者**（RD-34 钉的是"有写无读"）。
    ///
    /// ⚠️ 六格齐全时**不自己造话**，直接取 `statementParts`（RD-51）：
    /// 覆盖率页尾与 CLI 读的是那一份，健康页若另拼一套，同一个数就会在两页上长成两句话——
    /// 尤其丢掉「⇒ 这里说的『没找到报告』不等于『该项目没有覆盖率报告』」那半边（RD-26 要的退让句）。
    /// 六格不齐（旧报告没统计过）才退到 `unmeasuredScope` + `capDisclosureText` 的既有修辞。
    var displayDisclosureText: String? {
        if let shape = displayShapeFromFields {
            return Self.disclosureSentence(shape.statementParts)
        }
        var parts: [String] = []
        if let unmeasuredScope { parts.append(unmeasuredScope) }
        if let droppedByCap, droppedByCap > 0 { parts.append(capDisclosureText) }
        return Self.disclosureSentence(parts)
    }

    /// 披露句子串成上屏那一句的**唯一**排法（分隔符与句末标点也只有一处）。
    /// 空清单 ⇒ `nil`：扫描面完整、也没摘掉东西时，页上不许留一个空壳句子。
    private static func disclosureSentence(_ parts: [String]) -> String? {
        parts.isEmpty ? nil : parts.joined(separator: "；") + "。"
    }

    /// "这个项目到底有没有覆盖率报告"这句话成不成立。
    /// **上限/深度/读不动任一命中时不成立** —— RD-26 的病根就是把"我没看"说成"这里没有"。
    var absenceClaimIsSound: Bool {
        reports.isEmpty && (unmeasuredScope?.isEmpty ?? true)
            && (droppedByCap ?? 0) == 0 && (undisplayedCount ?? 0) == 0
    }

    /// 从**落盘的那几格**原样还原 §6.1 显示形状（RD-50 的接线前提）。
    ///
    /// 为什么能还原、也算不上第二把尺子：`CoverageDisplayShape` 由 `evaluate` 一次算出，
    /// 再由 `CoverageAnalyzer` 逐格抄进契约（`metrics.truncationTotalCount = shape.…` 那几行），
    /// 两侧本来同源。而上屏那一句的唯一装配口 `statementParts` 住在形状上，
    /// 视图与 CLI 手里只有 `CoverageMetrics`（`CoverageMergeLedger` 不落盘）
    /// ⇒ 这里把抄出去的格子**按名字接回来**，一个数都不重算、不换算、不取 `reports.count`。
    /// ⚠️ 六格（除 `unmeasuredScope`）任一缺席 ⇒ `nil`：那一版根本没统计过。
    ///    `unmeasuredScope` 刻意不参与缺席判定 —— 它 `nil` 的意思是「扫描面完整」，
    ///    和「没统计」是两件事，混用就是把三态压回两态（本轮要修的那件事）。
    var displayShapeFromFields: CoverageDisplayShape? {
        guard let total = truncationTotalCount,
              let displayed = displayedCount,
              let undisplayed = undisplayedCount,
              let dropped = droppedByCap,
              let reportCoordinates = undisplayedReports,
              let directories = unexaminedDirectories else { return nil }
        return CoverageDisplayShape(
            truncationTotalCount: total,
            displayedCount: displayed,
            undisplayedCount: undisplayed,
            undisplayedReports: reportCoordinates,
            unexaminedDirectories: directories,
            droppedByCap: dropped,
            unmeasuredScope: unmeasuredScope)
    }

    /// 覆盖率页页尾那一句**账**（RD-50：字段全都落了盘、装配口也早就有，缺的是最后一步读者）。
    /// 三态各说各话，谁也不许冒充谁：
    /// · **字段缺席**（旧报告没统计过）⇒ 走 `capDisclosureText` 的既有修辞
    ///   「未统计是否有报告被上限丢弃」—— 绝不渲染成「没被切掉」，也不新造第二套说法；
    /// · **统计过、真的没切**（六格齐且各为 0）⇒ `nil`，**一个字都不许多**；
    /// · **有东西被摘掉** ⇒ 点名份数 + 已有的相对路径坐标，句子**逐字**来自
    ///   `CoverageDisplayShape.statementParts`（本函数只做串接，不拼一个汉字的修辞）。
    var boardAccountingNote: String? {
        guard let shape = displayShapeFromFields else { return capDisclosureText }
        return Self.disclosureSentence(shape.statementParts)
    }
}

extension CoverageReport {
    /// 格式那一格的上屏话：`nil`（旧报告没记过）与 `"unrecognized"`（认不出格式）
    /// **是两件事**，这里必须给出两种不同说法。
    var formatText: String {
        guard let format else { return "格式未记录（旧报告，不声称与任何一份同源）" }
        guard format != CoverageReportFormat.unrecognized.rawValue else {
            return "认不出格式，不与任何报告合并"
        }
        return CoverageReportFormat(rawValue: format)?.toolName ?? "格式键 \(format)"
    }

    /// 运行归属 + 证据档一句（只有键没有"凭什么"，读的人无法分辨对偶落法与恰好同目录）。
    var runText: String {
        guard let runKey else { return "认不出属于哪次运行（不参与任何去重）" }
        guard let evidence = runEvidence,
              let attested = CoverageRunEvidence(rawValue: evidence) else {
            return "有运行键 \(runKey) 但没记证据档 ⇒ 不声称同源"
        }
        return "同一次运行（\(attested.note)）"
    }

    /// 模块与源码身份那句。`nil` 一律说"未知"，不许补成空串或 0。
    var bindingText: String {
        let module: String
        if let moduleKey {
            module = moduleKey.isEmpty ? "全仓（仓库根）" : "模块 \(moduleKey)"
        } else {
            module = "模块未知（报告在被扫目录之外）"
        }
        let source: String
        if let commit = sourceFingerprint {
            switch sourceRepository {
            case ".":
                source = "扫描时源码在 \(commit)（被扫目录自己的仓库；**不是**产物自报的提交）"
            case nil:
                source = "扫描时源码在 \(commit)，但**没记**这个提交来自哪个仓库 ⇒ 不许声称是本项目自己的"
            case let coordinate?:
                // 措辞与 `ScanProvenance.relocationNote` 同一句关键词（两处说同一件事，不许两套话）。
                source = "扫描时源码在 \(commit)，注意：提交号来自外层仓库"
                    + "（相对被扫根 \(coordinate)）⇒ 说的不是本项目自己的提交"
            }
        } else {
            source = "未绑定提交（非 git 或 git 读失败），不按新鲜数据声称"
        }
        return module + " · " + source
    }
}
